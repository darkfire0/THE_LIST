local _, ns = ...

local Modal = {}
ns.QuickModal = Modal

local Guard = ns.Guard
local DB = ns.DB
local Theme = ns.Theme

local MODAL_W = 500
local MODAL_H_BLACK = 472
local MODAL_H_GREEN = 418

local dimmer, popup
local state = {
    listType = ns.LIST_BLACK,
    category = "Leaver",
    severity = 2,
    share = true,
    nativeIgnore = false,
    guid = nil,
    class = nil,
    editingKey = nil,
}

local ui = {}

local function CloseModal()
    if dimmer then dimmer:Hide() end
end

local function RefreshModeColors()
    local isGreen = (state.listType == ns.LIST_GREEN)
    local gr, gg, gb = Theme:GetGoodRGB()
    local br, bgc, bb = Theme:GetBadRGB()
    local r, g, b
    if isGreen then
        r, g, b = gr, gg, gb
    else
        r, g, b = br, bgc, bb
    end

    if popup then
        popup:SetHeight(isGreen and MODAL_H_GREEN or MODAL_H_BLACK)
        if popup._brd and popup._brd.Fit then popup._brd:Fit() end
        if popup._topAccent then
            popup._topAccent:SetColorTexture(r, g, b, 0.95)
        end
    end

    if ui.blackTab then
        local alpha = not isGreen and 1 or 0.5
        ui.blackTab._baseBrd = not isGreen and { br, bgc, bb, 0.9 } or { 1, 1, 1, 0.16 }
        ui.blackTab._baseLblAlpha = alpha
        ui.blackTab._brd:SetColor(unpack(ui.blackTab._baseBrd))
        ui.blackTab._lbl:SetTextColor(1, 1, 1, alpha)
    end
    if ui.greenTab then
        local alpha = isGreen and 1 or 0.5
        ui.greenTab._baseBrd = isGreen and { gr, gg, gb, 0.9 } or { 1, 1, 1, 0.16 }
        ui.greenTab._baseLblAlpha = alpha
        ui.greenTab._brd:SetColor(unpack(ui.greenTab._baseBrd))
        ui.greenTab._lbl:SetTextColor(1, 1, 1, alpha)
    end

    local cats = ns.CATEGORIES[state.listType] or ns.CATEGORIES.black
    local catValid = false
    for i = 1, #cats do
        if cats[i] == state.category then catValid = true; break end
    end
    if not catValid then state.category = cats[1] end

    for i = 1, #ui.catButtons do
        local btn = ui.catButtons[i]
        local cat = cats[i]
        if cat then
            btn._cat = cat
            btn._lbl:SetText(cat)
            local active = (cat == state.category)
            local alpha = active and 1 or 0.65
            btn._baseBrd = active and { r, g, b, 0.9 } or { 1, 1, 1, 0.16 }
            btn._baseLblAlpha = alpha
            btn._brd:SetColor(unpack(btn._baseBrd))
            btn._lbl:SetTextColor(1, 1, 1, alpha)
            btn:Show()
        else
            btn:Hide()
        end
    end

    for sev = 1, 3 do
        local btn = ui.sevButtons[sev]
        if isGreen then
            btn:Hide()
        else
            btn:Show()
            local active = (state.severity == sev)
            local alpha = active and 1 or 0.65
            btn._baseBrd = active and { r, g, b, 0.9 } or { 1, 1, 1, 0.16 }
            btn._baseLblAlpha = alpha
            btn._brd:SetColor(unpack(btn._baseBrd))
            btn._lbl:SetTextColor(1, 1, 1, alpha)
        end
    end
    if ui.sevLabel then ui.sevLabel:SetShown(not isGreen) end

    if ui.sharedLabel and ui.catLabel and ui.sevLabel then
        ui.sharedLabel:ClearAllPoints()
        if isGreen then
            ui.sharedLabel:SetPoint("TOPLEFT", ui.catLabel, "BOTTOMLEFT", 0, -68)
        else
            ui.sharedLabel:SetPoint("TOPLEFT", ui.sevLabel, "BOTTOMLEFT", 0, -40)
        end
    end

    if ui.shareChk then
        ui.shareChk._setChecked(state.share)
    end
    if ui.ignoreChk then
        ui.ignoreChk:SetShown(not isGreen)
        ui.ignoreChk._setChecked(state.nativeIgnore)
    end
