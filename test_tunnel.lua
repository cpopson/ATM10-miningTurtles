-- test_tunnel.lua — scenario suite driving tunnel.lua against mockturtle via
-- nav. Runs under plain `lua`; prints "N passed, M failed" and (on desktop)
-- exits non-zero on failure. Mirrors test_quarry.lua's harness style.
--
-- Run:  lua test_tunnel.lua

local Nav = require("nav")
local Mock = require("mockturtle")
local Tunnel = require("tunnel")

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

--------------------------------------------------------------------------------
-- Tunnel-specific helpers: corridor cells are relative to the start FACING, so
-- we project (l,w,u) back to world coords the same way tunnel.lua does.
--------------------------------------------------------------------------------
local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

-- worldOf(S,l,w,u) -> x,y,z  (l forward, w right, u up from the mouth pose S)
local function worldOf(S, l, w, u)
  local Fx, Fz = DX[S.h], DZ[S.h]
  local Rx, Rz = DX[(S.h + 1) % 4], DZ[(S.h + 1) % 4]
  return S.x + l * Fx + w * Rx, S.y + u, S.z + l * Fz + w * Rz
end

-- Fill the W×L×H corridor solid EXCEPT the mouth cell (0,0,0), so the turtle
-- digs every cell it enters.
local function fillCorridor(m, S, W, L, H, name)
  name = name or "minecraft:stone"
  for l = 0, L - 1 do
    for w = 0, W - 1 do
      for u = 0, H - 1 do
        if not (l == 0 and w == 0 and u == 0) then
          local x, y, z = worldOf(S, l, w, u)
          m:_setBlock(x, y, z, name)
        end
      end
    end
  end
end

-- Assert every corridor cell (except the mouth) was dug and every cell is air.
local function assertCorridorCleared(m, S, W, L, H, tag)
  local allDug, allAir = true, true
  for l = 0, L - 1 do
    for w = 0, W - 1 do
      for u = 0, H - 1 do
        local x, y, z = worldOf(S, l, w, u)
        if not (l == 0 and w == 0 and u == 0) then
          if not m:_wasDug(x, y, z) then allDug = false end
        end
        if m:_blockAt(x, y, z) ~= nil then allAir = false end
      end
    end
  end
  ok(allDug, tag .. ": every corridor cell (except mouth) was dug")
  ok(allAir, tag .. ": every corridor cell is now air")
end

--------------------------------------------------------------------------------
-- 1. full coverage of a 3x3x2 corridor
--------------------------------------------------------------------------------
local function s01_full_coverage_3x3x2()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 3, 3, 2)

  local success, stats = Tunnel.new(nav):run({ width = 3, length = 3, depth = 2 })
  eq(success, true, "s01: run succeeds")
  eq(stats.levelsDone, 2, "s01: both height levels done")
  eq(stats.cellsCleared, 17, "s01: cellsCleared == W*L*H-1 (17, mouth not counted)")
  assertCorridorCleared(m, start, 3, 3, 2, "s01")
  eq(m:_wasDug(0, 1, 0), false, "s01: mouth cell (entry) not dug")
  poseEq(nav, m, 0, 1, 0, 0, "s01: returned to start pose")
end

--------------------------------------------------------------------------------
-- 2. returns to start pose with a non-zero start heading (projection under rotation)
--------------------------------------------------------------------------------
local function s02_returns_to_start_nonzero_heading()
  local start = { x = 0, y = 1, z = 0, h = 1 } -- facing East
  local m, nav = setup(start)
  fillCorridor(m, start, 2, 4, 3)

  local success = Tunnel.new(nav):run({ width = 2, length = 4, depth = 3 })
  eq(success, true, "s02: run succeeds")
  assertCorridorCleared(m, start, 2, 4, 3, "s02")
  poseEq(nav, m, 0, 1, 0, 1, "s02: round trip closes with heading restored")
end

