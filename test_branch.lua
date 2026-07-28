-- test_branch.lua — scenario suite driving branch.lua against mockturtle via
-- nav. Runs under plain `lua`; prints "N passed, M failed" and (on desktop)
-- exits non-zero on failure. Mirrors test_tunnel.lua's harness style.
--
-- Run:  lua test_branch.lua

local Nav = require("nav")
local Mock = require("mockturtle")
local Branch = require("branch")

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
local function setup(startPose, fuel, cfg)
  startPose = startPose or { x = 0, y = 1, z = 0, h = 0 }
  cfg = cfg or {}
  cfg.pose, cfg.fuel = startPose, fuel
  local m = Mock.new(cfg)
  local nav = Nav.new(m, startPose)
  return m, nav
end

--------------------------------------------------------------------------------
-- Branch-specific oracle. Everything below is derived from the SPEC ALONE, never
-- from branch.lua, so the suite is a real oracle rather than a mirror of the
-- implementation (same reason test_tunnel.lua re-derives its own projection).
--------------------------------------------------------------------------------
local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

-- worldOf(S,l,w,u) -> x,y,z  (l forward, w right, u up from the mouth pose S)
local function worldOf(S, l, w, u)
  local Fx, Fz = DX[S.h], DZ[S.h]
  local Rx, Rz = DX[(S.h + 1) % 4], DZ[(S.h + 1) % 4]
  return S.x + l * Fx + w * Rx, S.y + u, S.z + l * Fz + w * Rz
end

