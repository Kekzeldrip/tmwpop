--[[--------------------------------------------------------------------
    TMWPop – Tracker.lua
    Maintains a real-time snapshot of the player's combat state.

    Inspired by the event-tracking patterns in ascott18/TellMeWhen:
      • Buff / debuff tracking  (UNIT_AURA)
      • Cooldown tracking       (SPELL_UPDATE_COOLDOWN)
      • Resource tracking       (UNIT_POWER_UPDATE, UNIT_HEALTH)
      • Combo-point / charges   (UNIT_POWER_FREQUENT)
      • Combat state            (PLAYER_REGEN_DISABLED / _ENABLED)
      • Target info             (PLAYER_TARGET_CHANGED)
      • GCD tracking            (via spell cooldown API)
----------------------------------------------------------------------]]

local Tracker = {}
TMWPop.Tracker = Tracker

local GCD_THRESHOLD = 1.5   -- seconds; cooldowns <= this are GCD-only
local GCD_SPELL_ID  = 61304 -- hidden GCD spell used by the Blizzard API

--[[--------------------------------------------------------------------
    Snapshot structure
----------------------------------------------------------------------]]

local snapshot = {
    inCombat      = false,
    time          = 0,         -- GetTime()
    gcdRemains    = 0,

    -- player resources
    health        = 1,
    healthMax     = 1,
    healthPct     = 100,
    power         = 0,
    powerMax      = 1,
    powerType     = 0,
    comboPoints   = 0,

    -- target
    hasTarget      = false,
    targetHealth   = 1,
    targetHealthMax= 1,
    targetHealthPct= 100,

    -- active_enemies approximation (nameplates)
    activeEnemies  = 0,

    -- tables filled per-update
    buffs      = {},   -- [spellName_lower] = { up, remains, stacks, duration }
    debuffs    = {},   -- [spellName_lower] on target
    cooldowns  = {},   -- [spellName_lower] = { ready, remains, charges, chargesFractional }
    dots       = {},   -- alias of debuffs for simc compat
}

Tracker.snapshot = snapshot

--[[--------------------------------------------------------------------
    Helpers
----------------------------------------------------------------------]]

local function lower(s)
    return s and s:lower():gsub("[%s%-]", "_") or ""
end

local function clamp(v, lo, hi) return math.min(math.max(v, lo), hi) end

-- TWW returns "secret" tainted values from unit functions in certain contexts.
-- tonumber() on a secret value returns nil, so we use this as a safe guard.
-- This mirrors what TellMeWhen does with issecretvalue() in Resources.lua.
local function safeNum(v, default)
    return tonumber(v) or default
end

--[[--------------------------------------------------------------------
    Spell API wrappers (C_Spell for TWW 11.x, fallback for Classic)
    Mirrors the logic in ascott18/TellMeWhen Components/Core/Common/Cooldowns.lua
    but standalone – no dependency on TMW.COMMON.
----------------------------------------------------------------------]]

local GetSpellCooldown
if C_Spell and C_Spell.GetSpellCooldown then
    local _fn = C_Spell.GetSpellCooldown
    GetSpellCooldown = function(spell)
        local result = _fn(spell)
        if not result then return nil end
        return result  -- table: { startTime, duration, isEnabled, modRate }
    end
else
    local _fn = _G.GetSpellCooldown
    GetSpellCooldown = function(spell)
        local startTime, duration, isEnabled, modRate = _fn(spell)
        if not startTime then return nil end
        return { startTime = startTime, duration = duration, isEnabled = isEnabled, modRate = modRate or 1 }
    end
end

local GetSpellCharges
if C_Spell and C_Spell.GetSpellCharges then
    local _fn = C_Spell.GetSpellCharges
    GetSpellCharges = function(spell)
        local result = _fn(spell)
        if not result then return nil end
        return result  -- table: { currentCharges, maxCharges, cooldownStartTime, cooldownDuration, chargeModRate }
    end
