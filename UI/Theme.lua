local _, ns = ...

local Theme = {}
ns.Theme = Theme

local Guard = ns.Guard

-- Canonical EllesmereUI palette tokens (measured from EllesmereUI.lua)
Theme.BG_PANEL    = { r = 0.069, g = 0.058, b = 0.047 }
Theme.BG_POPUP    = { r = 0.077, g = 0.068, b = 0.058 }
Theme.BG_BTN      = { r = 0.089, g = 0.080, b = 0.072 }
Theme.BG_DD       = { r = 0.103, g = 0.095, b = 0.088 }
Theme.BG_INPUT    = { r = 0.030, g = 0.023, b = 0.018 }
Theme.DEFAULT_ACC = { r = 12 / 255, g = 210 / 255, b = 157 / 255 } -- #0CD29D
Theme.COLOR_BLACK = { r = 1.0, g = 0.30, b = 0.30 }
Theme.COLOR_GREEN = { r = 12 / 255, g = 210 / 255, b = 157 / 255 }
Theme.ROW_ODD_A   = 0.10
Theme.ROW_EVEN_A  = 0.20

local skinRef = nil
local skinLookCallbacks = {}

function Theme:HasEUI()
    return _G.EllesmereUI ~= nil
end

function Theme:HasEUIWidgets()
    return _G.EllesmereUI ~= nil and _G.EllesmereUI.Widgets ~= nil
end

function Theme:GetAccent()
    if skinRef and skinRef.GetAccentColor then
        local r, g, b = skinRef.GetAccentColor()
        if r then return r, g, b end
    end
    local eui = _G.EllesmereUI
    if eui and eui.GetAccentColor then
        local r, g, b = eui.GetAccentColor()
        if r then return r, g, b end
    end
    if eui and eui.ELLESMERE_GREEN then
        local c = eui.ELLESMERE_GREEN
        return c.r, c.g, c.b
    end
    return Theme.DEFAULT_ACC.r, Theme.DEFAULT_ACC.g, Theme.DEFAULT_ACC.b
end

function Theme:GetGoodRGB()
    return self:GetAccent()
end

function Theme:GetGoodHex()
    local r, g, b = self:GetGoodRGB()
    local ri = math.max(0, math.min(255, math.floor((r or 0.24) * 255 + 0.5)))
    local gi = math.max(0, math.min(255, math.floor((g or 0.78) * 255 + 0.5)))
    local bi = math.max(0, math.min(255, math.floor((b or 0.93) * 255 + 0.5)))
    return string.format("|cff%02x%02x%02x", ri, gi, bi)
end

function Theme:GetBadRGB()
    return Theme.COLOR_BLACK.r, Theme.COLOR_BLACK.g, Theme.COLOR_BLACK.b
end

function Theme:GetBadHex()
    return "|cffff4d4d"
end

function Theme:GetFont()
    if skinRef and skinRef.GetFont then
        local path, flags = skinRef.GetFont()
        if path then return path, flags or "" end
    end
    local eui = _G.EllesmereUI
    if eui and eui.GetFontPath then
        local path = eui.GetFontPath()
        local flags = eui.GetFontOutlineFlag and eui.GetFontOutlineFlag() or ""
        if path then return path, flags end
    end
    if eui and eui.EXPRESSWAY then
        return eui.EXPRESSWAY, ""
    end
    return _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", ""
end

function Theme:SolidTex(parent, layer, r, g, b, a)
    local eui = _G.EllesmereUI
    if eui and eui.SolidTex then
        return eui.SolidTex(parent, layer, r, g, b, a)
    end
    local tex = parent:CreateTexture(nil, layer or "BACKGROUND")
    tex:SetColorTexture(r or 0, g or 0, b or 0, a or 1)
    return tex
end

function Theme:MakeFont(parent, size, flags, r, g, b, a)
    local fontPath, defaultFlags = self:GetFont()
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(fontPath, size or 12, flags or defaultFlags or "")
    fs:SetTextColor(r or 1, g or 1, b or 1, a or 1)
    return fs
end

