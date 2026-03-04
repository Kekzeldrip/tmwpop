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
    -- Gather spells from spellbook tabs
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

local function ScanCooldowns()
    local now = GetTime()
    for key, spellName in pairs(trackedSpells) do
        local start, dur, enabled = GetSpellCooldown(spellName)
        if start then
            local remains = 0
            if start > 0 and dur > GCD_THRESHOLD then
                remains = math.max(start + dur - now, 0)
            end
            local charges, maxCharges, chargeStart, chargeDur = 0, 1, 0, 0
            if GetSpellCharges then
                charges, maxCharges, chargeStart, chargeDur = GetSpellCharges(spellName) or 0, 1, 0, 0
            end
            local frac = charges or 0
            if chargeDur and chargeDur > 0 and chargeStart and chargeStart > 0 then
                frac = frac + clamp((now - chargeStart) / chargeDur, 0, 1)
            end
            snapshot.cooldowns[key] = {
                ready              = remains == 0,
                remains            = remains,
                charges            = charges or 0,
                maxCharges         = maxCharges or 1,
                chargesFractional  = frac,
            }
        end
    end
end

--[[--------------------------------------------------------------------
    GCD helper
----------------------------------------------------------------------]]

local function UpdateGCD()
    local start, dur = GetSpellCooldown(GCD_SPELL_ID)
    if start and start > 0 then
        snapshot.gcdRemains = math.max(start + dur - GetTime(), 0)
    else
        snapshot.gcdRemains = 0
    end
end

--[[--------------------------------------------------------------------
    Resource / health helpers
----------------------------------------------------------------------]]

local function UpdateResources()
    snapshot.health    = UnitHealth("player") or 1
    snapshot.healthMax = UnitHealthMax("player") or 1
    snapshot.healthPct = snapshot.healthMax > 0 and (snapshot.health / snapshot.healthMax * 100) or 100

    snapshot.powerType = UnitPowerType("player") or 0
    snapshot.power     = UnitPower("player") or 0
    snapshot.powerMax  = UnitPowerMax("player") or 1

    -- Combo points (rogue, feral, …)
    snapshot.comboPoints = GetComboPoints and GetComboPoints("player", "target") or UnitPower("player", 4) or 0
end

local function UpdateTarget()
    snapshot.hasTarget = UnitExists("target") and not UnitIsFriend("player", "target")
    if snapshot.hasTarget then
        snapshot.targetHealth    = UnitHealth("target") or 1
        snapshot.targetHealthMax = UnitHealthMax("target") or 1
        snapshot.targetHealthPct = snapshot.targetHealthMax > 0
            and (snapshot.targetHealth / snapshot.targetHealthMax * 100) or 100
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