elseif _G.GetSpellCharges then
    local _fn = _G.GetSpellCharges
    GetSpellCharges = function(spell)
        local currentCharges, maxCharges, cooldownStartTime, cooldownDuration = _fn(spell)
        if not cooldownStartTime then return nil end
        return { currentCharges = currentCharges, maxCharges = maxCharges, cooldownStartTime = cooldownStartTime, cooldownDuration = cooldownDuration, chargeModRate = 1 }
    end
end

--[[--------------------------------------------------------------------
    Aura scanning
----------------------------------------------------------------------]]

local function ScanAuras(unit, dest)
    -- Wipe previous data
    for k in pairs(dest) do dest[k] = nil end

    for i = 1, 40 do
        local name, _, stacks, _, duration, expirationTime, source
        if AuraUtil and AuraUtil.UnpackAuraData then
            -- Retail 10.x / 11.x aura API
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, unit == "player" and "HELPFUL" or "HARMFUL")
            if not aura then break end
            name            = aura.name
            stacks          = aura.applications or 0
            duration        = aura.duration or 0
            expirationTime  = aura.expirationTime or 0
            source          = aura.sourceUnit
        else
            -- Classic / older API fallback
            name, _, stacks, _, duration, expirationTime, source = UnitBuff and UnitBuff(unit, i) or UnitAura(unit, i)
            if not name then break end
        end

        local key = lower(name)
        local remains = math.max((expirationTime or 0) - GetTime(), 0)
        dest[key] = {
            up       = true,
            remains  = remains,
            stacks   = stacks or 0,
            duration = duration or 0,
        }
    end
end

--[[--------------------------------------------------------------------
    Cooldown scanning – scans the player's spellbook
----------------------------------------------------------------------]]

local trackedSpells = {}   -- populated once on PLAYER_READY

local function BuildSpellList()
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        -- TWW 11.x spellbook API
        local numLines = C_SpellBook.GetNumSpellBookSkillLines()
        for i = 1, numLines do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(i)
            if info then
                for j = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local itemInfo = C_SpellBook.GetSpellBookItemInfo(j, Enum.SpellBookSpellBank.Player)
                    if itemInfo and itemInfo.name then
                        trackedSpells[lower(itemInfo.name)] = itemInfo.name
                    end
                end
            end
        end
    else
        -- Classic / older retail spellbook API
        local numTabs = GetNumSpellTabs and GetNumSpellTabs() or 0
        for tab = 1, numTabs do
            local _, _, offset, numSpells = GetSpellTabInfo(tab)
            for j = offset + 1, offset + numSpells do
                local spellName = GetSpellBookItemName(j, "spell")
                if spellName then
                    trackedSpells[lower(spellName)] = spellName
                end
            end
        end
    end
end

local function ScanCooldowns()
    local now = GetTime()
    for key, spellName in pairs(trackedSpells) do
        local cd = GetSpellCooldown(spellName)
        if cd then
            local startTime = safeNum(cd.startTime, 0)
            local duration  = safeNum(cd.duration,  0)
            local remains = 0
            if startTime > 0 and duration > GCD_THRESHOLD then
                remains = math.max(startTime + duration - now, 0)
            end
            local charges, maxCharges, chargeStart, chargeDur = 0, 1, 0, 0
            if GetSpellCharges then
                local chargeInfo = GetSpellCharges(spellName)
                if chargeInfo then
                    charges     = safeNum(chargeInfo.currentCharges,    0)
                    maxCharges  = safeNum(chargeInfo.maxCharges,        1)
                    chargeStart = safeNum(chargeInfo.cooldownStartTime, 0)
                    chargeDur   = safeNum(chargeInfo.cooldownDuration,  0)
                end
            end
            local frac = charges
            if chargeDur > 0 and chargeStart > 0 then
                frac = frac + clamp((now - chargeStart) / chargeDur, 0, 1)
            end
            snapshot.cooldowns[key] = {
                ready              = remains == 0,
                remains            = remains,
                charges            = charges,
                maxCharges         = maxCharges,
                chargesFractional  = frac,
            }
        end
    end
