local _, ns = ...

local Banner = {}
ns.AlertBanner = Banner

local Guard = ns.Guard
local DB = ns.DB
local Theme = ns.Theme

local BANNER_W = 400
local BANNER_H = 92
local SOUND_THROTTLE_SEC = 1.5

local frame
local isHovered = false
local isPreview = false
local isFadingOut = false
local currentPayload = nil
local alertQueue = {}
local lastSoundAt = {}
local totalDuration = 7
local remainingTime = 0
local fadeInGroup
local fadeOutGroup

local function SanitizeText(str, maxLen)
    if Guard.SanitizePeerText then
        return Guard.SanitizePeerText(str, maxLen)
    end
    if type(str) ~= "string" then return "" end
    local s = str
        :gsub("|H.-|h", "")
        :gsub("|h", "")
        :gsub("|c%x%x%x%x%x%x%x%x", "")
        :gsub("|r", "")
        :gsub("|T.-|t", "")
        :gsub("|A.-|a", "")
    if maxLen and #s > maxLen then
        s = s:sub(1, maxLen)
    end
    return s
end

local function GetPayloadDedupeKey(payload)
    if not payload then return nil end
    local k = payload.key or payload.name
    if type(k) ~= "string" or k == "" then return nil end
    return k:lower()
end

local function PlayThrottledSound(listType, soundKey)
    if not soundKey or soundKey == "none" then return end
    local now = _G.GetTime and _G.GetTime() or time()
    local lt = listType or ns.LIST_BLACK
    if lastSoundAt[lt] and (now - lastSoundAt[lt]) < SOUND_THROTTLE_SEC then
        return
    end
    lastSoundAt[lt] = now
    Guard.PlayAlertSound(soundKey)
end

local function ApplyPosition()
    if not frame then return end
    local root = DB:Root()
    local pos = root and root.bannerPos
    local scale = tonumber(DB:Settings().bannerScale) or 1.0
    scale = math.max(0.6, math.min(1.6, scale))
    frame:SetScale(scale)
    frame:ClearAllPoints()
    if pos and pos.centerX ~= nil and pos.centerY ~= nil then
        frame:SetPoint("CENTER", UIParent, "CENTER", pos.centerX / scale, pos.centerY / scale)
    elseif pos and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end
end

local function SaveStandalonePosition()
    if not frame then return end
    local root = DB:Root()
    if not root then return end
    local point, _, relPoint, x, y = frame:GetPoint()
    if point then
        root.bannerPos = { point = point, relPoint = relPoint, x = x, y = y }
    end
end

local function StopProgressUpdate()
    if frame then
        frame:SetScript("OnUpdate", nil)
    end
end

local function UpdateProgressBarVisual()
    if not (frame and frame._progressBar) then return end
    if isPreview or totalDuration <= 0 then
        frame._progressBar:Hide()
        return
    end
    local maxW = math.max(1, (frame:GetWidth() or BANNER_W) - 5)
    local ratio = math.max(0, math.min(1, remainingTime / totalDuration))
    frame._progressBar:SetWidth(math.max(1, maxW * ratio))
    frame._progressBar:SetShown(ratio > 0)
end

local function StartFadeOut()
    if not frame then return end
    StopProgressUpdate()
    if isPreview or isHovered then return end
    if fadeInGroup and fadeInGroup:IsPlaying() then
        fadeInGroup:Stop()
    end
    if fadeOutGroup then
        isFadingOut = true
        fadeOutGroup:Stop()
        fadeOutGroup:Play()
    else
        isFadingOut = false
        frame:Hide()
    end
end

local function OnCountdownUpdate(_, elapsed)
    if isPreview or isHovered or isFadingOut or totalDuration <= 0 then
        StopProgressUpdate()
        return
    end
    remainingTime = remainingTime - (elapsed or 0)
    if remainingTime <= 0 then
        remainingTime = 0
        if frame and frame._progressBar then
            frame._progressBar:Hide()
        end
        StartFadeOut()
        return
    end
    UpdateProgressBarVisual()
end

local function ResumeCountdown()
    if not frame then return end
    if isPreview or isHovered or isFadingOut then
        StopProgressUpdate()
        return
    end
    if totalDuration <= 0 or remainingTime <= 0 then
        StopProgressUpdate()
        return
    end
    UpdateProgressBarVisual()
    frame:SetScript("OnUpdate", OnCountdownUpdate)
end

