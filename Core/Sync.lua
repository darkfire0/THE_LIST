local _, ns = ...

local Sync = {}
ns.Sync = Sync

local Guard = ns.Guard
local DB = ns.DB

local LibSerialize = _G.LibStub and _G.LibStub("LibSerialize", true)
local LibDeflate = _G.LibStub and _G.LibStub("LibDeflate", true)
local CTL = _G.ChatThrottleLib

local CHUNK_LIMIT = 230
local MAX_CHUNKS = 40
local MAX_DEFERRED_CHUNKS = 60
local HANDSHAKE_COOLDOWN = 20

local onlinePeers = {}     -- [authorID] = { authorLabel, via, target, gameAccountID, lastHelloAt }
local helloReplyAt = {}    -- [authorID] = lastHelloReplyTime
local pendingRevRanges = {} -- [authorID] = { { fromRev, toRev, ts }, ... }
local gapHelloScheduled = {} -- [authorID] = true
local lastGapHelloAt = {}  -- [authorID] = timestamp
local bnetKnownSent = {}   -- [gameAccountID] = lastHandshakeTime
local inboundBuffers = {}  -- [bufKey] = { total, received, parts, ts }
local deferredQueue = {}   -- queued sends while InChatMessagingLockdown() is active
local deferredHelloPending = false
local guildMembers = {}
local lastGuildHelloReplyAt = 0
local manualSyncAt = 0
local lastSendErrorNoticeAt = 0
local versionNoticeShown = false
local msgCounter = 0
local commFrame
local initialized = false

local stats = {
    prefixRegistered = false,
    prefixResult = nil,
    sentHello = 0,
    sentDelta = 0,
    sentChunksOk = 0,
    sentChunksFail = 0,
    recvHello = 0,
    recvDelta = 0,
    recvDecodeFail = 0,
    lastSendError = nil,
}