end

--[[--------------------------------------------------------------------
    GCD helper
----------------------------------------------------------------------]]

local function UpdateGCD()
    local cd = GetSpellCooldown(GCD_SPELL_ID)
    if cd then
        local startTime = safeNum(cd.startTime, 0)
        local duration  = safeNum(cd.duration,  0)
        if startTime > 0 then
            snapshot.gcdRemains = math.max(startTime + duration - GetTime(), 0)
        else
            snapshot.gcdRemains = 0
        end
    else
        snapshot.gcdRemains = 0
    end
end

--[[--------------------------------------------------------------------
    Resource / health helpers
----------------------------------------------------------------------]]

local function UpdateResources()
    local health    = safeNum(UnitHealth("player"),    1)
    local healthMax = safeNum(UnitHealthMax("player"), 1)
    snapshot.health    = health
    snapshot.healthMax = healthMax
    snapshot.healthPct = healthMax > 0 and (health / healthMax * 100) or 100

    snapshot.powerType = safeNum(UnitPowerType("player"), 0)
    snapshot.power     = safeNum(UnitPower("player"),     0)
    snapshot.powerMax  = safeNum(UnitPowerMax("player"),  1)

    -- Combo points (rogue, feral, …)
    local cp = GetComboPoints and GetComboPoints("player", "target") or UnitPower("player", 4)
    snapshot.comboPoints = safeNum(cp, 0)
end

local function UpdateTarget()
    snapshot.hasTarget = UnitExists("target") and not UnitIsFriend("player", "target")
    if snapshot.hasTarget then
        local tHealth    = safeNum(UnitHealth("target"),    1)
        local tHealthMax = safeNum(UnitHealthMax("target"), 1)
        snapshot.targetHealth    = tHealth
        snapshot.targetHealthMax = tHealthMax
        snapshot.targetHealthPct = tHealthMax > 0 and (tHealth / tHealthMax * 100) or 100
    end
end

local function CountEnemies()
    local count = 0
    if C_NamePlate then
        local plates = C_NamePlate.GetNamePlates() or {}
        for _, plate in ipairs(plates) do
            local unit = plate.namePlateUnitToken
            if unit and UnitCanAttack("player", unit) and not UnitIsDead(unit) then
                count = count + 1
            end
        end
    end
    snapshot.activeEnemies = math.max(count, snapshot.hasTarget and 1 or 0)
end

--[[--------------------------------------------------------------------
    Full snapshot refresh – called from Engine on each tick
----------------------------------------------------------------------]]

function Tracker.Refresh()
    snapshot.time = GetTime()
    UpdateGCD()
    UpdateResources()
    UpdateTarget()
    ScanAuras("player", snapshot.buffs)
    if snapshot.hasTarget then
        ScanAuras("target", snapshot.debuffs)
    else
        for k in pairs(snapshot.debuffs) do snapshot.debuffs[k] = nil end
    end
    -- dots is an alias for debuffs (SimC uses both terms)
    snapshot.dots = snapshot.debuffs
    ScanCooldowns()
    CountEnemies()

    snapshot.inCombat = UnitAffectingCombat and UnitAffectingCombat("player") or false
end

--[[--------------------------------------------------------------------
    Event wiring
----------------------------------------------------------------------]]

local trackFrame = CreateFrame("Frame", "TMWPopTrackerFrame", UIParent)
trackFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
trackFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
trackFrame:RegisterEvent("PLAYER_TARGET_CHANGED")

trackFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        snapshot.inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        snapshot.inCombat = false
    elseif event == "PLAYER_TARGET_CHANGED" then
        UpdateTarget()
    end
end)

TMWPop.RegisterEvent("PLAYER_READY", function()
    BuildSpellList()
end)