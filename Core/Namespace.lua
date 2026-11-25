local ADDON_NAME, ns = ...

_G.THE_LIST = ns

ns.ADDON_NAME  = ADDON_NAME or "THE_LIST"
ns.DISPLAY_NAME = "THE LIST"
ns.VERSION     = "1.1.3"
ns.COMM_PREFIX = "THELIST1"
ns.PROTOCOL_V  = 1

local function DetectClientFlavor()
    local rawToc = _G.GetBuildInfo and select(4, _G.GetBuildInfo())
    local toc = tonumber(rawToc) or 0
    local proj = _G.WOW_PROJECT_ID
    local isClassicExplicit = (_G.WOW_PROJECT_CLASSIC ~= nil and proj == _G.WOW_PROJECT_CLASSIC)
    local isForever = (not isClassicExplicit)
        and ((_G.WOW_PROJECT_CAMELOT ~= nil and proj == _G.WOW_PROJECT_CAMELOT)
            or (toc >= 16000 and toc < 17000))
    return toc, isForever
end

ns.TOC_VERSION, ns.IS_FOREVER = DetectClientFlavor()

ns.LIST_BLACK  = "black"
ns.LIST_GREEN  = "green"

ns.CATEGORIES = {
    black = {
        "Leaver",
        "Toxic",
        "Ninja",
        "AFK",
        "Low Effort",
        "Scammer",
        "Other",
    },
    green = {
        "Reliable",
        "Clutch",
        "Friendly",
        "Good Lead",
        "Carry",
        "Other",
    },
}

ns.SEVERITY_LABELS = {
    [1] = "Note",
    [2] = "Warn",
    [3] = "Hard Avoid",
}

ns.SOUND_PRESETS = {
    none            = "None (Silent)",
    eui_siren       = "EUI: Siren",
    eui_airhorn     = "EUI: Air Horn",
    eui_sonar       = "EUI: Sonar",
    eui_waterdrop   = "EUI: Water Drop",
    eui_phone       = "EUI: Phone",
    eui_kaching     = "EUI: Ka-Ching",
    blizz_raidwarn  = "Raid Warning",
    blizz_ready     = "Ready Check",
    blizz_bnet      = "BNet Toast",
}

ns.SOUND_ORDER = {
    "none",
    "eui_siren",
    "eui_airhorn",
    "eui_sonar",
    "eui_waterdrop",
    "eui_phone",
    "eui_kaching",
    "blizz_raidwarn",
    "blizz_ready",
    "blizz_bnet",
}

ns.ADD_SOUND_PRESETS = {
    thelist_add     = "THE LIST (thelist.mp3)",
    none            = "None (Silent)",
    eui_siren       = "EUI: Siren",
    eui_airhorn     = "EUI: Air Horn",
    eui_sonar       = "EUI: Sonar",
    eui_waterdrop   = "EUI: Water Drop",
    eui_phone       = "EUI: Phone",
    eui_kaching     = "EUI: Ka-Ching",
    blizz_raidwarn  = "Raid Warning",
    blizz_ready     = "Ready Check",
    blizz_bnet      = "BNet Toast",
}

ns.ADD_SOUND_ORDER = {
    "thelist_add",
    "none",
    "eui_siren",
    "eui_airhorn",
    "eui_sonar",
    "eui_waterdrop",
    "eui_phone",
    "eui_kaching",
    "blizz_raidwarn",
    "blizz_ready",
    "blizz_bnet",
}

ns.DEFAULTS = {
    settings = {
        -- Detection & Warnings
        warnGroupRoster      = true,
        warnGreenInGroup     = true,
        warnLfgApplicants    = true,
        warnLfgSearch        = true,
        warnTooltips         = true,
        warnChatSummary      = true,
        warnBanner           = true,
        minSeverityGroup     = 1,
        minSeverityLfg       = 1,
        includePeerMatches   = true,
        dedupeCooldownSec    = 180,
        addRightClickMenu    = true,
        captureRecent        = true,
        maxRecent            = 80,

        -- Native Blizzard Ignore Mirror
        autoNativeIgnore     = false,

        -- Sync
        syncEnabled          = true,
        syncBNet             = true,
        syncGuild            = true,
        syncParty            = false,
        syncRelay            = true,
        trustMode            = "friends_and_guild", -- "friends_and_guild" | "bnet_only" | "guild_only"
        syncGreenEntries     = true,
        autoSyncOnLogin      = true,

        -- Banner & Sound
        bannerDuration       = 7,
        bannerScale          = 1.15,
        addBadSound          = "thelist_add",
        blackSound           = "eui_siren",
        greenSound           = "none",
        testBannerCount      = 0,
    },
}

-- Lightweight internal pub/sub event bus
local listeners = {}

function ns:On(eventName, fn)
    if type(eventName) ~= "string" or type(fn) ~= "function" then return end
    if not listeners[eventName] then
        listeners[eventName] = {}
    end
    local list = listeners[eventName]
    list[#list + 1] = fn
end

function ns:Emit(eventName, ...)
    local list = listeners[eventName]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok and ns.DebugLog then
            ns.DebugLog("Event error [" .. tostring(eventName) .. "]: " .. tostring(err))
        end
    end
end

function ns.Print(msg)
    if DEFAULT_CHAT_FRAME then
        local goodHex = (ns.Theme and ns.Theme.GetGoodHex and ns.Theme:GetGoodHex()) or "|cff3ec8ec"
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4d4dTHE|r " .. goodHex .. "LIST|r: " .. tostring(msg))
    end
end
