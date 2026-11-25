local _, ns = ...

local Detector = {}
ns.Detector = Detector

local Guard = ns.Guard
local DB = ns.DB

local dedupeTimestamps = {}      -- [dedupeKey] = time()
local applicantMatches = {}      -- [applicantID] = { matches = {...}, hasBlack, hasGreen, maxSeverity }
local searchCache = {}           -- [resultID] = { matches = {...}, hasBlack, hasGreen, maxSeverity, hasLeaver }
local groupSnapshot = {}         -- [canonicalKey] = true (to detect fresh joins)
local initialized = false

local function GetRosterZoneMap()
    local map = {}
    if not (_G.IsInGroup and _G.IsInGroup() and _G.GetRaidRosterInfo) then return map end
    local count = _G.GetNumGroupMembers and _G.GetNumGroupMembers() or 0
    for i = 1, count do
        local ok, rName, _, _, _, _, _, rZone = pcall(_G.GetRaidRosterInfo, i)
        if ok then
            local safeName = Guard.SafeString(rName)
            local safeZone = Guard.SafeString(rZone)
            if safeName and safeZone and safeZone ~= "Unknown" then
                local key = Guard.NormalizeNameRealm(safeName)
                if key then map[key] = safeZone end
            end
        end
    end
    return map
end

local function GetUnitZoneContext(unit, info, rosterZones, instName, instType, activeKeyLevel)
    local zone = rosterZones and info and info.key and rosterZones[info.key] or nil
    if zone == "Offline" then zone = nil end

    if not zone and _G.C_Map and _G.C_Map.GetBestMapForUnit and _G.C_Map.GetMapInfo then
        local okMap, mapID = pcall(_G.C_Map.GetBestMapForUnit, unit)
        mapID = okMap and Guard.SafeNumber(mapID) or nil
        if mapID then
            local okInfo, mapInfo = pcall(_G.C_Map.GetMapInfo, mapID)
            if okInfo and Guard.CanReadTable(mapInfo) then
                zone = Guard.SafeString(mapInfo.name)
            end
        end
    end

    -- Append active Mythic+ key level only if unit is actually in the same dungeon instance
    if instType == "party" and instName and activeKeyLevel and _G.UnitIsVisible then
        local okVis, vis = pcall(_G.UnitIsVisible, unit)
        if not okVis or Guard.IsSecret(vis) or not vis then return zone or "" end
        return (zone or instName) .. " +" .. tostring(activeKeyLevel)
    end

    return zone or ""
end

local function ShouldFireAlert(dedupeKey)
    local cooldown = tonumber(DB:Settings().dedupeCooldownSec) or 180
    local now = time()
    local prev = dedupeTimestamps[dedupeKey]
    if prev and (now - prev) < cooldown then
        return false
    end
    dedupeTimestamps[dedupeKey] = now
    return true
end

function Detector:ResetCooldowns()
    wipe(dedupeTimestamps)
end

function Detector:GetApplicantMatch(applicantID)
    return applicantMatches[applicantID]
end

function Detector:ScanGroupRoster(force)
    local s = DB:Settings()
    if not IsInGroup() then
        wipe(groupSnapshot)
        return
    end

    local inRaid = IsInRaid()
    local count = GetNumGroupMembers()
    local newSnapshot = {}
    local rosterZones = GetRosterZoneMap()
    local myKey = Guard.GetPlayerKey()

    local instName, instType
    if _G.GetInstanceInfo then
        local okInst, iName, iType = pcall(_G.GetInstanceInfo)
        if okInst then
            instName = Guard.SafeString(iName)
            instType = Guard.SafeString(iType)
        end
    end
    local activeKeyLevel
    if instType == "party" and instName and _G.C_ChallengeMode and _G.C_ChallengeMode.GetActiveKeystoneInfo then
        local okKey, level = pcall(_G.C_ChallengeMode.GetActiveKeystoneInfo)
        level = okKey and Guard.SafeNumber(level) or nil
        if level and level > 0 then
            activeKeyLevel = level
        end
    end

    local loopEnd = inRaid and count or math.max(0, count - 1)
    for i = 1, loopEnd do
        local unit = inRaid and ("raid" .. i) or ("party" .. i)

        local info = Guard.SafeUnitInfo(unit)
        if info and info.key and info.key ~= myKey then
            newSnapshot[info.key] = true
            DB:AttachGuid(info.name, info.guid, info.class)

            local role
            if _G.UnitGroupRolesAssigned then
                local ok, r = pcall(_G.UnitGroupRolesAssigned, unit)
                if ok then role = Guard.SafeString(r) end
            end
            local unitZone = GetUnitZoneContext(unit, info, rosterZones, instName, instType, activeKeyLevel)
            DB:RecordRecentTeammate(info, role, unitZone, true, myKey)

            if s.warnGroupRoster then
                local isFreshJoin = (not groupSnapshot[info.key]) or force
                if isFreshJoin then
                    local match = DB:Lookup(info.name, info.guid)
                    if match then
                        local wantWarn = false
                        if match.hasBlack and (match.maxSeverity or 2) >= (s.minSeverityGroup or 1) then
                            wantWarn = true
                        elseif match.hasGreen and s.warnGreenInGroup then
                            wantWarn = true
                        end
                        if wantWarn and (force or ShouldFireAlert("grp:" .. info.key)) then
                            ns:Emit("ALERT_MATCH", {
                                kind = "group",
                                name = info.name,
                                key = info.key,
                                class = info.class,
                                guid = info.guid,
                                match = match,
                            })
                        end
                    end
                end
            end
        end
    end

    if s.captureRecent then
        DB:TrimRecentTeammates()
    end
    groupSnapshot = newSnapshot
