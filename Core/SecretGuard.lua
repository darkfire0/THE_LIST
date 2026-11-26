local _, ns = ...

local Guard = {}
ns.Guard = Guard

local issecret = _G.issecretvalue
local canaccesstable = _G.canaccesstable

function Guard.IsForever()
    return ns.IS_FOREVER == true
end

function Guard.SafeRegisterEvent(frame, event)
    if not (frame and frame.RegisterEvent and type(event) == "string" and event ~= "") then
        return false
    end
    local ok = pcall(frame.RegisterEvent, frame, event)
    return ok == true
end

function Guard.IsForeverGamepadUI()
    if not Guard.IsForever() then return false end
    local util = _G.InputUtil
    if util and type(util.IsGamepadUIEnabled) == "function" then
        local ok, on = pcall(util.IsGamepadUIEnabled)
        if ok and Guard.SafeBool(on) ~= nil then
            return on == true
        end
    end
    local style = _G.C_InputInterfaceStyle
    local enum = _G.Enum and _G.Enum.InputDeviceInterfaceType
    if style and style.GetCurrentStyle and enum and enum.Gamepad then
        local ok, cur = pcall(style.GetCurrentStyle)
        if ok and not Guard.IsSecret(cur) then
            return cur == enum.Gamepad
        end
    end
    local getter = (_G.C_CVar and _G.C_CVar.GetCVar) or _G.GetCVar
    if type(getter) == "function" then
        local ok, val = pcall(getter, "InputDeviceInterfaceStyle")
        if ok and not Guard.IsSecret(val) then
            return val == "1" or val == 1
        end
    end
    return false
end

function Guard.IsSecret(val)
    return issecret ~= nil and issecret(val) and true or false
end

function Guard.CanReadTable(tbl)
    if type(tbl) ~= "table" then return false end
    if Guard.IsSecret(tbl) then return false end
    if canaccesstable and not canaccesstable(tbl) then return false end
    return true
end

function Guard.SafeString(val)
    if type(val) ~= "string" then return nil end
    if Guard.IsSecret(val) then return nil end
    if val == "" then return nil end
    return val
end

Guard.VALID_CLASSES = {
    WARRIOR = true,
    PALADIN = true,
    HUNTER = true,
    ROGUE = true,
    PRIEST = true,
    DEATHKNIGHT = true,
    SHAMAN = true,
    MAGE = true,
    WARLOCK = true,
    MONK = true,
    DRUID = true,
    DEMONHUNTER = true,
    EVOKER = true,
}

function Guard.SafeClassToken(val)
    local s = Guard.SafeString(val)
    if not s or not Guard.VALID_CLASSES[s] then return nil end
    return s
end

function Guard.SafePlayerGuid(val)
    local s = Guard.SafeString(val)
    if not s or #s > 48 or not s:match("^[%w%-]+$") then
        return nil
    end
    if not Guard.IsForever() and s:sub(1, 7) ~= "Player-" then
        return nil
    end
    return s
end

function Guard.SanitizePeerText(str, maxLen)
    if type(str) ~= "string" or Guard.IsSecret(str) then return "" end
    local s = str
    s = s:gsub("|T.-|t", "")
    s = s:gsub("|A.-|a", "")
    s = s:gsub("|H.-|h", "")
    s = s:gsub("|h", "")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|K.-|k", "")
    s = s:gsub("|n", " ")
    s = s:gsub("[%c\r\n\t]", " ")
    s = s:gsub("|", "")
    s = s:match("^%s*(.-)%s*$") or ""
    if type(maxLen) == "number" and maxLen > 0 and #s > maxLen then
        s = s:sub(1, maxLen):match("^%s*(.-)%s*$") or ""
    end
    return s
end

function Guard.SafeNumber(val)
    if type(val) ~= "number" then return nil end
    if Guard.IsSecret(val) then return nil end
    return val
end

function Guard.SafeBool(val)
    if type(val) ~= "boolean" then return nil end
    if Guard.IsSecret(val) then return nil end
    return val