local function CompareSemver(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return 0 end
    local a1, a2, a3 = a:match("^(%d+)%.(%d+)%.(%d+)")
    local b1, b2, b3 = b:match("^(%d+)%.(%d+)%.(%d+)")
    a1, a2, a3 = tonumber(a1) or 0, tonumber(a2) or 0, tonumber(a3) or 0
    b1, b2, b3 = tonumber(b1) or 0, tonumber(b2) or 0, tonumber(b3) or 0
    if a1 ~= b1 then return (a1 > b1) and 1 or -1 end
    if a2 ~= b2 then return (a2 > b2) and 1 or -1 end
    if a3 ~= b3 then return (a3 > b3) and 1 or -1 end
    return 0
end

local function NotifyNewerVersionOnce(peerVer, peerProto)
    if versionNoticeShown then return end
    versionNoticeShown = true
    if peerProto and peerProto > ns.PROTOCOL_V then
        ns.Print(string.format("A friend/guildmate is running a newer THE LIST protocol (v%d). Update the addon to stay in sync.", peerProto))
    elseif peerVer then
        local cleanVer = Guard.SanitizePeerText(peerVer, 24)
        if cleanVer ~= "" then
            ns.Print("A newer version of THE LIST (v" .. cleanVer .. ") is available from a friend/guildmate.")
        end
    end
end

local function NextMsgID()
    msgCounter = (msgCounter % 99999) + 1
    return tostring(msgCounter)
end

local function EncodePacket(pkt)
    if not LibSerialize or not LibDeflate then return nil end
    local serialized = LibSerialize:Serialize(pkt)
    if not serialized then return nil end
    local compressed = LibDeflate:CompressDeflate(serialized)
    if not compressed then return nil end
    return LibDeflate:EncodeForPrint(compressed)
end

local function TryDecode(encoded, decodeFn)
    if not decodeFn then return nil end
    local compressed = decodeFn(LibDeflate, encoded)
    if not compressed then return nil end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return nil end
    local ok, pkt = LibSerialize:Deserialize(serialized)
    if not ok or type(pkt) ~= "table" then return nil end
    return pkt
end

local function DecodePacket(encoded)
    if not LibSerialize or not LibDeflate or type(encoded) ~= "string" then return nil end
    return TryDecode(encoded, LibDeflate.DecodeForPrint)
        or TryDecode(encoded, LibDeflate.DecodeForWoWAddonChannel)
end

local SEND_RESULT_NAMES = {
    [0]  = "Success",
    [1]  = "InvalidPrefix",
    [2]  = "InvalidMessage",
    [3]  = "AddonMessageThrottle",
    [4]  = "InvalidChatType",
    [5]  = "NotInGroup",
    [6]  = "TargetRequired",
    [7]  = "InvalidChannel",
    [8]  = "ChannelThrottle",
    [9]  = "GeneralError",
    [10] = "NotInGuild",
    [11] = "AddOnMessageLockdown",
    [12] = "TargetOffline",
}

local function FormatSendResult(res)
    if res == true or res == 0 or res == nil then return "Success" end
    if res == false then return "Failed" end
    return SEND_RESULT_NAMES[res] or ("Error#" .. tostring(res))
end

local function OnChunkSendResult(ctx, didSend, sendResult)
    if didSend then
        stats.sentChunksOk = stats.sentChunksOk + 1
        return
    end
    stats.sentChunksFail = stats.sentChunksFail + 1
    local errDesc = string.format("%s -> %s (%s)",
        tostring(ctx and ctx.transport or "?"),
        tostring(ctx and ctx.target or "channel"),
        FormatSendResult(sendResult))
    stats.lastSendError = errDesc

    local now = time()
    local r = _G.Enum and _G.Enum.SendAddonMessageResult
    local notInGroupCode = r and r.NotInGroup or 5
    local notInGuildCode = r and r.NotInGuild or 10
    if manualSyncAt > 0 and (now - manualSyncAt) <= 15
        and (now - lastSendErrorNoticeAt) >= 10
        and sendResult ~= notInGroupCode and sendResult ~= notInGuildCode
    then
        lastSendErrorNoticeAt = now
        ns.Print("Sync send failed on " .. errDesc)
    end
end

local function DispatchRawChunk(transport, target, chunk, prio)
    local sendPrio = (prio == "ALERT" or prio == "NORMAL" or prio == "BULK") and prio or "BULK"
    if Guard.InCommLockdown() then
        if #deferredQueue < MAX_DEFERRED_CHUNKS then
            deferredQueue[#deferredQueue + 1] = { transport = transport, target = target, chunk = chunk, prio = sendPrio }
        end
        return false
    end

    local queueName = ns.COMM_PREFIX .. ":" .. tostring(transport) .. ":" .. tostring(target or "")
    local ctx = { transport = transport, target = target }

    if transport == "BNET" then
        if CTL and CTL.BNSendGameData then
            CTL:BNSendGameData(sendPrio, ns.COMM_PREFIX, chunk, "WHISPER", target, queueName, OnChunkSendResult, ctx)
            return true
        elseif _G.C_BattleNet and _G.C_BattleNet.SendGameData then
            local ok, res = pcall(_G.C_BattleNet.SendGameData, target, ns.COMM_PREFIX, chunk)
            local didSend = ok and (res == nil or res == true or res == 0)
            OnChunkSendResult(ctx, didSend, ok and res or false)
            return didSend
        elseif _G.BNSendGameData then
            local ok, res = pcall(_G.BNSendGameData, target, ns.COMM_PREFIX, chunk)
            local didSend = ok and (res == nil or res == true or res == 0)
            OnChunkSendResult(ctx, didSend, ok and res or false)
            return didSend
        end
        return false
    end

    if CTL and CTL.SendAddonMessage then
        CTL:SendAddonMessage(sendPrio, ns.COMM_PREFIX, chunk, transport, target, queueName, OnChunkSendResult, ctx)
        return true
    elseif _G.C_ChatInfo and _G.C_ChatInfo.SendAddonMessage then
        local ok, res = pcall(_G.C_ChatInfo.SendAddonMessage, ns.COMM_PREFIX, chunk, transport, target)
        local didSend = ok and (res == nil or res == true or res == 0)
        OnChunkSendResult(ctx, didSend, ok and res or false)
        return didSend
    end
    return false
end

local function SendPacket(transport, target, pkt)
    local s = DB:Settings()
    if not s.syncEnabled then return false end

    if Guard.InCommLockdown() and pkt and pkt.t == "H" then
        deferredHelloPending = true
        return true
    end

    local encoded = EncodePacket(pkt)
    if not encoded then return false end

    local prio = (pkt and pkt.t == "H") and "NORMAL" or "BULK"

    if #encoded <= CHUNK_LIMIT then
        DispatchRawChunk(transport, target, "S|" .. encoded, prio)
        if pkt and pkt.t == "H" then
            stats.sentHello = stats.sentHello + 1
        elseif pkt and pkt.t == "D" then
            stats.sentDelta = stats.sentDelta + 1
        end
        return true
    end

    local total = math.ceil(#encoded / CHUNK_LIMIT)
    if total > MAX_CHUNKS then return false end
    local id = NextMsgID()
    for i = 1, total do
        local startIdx = (i - 1) * CHUNK_LIMIT + 1
        local slice = encoded:sub(startIdx, startIdx + CHUNK_LIMIT - 1)
        local frame = string.format("M|%s|%d/%d|%s", id, i, total, slice)
        DispatchRawChunk(transport, target, frame, prio)
    end
    if pkt and pkt.t == "H" then
        stats.sentHello = stats.sentHello + 1
    elseif pkt and pkt.t == "D" then
        stats.sentDelta = stats.sentDelta + 1
    end
    return true
end

local function BuildVersionVector()
    local root = DB:Root()
    local vec = {}
    if not root then return vec end
    vec[root.authorID] = root.revision or 0
    for aid, peer in pairs(root.peers) do
        if type(peer) == "table" and not DB:IsPeerMuted(aid) then
            vec[aid] = tonumber(peer.lastRev) or 0
        end
    end
    return vec
end

local function BuildHelloPacket()
    local root = DB:Root()
    if not root then return nil end
    return {
        t = "H",
        v = ns.PROTOCOL_V,
        ver = ns.VERSION,
        a = root.authorID,
        l = root.authorLabel,
        r = root.revision or 0,
        vec = BuildVersionVector(),
    }
end

local function BuildPersonalDelta(afterRev)
    local root = DB:Root()
    if not root then return nil end
    local s = DB:Settings()
    local items = {}
    local maxRev = afterRev
    local minRev = nil

    for _, e in pairs(root.personal) do
        if type(e) == "table" and (tonumber(e.rev) or 0) > afterRev then
            local isRetracted = (e.share == false and e.retracted == true)
            local isTombstone = (e.deleted == true) or isRetracted
            local canShare = (e.share ~= false) or isTombstone
            if canShare and (e.listType ~= ns.LIST_GREEN or s.syncGreenEntries or isTombstone) then
                if isRetracted and not e.deleted then
                    items[#items + 1] = {
                        key        = e.key,
                        name       = e.name,
                        rev        = e.rev,
                        deleted    = true,
                        listType   = e.listType,
                        sharedNote = "",
                        context    = "",
                        updatedAt  = e.updatedAt,
                    }
                else
                    items[#items + 1] = {
                        key        = e.key,
                        name       = e.name,
                        guid       = e.guid,
                        class      = e.class,
                        listType   = e.listType,
                        category   = e.category,
                        severity   = e.severity,
                        sharedNote = e.deleted and "" or (e.sharedNote or ""),
                        context    = e.deleted and "" or (e.context or ""),
                        createdAt  = e.createdAt,
                        updatedAt  = e.updatedAt,
                        rev        = e.rev,
                        deleted    = e.deleted == true,
                    }
                end
                if not minRev or e.rev < minRev then minRev = e.rev end
                if e.rev > maxRev then maxRev = e.rev end
            end
        end
    end

    if #items == 0 and (root.revision or 0) <= afterRev then
        return nil
    end

    table.sort(items, function(a, b)
        local ra, rb = tonumber(a.rev) or 0, tonumber(b.rev) or 0
        if ra ~= rb then return ra < rb end
        return tostring(a.key or "") < tostring(b.key or "")
    end)

    return {
        t = "D",
        v = ns.PROTOCOL_V,
        s = root.authorID,
        a = root.authorID,
        l = root.authorLabel,
        fromRev = afterRev,
        toRev = math.max(maxRev, root.revision or 0),
        items = items,
    }
end

local function BuildRelayDelta(authorID, afterRev)
    local root = DB:Root()
    if not root or not authorID or authorID == root.authorID then return nil end
    local peer = root.peers[authorID]
    if not peer or type(peer.entries) ~= "table" then return nil end
    local trust = DB:GetPeerTrust(authorID)
    if trust.muted or trust.relay == false then return nil end

    local items = {}
    local maxRev = tonumber(peer.lastRev) or 0
    if maxRev <= afterRev then return nil end

    for _, e in pairs(peer.entries) do
        if type(e) == "table" and (tonumber(e.rev) or 0) > afterRev then
            items[#items + 1] = {
                key        = e.key,
                name       = e.name,
                guid       = e.guid,
                class      = e.class,
                listType   = e.listType,
                category   = e.category,
                severity   = e.severity,
                sharedNote = e.deleted and "" or (e.sharedNote or ""),
                context    = e.deleted and "" or (e.context or ""),
                createdAt  = e.createdAt,
                updatedAt  = e.updatedAt,
                rev        = e.rev,
                deleted    = e.deleted == true,
            }
        end
    end

    if #items == 0 then return nil end

    table.sort(items, function(a, b)
        local ra, rb = tonumber(a.rev) or 0, tonumber(b.rev) or 0
        if ra ~= rb then return ra < rb end
        return tostring(a.key or "") < tostring(b.key or "")
    end)

    return {
        t = "D",
        v = ns.PROTOCOL_V,
        s = root.authorID,
        a = authorID,
        l = peer.authorLabel or authorID,
        fromRev = afterRev,
        toRev = maxRev,
        items = items,
    }
end

-- Send deltas in manageable batches so packets compress cleanly; recursively split if a batch exceeds MAX_CHUNKS
local function SendBatchedSlice(transport, target, deltaPkt, items, startIdx, endIdx, sliceFromRev, isFinal)
    local count = endIdx - startIdx + 1
    if count <= 0 then return end
    local slice = {}
    for j = startIdx, endIdx do
        slice[#slice + 1] = items[j]
    end
    local sliceToRev = isFinal and deltaPkt.toRev or (tonumber(items[endIdx].rev) or sliceFromRev)
    local pkt = {
        t = "D",
        v = deltaPkt.v,
        s = deltaPkt.s,
        a = deltaPkt.a,
        l = deltaPkt.l,
        fromRev = sliceFromRev,
        toRev = sliceToRev,
        items = slice,
    }
    if not SendPacket(transport, target, pkt) and count > 1 then
        local mid = startIdx + math.floor(count / 2) - 1
        local midRev = tonumber(items[mid].rev) or sliceFromRev
        SendBatchedSlice(transport, target, deltaPkt, items, startIdx, mid, sliceFromRev, false)
        SendBatchedSlice(transport, target, deltaPkt, items, mid + 1, endIdx, midRev, isFinal)
    end
end

local function SendBatchedDelta(transport, target, deltaPkt)
    if not deltaPkt or not DB:Settings().syncEnabled then return end
    if not LibSerialize or not LibDeflate then return end
    local items = deltaPkt.items or {}
    if #items <= 25 then
        if not SendPacket(transport, target, deltaPkt) and #items > 1 then
            local mid = math.floor(#items / 2)
            local midRev = tonumber(items[mid].rev) or deltaPkt.fromRev
            SendBatchedSlice(transport, target, deltaPkt, items, 1, mid, deltaPkt.fromRev, false)
            SendBatchedSlice(transport, target, deltaPkt, items, mid + 1, #items, midRev, true)
        end
        return
    end
    local idx = 1
    local curFromRev = deltaPkt.fromRev
    while idx <= #items do
        local lastIdx = math.min(#items, idx + 24)
        local isFinal = (lastIdx == #items)
        SendBatchedSlice(transport, target, deltaPkt, items, idx, lastIdx, curFromRev, isFinal)
        curFromRev = tonumber(items[lastIdx].rev) or curFromRev
        idx = lastIdx + 1
    end
end

function Sync:CollectBNetWoWAccounts()
    local targets = {}
    if not _G.BNGetNumFriends or not _G.C_BattleNet then return targets end
    if _G.BNConnected then
        local okConn, connected = pcall(_G.BNConnected)
        if okConn and Guard.SafeBool(connected) == false then
            return targets
        end
    end
    local ok, total = pcall(_G.BNGetNumFriends)
    total = ok and Guard.SafeNumber(total) or nil
    if not total or total <= 0 then return targets end

    local seenGid = {}
    local wowClient = _G.BNET_CLIENT_WOW or "WoW"

    local function ConsiderGameAccount(acc, ga)
        if not Guard.CanReadTable(ga) then return end
        local isOnline = Guard.SafeBool(ga.isOnline)
        local clientProgram = Guard.SafeString(ga.clientProgram)
        local inRegion = Guard.SafeBool(ga.isInCurrentRegion)
        local wowProj = Guard.SafeNumber(ga.wowProjectID)
        local gid = Guard.SafeNumber(ga.gameAccountID)
        if isOnline ~= true or clientProgram ~= wowClient or inRegion == false or not gid or seenGid[gid] then
            return
        end
        local sameProject = (not _G.WOW_PROJECT_ID) or (not wowProj) or (wowProj == _G.WOW_PROJECT_ID)
        if not sameProject then return end

        seenGid[gid] = true
        local charName = Guard.SafeString(ga.characterName)
        local realmName = Guard.SafeString(ga.realmName)
        local charLabel = charName
        if charLabel and realmName and not Guard.IsForever() then
            charLabel = charLabel .. "-" .. (Guard.NormalizeRealm(realmName) or realmName)
        end
        local btag = acc and Guard.SafeString(acc.battleTag) or nil
        targets[#targets + 1] = {
            gameAccountID = gid,
            battleTag = btag,
            label = btag or charLabel or ("BNet#" .. tostring(gid)),
        }
    end

    for i = 1, total do
        local acc
        if _G.C_BattleNet.GetFriendAccountInfo then
            local okAcc, rawAcc = pcall(_G.C_BattleNet.GetFriendAccountInfo, i)
            if okAcc and Guard.CanReadTable(rawAcc) then
                acc = rawAcc
            end
        end
        if acc then
            ConsiderGameAccount(acc, acc.gameAccountInfo)
        end
        if _G.C_BattleNet.GetFriendNumGameAccounts and _G.C_BattleNet.GetFriendGameAccountInfo then
            local okNum, numGame = pcall(_G.C_BattleNet.GetFriendNumGameAccounts, i)
            numGame = okNum and Guard.SafeNumber(numGame) or 0
            for j = 1, numGame do
                local okGa, ga = pcall(_G.C_BattleNet.GetFriendGameAccountInfo, i, j)
                if okGa then
                    ConsiderGameAccount(acc, ga)
                end
            end
        end
    end
    return targets
end

local function RefreshGuildMembers()
    wipe(guildMembers)
    if not (_G.IsInGuild and _G.IsInGuild() and _G.GetNumGuildMembers and _G.GetGuildRosterInfo) then return end
    local total = _G.GetNumGuildMembers() or 0
    for i = 1, total do
        local name = _G.GetGuildRosterInfo(i)
        local key = Guard.NormalizeNameRealm(name)
        if key then guildMembers[key] = true end
    end
end

local function IsTransportAllowed(transport, senderKey)
    local mode = DB:Settings().trustMode or "friends_and_guild"
    if mode == "bnet_only" then
        return transport == "BNET"
    elseif mode == "guild_only" then
        if transport == "GUILD" then return true end
        if transport == "WHISPER" and _G.IsInGuild and _G.IsInGuild() then
            if not next(guildMembers) then
                RefreshGuildMembers()
            end
            if not next(guildMembers) then return true end
            local key = Guard.NormalizeNameRealm(senderKey)
            return key ~= nil and guildMembers[key] == true
        end
        return false
    end
    return true
end

local function ResolveReplyRoute(transport, gameAccountID, whisperTarget)
    if transport == "BNET" then
        return "BNET", gameAccountID
    elseif transport == "GUILD" or transport == "PARTY" or transport == "RAID" or transport == "INSTANCE_CHAT" then
        return transport, nil
    else
        return "WHISPER", whisperTarget
    end
end

local function HandleHello(pkt, transport, senderKey, gameAccountID, senderDisplay)
    local root = DB:Root()
    if not root or type(pkt.a) ~= "string" or pkt.a == "" or pkt.a == root.authorID then return end

    if not IsTransportAllowed(transport, senderKey) then
        return
    end
    local s = DB:Settings()
    stats.recvHello = stats.recvHello + 1

    local peerAuthorID = pkt.a
    local cleanLabel = Guard.SanitizePeerText(pkt.l, 64)
    local peerLabel = (cleanLabel ~= "" and cleanLabel) or senderDisplay or senderKey or peerAuthorID
    local whisperTarget = (type(senderDisplay) == "string" and senderDisplay ~= "") and senderDisplay or senderKey
    onlinePeers[peerAuthorID] = {
        authorID = peerAuthorID,
        authorLabel = peerLabel,
        via = transport,
        target = whisperTarget,
        gameAccountID = gameAccountID,
        lastHelloAt = time(),
        rev = tonumber(pkt.r) or 0,
    }

    -- Ensure peer appears in SavedVariables even before entries exist
    DB:EnsurePeerRecord(peerAuthorID, peerLabel, transport)

    if type(pkt.ver) == "string" and CompareSemver(pkt.ver, ns.VERSION) > 0 then
        NotifyNewerVersionOnce(pkt.ver, nil)
    end

    -- Decide what to send back to the requester.
    -- GUILD replies stay on GUILD (cross-faction safe; WHISPER fails across factions in Retail guilds).
    local replyTransport, replyTarget = ResolveReplyRoute(transport, gameAccountID, whisperTarget)
    local canReplyTarget = (replyTransport ~= "BNET" and replyTransport ~= "WHISPER") or (replyTarget ~= nil)

    local peerVec = type(pkt.vec) == "table" and pkt.vec or {}
    local peerKnownMyRev = tonumber(peerVec[root.authorID]) or 0
    local pendingDeltas = {}
    if (root.revision or 0) > peerKnownMyRev then
        local delta = BuildPersonalDelta(peerKnownMyRev)
        if delta then
            pendingDeltas[#pendingDeltas + 1] = delta
        end
    end

    -- 1-hop trusted relay for other peers
    if s.syncRelay then
        for aid, cachedPeer in pairs(root.peers) do
            if aid ~= root.authorID and aid ~= peerAuthorID and type(cachedPeer) == "table" then
                local theirRev = tonumber(peerVec[aid]) or 0
                if (tonumber(cachedPeer.lastRev) or 0) > theirRev then
                    local relayDelta = BuildRelayDelta(aid, theirRev)
                    if relayDelta then
                        pendingDeltas[#pendingDeltas + 1] = relayDelta
                    end
                end
            end
        end
    end

    local function SendReplies()
        for i = 1, #pendingDeltas do
            SendBatchedDelta(replyTransport, replyTarget, pendingDeltas[i])
        end
    end

    if #pendingDeltas > 0 and canReplyTarget then
        if replyTransport == "GUILD" and _G.C_Timer and _G.C_Timer.After then
            local jitter = 0.15 + math.random() * 0.65
            _G.C_Timer.After(jitter, SendReplies)
        else
            SendReplies()
        end
    end

    -- If peer has newer revisions for us, reply with our own HELLO once so they push back
    local myKnownTheirRev = root.peers[peerAuthorID] and tonumber(root.peers[peerAuthorID].lastRev) or 0
    local now = time()
    local guildHelloReady = (replyTransport ~= "GUILD") or ((now - lastGuildHelloReplyAt) >= 15)
    local peerReplyReady = (now - (helloReplyAt[peerAuthorID] or 0)) >= 15
    if canReplyTarget and (tonumber(pkt.r) or 0) > myKnownTheirRev and peerReplyReady and guildHelloReady then
        helloReplyAt[peerAuthorID] = now
        if replyTransport == "GUILD" then
            lastGuildHelloReplyAt = now
        end
        local hello = BuildHelloPacket()
        if hello then SendPacket(replyTransport, replyTarget, hello) end
    end

    ns:Emit("PEERS_CHANGED")
end

local function HandleDelta(pkt, transport, senderKey, gameAccountID, senderDisplay)
    local root = DB:Root()
    if not root or type(pkt.a) ~= "string" or pkt.a == "" or pkt.a == root.authorID then return end

    if not IsTransportAllowed(transport, senderKey) then
        return
    end
    local s = DB:Settings()
    -- Only accept relayed third-party entries if relay is enabled
    if pkt.s ~= pkt.a and not s.syncRelay then
        return
    end

    stats.recvDelta = stats.recvDelta + 1

    local via = (pkt.s ~= pkt.a) and ("RELAY/" .. transport) or transport
    local applied, hasGap = DB:MergePeerDelta(pkt.a, Guard.SafeString(pkt.l), pkt.items, pkt.toRev, via, pkt.fromRev)

    local peerAuthorID = pkt.a
    local numFrom = tonumber(pkt.fromRev)
    local numTo = tonumber(pkt.toRev)
    local now = time()

    if hasGap and numFrom and numTo and numTo > numFrom then
        local ranges = pendingRevRanges[peerAuthorID]
        if not ranges then
            ranges = {}
            pendingRevRanges[peerAuthorID] = ranges
        end
        if #ranges < 32 then
            ranges[#ranges + 1] = { fromRev = numFrom, toRev = numTo, ts = now }
        end
    end

    local ranges = pendingRevRanges[peerAuthorID]
    if ranges then
        for i = #ranges, 1, -1 do
            if (now - (ranges[i].ts or 0)) > 30 then
                table.remove(ranges, i)
            end
        end
        local progressed = true
        while progressed do
            progressed = false
            local peer = root.peers[peerAuthorID]
            local curLastRev = (type(peer) == "table" and tonumber(peer.lastRev)) or 0
            for i = #ranges, 1, -1 do
                local r = ranges[i]
                if r.fromRev <= curLastRev then
                    if DB:AdvancePeerLastRev(peerAuthorID, r.toRev) then
                        progressed = true
                    end
                    table.remove(ranges, i)
                end
            end
        end
        if #ranges == 0 then
            pendingRevRanges[peerAuthorID] = nil
        else
            local whisperTarget = (type(senderDisplay) == "string" and senderDisplay ~= "") and senderDisplay or senderKey
            local replyTransport, replyTarget = ResolveReplyRoute(transport, gameAccountID, whisperTarget)
            local canReachTarget = (replyTransport ~= "BNET" and replyTransport ~= "WHISPER") or (replyTarget ~= nil)
            local guildReady = (replyTransport ~= "GUILD") or ((now - lastGuildHelloReplyAt) >= 15)
            if canReachTarget and not gapHelloScheduled[peerAuthorID]
                and (now - (lastGapHelloAt[peerAuthorID] or 0)) >= 15 and guildReady
                and _G.C_Timer and _G.C_Timer.After
            then
                gapHelloScheduled[peerAuthorID] = true
                _G.C_Timer.After(2.5, function()
                    gapHelloScheduled[peerAuthorID] = nil
                    if not pendingRevRanges[peerAuthorID] then return end
                    pendingRevRanges[peerAuthorID] = nil
                    local tNow = time()
                    if replyTransport == "GUILD" and (tNow - lastGuildHelloReplyAt) < 15 then return end
                    lastGapHelloAt[peerAuthorID] = tNow
                    if replyTransport == "GUILD" then
                        lastGuildHelloReplyAt = tNow
                    end
                    local hello = BuildHelloPacket()
                    if hello then
                        SendPacket(replyTransport, replyTarget, hello)
                    end
                end)
            end
        end
    end

    if applied > 0 and manualSyncAt > 0 and (now - manualSyncAt) <= 15 then
        local cleanName = Guard.SanitizePeerText(pkt.l, 64)
        local displayLabel = (cleanName ~= "" and cleanName) or peerAuthorID
        ns.Print(string.format("Synced %d %s from %s.", applied, applied == 1 and "entry" or "entries", displayLabel))
    end
end

local function CleanupBuffers()
    local now = time()
    for k, buf in pairs(inboundBuffers) do
        if (now - (buf.ts or 0)) > 30 then
            inboundBuffers[k] = nil
        end
    end
end

local function OnIncomingRaw(transport, senderKey, gameAccountID, rawText, senderDisplay)
    if type(rawText) ~= "string" or Guard.IsSecret(rawText) then return end

    local s = DB:Settings()
    if not s.syncEnabled then return end

    local encoded = nil
    local tag = rawText:sub(1, 2)
    if tag == "S|" then
        encoded = rawText:sub(3)
    elseif tag == "M|" then
        local msgID, idxStr, totalStr, chunk = rawText:match("^M|([^|]+)|(%d+)/(%d+)|(.*)$")
        local idx, total = tonumber(idxStr), tonumber(totalStr)
        if not msgID or not idx or not total or total < 1 or total > MAX_CHUNKS or idx < 1 or idx > total then
            return
        end
        CleanupBuffers()
        local bufKey = transport .. ":" .. tostring(senderKey or gameAccountID) .. ":" .. msgID
        local buf = inboundBuffers[bufKey]
        if not buf or buf.total ~= total then
            buf = { total = total, received = 0, parts = {}, ts = time() }
            inboundBuffers[bufKey] = buf
        end
        if not buf.parts[idx] then
            buf.parts[idx] = chunk
            buf.received = buf.received + 1
            buf.ts = time()
        end
        if buf.received >= buf.total then
            inboundBuffers[bufKey] = nil
            for p = 1, buf.total do
                if type(buf.parts[p]) ~= "string" then
                    return
                end
            end
            encoded = table.concat(buf.parts)
        end
    end

    if not encoded then return end
    local pkt = DecodePacket(encoded)
    if not pkt then
        stats.recvDecodeFail = stats.recvDecodeFail + 1
        return
    end
    if type(pkt.v) == "number" and pkt.v > ns.PROTOCOL_V then
        NotifyNewerVersionOnce(pkt.ver, pkt.v)
        return
    end
    if pkt.v ~= ns.PROTOCOL_V then return end

    if pkt.t == "H" then
        HandleHello(pkt, transport, senderKey, gameAccountID, senderDisplay)
    elseif pkt.t == "D" then
        HandleDelta(pkt, transport, senderKey, gameAccountID, senderDisplay)
    end
end

function Sync:FlushDeferredQueue()
    if Guard.InCommLockdown() then return end
    if #deferredQueue > 0 then
        local copy = {}
        for i = 1, #deferredQueue do copy[i] = deferredQueue[i] end
        wipe(deferredQueue)
        for i = 1, #copy do
            local item = copy[i]
            DispatchRawChunk(item.transport, item.target, item.chunk, item.prio)
        end
    end
    if deferredHelloPending then
        deferredHelloPending = false
        self:BroadcastHello(false)
    end
end

function Sync:GetDeferredCount()
    return #deferredQueue + (deferredHelloPending and 1 or 0)
end

function Sync:GetOnlinePeers()
    return onlinePeers
end

function Sync:GetOnlinePeerCount()
    local count = 0
    for _ in pairs(onlinePeers) do
        count = count + 1
    end
    return count
end

function Sync:BroadcastHello(force)
    local s = DB:Settings()
    if not s.syncEnabled then
        return { ok = false, reason = "disabled" }
    end
    if Guard.InCommLockdown() then
        deferredHelloPending = true
        return { ok = false, reason = "lockdown", deferred = true }
    end

    local hello = BuildHelloPacket()
    if not hello then
        return { ok = false, reason = "not_initialized" }
    end

    local status = {
        ok = true,
        guild = false,
        party = false,
        partyChannel = nil,
        bnetCount = 0,
        bnetSkippedCooldown = 0,
    }

    if s.syncGuild and IsTransportAllowed("GUILD") and _G.IsInGuild and _G.IsInGuild() then
        if SendPacket("GUILD", nil, hello) then
            status.guild = true
        end
    end

    if s.syncParty and IsTransportAllowed("PARTY") and _G.IsInGroup and _G.IsInGroup() then
        local chan = (_G.IsInGroup(_G.LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT")
            or ((_G.IsInRaid and _G.IsInRaid()) and "RAID" or "PARTY")
        if SendPacket(chan, nil, hello) then
            status.party = true
            status.partyChannel = chan
        end
    end

    if s.syncBNet and IsTransportAllowed("BNET") then
        local now = time()
        local accounts = self:CollectBNetWoWAccounts()
        for i = 1, #accounts do
            local gid = accounts[i].gameAccountID
            local last = bnetKnownSent[gid] or 0
            if force or (now - last) >= HANDSHAKE_COOLDOWN then
                bnetKnownSent[gid] = now
                if SendPacket("BNET", gid, hello) then
                    status.bnetCount = status.bnetCount + 1
                end
            else
                status.bnetSkippedCooldown = status.bnetSkippedCooldown + 1
            end
        end
    end

    return status
end

function Sync:PushPersonalUpdate()
    local s = DB:Settings()
    if not s.syncEnabled then return end
    local root = DB:Root()
    if not root then return end

    -- Push latest delta directly to online channels
    local minRev = math.max(0, (root.revision or 1) - 1)
    local delta = BuildPersonalDelta(minRev)
    if not delta then return end

    if s.syncGuild and IsTransportAllowed("GUILD") and _G.IsInGuild and _G.IsInGuild() then
        SendBatchedDelta("GUILD", nil, delta)
    end
    if s.syncParty and IsTransportAllowed("PARTY") and _G.IsInGroup and _G.IsInGroup() then
        local chan = (_G.IsInGroup(_G.LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT")
            or ((_G.IsInRaid and _G.IsInRaid()) and "RAID" or "PARTY")
        SendBatchedDelta(chan, nil, delta)
    end
    if s.syncBNet and IsTransportAllowed("BNET") then
        local accounts = self:CollectBNetWoWAccounts()
        for i = 1, #accounts do
            SendBatchedDelta("BNET", accounts[i].gameAccountID, delta)
        end
    end
end

function Sync:SyncNow()
    manualSyncAt = time()
    wipe(bnetKnownSent)
    local status = self:BroadcastHello(true)
    ns:Emit("PEERS_CHANGED")
    return status
end

function Sync:SyncWithPlayer(rawName)
    local s = DB:Settings()
    if not s.syncEnabled then
        return { ok = false, reason = "disabled" }
    end
    local _, display = Guard.NormalizeNameRealm(rawName)
    if not display then
        return { ok = false, reason = "invalid_target" }
    end
    if Guard.InCommLockdown() then
        return { ok = false, reason = "lockdown" }
    end
    local hello = BuildHelloPacket()
    if not hello then
        return { ok = false, reason = "not_initialized" }
    end
    manualSyncAt = time()
    if SendPacket("WHISPER", display, hello) then
        return { ok = true, whisperTarget = display }
    end
    return { ok = false, reason = "send_failed" }
end

function Sync:FormatSyncStatus(status)
    if type(status) ~= "table" then
        return "Sync handshake could not be sent."
    end
    if not status.ok then
        if status.reason == "disabled" then
            return "In-game sync is disabled in Settings."
        elseif status.reason == "lockdown" then
            if status.deferred then
                return "Messaging lockdown active; sync queued for when combat/encounter ends."
            end
            return "Messaging lockdown active; direct whisper sync cannot send right now."
        elseif status.reason == "invalid_target" then
            local usageTarget = Guard.IsForever() and "PlayerName" or "Player-Realm"
            return "Invalid player name. Usage: /thelist sync " .. usageTarget
        end
        return "Sync handshake could not be sent (" .. tostring(status.reason or "unknown") .. ")."
    end

    if status.whisperTarget then
        return "Direct sync handshake whispered to " .. tostring(status.whisperTarget) .. "."
    end

    local targets = {}
    if status.guild then
        targets[#targets + 1] = "Guild"
    end
    if status.party then
        local ch = status.partyChannel == "RAID" and "Raid"
            or (status.partyChannel == "INSTANCE_CHAT" and "Instance" or "Party")
        targets[#targets + 1] = ch
    end
    if (status.bnetCount or 0) > 0 then
        targets[#targets + 1] = string.format("%d BNet %s", status.bnetCount, status.bnetCount == 1 and "friend" or "friends")
    end

    if #targets == 0 then
        local flavorLabel = Guard.IsForever() and "Forever" or "Retail"
        local usageTarget = Guard.IsForever() and "PlayerName" or "Name-Realm"
        return string.format(
            "Sync handshake had no online targets (0 %s BNet friends, no guild/party channel active). Use /thelist sync %s to sync directly.",
            flavorLabel, usageTarget
        )
    end
    return "Sync handshake sent (" .. table.concat(targets, ", ") .. ")."
end

function Sync:PrintDebugStatus()
    local root = DB:Root()
    local s = DB:Settings()
    local bnConn = "n/a"
    if _G.BNConnected then
        local okConn, conn = pcall(_G.BNConnected)
        if okConn and Guard.SafeBool(conn) ~= nil then
            bnConn = tostring(Guard.SafeBool(conn))
        end
    end
    local accounts = self:CollectBNetWoWAccounts()
    local labels = {}
    for i = 1, math.min(5, #accounts) do
        labels[#labels + 1] = tostring(accounts[i].label)
    end
    if #accounts > 5 then
        labels[#labels + 1] = string.format("+%d more", #accounts - 5)
    end
    local inGuild = (_G.IsInGuild and _G.IsInGuild()) and "yes" or "no"
    local inGroup = (_G.IsInGroup and _G.IsInGroup()) and "yes" or "no"
    local flavorLabel = Guard.IsForever() and "Forever" or "Retail"

    ns.Print(string.format(
        "Sync Debug: prefix=%s (%s), lockdown=%s, enabled=%s, trust=%s, BNet=%s, Guild=%s, Party=%s, Relay=%s, id=%s, rev=%d",
        tostring(stats.prefixRegistered), tostring(stats.prefixResult),
        tostring(Guard.InCommLockdown()), tostring(s.syncEnabled), tostring(s.trustMode),
        tostring(s.syncBNet), tostring(s.syncGuild), tostring(s.syncParty), tostring(s.syncRelay),
        tostring(root and root.authorID), tonumber(root and root.revision) or 0
    ))
    ns.Print(string.format(
        "Targets: BNConnected=%s, %sBNet=%d [%s], inGuild=%s, inGroup=%s, onlinePeers=%d",
        bnConn, flavorLabel, #accounts, table.concat(labels, ", "), inGuild, inGroup, self:GetOnlinePeerCount()
    ))
    ns.Print(string.format(
        "Stats: sent(H=%d, D=%d, ok=%d, fail=%d), recv(H=%d, D=%d, decodeFail=%d), deferred=%d, lastErr=%s",
        stats.sentHello, stats.sentDelta, stats.sentChunksOk, stats.sentChunksFail,
        stats.recvHello, stats.recvDelta, stats.recvDecodeFail,
        self:GetDeferredCount(), tostring(stats.lastSendError or "none")
    ))
end

function Sync:Init()
    if initialized then return end
    initialized = true

    if _G.C_ChatInfo and _G.C_ChatInfo.RegisterAddonMessagePrefix then
        local okReg, regRes = pcall(_G.C_ChatInfo.RegisterAddonMessagePrefix, ns.COMM_PREFIX)
        stats.prefixResult = okReg and regRes or "error"
        stats.prefixRegistered = okReg and (regRes == true or regRes == 0 or regRes == 1)
    end

    commFrame = CreateFrame("Frame")
    Guard.SafeRegisterEvent(commFrame, "CHAT_MSG_ADDON")
    Guard.SafeRegisterEvent(commFrame, "BN_CHAT_MSG_ADDON")
    Guard.SafeRegisterEvent(commFrame, "BN_FRIEND_INFO_CHANGED")
    Guard.SafeRegisterEvent(commFrame, "GROUP_JOINED")
    Guard.SafeRegisterEvent(commFrame, "PLAYER_REGEN_ENABLED")
    Guard.SafeRegisterEvent(commFrame, "ENCOUNTER_END")
    if not Guard.IsForever() then
        Guard.SafeRegisterEvent(commFrame, "CHALLENGE_MODE_COMPLETED")
    end
    Guard.SafeRegisterEvent(commFrame, "GUILD_ROSTER_UPDATE")

    local helloDebounce = false
    local function ScheduleHello()
        if helloDebounce then return end
        helloDebounce = true
        C_Timer.After(2.0, function()
            helloDebounce = false
            Sync:BroadcastHello(false)
        end)
    end

    commFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_ADDON" then
            local prefix, text, channel, sender = ...
            local safePrefix = Guard.SafeString(prefix)
            if safePrefix ~= ns.COMM_PREFIX then return end
            local safeChan = Guard.SafeString(channel)
            if not safeChan then return end
            local safeSender = Guard.SafeString(sender)
            local sKey, sDisplay = Guard.NormalizeNameRealm(safeSender)
            local myKey = Guard.GetPlayerKey()
            if myKey and sKey == myKey then return end
            OnIncomingRaw(safeChan, sKey or safeSender, nil, text, safeSender or sDisplay)
        elseif event == "BN_CHAT_MSG_ADDON" then
            local prefix, text, _, senderGameAccountID = ...
            local safePrefix = Guard.SafeString(prefix)
            if safePrefix ~= ns.COMM_PREFIX then return end
            local safeGid = Guard.SafeNumber(senderGameAccountID)
            if not safeGid then return end
            OnIncomingRaw("BNET", tostring(safeGid), safeGid, text)
        elseif event == "BN_FRIEND_INFO_CHANGED" then
            if DB:Settings().syncEnabled and DB:Settings().syncBNet and IsTransportAllowed("BNET") then
                ScheduleHello()
            end
        elseif event == "GROUP_JOINED" then
            if DB:Settings().syncEnabled and DB:Settings().syncParty and IsTransportAllowed("PARTY") then
                ScheduleHello()
            end
        elseif event == "PLAYER_REGEN_ENABLED" or event == "ENCOUNTER_END" or event == "CHALLENGE_MODE_COMPLETED" then
            C_Timer.After(0.5, function() Sync:FlushDeferredQueue() end)
        elseif event == "GUILD_ROSTER_UPDATE" then
            RefreshGuildMembers()
            if DB:Settings().syncEnabled and DB:Settings().syncGuild and IsTransportAllowed("GUILD") then
                ScheduleHello()
            end
        end
    end)

    ns:On("DB_CHANGED", function(kind)
        if kind == "personal" or kind == "personal_remove" then
            Sync:PushPersonalUpdate()
        elseif kind == "personal_import" then
            Sync:BroadcastHello(true)
        end
    end)

    if DB:Settings().autoSyncOnLogin then
        C_Timer.After(3.5, function()
            Sync:BroadcastHello(true)
        end)
    end
end