--------------------------------------------------------------------------------
-- 3. one-wide corridor 1xLxH
--------------------------------------------------------------------------------
local function s03_one_wide_corridor()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 1, 5, 2)
  local success, stats = Tunnel.new(nav):run({ width = 1, length = 5, depth = 2 })
  eq(success, true, "s03: run succeeds")
  eq(stats.cellsCleared, 9, "s03: cellsCleared == 9")
  assertCorridorCleared(m, start, 1, 5, 2, "s03")
  poseEq(nav, m, 0, 1, 0, 0, "s03: closed loop")
end

--------------------------------------------------------------------------------
-- 4. tall corridor WxLx4
--------------------------------------------------------------------------------
local function s04_tall_corridor()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 2, 2, 4)
  local success, stats = Tunnel.new(nav):run({ width = 2, length = 2, depth = 4 })
  eq(success, true, "s04: run succeeds")
  eq(stats.cellsCleared, 15, "s04: cellsCleared == 15")
  eq(stats.levelsDone, 4, "s04: all four levels done")
  assertCorridorCleared(m, start, 2, 2, 4, "s04")
  poseEq(nav, m, 0, 1, 0, 0, "s04: closed loop")
end

--------------------------------------------------------------------------------
-- 5. single block 1x1x1 (mouth only: nothing to dig)
--------------------------------------------------------------------------------
local function s05_single_block_1x1x1()
  local m, nav = setup()
  local success, stats = Tunnel.new(nav):run({ width = 1, length = 1, depth = 1 })
  eq(success, true, "s05: run succeeds")
  eq(stats.cellsCleared, 0, "s05: cellsCleared == 0 (only the mouth)")
  eq(stats.levelsDone, 1, "s05: one level done")
  eq(#m:_getDigLog(), 0, "s05: nothing dug")
  poseEq(nav, m, 0, 1, 0, 0, "s05: closed loop")
end

--------------------------------------------------------------------------------
-- 6. vertical shaft 1x1x4 (height only)
--------------------------------------------------------------------------------
local function s06_vertical_shaft_1x1x4()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 1, 1, 4)
  local success, stats = Tunnel.new(nav):run({ width = 1, length = 1, depth = 4 })
  eq(success, true, "s06: run succeeds")
  eq(stats.cellsCleared, 3, "s06: cellsCleared == 3")
  assertCorridorCleared(m, start, 1, 1, 4, "s06")
  local ax, ay, az = worldOf(start, 0, 1, 0) -- the cell to the right of the shaft
  eq(m:_wasDug(ax, ay, az), false, "s06: adjacent column untouched")
  poseEq(nav, m, 0, 1, 0, 0, "s06: closed loop")
end

--------------------------------------------------------------------------------
-- 7. fuel exhaustion mid-tunnel: aborts cleanly, no auto-return
--------------------------------------------------------------------------------
local function s07_fuel_exhaustion_partial()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start, 8)
  fillCorridor(m, start, 3, 3, 3)
  local success, err, stats = Tunnel.new(nav):run({ width = 3, length = 3, depth = 3 })
  eq(success, false, "s07: run aborts")
  eq(err, "no_fuel", "s07: reason is no_fuel")
  ok(stats.levelsDone < 3, "s07: did not finish all levels")
  ok(stats.cellsCleared > 0, "s07: made partial progress")
  local p = nav:getPose()
  ok(not (p.x == 0 and p.y == 1 and p.z == 0), "s07: stalled away from start (no auto-return)")
end

--------------------------------------------------------------------------------
-- 8. unbreakable block ahead stops the dig cleanly
--------------------------------------------------------------------------------
local function s08_bedrock_ahead()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 1, 5, 1)
  local bx, by, bz = worldOf(start, 3, 0, 0) -- bedrock 3 cells down the corridor
  m:_setBedrock(bx, by, bz)
  local success, err, stats = Tunnel.new(nav):run({ width = 1, length = 5, depth = 1 })
  eq(success, false, "s08: run aborts at the unbreakable block")
  eq(err, "blocked_unbreakable", "s08: reason is blocked_unbreakable")
  eq(stats.cellsCleared, 2, "s08: cleared 2 cells before the block")
  eq(stats.levelsDone, 0, "s08: level not marked done (sweep interrupted)")
  local hitBedrock = false
  for _, d in ipairs(m:_getDigLog()) do
    if d.name == "minecraft:bedrock" then hitBedrock = true end
  end
  ok(not hitBedrock, "s08: never dug bedrock")
