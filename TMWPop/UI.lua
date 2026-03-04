--[[--------------------------------------------------------------------
    TMWPop – UI.lua
    Main recommendation icon + configuration / import menu.
----------------------------------------------------------------------]]

local UI = {}
TMWPop.UI = UI

--[[--------------------------------------------------------------------
    Constants
----------------------------------------------------------------------]]

local ICON_SIZE = 64
local UPDATE_HZ = 10            -- ticks per second while in combat
local IDLE_HZ   = 2             -- ticks per second out of combat
local FALLBACK_TEXTURE = "Interface\Icons\INV_Misc_QuestionMark"

--[[--------------------------------------------------------------------
    Compat: GetSpellInfo was removed in Midnight (12.0).
    Use C_Spell.GetSpellInfo if available, otherwise fall back.
    Returns a FileDataID (number) on Midnight, or a texture path on older clients.
----------------------------------------------------------------------]]

local function GetSpellIconTexture(spellName)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellName)
        if info and info.iconID then
            return info.iconID  -- FileDataID, usable directly with SetTexture
        end
        return nil
    elseif _G.GetSpellInfo then
        local _, _, tex = _G.GetSpellInfo(spellName)
        return tex
    end
    return nil
end

--[[--------------------------------------------------------------------
    Main Icon Frame
----------------------------------------------------------------------]]

local icon = CreateFrame("Button", "TMWPopMainIcon", UIParent, "SecureActionButtonTemplate")
icn:SetSize(ICON_SIZE, ICON_SIZE)
icn:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
icn:SetMovable(true)
icn:EnableMouse(true)
icn:RegisterForDrag("LeftButton")

-- backdrop texture
icon.tex = icon:CreateTexture(nil, "BACKGROUND")
icn.tex:SetAllPoints()
icn.tex:SetTexture(FALLBACK_TEXTURE)

-- cooldown sweep
icon.cd = CreateFrame("Cooldown", "TMWPopMainIconCD", icon, "CooldownFrameTemplate")
icn.cd:SetAllPoints()

-- glow border (highlight on recommended spell)
icon.glow = icon:CreateTexture(nil, "OVERLAY")
icn.glow:SetTexture("Interface\Buttons\UI-ActionButton-Border")
icn.glow:SetBlendMode("ADD")
icn.glow:SetPoint("CENTER")
icn.glow:SetSize(ICON_SIZE * 1.4, ICON_SIZE * 1.4)
icn.glow:SetAlpha(0)

-- tooltip
icon:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.spellName then
        GameTooltip:SetText(self.spellName, 1, 1, 1)
    else
        GameTooltip:SetText("TMWPop – No recommendation", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end)
icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

-- dragging
icon:SetScript("OnDragStart", function(self)
    if not TMWPop.db or not TMWPop.db.locked then self:StartMoving() end
end)
icon:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

--- Display a recommendation on the icon.
local function ShowRecommendation(rec)
    if not rec then
        icon.tex:SetTexture(FALLBACK_TEXTURE)
        icon.spellName = nil
        icon.glow:SetAlpha(0)
        return
    end

    local spellName = rec.action:gsub("_", " ")
    icon.spellName = spellName

    -- GetSpellIconTexture handles Midnight (C_Spell.GetSpellInfo)
    -- and older clients (_G.GetSpellInfo).
    local tex = GetSpellIconTexture(spellName)
    if tex then
        icon.tex:SetTexture(tex)
    else
        icon.tex:SetTexture(FALLBACK_TEXTURE)
    end

    icon.glow:SetAlpha(0.6)
end

--[[--------------------------------------------------------------------
    Tick loop (OnUpdate)
----------------------------------------------------------------------]]

local elapsed_acc = 0