end

function Guard.IsUnitIdentitySecret(unit)
    if type(unit) ~= "string" or Guard.IsSecret(unit) then return true end
    if _G.C_Secrets and _G.C_Secrets.ShouldUnitIdentityBeSecret then
        local ok, res = pcall(_G.C_Secrets.ShouldUnitIdentityBeSecret, unit)
        if ok and res then return true end
    end
    return false
end

function Guard.InCommLockdown()
    if _G.C_ChatInfo and _G.C_ChatInfo.InChatMessagingLockdown then
        local ok, locked = pcall(_G.C_ChatInfo.InChatMessagingLockdown)
        if ok and Guard.SafeBool(locked) == true then return true end
    end
    return false
end

local RESTRICTION_NAMES = { "Map", "Chat", "Combat", "Encounter", "ChallengeMode", "PvPMatch" }

function Guard.GetLockdownDiagnostics()
    local diag = {
        inChatLockdown = "n/a",
        outgoingRestricted = "n/a",
        restrictions = {},
        instanceName = "",
        instanceType = "none",
    }
    if _G.C_ChatInfo then
        if _G.C_ChatInfo.InChatMessagingLockdown then
            local ok, v = pcall(_G.C_ChatInfo.InChatMessagingLockdown)
            local b = ok and Guard.SafeBool(v)
            if b ~= nil then diag.inChatLockdown = b end
        end
        if _G.C_ChatInfo.AreOutgoingAddonChatMessagesRestricted then
            local ok, v = pcall(_G.C_ChatInfo.AreOutgoingAddonChatMessagesRestricted)
            local b = ok and Guard.SafeBool(v)
            if b ~= nil then diag.outgoingRestricted = b end
        end
    end
    local enumTbl = _G.Enum and _G.Enum.AddOnRestrictionType
    local ra = _G.C_RestrictedActions
    if enumTbl and ra and ra.IsAddOnRestrictionActive then
        for i = 1, #RESTRICTION_NAMES do
            local rName = RESTRICTION_NAMES[i]
            local code = enumTbl[rName]
            if code ~= nil then
                local ok, active = pcall(ra.IsAddOnRestrictionActive, code)
                if ok and Guard.SafeBool(active) == true then
                    diag.restrictions[#diag.restrictions + 1] = rName
                end
            end
        end
    end
    if _G.GetInstanceInfo then
        local ok, iName, iType = pcall(_G.GetInstanceInfo)
        if ok then
            diag.instanceName = Guard.SafeString(iName) or ""
            diag.instanceType = Guard.SafeString(iType) or "none"
        end
    end
    return diag
end

function Guard.GetPlayerRealmNormalized()
    if _G.GetNormalizedRealmName then
        local ok, realm = pcall(_G.GetNormalizedRealmName)
        if ok and type(realm) == "string" and not Guard.IsSecret(realm) and realm ~= "" then
            return realm
        end
    end
    if _G.GetRealmName then
        local ok, realm = pcall(_G.GetRealmName)
        if ok and type(realm) == "string" and not Guard.IsSecret(realm) and realm ~= "" then
            return (realm:gsub("[%s%-']", ""))
        end
    end
    return "UnknownRealm"
end

local foreverRealmTokens = nil

local function IsPlaceholderName(name)
    return name == (_G.UNKNOWNOBJECT or "Unknown") or name == (_G.UNKNOWN or "Unknown")
end

local function GetForeverRealmTokens()
    if foreverRealmTokens then return foreverRealmTokens end
    local tokens = {}
    local function Add(val)
        local s = Guard.SafeString(val)
        if not s then return end
        local squashed = (s:gsub("[%s%-']", "")):lower()
        if squashed ~= "" then
            tokens[squashed] = true
        end
    end
    if _G.GetRealmName then
        local ok, r = pcall(_G.GetRealmName)
        if ok then Add(r) end
    end
    if _G.GetNormalizedRealmName then
        local ok, r = pcall(_G.GetNormalizedRealmName)
        if ok then Add(r) end
    end
    if next(tokens) ~= nil then
        foreverRealmTokens = tokens
    end
    return tokens
end

local function IsForeverRealmToken(val)
    local s = Guard.SafeString(val)
    if not s then return false end
    local tokens = GetForeverRealmTokens()
    if not next(tokens) then return false end
    local squashed = (s:gsub("[%s%-']", "")):lower()
    if tokens[squashed] then return true end
    local stem = squashed:match("^(.-)%d+$")
    return stem ~= nil and tokens[stem] == true
end

function Guard.NormalizeRealm(realm)
    if type(realm) ~= "string" or Guard.IsSecret(realm) then return nil end
    local trimmed = realm:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then return nil end
    -- WoW normalized realm names remove spaces, hyphens, and apostrophes
    return (trimmed:gsub("[%s%-']", ""))
end

-- Returns canonicalKey, displayName, short/firstPart, and normalizedRealm (nil on Forever)
function Guard.NormalizeNameRealm(rawName, fallbackRealm)
    if Guard.IsForever() then
        local s = Guard.SafeString(rawName)
        if not s then return nil, nil end
        s = s:match("^%s*(.-)%s*$")
        if not s or s == "" or IsPlaceholderName(s) then return nil, nil end

        local base = s:match("^([^%-]+)%-") or s
        base = base:gsub("%s+", " "):match("^%s*(.-)%s*$")
        if not base or base == "" or IsPlaceholderName(base) then return nil, nil end

        local display = base
        if not base:find(" ", 1, true) then
            local sec = Guard.SafeString(fallbackRealm)
            if sec then
                sec = sec:gsub("%s+", " "):match("^%s*(.-)%s*$")
                if sec and sec ~= "" and not IsPlaceholderName(sec) and not IsForeverRealmToken(sec) then
                    display = base .. " " .. sec
                end
            end
        end

        local key = display:lower()
        local firstPart = display:match("^(%S+)") or display
        return key, display, firstPart, nil
    end

    local s = Guard.SafeString(rawName)
    if not s then return nil, nil end
    s = s:match("^%s*(.-)%s*$")
    if not s or s == "" then return nil, nil end

    local namePart, realmPart = s:match("^([^%-]+)%-(.+)$")
    if not namePart then
        namePart = s
        realmPart = fallbackRealm or Guard.GetPlayerRealmNormalized()
    end

    namePart = namePart:match("^%s*(.-)%s*$")
    local normRealm = Guard.NormalizeRealm(realmPart) or Guard.GetPlayerRealmNormalized()
    if not namePart or namePart == "" then return nil, nil end

    local display = namePart .. "-" .. normRealm
    local key = display:lower()
    return key, display, namePart, normRealm
end

function Guard.SafeUnitInfo(unit, playersOnly)
    if type(unit) ~= "string" or Guard.IsSecret(unit) or unit == "" then return nil end
    if Guard.IsUnitIdentitySecret(unit) then return nil end
    if not _G.UnitExists then return nil end
    local okExists, exists = pcall(_G.UnitExists, unit)
    if not okExists or Guard.IsSecret(exists) or not exists then return nil end

    local isPlayer = false
    if _G.UnitIsPlayer then
        local ok, p = pcall(_G.UnitIsPlayer, unit)
        if ok then isPlayer = (Guard.SafeBool(p) == true) end
    end
    if playersOnly == true and not isPlayer then
        return nil
    end

    local isForever = Guard.IsForever()
    local name, realm
    if isForever then
        if _G.UnitName then
            local ok, n, r = pcall(_G.UnitName, unit)
            if ok then
                name, realm = Guard.SafeString(n), Guard.SafeString(r)
            end
        end
        if (not name or IsPlaceholderName(name)) and _G.UnitFullName then
            local ok, n, r = pcall(_G.UnitFullName, unit)
            if ok then
                name, realm = Guard.SafeString(n), Guard.SafeString(r)
            end
        end
    else
        if _G.UnitFullName then
            local ok, n, r = pcall(_G.UnitFullName, unit)
            if ok then
                name, realm = Guard.SafeString(n), Guard.SafeString(r)
            end
        end
        if not name and _G.UnitName then
            local ok, n, r = pcall(_G.UnitName, unit)
            if ok then
                name, realm = Guard.SafeString(n), Guard.SafeString(r)
            end
        end
    end
    if not name or IsPlaceholderName(name) then return nil end

    local key, display, firstPart = Guard.NormalizeNameRealm(name, realm)
    if not key then return nil end

    local guid
    if _G.UnitGUID then
        local ok, g = pcall(_G.UnitGUID, unit)
        if ok then guid = Guard.SafeString(g) end
    end

    local classToken
    if _G.UnitClass then
        local ok, _, cls = pcall(_G.UnitClass, unit)
        if ok then classToken = Guard.SafeString(cls) end
    end

    local outShortName = name
    local outRealm = nil
    if isForever then
        outShortName = firstPart or name
    else
        outRealm = realm or Guard.GetPlayerRealmNormalized()
    end

    return {
        key = key,
        name = display,
        shortName = outShortName,
        realm = outRealm,
        guid = guid,
        class = classToken,
        isPlayer = isPlayer,
    }
end

local cachedPlayerKey = nil

function Guard.GetPlayerKey()
    if cachedPlayerKey then return cachedPlayerKey end
    local info = Guard.SafeUnitInfo("player", true)
    if Guard.IsForever() then
        if info and info.key then
            cachedPlayerKey = info.key
            return cachedPlayerKey
        end
        return nil
    end
    if info and info.key and info.realm and info.realm ~= "UnknownRealm" and not info.key:find("%-unknownrealm$") then
        cachedPlayerKey = info.key
        return cachedPlayerKey
    end
    if _G.UnitFullName then
        local ok, n, r = pcall(_G.UnitFullName, "player")
        if ok then
            local name = Guard.SafeString(n)
            local realm = Guard.SafeString(r)
            if name then
                local resolvedRealm = realm or Guard.GetPlayerRealmNormalized()
                if resolvedRealm and resolvedRealm ~= "" and resolvedRealm ~= "UnknownRealm" then
                    local key = Guard.NormalizeNameRealm(name, resolvedRealm)
                    if key and not key:find("%-unknownrealm$") then
                        cachedPlayerKey = key
                        return cachedPlayerKey
                    end
                end
            end
        end
    end
    return info and info.key or nil
end

function Guard.GetClassRGB(classToken)
    if type(classToken) == "string" then
        if _G.EllesmereUI and _G.EllesmereUI.GetClassColor then
            local c = _G.EllesmereUI.GetClassColor(classToken)
            if c and c.r then return c.r, c.g, c.b end
        end
        if _G.C_ClassColor and _G.C_ClassColor.GetClassColor then
            local c = _G.C_ClassColor.GetClassColor(classToken)
            if c then return c.r, c.g, c.b end
        end
        if _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[classToken] then
            local c = _G.RAID_CLASS_COLORS[classToken]
            return c.r, c.g, c.b
        end
    end
    return 0.90, 0.90, 0.90
end

function Guard.FormatPlayerNameColored(rawName, cr, cg, cb)
    local ri = math.max(0, math.min(255, math.floor((cr or 0.90) * 255 + 0.5)))
    local gi = math.max(0, math.min(255, math.floor((cg or 0.90) * 255 + 0.5)))
    local bi = math.max(0, math.min(255, math.floor((cb or 0.90) * 255 + 0.5)))
    local hex = string.format("|cff%02x%02x%02x", ri, gi, bi)
    local text = tostring(rawName or "?")
    if not Guard.IsForever() and type(rawName) == "string" then
        local base, realm = rawName:match("^([^%-]+)(%-.+)$")
        if base and realm then
            return hex .. base .. "|r|cff7a7a7a" .. realm .. "|r"
        end
    end
    return hex .. text .. "|r"
end

function Guard.GetCurrentInstanceContext()
    if not _G.GetInstanceInfo then return "" end
    local ok, iName, iType = pcall(_G.GetInstanceInfo)
    if not ok then return "" end
    local instName = Guard.SafeString(iName)
    local instType = Guard.SafeString(iType)
    if not instName or not instType or instType == "none" then
        return ""
    end
    if instType == "party" and _G.C_ChallengeMode and _G.C_ChallengeMode.GetActiveKeystoneInfo then
        local okKey, level = pcall(_G.C_ChallengeMode.GetActiveKeystoneInfo)
        level = okKey and Guard.SafeNumber(level) or nil
        if level and level > 0 then
            return instName .. " +" .. tostring(level)
        end
    end
    return instName
end

local THELIST_SOUND_PATHS = {
    thelist_add   = "Interface\\AddOns\\THE_LIST\\Media\\thelist.mp3",
}

local EUI_SOUND_PATHS = {
    eui_siren     = "Interface\\AddOns\\EllesmereUI\\media\\sounds\\WarningSiren.ogg",
    eui_airhorn   = "Interface\\AddOns\\EllesmereUI\\media\\sounds\\AirHorn.ogg",
    eui_sonar     = "Interface\\AddOns\\EllesmereUI\\media\\sounds\\Sonar.ogg",
    eui_waterdrop = "Interface\\AddOns\\EllesmereUI\\media\\sounds\\WaterDrop.ogg",
    eui_phone     = "Interface\\AddOns\\EllesmereUI\\media\\sounds\\Phone.ogg",
    eui_kaching   = "Interface\\AddOns\\EllesmereUI\\media\\sounds\\Kaching.ogg",
}

function Guard.PlayAlertSound(soundKey)
    if not soundKey or soundKey == "none" then return end
    local localPath = THELIST_SOUND_PATHS[soundKey]
    if localPath then
        if _G.PlaySoundFile then
            pcall(_G.PlaySoundFile, localPath, "Master")
        end
        return
    end
    local euiPath = EUI_SOUND_PATHS[soundKey]
    if euiPath and _G.PlaySoundFile then
        if _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded and _G.C_AddOns.IsAddOnLoaded("EllesmereUI") then
            local ok = pcall(_G.PlaySoundFile, euiPath, "Master")
            if ok then return end
        end
        -- Fallback to Blizzard sound if EUI isn't loaded
        soundKey = (soundKey == "eui_kaching") and "blizz_ready" or "blizz_raidwarn"
    end
    if not _G.PlaySound or not _G.SOUNDKIT then return end
    if soundKey == "blizz_raidwarn" and _G.SOUNDKIT.RAID_WARNING then
        pcall(_G.PlaySound, _G.SOUNDKIT.RAID_WARNING, "Master")
    elseif soundKey == "blizz_ready" and _G.SOUNDKIT.READY_CHECK then
        pcall(_G.PlaySound, _G.SOUNDKIT.READY_CHECK, "Master")
    elseif soundKey == "blizz_bnet" and _G.SOUNDKIT.UI_BNET_TOAST then
        pcall(_G.PlaySound, _G.SOUNDKIT.UI_BNET_TOAST, "Master")
    end
end

function Guard.FormatRole(role)
    if role == "TANK" then return "Tank" end
    if role == "HEALER" then return "Healer" end
    if role == "DAMAGER" or role == "DPS" then return "DPS" end
    return "Member"
end

function Guard.FormatRelativeTime(ts)
    if type(ts) ~= "number" or ts <= 0 then return "Unknown" end
    local now = time()
    local diff = math.max(0, now - ts)
    if diff < 60 then return "Just now" end
    if diff < 3600 then return math.floor(diff / 60) .. "m ago" end
    if diff < 86400 then return math.floor(diff / 3600) .. "h ago" end
    if diff < 2592000 then return math.floor(diff / 86400) .. "d ago" end
    return date("%Y-%m-%d", ts)
end
