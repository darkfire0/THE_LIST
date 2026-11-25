local _, ns = ...

local Hooks = {}
ns.Hooks = Hooks

local Guard = ns.Guard
local DB = ns.DB
local Detector = ns.Detector

-- Weak tables keep zero custom fields on Blizzard or EllesmereUI frames (taint-safe)
local badgeOverlays = setmetatable({}, { __mode = "k" })
local tipAnnotatedSerial = setmetatable({}, { __mode = "k" })
local hookedTooltips = setmetatable({}, { __mode = "k" })
local euiOverlaidRows = {
    search = setmetatable({}, { __mode = "k" }),
    applicant = setmetatable({}, { __mode = "k" }),
}
local isEuiGroupFinderLoaded = false
local initialized = false

local function IsEuiGroupFinderLoaded()
    if isEuiGroupFinderLoaded then return true end
    if _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded and _G.C_AddOns.IsAddOnLoaded("EllesmereUIGroupFinder") then
        isEuiGroupFinderLoaded = true
        return true
    end
    return false
end

local function GetMatchSummaryLines(match, headerLabel)
    local lines = {}
    if not match then return lines end
    local goodHex = (ns.Theme and ns.Theme.GetGoodHex and ns.Theme:GetGoodHex()) or "|cff3ec8ec"
    local tagColor = match.effectiveType == ns.LIST_GREEN and goodHex or "|cffff4d4d"
    local listWord = match.effectiveType == ns.LIST_GREEN and "GOOD BOI" or "BAD BOI"
    lines[#lines + 1] = {
        left = (headerLabel and (headerLabel .. " ") or "") .. tagColor .. "THE LIST: " .. listWord .. "|r",
        right = "",
    }
    if match.personal then
        local e = match.personal
        local sev = (e.listType == ns.LIST_BLACK) and (" [" .. (ns.SEVERITY_LABELS[e.severity or 2] or "Warn") .. "]") or ""
        local note = (e.sharedNote ~= "" and e.sharedNote) or e.privateNote or ""
        local text = "|cffffffffYou|r (" .. (e.category or "Other") .. sev .. ")"
        if note ~= "" then text = text .. ": " .. note end
        lines[#lines + 1] = { left = text, wrap = true, r = 0.92, g = 0.92, b = 0.92 }
    end
    for i = 1, #match.peers do
        local p = match.peers[i]
        local e = p.entry
        local pCol = (e.listType == ns.LIST_GREEN) and goodHex or "|cffff7a7a"
        local text = pCol .. tostring(p.authorLabel) .. "|r (" .. (e.category or "Other") .. ")"
        if e.sharedNote and e.sharedNote ~= "" then
            text = text .. ": " .. e.sharedNote
        end
        lines[#lines + 1] = { left = text, wrap = true, r = 0.85, g = 0.85, b = 0.85 }
    end
    return lines
end

local function AppendMatchToTooltip(tooltip, match, playerLabel)
    if not tooltip or not tooltip.AddLine or not match then return end
    local lines = GetMatchSummaryLines(match, playerLabel)
    if #lines == 0 then return end
    tooltip:AddLine(" ")
    for i = 1, #lines do
        local l = lines[i]
        tooltip:AddLine(l.left, l.r or 1, l.g or 1, l.b or 1, l.wrap == true)
    end
end

local hookedWheels = setmetatable({}, { __mode = "k" })

local function EnsureRowOverlay(row)
    local ov = badgeOverlays[row]
    if ov then return ov end

    ov = CreateFrame("Frame", nil, row)
    ov:SetAllPoints(row)
    ov:SetFrameLevel((row:GetFrameLevel() or 1) + 4)
    ov:EnableMouse(false)

    local bgTint = ov:CreateTexture(nil, "BACKGROUND")
    bgTint:SetAllPoints(ov)
    ov.bgTint = bgTint

    local leftBar = ov:CreateTexture(nil, "ARTWORK")
    leftBar:SetPoint("TOPLEFT", ov, "TOPLEFT", 0, 0)
    leftBar:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", 0, 0)
    leftBar:SetWidth(3)
    ov.leftBar = leftBar

    local topLine = ov:CreateTexture(nil, "ARTWORK")
    topLine:SetPoint("TOPLEFT", ov, "TOPLEFT", 3, 0)
    topLine:SetPoint("TOPRIGHT", ov, "TOPRIGHT", 0, 0)
    topLine:SetHeight(1)
    ov.topLine = topLine

    local bottomLine = ov:CreateTexture(nil, "ARTWORK")
    bottomLine:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", 3, 0)
    bottomLine:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", 0, 0)
    bottomLine:SetHeight(1)
    ov.bottomLine = bottomLine

    local rightLine = ov:CreateTexture(nil, "ARTWORK")
    rightLine:SetPoint("TOPRIGHT", ov, "TOPRIGHT", 0, -1)
    rightLine:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", 0, 1)
    rightLine:SetWidth(1)
    ov.rightLine = rightLine

    ov.markers = {}
    ov:Hide()
    badgeOverlays[row] = ov
    return ov
end

local function EnsureMarker(ov, idx)
    local marker = ov.markers[idx]
    if marker then return marker end

    marker = CreateFrame("Frame", nil, ov)
    marker:SetSize(13, 13)
    marker:EnableMouse(false)

    local icon = marker:CreateTexture(nil, "OVERLAY")
    icon:SetAllPoints()
    marker.icon = icon

    marker:Hide()
    ov.markers[idx] = marker
    return marker
end

local function HideRowOverlay(row)
    local ov = badgeOverlays[row]
    if not ov then return end
    for i = 1, #ov.markers do
        ov.markers[i]:Hide()
    end
    ov:Hide()
end

local function GetTagColors(hasBlack)
    if hasBlack then
        return 1.0, 0.30, 0.30
    end
    if ns.Theme and ns.Theme.GetGoodRGB then
        return ns.Theme:GetGoodRGB()
    end
    return 0.24, 0.78, 0.93
end

local function StyleMarker(marker, hasBlack)
    local r, g, b = GetTagColors(hasBlack)
    local atlas = hasBlack and "uitools-icon-close" or "common-icon-checkmark"
    if marker.icon.SetAtlas then
        marker.icon:SetAtlas(atlas, false)
    end
    if marker.icon.SetDesaturated then
        marker.icon:SetDesaturated(true)
    end
    marker.icon:SetVertexColor(r, g, b, 0.95)
end

local function PlaceAlignedMarker(ov, idx, nameFS, rightStopRegion, hasBlack, alignToStop)
    if not (nameFS and nameFS.GetLeft and nameFS.GetRight and nameFS.GetStringWidth) then
        return false
    end
    if nameFS.GetJustifyH and nameFS:GetJustifyH() == "RIGHT" then
        return false
    end

    local nLeft = Guard.SafeNumber(nameFS:GetLeft())
    local nRight = Guard.SafeNumber(nameFS:GetRight())
    local strW = Guard.SafeNumber(nameFS:GetStringWidth())
    if not (nLeft and nRight and strW) then return false end

    local iconSz = 12
    local stopShown = rightStopRegion and rightStopRegion.IsShown and rightStopRegion:IsShown() and rightStopRegion.GetLeft
    local stopLeft = stopShown and Guard.SafeNumber(rightStopRegion:GetLeft()) or nil

    local anchorToStop = (alignToStop and stopLeft ~= nil)
    local leftOffset = 0
    if anchorToStop then
        local minClearLeft = nLeft + math.min(strW, math.max(0, stopLeft - nLeft)) + 4
        if minClearLeft > (stopLeft - iconSz - 6) then
            return false
        end
    else
        local maxRight = stopLeft and math.min(nRight, stopLeft - 4) or nRight
        local usedNameW = math.min(strW, math.max(0, maxRight - nLeft))
        leftOffset = math.floor(usedNameW + 6.5)
        if (maxRight - nLeft) - leftOffset < iconSz then
            return false
        end
    end

    local marker = EnsureMarker(ov, idx)
    StyleMarker(marker, hasBlack)

    marker:SetFrameLevel((ov:GetFrameLevel() or 1) + 5)
    marker:SetSize(iconSz, iconSz)
    marker:ClearAllPoints()
    if anchorToStop then
        marker:SetPoint("RIGHT", rightStopRegion, "LEFT", -6, 0)
    else
        marker:SetPoint("LEFT", nameFS, "LEFT", leftOffset, 0)
    end
    marker:Show()
    return true
end

local function IsResPeerOnly(res)
    if not res or not res.matches then return true end
    for i = 1, #res.matches do
        local m = res.matches[i].match
        if m and m.personal then
            return false
        end
    end
    return true
end

local function PaintRowAccent(row, hasBlack, maxSeverity, isPeerOnly)
    local ov = EnsureRowOverlay(row)
    local r, g, b = GetTagColors(hasBlack)

    local tintA
    if hasBlack then
        local sev = maxSeverity or 2
        if sev >= 3 then
            tintA = 0.14
        elseif sev == 2 then
            tintA = 0.09
        else
            tintA = 0.05
        end
    else
        tintA = 0.07
    end
    if isPeerOnly then
        tintA = tintA * 0.7
    end
    ov.bgTint:SetColorTexture(r, g, b, tintA)

    local barW = (hasBlack and (maxSeverity or 2) >= 3) and 4 or 3
    local barA = isPeerOnly and 0.72 or 0.95
    ov.leftBar:SetWidth(barW)
    ov.leftBar:SetColorTexture(r, g, b, barA)
    ov.topLine:ClearAllPoints()
    ov.topLine:SetPoint("TOPLEFT", ov, "TOPLEFT", barW, 0)
    ov.topLine:SetPoint("TOPRIGHT", ov, "TOPRIGHT", 0, 0)
    ov.topLine:SetColorTexture(r, g, b, 0.28)
    ov.bottomLine:ClearAllPoints()
    ov.bottomLine:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", barW, 0)
    ov.bottomLine:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", 0, 0)
    ov.bottomLine:SetColorTexture(r, g, b, 0.65)
    ov.rightLine:SetColorTexture(r, g, b, 0.28)
    for i = 1, #ov.markers do
        ov.markers[i]:Hide()
    end
    ov:Show()
    return ov
end

local function FindApplicantMemberFrame(row, memberIdx)
    if row.lines and row.lines[memberIdx] then
        local line = row.lines[memberIdx]
        return line, line.name, (line.spec or (line.roles and line.roles[1]))
    end
    if row.Members and row.Members[memberIdx] then
        local m = row.Members[memberIdx]
        return m, m.Name, m.RoleIcon1 or m.RoleIcon
    end
    local children = { row:GetChildren() }
    for i = 1, #children do
        local c = children[i]
        if c and c.memberIdx == memberIdx then
            return c, c.Name or c.name, c.RoleIcon1 or c.RoleIcon
        end
    end
    return nil, nil, nil
end

local function ShouldPaintRow(row, res)
    if not row then return false end
    local shown = row.IsShown and row:IsShown()
    local ea = row.GetEffectiveAlpha and Guard.SafeNumber(row:GetEffectiveAlpha())
    if not shown or (ea and ea < 0.05) then
        HideRowOverlay(row)
        return false
    end
    if not res or not res.matches or #res.matches == 0 then
        HideRowOverlay(row)
        return false
    end
    return true
end

local function PaintApplicantRow(row, res)
    if not ShouldPaintRow(row, res) then return end

    local ov = PaintRowAccent(row, res.hasBlack, res.maxSeverity, IsResPeerOnly(res))

    local perMember = {}
    for i = 1, #res.matches do
        local item = res.matches[i]
        local idx = item.memberIndex or 1
        local slot = perMember[idx]
        if not slot then
            slot = { hasBlack = false, hasGreen = false }
            perMember[idx] = slot
        end
        if item.match.hasBlack then slot.hasBlack = true end
        if item.match.hasGreen then slot.hasGreen = true end
    end

    local mIdx = 0
    for idx, slot in pairs(perMember) do
        local _, nameFS, roleStop = FindApplicantMemberFrame(row, idx)
        if nameFS then
            mIdx = mIdx + 1
            PlaceAlignedMarker(ov, mIdx, nameFS, roleStop, slot.hasBlack, true)
        end
    end
end

local function PaintSearchRow(row, res)
    if not ShouldPaintRow(row, res) then return end

    local ov = PaintRowAccent(row, res.hasBlack, res.maxSeverity, IsResPeerOnly(res))
    local nameFS = row.name or row.Name
    local stopRegion = row.status or row.DiscordIcon or row.Level or row.DataDisplay or row.ActivityName
    PlaceAlignedMarker(ov, 1, nameFS, stopRegion, res.hasBlack, false)
end

local hookedBrowseRows = setmetatable({}, { __mode = "k" })
local browseNoteCard = nil
local foreverLfgHooksInstalled = false

local function HideBrowseNoteCard()
    if browseNoteCard then
        browseNoteCard:Hide()
    end
end

local function EnsureBrowseNoteCard()
    if browseNoteCard then return browseNoteCard end

    local T = ns.Theme
    local card = CreateFrame("Frame", "TheListBrowseNoteCard", UIParent)
    card:SetFrameStrata("TOOLTIP")
    card:EnableMouse(false)
    card:SetSize(280, 60)

    local pop = T and T.BG_POPUP or { r = 0.077, g = 0.068, b = 0.058 }
    if T and T.SolidTex then
        local bg = T:SolidTex(card, "BACKGROUND", pop.r, pop.g, pop.b, 0.96)
        bg:SetAllPoints()
        card._bg = bg
        card._brd = T:MakeBorder(card, 1, 1, 1, 0.22, bg)
        card._topBar = T:SolidTex(card, "ARTWORK", 1, 0.3, 0.3, 0.95)
    else
        local bg = card:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(pop.r, pop.g, pop.b, 0.96)
        card._bg = bg
        card._topBar = card:CreateTexture(nil, "ARTWORK")
        card._topBar:SetColorTexture(1, 0.3, 0.3, 0.95)
    end
    card._topBar:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
    card._topBar:SetPoint("TOPRIGHT", card, "TOPRIGHT", -1, -1)
    card._topBar:SetHeight(2)

    card._lines = {}
    card:Hide()
    browseNoteCard = card
    return card
end

local function ShowBrowseNoteCard(row, res)
    if not (row and res and res.matches and #res.matches > 0) then
        HideBrowseNoteCard()
        return
    end

    local allLines = {}
    for i = 1, #res.matches do
        local item = res.matches[i]
        local lines = GetMatchSummaryLines(item.match, item.name)
        for j = 1, #lines do
            allLines[#allLines + 1] = lines[j]
        end
    end
    if #allLines == 0 then
        HideBrowseNoteCard()
        return
    end

    local card = EnsureBrowseNoteCard()
    local r, g, b = GetTagColors(res.hasBlack)
    if card._topBar then card._topBar:SetColorTexture(r, g, b, 0.95) end
    if card._brd and card._brd.SetColor then card._brd:SetColor(r, g, b, 0.55) end

    local T = ns.Theme
    local maxW = 220
    local totalH = 12
    for i = 1, #allLines do
        local l = allLines[i]
        local fs = card._lines[i]
        if not fs then
            if T and T.MakeFont then
                fs = T:MakeFont(card, 11, "", 1, 1, 1, 0.95)
            else
                fs = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            end
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(true)
            card._lines[i] = fs
        end
        fs:ClearAllPoints()
        if i == 1 then
            fs:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)
        else
            fs:SetPoint("TOPLEFT", card._lines[i - 1], "BOTTOMLEFT", 0, -3)
        end
        fs:SetWidth(300)
        fs:SetTextColor(l.r or 1, l.g or 1, l.b or 1, 1)
        fs:SetText(l.left or "")
        fs:Show()
        local sw = fs.GetStringWidth and Guard.SafeNumber(fs:GetStringWidth()) or nil
        local sh = fs.GetStringHeight and Guard.SafeNumber(fs:GetStringHeight()) or nil
        if sw and sw > maxW then maxW = math.min(340, math.ceil(sw)) end
        totalH = totalH + ((sh and sh > 0) and sh or 13) + 3
    end
    for i = #allLines + 1, #card._lines do
        card._lines[i]:Hide()
    end

    local cardW = math.min(360, math.max(220, maxW + 20))
    for i = 1, #allLines do
        card._lines[i]:SetWidth(cardW - 20)
    end
    card:SetSize(cardW, math.max(36, math.ceil(totalH + 6)))
    if card._brd and card._brd.Fit then card._brd:Fit() end

    local tip = _G.LFGBrowseSearchEntryTooltip
    local anchor = (tip and tip.IsShown and tip:IsShown()) and tip or row
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
    card:Show()
end

local function RefreshBlizzardSearchRow(entryFrame)
    if not entryFrame then return end
    if not DB:Settings().warnLfgSearch then
        HideRowOverlay(entryFrame)
        return
    end
    local rid = entryFrame.resultID
    if not rid or Guard.IsSecret(rid) then
        HideRowOverlay(entryFrame)
        return
    end
    PaintSearchRow(entryFrame, Detector:InspectSearchResult(rid))
end

local function RefreshBlizzardApplicantRow(applicantFrame)
    if not applicantFrame then return end
    if not DB:Settings().warnLfgApplicants then
        HideRowOverlay(applicantFrame)
        return
    end
    local appID = applicantFrame.applicantID
    if not appID or Guard.IsSecret(appID) then
        HideRowOverlay(applicantFrame)
        return
    end
    PaintApplicantRow(applicantFrame, Detector:GetApplicantMatch(appID))
end

-- Recursively locate visible EllesmereUIGroupFinder custom row frames carrying .resultID / .applicantID
local function ScanEuiGroupFinderRows(rootFrame, depth, mode, seen)
    if not rootFrame or depth > 4 then return end
    local seenMap = seen or {}
    if rootFrame.IsMouseWheelEnabled and rootFrame:IsMouseWheelEnabled() and not hookedWheels[rootFrame] then
        hookedWheels[rootFrame] = true
        rootFrame:HookScript("OnMouseWheel", function()
            Hooks:RefreshLFGOverlays()
        end)
    end
    local tracked = euiOverlaidRows[mode]
    local children = { rootFrame:GetChildren() }
    for i = 1, #children do
        local child = children[i]
        if child and child.IsShown and child:IsShown() then
            if mode == "search" and child.resultID and not child.GetElementData then
                seenMap[child] = true
                if DB:Settings().warnLfgSearch then
                    local res = Detector:InspectSearchResult(child.resultID)
                    PaintSearchRow(child, res)
                    if res and res.matches and #res.matches > 0 then
                        tracked[child] = true
                    else
                        tracked[child] = nil
                    end
                else
                    HideRowOverlay(child)
                    tracked[child] = nil
                end
            elseif mode == "applicant" and child.applicantID and not child.GetElementData then
                seenMap[child] = true
                if DB:Settings().warnLfgApplicants then
                    local res = Detector:GetApplicantMatch(child.applicantID)
                    PaintApplicantRow(child, res)
                    if res and res.matches and #res.matches > 0 then
                        tracked[child] = true
                    else
                        tracked[child] = nil
                    end
                else
                    HideRowOverlay(child)
                    tracked[child] = nil
                end
            end
            ScanEuiGroupFinderRows(child, depth + 1, mode, seenMap)
        end
    end
    if depth == 1 and tracked then
        for row in pairs(tracked) do
            if not seenMap[row] then
                HideRowOverlay(row)
                tracked[row] = nil
            end
        end
    end
end

local function RefreshForeverBrowseRow(row)
    if not row or row.CategoryLabel or not row.resultID then
        HideRowOverlay(row)
        return
    end
    if not hookedBrowseRows[row] and row.HookScript then
        hookedBrowseRows[row] = true
        pcall(row.HookScript, row, "OnEnter", function(self)
            if not DB:Settings().warnTooltips then return end
            local rid = self.resultID
            if not rid or Guard.IsSecret(rid) then return end
            local res = Detector:InspectSearchResult(rid)
            if res and res.matches and #res.matches > 0 then
                ShowBrowseNoteCard(self, res)
            else
                HideBrowseNoteCard()
            end
        end)
        pcall(row.HookScript, row, "OnLeave", function()
            HideBrowseNoteCard()
        end)
    end
    RefreshBlizzardSearchRow(row)
end

local refreshQueued = false
function Hooks:RefreshLFGOverlays()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        local lfg = _G.LFGListFrame
        if lfg then
            local sp = lfg.SearchPanel
            if sp and sp:IsShown() then
                if sp.ScrollBox and sp.ScrollBox.ForEachFrame then
                    sp.ScrollBox:ForEachFrame(RefreshBlizzardSearchRow)
                end
                if IsEuiGroupFinderLoaded() then
                    ScanEuiGroupFinderRows(sp, 1, "search")
                end
            end
            local av = lfg.ApplicationViewer
            if av and av:IsShown() then
                if av.ScrollBox and av.ScrollBox.ForEachFrame then
                    av.ScrollBox:ForEachFrame(RefreshBlizzardApplicantRow)
                end
                if IsEuiGroupFinderLoaded() then
                    ScanEuiGroupFinderRows(av, 1, "applicant")
                end
            end
        end
        local bf = _G.LFGBrowseFrame
        if bf and bf:IsShown() and _G.LFGBrowseFrameScrollBox and _G.LFGBrowseFrameScrollBox.ForEachFrame then
            _G.LFGBrowseFrameScrollBox:ForEachFrame(RefreshForeverBrowseRow)
        end
    end)
end

local function InstallForeverLFGHooks()
    if foreverLfgHooksInstalled then return end
    foreverLfgHooksInstalled = true

    if _G.LFGBrowseSearchEntry_Update then
        hooksecurefunc("LFGBrowseSearchEntry_Update", RefreshForeverBrowseRow)
    end
    local bsb = _G.LFGBrowseFrameScrollBox
    if bsb and bsb.Update then
        hooksecurefunc(bsb, "Update", function()
            Hooks:RefreshLFGOverlays()
        end)
    end
    local btip = _G.LFGBrowseSearchEntryTooltip
    if btip and btip.HookScript then
        pcall(btip.HookScript, btip, "OnHide", HideBrowseNoteCard)
    end
    local bf = _G.LFGBrowseFrame
    if bf and bf.HookScript then
        pcall(bf.HookScript, bf, "OnHide", HideBrowseNoteCard)
    end
    Hooks:RefreshLFGOverlays()
end

local function EnsureTooltipResetHooks(tooltip)
    if not tooltip or hookedTooltips[tooltip] or not tooltip.HookScript then return end
    hookedTooltips[tooltip] = true
    if not tooltip.HasScript or tooltip:HasScript("OnTooltipCleared") then
        pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", function(tip)
            tipAnnotatedSerial[tip] = nil
        end)
    end
    if not tooltip.HasScript or tooltip:HasScript("OnHide") then
        pcall(tooltip.HookScript, tooltip, "OnHide", function(tip)
            tipAnnotatedSerial[tip] = nil
        end)
    end
end

local function AnnotateSearchTooltip(tooltip, resultID)
    if not tooltip or not resultID or Guard.IsSecret(resultID) then return end
    if not DB:Settings().warnTooltips then return end
    EnsureTooltipResetHooks(tooltip)
    local key = "S:" .. tostring(resultID)
    if tipAnnotatedSerial[tooltip] == key then return end
    tipAnnotatedSerial[tooltip] = key

    local res = Detector:InspectSearchResult(resultID)
    if not res or #res.matches == 0 then return end
    for i = 1, #res.matches do
        local item = res.matches[i]
        AppendMatchToTooltip(tooltip, item.match, item.name)
    end
    tooltip:Show()
end

local function AnnotateApplicantTooltip(tooltip, applicantID, memberIdx)
    if not tooltip or not applicantID or Guard.IsSecret(applicantID) then return end
    if not DB:Settings().warnTooltips then return end
    EnsureTooltipResetHooks(tooltip)
    local key = "A:" .. tostring(applicantID) .. ":" .. tostring(memberIdx or 0)
    if tipAnnotatedSerial[tooltip] == key then return end
    tipAnnotatedSerial[tooltip] = key

    local res = Detector:GetApplicantMatch(applicantID)
    if not res then return end

    local showedAny = false
    for i = 1, #res.matches do
        local item = res.matches[i]
        if not memberIdx or item.memberIndex == memberIdx or #res.matches > 1 then
            AppendMatchToTooltip(tooltip, item.match, item.name)
            showedAny = true
        end
    end
    if showedAny then tooltip:Show() end
end

local function GetMenuTargetName(contextData, ownerRegion)
    if Guard.CanReadTable(contextData) then
        if Guard.SafeBool(contextData.isSelf) == true or Guard.IsSecret(contextData.name) then
            return nil, nil, nil
        end

        local resolvedGuid = Guard.SafeString(contextData.guid)
        if not resolvedGuid and contextData.playerLocation and _G.C_PlayerInfo and _G.C_PlayerInfo.GetGUIDFromPlayerLocation then
            local okLoc, locGuid = pcall(_G.C_PlayerInfo.GetGUIDFromPlayerLocation, contextData.playerLocation)
            if okLoc then
                resolvedGuid = Guard.SafeString(locGuid)
            end
        end

        -- Standard unit / player / friend context menus
        if Guard.SafeString(contextData.unit) then
            local info = Guard.SafeUnitInfo(contextData.unit)
            if info then return info.name, info.guid or resolvedGuid, info.class end
        end
        if Guard.SafeString(contextData.name) then
            local name = contextData.name
            local second = Guard.IsForever() and Guard.SafeString(contextData.surname) or Guard.SafeString(contextData.server)
            local _, display = Guard.NormalizeNameRealm(name, second)
            if display then return display, resolvedGuid, nil end
        end
        if Guard.CanReadTable(contextData.accountInfo) and Guard.CanReadTable(contextData.accountInfo.gameAccountInfo) then
            local ga = contextData.accountInfo.gameAccountInfo
            local cn = Guard.SafeString(ga.characterName)
            local rn = (not Guard.IsForever()) and Guard.SafeString(ga.realmName) or nil
            if cn then
                local _, display = Guard.NormalizeNameRealm(cn, rn)
                return display, Guard.SafeString(ga.playerGuid) or resolvedGuid, nil
            end
        end
        if contextData.resultID and not Guard.IsSecret(contextData.resultID) and _G.C_LFGList then
            if _G.C_LFGList.GetSearchResultInfo then
                local ok, info = pcall(_G.C_LFGList.GetSearchResultInfo, contextData.resultID)
                if ok and Guard.CanReadTable(info) and Guard.SafeString(info.leaderName) then
                    return info.leaderName, resolvedGuid, nil
                end
            end
            if _G.C_LFGList.GetSearchResultLeaderInfo then
                local okL, leader = pcall(_G.C_LFGList.GetSearchResultLeaderInfo, contextData.resultID)
                if okL and Guard.CanReadTable(leader) and Guard.SafeString(leader.name) then
                    return leader.name, resolvedGuid, Guard.SafeString(leader.classFilename or leader.class)
                end
            end
        end
    end

    -- Fallback for LFG applicant/search rows (Blizzard or EUI GroupFinder or Forever)
    if ownerRegion then
        local parent = ownerRegion.GetParent and ownerRegion:GetParent() or nil
        local appID = ownerRegion.applicantID or (parent and parent.applicantID)
        local memIdx = ownerRegion.memberIdx or 1
        if appID and not Guard.IsSecret(appID) and _G.C_LFGList and _G.C_LFGList.GetApplicantMemberInfo then
            local ok, name, class = pcall(_G.C_LFGList.GetApplicantMemberInfo, appID, memIdx)
            if ok and Guard.SafeString(name) then
                return name, nil, Guard.SafeString(class)
            end
        end
        local rid = ownerRegion.resultID or (parent and parent.resultID)
        if rid and not Guard.IsSecret(rid) and _G.C_LFGList then
            if _G.C_LFGList.GetSearchResultInfo then
                local ok, info = pcall(_G.C_LFGList.GetSearchResultInfo, rid)
                if ok and Guard.CanReadTable(info) and Guard.SafeString(info.leaderName) then
                    return info.leaderName, nil, nil
                end
            end
            if _G.C_LFGList.GetSearchResultLeaderInfo then
                local okL, leader = pcall(_G.C_LFGList.GetSearchResultLeaderInfo, rid)
                if okL and Guard.CanReadTable(leader) and Guard.SafeString(leader.name) then
                    return leader.name, nil, Guard.SafeString(leader.classFilename or leader.class)
                end
            end
        end
    end

    return nil, nil, nil
end

local MENU_TAGS = {
    "MENU_UNIT_PLAYER",
    "MENU_UNIT_ENEMY_PLAYER",
    "MENU_UNIT_PARTY",
    "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_RAID",
    "MENU_UNIT_TARGET",
    "MENU_UNIT_FOCUS",
    "MENU_UNIT_FRIEND",
    "MENU_UNIT_BN_FRIEND",
    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
    "MENU_LFG_FRAME_MEMBER_APPLY",
    "MENU_LFG_FRAME_SEARCH_ENTRY",
}

local function InstallContextMenus()
    if not (_G.Menu and _G.Menu.ModifyMenu) then return end

    for _, tag in ipairs(MENU_TAGS) do
        _G.Menu.ModifyMenu(tag, function(ownerRegion, rootDescription, contextData)
            if Guard.IsForever() and Guard.IsForeverGamepadUI() then return end
            if not DB:Settings().addRightClickMenu then return end
            local targetName, guid, class = GetMenuTargetName(contextData, ownerRegion)
            if not targetName then return end
            local key = Guard.NormalizeNameRealm(targetName)
            local myKey = Guard.GetPlayerKey()
            if not key or (myKey and key == myKey) then return end

            local match = DB:Lookup(targetName, guid, false)
            local personal = match and match.personal
            local goodHex = (ns.Theme and ns.Theme.GetGoodHex and ns.Theme:GetGoodHex()) or "|cff3ec8ec"

            rootDescription:CreateDivider()
            if personal then
                rootDescription:CreateTitle("|cffff4d4dTHE|r " .. goodHex .. "LIST|r")
                rootDescription:CreateButton("Edit Note / Entry...", function()
                    if ns.QuickModal then
                        ns.QuickModal:Open({
                            name = personal.name,
                            guid = personal.guid or guid,
                            class = personal.class or class,
                            entry = personal,
                        })
                    end
                end)
                rootDescription:CreateButton("Remove from THE LIST", function()
                    DB:RemovePersonal(personal.key)
                    ns.Print("Removed " .. personal.name .. " from THE LIST.")
                end)
            else
                local sub = rootDescription:CreateButton("|cffff4d4dTHE|r " .. goodHex .. "LIST|r")
                sub:CreateButton("|cffff4d4dAdd to Bad Bois...|r", function()
                    if ns.QuickModal then
                        ns.QuickModal:Open({
                            name = targetName,
                            guid = guid,
                            class = class,
                            listType = ns.LIST_BLACK,
                        })
                    end
                end)
                sub:CreateButton(goodHex .. "Add to Good Bois...|r", function()
                    if ns.QuickModal then
                        ns.QuickModal:Open({
                            name = targetName,
                            guid = guid,
                            class = class,
                            listType = ns.LIST_GREEN,
                        })
                    end
                end)
            end
        end)
    end
end

function Hooks:Init()
    if initialized then return end
    initialized = true

    -- Unit tooltip annotation
    if _G.TooltipDataProcessor and _G.TooltipDataProcessor.AddTooltipPostCall and _G.Enum and _G.Enum.TooltipDataType then
        _G.TooltipDataProcessor.AddTooltipPostCall(_G.Enum.TooltipDataType.Unit, function(tooltip, data)
            if not DB:Settings().warnTooltips then return end
            local info = nil
            if tooltip and tooltip.GetUnit then
                local ok, _, unit = pcall(tooltip.GetUnit, tooltip)
                if ok and Guard.SafeString(unit) then
                    info = Guard.SafeUnitInfo(unit, true)
                end
            end
            if info and info.isPlayer then
                DB:AttachGuid(info.name, info.guid, info.class)
                local match = DB:Lookup(info.name, info.guid)
                if match then
                    AppendMatchToTooltip(tooltip, match)
                end
            elseif Guard.CanReadTable(data) then
                local dataGuid = Guard.SafeString(data.guid)
                if dataGuid then
                    local match = DB:Lookup(nil, dataGuid)
                    if match then
                        AppendMatchToTooltip(tooltip, match)
                    end
                end
            end
        end)
    end

    -- LFG tooltip hooks (shared by Blizzard UI and EllesmereUIGroupFinder)
    if _G.LFGListUtil_SetSearchEntryTooltip then
        hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", function(tooltip, resultID)
            AnnotateSearchTooltip(tooltip, resultID)
        end)
    end
    if _G.LFGListApplicantMember_OnEnter then
        hooksecurefunc("LFGListApplicantMember_OnEnter", function(line)
            if not line or not line.GetParent then return end
            local p = line:GetParent()
            local appID = p and p.applicantID
            AnnotateApplicantTooltip(GameTooltip, appID, line.memberIdx)
        end)
    end

    -- Extra GameTooltip guard for custom / private tooltips (e.g., EUI GroupFinder streamer mode)
    if _G.GameTooltip then
        EnsureTooltipResetHooks(_G.GameTooltip)
        _G.GameTooltip:HookScript("OnShow", function(tip)
            local owner = tip:GetOwner()
            if not owner then return end
            if owner.resultID then
                AnnotateSearchTooltip(tip, owner.resultID)
            elseif owner.memberIdx and owner:GetParent() and owner:GetParent().applicantID then
                AnnotateApplicantTooltip(tip, owner:GetParent().applicantID, owner.memberIdx)
            end
        end)
    end

    -- LFG row overlays
    if _G.LFGListSearchEntry_Update then
        hooksecurefunc("LFGListSearchEntry_Update", RefreshBlizzardSearchRow)
    end
    if _G.LFGListSearchPanel_UpdateResults then
        hooksecurefunc("LFGListSearchPanel_UpdateResults", function()
            Hooks:RefreshLFGOverlays()
        end)
    end
    if _G.LFGListApplicationViewer_UpdateApplicant then
        hooksecurefunc("LFGListApplicationViewer_UpdateApplicant", RefreshBlizzardApplicantRow)
    end

    ns:On("SEARCH_RESULTS_UPDATED", function() Hooks:RefreshLFGOverlays() end)
    ns:On("APPLICANTS_SCANNED", function() Hooks:RefreshLFGOverlays() end)
    ns:On("DB_CHANGED", function() Hooks:RefreshLFGOverlays() end)

    if Guard.IsForever() then
        local isVanillaLfgLoaded = _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded
            and _G.C_AddOns.IsAddOnLoaded("Blizzard_GroupFinder_VanillaStyle")
        if isVanillaLfgLoaded then
            InstallForeverLFGHooks()
        elseif _G.EventUtil and _G.EventUtil.ContinueOnAddOnLoaded then
            _G.EventUtil.ContinueOnAddOnLoaded("Blizzard_GroupFinder_VanillaStyle", InstallForeverLFGHooks)
        else
            local lfgLoader = CreateFrame("Frame")
            Guard.SafeRegisterEvent(lfgLoader, "ADDON_LOADED")
            lfgLoader:SetScript("OnEvent", function(self, _, addonName)
                if addonName == "Blizzard_GroupFinder_VanillaStyle" then
                    self:UnregisterEvent("ADDON_LOADED")
                    InstallForeverLFGHooks()
                end
            end)
        end
    end

    InstallContextMenus()
end