function Theme:MakeBorder(frame, r, g, b, a, bgTex)
    local eui = _G.EllesmereUI
    if eui and eui.MakeRoundedBorder then
        return eui.MakeRoundedBorder(frame, r, g, b, a, bgTex)
    end
    local top = frame:CreateTexture(nil, "BORDER")
    local bot = frame:CreateTexture(nil, "BORDER")
    local left = frame:CreateTexture(nil, "BORDER")
    local right = frame:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(1)
    bot:SetPoint("BOTTOMLEFT"); bot:SetPoint("BOTTOMRIGHT"); bot:SetHeight(1)
    left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT"); left:SetWidth(1)
    right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT"); right:SetWidth(1)

    local edges = { top, bot, left, right }
    local brd = {}
    function brd:SetColor(nr, ng, nb, na)
        for i = 1, 4 do
            edges[i]:SetColorTexture(nr, ng, nb, na or 1)
        end
    end
    function brd:Fit() end
    brd:SetColor(r or 1, g or 1, b or 1, a or 0.15)
    return brd
end

function Theme:MakeButton(parent, text, w, h, fontSize, onClick, accentBorder)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(w or 100, h or 28)

    local bg = self:SolidTex(btn, "BACKGROUND", Theme.BG_BTN.r, Theme.BG_BTN.g, Theme.BG_BTN.b, 0.72)
    bg:SetAllPoints()

    local brdR, brdG, brdB, brdA = 1, 1, 1, 0.24
    if accentBorder == "accent" or accentBorder == "green" then
        brdR, brdG, brdB = self:GetGoodRGB()
        brdA = 0.70
    elseif accentBorder == "red" then
        brdR, brdG, brdB, brdA = Theme.COLOR_BLACK.r, Theme.COLOR_BLACK.g, Theme.COLOR_BLACK.b, 0.70
    end

    local brd = self:MakeBorder(btn, brdR, brdG, brdB, brdA, bg)
    local baseLblAlpha = accentBorder and 0.95 or 0.72
    local lbl = self:MakeFont(btn, fontSize or 12, "", 1, 1, 1, baseLblAlpha)
    lbl:SetPoint("CENTER")
    lbl:SetText(text or "")

    btn._bg = bg
    btn._brd = brd
    btn._lbl = lbl
    btn._baseBrd = { brdR, brdG, brdB, brdA }
    btn._baseLblAlpha = baseLblAlpha

    btn:SetScript("OnEnter", function(self)
        local c = self._baseBrd
        self._bg:SetColorTexture(Theme.BG_BTN.r, Theme.BG_BTN.g, Theme.BG_BTN.b, 0.92)
        self._brd:SetColor(c[1], c[2], c[3], math.min(1, c[4] + 0.25))
        self._lbl:SetTextColor(1, 1, 1, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        local c = self._baseBrd
        self._bg:SetColorTexture(Theme.BG_BTN.r, Theme.BG_BTN.g, Theme.BG_BTN.b, 0.72)
        self._brd:SetColor(c[1], c[2], c[3], c[4])
        self._lbl:SetTextColor(1, 1, 1, self._baseLblAlpha or 0.72)
    end)
    btn:SetScript("OnClick", function(self)
        if onClick then onClick(self) end
    end)

    return btn
end

function Theme:MakeEditBox(parent, w, h, placeholderText, multiline)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(w or 220, h or 28)
    holder:EnableMouse(true)

    local bg = self:SolidTex(holder, "BACKGROUND", 0, 0, 0, 0.45)
    bg:SetAllPoints()
    local brd = self:MakeBorder(holder, 1, 1, 1, 0.14, bg)

    local box = CreateFrame("EditBox", nil, holder)
    box:SetAutoFocus(false)
    box:SetMultiLine(multiline == true)
    box:SetFont(self:GetFont(), 12, "")
    box:SetTextColor(1, 1, 1, 0.92)
    if multiline then
        box:SetPoint("TOPLEFT", holder, "TOPLEFT", 10, -8)
        box:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -10, 8)
    else
        box:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        box:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
        box:SetTextInsets(10, 10, 0, 0)
        box:SetJustifyH("LEFT")
    end

    local ph = self:MakeFont(box, 11, "", 0.6, 0.6, 0.6, 0.55)
    if multiline then
        ph:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
    else
        ph:SetPoint("LEFT", box, "LEFT", 10, 0)
    end
    ph:SetText(placeholderText or "")
    holder:SetScript("OnMouseDown", function() box:SetFocus() end)

    box:SetScript("OnTextChanged", function(self)
        ph:SetShown((self:GetText() or "") == "")
    end)
    box:SetScript("OnEditFocusGained", function()
        local r, g, b = Theme:GetAccent()
        brd:SetColor(r, g, b, 0.75)
    end)
    box:SetScript("OnEditFocusLost", function()
        brd:SetColor(1, 1, 1, 0.14)
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    holder.editBox = box
    holder.placeholder = ph
    holder.border = brd
    return holder, box
end

function Theme:ShowTooltip(anchor, title, bodyLines, titleColor)
    local eui = _G.EllesmereUI
    if eui and eui.ShowWidgetTooltip and not bodyLines then
        eui.ShowWidgetTooltip(anchor, title)
        return
    end
    if not _G.GameTooltip then return end
    _G.GameTooltip:SetOwner(anchor, "ANCHOR_TOP")
    _G.GameTooltip:ClearLines()
    local r, g, b
    if type(titleColor) == "table" then
        r = titleColor.r or titleColor[1] or 0.96
        g = titleColor.g or titleColor[2] or 0.96
        b = titleColor.b or titleColor[3] or 0.96
    else
        r, g, b = self:GetAccent()
    end
    _G.GameTooltip:AddLine(title or "", r, g, b)
    if type(bodyLines) == "table" then
        for i = 1, #bodyLines do
            local line = bodyLines[i]
            if type(line) == "table" then
                _G.GameTooltip:AddLine(line.text or "", line.r or 0.9, line.g or 0.9, line.b or 0.9, true)
            else
                _G.GameTooltip:AddLine(tostring(line), 0.9, 0.9, 0.9, true)
            end
        end
    end
    _G.GameTooltip:Show()
end

function Theme:HideTooltip()
    local eui = _G.EllesmereUI
    if eui and eui.HideWidgetTooltip then
        eui.HideWidgetTooltip()
    end
    if _G.GameTooltip then
        _G.GameTooltip:Hide()
    end
end

local function ApplyColorPrefix(text, color)
    local t = tostring(text or "")
    if type(color) ~= "table" then return t end
    local r = color.r or color[1] or 1
    local g = color.g or color[2] or 1
    local b = color.b or color[3] or 1
    local ri = math.max(0, math.min(255, math.floor(r * 255 + 0.5)))
    local gi = math.max(0, math.min(255, math.floor(g * 255 + 0.5)))
    local bi = math.max(0, math.min(255, math.floor(b * 255 + 0.5)))
    return string.format("|cff%02x%02x%02x%s|r", ri, gi, bi, t)
end

local function BuildEUIContextItems(items)
    local out = {}
    for i = 1, #items do
        local item = items[i]
        if item == "---" then
            out[#out + 1] = "---"
        elseif type(item) == "table" then
            local disabledFn = item.isDisabled
            if item.isTitle and not disabledFn then
                disabledFn = function() return true end
            end
            local entry = {
                text = ApplyColorPrefix(item.text, item.color),
                noLoc = true,
                onClick = item.onClick,
                isDisabled = disabledFn,
                isActive = item.isActive,
                desc = item.desc,
                tooltip = item.tooltip,
            }
            if type(item.children) == "table" then
                entry.children = BuildEUIContextItems(item.children)
            end
            out[#out + 1] = entry
        end
    end
    return out
end

local function PopulateBlizzardMenu(root, items)
    for i = 1, #items do
        local item = items[i]
        if item == "---" then
            if root.CreateDivider then root:CreateDivider() end
        elseif type(item) == "table" then
            local text = ApplyColorPrefix(item.text, item.color)
            if item.isTitle and root.CreateTitle then
                root:CreateTitle(text)
            elseif type(item.children) == "table" and root.CreateButton then
                local sub = root:CreateButton(text)
                PopulateBlizzardMenu(sub, item.children)
            elseif root.CreateButton then
                local disabled = item.isDisabled and item.isDisabled()
                local btn = root:CreateButton(text, function()
                    if not disabled and item.onClick then
                        item.onClick()
                    end
                end)
                if disabled and btn and btn.SetEnabled then
                    btn:SetEnabled(false)
                end
            end
        end
    end
end

function Theme:ShowContextMenu(anchor, items, opts)
    if type(items) ~= "table" or #items == 0 then return false end
    local eui = _G.EllesmereUI
    if eui and eui.ShowContextMenu then
        local euiItems = BuildEUIContextItems(items)
        local ok = pcall(eui.ShowContextMenu, anchor, euiItems, opts)
        if ok then return true end
    end
    if _G.MenuUtil and _G.MenuUtil.CreateContextMenu then
        local owner = anchor or _G.UIParent
        local ok = pcall(_G.MenuUtil.CreateContextMenu, owner, function(_, root)
            PopulateBlizzardMenu(root, items)
        end)
        if ok then return true end
    end
    return false
end

local localEscapeFrames = setmetatable({}, { __mode = "k" })
local localEscapeCombatFrame = nil

local function IsEscapePropRestricted()
    return type(_G.InCombatLockdown) == "function" and _G.InCombatLockdown() == true
end

local function SetLocalEscapeProp(owner, propagate)
    if not owner or type(owner.SetPropagateKeyboardInput) ~= "function" then
        return false
    end
    if IsEscapePropRestricted() then
        if propagate then
            owner._tlRestoreEscapeProp = true
        end
        return false
    end
    owner:SetPropagateKeyboardInput(propagate)
    if propagate then
        owner._tlRestoreEscapeProp = nil
    end
    return true
end

local function EnsureLocalEscapeCombatListener()
    if localEscapeCombatFrame or type(_G.CreateFrame) ~= "function" then return end
    local f = _G.CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function()
        if IsEscapePropRestricted() then return end
        for owner in pairs(localEscapeFrames) do
            if owner._tlRestoreEscapeProp then
                SetLocalEscapeProp(owner, true)
            end
        end
    end)
    localEscapeCombatFrame = f
end

function Theme:RegisterEscapeClose(frame, globalName, onClose)
    if not (Guard and Guard.IsForever and Guard.IsForever()) then
        if type(globalName) ~= "string" or globalName == "" or type(_G.UISpecialFrames) ~= "table" then
            return false
        end
        for i = 1, #_G.UISpecialFrames do
            if _G.UISpecialFrames[i] == globalName then return true end
        end
        _G.UISpecialFrames[#_G.UISpecialFrames + 1] = globalName
        return true
    end

    if not frame then return false end
    if frame._tlLocalEscInstalled then return true end
    if type(frame.EnableKeyboard) ~= "function"
        or type(frame.SetPropagateKeyboardInput) ~= "function"
        or type(frame.HookScript) ~= "function"
    then
        return false
    end

    frame._tlLocalEscInstalled = true
    localEscapeFrames[frame] = true
    EnsureLocalEscapeCombatListener()

    frame:EnableKeyboard(true)
    SetLocalEscapeProp(frame, true)
    frame:HookScript("OnShow", function(owner)
        SetLocalEscapeProp(owner, true)
    end)
    frame:HookScript("OnKeyDown", function(owner, key)
        if key ~= "ESCAPE" then return end
        if not IsEscapePropRestricted() then
            SetLocalEscapeProp(owner, false)
            if _G.C_Timer and _G.C_Timer.After then
                _G.C_Timer.After(0, function() SetLocalEscapeProp(owner, true) end)
            else
                SetLocalEscapeProp(owner, true)
            end
        end
        if type(onClose) == "function" then
            onClose(owner)
        elseif owner.Hide then
            owner:Hide()
        end
    end)
    return true
end

function Theme:OnLooksChanged(fn)
    if type(fn) ~= "function" then return end
    skinLookCallbacks[#skinLookCallbacks + 1] = fn
end

function Theme:GetSkinFacade()
    return skinRef
end

function Theme:Init()
    local eui = _G.EllesmereUI
    if eui and eui.RegisterSkin then
        eui.RegisterSkin(ns.ADDON_NAME, function(S)
            skinRef = S
            if S.OnLooksChanged then
                S.OnLooksChanged(function()
                    for i = 1, #skinLookCallbacks do
                        pcall(skinLookCallbacks[i])
                    end
                end)
            end
        end)
    end
    if eui and eui.RegAccent then
        eui.RegAccent({
            type = "callback",
            fn = function()
                for i = 1, #skinLookCallbacks do
                    pcall(skinLookCallbacks[i])
                end
            end,
        })
    end
end