local function UpdateActionAndQueueLayout()
    if not frame then return end
    local qCount = #alertQueue
    local showNext = (not isPreview) and qCount > 0
    local p = currentPayload
    local m = p and p.match
    local showCopy = (not isPreview) and m and m.peers and #m.peers > 0 and not m.personal

    frame._nextBtn:SetShown(showNext)
    frame._queueBadge:SetShown(showNext)
    if showNext then
        frame._queueBadge:SetText("1 / " .. tostring(1 + qCount))
    end

    frame._copyBtn:SetShown(showCopy == true)
    if showCopy then
        frame._copyBtn:ClearAllPoints()
        if showNext then
            frame._copyBtn:SetPoint("RIGHT", frame._queueBadge, "LEFT", -6, 0)
        else
            frame._copyBtn:SetPoint("TOPRIGHT", frame._closeBtn, "BOTTOMRIGHT", 0, -4)
        end
    end

    -- Keep nameLbl clear of Row 2 right-side controls
    local rightPad = -14
    if showNext and showCopy then
        rightPad = -144
    elseif showNext then
        rightPad = -92
    elseif showCopy then
        rightPad = -64
    end
    frame._nameLbl:ClearAllPoints()
    frame._nameLbl:SetPoint("TOPLEFT", frame._headline, "BOTTOMLEFT", 0, -5)
    frame._nameLbl:SetPoint("RIGHT", frame, "RIGHT", rightPad, 0)
end

local function DismissAll()
    isPreview = false
    isFadingOut = false
    currentPayload = nil
    wipe(alertQueue)
    StopProgressUpdate()
    if fadeInGroup and fadeInGroup:IsPlaying() then fadeInGroup:Stop() end
    if fadeOutGroup and fadeOutGroup:IsPlaying() then fadeOutGroup:Stop() end
    if frame then
        frame:SetAlpha(1)
        frame:Hide()
    end
end

local function ShowNextQueued()
    if #alertQueue == 0 then
        DismissAll()
        return
    end
    local nextPayload = table.remove(alertQueue, 1)
    Banner:ShowAlert(nextPayload, false)
end

