-- test_nav.lua — 12-scenario suite driving nav.lua against mockturtle.lua.
-- Runs under plain `lua` (no external test lib). Prints "N passed, M failed"
-- and exits non-zero on any failure so it works as a CI gate.
--
-- Run:  lua test_nav.lua   (expect: 12 passed, 0 failed)

local Nav = require("nav")
local Mock = require("mockturtle")

local passed, failed = 0, 0

local function ok(cond, msg)
  if cond then
    passed = passed + 1
    -- print("  PASS: " .. msg)  -- uncomment for verbose runs
  else
    failed = failed + 1
    print("  FAIL: " .. msg)
  end
end

local function eq(actual, expected, msg)
  if actual == expected then
    ok(true, msg)
  else
    ok(false, msg .. " (got " .. tostring(actual) .. " want " .. tostring(expected) .. ")")
  end
end

-- Assert BOTH nav's tracked pose and the mock's actual pose equal the expected
-- pose. Divergence between them is the desync class of bug this suite exists to
-- catch.
local function poseEq(nav, mock, x, y, z, h, msg)
  local np = nav:getPose()
  local mp = mock:_getPose()
  local navOk = np.x == x and np.y == y and np.z == z and np.h == h
  local mockOk = mp.x == x and mp.y == y and mp.z == z and mp.h == h
  if navOk and mockOk then
    ok(true, msg)
  else
    ok(false, string.format(
      "%s  want (%d,%d,%d,%d)  nav (%d,%d,%d,%d)  mock (%d,%d,%d,%d)",
      msg, x, y, z, h, np.x, np.y, np.z, np.h, mp.x, mp.y, mp.z, mp.h))
  end
end

--------------------------------------------------------------------------------
-- 1. straight_line_forward
--------------------------------------------------------------------------------
local function s01_straight_line_forward()
  local m = Mock.new({ fuel = 100 })
  local nav = Nav.new(m)
  for _ = 1, 3 do assert(nav:forward()) end
  poseEq(nav, m, 0, 0, -3, 0, "s01: forward x3 facing N -> (0,0,-3)")
  eq(m:_getFuel(), 97, "s01: fuel consumed 3")
end

--------------------------------------------------------------------------------
-- 2. all_four_turns_and_wrap
--------------------------------------------------------------------------------
local function s02_all_four_turns_and_wrap()
  local m = Mock.new({ fuel = 100 })
  local nav = Nav.new(m)
  nav:turnRight(); eq(nav:getHeading(), 1, "s02: R 0->1")
  nav:turnRight(); eq(nav:getHeading(), 2, "s02: R 1->2")
  nav:turnRight(); eq(nav:getHeading(), 3, "s02: R 2->3")
  nav:turnRight(); eq(nav:getHeading(), 0, "s02: R 3->0 (wrap)")
  nav:turnLeft(); eq(nav:getHeading(), 3, "s02: L 0->3 (wrap)")
  nav:turnLeft(); eq(nav:getHeading(), 2, "s02: L 3->2")
  nav:turnLeft(); eq(nav:getHeading(), 1, "s02: L 2->1")
  nav:turnLeft(); eq(nav:getHeading(), 0, "s02: L 1->0")
  eq(m:_getPose().h, 0, "s02: mock heading agrees")
end

--------------------------------------------------------------------------------
-- 3. turnTo_minimal_rotation
--------------------------------------------------------------------------------
local function s03_turnTo_minimal_rotation()
  local m = Mock.new({ fuel = 100 })
  -- Count backend turn calls to prove minimal rotation, not just final heading.
  local lc, rc = 0, 0
  local origL, origR = m.turnLeft, m.turnRight
  m.turnLeft = function(...) lc = lc + 1; return origL(...) end
  m.turnRight = function(...) rc = rc + 1; return origR(...) end
  local nav = Nav.new(m)

  nav:turnTo(3)
  eq(nav:getHeading(), 3, "s03: turnTo(3) from 0 -> heading 3")
  eq(lc, 1, "s03: turnTo(3) used one left")
  eq(rc, 0, "s03: turnTo(3) used no rights")

  -- reset to 0, then turnTo(2) should be two turns
  nav:turnTo(0); lc, rc = 0, 0
  nav:turnTo(2)
  eq(nav:getHeading(), 2, "s03: turnTo(2) -> heading 2")
  eq(lc + rc, 2, "s03: turnTo(2) used two turns")

  nav:turnTo(0); lc, rc = 0, 0
  nav:turnTo(0)
  eq(lc + rc, 0, "s03: turnTo(current) is a no-op")
end

