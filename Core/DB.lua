local _, ns = ...

local DB = {}
ns.DB = DB

local Guard = ns.Guard

local guidIndex = {}     -- guid -> { [canonicalKey] = true }
local guidIndexDirty = true

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function GenerateAuthorID()
    local guid = _G.UnitGUID and _G.UnitGUID("player")
    if guid and not Guard.IsSecret(guid) and guid ~= "" then
        local clean = guid:gsub("[^%w]", "")
        return "TL_" .. clean:sub(-10) .. "_" .. string.format("%x", time() % 65535)
    end
    return "TL_" .. string.format("%x%x", time(), math.random(1000, 9999))
end

function DB:RefreshMyLabel()
    if not _G.TheListDB then return end
    local info = Guard.SafeUnitInfo("player")
    if info and info.name then
        _G.TheListDB.authorLabel = info.name
    end
end

function DB:Init()
    if type(_G.TheListDB) ~= "table" then
        _G.TheListDB = {}
    end
    local root = _G.TheListDB
    local hadExistingDB = (root.schemaVersion ~= nil) or (type(root.settings) == "table" and next(root.settings) ~= nil)
    root.schemaVersion = tonumber(root.schemaVersion) or (hadExistingDB and 1 or 3)
    if type(root.authorID) ~= "string" or root.authorID == "" then
        root.authorID = GenerateAuthorID()
    end
    root.revision = tonumber(root.revision) or 0
    if type(root.personal) ~= "table" then root.personal = {} end
    if type(root.peers) ~= "table" then root.peers = {} end
    if type(root.peerTrust) ~= "table" then root.peerTrust = {} end
    if type(root.dismissedPeerEntries) ~= "table" then root.dismissedPeerEntries = {} end
    if type(root.recent) ~= "table" then root.recent = {} end
    if type(root.settings) ~= "table" then root.settings = {} end

    CopyDefaults(ns.DEFAULTS.settings, root.settings)
    if root.schemaVersion < 2 then
        if root.settings.greenSound == "eui_kaching" then
            root.settings.greenSound = "none"
        end
        if root.settings.blackSound == "thelist_add" then
            root.settings.blackSound = "eui_siren"
        end
        root.schemaVersion = 2
    end
    if root.schemaVersion < 3 then
        root.settings.syncRelay = false
        root.settings.trustMode = nil
        root.schemaVersion = 3
    end
    self:RefreshMyLabel()
    self:PruneOldTombstones()
    guidIndexDirty = true
    return root
end

function DB:Root()
    return _G.TheListDB
end

function DB:Settings()
    return _G.TheListDB and _G.TheListDB.settings or ns.DEFAULTS.settings
end

function DB:ResetSettings()
    if not _G.TheListDB then return end
    _G.TheListDB.settings = {}
    CopyDefaults(ns.DEFAULTS.settings, _G.TheListDB.settings)
    _G.TheListDB.bannerPos = nil
    ns:Emit("SETTINGS_CHANGED")
end

local function IndexGuid(guid, key)
    if type(guid) ~= "string" or guid == "" then return end
    if not guidIndex[guid] then guidIndex[guid] = {} end
    guidIndex[guid][key] = true
end

local function RebuildGuidIndex()
    wipe(guidIndex)
    local root = _G.TheListDB
    if not root then
        guidIndexDirty = false
        return
    end
    for key, e in pairs(root.personal) do
        if type(e) == "table" and not e.deleted and e.guid then
            IndexGuid(e.guid, key)
        end
    end
    for aid, peer in pairs(root.peers) do
        if type(peer) == "table" and not DB:IsPeerMuted(aid) and type(peer.entries) == "table" then
            for key, e in pairs(peer.entries) do
                if type(e) == "table" and not e.deleted and e.guid and not DB:IsPeerEntryDismissed(aid, key) then
                    IndexGuid(e.guid, key)
                end
            end
        end
    end
    guidIndexDirty = false
end

local function EnsureGuidIndex()
    if guidIndexDirty then RebuildGuidIndex() end
end

function DB:IsPeerMuted(authorID)
    local root = _G.TheListDB
    if not root or not authorID then return false end
    local trust = root.peerTrust[authorID]
    return trust and trust.muted == true or false
end

function DB:IsPeerEntryDismissed(authorID, key)
    local root = _G.TheListDB
    if not root or not authorID or not key then return false end
    local map = root.dismissedPeerEntries and root.dismissedPeerEntries[authorID]
    return type(map) == "table" and map[key] ~= nil
end

function DB:DismissPeerEntry(authorID, key)
    local root = _G.TheListDB
    if not root or type(authorID) ~= "string" or authorID == "" or type(key) ~= "string" or key == "" then
        return false
    end
    if type(root.dismissedPeerEntries) ~= "table" then
        root.dismissedPeerEntries = {}
    end
    if type(root.dismissedPeerEntries[authorID]) ~= "table" then
        root.dismissedPeerEntries[authorID] = {}
    end
    root.dismissedPeerEntries[authorID][key] = time()
    guidIndexDirty = true
    ns:Emit("DB_CHANGED", "peer_dismiss", key)
    return true
end

function DB:DismissPeerEntries(authorIDs, key)
    local root = _G.TheListDB
    if not root or type(authorIDs) ~= "table" or type(key) ~= "string" or key == "" then
        return 0
    end
    if type(root.dismissedPeerEntries) ~= "table" then
        root.dismissedPeerEntries = {}
    end
    local now = time()
    local count = 0
    for i = 1, #authorIDs do
        local aid = authorIDs[i]
        if type(aid) == "string" and aid ~= "" then
            if type(root.dismissedPeerEntries[aid]) ~= "table" then
                root.dismissedPeerEntries[aid] = {}
            end
            if root.dismissedPeerEntries[aid][key] == nil then
                count = count + 1
            end
            root.dismissedPeerEntries[aid][key] = now
        end
    end
    if count > 0 then
        guidIndexDirty = true
        ns:Emit("DB_CHANGED", "peer_dismiss", key)
    end
    return count
end

function DB:UndismissPeerEntry(authorID, key)
    local root = _G.TheListDB
    if not root or not authorID or not key or type(root.dismissedPeerEntries) ~= "table" then
        return false
    end
    local map = root.dismissedPeerEntries[authorID]
    if type(map) ~= "table" or map[key] == nil then
        return false
    end
    map[key] = nil
    if next(map) == nil then
        root.dismissedPeerEntries[authorID] = nil
    end
    guidIndexDirty = true
    ns:Emit("DB_CHANGED", "peer_dismiss", key)
    return true
end

function DB:ClearDismissedForPeer(authorID)
    local root = _G.TheListDB
    if not root or not authorID or type(root.dismissedPeerEntries) ~= "table" then
        return false
    end
    if root.dismissedPeerEntries[authorID] == nil then
        return false
    end
    root.dismissedPeerEntries[authorID] = nil
    guidIndexDirty = true
    ns:Emit("DB_CHANGED", "peer_dismiss", authorID)
    ns:Emit("PEERS_CHANGED")
    return true
end

function DB:GetDismissedCount(authorID)
    local root = _G.TheListDB
    if not root or not authorID or type(root.dismissedPeerEntries) ~= "table" then
        return 0
    end
    local map = root.dismissedPeerEntries[authorID]
    if type(map) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(map) do
        n = n + 1
    end
    return n
