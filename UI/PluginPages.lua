local _, ns = ...

local PluginPages = {}
ns.PluginPages = PluginPages

local Guard = ns.Guard
local DB = ns.DB
local Sync = ns.Sync
local Theme = ns.Theme

local PLUGIN_ID = "THE_LIST"
local MODULE_MAIN = "Main"

local PAGE_BAD = "Bad Bois"
local PAGE_GOOD = "Good Bois"
local PAGE_RECENT = "Recent"
local PAGE_SETTINGS = "Settings & Sync"

local SEP = " |cff555555/|r "

local SEVERITY_COLOR_LABELS = {
    [1] = "|cff9e9e9eNote|r",
    [2] = "|cffffb84dWarn|r",
    [3] = "|cffff4d4dHard Avoid|r",
}

local uiState = {
    search = "",
    sourceFilter = "all",   -- "all" | "mine" | "peers"
    sortBy = "newest",      -- "newest" | "name" | "category"
    minSeverity = 1,        -- 1 | 2 | 3 (Bad Bois only)
    searchTimer = nil,
    activePage = nil,
    activeParent = nil,
    pageParents = {},
    headerBuilders = {},
    headerRefreshByPage = {},
    summaryUpdaterByPage = {},
    lastShownCountByPage = {},
    rowPool = {},
    activeRows = {},
    subRowPool = {},
    activeSubRows = {},
    expandedKeys = {},
    emptyFS = nil,
    peerRowPool = {},
    activePeerRows = {},
    peerEmptyFS = nil,
    unlockPlaceholder = nil,
}

local function IsPluginShown()
    local eui = _G.EllesmereUI
    if not (eui and eui.IsShown and eui:IsShown() and eui.GetActiveModule and eui.GetPluginModuleKey) then
        return false
    end
    local fullKey = eui.GetPluginModuleKey(PLUGIN_ID, MODULE_MAIN)
    return fullKey ~= nil and eui:GetActiveModule() == fullKey
end

-- Uses EUI's neutral dark button surface + crisp accent/crimson border (zero muddy tint)
local function MakeButtonColours(tint)
    if tint == "red" then
        local br, bg, bb = Theme:GetBadRGB()
        return {
            Theme.BG_BTN.r, Theme.BG_BTN.g, Theme.BG_BTN.b, 0.90,
            0.135, 0.115, 0.105, 0.96,
            br, bg, bb, 0.72,  br, bg, bb, 1.0,
            br, math.min(1, bg + 0.12), math.min(1, bb + 0.12), 0.90,
            1, 1, 1, 1.0,
        }
    elseif tint == "green" then
        local gr, gg, gb = Theme:GetGoodRGB()
        return {
            Theme.BG_BTN.r, Theme.BG_BTN.g, Theme.BG_BTN.b, 0.90,
            0.125, 0.118, 0.110, 0.96,
            gr, gg, gb, 0.72,  gr, gg, gb, 1.0,
            gr, gg, gb, 0.88,  gr, gg, gb, 1.0,
        }
    end
    local eui = _G.EllesmereUI
    if eui and eui.WB_COLOURS then
        return eui.WB_COLOURS
    end
    return nil
end

local function MakeEUIButton(parent, text, w, h, fontSize, onClick, tint, tooltip)
    local eui = _G.EllesmereUI
    local colours = MakeButtonColours(tint)
    local btn
    if eui and eui.MakeStyledButton and colours then
        btn = CreateFrame("Button", nil, parent)
        btn:SetSize(w or 100, h or 28)
        local wrappedClick = onClick and function() onClick(btn) end or nil
        local bg, brd, lbl = eui.MakeStyledButton(btn, text, fontSize or 12, colours, wrappedClick)
        btn._bg = bg
        btn._brd = brd
        btn._lbl = lbl
    else
        btn = Theme:MakeButton(parent, text, w, h, fontSize, onClick, tint)
    end
    if tooltip then
        btn:HookScript("OnEnter", function(self) Theme:ShowTooltip(self, tooltip) end)
        btn:HookScript("OnLeave", function() Theme:HideTooltip() end)
    end
    return btn
end

local function HidePooledRows()
    for i = 1, #uiState.activeRows do
        local r = uiState.activeRows[i]
        if r._hoverBg then r._hoverBg:Hide() end
        r:Hide()
        uiState.activeRows[i] = nil
    end
    for i = 1, #uiState.activeSubRows do
        local sr = uiState.activeSubRows[i]
        if sr._hoverBg then sr._hoverBg:Hide() end
        sr:Hide()
        uiState.activeSubRows[i] = nil
    end
    if uiState.emptyFS then uiState.emptyFS:Hide() end
end

local function ConfirmRemoveEntry(entry)
    local eui = _G.EllesmereUI
    if eui and eui.ShowConfirmPopup then
        eui:ShowConfirmPopup({
            title = "Remove from THE LIST",
            message = string.format("Remove %s from THE LIST? Synced peers will also receive this removal.", entry.name or entry.key),
            confirmText = "Remove",
            cancelText = "Cancel",
            onConfirm = function()
                DB:RemovePersonal(entry.key)
            end,
        })
    else
        DB:RemovePersonal(entry.key)
    end
end

local function SetRowTextRightBound(row, rightPad)
    row._metaFS:ClearAllPoints()
    row._metaFS:SetPoint("LEFT", row._nameFS, "RIGHT", 10, 0)
    row._metaFS:SetPoint("RIGHT", row, "RIGHT", rightPad, 0)

    row._noteFS:ClearAllPoints()
    row._noteFS:SetPoint("TOPLEFT", row._nameFS, "BOTTOMLEFT", 0, -4)
    row._noteFS:SetPoint("RIGHT", row, "RIGHT", rightPad, 0)
end

local function SetRowHovered(row, hovered)
    if not row then return end
    if row._hoverBg then row._hoverBg:SetShown(hovered) end

    if row._mode == "entry" then
        if hovered then
            if row._timeFS then row._timeFS:Hide() end
            if row._btn1 then row._btn1:SetShown(row._wantBtn1 == true) end
            if row._btn2 then row._btn2:SetShown(row._wantBtn2 == true) end
            if row._btn3 then row._btn3:SetShown(row._wantBtn3 == true) end
            SetRowTextRightBound(row, row._hoverRightPad or -156)
        else
            if row._timeFS then row._timeFS:Show() end
            if row._btn1 then row._btn1:Hide() end
            if row._btn2 then row._btn2:Hide() end
            if row._btn3 then row._btn3:Hide() end
            row._metaFS:ClearAllPoints()
            row._metaFS:SetPoint("LEFT", row._nameFS, "RIGHT", 10, 0)
            if row._timeFS then
                row._metaFS:SetPoint("RIGHT", row._timeFS, "LEFT", -10, 0)
            else
                row._metaFS:SetPoint("RIGHT", row, "RIGHT", -14, 0)
            end
            row._noteFS:ClearAllPoints()
            row._noteFS:SetPoint("TOPLEFT", row._nameFS, "BOTTOMLEFT", 0, -4)
            row._noteFS:SetPoint("RIGHT", row, "RIGHT", -14, 0)
        end
    elseif row._mode == "subrow" then
        if row._dismissBtn then row._dismissBtn:SetShown(hovered) end
        local pad = hovered and -78 or -12
        row._metaFS:ClearAllPoints()
        row._metaFS:SetPoint("TOPLEFT", row, "TOPLEFT", 12, -4)
        row._metaFS:SetPoint("RIGHT", row, "RIGHT", pad, 0)
        row._noteFS:ClearAllPoints()
        row._noteFS:SetPoint("TOPLEFT", row._metaFS, "BOTTOMLEFT", 0, -2)
        row._noteFS:SetPoint("RIGHT", row, "RIGHT", pad, 0)
    end
end