--------------------------------------------------------------------------------
-- 4. forward_into_dug_obstruction (+ detect/inspect correctness)
--------------------------------------------------------------------------------
local function s04_forward_into_dug_obstruction()
  local m = Mock.new({ fuel = 100 })
  m:_setBlock(0, 0, -1, "minecraft:stone")
  local nav = Nav.new(m)

  eq(nav:detect(), true, "s04: detect true before dig")
  local present, data = nav:inspect()
  ok(present and data and data.name == "minecraft:stone", "s04: inspect names the block")

  local moved = nav:forward()
  eq(moved, true, "s04: forward succeeds after digging obstruction")
  poseEq(nav, m, 0, 0, -1, 0, "s04: advanced to (0,0,-1)")
  eq(m:_wasDug(0, 0, -1), true, "s04: obstruction was dug")
  eq(nav:detect(), false, "s04: detect false after (air ahead)")
end

--------------------------------------------------------------------------------
-- 5. gravel_column_refill
--------------------------------------------------------------------------------
local function s05_gravel_column_refill()
  local m = Mock.new({ fuel = 100 })
  m:_setGravel(0, 0, -1)
  m:_setGravel(0, 1, -1)
  m:_setGravel(0, 2, -1)
  local nav = Nav.new(m)

  local moved = nav:forward()
  eq(moved, true, "s05: forward eventually advances through refilling gravel")
  poseEq(nav, m, 0, 0, -1, 0, "s05: advanced to (0,0,-1)")
  -- All three gravel blocks in the column had to be dug.
  local digs = 0
  for _, d in ipairs(m:_getDigLog()) do
    if d.x == 0 and d.z == -1 then digs = digs + 1 end
  end
  ok(digs >= 3, "s05: dug the gravel column at least 3 times (got " .. digs .. ")")
end

--------------------------------------------------------------------------------
-- 6. gravel_exceeds_retry_bounded (must terminate, not loop forever)
--------------------------------------------------------------------------------
local function s06_gravel_exceeds_retry_bounded()
  local m = Mock.new({ fuel = 100 })
  for y = 0, 4 do m:_setGravel(0, y, -1) end -- 5 tall, retries capped at 3
  local nav = Nav.new(m, nil, { maxDigRetries = 3 })

  local moved, err = nav:forward()
  eq(moved, false, "s06: forward gives up on an over-tall gravel feed")
  ok(err and err:match("^blocked"), "s06: reports a blocked_* reason (got " .. tostring(err) .. ")")
  poseEq(nav, m, 0, 0, 0, 0, "s06: pose unchanged after giving up")
end

--------------------------------------------------------------------------------
-- 7. fuel_consumption_and_out_of_fuel
--------------------------------------------------------------------------------
local function s07_fuel_consumption_and_out_of_fuel()
  local m = Mock.new({ fuel = 2 })
  local nav = Nav.new(m)
  eq(nav:forward(), true, "s07: move 1 ok")
  eq(nav:forward(), true, "s07: move 2 ok")
  local moved, err = nav:forward()
  eq(moved, false, "s07: move 3 fails (out of fuel)")
  eq(err, "no_fuel", "s07: reason is no_fuel")
  poseEq(nav, m, 0, 0, -2, 0, "s07: stopped after 2 moves")
  eq(nav:getFuelLevel(), 0, "s07: fuel exhausted")
end

--------------------------------------------------------------------------------
-- 8. refuel_from_inventory
--------------------------------------------------------------------------------
local function s08_refuel_from_inventory()
  local m = Mock.new({ fuel = 0 })
  m:_addItem(1, "minecraft:coal", 1, 80) -- slot 1 selected by default
  local nav = Nav.new(m)

  eq(nav:getFuelLevel(), 0, "s08: starts empty")
  local rok, level = nav:refuel()
  eq(rok, true, "s08: refuel succeeds")
  eq(level, 80, "s08: fuel raised to 80")
  eq(nav:forward(), true, "s08: can move after refuelling")
  poseEq(nav, m, 0, 0, -1, 0, "s08: advanced one block")
end

