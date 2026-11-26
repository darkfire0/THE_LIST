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
    subRows = {},
    subRowPool = {},
    expandedKeys = {},
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

local function SetRowHovered(row, hovered)
    if not row then return end
    if row._hoverBg then row._hoverBg:SetShown(hovered) end
    local ctx = row._ctx
    local mode = ctx and ctx.mode
    if mode == "entry" then
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
    elseif mode == "subrow" then
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
                    RenderContent()
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
                        RenderContent()
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
                    ns.QuickModal:Open({ name = entry.name, guid = rec.guid or entry.guid, class = rec.class or entry.class, entry = entry })
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
                if _G.StaticPopup_Show and _G.StaticPopupDialogs and _G.StaticPopupDialogs["THELIST_STANDALONE_REMOVE"] then
                    _G.StaticPopup_Show("THELIST_STANDALONE_REMOVE", entry.name or entry.key, nil, { key = entry.key })
                else
                    DB:RemovePersonal(entry.key)
                end
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
        local isExpanded = ui.expandedKeys[expandKey] == true
        items[#items + 1] = {
            text = isExpanded and "Collapse Peer Notes" or "Expand Peer Notes",
            onClick = function()
                ui.expandedKeys[expandKey] = not isExpanded and true or nil
                RenderContent()
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
                    RenderContent()
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
                        RenderContent()
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
    local ctx = self._ctx
    if not ctx then return end

    if ctx.mode == "sync" then
        local p = ctx.peer
        if not p then return end
        local lines = {
            "Transport: " .. tostring(p.via or "SYNC"),
            "Revision: " .. tostring(p.lastRev or 0),
            ctx.isOnline and "Status: Online now" or ("Last seen: " .. Guard.FormatRelativeTime(p.lastSeenAt)),
        }
        if (ctx.dismissedCount or 0) > 0 then
            lines[#lines + 1] = "Dismissed locally: " .. tostring(ctx.dismissedCount) .. " (right-click to restore)"
        end
        Theme:ShowTooltip(self, p.authorLabel or ctx.authorID, lines)
    elseif ctx.mode == "recent" then
        local item = ctx.item
        if not item then return end
        Theme:ShowTooltip(self, item.name, {
            "Role: " .. tostring(ctx.roleTxt or "Member"),
            tostring(ctx.noteTxt or "Last seen in group"),
            "Time: " .. tostring(ctx.seenTxt or "Unknown"),
        }, ctx.classRGB)
    elseif ctx.mode == "subrow" then
        local g = ctx.group
        local rec = ctx.rec
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
        Theme:ShowTooltip(self, rec.name or rec.key, lines, ctx.classRGB)
    elseif ctx.mode == "entry" then
        local rec = ctx.rec
        local entry = rec and (rec.primary or rec.entry)
        if not entry then return end
        local lines = {
            "Source: " .. (rec.isMine and "You" or tostring(rec.authorLabel)),
            "Category: " .. (entry.category or "Other"),
        }
        if ctx.listType == ns.LIST_BLACK then
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
            local oppWord = (ctx.listType == ns.LIST_GREEN) and "Bad Boi" or "Good Boi"
            local cr, cg, cb
            if ctx.listType == ns.LIST_GREEN then
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
        Theme:ShowTooltip(self, entry.name or entry.key, lines, ctx.classRGB)
    end
end

local function Row_OnLeave(self)
    if not (self.IsMouseOver and self:IsMouseOver()) then
        SetRowHovered(self, false)
    end
    Theme:HideTooltip()
end

local function Row_OnMouseUp(self, button)
    local ctx = self._ctx
    if not ctx then return end
    if ctx.mode == "entry" and ctx.rec then
        local rec = ctx.rec
        if button == "LeftButton" and rec.hasExpandableDetails then
            local expandKey = tostring(rec.listType) .. ":" .. tostring(rec.key)
            ui.expandedKeys[expandKey] = not ui.expandedKeys[expandKey] and true or nil
            RenderContent()
        elseif button == "RightButton" then
            OpenEntryContextMenu(self, rec)
        end
    elseif ctx.mode == "subrow" and ctx.rec and ctx.group then
        if button == "RightButton" then
            OpenEntryContextMenu(self, ctx.rec, nil, ctx.group)
        end
    elseif ctx.mode == "sync" and ctx.authorID and button == "RightButton" then
        local dCount = DB:GetDismissedCount(ctx.authorID)
        if dCount > 0 then
            Theme:ShowContextMenu(self, {
                {
                    text = string.format("Restore Dismissed Entries (%d)", dCount),
                    onClick = function()
                        DB:ClearDismissedForPeer(ctx.authorID)
                        RenderContent()
                    end,
                },
            })
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
    elseif act == "recent_edit" then
        local item = ctx.item
        local personal = ctx.personalEntry
        if personal and ns.QuickModal then
            ns.QuickModal:Open({
                name = personal.name,
                guid = personal.guid or (item and item.guid),
                class = personal.class or (item and item.class),
                entry = personal,
            })
        end
    elseif act == "recent_black" or act == "recent_green" then
        local item = ctx.item
        if item and ns.QuickModal then
            ns.QuickModal:Open({
                name = item.name,
                guid = item.guid,
                class = item.class,
                context = item.context,
                listType = (act == "recent_green") and ns.LIST_GREEN or ns.LIST_BLACK,
            })
        end
    elseif act == "dismiss_group" then
        local rec = ctx.rec
        local g = ctx.group
        if rec and g and g.authors then
            local ids = {}
            for i = 1, #g.authors do
                if g.authors[i].authorID then
                    ids[#ids + 1] = g.authors[i].authorID
                end
            end
            DB:DismissPeerEntries(ids, rec.key)
        end
    elseif act == "entry_edit" then
        local entry = ctx.rec and (ctx.rec.primary or ctx.rec.entry)
        if entry and ns.QuickModal then
            ns.QuickModal:Open({ name = entry.name, guid = ctx.rec.guid or entry.guid, class = ctx.rec.class or entry.class, entry = entry })
        end
    elseif act == "entry_remove" then
        local entry = ctx.rec and (ctx.rec.primary or ctx.rec.entry)
        if not entry then return end
        if _G.StaticPopup_Show and _G.StaticPopupDialogs and _G.StaticPopupDialogs["THELIST_STANDALONE_REMOVE"] then
            _G.StaticPopup_Show("THELIST_STANDALONE_REMOVE", entry.name or entry.key, nil, { key = entry.key })
        else
            DB:RemovePersonal(entry.key)
        end
    elseif act == "entry_ignore" then
        local entry = ctx.rec and (ctx.rec.primary or ctx.rec.entry)
        if entry then
            DB:ToggleNativeIgnore(entry.key)
        end
    elseif act == "entry_adopt" then
        local rec = ctx.rec
        local entry = rec and (rec.primary or rec.entry)
        if not entry then return end
        DB:AdoptPeerEntry(entry, {
            guid = rec.guid,
            class = rec.class,
            listType = ctx.listType,
        })
        ns.Print("Saved " .. tostring(entry.name or rec.key) .. " to your personal list (local only).")
    elseif act == "entry_menu" then
        if ctx.rec then
            OpenEntryContextMenu(self, ctx.rec, { below = true })
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

        local timeFS = Theme:MakeFont(row, 11, "", 1, 1, 1, 0.44)
        timeFS:SetPoint("TOPRIGHT", row, "TOPRIGHT", -14, -10)
        timeFS:SetJustifyH("RIGHT")
        timeFS:SetWordWrap(false)
        row._timeFS = timeFS

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
        row:SetScript("OnMouseUp", Row_OnMouseUp)

        ui.rowPool[idx] = row
    end
    if row._hoverBg then row._hoverBg:Hide() end
    row:SetParent(parent)
    row:SetSize(rowW, 52)
    row:Show()
    return row
end

local function GetOrCreateSubRow(parent, idx, rowW)
    local row = ui.subRowPool[idx]
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetSize(rowW, 36)
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
        stripe:SetPoint("TOPLEFT"); stripe:SetPoint("BOTTOMLEFT"); stripe:SetWidth(2)
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

        row._ctx = {}
        row:SetScript("OnEnter", Row_OnEnter)
        row:SetScript("OnLeave", Row_OnLeave)
        row:SetScript("OnMouseUp", Row_OnMouseUp)

        ui.subRowPool[idx] = row
    end
    if row._hoverBg then row._hoverBg:Hide() end
    row:SetParent(parent)
    row:SetSize(rowW, 36)
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
    for i = 1, #ui.subRows do
        local sr = ui.subRows[i]
        if sr._hoverBg then sr._hoverBg:Hide() end
        sr:Hide()
        ui.subRows[i] = nil
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
    if ui.syncBtn then ui.syncBtn:SetShown(ui.tab == "sync") end
    if ui.testBtn and ui.tabAnchor then
        ui.testBtn:ClearAllPoints()
        if ui.tab == "sync" and ui.syncBtn then
            ui.testBtn:SetPoint("RIGHT", ui.syncBtn, "LEFT", -6, 0)
        else
            ui.testBtn:SetPoint("TOPRIGHT", ui.tabAnchor, "BOTTOMRIGHT", -20, -44)
        end
    end

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
            if row._timeFS then row._timeFS:Hide() end
            local dismissedCount = DB:GetDismissedCount(aid)
            local noteStr = isOnline and "Online now" or ("Last seen " .. Guard.FormatRelativeTime(peer.lastSeenAt))
            if dismissedCount > 0 then
                noteStr = noteStr .. "  |  " .. dismissedCount .. " dismissed"
            end
            row._metaFS:SetText(string.format("%s | rev %d", peer.via or "SYNC", peer.lastRev or 0))
            row._noteFS:SetText(noteStr)

            local ctx = row._ctx
            ctx.mode = "sync"
            ctx.authorID = aid
            ctx.peer = peer
            ctx.isOnline = isOnline
            ctx.dismissedCount = dismissedCount
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
        local gr, gg, gb = Theme:GetGoodRGB()
        local br, bg, bb = Theme:GetBadRGB()
        local goodHex = Theme:GetGoodHex()
        local badHex = Theme:GetBadHex()
        for i = 1, #recent do
            local item = recent[i]
            local row = GetOrCreateRow(content, i, rowW)
            ui.rows[#ui.rows + 1] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            row._bg:SetColorTexture(0, 0, 0, (i % 2 == 1) and Theme.ROW_ODD_A or Theme.ROW_EVEN_A)
            if row._timeFS then row._timeFS:Hide() end

            local match = DB:Lookup(item.name, item.guid, true)
            if match then
                if match.effectiveType == ns.LIST_GREEN then
                    row._stripe:SetColorTexture(gr, gg, gb, 0.95)
                else
                    row._stripe:SetColorTexture(br, bg, bb, 0.95)
                end
            else
                row._stripe:SetColorTexture(1, 1, 1, 0.16)
            end

            local cr, cg, cb = Guard.GetClassRGB(item.class)
            row._nameFS:SetTextColor(1, 1, 1, 1)
            row._nameFS:SetText(Guard.FormatPlayerNameColored(item.name or "?", cr, cg, cb))

            local roleTxt = Guard.FormatRole(item.role)
            local seenTxt = Guard.FormatRelativeTime(item.seenAt)
            local ctxTxt = (item.context and item.context ~= "") and ("Last seen: " .. item.context) or "Last seen in group"
            row._metaFS:SetText(roleTxt .. "  |  Last seen: " .. seenTxt)
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
                row._noteFS:SetText(lbl .. ctxTxt)
            else
                row._noteFS:SetText(ctxTxt)
            end

            local ctx = row._ctx
            ctx.mode = "recent"
            ctx.item = item
            ctx.rec = nil
            ctx.personalEntry = match and match.personal or nil
            ctx.roleTxt = roleTxt
            ctx.seenTxt = seenTxt
            ctx.noteTxt = ctxTxt
            ctx.classRGB = ctx.classRGB or { 1, 1, 1 }
            ctx.classRGB[1], ctx.classRGB[2], ctx.classRGB[3] = cr, cg, cb

            row._btn3:Hide()
            if match and match.personal then
                row._btn2:Hide()
                row._btn1:Show()
                ApplyBtnStyle(row._btn1, "Edit", 66, nil, "Edit your note for this player.", "recent_edit")
                SetRowTextRightBound(row, -92)
            else
                row._btn2:Show()
                row._btn1:Show()
                ApplyBtnStyle(row._btn2, "+ Bad Boi", 78, "red", nil, "recent_black")
                ApplyBtnStyle(row._btn1, "+ Good Boi", 84, "green", nil, "recent_green")
                SetRowTextRightBound(row, -192)
            end

            y = y - 52
        end
    else
        local listType = (ui.tab == "green") and ns.LIST_GREEN or ns.LIST_BLACK
        local items = DB:QueryEntries(listType, ui.sourceFilter, ui.search, ui.sortBy)
        ui.emptyFS:SetShown(#items == 0)
        ui.emptyFS:SetText("No entries yet. Fill in the bar above or right-click any player.")
        local sr, sg, sb
        local gr, gg, gb = Theme:GetGoodRGB()
        local br, bg, bb = Theme:GetBadRGB()
        local goodHex = Theme:GetGoodHex()
        local badHex = Theme:GetBadHex()
        if listType == ns.LIST_GREEN then
            sr, sg, sb = gr, gg, gb
        else
            sr, sg, sb = br, bg, bb
        end
        local subIdx = 0
        for i = 1, #items do
            local rec = items[i]
            local entry = rec.primary or rec.entry
            local row = GetOrCreateRow(content, i, rowW)
            ui.rows[#ui.rows + 1] = row
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
            row._bg:SetColorTexture(0, 0, 0, (i % 2 == 1) and Theme.ROW_ODD_A or Theme.ROW_EVEN_A)
            row._stripe:SetColorTexture(sr, sg, sb, rec.isMine and 0.95 or 0.50)
            local cr, cg, cb = Guard.GetClassRGB(rec.class or entry.class)
            row._nameFS:SetTextColor(1, 1, 1, 1)
            row._nameFS:SetText(Guard.FormatPlayerNameColored(rec.name or entry.name or rec.key, cr, cg, cb))
            if row._timeFS then
                row._timeFS:SetText(Guard.FormatRelativeTime(rec.latestUpdatedAt or entry.updatedAt))
            end

            local expandKey = tostring(listType) .. ":" .. tostring(rec.key)
            local isExpanded = rec.hasExpandableDetails and (ui.expandedKeys[expandKey] == true)
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
            local sevTxt = (listType == ns.LIST_BLACK) and ("  |  " .. (ns.SEVERITY_LABELS[entry.severity or 2] or "Warn")) or ""
            row._metaFS:SetText(metaPrefix .. (entry.category or "Other") .. sevTxt)

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

            local ctx = row._ctx
            ctx.mode = "entry"
            ctx.rec = rec
            ctx.item = nil
            ctx.listType = listType
            ctx.classRGB = ctx.classRGB or { 1, 1, 1 }
            ctx.classRGB[1], ctx.classRGB[2], ctx.classRGB[3] = cr, cg, cb

            if rec.isMine then
                row._wantBtn1 = true
                row._wantBtn2 = true
                ApplyBtnStyle(row._btn1, "Remove", 70, "red", nil, "entry_remove")
                ApplyBtnStyle(row._btn2, "Edit", 62, nil, nil, "entry_edit")
                if listType == ns.LIST_BLACK then
                    row._wantBtn3 = true
                    ApplyBtnStyle(row._btn3, entry.nativeIgnore and "Ignored" or "/ignore", 70, entry.nativeIgnore and "green" or nil, "Toggle Blizzard native /ignore for this player.", "entry_ignore")
                    row._hoverRightPad = -230
                else
                    row._wantBtn3 = false
                    row._hoverRightPad = -156
                end
            else
                row._wantBtn1 = true
                row._wantBtn2 = true
                row._wantBtn3 = false
                ApplyBtnStyle(row._btn1, "...", 28, nil, "More peer actions (Save & Edit, Dismiss entry, Mute peer).", "entry_menu")
                ApplyBtnStyle(row._btn2, "Save to Mine", 94, (listType == ns.LIST_GREEN) and "green" or nil, "Save a local copy to your personal list (not re-shared until edited).", "entry_adopt")
                row._hoverRightPad = -148
            end
            SetRowHovered(row, row.IsMouseOver and row:IsMouseOver() or false)
            y = y - 52

            if isExpanded then
                local function RenderSubGroupList(groups, isConflict)
                    if not groups then return end
                    for gi = 1, #groups do
                        local g = groups[gi]
                        subIdx = subIdx + 1
                        local subRow = GetOrCreateSubRow(content, subIdx, rowW - 18)
                        ui.subRows[#ui.subRows + 1] = subRow
                        subRow:ClearAllPoints()
                        subRow:SetPoint("TOPLEFT", content, "TOPLEFT", 18, y)

                        if isConflict then
                            if g.listType == ns.LIST_GREEN then
                                subRow._stripe:SetColorTexture(gr, gg, gb, 0.85)
                            else
                                subRow._stripe:SetColorTexture(br, bg, bb, 0.85)
                            end
                        else
                            subRow._stripe:SetColorTexture(0.56, 0.72, 1.0, 0.75)
                        end

                        local authTxt = FormatAuthorsSummary(g.authors, true, 3)
                        local cBadge = ""
                        if isConflict then
                            cBadge = (g.listType == ns.LIST_GREEN) and (goodHex .. " [Good Boi]|r") or (badHex .. " [Bad Boi]|r")
                        end
                        local gSev = (g.listType == ns.LIST_BLACK) and ("  |  " .. (ns.SEVERITY_LABELS[g.severity or 2] or "Warn")) or ""
                        subRow._metaFS:SetText(string.format("|cff8fb8ff%s|r%s  %s%s  |  %s", authTxt, cBadge, g.category or "Other", gSev, Guard.FormatRelativeTime(g.updatedAt)))

                        local gNote = (g.sharedNote ~= "" and g.sharedNote)
                            or (g.context and g.context ~= "" and ("Context: " .. g.context))
                            or "(No note)"
                        subRow._noteFS:SetText(gNote)

                        local sctx = subRow._ctx
                        sctx.mode = "subrow"
                        sctx.rec = rec
                        sctx.group = g
                        sctx.classRGB = sctx.classRGB or { 1, 1, 1 }
                        sctx.classRGB[1], sctx.classRGB[2], sctx.classRGB[3] = cr, cg, cb
                        SetRowHovered(subRow, subRow.IsMouseOver and subRow:IsMouseOver() or false)

                        y = y - 36
                    end
                end
                RenderSubGroupList(rec.distinctPeerGroups, false)
                RenderSubGroupList(rec.conflictGroups, true)
            end
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
    local searchHolder, searchBox = Theme:MakeEditBox(frame, 522, 28, "Filter list by player, tag, note, or friend...")
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
    ui.syncBtn = syncBtn
    ui.tabAnchor = tabBand

    local testBtn = Theme:MakeButton(frame, "Test Banner", 94, 28, 11, function()
        ns.AlertBanner:ShowTestAlert()
    end)
    testBtn:SetPoint("RIGHT", syncBtn, "LEFT", -6, 0)
    ui.testBtn = testBtn

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
    local srcLbls = { all = "Src: All", mine = "Src: Mine", peers = "Src: Peer-Only" }
    local srcBtn = Theme:MakeButton(frame, srcLbls[ui.sourceFilter], 104, 28, 11, function(self)
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