end

local function MakeMiniToggleRow(parent, labelText, initial, onToggle)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(222, 22)
    local box = CreateFrame("Frame", nil, row)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", row, "LEFT", 0, 0)
    local bbg = Theme:SolidTex(box, "BACKGROUND", 0.112, 0.105, 0.098, 1)
    bbg:SetAllPoints()
    local bbrd = Theme:MakeBorder(box, 1, 1, 1, 0.2, bbg)
    local ar, ag, ab = Theme:GetAccent()
    local chk = Theme:SolidTex(box, "OVERLAY", ar, ag, ab, 1)
    chk:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3)
    chk:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)

    local lbl = Theme:MakeFont(row, 11, "", 1, 1, 1, 0.88)
    lbl:SetPoint("LEFT", box, "RIGHT", 8, 0)
    lbl:SetText(labelText)

    local checked = initial == true
    local function SetChecked(val)
        checked = (val == true)
        chk:SetShown(checked)
        local r, g, b = Theme:GetAccent()
        chk:SetColorTexture(r, g, b, 1)
        bbrd:SetColor(checked and r or 1, checked and g or 1, checked and b or 1, checked and 0.65 or 0.2)
    end
    row._setChecked = SetChecked
    SetChecked(checked)

    row:SetScript("OnClick", function()
        SetChecked(not checked)
        if onToggle then onToggle(checked) end
    end)
    return row
end

local function UpdateCharCounters()
    if ui.sharedCounter and ui.sharedBox then
        local len = #(ui.sharedBox:GetText() or "")
        ui.sharedCounter:SetText(len .. "/280")
        if len >= 260 then
            ui.sharedCounter:SetTextColor(1, 0.72, 0.30, 0.90)
        else
            ui.sharedCounter:SetTextColor(1, 1, 1, 0.45)
        end
    end
    if ui.privCounter and ui.privBox then
        local len = #(ui.privBox:GetText() or "")
        ui.privCounter:SetText(len .. "/280")
        if len >= 260 then
            ui.privCounter:SetTextColor(1, 0.72, 0.30, 0.90)
        else
            ui.privCounter:SetTextColor(1, 1, 1, 0.45)
        end
    end
end

local function UpdateNameHint()
    if not (ui.nameHint and ui.nameBox) then return end
    local raw = ui.nameBox:GetText() or ""
    local key = Guard.NormalizeNameRealm(raw)
    if key and key ~= state.editingKey then
        local m = DB:Lookup(raw, nil, false)
        local personal = m and m.personal
        if personal then
            local isGreen = (personal.listType == ns.LIST_GREEN)
            local listName = isGreen and "Good Bois" or "Bad Bois"
            if isGreen then
                local gr, gg, gb = Theme:GetGoodRGB()
                ui.nameHint:SetTextColor(gr, gg, gb, 0.95)
            else
                local br, bg, bb = Theme:GetBadRGB()
                ui.nameHint:SetTextColor(br, bg, bb, 0.95)
            end
            ui.nameHint:SetText("Already on " .. listName .. " — saving will update")
            ui.nameHint:Show()
            return
        end
    end
    ui.nameHint:Hide()
end