icon:SetScript("OnUpdate", function(self, elapsed)
    elapsed_acc = elapsed_acc + elapsed
    local hz = (TMWPop.Tracker and TMWPop.Tracker.snapshot.inCombat) and UPDATE_HZ or IDLE_HZ
    local interval = 1 / hz
    if elapsed_acc < interval then return end
    elapsed_acc = elapsed_acc - interval

    if not TMWPop.db or not TMWPop.db.enabled then
        ShowRecommendation(nil)
        return
    end

    if TMWPop.Tracker then TMWPop.Tracker.Refresh() end

    local snap = TMWPop.Tracker and TMWPop.Tracker.snapshot
    local rec  = TMWPop.Engine and TMWPop.Engine.Recommend(snap)
    ShowRecommendation(rec)
end)

--[[--------------------------------------------------------------------
    Import Window (simple EditBox dialog)
----------------------------------------------------------------------]]

local importFrame

local function CreateImportFrame()
    if importFrame then return importFrame end

    importFrame = CreateFrame("Frame", "TMWPopImportFrame", UIParent, "BasicFrameTemplateWithInset")
    importFrame:SetSize(520, 400)
    importFrame:SetPoint("CENTER")
    importFrame:SetMovable(true)
    importFrame:EnableMouse(true)
    importFrame:RegisterForDrag("LeftButton")
    importFrame:SetScript("OnDragStart", importFrame.StartMoving)
    importFrame:SetScript("OnDragStop", importFrame.StopMovingOrSizing)
    importFrame:SetFrameStrata("DIALOG")

    importFrame.title = importFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    importFrame.title:SetPoint("TOP", 0, -6)
    importFrame.title:SetText("TMWPop – Import SimC Profile")

    local scroll = CreateFrame("ScrollFrame", "TMWPopImportScroll", importFrame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -36)
    scroll:SetPoint("BOTTOMRIGHT", -30, 44)

    local editBox = CreateFrame("EditBox", "TMWPopImportEdit", scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(460)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(editBox)

    importFrame.editBox = editBox

    local btn = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
    btn:SetSize(100, 24)
    btn:SetPoint("BOTTOMRIGHT", -8, 8)
    btn:SetText("Load")
    btn:SetScript("OnClick", function()
        local text = editBox:GetText()
        if text and text ~= "" then
            TMWPop.db.profile = text
            local profile = TMWPop.Engine.LoadProfileText(text)
            if TMWPop.SimCParser.IsValid(profile) then
                print("|cff00ccffTMWPop|r: profile loaded successfully.")
            else
                print("|cffff4444TMWPop|r: profile appears empty – check your paste.")
            end
        end
        importFrame:Hide()
    end)

    local cancelBtn = CreateFrame("Button", nil, importFrame, "UIPanelButtonTemplate")
    cancelBtn:SetSize(100, 24)
    cancelBtn:SetPoint("RIGHT", btn, "LEFT", -8, 0)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() importFrame:Hide() end)

    importFrame:Hide()
    return importFrame
end

--[[--------------------------------------------------------------------
    Event hooks
----------------------------------------------------------------------]]

TMWPop.RegisterEvent("SHOW_IMPORT", function()
    local f = CreateImportFrame()
    if TMWPop.db and TMWPop.db.profile and TMWPop.db.profile ~= "" then
        f.editBox:SetText(TMWPop.db.profile)
    else
        f.editBox:SetText("")
    end
    f:Show()
end)

TMWPop.RegisterEvent("RESET_POSITION", function()
    icon:ClearAllPoints()
    icon:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    print("|cff00ccffTMWPop|r: icon position reset.")
end)

TMWPop.RegisterEvent("LOCK_CHANGED", function(_, locked)
    icon:SetMovable(not locked)
end)

TMWPop.RegisterEvent("PLAYER_READY", function()
    if TMWPop.db and TMWPop.db.profile and TMWPop.db.profile ~= "" then
        local profile = TMWPop.Engine.LoadProfileText(TMWPop.db.profile)
        if TMWPop.SimCParser.IsValid(profile) then
            print("|cff00ccffTMWPop|r: saved profile loaded.")
        end
    end
end)