end

function DB:SetPeerTrust(authorID, field, val, label)
    local root = _G.TheListDB
    if not root or not authorID then return end
    if not root.peerTrust[authorID] then
        root.peerTrust[authorID] = { muted = false, receive = true, relay = true }
    end
    local t = root.peerTrust[authorID]
    t[field] = val
    if label then t.label = label end
    if field == "muted" then
        guidIndexDirty = true
    end
    ns:Emit("PEERS_CHANGED")
end

function DB:GetPeerTrust(authorID)
    local root = _G.TheListDB
    if not root or not authorID then return { muted = false, receive = true, relay = true } end
    if not root.peerTrust[authorID] then
        root.peerTrust[authorID] = { muted = false, receive = true, relay = true }
    end
    return root.peerTrust[authorID]
end

function DB:AddOrUpdatePersonal(opts)
    local root = _G.TheListDB
    if not root or type(opts) ~= "table" then return nil, "Not initialized" end
    local key, display = Guard.NormalizeNameRealm(opts.name)
    if not key then return nil, "Invalid player name" end

    local now = time()
    local existing = root.personal[key]
    local isNew = (existing == nil or existing.deleted == true)
    local wasActiveBad = existing and not existing.deleted and existing.listType == ns.LIST_BLACK
    local wasNativeIgnored = existing and not existing.deleted and existing.nativeIgnore == true
    local wasShared = existing and not existing.deleted and existing.share ~= false
    root.revision = (tonumber(root.revision) or 0) + 1

    local listType = (opts.listType == ns.LIST_GREEN) and ns.LIST_GREEN or ns.LIST_BLACK
    local defaultCat = (listType == ns.LIST_GREEN) and "Reliable" or "Leaver"

    local entry = existing or {}
    entry.key         = key
    entry.name        = display
    entry.guid        = Guard.SafeString(opts.guid) or entry.guid
    entry.class       = Guard.SafeString(opts.class) or entry.class
    entry.listType    = listType
    entry.category    = Guard.SafeString(opts.category) or entry.category or defaultCat
    entry.severity    = math.max(1, math.min(3, tonumber(opts.severity) or entry.severity or 2))
    entry.sharedNote  = (opts.sharedNote ~= nil) and tostring(opts.sharedNote) or (entry.sharedNote or "")
    entry.privateNote = (opts.privateNote ~= nil) and tostring(opts.privateNote) or (entry.privateNote or "")
    if opts.share ~= nil then
        entry.share = (opts.share == true)
    else
        entry.share = (entry.share ~= false)
    end
    if opts.context ~= nil and not Guard.IsSecret(opts.context) then
        local ctxStr = tostring(opts.context)
        if ctxStr ~= "" then
            entry.context = ctxStr
        else
            entry.context = entry.context or ""
        end
    else
        entry.context = entry.context or ""
    end

    local wantIgnore = false
    if entry.listType == ns.LIST_BLACK then
        if opts.nativeIgnore ~= nil then
            wantIgnore = (opts.nativeIgnore == true) or (self:Settings().autoNativeIgnore == true)
        else
            wantIgnore = wasNativeIgnored or (self:Settings().autoNativeIgnore == true)
        end
    end
    entry.nativeIgnore = wantIgnore

    if wasShared and entry.share == false then
        entry.retracted = true
    elseif entry.share == true then
        entry.retracted = nil
    end

    entry.createdAt   = isNew and now or (entry.createdAt or now)
    entry.updatedAt   = now
    entry.rev         = root.revision
    entry.deleted     = false

    root.personal[key] = entry
    guidIndexDirty = true

    if wantIgnore then
        self:ApplyNativeIgnore(display, true)
    elseif wasNativeIgnored then
        self:ApplyNativeIgnore(display, false)
    end

    if entry.listType == ns.LIST_BLACK and not wasActiveBad then
        Guard.PlayAlertSound(self:Settings().addBadSound)
    end

    ns:Emit("DB_CHANGED", "personal", key, entry)
    return entry
end

function DB:RemovePersonal(rawNameOrKey)
    local root = _G.TheListDB
    if not root then return false end
    local key = Guard.NormalizeNameRealm(rawNameOrKey)
    if not key then return false end
    local entry = root.personal[key]
    if not entry or entry.deleted then return false end

    root.revision = (tonumber(root.revision) or 0) + 1
    entry.deleted = true
    entry.updatedAt = time()
    entry.rev = root.revision
    -- Clear notes from deleted tombstones so sync stays tiny
    entry.sharedNote = ""
    entry.privateNote = ""
    guidIndexDirty = true

    if entry.nativeIgnore then
        self:ApplyNativeIgnore(entry.name, false)
        entry.nativeIgnore = false
    end

    ns:Emit("DB_CHANGED", "personal_remove", key, entry)
    return true
end

function DB:AdoptPeerEntry(entry, opts)
    if type(entry) ~= "table" then return nil, "Invalid entry" end
    local o = opts or {}
    return self:AddOrUpdatePersonal({
        name = entry.name or entry.key,
        guid = entry.guid or o.guid,
        class = entry.class or o.class,
        listType = entry.listType or o.listType or ns.LIST_BLACK,
        category = entry.category,
        severity = entry.severity,
        sharedNote = entry.sharedNote or "",
        context = entry.context or "",
        share = false,
    })
end

function DB:ApplyNativeIgnore(nameRealm, shouldIgnore)
    if not _G.C_FriendList then return false end
    local _, display = Guard.NormalizeNameRealm(nameRealm)
    if not display then return false end
    if shouldIgnore then
        if _G.C_FriendList.AddIgnore then
            local ok = pcall(_G.C_FriendList.AddIgnore, display)
            return ok
        end
    else
        if _G.C_FriendList.DelIgnore then
            local ok = pcall(_G.C_FriendList.DelIgnore, display)
            return ok
        end
    end
    return false
end

function DB:ToggleNativeIgnore(key)
    local root = _G.TheListDB
    local entry = root and root.personal and root.personal[key]
    if not entry or entry.deleted then return false end
    local target = not entry.nativeIgnore
    entry.nativeIgnore = target
    self:ApplyNativeIgnore(entry.name, target)
    ns:Emit("DB_CHANGED", "personal_local", key, entry)
    return target
end

function DB:AttachGuid(rawName, guid, classToken)
    local root = _G.TheListDB
    if not root then return end
    local key = Guard.NormalizeNameRealm(rawName)
    local safeGuid = Guard.SafeString(guid)
    if not key or not safeGuid then return end

    local changed = false
    local p = root.personal[key]
    if p and not p.deleted then
        if p.guid ~= safeGuid then
            p.guid = safeGuid
            changed = true
        end
        if classToken and not p.class then
            p.class = classToken
            changed = true
        end
    end
    for _, peer in pairs(root.peers) do
        if type(peer) == "table" and type(peer.entries) == "table" then
            local pe = peer.entries[key]
            if pe and not pe.deleted then
                if pe.guid ~= safeGuid then
                    pe.guid = safeGuid
                    changed = true
                end
                if classToken and not pe.class then
                    pe.class = classToken
                    changed = true
                end
            end
        end
    end
    if changed then guidIndexDirty = true end
end