--------------------------------------------------------------------------------
-- 9. bedrock_unbreakable_blocks_move
--------------------------------------------------------------------------------
local function s09_bedrock_unbreakable_blocks_move()
  local m = Mock.new({ fuel = 100, floorY = -1 })
  m:_setBedrock(0, 0, -1)
  local nav = Nav.new(m)

  local dok = nav:dig()
  eq(dok, false, "s09: cannot dig bedrock")

  local moved, err = nav:forward()
  eq(moved, false, "s09: forward blocked by bedrock")
  eq(err, "blocked_unbreakable", "s09: reason is blocked_unbreakable")
  eq(#m:_getDigLog(), 0, "s09: nothing was dug (gave up immediately)")
  poseEq(nav, m, 0, 0, 0, 0, "s09: pose unchanged vs bedrock ahead")

  -- Bedrock floor: down() must fail gracefully too.
  local dmoved, derr = nav:down()
  eq(dmoved, false, "s09: down blocked by bedrock floor")
  eq(derr, "blocked_unbreakable", "s09: down reason is blocked_unbreakable")
  poseEq(nav, m, 0, 0, 0, 0, "s09: still at origin after blocked down")
end

--------------------------------------------------------------------------------
-- 10. updown_y_tracking (+ digUp then ascend)
--------------------------------------------------------------------------------
local function s10_updown_y_tracking()
  local m = Mock.new({ fuel = 100 })
  local nav = Nav.new(m)
  assert(nav:up()); assert(nav:up()); assert(nav:down())
  poseEq(nav, m, 0, 1, 0, 0, "s10: y tracks 0->1->2->1 leaves x/z/h unchanged")
  eq(select(2, nav:getPos()), 1, "s10: final y is 1")

  -- dig-up then ascend through a block above.
  local m2 = Mock.new({ fuel = 100 })
  m2:_setBlock(0, 1, 0, "minecraft:dirt")
  local nav2 = Nav.new(m2)
  eq(nav2:up(), true, "s10: up digs the block above and ascends")
  poseEq(nav2, m2, 0, 1, 0, 0, "s10: reached (0,1,0)")
  eq(m2:_wasDug(0, 1, 0), true, "s10: block above was dug")
end

--------------------------------------------------------------------------------
-- 11. goTo_multi_axis
--------------------------------------------------------------------------------
local function s11_goTo_multi_axis()
  local m = Mock.new({ fuel = 100 })
  local nav = Nav.new(m)
  local gok = nav:goTo(2, -1, 3)
  eq(gok, true, "s11: goTo(2,-1,3) succeeds")
  poseEq(nav, m, 2, -1, 3, 2, "s11: arrived at (2,-1,3) facing S (last axis +Z)")
end

--------------------------------------------------------------------------------
-- 12. multi_leg_return_to_origin (the core convention guard)
--------------------------------------------------------------------------------
local function s12_multi_leg_return_to_origin()
  local m = Mock.new({ fuel = 200 })
  -- Blocks along the outbound path to force digs + turns.
  m:_setBlock(0, 0, -1, "minecraft:stone")
  m:_setBlock(0, 0, -2, "minecraft:stone")
  m:_setBlock(0, 0, -3, "minecraft:stone")
  m:_setBlock(1, 0, -3, "minecraft:stone")
  m:_setBlock(2, 0, -3, "minecraft:stone")
  m:_setBlock(2, 1, -3, "minecraft:stone")
  local nav = Nav.new(m)

  -- Outbound: N x3, turn east, x2, up 1.
  assert(nav:forward()); assert(nav:forward()); assert(nav:forward())
  nav:turnRight()
  assert(nav:forward()); assert(nav:forward())
  assert(nav:up())
  poseEq(nav, m, 2, 1, -3, 1, "s12: outbound ends at (2,1,-3) facing E")

  -- Return home and face original heading.
  local rok = nav:returnTo({ x = 0, y = 0, z = 0, h = 0 })
  eq(rok, true, "s12: returnTo origin succeeds")
  poseEq(nav, m, 0, 0, 0, 0, "s12: closed exactly on origin+heading (sim==convention)")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_straight_line_forward,
  s02_all_four_turns_and_wrap,
  s03_turnTo_minimal_rotation,
  s04_forward_into_dug_obstruction,
  s05_gravel_column_refill,
  s06_gravel_exceeds_retry_bounded,
  s07_fuel_consumption_and_out_of_fuel,
  s08_refuel_from_inventory,
  s09_bedrock_unbreakable_blocks_move,
  s10_updown_y_tracking,
  s11_goTo_multi_axis,
  s12_multi_leg_return_to_origin,
}

-- Run each scenario and count at the SCENARIO level (a scenario passes only if
-- all its assertions pass, and it didn't error out). Assertion-level FAIL lines
-- are still printed above for detail. This makes the summary read "12 passed,
-- 0 failed" as the docs promise.
local scPassed, scFailed = 0, 0
for i, scenario in ipairs(scenarios) do
  local before = failed
  local runOk, err = pcall(scenario)
  if runOk and failed == before then
    scPassed = scPassed + 1
  else
    scFailed = scFailed + 1
    if not runOk then
      print("  ERROR in scenario " .. i .. ": " .. tostring(err))
    end
  end
end

print(scPassed .. " passed, " .. scFailed .. " failed")
-- os.exit exists under desktop Lua (sets the process exit code for CI) but NOT
-- under CC:Tweaked's `os` table, so guard it — otherwise the suite crashes
-- in-game / in CraftOS-PC right after printing the summary.
if os.exit then os.exit(scFailed == 0 and 0 or 1) end
