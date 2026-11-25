local _, ns = ...

local StandaloneUI = {}
ns.StandaloneUI = StandaloneUI

local Guard = ns.Guard
local DB = ns.DB
local Sync = ns.Sync
local Theme = ns.Theme

local frame
local ui = {
    tab = "black",          -- "black" | "green" | "recent" | "sync"
    search = "",
    sourceFilter = "all",   -- "all" | "mine" | "peers"
    sortBy = "newest",      -- "newest" | "name" | "category"
    searchTimer = nil,
    rows = {},
    rowPool = {},
}

if _G.StaticPopupDialogs and not _G.StaticPopupDialogs["THELIST_STANDALONE_REMOVE"] then
    _G.StaticPopupDialogs["THELIST_STANDALONE_REMOVE"] = {
        text = "Remove %s from THE LIST? Synced peers will also receive this removal.",
        button1 = _G.YES or "Yes",
        button2 = _G.NO or "No",
        OnAccept = function(_, data)
            if data and data.key then
                DB:RemovePersonal(data.key)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

local function SetRowTextRightBound(row, rightPad)
    row._metaFS:ClearAllPoints()
    row._metaFS:SetPoint("LEFT", row._nameFS, "RIGHT", 10, 0)
    row._metaFS:SetPoint("RIGHT", row, "RIGHT", rightPad, 0)

    row._noteFS:ClearAllPoints()
    row._noteFS:SetPoint("TOPLEFT", row._nameFS, "BOTTOMLEFT", 0, -4)
    row._noteFS:SetPoint("RIGHT", row, "RIGHT", rightPad, 0)
end

local function ApplyBtnStyle(btn, text, w, tint, tooltip, action)
    btn:SetSize(w, 24)
    btn._lbl:SetText(text or "")
    btn._tooltipText = tooltip
    btn._action = action

    local r, g, b, a = 1, 1, 1, 0.24
    if tint == "red" then
        r, g, b = Theme:GetBadRGB()
        a = 0.60
    elseif tint == "green" then
        r, g, b = Theme:GetGoodRGB()
        a = 0.78
    end
    if btn._baseBrd then
        btn._baseBrd[1], btn._baseBrd[2], btn._baseBrd[3], btn._baseBrd[4] = r, g, b, a
    else
        btn._baseBrd = { r, g, b, a }
    end
    btn._brd:SetColor(r, g, b, a)
end

local RenderContent

local function Row_OnEnter(self)
    if self._hoverBg then self._hoverBg:Show() end
    local ctx = self._ctx
    if not ctx then return end

    if ctx.mode == "sync" then
        local p = ctx.peer
        if not p then return end
        Theme:ShowTooltip(self, p.authorLabel or ctx.authorID, {
            "Transport: " .. tostring(p.via or "SYNC"),
            "Revision: " .. tostring(p.lastRev or 0),
            ctx.isOnline and "Status: Online now" or ("Last seen: " .. Guard.FormatRelativeTime(p.lastSeenAt)),
        })
    elseif ctx.mode == "recent" then
        local item = ctx.item
        if not item then return end
        Theme:ShowTooltip(self, item.name, {
            "Role: " .. tostring(ctx.roleTxt or "Member"),
            tostring(ctx.noteTxt or "Last seen in group"),
            "Time: " .. tostring(ctx.seenTxt or "Unknown"),
        }, ctx.classRGB)
    elseif ctx.mode == "entry" then
        local rec = ctx.rec
        local entry = rec and rec.entry
        if not entry then return end
        local lines = {
            "Source: " .. (rec.isMine and "You" or tostring(rec.authorLabel)),
            "Category: " .. (entry.category or "Other"),
        }
        if ctx.listType == ns.LIST_BLACK then
            lines[#lines + 1] = "Severity: " .. (ns.SEVERITY_LABELS[entry.severity or 2] or "Warn")
        end
        if entry.sharedNote and entry.sharedNote ~= "" then
            lines[#lines + 1] = { text = "Shared Note: " .. entry.sharedNote, r = 0.95, g = 0.95, b = 0.95 }
        end
        if rec.isMine and entry.privateNote and entry.privateNote ~= "" then
            lines[#lines + 1] = { text = "Private Note: " .. entry.privateNote, r = 0.75, g = 0.85, b = 1.0 }
        end
        if entry.context and entry.context ~= "" then
            lines[#lines + 1] = { text = "Context: " .. entry.context, r = 0.7, g = 0.7, b = 0.7 }
        end
        Theme:ShowTooltip(self, entry.name or entry.key, lines, ctx.classRGB)
    end
end

local function Row_OnLeave(self)
    if self._hoverBg then self._hoverBg:Hide() end
    Theme:HideTooltip()
end

local function RowBtn_OnEnter(self)
    local c = self._baseBrd
    self._bg:SetColorTexture(Theme.BG_BTN.r, Theme.BG_BTN.g, Theme.BG_BTN.b, 0.92)
    self._brd:SetColor(c[1], c[2], c[3], math.min(1, c[4] + 0.25))
    self._lbl:SetTextColor(1, 1, 1, 1)
    if self._tooltipText then
        Theme:ShowTooltip(self, self._tooltipText)
    end
end

local function RowBtn_OnLeave(self)
    local c = self._baseBrd
    self._bg:SetColorTexture(Theme.BG_BTN.r, Theme.BG_BTN.g, Theme.BG_BTN.b, 0.72)
    self._brd:SetColor(c[1], c[2], c[3], c[4])
    self._lbl:SetTextColor(1, 1, 1, 0.85)
    if self._tooltipText then
        Theme:HideTooltip()
    end
end

local function RowBtn_OnClick(self)
    local row = self._row
    local ctx = row and row._ctx
    local act = self._action
    if not (ctx and act) then return end

    if act == "sync_mute" then
        local trust = DB:GetPeerTrust(ctx.authorID)
        DB:SetPeerTrust(ctx.authorID, "muted", not trust.muted, ctx.peer and ctx.peer.authorLabel)
        RenderContent()
    elseif act == "sync_purge" then
        DB:DeletePeerCache(ctx.authorID)
        RenderContent()
    elseif act == "sync_relay" then
        local trust = DB:GetPeerTrust(ctx.authorID)
        DB:SetPeerTrust(ctx.authorID, "relay", trust.relay == false, ctx.peer and ctx.peer.authorLabel)
        RenderContent()
    elseif act == "recent_black" or act == "recent_green" then
        local item = ctx.item
        if item and ns.QuickModal then
            ns.QuickModal:Open({
                name = item.name,
                guid = item.guid,
                class = item.class,
                listType = (act == "recent_green") and ns.LIST_GREEN or ns.LIST_BLACK,
            })
        end
    elseif act == "entry_edit" then
        local entry = ctx.rec and ctx.rec.entry
        if entry and ns.QuickModal then
            ns.QuickModal:Open({ name = entry.name, guid = entry.guid, class = entry.class, entry = entry })
        end
    elseif act == "entry_remove" then
        local entry = ctx.rec and ctx.rec.entry
        if not entry then return end
        if _G.StaticPopup_Show and _G.StaticPopupDialogs and _G.StaticPopupDialogs["THELIST_STANDALONE_REMOVE"] then
            _G.StaticPopup_Show("THELIST_STANDALONE_REMOVE", entry.name or entry.key, nil, { key = entry.key })
        else
            DB:RemovePersonal(entry.key)
        end
    elseif act == "entry_ignore" then
        local entry = ctx.rec and ctx.rec.entry
        if entry then
            DB:ToggleNativeIgnore(entry.key)
        end
    elseif act == "entry_copy" then
        local entry = ctx.rec and ctx.rec.entry
        if not entry then return end
        DB:AddOrUpdatePersonal({
            name = entry.name,
            guid = entry.guid,
            class = entry.class,
            listType = entry.listType,
            category = entry.category,
            severity = entry.severity,
            sharedNote = entry.sharedNote,
            context = entry.context,
            share = true,
        })
        ns.Print("Copied " .. tostring(entry.name or entry.key) .. " to your personal list.")
    elseif act == "entry_mute" then
        local rec = ctx.rec
        if rec then
            DB:SetPeerTrust(rec.authorID, "muted", true, rec.authorLabel)
            RenderContent()
        end
    end
end

local function InitRowButton(btn, row)
    btn._row = row
    btn:SetScript("OnEnter", RowBtn_OnEnter)
    btn:SetScript("OnLeave", RowBtn_OnLeave)
    btn:SetScript("OnClick", RowBtn_OnClick)
end

local function GetOrCreateRow(parent, idx, rowW)
    local row = ui.rowPool[idx]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetSize(rowW, 52)
        row:EnableMouse(true)

        local bg = Theme:SolidTex(row, "BACKGROUND", 0, 0, 0, Theme.ROW_ODD_A)
        bg:SetAllPoints()
        row._bg = bg

        local hoverBg = Theme:SolidTex(row, "BACKGROUND", 1, 1, 1, 0.04)
        hoverBg:SetAllPoints()
        hoverBg:SetDrawLayer("BACKGROUND", 1)
        hoverBg:Hide()
        row._hoverBg = hoverBg

        local div = Theme:SolidTex(row, "BORDER", 1, 1, 1, 0.04)
        div:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        div:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        div:SetHeight(1)

        local stripe = Theme:SolidTex(row, "ARTWORK", 1, 0.3, 0.3, 0.95)
        stripe:SetPoint("TOPLEFT"); stripe:SetPoint("BOTTOMLEFT"); stripe:SetWidth(3)
        row._stripe = stripe

        local nameFS = Theme:MakeFont(row, 14, "", 1, 1, 1, 0.95)
        nameFS:SetPoint("TOPLEFT", row, "TOPLEFT", 14, -8)
        nameFS:SetJustifyH("LEFT")
        nameFS:SetWordWrap(false)
        row._nameFS = nameFS

        local metaFS = Theme:MakeFont(row, 11, "", 1, 1, 1, 0.58)
        metaFS:SetPoint("LEFT", nameFS, "RIGHT", 10, 0)
        metaFS:SetJustifyH("LEFT")
        metaFS:SetWordWrap(false)
        row._metaFS = metaFS

        local noteFS = Theme:MakeFont(row, 12, "", 0.88, 0.88, 0.88, 0.84)
        noteFS:SetPoint("TOPLEFT", nameFS, "BOTTOMLEFT", 0, -4)
        noteFS:SetPoint("RIGHT", row, "RIGHT", -232, 0)
        noteFS:SetJustifyH("LEFT")
        noteFS:SetWordWrap(false)
        row._noteFS = noteFS

        local btn1 = Theme:MakeButton(row, "", 70, 24, 11)
        btn1:SetPoint("RIGHT", row, "RIGHT", -12, 0)
        InitRowButton(btn1, row)
        row._btn1 = btn1

        local btn2 = Theme:MakeButton(row, "", 70, 24, 11)
        btn2:SetPoint("RIGHT", btn1, "LEFT", -6, 0)
        InitRowButton(btn2, row)
        row._btn2 = btn2

        local btn3 = Theme:MakeButton(row, "", 70, 24, 11)
        btn3:SetPoint("RIGHT", btn2, "LEFT", -6, 0)
        InitRowButton(btn3, row)
        row._btn3 = btn3

        row._ctx = {}
        row:SetScript("OnEnter", Row_OnEnter)
        row:SetScript("OnLeave", Row_OnLeave)

        ui.rowPool[idx] = row
    end
    if row._hoverBg then row._hoverBg:Hide() end
    row:SetParent(parent)
    row:SetSize(rowW, 52)
    row:Show()
    return row
end

RenderContent = function()
    if not frame or not frame:IsShown() then return end
    for i = 1, #ui.rows do
        local r = ui.rows[i]
        if r._hoverBg then r._hoverBg:Hide() end
        r:Hide()
        ui.rows[i] = nil
    end

    local content = ui.scrollChild
    local rowW = math.max(400, (ui.scroll:GetWidth() or 910) - 12)
    content:SetWidth(rowW)
    local y = -4

    -- Update active tab styling
    local ar, ag, ab = Theme:GetAccent()
    for key, btn in pairs(ui.tabs) do
        local active = (key == ui.tab)
        btn._underline:SetShown(active)
        btn._underline:SetColorTexture(ar, ag, ab, 1)
        btn._lbl:SetTextColor(1, 1, 1, active and 1 or 0.55)
    end

    local showEntryFilters = (ui.tab == "black" or ui.tab == "green")
    if ui.srcBtn then ui.srcBtn:SetShown(showEntryFilters) end
    if ui.sortBtn then ui.sortBtn:SetShown(showEntryFilters) end

    if ui.tab == "sync" then
        local root = DB:Root()
        local online = Sync:GetOnlinePeers()
        local peersList = {}
        if root then
            for aid, peer in pairs(root.peers) do
                if type(peer) == "table" then
                    peersList[#peersList + 1] = {
                        authorID = aid,
                        peer = peer,
                        isOnline = (online[aid] ~= nil),
                        lastSeenAt = peer.lastSeenAt or 0,
                    }
                end
            end
        end
        for aid, o in pairs(online) do
            if not (root and root.peers[aid]) then
                peersList[#peersList + 1] = {
                    authorID = aid,
                    peer = {
                        authorLabel = o.authorLabel or aid,
                        via = o.via or "SYNC",
                        lastRev = o.rev or 0,
                        lastSeenAt = o.lastHelloAt or time(),
                    },
                    isOnline = true,
                    lastSeenAt = o.lastHelloAt or time(),
                }
            end
        end
        table.sort(peersList, function(a, b)
            if a.isOnline ~= b.isOnline then return a.isOnline end
            return (a.lastSeenAt or 0) > (b.lastSeenAt or 0)
        end)

        for idx = 1, #peersList do
            local rec = peersList[idx]
            local aid = rec.authorID
            local peer = rec.peer
            local isOnline = rec.isOnline
            local row = GetOrCreateRow(content, idx, rowW)
            ui.rows[#ui.rows + 1] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            row._bg:SetColorTexture(0, 0, 0, (idx % 2 == 1) and Theme.ROW_ODD_A or Theme.ROW_EVEN_A)
            row._stripe:SetColorTexture(isOnline and ar or 0.4, isOnline and ag or 0.4, isOnline and ab or 0.4, 0.95)
            row._nameFS:SetTextColor(1, 1, 1, 0.95)
            row._nameFS:SetText(peer.authorLabel or aid)
            row._metaFS:SetText(string.format("%s | rev %d", peer.via or "SYNC", peer.lastRev or 0))
            row._noteFS:SetText(isOnline and "Online now" or ("Last seen " .. Guard.FormatRelativeTime(peer.lastSeenAt)))

            local ctx = row._ctx
            ctx.mode = "sync"
            ctx.authorID = aid
            ctx.peer = peer
            ctx.isOnline = isOnline
            ctx.rec = nil
            ctx.item = nil

            local trust = DB:GetPeerTrust(aid)
            row._btn1:Show()
            ApplyBtnStyle(row._btn1, "Purge", 66, "red", "Delete cached entries from this peer.", "sync_purge")
            row._btn2:Show()
            ApplyBtnStyle(row._btn2, trust.muted and "Muted" or "Active", 70, trust.muted and "red" or "green", "Mute or unmute this peer locally.", "sync_mute")
            row._btn3:Show()
            ApplyBtnStyle(row._btn3, trust.relay ~= false and "Relay: On" or "Relay: Off", 80, nil, "Toggle 1-hop trusted relay for this peer.", "sync_relay")
            SetRowTextRightBound(row, -242)

            y = y - 52
        end
        if #peersList == 0 then
            ui.emptyFS:SetText("No peers synced yet. Online BNet friends & guildmates appear automatically.")
            ui.emptyFS:Show()
        else
            ui.emptyFS:Hide()
        end
    elseif ui.tab == "recent" then
        local recent = DB:GetRecentTeammates(ui.search)
        ui.emptyFS:SetShown(#recent == 0)
        ui.emptyFS:SetText("No recent teammates recorded yet.")
        for i = 1, #recent do
            local item = recent[i]
            local row = GetOrCreateRow(content, i, rowW)
            ui.rows[#ui.rows + 1] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            row._bg:SetColorTexture(0, 0, 0, (i % 2 == 1) and Theme.ROW_ODD_A or Theme.ROW_EVEN_A)
            row._stripe:SetColorTexture(1, 1, 1, 0.16)
            local cr, cg, cb = Guard.GetClassRGB(item.class)
            row._nameFS:SetTextColor(cr, cg, cb, 1)
            row._nameFS:SetText(item.name)

            local roleTxt = Guard.FormatRole(item.role)
            local seenTxt = Guard.FormatRelativeTime(item.seenAt)
            local noteTxt = (item.context and item.context ~= "") and ("Last seen: " .. item.context) or "Last seen in group"
            row._metaFS:SetText(roleTxt .. "  |  Last seen: " .. seenTxt)
            row._noteFS:SetText(noteTxt)

            local ctx = row._ctx
            ctx.mode = "recent"
            ctx.item = item
            ctx.rec = nil
            ctx.roleTxt = roleTxt
            ctx.seenTxt = seenTxt
            ctx.noteTxt = noteTxt
            ctx.classRGB = ctx.classRGB or { 1, 1, 1 }
            ctx.classRGB[1], ctx.classRGB[2], ctx.classRGB[3] = cr, cg, cb

            row._btn3:Hide()
            row._btn2:Show()
            row._btn1:Show()
            ApplyBtnStyle(row._btn2, "+ Bad Boi", 78, "red", nil, "recent_black")
            ApplyBtnStyle(row._btn1, "+ Good Boi", 84, "green", nil, "recent_green")
            SetRowTextRightBound(row, -192)

            y = y - 52
        end
    else
        local listType = (ui.tab == "green") and ns.LIST_GREEN or ns.LIST_BLACK
        local items = DB:QueryEntries(listType, ui.sourceFilter, ui.search, ui.sortBy)
        ui.emptyFS:SetShown(#items == 0)
        ui.emptyFS:SetText("No entries yet. Fill in the bar above or right-click any player.")
        local sr, sg, sb
        if listType == ns.LIST_GREEN then
            sr, sg, sb = Theme:GetGoodRGB()
        else
            sr, sg, sb = Theme:GetBadRGB()
        end
        for i = 1, #items do
            local rec = items[i]
            local entry = rec.entry
            local row = GetOrCreateRow(content, i, rowW)
            ui.rows[#ui.rows + 1] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            row._bg:SetColorTexture(0, 0, 0, (i % 2 == 1) and Theme.ROW_ODD_A or Theme.ROW_EVEN_A)
            row._stripe:SetColorTexture(sr, sg, sb, rec.isMine and 0.95 or 0.50)
            local cr, cg, cb = Guard.GetClassRGB(entry.class)
            row._nameFS:SetTextColor(cr, cg, cb, 1)
            row._nameFS:SetText(entry.name)

            local sevTxt = (listType == ns.LIST_BLACK) and ("  |  " .. (ns.SEVERITY_LABELS[entry.severity or 2] or "Warn")) or ""
            row._metaFS:SetText((rec.isMine and "[You] " or ("[" .. tostring(rec.authorLabel) .. "] ")) .. (entry.category or "Other") .. sevTxt .. "  |  " .. Guard.FormatRelativeTime(entry.updatedAt))
            row._noteFS:SetText((entry.sharedNote ~= "" and entry.sharedNote) or entry.privateNote or "(No note)")

            local ctx = row._ctx
            ctx.mode = "entry"
            ctx.rec = rec
            ctx.item = nil
            ctx.listType = listType
            ctx.classRGB = ctx.classRGB or { 1, 1, 1 }
            ctx.classRGB[1], ctx.classRGB[2], ctx.classRGB[3] = cr, cg, cb

            if rec.isMine then
                row._btn1:Show()
                row._btn2:Show()
                ApplyBtnStyle(row._btn1, "Remove", 70, "red", nil, "entry_remove")
                ApplyBtnStyle(row._btn2, "Edit", 62, nil, nil, "entry_edit")
                if listType == ns.LIST_BLACK then
                    row._btn3:Show()
                    ApplyBtnStyle(row._btn3, entry.nativeIgnore and "Ignored" or "/ignore", 70, entry.nativeIgnore and "green" or nil, "Toggle Blizzard native /ignore for this player.", "entry_ignore")
                    SetRowTextRightBound(row, -230)
                else
                    row._btn3:Hide()
                    SetRowTextRightBound(row, -156)
                end
            else
                row._btn1:Show()
                row._btn2:Show()
                row._btn3:Hide()
                ApplyBtnStyle(row._btn1, "Mute", 72, "red", "Hide synced entries from this peer locally.", "entry_mute")
                ApplyBtnStyle(row._btn2, "Copy", 64, nil, "Save a personal copy to your own list.", "entry_copy")
                SetRowTextRightBound(row, -168)
            end
            y = y - 52
        end
    end

    content:SetHeight(math.max(200, math.abs(y) + 20))
end

local function BuildStandaloneFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "TheListStandaloneFrame", UIParent)
    frame:SetSize(980, 680)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    Theme:RegisterEscapeClose(frame, "TheListStandaloneFrame", function() frame:Hide() end)

    local bg = Theme:SolidTex(frame, "BACKGROUND", Theme.BG_PANEL.r, Theme.BG_PANEL.g, Theme.BG_PANEL.b, 0.98)
    bg:SetAllPoints()
    Theme:MakeBorder(frame, 1, 1, 1, 0.14, bg)

    local title = Theme:MakeFont(frame, 18, "", 1, 1, 1, 0.96)
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -18)
    title:SetText("|cffff4d4dTHE|r " .. Theme:GetGoodHex() .. "LIST|r")

    local sub = Theme:MakeFont(frame, 11, "", 1, 1, 1, 0.55)
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    sub:SetText("Personal & Synced Bad Bois / Good Bois")

    local closeBtn = Theme:MakeButton(frame, "X", 26, 26, 11, function() frame:Hide() end)
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -16)

    -- Tab bar matching EllesmereUI 40px band + accent underline
    local tabBand = Theme:SolidTex(frame, "BACKGROUND", 0, 0, 0, 0.25)
    tabBand:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -64)
    tabBand:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -64)
    tabBand:SetHeight(36)

    ui.tabs = {}
    local tabDefs = {
        { key = "black",  label = "Bad Bois" },
        { key = "green",  label = "Good Bois" },
        { key = "recent", label = "Recent" },
        { key = "sync",   label = "Sync Peers" },
    }
    for i = 1, #tabDefs do
        local def = tabDefs[i]
        local b = CreateFrame("Button", nil, frame)
        b:SetSize(110, 36)
        b:SetPoint("LEFT", tabBand, "LEFT", 16 + (i - 1) * 114, 0)
        local lbl = Theme:MakeFont(b, 12, "", 1, 1, 1, 0.65)
        lbl:SetPoint("CENTER")
        lbl:SetText(def.label)
        local ul = Theme:SolidTex(b, "ARTWORK", Theme.DEFAULT_ACC.r, Theme.DEFAULT_ACC.g, Theme.DEFAULT_ACC.b, 1)
        ul:SetPoint("BOTTOMLEFT"); ul:SetPoint("BOTTOMRIGHT"); ul:SetHeight(2)
        ul:Hide()
        b._lbl = lbl
        b._underline = ul
        b:SetScript("OnClick", function()
            ui.tab = def.key
            RenderContent()
        end)
        ui.tabs[def.key] = b
    end

    -- Row 1: Direct Quick-Add Bar
    local nameHolder, nameBox = Theme:MakeEditBox(frame, 200, 28,
        Guard.IsForever() and "Player Name" or "PlayerName-RealmName")
    nameHolder:SetPoint("TOPLEFT", tabBand, "BOTTOMLEFT", 20, -10)
    nameBox:SetFont(Theme:GetFont(), 12, "")

    local noteHolder, noteBox = Theme:MakeEditBox(frame, 330, 28, "Quick note (synced)...")
    noteHolder:SetPoint("LEFT", nameHolder, "RIGHT", 6, 0)
    noteBox:SetFont(Theme:GetFont(), 12, "")

    local function QuickSubmit(listType)
        local raw = (nameBox:GetText() or ""):match("^%s*(.-)%s*$")
        if raw == "" then
            ns.QuickModal:Open({ listType = listType })
            return
        end
        local key = Guard.NormalizeNameRealm(raw)
        if not key then
            ns.Print(Guard.IsForever() and "Enter a valid player name." or "Enter a valid Player-Realm name.")
            return
        end
        DB:AddOrUpdatePersonal({
            name = raw,
            listType = listType,
            category = (listType == ns.LIST_GREEN) and "Reliable" or "Leaver",
            severity = 2,
            sharedNote = noteBox:GetText() or "",
            share = true,
        })
        nameBox:SetText("")
        noteBox:SetText("")
    end

    local addBlackBtn = Theme:MakeButton(frame, "+ Bad Boi", 96, 28, 11, function() QuickSubmit(ns.LIST_BLACK) end, "red")
    addBlackBtn:SetPoint("LEFT", noteHolder, "RIGHT", 6, 0)

    local addGreenBtn = Theme:MakeButton(frame, "+ Good Boi", 98, 28, 11, function() QuickSubmit(ns.LIST_GREEN) end, "green")
    addGreenBtn:SetPoint("LEFT", addBlackBtn, "RIGHT", 6, 0)

    -- Row 2: Search + Source/Sort Filters + Sync + Test
    local searchHolder, searchBox = Theme:MakeEditBox(frame, 534, 28, "Filter list by player, tag, note, or friend...")
    searchHolder:SetPoint("TOPLEFT", nameHolder, "BOTTOMLEFT", 0, -6)
    searchBox:SetFont(Theme:GetFont(), 12, "")
    searchBox:SetTextInsets(10, 26, 0, 0)

    local suppressDebounce = false
    local clearBtn = CreateFrame("Button", nil, searchHolder)
    clearBtn:SetSize(20, 20)
    clearBtn:SetPoint("RIGHT", searchHolder, "RIGHT", -5, 0)
    clearBtn:SetFrameLevel(searchBox:GetFrameLevel() + 2)
    local clearLbl = Theme:MakeFont(clearBtn, 11, "", 1, 1, 1, 0.5)
    clearLbl:SetPoint("CENTER")
    clearLbl:SetText("X")
    clearBtn:Hide()
    clearBtn:SetScript("OnEnter", function() clearLbl:SetTextColor(1, 1, 1, 0.95) end)
    clearBtn:SetScript("OnLeave", function() clearLbl:SetTextColor(1, 1, 1, 0.5) end)
    clearBtn:SetScript("OnClick", function()
        if ui.searchTimer then
            ui.searchTimer:Cancel()
            ui.searchTimer = nil
        end
        ui.search = ""
        suppressDebounce = true
        searchBox:SetText("")
        suppressDebounce = false
        searchBox:ClearFocus()
        RenderContent()
    end)

    searchBox:SetScript("OnTextChanged", function(self)
        local txt = self:GetText() or ""
        searchHolder.placeholder:SetShown(txt == "")
        clearBtn:SetShown(txt ~= "")
        if suppressDebounce then return end
        if ui.searchTimer then
            ui.searchTimer:Cancel()
            ui.searchTimer = nil
        end
        ui.searchTimer = C_Timer.NewTimer(0.12, function()
            ui.searchTimer = nil
            ui.search = txt
            RenderContent()
        end)
    end)

    local syncBtn = Theme:MakeButton(frame, "Sync Now", 88, 28, 11, function()
        local status = Sync:SyncNow()
        ns.Print(Sync:FormatSyncStatus(status))
    end)
    syncBtn:SetPoint("TOPRIGHT", tabBand, "BOTTOMRIGHT", -20, -44)

    local testBtn = Theme:MakeButton(frame, "Test Banner", 94, 28, 11, function()
        ns.AlertBanner:ShowTestAlert()
    end)
    testBtn:SetPoint("RIGHT", syncBtn, "LEFT", -6, 0)

    local sortCycle = { newest = "name", name = "category", category = "newest" }
    local sortLbls = { newest = "Sort: Newest", name = "Sort: Name", category = "Sort: Tag" }
    local sortBtn = Theme:MakeButton(frame, sortLbls[ui.sortBy], 100, 28, 11, function(self)
        ui.sortBy = sortCycle[ui.sortBy] or "newest"
        self._lbl:SetText(sortLbls[ui.sortBy])
        RenderContent()
    end)
    sortBtn:SetPoint("RIGHT", testBtn, "LEFT", -6, 0)
    ui.sortBtn = sortBtn

    local srcCycle = { all = "mine", mine = "peers", peers = "all" }
    local srcLbls = { all = "Src: All", mine = "Src: Mine", peers = "Src: Synced" }
    local srcBtn = Theme:MakeButton(frame, srcLbls[ui.sourceFilter], 92, 28, 11, function(self)
        ui.sourceFilter = srcCycle[ui.sourceFilter] or "all"
        self._lbl:SetText(srcLbls[ui.sourceFilter])
        RenderContent()
    end)
    srcBtn:SetPoint("RIGHT", sortBtn, "LEFT", -6, 0)
    ui.srcBtn = srcBtn

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", searchHolder, "BOTTOMLEFT", 0, -12)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 16)
    ui.scroll = scroll

    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(910, 300)
    scroll:SetScrollChild(scrollChild)
    ui.scrollChild = scrollChild

    ui.emptyFS = Theme:MakeFont(scrollChild, 12, "", 1, 1, 1, 0.45)
    ui.emptyFS:SetPoint("TOP", scrollChild, "TOP", 0, -40)
    ui.emptyFS:Hide()

    return frame
end

function StandaloneUI:RegisterBlizzardSettings()
    if not (_G.Settings and _G.Settings.RegisterCanvasLayoutCategory and _G.Settings.RegisterAddOnCategory) then
        return
    end
    if _G.EllesmereUI and _G.EllesmereUI.RegisterPlugin then
        return
    end

    local panel = CreateFrame("Frame")
    local title = Theme:MakeFont(panel, 18, "", 1, 1, 1, 0.96)
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("|cffff4d4dTHE|r " .. Theme:GetGoodHex() .. "LIST|r")

    local desc = Theme:MakeFont(panel, 12, "", 1, 1, 1, 0.65)
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    desc:SetText("Personal and in-game synced Bad Bois & Good Bois. Use /thelist or /list to open the full manager.")

    local openBtn = Theme:MakeButton(panel, "Open THE LIST Window", 180, 32, 12, function()
        if _G.HideUIPanel and _G.SettingsPanel then
            pcall(_G.HideUIPanel, _G.SettingsPanel)
        end
        StandaloneUI:Toggle()
    end, "accent")
    openBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)

    local s = DB:Settings()
    local checks = {
        { key = "warnGroupRoster",   label = "Warn when a listed player is in your group" },
        { key = "warnLfgApplicants", label = "Warn when a listed player queues into your group" },
        { key = "warnLfgSearch",     label = "Flag Premade Groups containing listed players" },
        { key = "syncEnabled",       label = "Enable in-game Battle.net & Guild sync" },
        { key = "syncBNet",          label = "Sync via Battle.net friends (cross-realm / cross-faction)" },
        { key = "syncGuild",         label = "Sync via Guild addon channel" },
        { key = "syncRelay",         label = "1-hop trusted relay for offline friends" },
    }
    local y = -124
    for i = 1, #checks do
        local c = checks[i]
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, y)
        cb:SetChecked(s[c.key] == true)
        local lbl = Theme:MakeFont(panel, 12, "", 1, 1, 1, 0.9)
        lbl:SetPoint("LEFT", cb, "RIGHT", 6, 0)
        lbl:SetText(c.label)
        cb:SetScript("OnClick", function(self)
            s[c.key] = self:GetChecked() and true or false
        end)
        y = y - 30
    end

    local category = _G.Settings.RegisterCanvasLayoutCategory(panel, "THE LIST")
    _G.Settings.RegisterAddOnCategory(category)
end

function StandaloneUI:Toggle()
    local f = BuildStandaloneFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        RenderContent()
    end
end

function StandaloneUI:Init()
    ns:On("DB_CHANGED", function() RenderContent() end)
    ns:On("PEERS_CHANGED", function() RenderContent() end)
end