local function FormatAuthorsSummary(authors, useShort, limit)
    if type(authors) ~= "table" or #authors == 0 then return "" end
    local maxShow = limit and math.min(limit, #authors) or #authors
    local names = {}
    for i = 1, maxShow do
        local a = authors[i]
        if useShort then
            names[#names + 1] = tostring(a.shortLabel or a.authorLabel or a.authorID or "?")
        else
            names[#names + 1] = tostring(a.authorLabel or a.shortLabel or a.authorID or "?")
        end
    end
    local out = table.concat(names, ", ")
    if limit and #authors > limit then
        out = out .. " (+" .. tostring(#authors - limit) .. ")"
    end
    return out
end

local function CollectUniquePeers(rec)
    local out, seen = {}, {}
    local function AddList(list)
        if type(list) ~= "table" then return end
        for i = 1, #list do
            local p = list[i]
            if p and p.authorID and not seen[p.authorID] then
                seen[p.authorID] = true
                out[#out + 1] = p
            end
        end
    end
    AddList(rec.peers)
    AddList(rec.conflictPeers)
    return out
end

local RepaintEntriesList

local function OpenEntryContextMenu(anchor, rec, opts, subGroup)
    if not rec then return end
    local entry = rec.primary or rec.entry
    local items = {}
    local br, bg, bb = Theme:GetBadRGB()

    if subGroup then
        local groupAuthors = subGroup.authors or {}
        local authorIDs = {}
        for i = 1, #groupAuthors do
            if groupAuthors[i].authorID then
                authorIDs[#authorIDs + 1] = groupAuthors[i].authorID
            end
        end
        items[#items + 1] = {
            text = "Dismiss This Note",
            desc = "Hide locally without muting the peer.",
            onClick = function()
                DB:DismissPeerEntries(authorIDs, rec.key)
            end,
        }
        if not rec.isMine then
            items[#items + 1] = {
                text = "Save This Note to My List (Local)",
                onClick = function()
                    DB:AdoptPeerEntry({
                        key = rec.key,
                        name = rec.name,
                        guid = rec.guid,
                        class = rec.class,
                        listType = subGroup.listType or rec.listType,
                        category = subGroup.category,
                        severity = subGroup.severity,
                        sharedNote = subGroup.sharedNote,
                        context = subGroup.context,
                    }, { guid = rec.guid, class = rec.class })
                    ns.Print("Saved " .. tostring(rec.name or rec.key) .. " to your personal list (local only).")
                end,
            }
        end
        if #groupAuthors == 1 then
            local p = groupAuthors[1]
            items[#items + 1] = "---"
            items[#items + 1] = {
                text = "Mute Peer: " .. tostring(p.shortLabel or p.authorLabel),
                color = { br, bg, bb },
                onClick = function()
                    DB:SetPeerTrust(p.authorID, "muted", true, p.authorLabel)
                    if RepaintEntriesList then RepaintEntriesList() end
                end,
            }
        elseif #groupAuthors > 1 then
            local muteChildren = {}
            for i = 1, #groupAuthors do
                local p = groupAuthors[i]
                muteChildren[#muteChildren + 1] = {
                    text = tostring(p.shortLabel or p.authorLabel),
                    color = { br, bg, bb },
                    onClick = function()
                        DB:SetPeerTrust(p.authorID, "muted", true, p.authorLabel)
                        if RepaintEntriesList then RepaintEntriesList() end
                    end,
                }
            end
            items[#items + 1] = "---"
            items[#items + 1] = { text = "Mute Peer", children = muteChildren }
        end
        Theme:ShowContextMenu(anchor, items, opts)
        return
    end

    if rec.isMine and entry then
        items[#items + 1] = {
            text = "Edit Entry",
            onClick = function()
                if ns.QuickModal then
                    ns.QuickModal:Open({
                        name = entry.name,
                        guid = rec.guid or entry.guid,
                        class = rec.class or entry.class,
                        entry = entry,
                    })
                end
            end,
        }
        if rec.listType == ns.LIST_BLACK then
            items[#items + 1] = {
                text = entry.nativeIgnore and "Remove Blizzard /ignore" or "Add Blizzard /ignore",
                onClick = function()
                    DB:ToggleNativeIgnore(entry.key)
                end,
            }
        end
        items[#items + 1] = {
            text = "Remove from Personal List",
            color = { br, bg, bb },
            onClick = function()
                ConfirmRemoveEntry(entry)
            end,
        }
    elseif entry then
        items[#items + 1] = {
            text = "Save to My List (Local)",
            desc = "Copies locally without re-sharing until you edit it.",
            onClick = function()
                DB:AdoptPeerEntry(entry, { guid = rec.guid, class = rec.class, listType = rec.listType })
                ns.Print("Saved " .. tostring(entry.name or rec.key) .. " to your personal list (local only).")
            end,
        }
        items[#items + 1] = {
            text = "Save & Edit...",
            onClick = function()
                if ns.QuickModal then
                    ns.QuickModal:Open({
                        name = entry.name or rec.name,
                        guid = rec.guid,
                        class = rec.class,
                        listType = rec.listType,
                        category = entry.category,
                        severity = entry.severity,
                        sharedNote = entry.sharedNote,
                        context = entry.context,
                        share = false,
                    })
                end
            end,
        }
    end

    if rec.hasExpandableDetails then
        local expandKey = tostring(rec.listType) .. ":" .. tostring(rec.key)
        local isExpanded = uiState.expandedKeys[expandKey] == true
        items[#items + 1] = {
            text = isExpanded and "Collapse Peer Notes" or "Expand Peer Notes",
            onClick = function()
                uiState.expandedKeys[expandKey] = not isExpanded and true or nil
                if RepaintEntriesList then RepaintEntriesList() end
            end,
        }
    end

    local uniquePeers = CollectUniquePeers(rec)
    if #uniquePeers > 0 then
        items[#items + 1] = "---"
        if #uniquePeers == 1 then
            local p = uniquePeers[1]
            items[#items + 1] = {
                text = "Dismiss Entry from " .. tostring(p.shortLabel or p.authorLabel),
                desc = "Hide this player from this peer without muting them.",
                onClick = function()
                    DB:DismissPeerEntry(p.authorID, rec.key)
                end,
            }
            items[#items + 1] = {
                text = "Mute Peer: " .. tostring(p.shortLabel or p.authorLabel),
                color = { br, bg, bb },
                onClick = function()
                    DB:SetPeerTrust(p.authorID, "muted", true, p.authorLabel)
                    if RepaintEntriesList then RepaintEntriesList() end
                end,
            }
        else
            local allIDs = {}
            local muteChildren = {}
            for i = 1, #uniquePeers do
                local p = uniquePeers[i]
                allIDs[#allIDs + 1] = p.authorID
                muteChildren[#muteChildren + 1] = {
                    text = tostring(p.shortLabel or p.authorLabel),
                    color = { br, bg, bb },
                    onClick = function()
                        DB:SetPeerTrust(p.authorID, "muted", true, p.authorLabel)
                        if RepaintEntriesList then RepaintEntriesList() end
                    end,
                }
            end
            items[#items + 1] = {
                text = "Dismiss All Synced Notes for Player",
                desc = "Hide all current peer entries for this player locally.",
                onClick = function()
                    DB:DismissPeerEntries(allIDs, rec.key)
                end,
            }
            items[#items + 1] = {
                text = "Mute Peer",
                children = muteChildren,
            }
        end
    end

    Theme:ShowContextMenu(anchor, items, opts)
end

local function Row_OnEnter(self)
    SetRowHovered(self, true)
    if self._mode == "recent" then
        local item = self._item
        if not item then return end
        Theme:ShowTooltip(self, item.name, {
            "Role: " .. tostring(self._roleTxt or "Member"),
            tostring(self._ctx or "Last seen in group"),
            "Time: " .. tostring(self._seenTxt or "Unknown"),
        }, self._classRGB)
    elseif self._mode == "subrow" then
        local g = self._group
        local rec = self._rec
        if not (g and rec) then return end
        local listWord = (g.listType == ns.LIST_GREEN) and "Good Boi" or "Bad Boi"
        local lines = {
            "Peers: " .. FormatAuthorsSummary(g.authors, false),
            "List: " .. listWord .. "  (" .. tostring(g.category or "Other") .. ")",
        }
        if g.listType == ns.LIST_BLACK then
            lines[#lines + 1] = "Severity: " .. (ns.SEVERITY_LABELS[g.severity or 2] or "Warn")
        end
        lines[#lines + 1] = "Updated: " .. Guard.FormatRelativeTime(g.updatedAt)
        if g.sharedNote and g.sharedNote ~= "" then
            lines[#lines + 1] = { text = "Note: " .. g.sharedNote, r = 0.95, g = 0.95, b = 0.95 }
        end
        if g.context and g.context ~= "" then
            lines[#lines + 1] = { text = "Context: " .. g.context, r = 0.72, g = 0.72, b = 0.72 }
        end
        lines[#lines + 1] = { text = "Right-click for options", r = 0.55, g = 0.55, b = 0.55 }
        Theme:ShowTooltip(self, rec.name or rec.key, lines, self._classRGB)
    elseif self._mode == "entry" then
        local rec = self._rec
        local entry = rec and (rec.primary or rec.entry)
        if not entry then return end
        local lines = {
            "Source: " .. (rec.isMine and "You" or tostring(rec.authorLabel)),
            "Category: " .. (entry.category or "Other"),
        }
        if self._listType == ns.LIST_BLACK then
            lines[#lines + 1] = "Severity: " .. (ns.SEVERITY_LABELS[entry.severity or 2] or "Warn")
        end
        if rec.isMine and entry.share == false then
            lines[#lines + 1] = { text = "Visibility: Local only (not synced)", r = 0.72, g = 0.72, b = 0.72 }
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

        if rec.sameAsPrimaryPeers and #rec.sameAsPrimaryPeers > 0 then
            lines[#lines + 1] = {
                text = "Also listed identically by: " .. FormatAuthorsSummary(rec.sameAsPrimaryPeers, false),
                r = 0.65, g = 0.80, b = 1.0,
            }
        end

        if rec.distinctPeerGroups and #rec.distinctPeerGroups > 0 then
            lines[#lines + 1] = { text = "Other Peer Notes:", r = 0.56, g = 0.72, b = 1.0 }
            for i = 1, #rec.distinctPeerGroups do
                local g = rec.distinctPeerGroups[i]
                local auths = FormatAuthorsSummary(g.authors, false)
                local sev = (g.listType == ns.LIST_BLACK) and (" [" .. (ns.SEVERITY_LABELS[g.severity or 2] or "Warn") .. "]") or ""
                local note = (g.sharedNote ~= "" and g.sharedNote) or (g.context ~= "" and ("Context: " .. g.context)) or "(No note)"
                lines[#lines + 1] = {
                    text = string.format("%s (%s%s): %s", auths, g.category or "Other", sev, note),
                    r = 0.88, g = 0.88, b = 0.92,
                }
            end
        end

        if rec.conflictGroups and #rec.conflictGroups > 0 then
            local oppWord = (self._listType == ns.LIST_GREEN) and "Bad Boi" or "Good Boi"
            local cr, cg, cb
            if self._listType == ns.LIST_GREEN then
                cr, cg, cb = Theme:GetBadRGB()
            else
                cr, cg, cb = Theme:GetGoodRGB()
            end
            lines[#lines + 1] = { text = "Conflicting Peer Entries (" .. oppWord .. "):", r = cr, g = cg, b = cb }
            for i = 1, #rec.conflictGroups do
                local g = rec.conflictGroups[i]
                local auths = FormatAuthorsSummary(g.authors, false)
                local sev = (g.listType == ns.LIST_BLACK) and (" [" .. (ns.SEVERITY_LABELS[g.severity or 2] or "Warn") .. "]") or ""
                local note = (g.sharedNote ~= "" and g.sharedNote) or (g.context ~= "" and ("Context: " .. g.context)) or "(No note)"
                lines[#lines + 1] = {
                    text = string.format("%s (%s%s): %s", auths, g.category or "Other", sev, note),
                    r = 0.92, g = 0.88, b = 0.88,
                }
            end
        end

        lines[#lines + 1] = {
            text = rec.hasExpandableDetails and "Left-click to expand/collapse · Right-click for options" or "Right-click for options",
            r = 0.55, g = 0.55, b = 0.55,
        }
        Theme:ShowTooltip(self, entry.name or entry.key, lines, self._classRGB)
    end
end

local function Row_OnLeave(self)
    if not (self.IsMouseOver and self:IsMouseOver()) then
        SetRowHovered(self, false)
    end
    Theme:HideTooltip()
end

local function Row_OnMouseUp(self, button)
    if self._mode == "entry" and self._rec then
        local rec = self._rec
        if button == "LeftButton" and rec.hasExpandableDetails then
            local expandKey = tostring(rec.listType) .. ":" .. tostring(rec.key)
            uiState.expandedKeys[expandKey] = not uiState.expandedKeys[expandKey] and true or nil
            if RepaintEntriesList then RepaintEntriesList() end
        elseif button == "RightButton" then
            OpenEntryContextMenu(self, rec)
        end
    elseif self._mode == "subrow" and self._rec and self._group then
        if button == "RightButton" then
            OpenEntryContextMenu(self, self._rec, nil, self._group)
        end
    end
end

local function RowBtn_OnEnter(self)
    if self._row then SetRowHovered(self._row, true) end
    local c = self._baseBrd
    self._bg:SetColorTexture(Theme.BG_BTN.r, Theme.BG_BTN.g, Theme.BG_BTN.b, 0.92)
    self._brd:SetColor(c[1], c[2], c[3], math.min(1, c[4] + 0.25))
    self._lbl:SetTextColor(1, 1, 1, 1)
    if self._tooltipText then
        Theme:ShowTooltip(self, self._tooltipText)
    end
end

local function RowBtn_OnLeave(self)
    if self._row and not (self._row.IsMouseOver and self._row:IsMouseOver()) then
        SetRowHovered(self._row, false)
    end
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
    local act = self._action
    if not (row and act) then return end

    if act == "recent_edit" then
        local item = row._item
        local personal = row._personalEntry
        if personal and ns.QuickModal then
            ns.QuickModal:Open({
                name = personal.name,
                guid = personal.guid or (item and item.guid),
                class = personal.class or (item and item.class),
                entry = personal,
            })
        end
        return
    elseif act == "recent_black" or act == "recent_green" then
        local item = row._item
        if item and ns.QuickModal then
            ns.QuickModal:Open({
                name = item.name,
                guid = item.guid,
                class = item.class,
                context = item.context,
                listType = (act == "recent_green") and ns.LIST_GREEN or ns.LIST_BLACK,
            })
        end
        return
    end

    if act == "dismiss_group" then
        local rec = row._rec
        local g = row._group
        if rec and g and g.authors then
            local ids = {}
            for i = 1, #g.authors do
                if g.authors[i].authorID then
                    ids[#ids + 1] = g.authors[i].authorID
                end
            end
            DB:DismissPeerEntries(ids, rec.key)
        end
        return
    end

    local rec = row._rec
    local entry = rec and (rec.primary or rec.entry)
    if not entry then return end

    if act == "remove" then
        ConfirmRemoveEntry(entry)
    elseif act == "edit" then
        if ns.QuickModal then
            ns.QuickModal:Open({
                name = entry.name,
                guid = rec.guid or entry.guid,
                class = rec.class or entry.class,
                entry = entry,
            })
        end
    elseif act == "ignore" then
        DB:ToggleNativeIgnore(entry.key)
    elseif act == "adopt" then
        DB:AdoptPeerEntry(entry, {
            guid = rec.guid,
            class = rec.class,
            listType = row._listType,
        })
        ns.Print("Saved " .. tostring(entry.name or rec.key) .. " to your personal list (local only).")
    elseif act == "peer_menu" then
        OpenEntryContextMenu(self, rec, { below = true })
    end
end

local function InitRowButton(btn, row)
    btn._row = row
    btn:SetScript("OnEnter", RowBtn_OnEnter)
    btn:SetScript("OnLeave", RowBtn_OnLeave)
    btn:SetScript("OnClick", RowBtn_OnClick)
end

local function GetOrCreateRow(parent, idx, rowW)
    local row = uiState.rowPool[idx]
    if not row then
        row = CreateFrame("Frame", nil, parent)
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

        local stripe = Theme:SolidTex(row, "ARTWORK", 1, 0.3, 0.3, 0.9)
        stripe:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        stripe:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        stripe:SetWidth(3)
        row._stripe = stripe

        local nameFS = Theme:MakeFont(row, 14, "", 1, 1, 1, 0.96)
        nameFS:SetPoint("TOPLEFT", row, "TOPLEFT", 14, -8)
        nameFS:SetJustifyH("LEFT")
        nameFS:SetWordWrap(false)
        row._nameFS = nameFS

        local metaFS = Theme:MakeFont(row, 11, "", 1, 1, 1, 0.62)
        metaFS:SetPoint("LEFT", nameFS, "RIGHT", 10, 0)
        metaFS:SetJustifyH("LEFT")
        metaFS:SetWordWrap(false)
        row._metaFS = metaFS

        local timeFS = Theme:MakeFont(row, 11, "", 1, 1, 1, 0.44)
        timeFS:SetPoint("TOPRIGHT", row, "TOPRIGHT", -14, -10)
        timeFS:SetJustifyH("RIGHT")
        timeFS:SetWordWrap(false)
        row._timeFS = timeFS

        local noteFS = Theme:MakeFont(row, 12, "", 0.88, 0.88, 0.88, 0.86)
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

        row:SetScript("OnEnter", Row_OnEnter)
        row:SetScript("OnLeave", Row_OnLeave)
        row:SetScript("OnMouseUp", Row_OnMouseUp)

        uiState.rowPool[idx] = row
    end

    if row._hoverBg then row._hoverBg:Hide() end
    row:SetParent(parent)
    row:SetSize(rowW, 52)
    row:Show()
    return row
end

local function GetOrCreateSubRow(parent, idx, rowW)
    local row = uiState.subRowPool[idx]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:EnableMouse(true)

        local bg = Theme:SolidTex(row, "BACKGROUND", 0, 0, 0, 0.28)
        bg:SetAllPoints()
        row._bg = bg

        local hoverBg = Theme:SolidTex(row, "BACKGROUND", 1, 1, 1, 0.04)
        hoverBg:SetAllPoints()
        hoverBg:SetDrawLayer("BACKGROUND", 1)
        hoverBg:Hide()
        row._hoverBg = hoverBg

        local div = Theme:SolidTex(row, "BORDER", 1, 1, 1, 0.03)
        div:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        div:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        div:SetHeight(1)

        local stripe = Theme:SolidTex(row, "ARTWORK", 0.56, 0.72, 1.0, 0.75)
        stripe:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        stripe:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        stripe:SetWidth(2)
        row._stripe = stripe

        local metaFS = Theme:MakeFont(row, 11, "", 1, 1, 1, 0.65)
        metaFS:SetPoint("TOPLEFT", row, "TOPLEFT", 12, -4)
        metaFS:SetPoint("RIGHT", row, "RIGHT", -78, 0)
        metaFS:SetJustifyH("LEFT")
        metaFS:SetWordWrap(false)
        row._metaFS = metaFS

        local noteFS = Theme:MakeFont(row, 11, "", 0.85, 0.85, 0.85, 0.86)
        noteFS:SetPoint("TOPLEFT", metaFS, "BOTTOMLEFT", 0, -2)
        noteFS:SetPoint("RIGHT", row, "RIGHT", -78, 0)
        noteFS:SetJustifyH("LEFT")
        noteFS:SetWordWrap(false)
        row._noteFS = noteFS

        local dismissBtn = Theme:MakeButton(row, "Dismiss", 58, 20, 10)
        dismissBtn:SetPoint("RIGHT", row, "RIGHT", -10, 0)
        InitRowButton(dismissBtn, row)
        dismissBtn._baseBrd = { 1, 1, 1, 0.20 }
        dismissBtn._brd:SetColor(1, 1, 1, 0.20)
        dismissBtn._tooltipText = "Hide this synced note locally without muting the peer."
        dismissBtn._action = "dismiss_group"
        row._dismissBtn = dismissBtn

        row:SetScript("OnEnter", Row_OnEnter)
        row:SetScript("OnLeave", Row_OnLeave)
        row:SetScript("OnMouseUp", Row_OnMouseUp)

        uiState.subRowPool[idx] = row
    end

    if row._hoverBg then row._hoverBg:Hide() end
    row:SetParent(parent)
    row:SetSize(rowW, 36)
    row:Show()
    return row
end

RepaintEntriesList = function()
    local parent = uiState.activeParent
    local pageName = uiState.activePage
    if not (parent and pageName) then return 100 end
    if pageName ~= PAGE_BAD and pageName ~= PAGE_GOOD and pageName ~= PAGE_RECENT then return 100 end

    HidePooledRows()

    local eui = _G.EllesmereUI
    local pad = (eui and eui.CONTENT_PAD) or 40
    local totalW = parent:GetWidth()
    if not totalW or totalW < 200 then totalW = 1005 end
    local rowW = totalW - pad * 2
    local y = -6

    local goodHex = Theme:GetGoodHex()
    local badHex = Theme:GetBadHex()
    local gr, gg, gb = Theme:GetGoodRGB()
    local br, bg, bb = Theme:GetBadRGB()

    if pageName == PAGE_RECENT then
        local recent = DB:GetRecentTeammates(uiState.search)
        if #recent == 0 then
            if not uiState.emptyFS then
                uiState.emptyFS = Theme:MakeFont(parent, 12, "", 1, 1, 1, 0.45)
            end
            uiState.emptyFS:SetParent(parent)
            uiState.emptyFS:ClearAllPoints()
            uiState.emptyFS:SetPoint("TOP", parent, "TOP", 0, -28)
            uiState.emptyFS:SetText("No recent teammates recorded yet. Group up to auto-log players.")
            uiState.emptyFS:Show()
            return 100
        end

        for i = 1, #recent do
            local item = recent[i]
            local row = GetOrCreateRow(parent, i, rowW)
            uiState.activeRows[#uiState.activeRows + 1] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", parent, "TOPLEFT", pad, y)

            row._bg:SetColorTexture(0, 0, 0, (i % 2 == 1) and Theme.ROW_ODD_A or Theme.ROW_EVEN_A)

            local cr, cg, cb = Guard.GetClassRGB(item.class)
            row._nameFS:SetTextColor(1, 1, 1, 1)
            row._nameFS:SetText(Guard.FormatPlayerNameColored(item.name or "?", cr, cg, cb))
            if row._timeFS then row._timeFS:Hide() end

            local match = DB:Lookup(item.name, item.guid, true)
            if match then
                if match.effectiveType == ns.LIST_GREEN then
                    row._stripe:SetColorTexture(gr, gg, gb, 0.95)
                else
                    row._stripe:SetColorTexture(br, bg, bb, 0.95)
                end
            else
                row._stripe:SetColorTexture(1, 1, 1, 0.14)
            end

            local roleTxt = Guard.FormatRole(item.role)
            local seenTxt = Guard.FormatRelativeTime(item.seenAt)
            row._metaFS:SetText(string.format("%s%s%s", roleTxt, SEP, seenTxt))

            local ctx = (item.context and item.context ~= "") and ("Last seen: " .. item.context) or "Last seen in group"
            if match then
                local lbl
                if match.personal then
                    lbl = match.effectiveType == ns.LIST_GREEN
                        and (goodHex .. "[Good Boi]|r ")
                        or (badHex .. "[Bad Boi]|r ")
                else
                    lbl = match.effectiveType == ns.LIST_GREEN
                        and (goodHex .. "[Peer: Good Boi]|r ")
                        or (badHex .. "[Peer: Bad Boi]|r ")
                end
                row._noteFS:SetText(lbl .. ctx)
            else
                row._noteFS:SetText(ctx)
            end

            row._mode = "recent"
            row._item = item
            row._rec = nil
            row._personalEntry = match and match.personal or nil
            row._roleTxt = roleTxt
            row._ctx = ctx
            row._seenTxt = seenTxt
            row._classRGB = row._classRGB or { 1, 1, 1 }
            row._classRGB[1], row._classRGB[2], row._classRGB[3] = cr, cg, cb

            row._btn3:Hide()
            if match and match.personal then
                row._btn2:Hide()
                row._btn1:SetSize(66, 24)
                row._btn1:Show()
                SetRowTextRightBound(row, -92)

                row._btn1._lbl:SetText("Edit")
                row._btn1._baseBrd = { 1, 1, 1, 0.24 }
                row._btn1._brd:SetColor(1, 1, 1, 0.24)
                row._btn1._tooltipText = "Edit your note for this player."
                row._btn1._action = "recent_edit"
            else
                row._btn2:SetSize(78, 24)
                row._btn1:SetSize(84, 24)
                row._btn2:Show()
                row._btn1:Show()
                SetRowTextRightBound(row, -192)

                row._btn2._lbl:SetText("+ Bad Boi")
                row._btn2._baseBrd = { br, bg, bb, 0.65 }
                row._btn2._brd:SetColor(br, bg, bb, 0.65)
                row._btn2._tooltipText = nil
                row._btn2._action = "recent_black"

                row._btn1._lbl:SetText("+ Good Boi")
                row._btn1._baseBrd = { gr, gg, gb, 0.65 }
                row._btn1._brd:SetColor(gr, gg, gb, 0.65)
                row._btn1._tooltipText = nil
                row._btn1._action = "recent_green"
            end

            y = y - 52
        end
    else
        local listType = (pageName == PAGE_GOOD) and ns.LIST_GREEN or ns.LIST_BLACK
        local minSev = (listType == ns.LIST_BLACK) and (uiState.minSeverity or 1) or nil
        local items = DB:QueryEntries(listType, uiState.sourceFilter, uiState.search, uiState.sortBy, nil, minSev)

        uiState.lastShownCountByPage[pageName] = #items
        local upd = uiState.summaryUpdaterByPage[pageName]
        if upd then upd(#items) end

        if #items == 0 then
            if not uiState.emptyFS then
                uiState.emptyFS = Theme:MakeFont(parent, 12, "", 1, 1, 1, 0.45)
            end
            uiState.emptyFS:SetParent(parent)
            uiState.emptyFS:ClearAllPoints()
            uiState.emptyFS:SetPoint("TOP", parent, "TOP", 0, -28)
            uiState.emptyFS:SetText("No entries match the current filter. Click + Add above or right-click any player.")
            uiState.emptyFS:Show()
            return 100
        end

        local subIdx = 0
        for i = 1, #items do
            local rec = items[i]
            local entry = rec.primary or rec.entry
            local row = GetOrCreateRow(parent, i, rowW)
            uiState.activeRows[#uiState.activeRows + 1] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", parent, "TOPLEFT", pad, y)

            row._bg:SetColorTexture(0, 0, 0, (i % 2 == 1) and Theme.ROW_ODD_A or Theme.ROW_EVEN_A)
            if listType == ns.LIST_GREEN then
                row._stripe:SetColorTexture(gr, gg, gb, rec.isMine and 0.95 or 0.55)
            else
                local sev = rec.maxSeverity or entry.severity or 2
                local sa = (sev == 3 and 1.0) or (sev == 2 and 0.78) or 0.42
                if not rec.isMine then sa = sa * 0.65 end
                row._stripe:SetColorTexture(br, bg, bb, sa)
            end

            local cr, cg, cb = Guard.GetClassRGB(rec.class or entry.class)
            row._nameFS:SetTextColor(1, 1, 1, 1)
            row._nameFS:SetText(Guard.FormatPlayerNameColored(rec.name or entry.name or rec.key, cr, cg, cb))
            if row._timeFS then
                row._timeFS:SetText(Guard.FormatRelativeTime(rec.latestUpdatedAt or entry.updatedAt))
            end

            local expandKey = tostring(listType) .. ":" .. tostring(rec.key)
            local isExpanded = rec.hasExpandableDetails and (uiState.expandedKeys[expandKey] == true)
            local expandHint = isExpanded and "[-]" or "[+]"

            local tags = {}
            if rec.isMine then
                if rec.distinctNoteCount > 0 then
                    tags[#tags + 1] = "|cff8fb8ff+" .. rec.distinctNoteCount .. " peer " .. (rec.distinctNoteCount == 1 and "note" or "notes") .. " " .. expandHint .. "|r"
                elseif rec.peerCount == 1 then
                    tags[#tags + 1] = "|cff8fb8ff+ " .. tostring(rec.peers[1].shortLabel or rec.peers[1].authorLabel) .. "|r"
                elseif rec.peerCount > 1 then
                    tags[#tags + 1] = "|cff8fb8ff+" .. rec.peerCount .. " peers|r"
                end
                if entry.share == false then
                    tags[#tags + 1] = "|cff888888Local|r"
                end
                if listType == ns.LIST_BLACK and entry.nativeIgnore == true then
                    tags[#tags + 1] = "|cff999999Ignored|r"
                end
            else
                if rec.distinctNoteCount > 0 then
                    tags[#tags + 1] = "|cff8fb8ff" .. tostring(rec.primaryShortLabel) .. " (+" .. rec.distinctNoteCount .. " " .. (rec.distinctNoteCount == 1 and "note" or "notes") .. ") " .. expandHint .. "|r"
                elseif rec.peerCount > 1 then
                    tags[#tags + 1] = "|cff8fb8ff" .. tostring(rec.primaryShortLabel) .. " +" .. (rec.peerCount - 1) .. "|r"
                else
                    tags[#tags + 1] = "|cff8fb8ff" .. tostring(rec.primaryShortLabel) .. "|r"
                end
            end

            if rec.conflictCount > 0 then
                local oppWord = (listType == ns.LIST_GREEN) and "Bad Boi" or "Good Boi"
                local oppHex = (listType == ns.LIST_GREEN) and badHex or goodHex
                local cSuffix = (rec.distinctNoteCount == 0) and (" " .. expandHint) or ""
                local cPrefix = (rec.conflictCount == 1) and "! Peer: " or ("! " .. rec.conflictCount .. " peers: ")
                tags[#tags + 1] = oppHex .. cPrefix .. oppWord .. cSuffix .. "|r"
            end

            local metaPrefix = (#tags > 0) and (table.concat(tags, "  ") .. "  ") or ""
            local sevTag = (listType == ns.LIST_BLACK) and (SEP .. (SEVERITY_COLOR_LABELS[entry.severity or 2] or "Warn")) or ""
            row._metaFS:SetText(string.format("%s%s%s", metaPrefix, entry.category or "Other", sevTag))

            local notePreview = (entry.sharedNote ~= "" and entry.sharedNote) or ""
            if rec.isMine and entry.privateNote and entry.privateNote ~= "" then
                notePreview = (notePreview ~= "" and (notePreview .. "  |cff999999[Private: " .. entry.privateNote .. "]|r")
                    or ("|cff999999[Private: " .. entry.privateNote .. "]|r"))
            end
            if notePreview == "" and rec.isMine and rec.distinctPeerGroups and rec.distinctPeerGroups[1] then
                local g = rec.distinctPeerGroups[1]
                if g.sharedNote and g.sharedNote ~= "" and g.authors and g.authors[1] then
                    notePreview = "|cff8fb8ff" .. tostring(g.authors[1].shortLabel or g.authors[1].authorLabel) .. ":|r " .. g.sharedNote
                end
            end
            if notePreview == "" then
                notePreview = (entry.context and entry.context ~= "") and ("Context: " .. entry.context) or "(No note)"
            end
            row._noteFS:SetText(notePreview)

            row._mode = "entry"
            row._rec = rec
            row._item = nil
            row._personalEntry = nil
            row._listType = listType
            row._pageName = pageName
            row._classRGB = row._classRGB or { 1, 1, 1 }
            row._classRGB[1], row._classRGB[2], row._classRGB[3] = cr, cg, cb

            if rec.isMine then
                row._btn1:SetSize(70, 24)
                row._btn2:SetSize(62, 24)
                row._btn3:SetSize(70, 24)
                row._wantBtn1 = true
                row._wantBtn2 = true

                row._btn1._lbl:SetText("Remove")
                row._btn1._baseBrd = { br, bg, bb, 0.55 }
                row._btn1._brd:SetColor(br, bg, bb, 0.55)
                row._btn1._tooltipText = nil
                row._btn1._action = "remove"

                row._btn2._lbl:SetText("Edit")
                row._btn2._baseBrd = { 1, 1, 1, 0.24 }
                row._btn2._brd:SetColor(1, 1, 1, 0.24)
                row._btn2._tooltipText = nil
                row._btn2._action = "edit"

                if listType == ns.LIST_BLACK then
                    row._wantBtn3 = true
                    row._btn3._lbl:SetText(entry.nativeIgnore and "Ignored" or "/ignore")
                    if entry.nativeIgnore then
                        row._btn3._baseBrd = { gr, gg, gb, 0.85 }
                        row._btn3._brd:SetColor(gr, gg, gb, 0.85)
                    else
                        row._btn3._baseBrd = { 1, 1, 1, 0.20 }
                        row._btn3._brd:SetColor(1, 1, 1, 0.20)
                    end
                    row._btn3._tooltipText = "Toggle Blizzard native /ignore for this player."
                    row._btn3._action = "ignore"
                    row._hoverRightPad = -230
                else
                    row._wantBtn3 = false
                    row._hoverRightPad = -156
                end
            else
                row._wantBtn3 = false
                row._wantBtn2 = true
                row._wantBtn1 = true
                row._btn1:SetSize(28, 24)
                row._btn2:SetSize(94, 24)
                row._hoverRightPad = -148

                row._btn2._lbl:SetText("Save to Mine")
                if listType == ns.LIST_GREEN then
                    row._btn2._baseBrd = { gr, gg, gb, 0.55 }
                    row._btn2._brd:SetColor(gr, gg, gb, 0.55)
                else
                    row._btn2._baseBrd = { 1, 1, 1, 0.28 }
                    row._btn2._brd:SetColor(1, 1, 1, 0.28)
                end
                row._btn2._tooltipText = "Save a local copy to your personal list (not re-shared until edited)."
                row._btn2._action = "adopt"

                row._btn1._lbl:SetText("...")
                row._btn1._baseBrd = { 1, 1, 1, 0.24 }
                row._btn1._brd:SetColor(1, 1, 1, 0.24)
                row._btn1._tooltipText = "More peer actions (Save & Edit, Dismiss entry, Mute peer)."
                row._btn1._action = "peer_menu"
            end

            SetRowHovered(row, row.IsMouseOver and row:IsMouseOver() or false)
            y = y - 52

            if isExpanded then
                local function RenderSubGroupList(groups, isConflict)
                    if not groups then return end
                    for gi = 1, #groups do
                        local g = groups[gi]
                        subIdx = subIdx + 1
                        local sr = GetOrCreateSubRow(parent, subIdx, rowW - 18)
                        uiState.activeSubRows[#uiState.activeSubRows + 1] = sr
                        sr:ClearAllPoints()
                        sr:SetPoint("TOPLEFT", parent, "TOPLEFT", pad + 18, y)

                        if isConflict then
                            if g.listType == ns.LIST_GREEN then
                                sr._stripe:SetColorTexture(gr, gg, gb, 0.85)
                            else
                                sr._stripe:SetColorTexture(br, bg, bb, 0.85)
                            end
                        else
                            sr._stripe:SetColorTexture(0.56, 0.72, 1.0, 0.75)
                        end

                        local authTxt = FormatAuthorsSummary(g.authors, true, 3)
                        local cBadge = ""
                        if isConflict then
                            cBadge = (g.listType == ns.LIST_GREEN) and (goodHex .. " [Good Boi]|r") or (badHex .. " [Bad Boi]|r")
                        end
                        local gSev = (g.listType == ns.LIST_BLACK) and (SEP .. (SEVERITY_COLOR_LABELS[g.severity or 2] or "Warn")) or ""
                        sr._metaFS:SetText(string.format("|cff8fb8ff%s|r%s  %s%s%s%s", authTxt, cBadge, g.category or "Other", gSev, SEP, Guard.FormatRelativeTime(g.updatedAt)))

                        local gNote = (g.sharedNote ~= "" and g.sharedNote)
                            or (g.context and g.context ~= "" and ("Context: " .. g.context))
                            or "(No note)"
                        sr._noteFS:SetText(gNote)

                        sr._mode = "subrow"
                        sr._rec = rec
                        sr._group = g
                        sr._classRGB = sr._classRGB or { 1, 1, 1 }
                        sr._classRGB[1], sr._classRGB[2], sr._classRGB[3] = cr, cg, cb
                        SetRowHovered(sr, sr.IsMouseOver and sr:IsMouseOver() or false)

                        y = y - 36
                    end
                end
                RenderSubGroupList(rec.distinctPeerGroups, false)
                RenderSubGroupList(rec.conflictGroups, true)
            end
        end
    end

    local totalH = math.max(100, math.abs(y) + 16)
    local scrollChild = parent:GetParent()
    if scrollChild and scrollChild.SetHeight then
        scrollChild:SetHeight(totalH + 20)
    end
    return totalH
end

local function FormatCountSummary(listType, pageName, shownCount)
    local total, mine, peerOnly, shared
    if DB.GetListCounts then
        total, mine, peerOnly, shared = DB:GetListCounts(listType)
    else
        local c = DB:GetCounts()
        if listType == ns.LIST_GREEN then
            mine, peerOnly = c.myGreen or 0, c.peerOnlyGreen or 0
        else
            mine, peerOnly = c.myBlack or 0, c.peerOnlyBlack or 0
        end
        total = mine + peerOnly
        shared = 0
    end

    if shownCount ~= nil and shownCount ~= total then
        return string.format("Showing %d of %d %s", shownCount, total, pageName)
    end

    local parts = {
        string.format("%d %s", total, total == 1 and "player" or "players"),
        string.format("%d yours", mine),
    }
    if (peerOnly or 0) > 0 then
        parts[#parts + 1] = string.format("%d from peers", peerOnly)
    elseif (shared or 0) > 0 then
        parts[#parts + 1] = string.format("%d also on peers", shared)
    end
    return table.concat(parts, "  |  ")
end

local function BuildSearchToolbar(headerFrame, pad, innerW, y, pageName, includeFilters, onUpdateSummary, listType)
    local isBadPage = (includeFilters and pageName == PAGE_BAD)
    local rightUsed = includeFilters and (isBadPage and 412 or 314) or 112
    local searchW = math.max(150, innerW - rightUsed)
    local placeholder = (pageName == PAGE_BAD and "Filter Bad Bois by name, tag, note, or friend...")
        or (pageName == PAGE_GOOD and "Filter Good Bois by name, tag, note, or friend...")
        or "Filter recent teammates by name, role, or zone..."

    local searchHolder, searchBox = Theme:MakeEditBox(headerFrame, searchW, 28, placeholder)
    searchHolder:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", pad, y)
    searchBox:SetFont(Theme:GetFont(), 12, "")
    searchBox:SetTextInsets(10, 26, 0, 0)
    searchBox:SetText(uiState.search or "")

    local suppressDebounce = false

    local clearBtn = CreateFrame("Button", nil, searchHolder)
    clearBtn:SetSize(20, 20)
    clearBtn:SetPoint("RIGHT", searchHolder, "RIGHT", -5, 0)
    clearBtn:SetFrameLevel(searchBox:GetFrameLevel() + 2)
    local clearLbl = Theme:MakeFont(clearBtn, 11, "", 1, 1, 1, 0.5)
    clearLbl:SetPoint("CENTER")
    clearLbl:SetText("X")
    clearBtn:SetShown((uiState.search or "") ~= "")
    clearBtn:SetScript("OnEnter", function() clearLbl:SetTextColor(1, 1, 1, 0.95) end)
    clearBtn:SetScript("OnLeave", function() clearLbl:SetTextColor(1, 1, 1, 0.5) end)
    clearBtn:SetScript("OnClick", function()
        if uiState.searchTimer then
            uiState.searchTimer:Cancel()
            uiState.searchTimer = nil
        end
        uiState.search = ""
        suppressDebounce = true
        searchBox:SetText("")
        suppressDebounce = false
        searchBox:ClearFocus()
        RepaintEntriesList()
        if onUpdateSummary then onUpdateSummary() end
    end)

    searchBox:SetScript("OnTextChanged", function(self)
        local txt = self:GetText() or ""
        searchHolder.placeholder:SetShown(txt == "")
        clearBtn:SetShown(txt ~= "")
        if suppressDebounce then return end
        if uiState.searchTimer then
            uiState.searchTimer:Cancel()
            uiState.searchTimer = nil
        end
        uiState.searchTimer = C_Timer.NewTimer(0.12, function()
            uiState.searchTimer = nil
            uiState.search = txt
            RepaintEntriesList()
            if onUpdateSummary then onUpdateSummary() end
        end)
    end)

    if includeFilters then
        local addTint = (listType == ns.LIST_GREEN) and "green" or "red"
        local addBtn = MakeEUIButton(headerFrame, "+ Add", 82, 28, 12, function()
            if ns.QuickModal then
                ns.QuickModal:Open({ listType = listType })
            end
        end, addTint, "Add a player to " .. pageName .. ".")
        addBtn:SetPoint("TOPRIGHT", headerFrame, "TOPLEFT", pad + innerW, y)

        local sortCycle = { newest = "name", name = "category", category = "newest" }
        local sortLbls = { newest = "Sort: Newest", name = "Sort: Name", category = "Sort: Tag" }
        local sortBtn = MakeEUIButton(headerFrame, sortLbls[uiState.sortBy], 102, 28, 12, function(self)
            uiState.sortBy = sortCycle[uiState.sortBy] or "newest"
            self._lbl:SetText(sortLbls[uiState.sortBy])
            RepaintEntriesList()
        end, nil, "Sort list by Newest, Name, or Category.")
        sortBtn:SetPoint("RIGHT", addBtn, "LEFT", -6, 0)

        local srcCycle = { all = "mine", mine = "peers", peers = "all" }
        local srcLbls = { all = "Src: All", mine = "Src: Mine", peers = "Src: Peer-Only" }
        local srcBtn = MakeEUIButton(headerFrame, srcLbls[uiState.sourceFilter], 106, 28, 12, function(self)
            uiState.sourceFilter = srcCycle[uiState.sourceFilter] or "all"
            self._lbl:SetText(srcLbls[uiState.sourceFilter])
            RepaintEntriesList()
            if onUpdateSummary then onUpdateSummary() end
        end, nil, "Filter source: All players, Your list only, or Peer-only players not on your list.")
        srcBtn:SetPoint("RIGHT", sortBtn, "LEFT", -6, 0)

        local sevFilterBtn
        local sevFilterLbls = { [1] = "Sev: All", [2] = "Sev: Warn+", [3] = "Sev: Avoid" }
        if isBadPage then
            sevFilterBtn = MakeEUIButton(headerFrame, sevFilterLbls[uiState.minSeverity or 1], 92, 28, 12, function(self)
                uiState.minSeverity = ((uiState.minSeverity or 1) % 3) + 1
                self._lbl:SetText(sevFilterLbls[uiState.minSeverity])
                RepaintEntriesList()
                if onUpdateSummary then onUpdateSummary() end
            end, nil, "Filter Bad Bois by minimum severity: All, Warn+, or Hard Avoid.")
            sevFilterBtn:SetPoint("RIGHT", srcBtn, "LEFT", -6, 0)
        end

        return function()
            if (searchBox:GetText() or "") ~= (uiState.search or "") then
                if uiState.searchTimer then
                    uiState.searchTimer:Cancel()
                    uiState.searchTimer = nil
                end
                suppressDebounce = true
                searchBox:SetText(uiState.search or "")
                suppressDebounce = false
            end
            clearBtn:SetShown((uiState.search or "") ~= "")
            sortBtn._lbl:SetText(sortLbls[uiState.sortBy])
            srcBtn._lbl:SetText(srcLbls[uiState.sourceFilter])
            if sevFilterBtn then
                sevFilterBtn._lbl:SetText(sevFilterLbls[uiState.minSeverity or 1])
            end
        end
    else
        local clrBtn = MakeEUIButton(headerFrame, "Clear Recent", 104, 28, 12, function()
            if DB:Root() then wipe(DB:Root().recent) end
            RepaintEntriesList()
        end)
        clrBtn:SetPoint("TOPRIGHT", headerFrame, "TOPLEFT", pad + innerW, y)
        return function()
            if (searchBox:GetText() or "") ~= (uiState.search or "") then
                if uiState.searchTimer then
                    uiState.searchTimer:Cancel()
                    uiState.searchTimer = nil
                end
                suppressDebounce = true
                searchBox:SetText(uiState.search or "")
                suppressDebounce = false
            end
            clearBtn:SetShown((uiState.search or "") ~= "")
        end
    end
end

local function BuildEntryPageHeader(headerFrame, width, pageName, listType)
    local eui = _G.EllesmereUI
    local pad = (eui and eui.CONTENT_PAD) or 40
    local innerW = math.max(540, width - pad * 2)

    local countFS = Theme:MakeFont(headerFrame, 11, "", 1, 1, 1, 0.48)
    countFS:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", pad, -8)
    countFS:SetJustifyH("LEFT")

    local syncStatusBtn = CreateFrame("Button", nil, headerFrame)
    syncStatusBtn:SetHeight(18)
    syncStatusBtn:SetPoint("TOPRIGHT", headerFrame, "TOPLEFT", pad + innerW, -6)
    local syncLbl = Theme:MakeFont(syncStatusBtn, 11, "", 1, 1, 1, 0.72)
    syncLbl:SetPoint("RIGHT", syncStatusBtn, "RIGHT", -2, 0)
    syncLbl:SetJustifyH("RIGHT")

    local function RefreshSyncStatusText(hovering)
        local onlineCount = Sync.GetOnlinePeerCount and Sync:GetOnlinePeerCount() or 0
        if onlineCount > 0 then
            local pWord = (onlineCount == 1) and "peer" or "peers"
            local syncHex = hovering and "|cffffffff" or "|cffbbbbbb"
            syncLbl:SetText(Theme:GetGoodHex() .. onlineCount .. " " .. pWord .. " online|r  |cff555555/|r  " .. syncHex .. "Sync|r")
        else
            local syncHex = hovering and "|cffffffff" or "|cff777777"
            syncLbl:SetText(syncHex .. "Sync|r")
        end
        local tw = syncLbl:GetStringWidth() or 40
        syncStatusBtn:SetWidth(math.max(44, math.ceil(tw + 8)))
    end
    RefreshSyncStatusText(false)

    syncStatusBtn:SetScript("OnEnter", function(self)
        RefreshSyncStatusText(true)
        Theme:ShowTooltip(self, "Click to run a manual sync handshake now.")
    end)
    syncStatusBtn:SetScript("OnLeave", function()
        RefreshSyncStatusText(false)
        Theme:HideTooltip()
    end)
    syncStatusBtn:SetScript("OnClick", function()
        local status = Sync:SyncNow()
        ns.Print(Sync:FormatSyncStatus(status))
    end)

    local topDiv = Theme:SolidTex(headerFrame, "ARTWORK", 1, 1, 1, 0.05)
    topDiv:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", pad, -26)
    topDiv:SetSize(innerW, 1)

    local function UpdateSummary(shownCount)
        local sc = shownCount
        if sc == nil then sc = uiState.lastShownCountByPage[pageName] end
        countFS:SetText(FormatCountSummary(listType, pageName, sc))
        RefreshSyncStatusText(syncStatusBtn.IsMouseOver and syncStatusBtn:IsMouseOver() or false)
    end
    uiState.summaryUpdaterByPage[pageName] = UpdateSummary

    local refreshSearch = BuildSearchToolbar(headerFrame, pad, innerW, -33, pageName, true, UpdateSummary, listType)

    uiState.headerRefreshByPage[pageName] = function()
        if refreshSearch then refreshSearch() end
        UpdateSummary()
    end
    UpdateSummary()

    return 66
end

local function BuildListHeader(pageName)
    if pageName ~= PAGE_BAD and pageName ~= PAGE_GOOD and pageName ~= PAGE_RECENT then
        return nil
    end
    local existing = uiState.headerBuilders[pageName]
    if existing then return existing end

    local fn
    if pageName == PAGE_RECENT then
        fn = function(headerFrame, width)
            local eui = _G.EllesmereUI
            local pad = (eui and eui.CONTENT_PAD) or 40
            local innerW = math.max(540, width - pad * 2)
            local refreshSearch = BuildSearchToolbar(headerFrame, pad, innerW, -9, pageName, false)
            uiState.headerRefreshByPage[pageName] = refreshSearch
            return 46
        end
    else
        local listType = (pageName == PAGE_GOOD) and ns.LIST_GREEN or ns.LIST_BLACK
        fn = function(headerFrame, width)
            return BuildEntryPageHeader(headerFrame, width, pageName, listType)
        end
    end

    uiState.headerBuilders[pageName] = fn
    return fn
end

local function HidePooledPeerRows()
    for i = 1, #uiState.activePeerRows do
        uiState.activePeerRows[i]:Hide()
        uiState.activePeerRows[i] = nil
    end
    if uiState.peerEmptyFS then uiState.peerEmptyFS:Hide() end
end

local function PeerBtn_OnClick(self)
    local row = self._row
    local p = row and row._peerData
    if not p then return end
    local eui = _G.EllesmereUI
    local act = self._action
    if act == "purge" then
        DB:DeletePeerCache(p.authorID)
        if eui and eui.RefreshPage then eui:RefreshPage(true) end
    elseif act == "mute" then
        local trust = DB:GetPeerTrust(p.authorID)
        DB:SetPeerTrust(p.authorID, "muted", not trust.muted, p.label)
        if eui and eui.RefreshPage then eui:RefreshPage(true) end
    elseif act == "relay" then
        local trust = DB:GetPeerTrust(p.authorID)
        DB:SetPeerTrust(p.authorID, "relay", trust.relay == false, p.label)
        if eui and eui.RefreshPage then eui:RefreshPage(true) end
    end
end

local function PeerRow_OnEnter(self)
    local p = self._peerData
    if not p then return end
    local lines = {
        "Transport: " .. tostring(p.via or "SYNC"),
        "Entries: " .. tostring(p.count or 0) .. "  |  Rev: " .. tostring(p.lastRev or 0),
        p.online and "Status: Online now" or ("Last seen: " .. Guard.FormatRelativeTime(p.lastSeenAt)),
    }
    if (p.dismissedCount or 0) > 0 then
        lines[#lines + 1] = "Dismissed locally: " .. tostring(p.dismissedCount) .. " (right-click to restore)"
    end
    Theme:ShowTooltip(self, p.label, lines)
end

local function PeerRow_OnLeave()
    Theme:HideTooltip()
end

local function PeerRow_OnMouseUp(self, button)
    if button ~= "RightButton" then return end
    local p = self._peerData
    if not p then return end
    local dCount = DB:GetDismissedCount(p.authorID)
    if dCount <= 0 then return end
    Theme:ShowContextMenu(self, {
        {
            text = string.format("Restore Dismissed Entries (%d)", dCount),
            onClick = function()
                DB:ClearDismissedForPeer(p.authorID)
                local eui = _G.EllesmereUI
                if eui and eui.RefreshPage then eui:RefreshPage(true) end
            end,
        },
    })
end

local function GetOrCreatePeerRow(parent, idx, rowW)
    local row = uiState.peerRowPool[idx]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:EnableMouse(true)
        local bg = Theme:SolidTex(row, "BACKGROUND", 0, 0, 0, Theme.ROW_ODD_A)
        bg:SetAllPoints()
        row._bg = bg

        local dot = Theme:SolidTex(row, "ARTWORK", 0.5, 0.5, 0.5, 1)
        dot:SetSize(8, 8)
        dot:SetPoint("LEFT", row, "LEFT", 14, 0)
        row._dot = dot

        local title = Theme:MakeFont(row, 13, "", 1, 1, 1, 0.94)
        title:SetPoint("LEFT", dot, "RIGHT", 10, 7)
        title:SetWordWrap(false)
        row._title = title

        local sub = Theme:MakeFont(row, 11, "", 1, 1, 1, 0.58)
        sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
        sub:SetPoint("RIGHT", row, "RIGHT", -242, 0)
        sub:SetWordWrap(false)
        row._sub = sub

        local purgeBtn = Theme:MakeButton(row, "Purge", 66, 24, 11)
        purgeBtn:SetPoint("RIGHT", row, "RIGHT", -12, 0)
        purgeBtn._row = row
        purgeBtn._action = "purge"
        purgeBtn:SetScript("OnClick", PeerBtn_OnClick)
        row._purgeBtn = purgeBtn

        local muteBtn = Theme:MakeButton(row, "Active", 70, 24, 11)
        muteBtn:SetPoint("RIGHT", purgeBtn, "LEFT", -6, 0)
        muteBtn._row = row
        muteBtn._action = "mute"
        muteBtn:SetScript("OnClick", PeerBtn_OnClick)
        row._muteBtn = muteBtn

        local relayBtn = Theme:MakeButton(row, "Relay: On", 80, 24, 11)
        relayBtn:SetPoint("RIGHT", muteBtn, "LEFT", -6, 0)
        relayBtn._row = row
        relayBtn._action = "relay"
        relayBtn:SetScript("OnClick", PeerBtn_OnClick)
        row._relayBtn = relayBtn

        row:SetScript("OnEnter", PeerRow_OnEnter)
        row:SetScript("OnLeave", PeerRow_OnLeave)
        row:SetScript("OnMouseUp", PeerRow_OnMouseUp)

        uiState.peerRowPool[idx] = row
    end

    row:SetParent(parent)
    row:SetSize(rowW, 50)
    row:Show()
    return row
end

local function BuildPeerRows(parent, y)
    HidePooledPeerRows()

    local eui = _G.EllesmereUI
    local pad = (eui and eui.CONTENT_PAD) or 40
    local rowW = parent:GetWidth() - pad * 2
    local root = DB:Root()
    local online = Sync:GetOnlinePeers()

    local list = {}
    if root then
        for aid, peer in pairs(root.peers) do
            if type(peer) == "table" then
                local count = 0
                if type(peer.entries) == "table" then
                    for _, e in pairs(peer.entries) do
                        if type(e) == "table" and not e.deleted then count = count + 1 end
                    end
                end
                list[#list + 1] = {
                    authorID = aid,
                    label = peer.authorLabel or aid,
                    via = peer.via or "SYNC",
                    lastRev = peer.lastRev or 0,
                    lastSeenAt = peer.lastSeenAt or 0,
                    count = count,
                    online = online[aid] ~= nil,
                }
            end
        end
    end
    for aid, o in pairs(online) do
        if not (root and root.peers[aid]) then
            list[#list + 1] = {
                authorID = aid,
                label = o.authorLabel or aid,
                via = o.via or "SYNC",
                lastRev = o.rev or 0,
                lastSeenAt = o.lastHelloAt or time(),
                count = 0,
                online = true,
            }
        end
    end

    if #list == 0 then
        if not uiState.peerEmptyFS then
            uiState.peerEmptyFS = Theme:MakeFont(parent, 12, "", 1, 1, 1, 0.48)
        end
        uiState.peerEmptyFS:SetParent(parent)
        uiState.peerEmptyFS:ClearAllPoints()
        uiState.peerEmptyFS:SetPoint("TOPLEFT", parent, "TOPLEFT", pad, y - 8)
        uiState.peerEmptyFS:SetText("No peers synced yet. Online BNet friends or guildmates with THE LIST will appear here automatically.")
        uiState.peerEmptyFS:Show()
        return y - 36
    end

    table.sort(list, function(a, b)
        if a.online ~= b.online then return a.online end
        return (a.lastSeenAt or 0) > (b.lastSeenAt or 0)
    end)

    local gr, gg, gb = Theme:GetGoodRGB()
    local br, bg, bb = Theme:GetBadRGB()
    for i = 1, #list do
        local p = list[i]
        local trust = DB:GetPeerTrust(p.authorID)
        local dismissedCount = DB:GetDismissedCount(p.authorID)
        p.dismissedCount = dismissedCount

        local row = GetOrCreatePeerRow(parent, i, rowW)
        uiState.activePeerRows[#uiState.activePeerRows + 1] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", pad, y)
        row._peerData = p

        row._bg:SetColorTexture(0, 0, 0, (i % 2 == 1) and Theme.ROW_ODD_A or Theme.ROW_EVEN_A)
        row._dot:SetColorTexture(p.online and gr or 0.5, p.online and gg or 0.5, p.online and gb or 0.5, 1)
        row._title:SetText(p.label)
        local subStr = string.format("%s%s%d entries%srev %d%s%s",
            p.via, SEP, p.count, SEP, p.lastRev, SEP, p.online and "Online now" or Guard.FormatRelativeTime(p.lastSeenAt))
        if dismissedCount > 0 then
            subStr = subStr .. SEP .. dismissedCount .. " dismissed"
        end
        row._sub:SetText(subStr)

        row._muteBtn._lbl:SetText(trust.muted and "Muted" or "Active")
        if trust.muted then
            row._muteBtn._baseBrd = { br, bg, bb, 0.70 }
            row._muteBtn._brd:SetColor(br, bg, bb, 0.70)
        else
            row._muteBtn._baseBrd = { gr, gg, gb, 0.70 }
            row._muteBtn._brd:SetColor(gr, gg, gb, 0.70)
        end
        row._relayBtn._lbl:SetText(trust.relay ~= false and "Relay: On" or "Relay: Off")

        y = y - 50
    end
    return y
end

local transferDimmer, transferPopup, transferUI

local function CloseTransferModal()
    if transferDimmer then transferDimmer:Hide() end
end

local function EnsureTransferModal()
    if transferPopup then return end

    local eui = _G.EllesmereUI
    local W_POP, H_POP = 540, 340
    if eui and eui.BuildPopupShell then
        transferDimmer, transferPopup = eui.BuildPopupShell("TheListTransferModal", {
            w = W_POP,
            h = H_POP,
            bump = 1.15,
            clamp = true,
            dimAlpha = 0.45,
            onEscape = CloseTransferModal,
            onDimmerDown = CloseTransferModal,
        })
    else
        transferDimmer = CreateFrame("Frame", "TheListTransferModalDimmer", UIParent)
        transferDimmer:SetFrameStrata("FULLSCREEN_DIALOG")
        transferDimmer:SetAllPoints(UIParent)
        transferDimmer:EnableMouse(true)
        transferDimmer:SetScript("OnMouseDown", CloseTransferModal)
        Theme:SolidTex(transferDimmer, "BACKGROUND", 0, 0, 0, 0.45):SetAllPoints()

        transferPopup = CreateFrame("Frame", "TheListTransferModalPopup", transferDimmer)
        transferPopup:SetSize(W_POP, H_POP)
        transferPopup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        transferPopup:SetFrameStrata("FULLSCREEN_DIALOG")
        transferPopup:SetFrameLevel(transferDimmer:GetFrameLevel() + 10)
        transferPopup:EnableMouse(true)
        local bg = Theme:SolidTex(transferPopup, "BACKGROUND", Theme.BG_POPUP.r, Theme.BG_POPUP.g, Theme.BG_POPUP.b, 0.98)
        bg:SetAllPoints()
        transferPopup._brd = Theme:MakeBorder(transferPopup, 1, 1, 1, 0.16, bg)
    end
    transferDimmer:Hide()

    local PAD = 20
    local INNER_W = W_POP - PAD * 2
    local gr, gg, gb = Theme:GetGoodRGB()

    local topBar = Theme:SolidTex(transferPopup, "ARTWORK", gr, gg, gb, 0.95)
    topBar:SetPoint("TOPLEFT", transferPopup, "TOPLEFT", 1, -1)
    topBar:SetPoint("TOPRIGHT", transferPopup, "TOPRIGHT", -1, -1)
    topBar:SetHeight(2)

    local title = Theme:MakeFont(transferPopup, 15, "", 1, 1, 1, 0.96)
    title:SetPoint("TOPLEFT", transferPopup, "TOPLEFT", PAD, -16)

    local closeX = Theme:MakeButton(transferPopup, "X", 24, 24, 11, CloseTransferModal)
    closeX:SetPoint("TOPRIGHT", transferPopup, "TOPRIGHT", -14, -14)

    local hint = Theme:MakeFont(transferPopup, 11, "", 1, 1, 1, 0.62)
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    hint:SetPoint("RIGHT", transferPopup, "RIGHT", -PAD, 0)
    hint:SetJustifyH("LEFT")

    local boxHolder = CreateFrame("Frame", nil, transferPopup)
    boxHolder:SetSize(INNER_W, 198)
    boxHolder:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    local boxBg = Theme:SolidTex(boxHolder, "BACKGROUND", 0, 0, 0, 0.45)
    boxBg:SetAllPoints()
    Theme:MakeBorder(boxHolder, 1, 1, 1, 0.14, boxBg)

    local scroll = CreateFrame("ScrollFrame", nil, boxHolder, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", boxHolder, "TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", boxHolder, "BOTTOMRIGHT", -28, 8)

    local editBox = CreateFrame("EditBox", nil, scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetWidth(INNER_W - 40)
    editBox:SetFont(Theme:GetFont(), 11, "")
    editBox:SetTextColor(0.95, 0.95, 0.95, 0.95)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(editBox)
    boxHolder:EnableMouse(true)
    boxHolder:SetScript("OnMouseDown", function() editBox:SetFocus() end)

    local statusFS = Theme:MakeFont(transferPopup, 11, "", 1, 1, 1, 0.72)
    statusFS:SetPoint("TOPLEFT", boxHolder, "BOTTOMLEFT", 0, -8)
    statusFS:SetPoint("RIGHT", transferPopup, "RIGHT", -PAD, 0)
    statusFS:SetJustifyH("LEFT")

    local closeBtn = Theme:MakeButton(transferPopup, "Close", 120, 30, 12, CloseTransferModal)
    closeBtn:SetPoint("BOTTOMLEFT", transferPopup, "BOTTOMLEFT", PAD, 14)

    local actionBtn = Theme:MakeButton(transferPopup, "Import", 150, 30, 12, function()
        if transferUI.mode == "export" then
            editBox:SetFocus()
            editBox:HighlightText()
            statusFS:SetText("Highlighted — press Ctrl+C to copy.")
        else
            local imported, skipped, err = DB:ImportPersonalString(editBox:GetText() or "")
            if err then
                local br, bg, bb = Theme:GetBadRGB()
                statusFS:SetTextColor(br, bg, bb, 0.95)
                statusFS:SetText(err)
            else
                local ar, ag, ab = Theme:GetGoodRGB()
                statusFS:SetTextColor(ar, ag, ab, 0.95)
                statusFS:SetText(string.format("Imported %d entries (%d skipped as older/duplicate).", imported, skipped))
                ns.Print(string.format("Imported %d entries (%d skipped).", imported, skipped))
            end
        end
    end, "accent")
    actionBtn:SetPoint("BOTTOMRIGHT", transferPopup, "BOTTOMRIGHT", -PAD, 14)

    transferUI = {
        mode = "export",
        title = title,
        hint = hint,
        editBox = editBox,
        statusFS = statusFS,
        actionBtn = actionBtn,
    }
end

local function OpenTransferModal(mode)
    EnsureTransferModal()
    transferUI.mode = mode
    transferUI.statusFS:SetTextColor(1, 1, 1, 0.72)
    if mode == "export" then
        transferUI.title:SetText("EXPORT PERSONAL LIST")
        transferUI.hint:SetText("Press Ctrl+C to copy for backup or Discord. Private notes are excluded.")
        transferUI.actionBtn._lbl:SetText("Select All")
        local str, err, count = DB:ExportPersonalString()
        if err then
            transferUI.editBox:SetText("")
            transferUI.statusFS:SetText(err)
        else
            transferUI.editBox:SetText(str or "")
            transferUI.statusFS:SetText(string.format("Exported %d personal entries (%d chars).", count or 0, #(str or "")))
        end
        transferDimmer:Show()
        transferUI.editBox:SetFocus()
        transferUI.editBox:HighlightText()
    else
        transferUI.title:SetText("IMPORT LIST STRING")
        transferUI.hint:SetText("Paste a THELIST:1:... string below to merge entries into your personal list.")
        transferUI.actionBtn._lbl:SetText("Import Entries")
        transferUI.editBox:SetText("")
        transferUI.statusFS:SetText("Existing entries with newer timestamps and your private notes are preserved.")
        transferDimmer:Show()
        transferUI.editBox:SetFocus()
    end
end

local function BuildSettingsTab(parent, yOffset)
    local eui = _G.EllesmereUI
    local W = eui.Widgets
    local y = yOffset
    local s = DB:Settings()
    local isPrebuild = eui.IsSearchPrebuild and eui.IsSearchPrebuild()
    local _, h

    -- 1. Detection & Warnings
    _, h = W:SectionHeader(parent, "DETECTION & LFG WARNINGS", y); y = y - h
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Warn on Group Members",
          tooltip = "Alert when someone in your party, raid, or matchmade group is on THE LIST.",
          getValue = function() return s.warnGroupRoster end,
          setValue = function(v) s.warnGroupRoster = v end },
        { type = "toggle", text = "Warn on Good Bois",
          tooltip = "Show an alert when a Good Boi appears in your group.",
          getValue = function() return s.warnGreenInGroup end,
          setValue = function(v) s.warnGreenInGroup = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Warn on LFG Applicants",
          tooltip = "Alert and badge applicants queueing into your Premade Group.",
          getValue = function() return s.warnLfgApplicants end,
          setValue = function(v) s.warnLfgApplicants = v; ns.Hooks:RefreshLFGOverlays() end },
        { type = "toggle", text = "Warn on LFG Groups",
          tooltip = "Flag groups in Group Finder whose leader or visible members are on THE LIST.",
          getValue = function() return s.warnLfgSearch end,
          setValue = function(v) s.warnLfgSearch = v; ns.Hooks:RefreshLFGOverlays() end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Show Tooltip Notes",
          tooltip = "Append THE LIST notes to player and LFG hover tooltips.",
          getValue = function() return s.warnTooltips end,
          setValue = function(v) s.warnTooltips = v end },
        { type = "toggle", text = "Print Chat Warnings",
          tooltip = "Print a private summary line in your chat frame when a match triggers.",
          getValue = function() return s.warnChatSummary end,
          setValue = function(v) s.warnChatSummary = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Right-Click Menu Entries",
          tooltip = "Add THE LIST actions to player, party, friend, and LFG right-click menus.",
          getValue = function() return s.addRightClickMenu end,
          setValue = function(v) s.addRightClickMenu = v end },
        { type = "toggle", text = "Capture Recent Teammates",
          tooltip = "Remember recent group teammates with their zone and role.",
          getValue = function() return s.captureRecent end,
          setValue = function(v) s.captureRecent = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Min Severity (Group)",
          values = { [1] = "1 - Note & Above", [2] = "2 - Warn & Above", [3] = "3 - Hard Avoid Only" },
          order = { 1, 2, 3 },
          getValue = function() return s.minSeverityGroup or 1 end,
          setValue = function(v) s.minSeverityGroup = v end },
        { type = "dropdown", text = "Min Severity (LFG)",
          values = { [1] = "1 - Note & Above", [2] = "2 - Warn & Above", [3] = "3 - Hard Avoid Only" },
          order = { 1, 2, 3 },
          getValue = function() return s.minSeverityLfg or 1 end,
          setValue = function(v) s.minSeverityLfg = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Include Synced Friend Lists",
          tooltip = "Match against synced friend and guild entries in addition to your own.",
          getValue = function() return s.includePeerMatches end,
          setValue = function(v) s.includePeerMatches = v; ns.Hooks:RefreshLFGOverlays() end },
        { type = "toggle", text = "Auto-Mirror to Blizzard /ignore",
          tooltip = "Automatically run native C_FriendList.AddIgnore when adding a Bad Boi.",
          getValue = function() return s.autoNativeIgnore end,
          setValue = function(v) s.autoNativeIgnore = v end }
    ); y = y - h

    -- 2. Banner & Sound
    _, h = W:SectionHeader(parent, "ALERT BANNER & SOUND", y); y = y - h
    if not isPrebuild and eui.BuildUnlockPlaceholder then
        local pad = eui.CONTENT_PAD or 40
        local holder = uiState.unlockPlaceholder
        if not holder then
            holder = CreateFrame("Frame", nil, parent)
            holder:SetSize(parent:GetWidth() - pad * 2, 48)
            eui.BuildUnlockPlaceholder({
                parent = holder,
                text = "Position Alert Banner in EllesmereUI Unlock Mode",
            })
            uiState.unlockPlaceholder = holder
        else
            holder:SetParent(parent)
            holder:SetSize(parent:GetWidth() - pad * 2, 48)
        end
        holder:ClearAllPoints()
        holder:SetPoint("TOPLEFT", parent, "TOPLEFT", pad, y)
        holder:Show()
        y = y - 54
    end

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Show On-Screen Banner",
          tooltip = "Show the 'YOU JUST MADE THE LIST!' toast banner on matches.",
          getValue = function() return s.warnBanner end,
          setValue = function(v) s.warnBanner = v end },
        { type = "slider", text = "Banner Duration (sec)", min = 2, max = 20, step = 1,
          getValue = function() return s.bannerDuration or 7 end,
          setValue = function(v) s.bannerDuration = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Banner Scale", min = 0.7, max = 1.4, step = 0.05,
          getValue = function() return s.bannerScale or 1.15 end,
          setValue = function(v) s.bannerScale = v; ns.AlertBanner:ApplySettings() end },
        { type = "slider", text = "Alert Cooldown (sec)", min = 10, max = 600, step = 10,
          getValue = function() return s.dedupeCooldownSec or 180 end,
          setValue = function(v) s.dedupeCooldownSec = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Add Bad Boi Sound",
          tooltip = "Sound played when you add a player to Bad Bois (does not play on group/LFG alerts).",
          values = ns.ADD_SOUND_PRESETS,
          order = ns.ADD_SOUND_ORDER,
          getValue = function() return s.addBadSound or "thelist_add" end,
          setValue = function(v) s.addBadSound = v; Guard.PlayAlertSound(v) end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Bad Bois Alert Sound",
          tooltip = "Sound played when a Bad Boi is detected in your group or LFG.",
          values = ns.SOUND_PRESETS,
          order = ns.SOUND_ORDER,
          getValue = function() return s.blackSound or "eui_siren" end,
          setValue = function(v) s.blackSound = v; Guard.PlayAlertSound(v) end },
        { type = "dropdown", text = "Good Bois Alert Sound",
          tooltip = "Sound played when a Good Boi is detected in your group or LFG (off by default).",
          values = ns.SOUND_PRESETS,
          order = ns.SOUND_ORDER,
          getValue = function() return s.greenSound or "none" end,
          setValue = function(v) s.greenSound = v; Guard.PlayAlertSound(v) end }
    ); y = y - h

    _, h = W:WideButton(parent, "Test 'YOU JUST MADE THE LIST!' Banner", y, function()
        ns.AlertBanner:ShowTestAlert()
    end, 360); y = y - h

    -- 3. In-Game Sync
    _, h = W:SectionHeader(parent, "IN-GAME SYNC (BNET & GUILD)", y); y = y - h
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Enable In-Game Sync",
          tooltip = "Automatically sync your shared entries with trusted BNet friends and guildmates.",
          getValue = function() return s.syncEnabled end,
          setValue = function(v) s.syncEnabled = v end },
        { type = "toggle", text = "Auto-Sync on Login",
          tooltip = "Send a compact sync handshake shortly after logging in.",
          getValue = function() return s.autoSyncOnLogin end,
          setValue = function(v) s.autoSyncOnLogin = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "BNet Friends Sync",
          tooltip = "Sync cross-realm and cross-faction with BNet friends running THE LIST.",
          getValue = function() return s.syncBNet end,
          setValue = function(v) s.syncBNet = v end },
        { type = "toggle", text = "Guild Sync",
          tooltip = "Broadcast and receive updates across your guild addon channel.",
          getValue = function() return s.syncGuild end,
          setValue = function(v) s.syncGuild = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Party / Raid Sync",
          tooltip = "Opportunistically sync with group members running THE LIST.",
          getValue = function() return s.syncParty end,
          setValue = function(v) s.syncParty = v end },
        { type = "toggle", text = "1-Hop Trusted Relay",
          tooltip = "Relay updates across your enabled sync channels so offline friends receive changes when any shared peer logs on.",
          getValue = function() return s.syncRelay end,
          setValue = function(v) s.syncRelay = v end }
    ); y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Sync Good Bois Entries",
          tooltip = "Include positive Good Bois entries in peer sync.",
          getValue = function() return s.syncGreenEntries end,
          setValue = function(v) s.syncGreenEntries = v end }
    ); y = y - h

    _, h = W:WideDualButton(parent, "Sync Now", "Refresh Peer List", y,
        function()
            local status = Sync:SyncNow()
            ns.Print(Sync:FormatSyncStatus(status))
        end,
        function()
            eui:RefreshPage(true)
        end, 220); y = y - h

    _, h = W:SectionHeader(parent, "BACKUP & SHARE (EXPORT / IMPORT)", y); y = y - h
    _, h = W:WideDualButton(parent, "Export List String", "Import List String", y,
        function()
            OpenTransferModal("export")
        end,
        function()
            OpenTransferModal("import")
        end, 220); y = y - h

    _, h = W:SectionHeader(parent, "SYNC CIRCLE PEERS", y); y = y - h
    if not isPrebuild then
        y = BuildPeerRows(parent, y)
    end

    return math.abs(y) + 20
end

local function BuildMainPage(pageName, parent, yOffset)
    local eui = _G.EllesmereUI
    if pageName == PAGE_SETTINGS then
        HidePooledRows()
        uiState.activePage = pageName
        uiState.activeParent = parent
        return BuildSettingsTab(parent, yOffset)
    end
    HidePooledPeerRows()
    if uiState.unlockPlaceholder then uiState.unlockPlaceholder:Hide() end
    if eui and eui.IsSearchPrebuild and eui.IsSearchPrebuild() then
        return 100
    end
    uiState.activePage = pageName
    uiState.activeParent = parent
    uiState.pageParents[pageName] = parent

    local hb = BuildListHeader(pageName)
    if hb and eui and eui.SetContentHeader then
        eui:SetContentHeader(hb)
    elseif eui and eui.ClearContentHeader then
        eui:ClearContentHeader()
    end

    return RepaintEntriesList()
end

function PluginPages:Register()
    local eui = _G.EllesmereUI
    if not (eui and eui.RegisterPlugin) then return false end
    if eui.IsPluginRegistered and eui.IsPluginRegistered(PLUGIN_ID) then return true end

    local ok = eui.RegisterPlugin(PLUGIN_ID, {
        label = "THE LIST",
        position = "bottom",
        modules = {
            {
                key = MODULE_MAIN,
                title = "Lists & Sync",
                description = "You just made THE LIST! Track Bad Bois & Good Bois across your group, Group Finder, BNet friends, and guild.",
                pages = { PAGE_BAD, PAGE_GOOD, PAGE_RECENT, PAGE_SETTINGS },
                getHeaderBuilder = BuildListHeader,
                buildPage = BuildMainPage,
                onPageCacheRestore = function(pageName)
                    uiState.activePage = pageName
                    if uiState.pageParents[pageName] then
                        uiState.activeParent = uiState.pageParents[pageName]
                    end
                    if pageName == PAGE_BAD or pageName == PAGE_GOOD or pageName == PAGE_RECENT then
                        local refreshHdr = uiState.headerRefreshByPage[pageName]
                        if refreshHdr then refreshHdr(false) end
                        RepaintEntriesList()
                    end
                end,
                onReset = function()
                    DB:ResetSettings()
                    eui:RefreshPage(true)
                end,
                searchPrebuild = true,
            },
        },
    })

    if ok then
        ns:On("DB_CHANGED", function()
            if IsPluginShown() and uiState.activePage ~= PAGE_SETTINGS then
                local refreshHdr = uiState.headerRefreshByPage[uiState.activePage]
                if refreshHdr then refreshHdr(false) end
                RepaintEntriesList()
            end
        end)
        ns:On("PEERS_CHANGED", function()
            if IsPluginShown() then
                if uiState.activePage == PAGE_SETTINGS then
                    eui:RefreshPage(true)
                else
                    local refreshHdr = uiState.headerRefreshByPage[uiState.activePage]
                    if refreshHdr then refreshHdr(false) end
                    RepaintEntriesList()
                end
            end
        end)
        Theme:OnLooksChanged(function()
            if IsPluginShown() then
                eui:RefreshPage(true)
            end
        end)
    end

    return ok
end

function PluginPages:Open(_, pageName)
    local eui = _G.EllesmereUI
    if not (eui and eui.OpenPlugin) then return false end
    return eui.OpenPlugin(PLUGIN_ID, MODULE_MAIN, pageName)
end