end

--------------------------------------------------------------------------------
-- 9. gravel above the corridor: nav auto-dig retry still yields full coverage
--------------------------------------------------------------------------------
local function s09_gravel_coverage()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 3, 3, 2)
  -- Gravel stacked directly ABOVE the top corridor cell of an interior column;
  -- it falls in only when that top cell is dug (the last level), so coverage is
  -- unaffected but digging it triggers repeated refill.
  local gx, gy, gz = worldOf(start, 1, 1, 2) -- one cell above the u=1 top cell
  m:_setGravel(gx, gy, gz)
  m:_setGravel(gx, gy + 1, gz)
  local success, stats = Tunnel.new(nav):run({ width = 3, length = 3, depth = 2 })
  eq(success, true, "s09: run succeeds through gravel")
  eq(stats.cellsCleared, 17, "s09: cellsCleared unchanged (moves, not digs)")
  assertCorridorCleared(m, start, 3, 3, 2, "s09")
  ok(#m:_getDigLog() > 17, "s09: dig log exceeds move count (gravel refill)")
  poseEq(nav, m, 0, 1, 0, 0, "s09: closed loop")
end

--------------------------------------------------------------------------------
-- 10. ender-chest auto-dump: loot fills, dump in place, resume, full clear
--------------------------------------------------------------------------------
local function s10_ender_dump_and_resume()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 3, 3, 2)
  for s = 1, 14 do m:_addItem(s, "minecraft:cobblestone", 64) end
  m:_addItem(15, "minecraft:stone", 63)
  m:_addEnderChest(16)

  local success, stats = Tunnel.new(nav, { chestSlot = 16 }):run({ width = 3, length = 3, depth = 2 })
  eq(success, true, "s10: run succeeds with ender-chest dumping")
  ok(stats.dumps >= 1, "s10: at least one dump happened")
  assertCorridorCleared(m, start, 3, 3, 2, "s10")
  ok(m:_enderTotal() > 0, "s10: loot was deposited into the ender network")
  local chest = m.getItemDetail(16) -- dot-call: bound turtle-API fn
  ok(chest ~= nil and chest.name:find("ender") ~= nil, "s10: ender chest still reserved in slot 16")
  poseEq(nav, m, 0, 1, 0, 0, "s10: closed loop after dumping")
end

--------------------------------------------------------------------------------
-- 11. no ender chest -> no dumping
--------------------------------------------------------------------------------
local function s11_no_chest_no_dump()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 2, 2, 2)
  local success, stats = Tunnel.new(nav):run({ width = 2, length = 2, depth = 2 })
  eq(success, true, "s11: run succeeds without a chest")
  eq(stats.dumps, 0, "s11: no dumps when no ender chest present")
  eq(m:_enderTotal(), 0, "s11: nothing deposited")
  assertCorridorCleared(m, start, 2, 2, 2, "s11")
end

--------------------------------------------------------------------------------
-- 12. floor-fill over a gap: patches the hole under the corridor, once
--------------------------------------------------------------------------------
local function s12_floor_fill_over_gap()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 1, 4, 1)
  -- Solid dirt floor one below the corridor, EXCEPT a gap under cell l=2.
  for l = 0, 3 do
    local fx, fy, fz = worldOf(start, l, 0, 0)
    if l ~= 2 then m:_setBlock(fx, fy - 1, fz, "minecraft:dirt") end
  end
  m:_addItem(14, "minecraft:cobblestone", 64)

  local success, stats = Tunnel.new(nav, { fill = true, fillerSlot = 14 }):run(
    { width = 1, length = 4, depth = 1 })
  eq(success, true, "s12: run succeeds")
  ok(stats.fills >= 1, "s12: at least one floor gap filled")
  local gx, gy, gz = worldOf(start, 2, 0, 0)
  local gap = m:_blockAt(gx, gy - 1, gz)
  ok(gap ~= nil and gap.name == "minecraft:cobblestone", "s12: gap under l=2 filled with cobblestone")
  local dx2, dy2, dz2 = worldOf(start, 1, 0, 0)
  local solid = m:_blockAt(dx2, dy2 - 1, dz2)
  ok(solid ~= nil and solid.name == "minecraft:dirt", "s12: already-solid floor not overwritten")
  assertCorridorCleared(m, start, 1, 4, 1, "s12")
  poseEq(nav, m, 0, 1, 0, 0, "s12: closed loop")