local MAX_PEER_ENTRIES = 1000
local MAX_PEERS = 150
local MAX_DELTA_ITEMS = 100

local function IsFiniteRev(n)
    return type(n) == "number" and n == n and n >= 0 and n < 1e12
end

function DB:EnsurePeerRecord(authorID, authorLabel, via)
    local root = _G.TheListDB
    if not root or type(authorID) ~= "string" or authorID == "" or #authorID > 64 or authorID == root.authorID then
        return nil
    end
    local trust = self:GetPeerTrust(authorID)
    if trust.receive == false then return nil end

    local cleanLabel = Guard.SanitizePeerText(authorLabel, 64)
    local peer = root.peers[authorID]
    if not peer then
        local peerCount = 0
        for _ in pairs(root.peers) do
            peerCount = peerCount + 1
        end
        if peerCount >= MAX_PEERS then
            return nil
        end
        peer = {
            authorID = authorID,
            authorLabel = (cleanLabel ~= "" and cleanLabel) or authorID,
            lastRev = 0,
            lastSeenAt = time(),
            via = via or "SYNC",
            entries = {},
        }
        root.peers[authorID] = peer
    end
    if cleanLabel ~= "" then
        peer.authorLabel = cleanLabel
        trust.label = cleanLabel
    end
    peer.lastSeenAt = time()
    peer.via = via or peer.via
    return peer
end

function DB:AdvancePeerLastRev(authorID, newLastRev)
    local root = _G.TheListDB
    if not root or type(authorID) ~= "string" or authorID == "" then return false end
    local peer = root.peers[authorID]
    local targetRev = tonumber(newLastRev)
    if type(peer) ~= "table" or not IsFiniteRev(targetRev) then return false end
    local cur = tonumber(peer.lastRev) or 0
    if targetRev > cur then
        peer.lastRev = targetRev
        return true
    end
    return false
end

