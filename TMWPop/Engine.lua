--[[--------------------------------------------------------------------
    TMWPop – Engine.lua
    Recommendation engine: evaluates parsed SimC rules against the
    current Tracker snapshot and returns Recommendation objects.
----------------------------------------------------------------------]]

local Engine = {}
TMWPop.Engine = Engine

--- Current compiled profile (set via Engine.LoadProfile)
local activeProfile = nil

--[[--------------------------------------------------------------------
    Condition evaluator
    Resolves a condNode tree against the Tracker snapshot.
----------------------------------------------------------------------]]

local function resolveIdent(ident, snap)
    -- ident examples:
    --   buff.enrage.up          → snap.buffs["enrage"].up
    --   buff.enrage.remains     → snap.buffs["enrage"].remains
    --   buff.enrage.stack       → snap.buffs["enrage"].stacks
    --   debuff.rupture.up       → snap.debuffs["rupture"].up
    --   dot.rip.remains         → snap.dots["rip"].remains
    --   cooldown.rampage.ready  → snap.cooldowns["rampage"].ready
    --   cooldown.x.remains      → snap.cooldowns["x"].remains
    --   cooldown.x.charges      → snap.cooldowns["x"].charges
    --   cooldown.x.charges_fractional
    --   health.pct              → snap.healthPct
    --   rage / mana / energy    → snap.power  (resource alias)
    --   combo_points            → snap.comboPoints
    --   active_enemies          → snap.activeEnemies
    --   time                    → snap.time   (combat time approx.)
    --   gcd.remains             → snap.gcdRemains
    --   target.health.pct       → snap.targetHealthPct

    local parts = {}
    for p in ident:gmatch("[^%.]+") do parts[#parts+1] = p end

    local cat = parts[1]

    -- buff.<name>.<field>
    if cat == "buff" or cat == "talent" then
        local name  = parts[2]
        local field = parts[3] or "up"
        local b = snap.buffs[name]
        if not b then
            if field == "up" then return false end
            if field == "stack" or field == "stacks" then return 0 end
            return 0
        end
        if field == "up"    then return b.up end
        if field == "down"  then return not b.up end
        if field == "stack" or field == "stacks" then return b.stacks end
        if field == "remains" then return b.remains end
        if field == "duration" then return b.duration end
        return 0
    end

    -- debuff.<name>.<field>  /  dot.<name>.<field>
    if cat == "debuff" or cat == "dot" then
        local name  = parts[2]
        local field = parts[3] or "up"
        local d = snap.debuffs[name]
        if not d then
            if field == "up" then return false end
            return 0
        end
        if field == "up"       then return d.up end
        if field == "down"     then return not d.up end
        if field == "remains"  then return d.remains end
        if field == "stack" or field == "stacks" then return d.stacks end
        return 0
    end

    -- cooldown.<name>.<field>
    if cat == "cooldown" then
        local name  = parts[2]
        local field = parts[3] or "ready"
        local cd = snap.cooldowns[name]
        if not cd then
            if field == "ready" or field == "up" then return true end -- unknown spell = assume ready
            return 0
        end
        if field == "ready" or field == "up" then return cd.ready end
        if field == "remains"          then return cd.remains end
        if field == "charges"          then return cd.charges end
        if field == "charges_fractional" then return cd.chargesFractional end
        return 0
    end

    -- gcd
    if cat == "gcd" then
        if parts[2] == "remains" then return snap.gcdRemains end
        return 0
    end

    -- target
    if cat == "target" then
        if parts[2] == "health" and parts[3] == "pct" then return snap.targetHealthPct end
        return 0
    end

    -- health
    if cat == "health" then
        if parts[2] == "pct" then return snap.healthPct end
        return snap.health
    end

    -- resource shorthands
    if cat == "rage" or cat == "mana" or cat == "energy"
       or cat == "focus" or cat == "runic_power" or cat == "fury"
       or cat == "pain" or cat == "insanity" or cat == "maelstrom"
       or cat == "astral_power" or cat == "holy_power" then
        return snap.power
    end

    if cat == "combo_points" then return snap.comboPoints end
    if cat == "active_enemies" or cat == "spell_targets" then return snap.activeEnemies end
    if cat == "time" then return snap.time end

    -- fallback
    return 0
end

--- Convert Lua booleans to numbers for comparison operators
local function tonum(v)
    if v == true  then return 1 end
    if v == false then return 0 end
    return tonumber(v) or 0
end

local function toBool(v)
    if v == nil or v == false or v == 0 then return false end
    return true
end

--- Evaluate a condNode tree → boolean
local function evalCond(node, snap)
    if not node then return true end  -- no condition ⇒ always true

    local op = node.op

    if op == "value" then
        local v = node.value
        if type(v) == "string" then
            return resolveIdent(v, snap)
        end
        return v
    end

    if op == "not" then
        return not toBool(evalCond(node.left, snap))
    end

    if op == "and" then
        return toBool(evalCond(node.left, snap)) and toBool(evalCond(node.right, snap))
    end

    if op == "or" then
        return toBool(evalCond(node.left, snap)) or toBool(evalCond(node.right, snap))
    end

    -- comparison operators
    local lv = tonum(evalCond(node.left, snap))
    local rv = tonum(evalCond(node.right, snap))

    if op == "="  then return lv == rv end
    if op == "!=" then return lv ~= rv end
    if op == "<"  then return lv <  rv end
    if op == ">"  then return lv >  rv end
    if op == "<=" then return lv <= rv end
    if op == ">=" then return lv >= rv end

    return false
end

-- Expose for testing
Engine.EvalCondition = evalCond
Engine.ResolveIdent  = resolveIdent

--[[--------------------------------------------------------------------
    Recommendation object
----------------------------------------------------------------------]]

--[[
    Recommendation = {
        action   = "rampage",
        listName = "default",
        index    = 3,          -- position in the list
        args     = { ... },
    }
----------------------------------------------------------------------]]

--[[--------------------------------------------------------------------
    Evaluate a single action list, return first passing Rule.
----------------------------------------------------------------------]]

local function evaluateList(listName, profile, snap, depth)
    depth = depth or 0
    if depth > 10 then return nil end  -- guard against infinite recursion

    local list = profile.lists[listName]
    if not list then return nil end

    for i, rule in ipairs(list) do
        -- call_action_list / run_action_list
        if rule.action == "call_action_list" or rule.action == "run_action_list" then
            local subName = rule.args and rule.args.name
            if subName then
                -- evaluate the list's own condition first
                if toBool(evalCond(rule.condTree, snap)) then
                    local rec = evaluateList(subName, profile, snap, depth + 1)
                    if rec then return rec end
                    -- run_action_list stops evaluation; call_action_list falls through
                    if rule.action == "run_action_list" then return nil end
                end
            end
        else
            if toBool(evalCond(rule.condTree, snap)) then
                return {
                    action   = rule.action,
                    listName = listName,
                    index    = i,
                    args     = rule.args,
                }
            end
        end
    end
    return nil
end

--[[--------------------------------------------------------------------
    Public API
----------------------------------------------------------------------]]

--- Load a parsed profile into the engine.
function Engine.LoadProfile(profile)
    activeProfile = profile
end

--- Run recommendation: evaluate "default" list against current snapshot.
--- @param snap table  Tracker.snapshot (or a mock for tests)
--- @return table|nil  Recommendation or nil
function Engine.Recommend(snap)
    if not activeProfile or not snap then return nil end

    -- try "precombat" if not yet in combat
    if not snap.inCombat and activeProfile.lists["precombat"] then
        local rec = evaluateList("precombat", activeProfile, snap, 0)
        if rec then return rec end
    end

    return evaluateList("default", activeProfile, snap, 0)
end

--- Evaluate from an explicit list name (useful for sub-lists).
function Engine.RecommendFrom(listName, snap)
    if not activeProfile or not snap then return nil end
    return evaluateList(listName, activeProfile, snap, 0)
end

--- Convenience: full pipeline from raw text.
function Engine.LoadProfileText(text)
    local profile = TMWPop.SimCParser.Parse(text)
    Engine.LoadProfile(profile)
    return profile
end
