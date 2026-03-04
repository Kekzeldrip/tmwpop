--[[--------------------------------------------------------------------
    TMWPop – Tests/TestRunner.lua
    Standalone Lua 5.1 unit-test runner for SimCParser and Engine.
    Run:  lua5.1 Tests/TestRunner.lua   (from the TMWPop directory)
----------------------------------------------------------------------]]

----------------------------------------------------------------------
-- Minimal WoW API stubs so we can load Core / SimCParser / Engine
----------------------------------------------------------------------

-- globals that WoW provides
CreateFrame   = function() return { RegisterEvent=function() end, SetScript=function() end } end
UIParent      = {}
GetTime       = function() return 100.0 end
UnitHealth    = function() return 50000 end
UnitHealthMax = function() return 100000 end
UnitPower     = function() return 80 end
UnitPowerMax  = function() return 100 end
UnitPowerType = function() return 1 end
UnitExists    = function() return true end
UnitIsFriend  = function() return false end
UnitAffectingCombat = function() return true end
GetComboPoints= function() return 3 end
GetSpellCooldown = function() return 0, 0, 1 end
GetSpellCharges  = function() return 2, 3, 95, 8 end
GetSpellInfo     = function(name) return name, nil, nil end
GetNumSpellTabs  = function() return 0 end
C_NamePlate      = { GetNamePlates = function() return {} end }
SLASH_TMWPOP1 = ""
SLASH_TMWPOP2 = ""
SlashCmdList  = {}
GameTooltip   = { SetOwner=function() end, SetText=function() end, Show=function() end, Hide=function() end }
strtrim = function(s) return s:match("^%s*(.-)%s*$") end
UnitIsDead = function() return false end
UnitCanAttack = function() return true end
UnitAura = function() return nil end
UnitBuff = function() return nil end
ChatFontNormal = {}
AuraUtil = nil

----------------------------------------------------------------------
-- Load addon sources in order
----------------------------------------------------------------------

TMWPop = {}
dofile("Core.lua")
dofile("SimCParser.lua")
dofile("Engine.lua")

----------------------------------------------------------------------
-- Tiny test framework
----------------------------------------------------------------------

local passed, failed, total = 0, 0, 0

local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write("  [PASS] " .. name .. "\n")
    else
        failed = failed + 1
        io.write("  [FAIL] " .. name .. ": " .. tostring(err) .. "\n")
    end
end

local function assertEqual(a, b, msg)
    if a ~= b then
        error((msg or "") .. " expected <" .. tostring(b) .. "> got <" .. tostring(a) .. ">", 2)
    end
end

local function assertTrue(v, msg)
    if not v then error((msg or "assertTrue failed") .. " got: " .. tostring(v), 2) end
end

local function assertFalse(v, msg)
    if v then error((msg or "assertFalse failed") .. " got: " .. tostring(v), 2) end
end

local function assertNotNil(v, msg)
    if v == nil then error(msg or "expected non-nil", 2) end
end

----------------------------------------------------------------------
-- SimCParser tests
----------------------------------------------------------------------

print("\n=== SimCParser Tests ===")

test("Parse empty string returns empty profile", function()
    local p = TMWPop.SimCParser.Parse("")
    assertTrue(not TMWPop.SimCParser.IsValid(p))
end)

test("Parse metadata lines", function()
    local text = [[
class=warrior
spec=fury
level=80
race=orc
]]
    local p = TMWPop.SimCParser.Parse(text)
    assertEqual(p.meta.class, "warrior")
    assertEqual(p.meta.spec, "fury")
    assertEqual(p.meta.level, "80")
    assertEqual(p.meta.race, "orc")
end)