end

--------------------------------------------------------------------------------
-- 13. torches at intervals, and they survive the return trip
--------------------------------------------------------------------------------
local function s13_torch_intervals_and_survive_return()
  local start = { x = 0, y = 1, z = 0, h = 1 } -- facing East
  local m, nav = setup(start)
  fillCorridor(m, start, 1, 6, 2)
  m:_addItem(15, "minecraft:torch", 64)

  local success, stats = Tunnel.new(nav, { torchSlot = 15, torchEvery = 2 }):run(
    { width = 1, length = 6, depth = 2 })
  eq(success, true, "s13: run succeeds")
  eq(stats.torches, 2, "s13: two torches placed (l=2,4)")
  for _, l in ipairs({ 2, 4 }) do
    local tx, ty, tz = worldOf(start, l, 0, 0)
    local b = m:_blockAt(tx, ty, tz)
    ok(b ~= nil and b.name == "minecraft:torch",
      "s13: torch present at l=" .. l .. " (survived the return)")
  end
  for _, l in ipairs({ 1, 3, 5 }) do
    local ex, ey, ez = worldOf(start, l, 0, 0)
    eq(m:_blockAt(ex, ey, ez), nil, "s13: no torch at l=" .. l)
  end
  poseEq(nav, m, 0, 1, 0, 1, "s13: closed loop with heading restored")
end

--------------------------------------------------------------------------------
-- 14. a 1-tall tunnel has no u=1 level, so torches are skipped
--------------------------------------------------------------------------------
local function s14_H1_skips_torches()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 2, 4, 1)
  m:_addItem(15, "minecraft:torch", 64)
  local success, stats = Tunnel.new(nav, { torchSlot = 15, torchEvery = 2 }):run(
    { width = 2, length = 4, depth = 1 })
  eq(success, true, "s14: run succeeds")
  eq(stats.torches, 0, "s14: no torches on a 1-tall tunnel")
  assertCorridorCleared(m, start, 2, 4, 1, "s14") -- all air => no stray torch
  poseEq(nav, m, 0, 1, 0, 0, "s14: closed loop")
end

--------------------------------------------------------------------------------
-- 15. onProgress hook can abort the tunnel (worker uses this for CONTROL stop)
--------------------------------------------------------------------------------
local function s15_onprogress_abort()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCorridor(m, start, 3, 3, 2)
  local calls = 0
  local success, err, stats = Tunnel.new(nav, {
    onProgress = function(info)
      calls = calls + 1
      if info.cells >= 5 then return false end
      return true
    end,
  }):run({ width = 3, length = 3, depth = 2 })
  eq(success, false, "s15: run aborts on onProgress false")
  eq(err, "aborted", "s15: reason is aborted")
  eq(stats.cellsCleared, 5, "s15: stopped at the abort cell")
  eq(calls, 5, "s15: hook called once per move up to the abort")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_full_coverage_3x3x2,
  s02_returns_to_start_nonzero_heading,
  s03_one_wide_corridor,
  s04_tall_corridor,
  s05_single_block_1x1x1,
  s06_vertical_shaft_1x1x4,
  s07_fuel_exhaustion_partial,
  s08_bedrock_ahead,
  s09_gravel_coverage,
  s10_ender_dump_and_resume,
  s11_no_chest_no_dump,
  s12_floor_fill_over_gap,
  s13_torch_intervals_and_survive_return,
  s14_H1_skips_torches,
  s15_onprogress_abort,
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