local function BuildBannerFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "TheListAlertBanner", UIParent)
    frame:SetSize(BANNER_W, BANNER_H)
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(100)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:Hide()

    local bg = Theme:SolidTex(frame, "BACKGROUND", Theme.BG_POPUP.r, Theme.BG_POPUP.g, Theme.BG_POPUP.b, 0.96)
    bg:SetAllPoints()
    frame._bg = bg

    local brd = Theme:MakeBorder(frame, 1, 1, 1, 0.16, bg)
    frame._brd = brd

    -- Signature EllesmereUI top 2px accent bar + left severity bar
    local topBar = Theme:SolidTex(frame, "ARTWORK", 1, 0.3, 0.3, 0.95)
    topBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    topBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    topBar:SetHeight(2)
    frame._topBar = topBar

    local leftBar = Theme:SolidTex(frame, "ARTWORK", 1, 0.3, 0.3, 0.95)
    leftBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -3)
    leftBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
    leftBar:SetWidth(3)
    frame._leftBar = leftBar

    -- Bottom 2px countdown progress bar
    local progressBar = Theme:SolidTex(frame, "ARTWORK", 1, 0.3, 0.3, 0.95)
    progressBar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 1)
    progressBar:SetHeight(2)
    progressBar:SetWidth(BANNER_W - 5)
    progressBar:Hide()
    frame._progressBar = progressBar

    local headline = Theme:MakeFont(frame, 11, "OUTLINE", 1, 0.35, 0.35, 1)
    headline:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -10)
    headline:SetJustifyH("LEFT")
    frame._headline = headline

    -- Crisp bordered severity/type mini-badge on header row
    local sevPill = CreateFrame("Frame", nil, frame)
    sevPill:SetHeight(16)
    sevPill:SetPoint("LEFT", headline, "RIGHT", 8, 0)
    local sevBg = Theme:SolidTex(sevPill, "BACKGROUND", 0.12, 0.10, 0.10, 0.90)
    sevBg:SetAllPoints()
    local sevBrd = Theme:MakeBorder(sevPill, 1, 0.3, 0.3, 0.65, sevBg)
    local sevTxt = Theme:MakeFont(sevPill, 9, "OUTLINE", 1, 1, 1, 0.95)
    sevTxt:SetPoint("CENTER", 0, 0)
    sevPill._bg = sevBg
    sevPill._brd = sevBrd
    sevPill._txt = sevTxt
    frame._sevPill = sevPill

    local closeBtn = Theme:MakeButton(frame, "X", 22, 22, 10, DismissAll)
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
    frame._closeBtn = closeBtn

    local editBtn = Theme:MakeButton(frame, "Open", 48, 22, 10, function()
        if currentPayload and currentPayload.name and ns.QuickModal then
            local p = currentPayload
            local personal = p.match and p.match.personal
            ns.QuickModal:Open({
                name = p.name,
                guid = p.guid,
                class = p.class,
                listType = p.match and p.match.effectiveType or ns.LIST_BLACK,
                entry = personal,
            })
        elseif ns.OpenUI then
            ns.OpenUI()
        end
    end)
    editBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    frame._editBtn = editBtn

    local nextBtn = Theme:MakeButton(frame, "Next", 44, 20, 10, function()
        ShowNextQueued()
    end)
    nextBtn:SetPoint("TOPRIGHT", closeBtn, "BOTTOMRIGHT", 0, -4)
    nextBtn:Hide()
    frame._nextBtn = nextBtn

    local queueBadge = Theme:MakeFont(frame, 10, "OUTLINE", 1, 1, 1, 0.78)
    queueBadge:SetPoint("RIGHT", nextBtn, "LEFT", -6, 0)
    queueBadge:Hide()
    frame._queueBadge = queueBadge

    local copyBtn = Theme:MakeButton(frame, "Save", 46, 20, 10, function()
        local p = currentPayload
        local m = p and p.match
        if not (p and m and m.peers and #m.peers > 0 and not m.personal) then return end
        local entry = m.primary or m.peers[1].entry
        if not entry then return end
        local saved = DB:AdoptPeerEntry(entry, {
            guid = p.guid,
            class = p.class,
            listType = m.effectiveType or ns.LIST_BLACK,
        })
        if saved then
            m.personal = saved
        end
        ns.Print("Saved " .. tostring(entry.name or p.name) .. " to your personal list (local only).")
        UpdateActionAndQueueLayout()
    end, "accent")
    copyBtn:Hide()
    frame._copyBtn = copyBtn

    local nameLbl = Theme:MakeFont(frame, 15, "OUTLINE", 1, 1, 1, 1)
    nameLbl:SetPoint("TOPLEFT", headline, "BOTTOMLEFT", 0, -5)
    nameLbl:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    nameLbl:SetJustifyH("LEFT")
    nameLbl:SetWordWrap(false)
    frame._nameLbl = nameLbl

    local metaLbl = Theme:MakeFont(frame, 11, "", 1, 1, 1, 0.72)
    metaLbl:SetPoint("TOPLEFT", nameLbl, "BOTTOMLEFT", 0, -3)
    metaLbl:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    metaLbl:SetJustifyH("LEFT")
    metaLbl:SetWordWrap(false)
    frame._metaLbl = metaLbl

    local noteLbl = Theme:MakeFont(frame, 11, "", 0.92, 0.92, 0.92, 0.92)
    noteLbl:SetPoint("TOPLEFT", metaLbl, "BOTTOMLEFT", 0, -4)
    noteLbl:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    noteLbl:SetJustifyH("LEFT")
    noteLbl:SetWordWrap(true)
    noteLbl:SetMaxLines(2)
    frame._noteLbl = noteLbl

    fadeInGroup = frame:CreateAnimationGroup()
    local fadeIn = fadeInGroup:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(0.18)
    fadeIn:SetSmoothing("OUT")
    fadeInGroup:SetScript("OnFinished", function()
        if frame then frame:SetAlpha(1) end
    end)

    fadeOutGroup = frame:CreateAnimationGroup()
    local fadeOut = fadeOutGroup:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.22)
    fadeOut:SetSmoothing("IN")
    fadeOutGroup:SetScript("OnFinished", function()
        isFadingOut = false
        if #alertQueue > 0 and not isPreview then
            ShowNextQueued()
        else
            if frame then
                frame:Hide()
                frame:SetAlpha(1)
            end
            currentPayload = nil
        end
    end)

    local function OnBannerHoverEnter()
        isHovered = true
        StopProgressUpdate()
        if isFadingOut and fadeOutGroup then
            fadeOutGroup:Stop()
            isFadingOut = false
            frame:SetAlpha(1)
            if totalDuration > 0 and remainingTime <= 0 then
                remainingTime = math.min(totalDuration, 1.5)
            end
            UpdateProgressBarVisual()
        end
    end
    local function OnBannerHoverLeave()
        if frame and frame.IsMouseOver and frame:IsMouseOver() then
            return
        end
        isHovered = false
        ResumeCountdown()
    end

    frame:SetScript("OnEnter", OnBannerHoverEnter)
    frame:SetScript("OnLeave", OnBannerHoverLeave)
    for _, childBtn in ipairs({ closeBtn, editBtn, nextBtn, copyBtn }) do
        childBtn:HookScript("OnEnter", OnBannerHoverEnter)
        childBtn:HookScript("OnLeave", OnBannerHoverLeave)
    end
    frame:SetScript("OnHide", function()
        StopProgressUpdate()
    end)
    frame:SetScript("OnDragStart", function(self)
        if not (_G.EllesmereUI and _G.EllesmereUI.IsUnlockModeActive and _G.EllesmereUI.IsUnlockModeActive()) then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveStandalonePosition()
    end)

    ApplyPosition()
    return frame
