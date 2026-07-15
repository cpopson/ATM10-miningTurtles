-- test_quarry.lua — scenario suite driving quarry.lua against mockturtle via
-- nav. Runs under plain `lua`; prints "N passed, M failed" and (on desktop)
-- exits non-zero on failure. Mirrors test_nav.lua's harness style.
--
-- Run:  lua test_quarry.lua

local Nav = require("nav")
local Mock = require("mockturtle")
local Quarry = require("quarry")

local passed, failed = 0, 0

local function ok(cond, msg)
  if cond then
    passed = passed + 1
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

-- Assert BOTH nav's tracked pose and the mock's actual pose equal expected.
local function poseEq(nav, mock, x, y, z, h, msg)
  local np, mp = nav:getPose(), mock:_getPose()
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

-- Build a mock + nav sharing a start pose. fuel nil -> unlimited.
local function setup(startPose, fuel)
  startPose = startPose or { x = 0, y = 1, z = 0, h = 0 }
  local m = Mock.new({ pose = startPose, fuel = fuel })
  local nav = Nav.new(m, startPose)
  return m, nav
end

-- Assert every cell of the box (start at sx,sy,sz; W x L x D) was dug and is air.
-- Box = x in [sx,sx+W-1], z in [sz,sz+L-1], y in [sy-D, sy-1].
local function assertBoxCleared(m, sx, sy, sz, W, L, D, tag)
  local allDug, allAir = true, true
  for x = sx, sx + W - 1 do
    for z = sz, sz + L - 1 do
      for y = sy - D, sy - 1 do
        if not m:_wasDug(x, y, z) then allDug = false end
        if m:_blockAt(x, y, z) ~= nil then allAir = false end
      end
    end
  end
  ok(allDug, tag .. ": every box cell was dug")
  ok(allAir, tag .. ": every box cell is now air")
end

-- Fill a solid box relative to a start-above pose (sx,sy,sz) covering the W×L×D
-- box the quarry will clear (y in [sy-D, sy-1]).
local function fillSolidBox(m, sx, sy, sz, W, L, D, name)
  m:_fillBox(sx, sy - D, sz, sx + W - 1, sy - 1, sz + L - 1, name or "minecraft:stone")
end

--------------------------------------------------------------------------------
-- 1. full coverage of a 3x3x2 box
--------------------------------------------------------------------------------
local function s01_full_coverage_3x3x2()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillSolidBox(m, 0, 1, 0, 3, 3, 2)

  local q = Quarry.new(nav)
  local success, stats = q:run({ width = 3, length = 3, depth = 2 })
  eq(success, true, "s01: run succeeds")
  eq(stats.layersDone, 2, "s01: both layers done")
  eq(stats.cellsCleared, 18, "s01: cellsCleared == W*L*D (18)")
  assertBoxCleared(m, 0, 1, 0, 3, 3, 2, "s01")
  eq(m:_wasDug(0, 1, 0), false, "s01: start cell (air entry) not dug")
  eq(m:_wasDug(-1, 0, 0), false, "s01: out-of-box cell not dug")
  poseEq(nav, m, 0, 1, 0, 0, "s01: returned to start pose")
end

--------------------------------------------------------------------------------
-- 2. returns to start pose (non-zero start heading restored)
--------------------------------------------------------------------------------
local function s02_returns_to_start_pose()
  local start = { x = 0, y = 1, z = 0, h = 1 } -- facing East
  local m, nav = setup(start)
  fillSolidBox(m, 0, 1, 0, 2, 4, 3)

  local q = Quarry.new(nav)
  local success = q:run({ width = 2, length = 4, depth = 3 })
  eq(success, true, "s02: run succeeds")
  assertBoxCleared(m, 0, 1, 0, 2, 4, 3, "s02")
  poseEq(nav, m, 0, 1, 0, 1, "s02: round trip closes with heading restored")
end

--------------------------------------------------------------------------------
-- 3. single row 1xN
--------------------------------------------------------------------------------
local function s03_single_row_1xN()
  local m, nav = setup()
  fillSolidBox(m, 0, 1, 0, 1, 5, 2)
  local success, stats = Quarry.new(nav):run({ width = 1, length = 5, depth = 2 })
  eq(success, true, "s03: run succeeds")
  eq(stats.cellsCleared, 10, "s03: cellsCleared == 10")
  assertBoxCleared(m, 0, 1, 0, 1, 5, 2, "s03")
  poseEq(nav, m, 0, 1, 0, 0, "s03: closed loop")
end

--------------------------------------------------------------------------------
-- 4. single column Nx1
--------------------------------------------------------------------------------
local function s04_single_column_Nx1()
  local m, nav = setup()
  fillSolidBox(m, 0, 1, 0, 5, 1, 2)
  local success, stats = Quarry.new(nav):run({ width = 5, length = 1, depth = 2 })
  eq(success, true, "s04: run succeeds")
  eq(stats.cellsCleared, 10, "s04: cellsCleared == 10")
  assertBoxCleared(m, 0, 1, 0, 5, 1, 2, "s04")
  poseEq(nav, m, 0, 1, 0, 0, "s04: closed loop")
