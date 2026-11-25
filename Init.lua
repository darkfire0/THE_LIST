local _, ns = ...

local DB = ns.DB
local Sync = ns.Sync
local Detector = ns.Detector
local Hooks = ns.Hooks
local Theme = ns.Theme
local AlertBanner = ns.AlertBanner
local PluginPages = ns.PluginPages
local StandaloneUI = ns.StandaloneUI

function ns.OpenUI(moduleKey, pageName)
    if InCombatLockdown() then
        ns.Print("Cannot open THE LIST panel during combat.")
        return
    end
    if _G.EllesmereUI and _G.EllesmereUI.OpenPlugin then
        if PluginPages:Open(moduleKey, pageName) then
            return
        end
    end
    StandaloneUI:Toggle()
end

-- Addon Compartment callbacks (WoW 10.1+ / 12.1.5 minimap compartment)
function _G.TheList_OnAddonCompartmentClick(_, buttonName)
    if buttonName == "RightButton" then
        ns.QuickModal:Open()
    else
        ns.OpenUI()
    end
end

function _G.TheList_OnAddonCompartmentEnter(_, menuButton)
    if not _G.GameTooltip then return end
    _G.GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
    _G.GameTooltip:ClearLines()
    local goodHex = Theme:GetGoodHex()
    local gr, gg, gb = Theme:GetGoodRGB()
    _G.GameTooltip:AddLine("|cffff4d4dTHE|r " .. goodHex .. "LIST|r")
    local counts = DB:GetCounts()
    _G.GameTooltip:AddLine(string.format("Personal: %d Bad Bois / %d Good Bois", counts.myBlack, counts.myGreen), 0.9, 0.9, 0.9)
    _G.GameTooltip:AddLine(string.format("Synced (%d peers): %d Bad Bois / %d Good Bois", counts.peerCount, counts.peerBlack, counts.peerGreen), 0.7, 0.85, 1.0)
    _G.GameTooltip:AddLine(" ")
    _G.GameTooltip:AddLine("Left-click: Open THE LIST", gr, gg, gb)
    _G.GameTooltip:AddLine("Right-click: Quick Add Player", gr, gg, gb)
    _G.GameTooltip:Show()
end

function _G.TheList_OnAddonCompartmentLeave()
    if _G.GameTooltip then _G.GameTooltip:Hide() end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_LOGIN")

boot:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ns.ADDON_NAME then
        DB:Init()
        Theme:Init()
        PluginPages:Register()
        StandaloneUI:Init()
        StandaloneUI:RegisterBlizzardSettings()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        DB:RefreshMyLabel()
        AlertBanner:Init()
        Detector:Init()
        Hooks:Init()
        Sync:Init()
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)

SLASH_THELIST1 = "/thelist"
SLASH_THELIST2 = "/list"
SLASH_THELIST3 = "/tl"
SlashCmdList.THELIST = function(msg)
    local raw = type(msg) == "string" and msg or ""
    local cmd = raw:lower():match("^%s*(.-)%s*$") or ""
    local arg = raw:match("^%s*[Aa][Dd][Dd]%s+(.-)%s*$")
    if arg and arg ~= "" then
        ns.QuickModal:Open({
            name = arg,
            listType = ns.LIST_BLACK,
        })
    elseif cmd == "add" then
        local info = ns.Guard.SafeUnitInfo("target", true)
        ns.QuickModal:Open({
            name = info and info.name or nil,
            guid = info and info.guid or nil,
            class = info and info.class or nil,
            listType = ns.LIST_BLACK,
        })
    elseif cmd == "syncdebug" or cmd == "sync debug" then
        Sync:PrintDebugStatus()
    elseif cmd == "sync" then
        local status = Sync:SyncNow()
        ns.Print(Sync:FormatSyncStatus(status))
    else
        local syncArg = raw:match("^%s*[Ss][Yy][Nn][Cc]%s+(.-)%s*$")
        if syncArg and syncArg ~= "" then
            local status = Sync:SyncWithPlayer(syncArg)
            ns.Print(Sync:FormatSyncStatus(status))
        elseif cmd == "test" then
            AlertBanner:ShowTestAlert()
        elseif cmd == "settings" then
            ns.OpenUI("Main", "Settings & Sync")
        else
            ns.OpenUI()
        end
    end
end