end

local KIND_LABELS = {
    group        = "IN YOUR GROUP",
    applicant    = "QUEUED INTO YOUR GROUP",
    queued_group = "GROUP YOU QUEUED INTO",
    test         = "PREVIEW ALERT",
}

local function UpdateSeverityPill(isGreen, severity)
    local pill = frame and frame._sevPill
    if not pill then return end
    local text, r, g, b
    if isGreen then
        text = "GOOD BOI"
        r, g, b = Theme:GetGoodRGB()
    else
        local sev = severity or 2
        if sev >= 3 then
            text = "HARD AVOID"
            r, g, b = Theme:GetBadRGB()
        elseif sev == 2 then
            text = "WARN"
            r, g, b = 1.0, 0.72, 0.30
        else
            text = "NOTE"
            r, g, b = 0.68, 0.68, 0.72
        end
    end
    pill._txt:SetText(text)
    pill._txt:SetTextColor(r, g, b, 1)
    pill._brd:SetColor(r, g, b, 0.72)
    pill._bg:SetColorTexture(r * 0.18, g * 0.18, b * 0.18, 0.90)
    local tw = pill._txt:GetStringWidth()
    if Guard.IsSecret(tw) or type(tw) ~= "number" or tw <= 0 then tw = 44 end
    pill:SetWidth(math.ceil(tw + 12))
    if pill._brd and pill._brd.Fit then pill._brd:Fit() end
end

local MAX_ALERT_QUEUE = 20