function DB:MergePeerDelta(authorID, authorLabel, items, toRev, via, fromRev)
    local peer = self:EnsurePeerRecord(authorID, authorLabel, via)
    if not peer then
        return 0, false
    end

    local applied = 0
    if type(items) == "table" then
        local activeCount = 0
        for _, pe in pairs(peer.entries) do
            if type(pe) == "table" and not pe.deleted then
                activeCount = activeCount + 1
            end
        end

        local limit = math.min(#items, MAX_DELTA_ITEMS)
        for i = 1, limit do
            local item = items[i]
            if type(item) == "table" then
                local rawKey = Guard.SanitizePeerText(item.key or item.name, 64)
                local itemKey, keyDisplay, _, keyRealm = Guard.NormalizeNameRealm(rawKey)
                local rawRev = Guard.SafeNumber(item.rev) or tonumber(item.rev)
                local itemRev = (rawRev ~= nil) and rawRev or 0
                if itemKey and IsFiniteRev(itemRev) then
                    local cur = peer.entries[itemKey]
                    local isDeleted = (item.deleted == true)
                    local isNewActive = (not cur or cur.deleted) and not isDeleted
                    if (not cur or itemRev > (tonumber(cur.rev) or 0)) and (not isNewActive or activeCount < MAX_PEER_ENTRIES) then
                        local cleanName = Guard.SanitizePeerText(item.name, 64)
                        local nameKey, nameDisplay = Guard.NormalizeNameRealm(cleanName, keyRealm)
                        local displayName = (nameKey == itemKey and nameDisplay) or keyDisplay or itemKey
                        local cleanCat = Guard.SanitizePeerText(item.category, 32)
                        if cleanCat == "" then cleanCat = "Other" end
                        local sev = Guard.SafeNumber(item.severity) or tonumber(item.severity) or 2
                        if sev ~= sev then sev = 2 end

                        local rawCreated = Guard.SafeNumber(item.createdAt) or tonumber(item.createdAt)
                        local rawUpdated = Guard.SafeNumber(item.updatedAt) or tonumber(item.updatedAt)
                        local nowTs = time()
                        local safeCreated = (rawCreated ~= nil and IsFiniteRev(rawCreated)) and rawCreated or nowTs
                        local safeUpdated = (rawUpdated ~= nil and IsFiniteRev(rawUpdated)) and rawUpdated or nowTs

                        if cur and not cur.deleted and isDeleted then
                            activeCount = math.max(0, activeCount - 1)
                        elseif isNewActive then
                            activeCount = activeCount + 1
                        end

                        peer.entries[itemKey] = {
                            key        = itemKey,
                            name       = displayName,
                            guid       = Guard.SafePlayerGuid(item.guid),
                            class      = Guard.SafeClassToken(item.class),
                            listType   = (item.listType == ns.LIST_GREEN) and ns.LIST_GREEN or ns.LIST_BLACK,
                            category   = cleanCat,
                            severity   = math.max(1, math.min(3, sev)),
                            sharedNote = Guard.SanitizePeerText(item.sharedNote, 300),
                            context    = Guard.SanitizePeerText(item.context, 80),
                            createdAt  = safeCreated,
                            updatedAt  = safeUpdated,
                            rev        = itemRev,
                            deleted    = isDeleted,
                        }
                        applied = applied + 1
                    end
                end
            end
        end
    end

    local curLastRev = tonumber(peer.lastRev) or 0
    local rawFrom = (fromRev ~= nil) and tonumber(fromRev) or nil
    local numFrom = (rawFrom ~= nil and IsFiniteRev(rawFrom)) and rawFrom or nil
    local rawTo = tonumber(toRev)
    local numTo = (rawTo ~= nil and IsFiniteRev(rawTo)) and rawTo or nil
    local hasGap = (numFrom ~= nil and numFrom > curLastRev)
    if not hasGap and numTo and numTo > curLastRev then
        peer.lastRev = numTo
    end
    if applied > 0 then
        guidIndexDirty = true
        ns:Emit("DB_CHANGED", "peer", authorID)
    else
        ns:Emit("PEERS_CHANGED")
    end
    return applied, hasGap
end

function DB:PruneOldTombstones(maxAgeSec)
    local root = _G.TheListDB
    if not root then return 0 end
    local age = tonumber(maxAgeSec) or (60 * 86400)
    local cutoff = time() - age
    local pruned = 0

    for key, e in pairs(root.personal) do
        if type(e) == "table" and e.deleted == true and (tonumber(e.updatedAt) or 0) < cutoff then
            root.personal[key] = nil
            pruned = pruned + 1
        end
    end
    for _, peer in pairs(root.peers) do
        if type(peer) == "table" and type(peer.entries) == "table" then
            for key, e in pairs(peer.entries) do
                if type(e) == "table" and e.deleted == true and (tonumber(e.updatedAt) or 0) < cutoff then
                    peer.entries[key] = nil
                    pruned = pruned + 1
                end
            end
        end
    end
    if pruned > 0 then
        guidIndexDirty = true
    end
    return pruned
end

function DB:DeletePeerCache(authorID)
    local root = _G.TheListDB
    if not root or not authorID then return end
    root.peers[authorID] = nil
    if type(root.dismissedPeerEntries) == "table" then
        root.dismissedPeerEntries[authorID] = nil
    end
    guidIndexDirty = true
    ns:Emit("DB_CHANGED", "peer_remove", authorID)
    ns:Emit("PEERS_CHANGED")
end

-- Looks up a player by Name-Realm and/or GUID across personal + active peers
function DB:Lookup(rawName, guid, includePeers)
    local root = _G.TheListDB
    if not root then return nil end

    local key = Guard.NormalizeNameRealm(rawName)
    local safeGuid = Guard.SafeString(guid)
    local mapped = nil
    if safeGuid then
        EnsureGuidIndex()
        mapped = guidIndex[safeGuid]
    end

    if not key and not mapped then return nil end

    local personalMatch = nil
    if key then
        local pe = root.personal[key]
        if pe and not pe.deleted then
            personalMatch = pe
        end
    end
    if not personalMatch and mapped then
        for mk in pairs(mapped) do
            if mk ~= key then
                local pe = root.personal[mk]
                if pe and not pe.deleted then
                    personalMatch = pe
                    break
                end
            end
        end
    end

    local settings = self:Settings()
    local allowPeers
    if includePeers ~= nil then
        allowPeers = (includePeers == true)
    else
        allowPeers = (settings.includePeerMatches == true)
    end
    local syncGreen = settings.syncGreenEntries
    local peerMatches = nil

    if allowPeers then
        for authorID, peer in pairs(root.peers) do
            if type(peer) == "table" and not self:IsPeerMuted(authorID) and type(peer.entries) == "table" then
                local matchedEntry = nil
                if key and not self:IsPeerEntryDismissed(authorID, key) then
                    local e = peer.entries[key]
                    if e and not e.deleted and (e.listType ~= ns.LIST_GREEN or syncGreen) then
                        matchedEntry = e
                    end
                end
                if not matchedEntry and mapped then
                    for mk in pairs(mapped) do
                        if mk ~= key and not self:IsPeerEntryDismissed(authorID, mk) then
                            local e = peer.entries[mk]
                            if e and not e.deleted and (e.listType ~= ns.LIST_GREEN or syncGreen) then
                                matchedEntry = e
                                break
                            end
                        end
                    end
                end
                if matchedEntry then
                    if not peerMatches then peerMatches = {} end
                    peerMatches[#peerMatches + 1] = {
                        authorID = authorID,
                        authorLabel = peer.authorLabel or authorID,
                        entry = matchedEntry,
                    }
                end
            end
        end
    end

    if not personalMatch and not peerMatches then return nil end

    local hasBlack, hasGreen = false, false
    local maxSeverity = 0
    if personalMatch then
        if personalMatch.listType == ns.LIST_BLACK then
            hasBlack = true
            maxSeverity = math.max(maxSeverity, personalMatch.severity or 2)
        else
            hasGreen = true
        end
    end
    if peerMatches then
        for i = 1, #peerMatches do
            local pe = peerMatches[i].entry
            if pe.listType == ns.LIST_BLACK then
                hasBlack = true
                maxSeverity = math.max(maxSeverity, pe.severity or 2)
            else
                hasGreen = true
            end
        end
    end

    local primary = personalMatch
    local primarySource = personalMatch and "You" or nil
    if not primary and peerMatches then
        if hasBlack then
            local bestMatch = nil
            local bestSev = -1
            local bestUpdated = -1
            for i = 1, #peerMatches do
                local pm = peerMatches[i]
                local pe = pm.entry
                if pe.listType == ns.LIST_BLACK then
                    local sev = pe.severity or 2
                    local upd = pe.updatedAt or 0
                    if sev > bestSev or (sev == bestSev and upd > bestUpdated) then
                        bestMatch = pm
                        bestSev = sev
                        bestUpdated = upd
                    end
                end
            end
            if bestMatch then
                primary = bestMatch.entry
                primarySource = bestMatch.authorLabel
            end
        end
        if not primary then
            primary = peerMatches[1].entry
            primarySource = peerMatches[1].authorLabel
        end
    end

    local effectiveType = (personalMatch and personalMatch.listType)
        or (hasBlack and ns.LIST_BLACK)
        or ns.LIST_GREEN

    return {
        personal = personalMatch,
        peers = peerMatches or {},
        hasBlack = hasBlack,
        hasGreen = hasGreen,
        maxSeverity = maxSeverity,
        effectiveType = effectiveType,
        primary = primary,
        primarySource = primarySource,
    }
end

local function ExtractShortLabel(rawLabel)
    if type(rawLabel) ~= "string" or rawLabel == "" then return "" end
    if Guard.IsForever() then return rawLabel end
    return rawLabel:match("^([^%-]+)%-") or rawLabel
end

function DB:BuildPeerShortLabels()
    local root = _G.TheListDB
    local rawById = {}
    local baseById = {}
    local counts = {}

    local function Register(aid, lbl)
        if type(aid) ~= "string" or aid == "" or rawById[aid] then return end
        if self:IsPeerMuted(aid) then return end
        local raw = (type(lbl) == "string" and lbl ~= "") and lbl or aid
        local base = ExtractShortLabel(raw)
        if base == "" then base = raw end
        rawById[aid] = raw
        baseById[aid] = base
        local bk = base:lower()
        counts[bk] = (counts[bk] or 0) + 1
    end

    if root and type(root.peers) == "table" then
        for aid, peer in pairs(root.peers) do
            if type(peer) == "table" then
                Register(aid, peer.authorLabel)
            end
        end
    end
    if ns.Sync and ns.Sync.GetOnlinePeers then
        local online = ns.Sync:GetOnlinePeers()
        if type(online) == "table" then
            for aid, o in pairs(online) do
                if type(o) == "table" then
                    Register(aid, o.authorLabel)
                end
            end
        end
    end

    local out = {}
    for aid, raw in pairs(rawById) do
        local base = baseById[aid]
        if (counts[base:lower()] or 0) > 1 then
            out[aid] = raw
        else
            out[aid] = base
        end
    end
    return out
end

function DB:GetShortPeerLabel(authorID, fallbackLabel, labelMap)
    local map = labelMap or self:BuildPeerShortLabels()
    if authorID and map[authorID] then
        return map[authorID]
    end
    if type(fallbackLabel) == "string" and fallbackLabel ~= "" then
        local short = ExtractShortLabel(fallbackLabel)
        if short ~= "" then return short end
        return fallbackLabel
    end
    return tostring(authorID or "")
end

local function NormalizeNoteText(str)
    if type(str) ~= "string" then return "" end
    return (str:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""):lower()
end

local function EntryContentFingerprint(entry, listType)
    local cat = (entry.category or "Other"):lower()
    local sev = (listType == ns.LIST_BLACK) and tostring(entry.severity or 2) or "0"
    local note = NormalizeNoteText(entry.sharedNote)
    return cat .. "|" .. sev .. "|" .. note
end

local function IsSameOrRedundantAsPrimary(primary, peerEntry, listType)
    if not (primary and peerEntry) then return false end
    local pCat = (primary.category or "Other"):lower()
    local eCat = (peerEntry.category or "Other"):lower()
    if pCat ~= eCat then return false end
    if listType == ns.LIST_BLACK and (primary.severity or 2) ~= (peerEntry.severity or 2) then
        return false
    end
    local pNote = NormalizeNoteText(primary.sharedNote)
    local eNote = NormalizeNoteText(peerEntry.sharedNote)
    return (eNote == pNote) or (eNote == "")
end

local function SortPeerRecs(list, listType)
    table.sort(list, function(a, b)
        local ea, eb = a.entry, b.entry
        if listType == ns.LIST_BLACK then
            local sa, sb = ea.severity or 2, eb.severity or 2
            if sa ~= sb then return sa > sb end
        end
        local na = NormalizeNoteText(ea.sharedNote) ~= ""
        local nb = NormalizeNoteText(eb.sharedNote) ~= ""
        if na ~= nb then return na end
        local ua, ub = ea.updatedAt or 0, eb.updatedAt or 0
        if ua ~= ub then return ua > ub end
        local la = (a.shortLabel or a.authorLabel or ""):lower()
        local lb = (b.shortLabel or b.authorLabel or ""):lower()
        if la ~= lb then return la < lb end
        return tostring(a.authorID or "") < tostring(b.authorID or "")
    end)
end

local function GroupPeerEntriesByContent(peerRecs, listType)
    if not peerRecs or #peerRecs == 0 then return {} end
    local byFp = {}
    local groups = {}
    for i = 1, #peerRecs do
        local pr = peerRecs[i]
        local e = pr.entry
        local fp = EntryContentFingerprint(e, listType)
        local g = byFp[fp]
        if not g then
            g = {
                listType = listType,
                category = e.category or "Other",
                severity = (listType == ns.LIST_BLACK) and (e.severity or 2) or 1,
                sharedNote = e.sharedNote or "",
                context = e.context or "",
                updatedAt = e.updatedAt or 0,
                authors = {},
            }
            byFp[fp] = g
            groups[#groups + 1] = g
        else
            if (e.updatedAt or 0) > (g.updatedAt or 0) then
                g.updatedAt = e.updatedAt or 0
                if type(e.sharedNote) == "string" and e.sharedNote ~= "" then
                    g.sharedNote = e.sharedNote
                end
            end
            if (g.context == nil or g.context == "") and type(e.context) == "string" and e.context ~= "" then
                g.context = e.context
            end
        end
        g.authors[#g.authors + 1] = pr
    end

    for i = 1, #groups do
        table.sort(groups[i].authors, function(a, b)
            local la = (a.shortLabel or a.authorLabel or ""):lower()
            local lb = (b.shortLabel or b.authorLabel or ""):lower()
            if la ~= lb then return la < lb end
            return tostring(a.authorID or "") < tostring(b.authorID or "")
        end)
    end

    table.sort(groups, function(a, b)
        if listType == ns.LIST_BLACK and (a.severity or 2) ~= (b.severity or 2) then
            return (a.severity or 2) > (b.severity or 2)
        end
        local na = NormalizeNoteText(a.sharedNote) ~= ""
        local nb = NormalizeNoteText(b.sharedNote) ~= ""
        if na ~= nb then return na end
        if (a.updatedAt or 0) ~= (b.updatedAt or 0) then
            return (a.updatedAt or 0) > (b.updatedAt or 0)
        end
        local aa = a.authors[1] and (a.authors[1].shortLabel or a.authors[1].authorLabel or ""):lower() or ""
        local ab = b.authors[1] and (b.authors[1].shortLabel or b.authors[1].authorLabel or ""):lower() or ""
        if aa ~= ab then return aa < ab end
        return (a.category or "") < (b.category or "")
    end)

    return groups
end

function DB:QueryEntries(listType, sourceFilter, searchText, sortBy, categoryFilter, minSeverityFilter)
    local root = _G.TheListDB
    if not root then return {} end

    local lt = (listType == ns.LIST_GREEN) and ns.LIST_GREEN or ns.LIST_BLACK
    local oppLt = (lt == ns.LIST_GREEN) and ns.LIST_BLACK or ns.LIST_GREEN
    local sf = sourceFilter or "all"
    local q = type(searchText) == "string" and searchText:lower():match("^%s*(.-)%s*$") or ""
    local catFilter = (type(categoryFilter) == "string" and categoryFilter ~= "") and categoryFilter or nil
    local sevFilter = (type(minSeverityFilter) == "number" and minSeverityFilter > 1 and lt == ns.LIST_BLACK) and minSeverityFilter or nil

    local shortLabels = self:BuildPeerShortLabels()
    local personalByKey = {}
    local peersByKey = {}
    local allKeys = {}

    for k, e in pairs(root.personal) do
        if type(e) == "table" and not e.deleted then
            local key = e.key or k
            personalByKey[key] = e
            allKeys[key] = true
        end
    end

    for authorID, peer in pairs(root.peers) do
        if type(peer) == "table" and not self:IsPeerMuted(authorID) and type(peer.entries) == "table" then
            local rawLbl = peer.authorLabel or authorID
            local shortLbl = self:GetShortPeerLabel(authorID, rawLbl, shortLabels)
            for k, e in pairs(peer.entries) do
                local key = (type(e) == "table" and e.key) or k
                if type(e) == "table" and not e.deleted and not self:IsPeerEntryDismissed(authorID, key) then
                    allKeys[key] = true
                    local slot = peersByKey[key]
                    if not slot then
                        slot = { black = {}, green = {} }
                        peersByKey[key] = slot
                    end
                    local bucket = (e.listType == ns.LIST_GREEN) and slot.green or slot.black
                    bucket[#bucket + 1] = {
                        authorID = authorID,
                        authorLabel = rawLbl,
                        shortLabel = shortLbl,
                        entry = e,
                    }
                end
            end
        end
    end

    local function MatchesEntryText(entry, authorLabel, shortLabel, includePrivate)
        if not entry then return false end
        if (entry.name or ""):lower():find(q, 1, true) then return true end
        if (entry.category or ""):lower():find(q, 1, true) then return true end
        if (entry.sharedNote or ""):lower():find(q, 1, true) then return true end
        if includePrivate and (entry.privateNote or ""):lower():find(q, 1, true) then return true end
        if (entry.context or ""):lower():find(q, 1, true) then return true end
        if (authorLabel or ""):lower():find(q, 1, true) then return true end
        if (shortLabel or ""):lower():find(q, 1, true) then return true end
        return false
    end

    local results = {}
    for key in pairs(allKeys) do
        local personal = personalByKey[key]
        local slot = peersByKey[key]
        local samePeers = slot and slot[lt] or {}
        local conflictPeers = slot and slot[oppLt] or {}

        local include = false
        local isMine = false
        if personal then
            if personal.listType == lt then
                include = true
                isMine = true
            end
        else
            if lt == ns.LIST_BLACK then
                include = (#samePeers > 0)
            else
                include = (#samePeers > 0 and #conflictPeers == 0)
            end
        end

        if include then
            if sf == "mine" and not isMine then
                include = false
            elseif sf == "peers" and isMine then
                include = false
            end
        end

        if include then
            local sameSorted = {}
            for i = 1, #samePeers do sameSorted[i] = samePeers[i] end
            SortPeerRecs(sameSorted, lt)

            local conflictSorted = {}
            for i = 1, #conflictPeers do conflictSorted[i] = conflictPeers[i] end
            SortPeerRecs(conflictSorted, oppLt)

            local primary, primaryAuthorID, primaryAuthorLabel, primaryShortLabel
            local sameAsPrimaryPeers = {}
            local otherPeers = {}

            if isMine then
                primary = personal
                primaryAuthorID = root.authorID
                primaryAuthorLabel = "You"
                primaryShortLabel = "You"
                for i = 1, #sameSorted do
                    local pr = sameSorted[i]
                    if IsSameOrRedundantAsPrimary(primary, pr.entry, lt) then
                        sameAsPrimaryPeers[#sameAsPrimaryPeers + 1] = pr
                    else
                        otherPeers[#otherPeers + 1] = pr
                    end
                end
            else
                local best = sameSorted[1]
                primary = best.entry
                primaryAuthorID = best.authorID
                primaryAuthorLabel = best.authorLabel
                primaryShortLabel = best.shortLabel
                for i = 2, #sameSorted do
                    local pr = sameSorted[i]
                    if IsSameOrRedundantAsPrimary(primary, pr.entry, lt) then
                        sameAsPrimaryPeers[#sameAsPrimaryPeers + 1] = pr
                    else
                        otherPeers[#otherPeers + 1] = pr
                    end
                end
            end

            local distinctPeerGroups = GroupPeerEntriesByContent(otherPeers, lt)
            local conflictGroups = GroupPeerEntriesByContent(conflictSorted, oppLt)

            local maxSeverity = 1
            if lt == ns.LIST_BLACK then
                if isMine then
                    maxSeverity = primary.severity or 2
                else
                    maxSeverity = 0
                    for i = 1, #sameSorted do
                        local sev = sameSorted[i].entry.severity or 2
                        if sev > maxSeverity then maxSeverity = sev end
                    end
                    if maxSeverity == 0 then maxSeverity = 2 end
                end
            end

            local latestUpdatedAt = primary.updatedAt or 0
            if not isMine or #distinctPeerGroups > 0 then
                for i = 1, #distinctPeerGroups do
                    local ts = distinctPeerGroups[i].updatedAt or 0
                    if ts > latestUpdatedAt then latestUpdatedAt = ts end
                end
            end

            local bestGuid = primary.guid
            local bestClass = primary.class
            if not bestGuid or not bestClass then
                for i = 1, #sameSorted do
                    bestGuid = bestGuid or sameSorted[i].entry.guid
                    bestClass = bestClass or sameSorted[i].entry.class
                end
            end
            if not bestGuid or not bestClass then
                for i = 1, #conflictSorted do
                    bestGuid = bestGuid or conflictSorted[i].entry.guid
                    bestClass = bestClass or conflictSorted[i].entry.class
                end
            end

            local passCat = true
            if catFilter then
                passCat = (primary.category == catFilter)
                if not passCat then
                    for i = 1, #distinctPeerGroups do
                        if distinctPeerGroups[i].category == catFilter then
                            passCat = true
                            break
                        end
                    end
                end
            end

            local passSev = (not sevFilter) or (maxSeverity >= sevFilter)

            local passQuery = (q == "")
            if not passQuery then
                if isMine and MatchesEntryText(personal, "You", "You", true) then
                    passQuery = true
                end
                if not passQuery then
                    for i = 1, #sameSorted do
                        local pr = sameSorted[i]
                        if MatchesEntryText(pr.entry, pr.authorLabel, pr.shortLabel, false) then
                            passQuery = true
                            break
                        end
                    end
                end
                if not passQuery then
                    for i = 1, #conflictSorted do
                        local pr = conflictSorted[i]
                        if MatchesEntryText(pr.entry, pr.authorLabel, pr.shortLabel, false) then
                            passQuery = true
                            break
                        end
                    end
                end
            end

            if passCat and passSev and passQuery then
                results[#results + 1] = {
                    key = key,
                    name = primary.name or key,
                    guid = bestGuid,
                    class = bestClass,
                    listType = lt,
                    isMine = isMine,
                    personal = isMine and personal or nil,
                    entry = primary,
                    primary = primary,
                    authorID = primaryAuthorID,
                    authorLabel = primaryAuthorLabel,
                    primaryShortLabel = primaryShortLabel,
                    peers = sameSorted,
                    sameAsPrimaryPeers = sameAsPrimaryPeers,
                    distinctPeerGroups = distinctPeerGroups,
                    conflictPeers = conflictSorted,
                    conflictGroups = conflictGroups,
                    peerCount = #sameSorted,
                    distinctNoteCount = #distinctPeerGroups,
                    conflictCount = #conflictSorted,
                    hasExpandableDetails = (#distinctPeerGroups > 0 or #conflictGroups > 0),
                    maxSeverity = maxSeverity,
                    latestUpdatedAt = latestUpdatedAt,
                }
            end
        end
    end

    table.sort(results, function(a, b)
        if sortBy == "name" then
            return (a.key or "") < (b.key or "")
        elseif sortBy == "category" then
            if a.primary.category ~= b.primary.category then
                return (a.primary.category or "") < (b.primary.category or "")
            end
            if (a.latestUpdatedAt or 0) ~= (b.latestUpdatedAt or 0) then
                return (a.latestUpdatedAt or 0) > (b.latestUpdatedAt or 0)
            end
            return (a.key or "") < (b.key or "")
        end
        -- default: newest
        if (a.latestUpdatedAt or 0) ~= (b.latestUpdatedAt or 0) then
            return (a.latestUpdatedAt or 0) > (b.latestUpdatedAt or 0)
        end
        return (a.key or "") < (b.key or "")
    end)

    return results
end

function DB:GetListCounts(listType)
    local root = _G.TheListDB
    if not root then return 0, 0, 0, 0 end

    local lt = (listType == ns.LIST_GREEN) and ns.LIST_GREEN or ns.LIST_BLACK
    local personalByKey = {}
    local peerHasList = {}

    for k, e in pairs(root.personal) do
        if type(e) == "table" and not e.deleted then
            personalByKey[e.key or k] = (e.listType == ns.LIST_GREEN) and ns.LIST_GREEN or ns.LIST_BLACK
        end
    end

    for aid, peer in pairs(root.peers) do
        if type(peer) == "table" and not self:IsPeerMuted(aid) and type(peer.entries) == "table" then
            for k, e in pairs(peer.entries) do
                local key = (type(e) == "table" and e.key) or k
                if type(e) == "table" and not e.deleted and not self:IsPeerEntryDismissed(aid, key) then
                    local slot = peerHasList[key]
                    if not slot then
                        slot = { black = false, green = false }
                        peerHasList[key] = slot
                    end
                    if e.listType == ns.LIST_GREEN then
                        slot.green = true
                    else
                        slot.black = true
                    end
                end
            end
        end
    end

    local mine, peerOnly, shared = 0, 0, 0
    for key, plt in pairs(personalByKey) do
        if plt == lt then
            mine = mine + 1
            local slot = peerHasList[key]
            if slot and slot[lt] then
                shared = shared + 1
            end
        end
    end
    for key, slot in pairs(peerHasList) do
        if not personalByKey[key] then
            if lt == ns.LIST_BLACK then
                if slot.black then peerOnly = peerOnly + 1 end
            else
                if slot.green and not slot.black then peerOnly = peerOnly + 1 end
            end
        end
    end

    return mine + peerOnly, mine, peerOnly, shared
end

function DB:BuildDedupedTooltipGroups(match)
    if type(match) ~= "table" then return {} end
    local shortLabels = self:BuildPeerShortLabels()
    local groups = {}
    local personal = match.personal
    local peers = match.peers or {}
    local consumed = {}

    if personal then
        local plt = (personal.listType == ns.LIST_GREEN) and ns.LIST_GREEN or ns.LIST_BLACK
        local g = {
            hasYou = true,
            peerNames = {},
            listType = plt,
            category = personal.category or "Other",
            severity = (plt == ns.LIST_BLACK) and (personal.severity or 2) or 1,
            note = personal.sharedNote or "",
            privateNote = personal.privateNote or "",
        }
        local seenNames = {}
        for i = 1, #peers do
            local p = peers[i]
            local pe = p.entry
            if pe then
                local elt = (pe.listType == ns.LIST_GREEN) and ns.LIST_GREEN or ns.LIST_BLACK
                if elt == plt and IsSameOrRedundantAsPrimary(personal, pe, plt) then
                    consumed[i] = true
                    local sLbl = self:GetShortPeerLabel(p.authorID, p.authorLabel, shortLabels)
                    if not seenNames[sLbl] then
                        seenNames[sLbl] = true
                        g.peerNames[#g.peerNames + 1] = sLbl
                    end
                end
            end
        end
        table.sort(g.peerNames, function(a, b) return a:lower() < b:lower() end)
        groups[#groups + 1] = g
    end

    local bucketMap = {}
    local peerBuckets = {}
    for i = 1, #peers do
        if not consumed[i] then
            local p = peers[i]
            local pe = p.entry
            if pe then
                local elt = (pe.listType == ns.LIST_GREEN) and ns.LIST_GREEN or ns.LIST_BLACK
                local fp = elt .. "|" .. EntryContentFingerprint(pe, elt)
                local b = bucketMap[fp]
                if not b then
                    b = {
                        hasYou = false,
                        peerNames = {},
                        _seen = {},
                        listType = elt,
                        category = pe.category or "Other",
                        severity = (elt == ns.LIST_BLACK) and (pe.severity or 2) or 1,
                        note = pe.sharedNote or "",
                        privateNote = "",
                        updatedAt = pe.updatedAt or 0,
                    }
                    bucketMap[fp] = b
                    peerBuckets[#peerBuckets + 1] = b
                elseif (pe.updatedAt or 0) > (b.updatedAt or 0) then
                    b.updatedAt = pe.updatedAt or 0
                    if type(pe.sharedNote) == "string" and pe.sharedNote ~= "" then
                        b.note = pe.sharedNote
                    end
                end
                local sLbl = self:GetShortPeerLabel(p.authorID, p.authorLabel, shortLabels)
                if not b._seen[sLbl] then
                    b._seen[sLbl] = true
                    b.peerNames[#b.peerNames + 1] = sLbl
                end
            end
        end
    end

    for i = 1, #peerBuckets do
        local b = peerBuckets[i]
        b._seen = nil
        table.sort(b.peerNames, function(a, c) return a:lower() < c:lower() end)
    end

    table.sort(peerBuckets, function(a, b)
        if a.listType ~= b.listType then
            return a.listType == ns.LIST_BLACK
        end
        if a.listType == ns.LIST_BLACK and (a.severity or 2) ~= (b.severity or 2) then
            return (a.severity or 2) > (b.severity or 2)
        end
        local na = NormalizeNoteText(a.note) ~= ""
        local nb = NormalizeNoteText(b.note) ~= ""
        if na ~= nb then return na end
        if (a.updatedAt or 0) ~= (b.updatedAt or 0) then
            return (a.updatedAt or 0) > (b.updatedAt or 0)
        end
        return (a.peerNames[1] or ""):lower() < (b.peerNames[1] or ""):lower()
    end)

    for i = 1, #peerBuckets do
        groups[#groups + 1] = peerBuckets[i]
    end
    return groups
end

function DB:TrimRecentTeammates()
    local root = _G.TheListDB
    if not root or type(root.recent) ~= "table" then return end
    local maxR = self:Settings().maxRecent or 80
    local count = 0
    for _ in pairs(root.recent) do
        count = count + 1
    end
    if count <= maxR then return end

    local list = {}
    for k, v in pairs(root.recent) do
        list[#list + 1] = { key = k, seenAt = (type(v) == "table" and v.seenAt) or 0 }
    end
    table.sort(list, function(a, b) return a.seenAt > b.seenAt end)
    for i = maxR + 1, #list do
        root.recent[list[i].key] = nil
    end
end

function DB:RecordRecentTeammate(info, role, context, deferTrim, myKeyOverride)
    local root = _G.TheListDB
    if not root or not self:Settings().captureRecent then return end
    if not info or not info.key then return end

    -- Don't record self
    local myKey = myKeyOverride or Guard.GetPlayerKey()
    if myKey and myKey == info.key then return end

    local prev = root.recent[info.key]
    local bestContext = (context and context ~= "") and context or (prev and prev.context) or ""

    root.recent[info.key] = {
        key = info.key,
        name = info.name,
        guid = info.guid or (prev and prev.guid),
        class = info.class or (prev and prev.class),
        role = (role and role ~= "NONE") and role or (prev and prev.role),
        context = bestContext,
        seenAt = time(),
    }

    if not deferTrim then
        self:TrimRecentTeammates()
    end
end

function DB:GetRecentTeammates(searchText)
    local root = _G.TheListDB
    if not root then return {} end
    local q = type(searchText) == "string" and searchText:lower():match("^%s*(.-)%s*$") or ""
    local out = {}
    for _, r in pairs(root.recent) do
        if type(r) == "table" then
            local ok = (q == "")
                or (r.name or ""):lower():find(q, 1, true)
                or (r.context or ""):lower():find(q, 1, true)
                or (r.class or ""):lower():find(q, 1, true)
            if ok then out[#out + 1] = r end
        end
    end
    table.sort(out, function(a, b) return (a.seenAt or 0) > (b.seenAt or 0) end)
    return out
end

function DB:GetCounts()
    local root = _G.TheListDB
    local counts = {
        myBlack = 0,
        myGreen = 0,
        peerBlack = 0,
        peerGreen = 0,
        peerOnlyBlack = 0,
        peerOnlyGreen = 0,
        peerCount = 0,
        recentCount = 0,
    }
    if not root then return counts end

    local personalByKey = {}
    for k, e in pairs(root.personal) do
        if type(e) == "table" and not e.deleted then
            local key = e.key or k
            if e.listType == ns.LIST_GREEN then
                counts.myGreen = counts.myGreen + 1
                personalByKey[key] = ns.LIST_GREEN
            else
                counts.myBlack = counts.myBlack + 1
                personalByKey[key] = ns.LIST_BLACK
            end
        end
    end

    local peerBlackKeys, peerGreenKeys = {}, {}
    for aid, peer in pairs(root.peers) do
        if type(peer) == "table" then
            counts.peerCount = counts.peerCount + 1
            if not self:IsPeerMuted(aid) and type(peer.entries) == "table" then
                for k, e in pairs(peer.entries) do
                    local key = (type(e) == "table" and e.key) or k
                    if type(e) == "table" and not e.deleted and not self:IsPeerEntryDismissed(aid, key) then
                        if e.listType == ns.LIST_GREEN then
                            peerGreenKeys[key] = true
                        else
                            peerBlackKeys[key] = true
                        end
                    end
                end
            end
        end
    end

    for key in pairs(peerBlackKeys) do
        counts.peerBlack = counts.peerBlack + 1
        if not personalByKey[key] then
            counts.peerOnlyBlack = counts.peerOnlyBlack + 1
        end
    end
    for key in pairs(peerGreenKeys) do
        counts.peerGreen = counts.peerGreen + 1
        if not personalByKey[key] and not peerBlackKeys[key] then
            counts.peerOnlyGreen = counts.peerOnlyGreen + 1
        end
    end

    for _ in pairs(root.recent) do counts.recentCount = counts.recentCount + 1 end
    return counts
end

local EXPORT_PREFIX = "THELIST:1:"
local MAX_IMPORT_ENTRIES = 1000
local MAX_IMPORT_ENCODED = 262144
local MAX_IMPORT_DECOMPRESSED = 524288

-- Export personal non-deleted entries into a printable string safe for Discord/backups.
-- Private notes and local Blizzard /ignore flags are intentionally excluded.
function DB:ExportPersonalString()
    local root = _G.TheListDB
    if not root then return nil, "Database not initialized." end
    local LibSerialize = _G.LibStub and _G.LibStub("LibSerialize", true)
    local LibDeflate = _G.LibStub and _G.LibStub("LibDeflate", true)
    if not (LibSerialize and LibDeflate) then
        return nil, "Required serialization libraries are unavailable."
    end

    local items = {}
    for _, e in pairs(root.personal) do
        if type(e) == "table" and not e.deleted and type(e.key) == "string" then
            items[#items + 1] = {
                key        = e.key,
                name       = e.name or e.key,
                guid       = e.guid,
                class      = e.class,
                listType   = (e.listType == ns.LIST_GREEN) and ns.LIST_GREEN or ns.LIST_BLACK,
                category   = e.category or "Other",
                severity   = e.severity or 2,
                sharedNote = e.sharedNote or "",
                context    = e.context or "",
                createdAt  = e.createdAt,
                updatedAt  = e.updatedAt,
            }
        end
    end

    local payload = {
        v = 1,
        ver = ns.VERSION,
        author = root.authorLabel or "",
        exportedAt = time(),
        items = items,
    }
    local serialized = LibSerialize:Serialize(payload)
    if not serialized then return nil, "Serialization failed." end
    local compressed = LibDeflate:CompressDeflate(serialized)
    if not compressed then return nil, "Compression failed." end
    local encoded = LibDeflate:EncodeForPrint(compressed)
    if not encoded then return nil, "Encoding failed." end
    return EXPORT_PREFIX .. encoded, nil, #items
end

function DB:ImportPersonalString(rawStr)
    local root = _G.TheListDB
    if not root then return 0, 0, "Database not initialized." end
    if type(rawStr) ~= "string" or Guard.IsSecret(rawStr) then
        return 0, 0, "Paste a valid THE LIST export string first."
    end
    local trimmed = rawStr:match("^%s*(.-)%s*$") or ""
    if trimmed == "" then
        return 0, 0, "Import string is empty."
    end
    if trimmed:sub(1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then
        return 0, 0, "Invalid format (expected a string starting with " .. EXPORT_PREFIX .. ")."
    end

    local LibSerialize = _G.LibStub and _G.LibStub("LibSerialize", true)
    local LibDeflate = _G.LibStub and _G.LibStub("LibDeflate", true)
    if not (LibSerialize and LibDeflate) then
        return 0, 0, "Required serialization libraries are unavailable."
    end

    local encoded = trimmed:sub(#EXPORT_PREFIX + 1):gsub("%s+", "")
    if #encoded > MAX_IMPORT_ENCODED then
        return 0, 0, "Import string is too large."
    end
    local compressed = LibDeflate:DecodeForPrint(encoded)
    if not compressed then return 0, 0, "Could not decode import string (corrupted or truncated)." end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return 0, 0, "Could not decompress import string." end
    if #serialized > MAX_IMPORT_DECOMPRESSED then
        return 0, 0, "Import payload is too large."
    end
    local ok, payload = LibSerialize:Deserialize(serialized)
    if not ok or type(payload) ~= "table" or type(payload.items) ~= "table" then
        return 0, 0, "Invalid THE LIST payload."
    end

    local imported, skipped = 0, 0
    local now = time()
    local limit = math.min(#payload.items, MAX_IMPORT_ENTRIES)
    for i = 1, limit do
        local item = payload.items[i]
        if type(item) == "table" then
            local rawKey = Guard.SanitizePeerText(item.key or item.name, 64)
            local key, keyDisplay, _, keyRealm = Guard.NormalizeNameRealm(rawKey)
            if key then
                local existing = root.personal[key]
                local rawUpdated = Guard.SafeNumber(item.updatedAt) or tonumber(item.updatedAt)
                local incUpdated = (rawUpdated ~= nil and IsFiniteRev(rawUpdated)) and rawUpdated or now
                if existing and not existing.deleted and (tonumber(existing.updatedAt) or 0) >= incUpdated then
                    skipped = skipped + 1
                else
                    local cleanName = Guard.SanitizePeerText(item.name, 64)
                    local nameKey, nameDisplay = Guard.NormalizeNameRealm(cleanName, keyRealm)
                    local displayName = (nameKey == key and nameDisplay) or keyDisplay or key
                    local listType = (item.listType == ns.LIST_GREEN) and ns.LIST_GREEN or ns.LIST_BLACK
                    local defaultCat = (listType == ns.LIST_GREEN) and "Reliable" or "Leaver"
                    local cleanCat = Guard.SanitizePeerText(item.category, 32)
                    if cleanCat == "" then cleanCat = defaultCat end
                    local sev = Guard.SafeNumber(item.severity) or tonumber(item.severity) or 2
                    if sev ~= sev then sev = 2 end
                    local rawCreated = Guard.SafeNumber(item.createdAt) or tonumber(item.createdAt)

                    root.revision = (tonumber(root.revision) or 0) + 1
                    local entry = existing or {}
                    local safeCreated = (rawCreated ~= nil and IsFiniteRev(rawCreated)) and rawCreated or entry.createdAt or now
                    entry.key         = key
                    entry.name        = displayName
                    entry.guid        = Guard.SafePlayerGuid(item.guid) or entry.guid
                    entry.class       = Guard.SafeClassToken(item.class) or entry.class
                    entry.listType    = listType
                    entry.category    = cleanCat
                    entry.severity    = math.max(1, math.min(3, sev))
                    entry.sharedNote  = Guard.SanitizePeerText(item.sharedNote, 300)
                    entry.privateNote = entry.privateNote or ""
                    local cleanCtx    = Guard.SanitizePeerText(item.context, 80)
                    entry.context     = (cleanCtx ~= "" and cleanCtx) or (entry.context or "")
                    if entry.share == nil then entry.share = true end
                    entry.retracted   = nil
                    entry.nativeIgnore = (listType == ns.LIST_BLACK) and (entry.nativeIgnore == true) or false
                    entry.createdAt   = safeCreated
                    entry.updatedAt   = incUpdated
                    entry.rev         = root.revision
                    entry.deleted     = false

                    root.personal[key] = entry
                    imported = imported + 1
                end
            else
                skipped = skipped + 1
            end
        end
    end

    if imported > 0 then
        guidIndexDirty = true
        ns:Emit("DB_CHANGED", "personal_import")
    end
    return imported, skipped, nil
end