local function EnsureModalBuilt()
    if popup then return end

    local eui = _G.EllesmereUI
    if eui and eui.BuildPopupShell then
        dimmer, popup = eui.BuildPopupShell("TheListQuickModal", {
            w = MODAL_W,
            h = MODAL_H_BLACK,
            bump = 1.15,
            clamp = true,
            dimAlpha = 0.45,
            onEscape = CloseModal,
            onDimmerDown = CloseModal,
        })
    else
        dimmer = CreateFrame("Frame", "TheListQuickModalDimmer", UIParent)
        dimmer:SetFrameStrata("FULLSCREEN_DIALOG")
        dimmer:SetAllPoints(UIParent)
        dimmer:EnableMouse(true)
        dimmer:SetScript("OnMouseDown", CloseModal)
        Theme:SolidTex(dimmer, "BACKGROUND", 0, 0, 0, 0.45):SetAllPoints()

        popup = CreateFrame("Frame", "TheListQuickModalPopup", dimmer)
        popup:SetSize(MODAL_W, MODAL_H_BLACK)
        popup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        popup:SetFrameStrata("FULLSCREEN_DIALOG")
        popup:SetFrameLevel(dimmer:GetFrameLevel() + 10)
        popup:EnableMouse(true)
        local bg = Theme:SolidTex(popup, "BACKGROUND", Theme.BG_POPUP.r, Theme.BG_POPUP.g, Theme.BG_POPUP.b, 0.98)
        bg:SetAllPoints()
        popup._brd = Theme:MakeBorder(popup, 1, 1, 1, 0.16, bg)
        Theme:RegisterEscapeClose(dimmer, "TheListQuickModalDimmer", CloseModal)
    end
    dimmer:Hide()

    local PAD = 22
    local INNER_W = MODAL_W - PAD * 2

    local topAccent = Theme:SolidTex(popup, "ARTWORK", 1, 0.3, 0.3, 0.95)
    topAccent:SetPoint("TOPLEFT", popup, "TOPLEFT", 1, -1)
    topAccent:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -1, -1)
    topAccent:SetHeight(2)
    popup._topAccent = topAccent

    local title = Theme:MakeFont(popup, 16, "", 1, 1, 1, 0.98)
    title:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD, -16)
    title:SetText("YOU JUST MADE THE LIST!")
    ui.title = title

    local closeX = Theme:MakeButton(popup, "X", 24, 24, 11, CloseModal)
    closeX:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -14, -14)

    local tabW = math.floor((INNER_W - 10) / 2)
    ui.blackTab = Theme:MakeButton(popup, "BAD BOIS", tabW, 30, 12, function()
        state.listType = ns.LIST_BLACK
        RefreshModeColors()
    end, "red")
    ui.blackTab:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)

    ui.greenTab = Theme:MakeButton(popup, "GOOD BOIS", tabW, 30, 12, function()
        state.listType = ns.LIST_GREEN
        RefreshModeColors()
    end, "green")
    ui.greenTab:SetPoint("LEFT", ui.blackTab, "RIGHT", 10, 0)

    local nameLbl = Theme:MakeFont(popup, 10, "", 1, 1, 1, 0.58)
    nameLbl:SetPoint("TOPLEFT", ui.blackTab, "BOTTOMLEFT", 0, -12)
    nameLbl:SetText(Guard.IsForever() and "PLAYER NAME" or "PLAYER (NAME-REALM)")

    local nameHint = Theme:MakeFont(popup, 10, "", 1, 0.78, 0.35, 0.90)
    nameHint:SetPoint("LEFT", nameLbl, "RIGHT", 8, 0)
    nameHint:SetPoint("RIGHT", popup, "RIGHT", -PAD, 0)
    nameHint:SetJustifyH("RIGHT")
    nameHint:SetWordWrap(false)
    nameHint:Hide()
    ui.nameHint = nameHint

    local nameHolder, nameBox = Theme:MakeEditBox(popup, INNER_W - 88, 30,
        Guard.IsForever() and "Player Name" or "PlayerName-RealmName")
    nameHolder:SetPoint("TOPLEFT", nameLbl, "BOTTOMLEFT", 0, -4)
    nameBox:SetFont(Theme:GetFont(), 12, "")
    nameBox:HookScript("OnTextChanged", UpdateNameHint)
    ui.nameBox = nameBox

    local targetBtn = Theme:MakeButton(popup, "Target", 80, 30, 11, function()
        local info = Guard.SafeUnitInfo("target")
        if info and info.isPlayer then
            nameBox:SetText(info.name)
            state.guid = info.guid
            state.class = info.class
        else
            ns.Print("Select a player target first (or identity is currently restricted).")
        end
    end)
    targetBtn:SetPoint("LEFT", nameHolder, "RIGHT", 8, 0)

    local catLbl = Theme:MakeFont(popup, 10, "", 1, 1, 1, 0.58)
    catLbl:SetPoint("TOPLEFT", nameHolder, "BOTTOMLEFT", 0, -12)
    catLbl:SetText("CATEGORY")
    ui.catLabel = catLbl

    local catW = math.floor((INNER_W - 24) / 4)
    ui.catButtons = {}
    for i = 1, 7 do
        local rowIdx = math.floor((i - 1) / 4)
        local colIdx = (i - 1) % 4
        local b = Theme:MakeButton(popup, "", catW, 24, 10, function(self)
            state.category = self._cat
            RefreshModeColors()
        end)
        b:SetPoint("TOPLEFT", catLbl, "BOTTOMLEFT", colIdx * (catW + 8), -4 - rowIdx * 29)
        ui.catButtons[i] = b
    end

    local sevLbl = Theme:MakeFont(popup, 10, "", 1, 1, 1, 0.58)
    sevLbl:SetPoint("TOPLEFT", catLbl, "BOTTOMLEFT", 0, -68)
    sevLbl:SetText("SEVERITY")
    ui.sevLabel = sevLbl

    local sevW = math.floor((INNER_W - 16) / 3)
    ui.sevButtons = {}
    for sev = 1, 3 do
        local b = Theme:MakeButton(popup, ns.SEVERITY_LABELS[sev], sevW, 24, 11, function()
            state.severity = sev
            RefreshModeColors()
        end)
        b:SetPoint("TOPLEFT", sevLbl, "BOTTOMLEFT", (sev - 1) * (sevW + 8), -4)
        ui.sevButtons[sev] = b
    end

    local sharedLbl = Theme:MakeFont(popup, 10, "", 1, 1, 1, 0.58)
    sharedLbl:SetPoint("TOPLEFT", sevLbl, "BOTTOMLEFT", 0, -40)
    sharedLbl:SetText("SHARED NOTE (SYNCED WITH FRIENDS & GUILD)")
    ui.sharedLabel = sharedLbl

    local sharedHolder, sharedBox = Theme:MakeEditBox(popup, INNER_W, 48, "What happened? (visible to trusted sync peers)", true)
    sharedHolder:SetPoint("TOPLEFT", sharedLbl, "BOTTOMLEFT", 0, -4)
    sharedBox:SetFont(Theme:GetFont(), 12, "")
    sharedBox:SetMaxLetters(280)
    sharedBox:HookScript("OnTextChanged", UpdateCharCounters)
    ui.sharedBox = sharedBox

    local sharedCounter = Theme:MakeFont(popup, 10, "", 1, 1, 1, 0.45)
    sharedCounter:SetPoint("BOTTOMRIGHT", sharedHolder, "TOPRIGHT", 0, 4)
    sharedCounter:SetText("0/280")
    ui.sharedCounter = sharedCounter

    local privLbl = Theme:MakeFont(popup, 10, "", 1, 1, 1, 0.58)
    privLbl:SetPoint("TOPLEFT", sharedHolder, "BOTTOMLEFT", 0, -10)
    privLbl:SetText("PRIVATE NOTE (LOCAL ONLY - NEVER SYNCED)")

    local privHolder, privBox = Theme:MakeEditBox(popup, INNER_W, 30, "Personal reminder (stays on your account only)", false)
    privHolder:SetPoint("TOPLEFT", privLbl, "BOTTOMLEFT", 0, -4)
    privBox:SetFont(Theme:GetFont(), 12, "")
    privBox:SetMaxLetters(280)
    privBox:HookScript("OnTextChanged", UpdateCharCounters)
    ui.privBox = privBox

    local privCounter = Theme:MakeFont(popup, 10, "", 1, 1, 1, 0.45)
    privCounter:SetPoint("BOTTOMRIGHT", privHolder, "TOPRIGHT", 0, 4)
    privCounter:SetText("0/280")
    ui.privCounter = privCounter

    ui.shareChk = MakeMiniToggleRow(popup, "Share entry with friends & guild", true, function(val)
        state.share = val
    end)
    ui.shareChk:SetPoint("TOPLEFT", privHolder, "BOTTOMLEFT", 0, -12)

    ui.ignoreChk = MakeMiniToggleRow(popup, "Also /ignore in Blizzard list", false, function(val)
        state.nativeIgnore = val
    end)
    ui.ignoreChk:SetPoint("LEFT", ui.shareChk, "RIGHT", 10, 0)

    local cancelBtn = Theme:MakeButton(popup, "Cancel", 148, 32, 12, CloseModal)
    cancelBtn:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", PAD, 16)

    local saveBtn = Theme:MakeButton(popup, "Save to THE LIST", INNER_W - 158, 32, 12, function()
        local rawName = ui.nameBox:GetText() or ""
        local key = Guard.NormalizeNameRealm(rawName)
        if not key then
            ns.Print(Guard.IsForever() and "Please enter a valid player name." or "Please enter a valid Player-Realm name.")
            return
        end
        local ctx = ""
        if GetInstanceInfo then
            local z, itype = GetInstanceInfo()
            if itype and itype ~= "none" and Guard.SafeString(z) then ctx = z end
        end
        local prevKey = state.editingKey
        DB:AddOrUpdatePersonal({
            name = rawName,
            guid = state.guid,
            class = state.class,
            listType = state.listType,
            category = state.category,
            severity = state.severity,
            sharedNote = ui.sharedBox:GetText() or "",
            privateNote = ui.privBox:GetText() or "",
            share = state.share,
            nativeIgnore = (state.listType == ns.LIST_BLACK) and state.nativeIgnore or false,
            context = (ctx ~= "" and ctx or nil),
        })
        if prevKey and prevKey ~= key then
            DB:RemovePersonal(prevKey)
        end
        CloseModal()
        ns.Print("Saved " .. rawName .. " to THE LIST.")
    end, "accent")
    saveBtn:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -PAD, 16)