local function EnqueueAlert(payload)
    if #alertQueue >= MAX_ALERT_QUEUE then
        return false
    end
    local key = GetPayloadDedupeKey(payload)
    if key then
        if currentPayload and GetPayloadDedupeKey(currentPayload) == key then
            return false
        end
        for i = 1, #alertQueue do
            if GetPayloadDedupeKey(alertQueue[i]) == key then
                return false
            end
        end
    end
    alertQueue[#alertQueue + 1] = payload
    UpdateActionAndQueueLayout()
    return true
end

function Banner:ShowAlert(payload, previewMode)
    local f = BuildBannerFrame()
    isPreview = (previewMode == true)
    isFadingOut = false
    if fadeInGroup and fadeInGroup:IsPlaying() then fadeInGroup:Stop() end
    if fadeOutGroup and fadeOutGroup:IsPlaying() then fadeOutGroup:Stop() end
    currentPayload = payload

    local match = payload.match
    local isGreen = (match and match.effectiveType == ns.LIST_GREEN)
    local r, g, b
    if isGreen then
        r, g, b = Theme:GetGoodRGB()
    else
        r, g, b = Theme:GetBadRGB()
    end

    f._topBar:SetColorTexture(r, g, b, 0.95)
    f._leftBar:SetColorTexture(r, g, b, 0.95)
    f._progressBar:SetColorTexture(r, g, b, 0.95)
    f._brd:SetColor(r, g, b, 0.45)

    f._headline:SetTextColor(r, g, b, 1)
    f._headline:SetText(isGreen and "GOOD BOI MATCH" or "YOU JUST MADE THE LIST!")

    local primary = match and match.primary
    UpdateSeverityPill(isGreen, primary and primary.severity or (match and match.maxSeverity) or 2)

    local cr, cg, cb = Guard.GetClassRGB(payload.class or (primary and primary.class))
    f._nameLbl:SetTextColor(cr, cg, cb, 1)
    f._nameLbl:SetText(SanitizeText(payload.name or "Unknown", 64))

    local kindTxt = KIND_LABELS[payload.kind]
    local rawSrc = tostring((match and match.primarySource) or "You")
    if match and not match.personal and DB.GetShortPeerLabel then
        local firstPeer = match.peers and match.peers[1]
        rawSrc = DB:GetShortPeerLabel(firstPeer and firstPeer.authorID, rawSrc)
    end
    local src = SanitizeText(rawSrc, 48)
    local cat = SanitizeText(tostring((primary and primary.category) or "Other"), 32)
    local peerExtra = ""
    if match and match.peers and #match.peers > 0 and match.personal then
        local n = #match.peers
        peerExtra = " (+" .. n .. (n == 1 and " friend)" or " friends)")
    elseif match and match.peers and #match.peers > 1 and not match.personal then
        peerExtra = " (+" .. (#match.peers - 1) .. " more)"
    end
    local metaPrefix = (kindTxt and kindTxt ~= "") and (kindTxt .. "  |  ") or ""
    f._metaLbl:SetText(metaPrefix .. "Source: " .. src .. peerExtra .. "  |  " .. cat)

    local noteText = (primary and ((primary.sharedNote ~= "" and primary.sharedNote) or primary.privateNote)) or ""
    if noteText == "" and match and match.peers and match.peers[1] and match.peers[1].entry then
        noteText = match.peers[1].entry.sharedNote or ""
    end
    noteText = SanitizeText(noteText, 280)
    if noteText == "" then noteText = "(No note recorded)" end
    f._noteLbl:SetText(noteText)

    UpdateActionAndQueueLayout()

    local noteH = f._noteLbl:GetStringHeight()
    if Guard.IsSecret(noteH) or type(noteH) ~= "number" or noteH <= 0 then noteH = 14 end
    local fitH = math.max(84, math.min(118, math.ceil(66 + noteH + 10)))
    f:SetSize(BANNER_W, fitH)
    if f._brd and f._brd.Fit then f._brd:Fit() end

    ApplyPosition()

    totalDuration = tonumber(DB:Settings().bannerDuration) or 7
    remainingTime = (not isPreview and totalDuration > 0) and totalDuration or 0

    if isPreview then
        f:SetAlpha(1)
        f._progressBar:Hide()
        f:Show()
        StopProgressUpdate()
    else
        f:SetAlpha(0)
        f:Show()
        if fadeInGroup then fadeInGroup:Play() else f:SetAlpha(1) end
        ResumeCountdown()
    end
end

function Banner:ShowTestAlert()
    wipe(alertQueue)
    local isForever = Guard.IsForever and Guard.IsForever()
    self:ShowAlert({
        kind = "test",
        name = isForever and "Chrisjericho" or "Chrisjericho-TarrenMill",
        class = "WARRIOR",
        match = {
            effectiveType = ns.LIST_BLACK,
            hasBlack = true,
            maxSeverity = 3,
            primarySource = "You",
            peers = {},
            primary = {
                listType = ns.LIST_BLACK,
                category = "Leaver",
                severity = 3,
                sharedNote = isForever
                    and "Left UBRS after first pull and whispered insults."
                    or "Left +14 Ara-Kara after first pull and whispered insults.",
            },
        },
    }, false)
    local testSound = DB:Settings().blackSound
    if testSound == "thelist_add" then testSound = "eui_siren" end
    PlayThrottledSound(ns.LIST_BLACK, testSound)
end

function Banner:GetFrame()
    return BuildBannerFrame()
end

function Banner:ApplySettings()
    ApplyPosition()
end

local function RegisterWithEUIUnlock()
    local eui = _G.EllesmereUI
    if not (eui and eui.RegisterUnlockElements and eui.MakeUnlockElement) then return end

    eui:RegisterUnlockElements({
        eui.MakeUnlockElement({
            key = "THE_LIST_AlertBanner",
            label = "THE LIST Alert",
            group = "THE LIST",
            order = 600,
            noResize = true,
            noSpecLayout = true,
            getFrame = function() return Banner:GetFrame() end,
            getSize = function()
                local f = Banner:GetFrame()
                return BANNER_W, (f and f:GetHeight() or BANNER_H)
            end,
            isHidden = function() return not DB:Settings().warnBanner end,
            savePos = function(_, _, _, x, y)
                local f = Banner:GetFrame()
                local root = DB:Root()
                if not (f and root) then return end
                local cur = root.bannerPos
                local isRestore = cur and x ~= nil and cur.centerX == x and cur.centerY == y
                if not isRestore and f:GetCenter() then
                    local cx, cy = f:GetCenter()
                    local upX, upY = UIParent:GetCenter()
                    local fes = f:GetEffectiveScale() or 1
                    local ues = UIParent:GetEffectiveScale() or 1
                    local ratio = fes / ues
                    root.bannerPos = {
                        centerX = cx * ratio - upX,
                        centerY = cy * ratio - upY,
                    }
                end
                if f and not eui._unlockActive then
                    ApplyPosition()
                end
            end,
            loadPos = function()
                local pos = DB:Root() and DB:Root().bannerPos
                if pos and pos.centerX ~= nil and pos.centerY ~= nil then
                    return {
                        point = "CENTER",
                        relPoint = "CENTER",
                        x = pos.centerX,
                        y = pos.centerY,
                    }
                end
                return nil
            end,
            clearPos = function()
                if DB:Root() then DB:Root().bannerPos = nil end
            end,
            applyPos = function()
                ApplyPosition()
            end,
        }),
    }, ns.ADDON_NAME)

    if eui.RegisterUnlockModeListener then
        eui:RegisterUnlockModeListener(ns.ADDON_NAME, function(active)
            if active then
                wipe(alertQueue)
                Banner:ShowAlert({
                    kind = "test",
                    name = "Alert Banner Preview",
                    class = "PRIEST",
                    match = {
                        effectiveType = ns.LIST_BLACK,
                        primarySource = "THE LIST",
                        peers = {},
                        primary = {
                            listType = ns.LIST_BLACK,
                            category = "Unlock Mode",
                            severity = 2,
                            sharedNote = "Drag or snap this banner anywhere in Unlock Mode.",
                        },
                    },
                }, true)
            else
                isPreview = false
                if frame then frame:Hide() end
            end
        end)
    end
end

local function FormatChatWarning(payload)
    local match = payload.match
    local isGreen = (match and match.effectiveType == ns.LIST_GREEN)
    local color = isGreen and Theme:GetGoodHex() or Theme:GetBadHex()
    local verb = isGreen and "GOOD BOI" or "BAD BOI"
    local where = (payload.kind == "group" and "is in your group")
        or (payload.kind == "applicant" and "queued for your group")
        or (payload.kind == "queued_group" and "is in the group you queued for")
        or "matched"

    local p = match and match.primary
    local rawNote = p and ((p.sharedNote ~= "" and p.sharedNote) or p.privateNote) or ""
    local note = SanitizeText(rawNote, 280)
    local src = SanitizeText(tostring((match and match.primarySource) or "You"), 48)
    local cat = SanitizeText(tostring((p and p.category) or "Other"), 32)
    local safeName = SanitizeText(tostring(payload.name or "Unknown"), 64):gsub("[|%[%]]", "")
    local link = "|Hplayer:" .. safeName .. "|h[" .. safeName .. "]|h"

    local msg = string.format("%s%s|r: %s %s (%s by %s)", color, verb, link, where, cat, src)
    if note ~= "" then
        msg = msg .. " - " .. note
    end
    return msg
end

function Banner:Init()
    BuildBannerFrame()
    RegisterWithEUIUnlock()

    ns:On("ALERT_MATCH", function(payload)
        local s = DB:Settings()
        if s.warnChatSummary then
            ns.Print(FormatChatWarning(payload))
        end
        if s.warnBanner then
            if frame and frame:IsShown() and not isPreview and not isFadingOut then
                EnqueueAlert(payload)
            else
                Banner:ShowAlert(payload, false)
            end
        end
        local isGreen = payload.match and payload.match.effectiveType == ns.LIST_GREEN
        local lt = isGreen and ns.LIST_GREEN or ns.LIST_BLACK
        local alertSound = isGreen and s.greenSound or s.blackSound
        -- thelist.mp3 is reserved exclusively for adding a Bad Boi, never group/LFG alerts
        if alertSound == "thelist_add" then
            alertSound = isGreen and "none" or "eui_siren"
        end
        PlayThrottledSound(lt, alertSound)
    end)

    ns:On("SETTINGS_CHANGED", function()
        ApplyPosition()
    end)
end