end

function Detector:ScanApplicants()
    wipe(applicantMatches)
    if not _G.C_LFGList or not _G.C_LFGList.GetApplicants then return end

    local ok, list = pcall(_G.C_LFGList.GetApplicants)
    if not ok or not Guard.CanReadTable(list) then return end

    local s = DB:Settings()

    for _, applicantID in ipairs(list) do
        if not Guard.IsSecret(applicantID) then
            local okApp, info = false, nil
            if _G.C_LFGList.GetApplicantInfo then
                okApp, info = pcall(_G.C_LFGList.GetApplicantInfo, applicantID)
            end
            if okApp and Guard.CanReadTable(info) then
                local status = Guard.SafeString(info.applicationStatus)
                local numMembers = Guard.SafeNumber(info.numMembers) or 0
                if status ~= "cancelled" and status ~= "declined" and status ~= "timedout" and status ~= "failed" and numMembers > 0 then
                    local found = {}
                    local hasBlack, hasGreen = false, false
                    local maxSev = 0

                    for m = 1, numMembers do
                        local okM, name, class, _, _, _, _, _, _, _, assignedRole = pcall(_G.C_LFGList.GetApplicantMemberInfo, applicantID, m)
                        if okM then
                            local safeName = Guard.SafeString(name)
                            local safeClass = Guard.SafeString(class)
                            local safeRole = Guard.SafeString(assignedRole)
                            if safeName then
                                local match = DB:Lookup(safeName, nil)
                                if match then
                                    found[#found + 1] = {
                                        memberIndex = m,
                                        name = safeName,
                                        class = safeClass,
                                        role = safeRole,
                                        match = match,
                                    }
                                    if match.hasBlack then
                                        hasBlack = true
                                        maxSev = math.max(maxSev, match.maxSeverity or 2)
                                    end
                                    if match.hasGreen then
                                        hasGreen = true
                                    end
                                end
                            end
                        end
                    end

                    if #found > 0 then
                        applicantMatches[applicantID] = {
                            applicantID = applicantID,
                            matches = found,
                            hasBlack = hasBlack,
                            hasGreen = hasGreen,
                            maxSeverity = maxSev,
                        }
                        if s.warnLfgApplicants then
                            for j = 1, #found do
                                local item = found[j]
                                local m = item.match
                                local shouldAlert = (m.hasBlack and (m.maxSeverity or 2) >= (s.minSeverityLfg or 1))
                                    or (m.hasGreen and s.warnGreenInGroup)
                                if shouldAlert and ShouldFireAlert("app:" .. tostring(applicantID) .. ":" .. item.name:lower()) then
                                    ns:Emit("ALERT_MATCH", {
                                        kind = "applicant",
                                        applicantID = applicantID,
                                        name = item.name,
                                        class = item.class,
                                        role = item.role,
                                        match = m,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    ns:Emit("APPLICANTS_SCANNED")
end

function Detector:InspectSearchResult(resultID)
    if not resultID or Guard.IsSecret(resultID) then return nil end
    if searchCache[resultID] ~= nil then
        return searchCache[resultID] or nil
    end
    if not _G.C_LFGList or not _G.C_LFGList.GetSearchResultInfo then return nil end

    local okInfo, info = pcall(_G.C_LFGList.GetSearchResultInfo, resultID)
    if not okInfo or not Guard.CanReadTable(info) then
        searchCache[resultID] = false
        return nil
    end

    local matches = {}
    local seenKeys = {}
    local hasBlack, hasGreen, hasLeaver = false, false, false
    local maxSev = 0

    local function CheckCandidate(rawName, classToken, role, isLeader, isLeaver)
        if isLeaver then hasLeaver = true end
        local safeName = Guard.SafeString(rawName)
        if not safeName then return end
        local key = Guard.NormalizeNameRealm(safeName)
        if not key or seenKeys[key] then return end
        seenKeys[key] = true

        local match = DB:Lookup(safeName, nil)
        if match then
            matches[#matches + 1] = {
                name = safeName,
                class = Guard.SafeString(classToken),
                role = Guard.SafeString(role),
                isLeader = (isLeader == true),
                match = match,
            }
            if match.hasBlack then
                hasBlack = true
                maxSev = math.max(maxSev, match.maxSeverity or 2)
            end
            if match.hasGreen then
                hasGreen = true
            end
        end
    end

    -- Check all named members exposed in C_LFGList.GetSearchResultPlayerInfo (Dungeons/Arenas/Skirmishes)
    local numMembers = Guard.SafeNumber(info.numMembers) or 0
    if _G.C_LFGList.GetSearchResultPlayerInfo and numMembers > 0 then
        for i = 1, numMembers do
            local okP, p = pcall(_G.C_LFGList.GetSearchResultPlayerInfo, resultID, i)
            if okP and Guard.CanReadTable(p) then
                CheckCandidate(p.name, p.classFilename, p.assignedRole, Guard.SafeBool(p.isLeader), Guard.SafeBool(p.isLeaver))
            end
        end
    end

    -- Check C_LFGList.GetSearchResultLeaderInfo (used by WoW Forever LFG listings)
    if _G.C_LFGList.GetSearchResultLeaderInfo then
        local okL, leader = pcall(_G.C_LFGList.GetSearchResultLeaderInfo, resultID)
        if okL and Guard.CanReadTable(leader) then
            CheckCandidate(
                leader.name,
                leader.classFilename or leader.class,
                leader.assignedRole,
                true,
                Guard.SafeBool(leader.isLeaver)
            )
        end
    end

    -- Fallback / ensure leaderName is always checked (critical for Raids / Custom groups)
    if info.leaderName then
        CheckCandidate(info.leaderName, nil, nil, true, false)
    end

    if #matches == 0 and not hasLeaver then
        searchCache[resultID] = false
        return nil
    end

    local res = {
        resultID = resultID,
        matches = matches,
        hasBlack = hasBlack,
        hasGreen = hasGreen,
        hasLeaver = hasLeaver,
        maxSeverity = maxSev,
    }
    searchCache[resultID] = res
    return res
end

function Detector:InvalidateSearchCache(resultID)
    if resultID then
        searchCache[resultID] = nil
    else
        wipe(searchCache)
    end
end

function Detector:Init()
    if initialized then return end
    initialized = true

    local f = CreateFrame("Frame")
    Guard.SafeRegisterEvent(f, "PLAYER_ENTERING_WORLD")
    Guard.SafeRegisterEvent(f, "GROUP_ROSTER_UPDATE")
    Guard.SafeRegisterEvent(f, "ZONE_CHANGED_NEW_AREA")
    Guard.SafeRegisterEvent(f, "LFG_LIST_APPLICANT_LIST_UPDATED")
    Guard.SafeRegisterEvent(f, "LFG_LIST_APPLICANT_UPDATED")
    Guard.SafeRegisterEvent(f, "LFG_LIST_SEARCH_RESULTS_RECEIVED")
    Guard.SafeRegisterEvent(f, "LFG_LIST_SEARCH_RESULT_UPDATED")

    local rosterQueued = false
    local function QueueRosterScan()
        if rosterQueued then return end
        rosterQueued = true
        C_Timer.After(0.25, function()
            rosterQueued = false
            Detector:ScanGroupRoster(false)
        end)
    end

    f:SetScript("OnEvent", function(_, event, arg1)
        if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
            QueueRosterScan()
        elseif event == "LFG_LIST_APPLICANT_LIST_UPDATED" or event == "LFG_LIST_APPLICANT_UPDATED" then
            Detector:ScanApplicants()
        elseif event == "LFG_LIST_SEARCH_RESULTS_RECEIVED" then
            Detector:InvalidateSearchCache()
            ns:Emit("SEARCH_RESULTS_UPDATED")
        elseif event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
            Detector:InvalidateSearchCache(arg1)
            ns:Emit("SEARCH_RESULTS_UPDATED", arg1)
        end
    end)

    -- Warn immediately when player applies to a group that contains someone on THE LIST
    if _G.C_LFGList and _G.C_LFGList.ApplyToGroup then
        hooksecurefunc(_G.C_LFGList, "ApplyToGroup", function(resultID)
            if not DB:Settings().warnLfgSearch then return end
            local res = Detector:InspectSearchResult(resultID)
            if not res or #res.matches == 0 then return end
            for i = 1, #res.matches do
                local item = res.matches[i]
                local m = item.match
                local shouldAlert = (m.hasBlack and (m.maxSeverity or 2) >= (DB:Settings().minSeverityLfg or 1))
                    or (m.hasGreen and DB:Settings().warnGreenInGroup)
                if shouldAlert and ShouldFireAlert("que:" .. tostring(resultID) .. ":" .. item.name:lower()) then
                    ns:Emit("ALERT_MATCH", {
                        kind = "queued_group",
                        resultID = resultID,
                        name = item.name,
                        class = item.class,
                        role = item.role,
                        match = m,
                    })
                end
            end
        end)
    end

    ns:On("DB_CHANGED", function()
        Detector:InvalidateSearchCache()
        Detector:ScanApplicants()
        ns:Emit("SEARCH_RESULTS_UPDATED")
    end)

    C_Timer.After(2.0, function()
        Detector:ScanGroupRoster(false)
    end)
end