end

function Modal:Open(opts)
    EnsureModalBuilt()
    opts = opts or {}

    local existing = opts.entry
    if not existing and opts.name then
        local m = DB:Lookup(opts.name, opts.guid, false)
        existing = m and m.personal
    end

    state.guid = opts.guid or (existing and existing.guid)
    state.class = opts.class or (existing and existing.class)
    state.editingKey = existing and existing.key or nil
    state.listType = (existing and existing.listType) or opts.listType or ns.LIST_BLACK
    state.category = (existing and existing.category) or ((state.listType == ns.LIST_GREEN) and "Reliable" or "Leaver")
    state.severity = (existing and existing.severity) or 2
    if existing then
        state.share = (existing.share ~= false)
    elseif opts.share ~= nil then
        state.share = (opts.share == true)
    else
        state.share = true
    end
    state.nativeIgnore = (existing and existing.nativeIgnore == true) or false

    ui.nameBox:SetText((existing and existing.name) or opts.name or "")
    ui.sharedBox:SetText((existing and existing.sharedNote) or "")
    ui.privBox:SetText((existing and existing.privateNote) or "")
    ui.title:SetText(existing and "EDIT LIST ENTRY" or "YOU JUST MADE THE LIST!")

    RefreshModeColors()
    UpdateCharCounters()
    UpdateNameHint()
    dimmer:Show()
    if not (opts.name or existing) then
        ui.nameBox:SetFocus()
    else
        ui.sharedBox:SetFocus()
    end
end