test("Parse simple action list", function()
    local text = [[
actions=rampage
actions+=raging_blow
actions+=bloodthirst
]]
    local p = TMWPop.SimCParser.Parse(text)
    assertTrue(TMWPop.SimCParser.IsValid(p))
    assertEqual(#p.lists["default"], 3)
    assertEqual(p.lists["default"][1].action, "rampage")
    assertEqual(p.lists["default"][2].action, "raging_blow")
    assertEqual(p.lists["default"][3].action, "bloodthirst")
end)

test("Parse named sub-lists", function()
    local text = [[
actions.precombat=flask
actions.precombat+=food
actions=call_action_list,name=precombat
actions+=rampage
]]
    local p = TMWPop.SimCParser.Parse(text)
    assertEqual(#p.lists["precombat"], 2)
    assertEqual(#p.lists["default"], 2)
    assertEqual(p.lists["precombat"][1].action, "flask")
end)

test("Parse action with if-condition", function()
    local text = "actions=rampage,if=buff.enrage.up&rage>=80"
    local p = TMWPop.SimCParser.Parse(text)
    local rule = p.lists["default"][1]
    assertEqual(rule.action, "rampage")
    assertNotNil(rule.condTree)
    assertEqual(rule.args["if"], "buff.enrage.up&rage>=80")
end)

test("Parse condition: simple comparison", function()
    local tree = TMWPop.SimCParser.ParseCondition("rage>=80")
    assertEqual(tree.op, ">=")
    assertEqual(tree.left.value, "rage")
    assertEqual(tree.right.value, 80)
end)

test("Parse condition: AND", function()
    local tree = TMWPop.SimCParser.ParseCondition("buff.enrage.up&rage>=80")
    assertEqual(tree.op, "and")
    assertEqual(tree.left.value, "buff.enrage.up")
    assertEqual(tree.right.op, ">=")
end)

test("Parse condition: OR", function()
    local tree = TMWPop.SimCParser.ParseCondition("buff.a.up|buff.b.up")
    assertEqual(tree.op, "or")
end)

test("Parse condition: NOT", function()
    local tree = TMWPop.SimCParser.ParseCondition("!buff.enrage.up")
    assertEqual(tree.op, "not")
    assertEqual(tree.left.value, "buff.enrage.up")
end)

test("Parse condition: parentheses", function()
    local tree = TMWPop.SimCParser.ParseCondition("(buff.a.up|buff.b.up)&rage>50")
    assertEqual(tree.op, "and")
    assertEqual(tree.left.op, "or")
    assertEqual(tree.right.op, ">")
end)

test("Parse condition: nested NOT with parens", function()
    local tree = TMWPop.SimCParser.ParseCondition("!(buff.a.up&buff.b.up)")
    assertEqual(tree.op, "not")
    assertEqual(tree.left.op, "and")
end)

test("Comments and blank lines are skipped", function()
    local text = [[
# This is a comment
class=warrior

# another comment
actions=rampage
]]
    local p = TMWPop.SimCParser.Parse(text)
    assertEqual(p.meta.class, "warrior")
    assertEqual(#p.lists["default"], 1)
end)

test("Parse slash-separated alternatives", function()
    local text = "actions=rampage/raging_blow"
    local p = TMWPop.SimCParser.Parse(text)
    assertEqual(#p.lists["default"], 2)
    assertEqual(p.lists["default"][1].action, "rampage")
    assertEqual(p.lists["default"][2].action, "raging_blow")
end)

----------------------------------------------------------------------
-- Engine condition evaluator tests
----------------------------------------------------------------------

print("\n=== Engine Tests ===")

local function makeSnap(overrides)
    local snap = {
        inCombat      = true,
        time          = 100,
        gcdRemains    = 0,
        health        = 50000,
        healthMax     = 100000,
        healthPct     = 50,
        power         = 80,
        powerMax      = 100,
        powerType     = 1,
        comboPoints   = 3,
        hasTarget     = true,
        targetHealth  = 40000,
        targetHealthMax = 100000,
        targetHealthPct = 40,
        activeEnemies = 1,
        buffs    = {},
        debuffs  = {},
        dots     = {},
        cooldowns = {},
    }
    snap.dots = snap.debuffs  -- alias
    if overrides then
        for k, v in pairs(overrides) do snap[k] = v end
    end
    return snap
end

test("Resolve rage identifier", function()
    local snap = makeSnap()
    local v = TMWPop.Engine.ResolveIdent("rage", snap)
    assertEqual(v, 80)
end)

test("Resolve combo_points", function()
    local snap = makeSnap()
    assertEqual(TMWPop.Engine.ResolveIdent("combo_points", snap), 3)
end)

test("Resolve buff.X.up (present)", function()
    local snap = makeSnap({ buffs = { enrage = { up = true, remains = 5, stacks = 1, duration = 8 } } })
    assertTrue(TMWPop.Engine.ResolveIdent("buff.enrage.up", snap))
end)

test("Resolve buff.X.up (absent)", function()
    local snap = makeSnap()
    assertFalse(TMWPop.Engine.ResolveIdent("buff.enrage.up", snap))
end)

test("Resolve buff.X.remains", function()
    local snap = makeSnap({ buffs = { enrage = { up = true, remains = 5.2, stacks = 1, duration = 8 } } })
    assertEqual(TMWPop.Engine.ResolveIdent("buff.enrage.remains", snap), 5.2)
end)

test("Resolve cooldown.X.ready (ready)", function()
    local snap = makeSnap({ cooldowns = { rampage = { ready = true, remains = 0, charges = 1, chargesFractional = 1 } } })
    assertTrue(TMWPop.Engine.ResolveIdent("cooldown.rampage.ready", snap))
end)

test("Resolve cooldown.X.ready (on CD)", function()
    local snap = makeSnap({ cooldowns = { rampage = { ready = false, remains = 3.5, charges = 0, chargesFractional = 0.5 } } })
    assertFalse(TMWPop.Engine.ResolveIdent("cooldown.rampage.ready", snap))
end)

test("Resolve health.pct", function()
    local snap = makeSnap()
    assertEqual(TMWPop.Engine.ResolveIdent("health.pct", snap), 50)
end)

test("Resolve target.health.pct", function()
    local snap = makeSnap()
    assertEqual(TMWPop.Engine.ResolveIdent("target.health.pct", snap), 40)
end)

test("Resolve active_enemies", function()
    local snap = makeSnap()
    assertEqual(TMWPop.Engine.ResolveIdent("active_enemies", snap), 1)
end)

test("Eval simple true condition (rage>=80)", function()
    local tree = TMWPop.SimCParser.ParseCondition("rage>=80")
    local snap = makeSnap()
    assertTrue(TMWPop.Engine.EvalCondition(tree, snap))
end)

test("Eval simple false condition (rage>90)", function()
    local tree = TMWPop.SimCParser.ParseCondition("rage>90")
    local snap = makeSnap()
    assertFalse(TMWPop.Engine.EvalCondition(tree, snap))
end)

test("Eval AND condition", function()
    local tree = TMWPop.SimCParser.ParseCondition("buff.enrage.up&rage>=80")
    local snap = makeSnap({ buffs = { enrage = { up = true, remains = 5, stacks = 1 } } })
    assertTrue(TMWPop.Engine.EvalCondition(tree, snap))
end)

test("Eval AND condition (one side false)", function()
    local tree = TMWPop.SimCParser.ParseCondition("buff.enrage.up&rage>=80")
    local snap = makeSnap()  -- no enrage buff
    assertFalse(TMWPop.Engine.EvalCondition(tree, snap))
end)

test("Eval OR condition", function()
    local tree = TMWPop.SimCParser.ParseCondition("buff.enrage.up|rage>=80")
    local snap = makeSnap()  -- no enrage but rage=80
    assertTrue(TMWPop.Engine.EvalCondition(tree, snap))
end)

test("Eval NOT condition", function()
    local tree = TMWPop.SimCParser.ParseCondition("!buff.enrage.up")
    local snap = makeSnap()  -- no enrage
    assertTrue(TMWPop.Engine.EvalCondition(tree, snap))
end)

test("Eval nil condition (no if= clause) → always true", function()
    assertTrue(TMWPop.Engine.EvalCondition(nil, makeSnap()))
end)

----------------------------------------------------------------------
-- Full Engine.Recommend tests
----------------------------------------------------------------------

test("Recommend with unconditional list picks first action", function()
    local text = [[
actions=rampage
actions+=raging_blow
]]
    TMWPop.Engine.LoadProfileText(text)
    local rec = TMWPop.Engine.Recommend(makeSnap())
    assertNotNil(rec)
    assertEqual(rec.action, "rampage")
end)

test("Recommend skips failed conditions", function()
    local text = [[
actions=rampage,if=rage>=100
actions+=raging_blow
]]
    TMWPop.Engine.LoadProfileText(text)
    local snap = makeSnap()  -- rage=80, fails >=100
    local rec = TMWPop.Engine.Recommend(snap)
    assertNotNil(rec)
    assertEqual(rec.action, "raging_blow")
end)

test("Recommend with buff condition", function()
    local text = [[
actions=rampage,if=buff.enrage.up
actions+=raging_blow
]]
    TMWPop.Engine.LoadProfileText(text)

    -- no enrage → skip rampage → raging_blow
    local rec1 = TMWPop.Engine.Recommend(makeSnap())
    assertEqual(rec1.action, "raging_blow")

    -- enrage up → rampage
    local snap2 = makeSnap({ buffs = { enrage = { up = true, remains = 5, stacks = 1 } } })
    local rec2 = TMWPop.Engine.Recommend(snap2)
    assertEqual(rec2.action, "rampage")
end)

test("Recommend with call_action_list", function()
    local text = [[
actions.aoe=whirlwind
actions=call_action_list,name=aoe,if=active_enemies>2
actions+=rampage
]]
    TMWPop.Engine.LoadProfileText(text)

    -- 1 enemy → skip aoe → rampage
    local rec1 = TMWPop.Engine.Recommend(makeSnap())
    assertEqual(rec1.action, "rampage")

    -- 3 enemies → enter aoe → whirlwind
    local rec2 = TMWPop.Engine.Recommend(makeSnap({ activeEnemies = 3 }))
    assertEqual(rec2.action, "whirlwind")
end)

test("Recommend precombat list when out of combat", function()
    local text = [[
actions.precombat=flask
actions=rampage
]]
    TMWPop.Engine.LoadProfileText(text)

    local snap = makeSnap({ inCombat = false })
    local rec = TMWPop.Engine.Recommend(snap)
    assertEqual(rec.action, "flask")
end)

test("Recommend returns nil for empty profile", function()
    TMWPop.Engine.LoadProfileText("")
    local rec = TMWPop.Engine.Recommend(makeSnap())
    assertEqual(rec, nil)
end)

test("Recommend with debuff/dot condition", function()
    local text = [[
actions=garrote,if=!dot.garrote.up
actions+=mutilate
]]
    TMWPop.Engine.LoadProfileText(text)

    -- no garrote dot → garrote
    local rec1 = TMWPop.Engine.Recommend(makeSnap())
    assertEqual(rec1.action, "garrote")

    -- garrote already up → mutilate
    local snap2 = makeSnap({ debuffs = { garrote = { up = true, remains = 10, stacks = 1 } } })
    snap2.dots = snap2.debuffs
    local rec2 = TMWPop.Engine.Recommend(snap2)
    assertEqual(rec2.action, "mutilate")
end)

test("Recommend with cooldown condition", function()
    local text = [[
actions=recklessness,if=cooldown.recklessness.ready
actions+=rampage
]]
    TMWPop.Engine.LoadProfileText(text)

    -- CD ready → recklessness
    local snap1 = makeSnap({ cooldowns = { recklessness = { ready = true, remains = 0 } } })
    assertEqual(TMWPop.Engine.Recommend(snap1).action, "recklessness")

    -- CD not ready → rampage
    local snap2 = makeSnap({ cooldowns = { recklessness = { ready = false, remains = 60 } } })
    assertEqual(TMWPop.Engine.Recommend(snap2).action, "rampage")
end)

test("Recommend with complex nested condition", function()
    local text = "actions=rampage,if=(buff.enrage.up|rage>=90)&cooldown.recklessness.remains>10"
    TMWPop.Engine.LoadProfileText(text)

    -- enrage up, reck CD 60 → true
    local snap1 = makeSnap({
        buffs = { enrage = { up = true, remains = 5, stacks = 1 } },
        cooldowns = { recklessness = { ready = false, remains = 60, charges = 0, chargesFractional = 0 } },
    })
    assertNotNil(TMWPop.Engine.Recommend(snap1))

    -- no enrage, rage=80 (<90), reck CD 60 → false (left side fails)
    local snap2 = makeSnap({
        cooldowns = { recklessness = { ready = false, remains = 60, charges = 0, chargesFractional = 0 } },
    })
    assertEqual(TMWPop.Engine.Recommend(snap2), nil)
end)

----------------------------------------------------------------------
-- Summary
----------------------------------------------------------------------

print(string.format("\n=== Results: %d/%d passed, %d failed ===\n", passed, total, failed))
os.exit(failed > 0 and 1 or 0)