-- Spine cells l = k*SP that carry a rib pair. k starts at 1, so the mouth never
-- gets ribs, and k*SP must stay inside the spine.
local function mouthsOf(SL, R, SP)
  local ms = {}
  if R > 0 then
    local k = 1
    while k * SP <= SL - 1 do
      ms[#ms + 1] = k * SP
      k = k + 1
    end
  end
  return ms
end

-- planCells -> spineCells, ribCells, mouths   (each cell = {l=,w=,u=})
local function planCells(SL, R, SP, H)
  local spine, ribs = {}, {}
  for l = 0, SL - 1 do
    for u = 0, H - 1 do
      spine[#spine + 1] = { l = l, w = 0, u = u }
    end
  end
  local ms = mouthsOf(SL, R, SP)
  for _, l in ipairs(ms) do
    for _, sgn in ipairs({ 1, -1 }) do
      for w = 1, R do
        for u = 0, H - 1 do
          ribs[#ribs + 1] = { l = l, w = sgn * w, u = u }
        end
      end
    end
  end
  return spine, ribs, ms
end

-- Corridor MOVES (not distinct cells): the spine sweep is SL*H-1, and each rib
-- is (R+1)*H-1 because its own mouth is the spine cell it starts from.
local function expectedCells(SL, R, SP, H)
  local n = #mouthsOf(SL, R, SP)
  return (SL * H - 1) + 2 * n * ((R + 1) * H - 1)
end

-- Fill a solid (l,w,u) box EXCEPT the spine mouth, so the turtle digs every cell
-- it enters and any stray move shows up as an unexpected dig.
local function fillRegion(m, S, l0, l1, w0, w1, u0, u1, name, props)
  name = name or "minecraft:stone"
  for l = l0, l1 do
    for w = w0, w1 do
      for u = u0, u1 do
        if not (l == 0 and w == 0 and u == 0) then
          local x, y, z = worldOf(S, l, w, u)
          m:_setBlock(x, y, z, name, props)
        end
      end
    end
  end
end

local function fillCells(m, S, cells, name, props)
  name = name or "minecraft:stone"
  for _, c in ipairs(cells) do
    if not (c.l == 0 and c.w == 0 and c.u == 0) then
      local x, y, z = worldOf(S, c.l, c.w, c.u)
      m:_setBlock(x, y, z, name, props)
    end
  end
end

local function assertCleared(m, S, cells, tag)
  local allDug, allAir = true, true
  for _, c in ipairs(cells) do
    local x, y, z = worldOf(S, c.l, c.w, c.u)
    if not (c.l == 0 and c.w == 0 and c.u == 0) then
      if not m:_wasDug(x, y, z) then allDug = false end
    end
    if m:_blockAt(x, y, z) ~= nil then allAir = false end
  end
  ok(allDug, tag .. ": every planned cell (except mouth) was dug")
  ok(allAir, tag .. ": every planned cell is now air")
end

local function assertUntouched(m, S, cells, tag)
  local clean = true
  for _, c in ipairs(cells) do
    local x, y, z = worldOf(S, c.l, c.w, c.u)
    if m:_wasDug(x, y, z) then clean = false end
  end
  ok(clean, tag .. ": off-plan cells untouched")
end

local function oreProps()
  return { tags = { ["c:ores"] = true } }
end

-- The L-shaped 5-block vein used by several scenarios, hanging off the RIGHT
-- wall of spine cell l=2, entirely outside a 1-wide x 2-high corridor.
local VEIN_L = {
  { l = 2, w = 1, u = 0 }, { l = 2, w = 2, u = 0 }, { l = 2, w = 2, u = 1 },
  { l = 2, w = 3, u = 1 }, { l = 2, w = 3, u = 0 },
}

--------------------------------------------------------------------------------
-- 1. spine + both rib pairs, full coverage, ribs only at multiples of spacing
--------------------------------------------------------------------------------
local function s01_spine_and_ribs_coverage()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillRegion(m, start, 0, 6, -3, 3, 0, 1)
  local spine, ribs, mouths = planCells(7, 2, 3, 2)

  local success, stats = Branch.new(nav):run(
    { length = 7, ribReach = 2, spacing = 3, height = 2 })
  eq(success, true, "s01: run succeeds")
  eq(#mouths, 2, "s01: oracle says two rib mouths (l=3,6)")
  eq(stats.ribPairs, 2, "s01: ribPairs == 2")
  eq(stats.ribsDone, 4, "s01: four ribs cut")
  eq(stats.subRuns, 5, "s01: subRuns == 1 spine + 4 ribs")
  eq(stats.cellsCleared, expectedCells(7, 2, 3, 2), "s01: cellsCleared == 33")
  eq(stats.cellsCleared, 33, "s01: cellsCleared literal == 33")
  eq(stats.spineDone, true, "s01: spine marked done")
  assertCleared(m, start, spine, "s01 spine")
  assertCleared(m, start, ribs, "s01 ribs")
  eq(m:_wasDug(worldOf(start, 0, 0, 0)), false, "s01: mouth cell (entry) not dug")
  assertUntouched(m, start, {
    { l = 1, w = 1, u = 0 }, { l = 2, w = -1, u = 0 },
    { l = 4, w = 1, u = 0 }, { l = 5, w = -1, u = 0 },
  }, "s01")
  poseEq(nav, m, 0, 1, 0, 0, "s01: returned to start pose")
end

--------------------------------------------------------------------------------
-- 2. non-zero start heading: projection and rib sides rotate with it
--------------------------------------------------------------------------------
local function s02_nonzero_start_heading()
  local start = { x = 0, y = 1, z = 0, h = 1 } -- facing East (+X)
  local m, nav = setup(start)
  fillRegion(m, start, 0, 6, -3, 3, 0, 1)
  local spine, ribs = planCells(7, 2, 3, 2)

  local success, stats = Branch.new(nav):run(
    { length = 7, ribReach = 2, spacing = 3, height = 2 })
  eq(success, true, "s02: run succeeds")
  eq(stats.cellsCleared, 33, "s02: cellsCleared unchanged under rotation")
  assertCleared(m, start, spine, "s02 spine")
  assertCleared(m, start, ribs, "s02 ribs")
  -- Hard-coded WORLD coords: facing East, right is South (+Z), left is North (-Z).
  eq(m:_wasDug(3, 1, 1), true, "s02: right rib of mouth l=3 runs +Z")
  eq(m:_wasDug(3, 1, -1), true, "s02: left rib of mouth l=3 runs -Z")
  eq(m:_wasDug(3, 1, -3), false, "s02: nothing beyond ribReach=2")
  poseEq(nav, m, 0, 1, 0, 1, "s02: round trip closes with heading restored")
end

--------------------------------------------------------------------------------
-- 3. ribReach off-by-one: a rib reaching R blocks is a tunnel of length R+1
--------------------------------------------------------------------------------
local function s03_rib_offbyone_reach()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillRegion(m, start, 0, 4, -5, 5, 0, 0)
  local _, _, mouths = planCells(5, 3, 4, 1)

  local success, stats = Branch.new(nav):run(
    { length = 5, ribReach = 3, spacing = 4, height = 1 })
  eq(success, true, "s03: run succeeds")
  eq(#mouths, 1, "s03: exactly one mouth (l=4)")
  eq(stats.cellsCleared, expectedCells(5, 3, 4, 1), "s03: cellsCleared == 10")
  for _, w in ipairs({ 1, 2, 3, -1, -2, -3 }) do
    eq(m:_wasDug(worldOf(start, 4, w, 0)), true, "s03: rib cell w=" .. w .. " dug")
  end
  for _, w in ipairs({ 4, -4 }) do
    eq(m:_wasDug(worldOf(start, 4, w, 0)), false, "s03: nothing at w=" .. w)
  end
  poseEq(nav, m, 0, 1, 0, 0, "s03: closed loop")
end

--------------------------------------------------------------------------------
-- 4. ribReach 0 degenerates to a plain (vein-following) tunnel
--------------------------------------------------------------------------------
local function s04_no_ribs_degenerates_to_tunnel()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillRegion(m, start, 0, 5, -1, 1, 0, 1)
  local spine = planCells(6, 0, 3, 2)

  local success, stats = Branch.new(nav):run(
    { length = 6, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s04: run succeeds")
  eq(stats.ribPairs, 0, "s04: no rib pairs")
  eq(stats.ribsDone, 0, "s04: no ribs cut")
  eq(stats.subRuns, 1, "s04: a single sub-run")
  eq(stats.cellsCleared, 11, "s04: cellsCleared == SL*H-1 == 11")
  assertCleared(m, start, spine, "s04 spine")
  assertUntouched(m, start, {
    { l = 2, w = 1, u = 0 }, { l = 3, w = -1, u = 0 }, { l = 3, w = 1, u = 1 },
  }, "s04")
  poseEq(nav, m, 0, 1, 0, 0, "s04: closed loop")
end

--------------------------------------------------------------------------------
-- 5. the mouth boundary: a rib needs k*spacing <= length-1
--------------------------------------------------------------------------------
local function s05_spacing_boundary()
  local start = { x = 0, y = 1, z = 0, h = 0 }

  local m1, nav1 = setup(start)
  fillRegion(m1, start, 0, 5, -2, 2, 0, 0)
  local _, s1 = Branch.new(nav1):run({ length = 6, ribReach = 2, spacing = 3, height = 1 })
  eq(s1.ribPairs, 1, "s05: length 6, spacing 3 -> one pair (l=3; l=6 is past the end)")
  eq(s1.ribsDone, 2, "s05: two ribs cut")

  local m2, nav2 = setup(start)
  fillRegion(m2, start, 0, 6, -2, 2, 0, 0)
  local _, s2 = Branch.new(nav2):run({ length = 7, ribReach = 2, spacing = 3, height = 1 })
  eq(s2.ribPairs, 2, "s05: length 7, spacing 3 -> two pairs (l=3,6)")
  eq(s2.ribsDone, 4, "s05: four ribs cut")
end

--------------------------------------------------------------------------------
-- 6. an ore vein exposed by the dig is followed and fully extracted
--------------------------------------------------------------------------------
local function s06_ore_vein_full_extraction()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  local spine = planCells(4, 0, 3, 2)
  fillCells(m, start, spine)
  fillCells(m, start, VEIN_L, "minecraft:iron_ore", oreProps())
  -- Plain stone touching the far end of the vein: the fill must stop at it.
  local sx, sy, sz = worldOf(start, 2, 4, 0)
  m:_setBlock(sx, sy, sz, "minecraft:stone")

  local success, stats = Branch.new(nav):run(
    { length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s06: run succeeds")
  eq(stats.oreMined, 5, "s06: the whole 5-block vein was mined")
  eq(stats.veins, 1, "s06: counted as one excursion")
  eq(stats.cellsCleared, 7, "s06: vein moves are NOT corridor cells")
  assertCleared(m, start, VEIN_L, "s06 vein")
  eq(m:_wasDug(sx, sy, sz), false, "s06: the non-ore neighbour was not dug")
  assertCleared(m, start, spine, "s06 spine")
  poseEq(nav, m, 0, 1, 0, 0, "s06: closed loop")
end

--------------------------------------------------------------------------------
-- 7. an excursion restores the exact pose, so the sweep order is untouched
--------------------------------------------------------------------------------
local function s07_vein_pose_restored_midsweep()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCells(m, start, planCells(4, 0, 3, 2))
  fillCells(m, start, VEIN_L, "minecraft:iron_ore", oreProps())

  local seen = {}
  local success = Branch.new(nav, {
    onProgress = function(info)
      if not info.inVein then
        seen[#seen + 1] = { info.pose.x, info.pose.y, info.pose.z, info.pose.h }
      end
      return true
    end,
  }):run({ length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s07: run succeeds")

  -- Independently derived serpentine order for a 1-wide, 4-long, 2-high sweep:
  -- out along u=0 at heading S.h, up, then back along u=1 at the flipped heading.
  local want = {}
  for l = 1, 3 do want[#want + 1] = { l, 0, 0, start.h } end
  want[#want + 1] = { 3, 0, 1, start.h } -- the ascent move keeps the row heading
  for l = 2, 0, -1 do want[#want + 1] = { l, 0, 1, (start.h + 2) % 4 } end

  eq(#seen, #want, "s07: one hook call per corridor move")
  local matched = true
  for i, cell in ipairs(want) do
    local x, y, z = worldOf(start, cell[1], cell[2], cell[3])
    local got = seen[i]
    if not got or got[1] ~= x or got[2] ~= y or got[3] ~= z or got[4] ~= cell[4] then
      matched = false
    end
  end
  ok(matched, "s07: sweep visited the expected cells in order, headings included")
  poseEq(nav, m, 0, 1, 0, 0, "s07: closed loop")
end

--------------------------------------------------------------------------------
-- 8. oreMatch rejects everything -> no vein following at all
--------------------------------------------------------------------------------
local function s08_ore_rejected_by_orematch()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCells(m, start, planCells(4, 0, 3, 2))
  fillCells(m, start, VEIN_L, "minecraft:iron_ore", oreProps())

  local success, stats = Branch.new(nav, {
    oreMatch = function() return false end,
  }):run({ length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s08: run succeeds")
  eq(stats.oreMined, 0, "s08: no ore mined")
  eq(stats.veins, 0, "s08: no excursions")
  eq(stats.cellsCleared, 7, "s08: corridor unchanged")
  local intact = true
  for _, c in ipairs(VEIN_L) do
    if m:_blockAt(worldOf(start, c.l, c.w, c.u)) == nil then intact = false end
  end
  ok(intact, "s08: every ore block still in place")
end

--------------------------------------------------------------------------------
-- 9. the default matcher falls back to the NAME for untagged modded ores, and
--    does not false-positive on ordinary stone-family blocks
--------------------------------------------------------------------------------
local function s09_ore_name_fallback_and_decoys()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCells(m, start, planCells(4, 0, 3, 2))
  local vein = { { l = 2, w = 1, u = 0 }, { l = 2, w = 2, u = 0 }, { l = 2, w = 2, u = 1 } }
  fillCells(m, start, vein, "allthemodium:vibranium_ore") -- NO tags at all
  local dx, dy, dz = worldOf(start, 2, 3, 0)
  m:_setBlock(dx, dy, dz, "minecraft:deepslate")
  local mx, my, mz = worldOf(start, 2, 1, 1)
  m:_setBlock(mx, my, mz, "minecraft:mossy_cobblestone")

  local success, stats = Branch.new(nav):run(
    { length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s09: run succeeds")
  eq(stats.oreMined, 3, "s09: untagged modded ore matched by name")
  assertCleared(m, start, vein, "s09 vein")
  eq(m:_wasDug(dx, dy, dz), false, "s09: deepslate decoy untouched")
  eq(m:_wasDug(mx, my, mz), false, "s09: mossy_cobblestone decoy untouched")
end

--------------------------------------------------------------------------------
-- 10. maxVein bounds a single excursion
--------------------------------------------------------------------------------
local function s10_vein_budget_capped()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCells(m, start, planCells(4, 0, 3, 2))
  local vein = {}
  for w = 1, 20 do vein[#vein + 1] = { l = 2, w = w, u = 0 } end
  fillCells(m, start, vein, "minecraft:iron_ore", oreProps())

  local success, stats = Branch.new(nav, { maxVein = 5 }):run(
    { length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s10: run succeeds (a capped vein is not an error)")
  eq(stats.oreMined, 5, "s10: exactly maxVein blocks mined")
  eq(stats.veinCapped, 1, "s10: one excursion hit the cap")
  for w = 1, 5 do
    eq(m:_blockAt(worldOf(start, 2, w, 0)), nil, "s10: vein block w=" .. w .. " mined")
  end
  ok(m:_blockAt(worldOf(start, 2, 6, 0)) ~= nil, "s10: vein block w=6 left in place")
  poseEq(nav, m, 0, 1, 0, 0, "s10: closed loop")
end

--------------------------------------------------------------------------------
-- 11. ore INSIDE the corridor box is left to the sweep, never to the vein DFS
--------------------------------------------------------------------------------
local function s11_vein_skips_cells_inside_the_corridor()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  local spine = planCells(5, 0, 3, 2)
  fillCells(m, start, spine, "minecraft:iron_ore", oreProps())

  local success, stats = Branch.new(nav):run(
    { length = 5, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s11: run succeeds")
  eq(stats.oreMined, 0, "s11: no vein moves — every ore cell is corridor")
  eq(stats.veins, 0, "s11: no excursions")
  eq(stats.cellsCleared, 9, "s11: the sweep cleared it all")
  assertCleared(m, start, spine, "s11 spine")
  poseEq(nav, m, 0, 1, 0, 0, "s11: closed loop")
end

--------------------------------------------------------------------------------
-- 12. running dry inside a vein: real reason survives tunnel's "aborted"
--------------------------------------------------------------------------------
local function s12_fuel_exhaustion_midvein()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start, 8)
  fillCells(m, start, planCells(4, 0, 3, 1))
  local vein = {}
  for w = 1, 20 do vein[#vein + 1] = { l = 2, w = w, u = 0 } end
  fillCells(m, start, vein, "minecraft:iron_ore", oreProps())

  local success, err, stats = Branch.new(nav, { veinFuelFloor = 1 }):run(
    { length = 4, ribReach = 0, spacing = 3, height = 1 })
  eq(success, false, "s12: run aborts")
  eq(err, "no_fuel", "s12: the vein's real reason survives the remap")
  ok(stats.oreMined > 0, "s12: partial vein progress before running dry")
  ok(stats ~= nil and stats.pose ~= nil, "s12: stall pose reported")
  local p = nav:getPose()
  ok(stats.poseLost or not (p.x == 0 and p.y == 1 and p.z == 0),
    "s12: stalled off the corridor (no auto-return), flagged as poseLost")
end

--------------------------------------------------------------------------------
-- 13. an unbreakable ore candidate is skipped, not fatal
--------------------------------------------------------------------------------
local function s13_unbreakable_ore_is_skipped()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCells(m, start, planCells(4, 0, 3, 2))
  -- Protected "ore" on the LEFT of cell l=1, and an ordinary 2-block vein on the
  -- RIGHT of l=2. Kept apart on purpose: a candidate adjacent to a mined vein
  -- cell is legitimately probed again from inside the vein, which would make the
  -- skip count 2 and say nothing about the skip-and-continue behaviour.
  local ux, uy, uz = worldOf(start, 1, -1, 0)
  m:_setBlock(ux, uy, uz, "minecraft:unobtainium_ore",
    { tags = { ["c:ores"] = true }, breakable = false })
  local vein = { { l = 2, w = 1, u = 0 }, { l = 2, w = 2, u = 0 } }
  fillCells(m, start, vein, "minecraft:iron_ore", oreProps())

  local success, stats = Branch.new(nav):run(
    { length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s13: run succeeds past the protected block")
  eq(stats.veinSkipped, 1, "s13: the unbreakable candidate was skipped once")
  eq(stats.oreMined, 2, "s13: the ordinary vein was still fully mined")
  assertCleared(m, start, vein, "s13 vein")
  ok(m:_blockAt(ux, uy, uz) ~= nil, "s13: the unbreakable block is still there")
  local hit = false
  for _, d in ipairs(m:_getDigLog()) do
    if d.name == "minecraft:unobtainium_ore" then hit = true end
  end
  ok(not hit, "s13: never dug the unbreakable block")
  poseEq(nav, m, 0, 1, 0, 0, "s13: closed loop")
end

--------------------------------------------------------------------------------
-- 14. bedrock in the spine aborts before any rib is reached
--------------------------------------------------------------------------------
local function s14_bedrock_in_spine_aborts()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillRegion(m, start, 0, 5, -2, 2, 0, 0)
  local bx, by, bz = worldOf(start, 3, 0, 0)
  m:_setBedrock(bx, by, bz)

  local success, err, stats = Branch.new(nav):run(
    { length = 6, ribReach = 2, spacing = 4, height = 1 })
  eq(success, false, "s14: run aborts")
  eq(err, "blocked_unbreakable", "s14: nav's reason passes through verbatim")
  eq(stats.cellsCleared, 2, "s14: cleared 2 cells before the block")
  eq(stats.ribsDone, 0, "s14: never reached the mouth at l=4")
  eq(stats.spineDone, false, "s14: spine not marked done")
  local hit = false
  for _, d in ipairs(m:_getDigLog()) do
    if d.name == "minecraft:bedrock" then hit = true end
  end
  ok(not hit, "s14: never dug bedrock")
end

--------------------------------------------------------------------------------
-- 15. the loot region filling MID-VEIN triggers a dump without leaving the vein
--------------------------------------------------------------------------------
local function s15_dump_midvein()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start, nil, { maxStack = 1 })
  fillCells(m, start, planCells(4, 0, 3, 2))
  local vein = {}
  for w = 1, 20 do vein[#vein + 1] = { l = 2, w = w, u = 0 } end
  fillCells(m, start, vein, "minecraft:diamond_ore", oreProps())
  m:_fillSlots(10, 1)
  m:_addEnderChest(16)

  local success, stats = Branch.new(nav, { chestSlot = 16 }):run(
    { length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s15: run succeeds")
  ok(stats.veinDumps >= 1, "s15: at least one dump happened MID-VEIN")
  eq(stats.oreMined, 20, "s15: the whole vein was mined despite the dumps")
  ok(m.enderNetwork["minecraft:diamond_ore"] ~= nil, "s15: ore reached the ender network")
  local chest = m.getItemDetail(16) -- dot-call: bound turtle-API fn
  ok(chest ~= nil and chest.name:find("ender") ~= nil, "s15: ender chest still in slot 16")
  assertCleared(m, start, vein, "s15 vein")
  poseEq(nav, m, 0, 1, 0, 0, "s15: closed loop")
end

--------------------------------------------------------------------------------
-- 16. a rib sub-run with torches DISABLED must not dump the torch slot
--------------------------------------------------------------------------------
local function s16_rib_run_does_not_dump_torches()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start, nil, { maxStack = 1 })
  fillRegion(m, start, 0, 4, -3, 3, 0, 1)
  m:_fillSlots(12, 1)
  m:_addItem(15, "minecraft:torch", 64) -- plenty, so a placed torch cannot empty the slot
  m:_addEnderChest(16)

  local success, stats = Branch.new(nav, {
    chestSlot = 16, torchSlot = 15, torchEvery = 4, ribTorchEvery = 0, fill = false,
  }):run({ length = 5, ribReach = 3, spacing = 2, height = 2 })
  eq(success, true, "s16: run succeeds")
  ok(stats.dumps + stats.veinDumps >= 1, "s16: a dump did happen")
  local torches = m.getItemDetail(15)
  ok(torches ~= nil and torches.name == "minecraft:torch",
    "s16: torches still reserved in slot 15")
  eq(m.enderNetwork["minecraft:torch"], nil, "s16: torches never teleported away")
end

--------------------------------------------------------------------------------
-- 17. the caller's onProgress can abort, and "aborted" is NOT remapped
--------------------------------------------------------------------------------
local function s17_onprogress_abort_passthrough()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillRegion(m, start, 0, 7, -2, 2, 0, 1)
  local calls = 0

  local success, err, stats = Branch.new(nav, {
    onProgress = function(info)
      calls = calls + 1
      if info.corridorCells >= 5 then return false end
      return true
    end,
  }):run({ length = 8, ribReach = 0, spacing = 3, height = 2 })
  eq(success, false, "s17: run aborts on onProgress false")
  eq(err, "aborted", "s17: reason stays aborted (not remapped)")
  eq(stats.cellsCleared, 5, "s17: stopped at the abort cell")
  eq(calls, 5, "s17: hook called once per corridor move up to the abort")
end

--------------------------------------------------------------------------------
-- 18. aborting from inside a rib propagates out through the nested sub-run
--------------------------------------------------------------------------------
local function s18_abort_inside_rib()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillRegion(m, start, 0, 6, -4, 4, 0, 0)
  local ribCalls = 0

  local success, err, stats = Branch.new(nav, {
    onProgress = function(info)
      if info.phase == "rib" and info.ribSide == "right" then
        ribCalls = ribCalls + 1
        if ribCalls >= 2 then return false end
      end
      return true
    end,
  }):run({ length = 7, ribReach = 3, spacing = 3, height = 1 })
  eq(success, false, "s18: run aborts from inside the rib")
  eq(err, "aborted", "s18: the nested abort surfaces as aborted")
  eq(stats.ribsDone, 0, "s18: the interrupted rib does not count as done")
  eq(stats.spineDone, false, "s18: spine not marked done")
  eq(ribCalls, 2, "s18: stopped on the second rib cell")
  ok(m:_wasDug(worldOf(start, 1, 0, 0)), "s18: the spine was partially cut")
end

--------------------------------------------------------------------------------
-- 19. spine torches survive the ribs — the whole reason ribs are cut mid-sweep
--------------------------------------------------------------------------------
local function s19_torches_survive_ribs()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillRegion(m, start, 0, 8, -2, 2, 0, 1)
  m:_addItem(15, "minecraft:torch", 64)
  local _, ribs = planCells(9, 2, 4, 2)

  -- torchEvery == spacing, so every torch sits exactly on a rib mouth.
  local success, stats = Branch.new(nav, { torchSlot = 15, torchEvery = 4 }):run(
    { length = 9, ribReach = 2, spacing = 4, height = 2 })
  eq(success, true, "s19: run succeeds")
  eq(stats.torches, 2, "s19: two spine torches placed (l=4,8)")
  for _, l in ipairs({ 4, 8 }) do
    local b = m:_blockAt(worldOf(start, l, 0, 0))
    ok(b ~= nil and b.name == "minecraft:torch",
      "s19: torch still standing at rib mouth l=" .. l)
  end
  for _, l in ipairs({ 1, 2, 3, 5, 6, 7 }) do
    eq(m:_blockAt(worldOf(start, l, 0, 0)), nil, "s19: no torch at l=" .. l)
  end
  assertCleared(m, start, ribs, "s19 ribs") -- ribTorchEvery defaults to 0
  poseEq(nav, m, 0, 1, 0, 0, "s19: closed loop")
end

--------------------------------------------------------------------------------
-- 20. a vein that breaks through the floor gets the floor patched back
--------------------------------------------------------------------------------
local function s20_floor_repatch_after_vein()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillCells(m, start, planCells(4, 0, 3, 2))
  -- Solid dirt floor one below the corridor, except a 2-deep ore column at l=2.
  for l = 0, 3 do
    local fx, fy, fz = worldOf(start, l, 0, -1)
    if l ~= 2 then m:_setBlock(fx, fy, fz, "minecraft:dirt") end
  end
  fillCells(m, start, { { l = 2, w = 0, u = -1 }, { l = 2, w = 0, u = -2 } },
    "minecraft:iron_ore", oreProps())
  m:_addItem(14, "minecraft:cobblestone", 64)

  local success, stats = Branch.new(nav, { fill = true, fillerSlot = 14 }):run(
    { length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s20: run succeeds")
  eq(stats.oreMined, 2, "s20: both floor ore blocks mined")
  ok(stats.fills >= 1, "s20: the hole it left was patched")
  local px, py, pz = worldOf(start, 2, 0, -1)
  local patch = m:_blockAt(px, py, pz)
  ok(patch ~= nil and patch.name == "minecraft:cobblestone",
    "s20: floor under l=2 is cobblestone again")
  eq(m:_blockAt(worldOf(start, 2, 0, -2)), nil, "s20: only the top cell patched, not backfilled")
  poseEq(nav, m, 0, 1, 0, 0, "s20: closed loop")
end

--------------------------------------------------------------------------------
-- 21. veinScan knobs: "none" is blind, "vertical" still sees floor and ceiling
--------------------------------------------------------------------------------
local function s21_scan_modes()
  local start = { x = 0, y = 1, z = 0, h = 0 }

  local m1, nav1 = setup(start)
  fillCells(m1, start, planCells(4, 0, 3, 2))
  fillCells(m1, start, VEIN_L, "minecraft:iron_ore", oreProps())
  local ok1, s1 = Branch.new(nav1, { veinScan = "none" }):run(
    { length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(ok1, true, "s21: none-scan run succeeds")
  eq(s1.oreMined, 0, "s21: veinScan=none mines no ore")
  ok(m1:_blockAt(worldOf(start, 2, 1, 0)) ~= nil, "s21: side vein left in place")

  local m2, nav2 = setup(start)
  fillCells(m2, start, planCells(4, 0, 3, 2))
  local floorVein = { { l = 2, w = 0, u = -1 }, { l = 2, w = 0, u = -2 } }
  fillCells(m2, start, floorVein, "minecraft:iron_ore", oreProps())
  -- A side block the vertical scan must NOT reach.
  local sx, sy, sz = worldOf(start, 2, 1, 0)
  m2:_setBlock(sx, sy, sz, "minecraft:iron_ore", oreProps())
  local ok2, s2 = Branch.new(nav2, { veinScan = "vertical" }):run(
    { length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(ok2, true, "s21: vertical-scan run succeeds")
  eq(s2.oreMined, 2, "s21: veinScan=vertical finds the floor vein")
  assertCleared(m2, start, floorVein, "s21 floor vein")
  ok(m2:_blockAt(sx, sy, sz) ~= nil, "s21: veinScan=vertical ignores the side wall")
end

--------------------------------------------------------------------------------
-- 22. nav:back() is never used — it cannot dig, and gravel can refill behind us
--------------------------------------------------------------------------------
local function s22_retreat_never_uses_back()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m = Mock.new({ pose = start })
  local backCalls = 0
  local origBack = m.back
  m.back = function(...)
    backCalls = backCalls + 1
    return origBack(...)
  end
  local nav = Nav.new(m, start)
  fillCells(m, start, planCells(4, 0, 3, 2))
  fillCells(m, start, VEIN_L, "minecraft:iron_ore", oreProps())

  local success, stats = Branch.new(nav):run(
    { length = 4, ribReach = 0, spacing = 3, height = 2 })
  eq(success, true, "s22: run succeeds")
  eq(stats.oreMined, 5, "s22: the vein was still fully extracted")
  eq(backCalls, 0, "s22: nav:back() never called anywhere in the pattern")
end

--------------------------------------------------------------------------------
-- 23. gravel above a rib: auto-dig retry keeps coverage and the move count
--------------------------------------------------------------------------------
local function s23_gravel_over_rib()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillRegion(m, start, 0, 4, -2, 2, 0, 1)
  local spine, ribs = planCells(5, 2, 2, 2)
  -- Two gravel blocks stacked directly above a rib's top cell.
  local gx, gy, gz = worldOf(start, 2, 1, 2)
  m:_setGravel(gx, gy, gz)
  m:_setGravel(gx, gy + 1, gz)

  local success, stats = Branch.new(nav):run(
    { length = 5, ribReach = 2, spacing = 2, height = 2 })
  eq(success, true, "s23: run succeeds through gravel")
  eq(stats.cellsCleared, expectedCells(5, 2, 2, 2), "s23: cellsCleared unchanged (moves, not digs)")
  eq(stats.cellsCleared, 29, "s23: cellsCleared literal == 29")
  -- NOTE: unlike tunnel, branch's move count exceeds its DISTINCT cell count
  -- (every rib re-enters H-1 spine cells on its way back down), so tunnel's
  -- "#digLog > cellsCleared" check does not carry over. Count the gravel itself.
  local gravelDigs, topDigs = 0, 0
  local tx, ty, tz = worldOf(start, 2, 1, 1)
  for _, d in ipairs(m:_getDigLog()) do
    if d.name == "minecraft:gravel" then gravelDigs = gravelDigs + 1 end
    if d.x == tx and d.y == ty and d.z == tz then topDigs = topDigs + 1 end
  end
  eq(gravelDigs, 2, "s23: both gravel blocks were dug out after settling")
  eq(topDigs, 3, "s23: the rib's top cell was dug 3x (stone + 2 gravel refills)")
  eq(#m:_getDigLog(), 27, "s23: 25 planned cells + 2 gravel refills")
  assertCleared(m, start, spine, "s23 spine")
  assertCleared(m, start, ribs, "s23 ribs")
  poseEq(nav, m, 0, 1, 0, 0, "s23: closed loop")
end

--------------------------------------------------------------------------------
-- 24. an invalid spec is rejected before the turtle moves at all
--------------------------------------------------------------------------------
local function s24_bad_spec()
  local start = { x = 0, y = 1, z = 0, h = 0 }
  local m, nav = setup(start)
  fillRegion(m, start, 0, 5, -2, 2, 0, 1)
  local branch = Branch.new(nav)

  local bad = {
    { spec = {}, why = "empty spec" },
    { spec = { length = 0, ribReach = 2, spacing = 3, height = 2 }, why = "length 0" },
    { spec = { length = 5, ribReach = -1, spacing = 3, height = 2 }, why = "negative ribReach" },
    { spec = { length = 5, ribReach = 2, spacing = 0, height = 2 }, why = "spacing 0" },
    { spec = { length = 5, ribReach = 2, spacing = 3, height = 2, width = 2 }, why = "width 2" },
  }
  for _, case in ipairs(bad) do
    local success, err, stats = branch:run(case.spec)
    eq(success, false, "s24: rejected (" .. case.why .. ")")
    eq(err, "bad_spec", "s24: reason is bad_spec (" .. case.why .. ")")
    eq(stats, nil, "s24: no stats for a rejected spec (" .. case.why .. ")")
  end
  eq(#m:_getDigLog(), 0, "s24: nothing was dug")
  poseEq(nav, m, 0, 1, 0, 0, "s24: the turtle never moved")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_spine_and_ribs_coverage,
  s02_nonzero_start_heading,
  s03_rib_offbyone_reach,
  s04_no_ribs_degenerates_to_tunnel,
  s05_spacing_boundary,
  s06_ore_vein_full_extraction,
  s07_vein_pose_restored_midsweep,
  s08_ore_rejected_by_orematch,
  s09_ore_name_fallback_and_decoys,
  s10_vein_budget_capped,
  s11_vein_skips_cells_inside_the_corridor,
  s12_fuel_exhaustion_midvein,
  s13_unbreakable_ore_is_skipped,
  s14_bedrock_in_spine_aborts,
  s15_dump_midvein,
  s16_rib_run_does_not_dump_torches,
  s17_onprogress_abort_passthrough,
  s18_abort_inside_rib,
  s19_torches_survive_ribs,
  s20_floor_repatch_after_vein,
  s21_scan_modes,
  s22_retreat_never_uses_back,
  s23_gravel_over_rib,
  s24_bad_spec,
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