end

--------------------------------------------------------------------------------
-- 5. single block 1x1x1
--------------------------------------------------------------------------------
local function s05_single_block_1x1x1()
  local m, nav = setup()
  m:_setBlock(0, 0, 0, "minecraft:stone")
  local success, stats = Quarry.new(nav):run({ width = 1, length = 1, depth = 1 })
  eq(success, true, "s05: run succeeds")
  eq(stats.cellsCleared, 1, "s05: cellsCleared == 1")
  eq(m:_wasDug(0, 0, 0), true, "s05: the single cell was dug")
  poseEq(nav, m, 0, 1, 0, 0, "s05: closed loop")
end

--------------------------------------------------------------------------------
-- 6. vertical shaft 1x1xN
--------------------------------------------------------------------------------
local function s06_vertical_shaft_1x1xN()
  local m, nav = setup()
  fillSolidBox(m, 0, 1, 0, 1, 1, 4)
  local success, stats = Quarry.new(nav):run({ width = 1, length = 1, depth = 4 })
  eq(success, true, "s06: run succeeds")
  eq(stats.cellsCleared, 4, "s06: cellsCleared == 4")
  assertBoxCleared(m, 0, 1, 0, 1, 1, 4, "s06")
  eq(m:_wasDug(1, 0, 0), false, "s06: adjacent column untouched")
  poseEq(nav, m, 0, 1, 0, 0, "s06: closed loop")
end

--------------------------------------------------------------------------------
-- 7. fuel exhaustion mid-quarry: aborts cleanly, does not hang
--------------------------------------------------------------------------------
local function s07_fuel_exhaustion_partial()
  local m, nav = setup({ x = 0, y = 1, z = 0, h = 0 }, 8)
  fillSolidBox(m, 0, 1, 0, 3, 3, 3)
  local success, err, stats = Quarry.new(nav):run({ width = 3, length = 3, depth = 3 })
  eq(success, false, "s07: run aborts")
  eq(err, "no_fuel", "s07: reason is no_fuel")
  ok(stats.layersDone < 3, "s07: did not finish all layers")
  ok(stats.cellsCleared > 0, "s07: made partial progress")
  local p = nav:getPose()
  ok(not (p.x == 0 and p.y == 1 and p.z == 0), "s07: stalled away from start (no auto-return)")
end

--------------------------------------------------------------------------------
-- 8. bedrock floor stops the descent cleanly
--------------------------------------------------------------------------------
local function s08_bedrock_floor_stops()
  local m, nav = setup()
  -- Box would be y in [-2,0]; make the bottom layer (y=-2) unbreakable floor.
  fillSolidBox(m, 0, 1, 0, 3, 3, 2)   -- stone at y = -1 and y = 0 only
  m:_setBedrockPlane(-2)              -- y <= -2 is bedrock
  local success, err, stats = Quarry.new(nav):run({ width = 3, length = 3, depth = 3 })
  eq(success, false, "s08: run aborts at bedrock")
  eq(err, "blocked_unbreakable", "s08: reason is blocked_unbreakable")
  eq(stats.layersDone, 2, "s08: cleared 2 layers before the floor")
  assertBoxCleared(m, 0, 1, 0, 3, 3, 2, "s08") -- y = 0 and y = -1 fully cleared
  local hitBedrock = false
  for _, d in ipairs(m:_getDigLog()) do
    if d.name == "minecraft:bedrock" then hitBedrock = true end
  end
  ok(not hitBedrock, "s08: never dug bedrock")
end

--------------------------------------------------------------------------------
-- 9. gravel inside the box: nav auto-dig retry still yields full coverage
--------------------------------------------------------------------------------
local function s09_gravel_inside_box()
  local m, nav = setup()
  fillSolidBox(m, 0, 1, 0, 3, 3, 2)
  -- Replace one interior box cell with gravel and stack a gravel column above
  -- it, so digging that cell triggers repeated refill.
  m:_setGravel(1, 0, 1)
  m:_setGravel(1, 1, 1)
  m:_setGravel(1, 2, 1)
  local success, stats = Quarry.new(nav):run({ width = 3, length = 3, depth = 2 })
  eq(success, true, "s09: run succeeds through gravel")
  eq(stats.cellsCleared, 18, "s09: cellsCleared unchanged (moves, not digs)")
  assertBoxCleared(m, 0, 1, 0, 3, 3, 2, "s09")
  ok(#m:_getDigLog() > 18, "s09: dig log exceeds move count (gravel refill)")
  poseEq(nav, m, 0, 1, 0, 0, "s09: closed loop")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_full_coverage_3x3x2,
  s02_returns_to_start_pose,
  s03_single_row_1xN,
  s04_single_column_Nx1,
  s05_single_block_1x1x1,
  s06_vertical_shaft_1x1xN,
  s07_fuel_exhaustion_partial,
  s08_bedrock_floor_stops,
  s09_gravel_inside_box,
}

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
if os.exit then os.exit(scFailed == 0 and 0 or 1) end
