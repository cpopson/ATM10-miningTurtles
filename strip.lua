-- strip.lua — in-game driver for the branch/strip pattern. Builds a nav over the
-- REAL turtle backend and runs branch.lua to cut a spine with paired ribs.
--
-- Usage (at the turtle prompt):
--   strip <length> [ribReach] [spacing] [height]
--   e.g.  strip 40           -- 40-long spine, 8-block ribs every 3, 2 tall
--         strip 40 12 4 3    -- 12-block ribs every 4 cells, 3 tall
--
-- Placement: put the turtle IN the spine mouth, facing the way you want the
-- spine to run. Its own cell is the start of the spine and is never dug. From
-- there the mine extends:
--   * FORWARD (its facing)      for <length> cells
--   * a rib pair LEFT and RIGHT at every multiple of <spacing>
--   * each rib reaching         <ribReach> blocks out from the spine
--   * UP                        for <height>  (default 2)
-- The turtle returns to the mouth, facing its original heading, when done.
--
-- Ore-vein following: as it digs, the turtle checks the faces it exposes and
-- mines out any connected ore vein it uncovers (up to `maxVein` blocks), then
-- carries on where it left off. Set `veinScan` in config.lua to trade coverage
-- for speed — turning costs no fuel, only time.
--
-- Fuel: see the estimate below; it includes an allowance for vein excursions.
-- Refuel first (`refuel all` with coal in a slot) — strip aborts cleanly if it
-- runs dry, but it does NOT walk home, so top it up generously.
--
-- Reserved inventory slots (auto-used only if stocked):
--   * slot 16 — Ender Chest: auto-dumps loot in place when the loot slots fill.
--   * slot 15 — Torches: one on the spine floor every few blocks (needs height >= 2).
--   * slot 14 — Filler blocks (cobble): patches gaps in the floor.

local Nav = require("nav")
local Branch = require("branch")
local Config = require("config")

local function colour(c)
  if term and term.isColor and term.isColor() then term.setTextColor(c) end
end
local function reset()
  if term and term.isColor and term.isColor() then term.setTextColor(colors.white) end
end

local args = { ... }
local SL = tonumber(args[1])
local R = tonumber(args[2]) or Config.ribReach or 8
local SP = tonumber(args[3]) or Config.ribSpacing or 3
local H = tonumber(args[4]) or 2
if not SL then
  print("usage: strip <length> [ribReach] [spacing] [height]   (e.g. strip 40 8 3 2)")
  return
end

-- The only reference to the real `turtle` global.
local nav = Nav.new(turtle, { x = 0, y = 0, z = 0, h = 0 })

local torchSlot = Config.torchSlot or 15
local fillerSlot = Config.fillerSlot or 14
local torchEvery = Config.torchEvery or 8
local veinFollow = Config.veinFollow ~= false
local veinScan = Config.veinScan or "sides"
local maxVein = Config.maxVein or 64

-- Fuel sanity check (placements and turns cost no fuel; only moves do).
local mouths = (R > 0) and math.floor((SL - 1) / SP) or 0
local spineMoves = SL * H - 1 + (SL - 1) + (H - 1)         -- sweep + "xzy" return
local ribMoves = 2 * mouths * (((R + 1) * H - 1) + R + (H - 1))
local veinAllow = veinFollow and (2 * maxVein * (2 * mouths + 1)) or 0
local est = spineMoves + ribMoves + veinAllow

local fuel = nav:getFuelLevel()
if fuel ~= "unlimited" and fuel < est then
  nav:refuel()
  fuel = nav:getFuelLevel()
  if fuel ~= "unlimited" and fuel < est then
    colour(colors and colors.red)
    print("Low fuel: have " .. tostring(fuel) .. ", need ~" .. est ..
      " (includes a vein-following allowance). Add coal and `refuel all`, then retry.")
    reset()
    return
  end
end

-- Report which optional features will actually engage, given what's stocked.
local chest = nav:getItemDetail(Config.chestSlot)
if chest and chest.name:lower():find("ender") and chest.name:lower():find("chest") then
  print("Ender Chest in slot " .. Config.chestSlot .. " - will auto-dump loot when full.")
else
  print("No ender chest in slot " .. Config.chestSlot .. " - overflow drops on the ground once full.")
end
if H < 2 then
  print("Height " .. H .. ": torches skipped (needs height >= 2).")
elseif nav:getItemCount(torchSlot) > 0 then
  print("Torches in slot " .. torchSlot .. " - one on the spine every " .. torchEvery .. " blocks.")
else
  print("No torches in slot " .. torchSlot .. " - the mine will be unlit.")
end
if nav:getItemCount(fillerSlot) > 0 then
  print("Filler in slot " .. fillerSlot .. " - floor gaps will be patched.")
else
  print("No filler in slot " .. fillerSlot .. " - floor gaps left open.")
end
if not veinFollow or veinScan == "none" then
  print("Vein following OFF - ribs are cut blind.")
else
  print("Vein following ON (" .. veinScan .. ", max " .. maxVein .. " blocks per vein).")
  if veinScan == "sides" then
    print("  Side scanning roughly triples wall-clock time (fuel cost is unchanged).")
    print("  Set veinScan = \"vertical\" in config.lua to speed it up.")
  end
end
if SP == 1 then
  colour(colors and colors.yellow)
  print("Spacing 1: ribs will merge into one open room, not a strip mine.")
  reset()
end
if mouths == 0 and R > 0 then
  colour(colors and colors.yellow)
  print("No ribs fit: spacing " .. SP .. " exceeds length-1 (" .. (SL - 1) .. "). Cutting a plain tunnel.")
  reset()
end

print(string.format("Strip mining: spine %d long, %d rib pair(s) every %d, reaching %d each side, %d tall...",
  SL, mouths, SP, R, H))

local ok, a, b = Branch.new(nav, {
  chestSlot = Config.chestSlot,
  torchSlot = torchSlot,
  torchEvery = (H >= 2) and torchEvery or 0,
  ribTorchEvery = 0,
  fill = true,
  fillerSlot = fillerSlot,
  veinFollow = veinFollow,
  veinScan = veinScan,
  maxVein = maxVein,
}):run({ length = SL, ribReach = R, spacing = SP, height = H })

if ok then
  colour(colors and colors.green)
  print(string.format("DONE: %d cells, %d ribs, %d ore from %d veins (%d torches, %d fills, %d dumps), back at start.",
    a.cellsCleared, a.ribsDone, a.oreMined, a.veins, a.torches, a.fills, a.dumps + a.veinDumps))
  reset()
  if a.veinCapped > 0 then
    print("  " .. a.veinCapped .. " vein(s) hit the " .. maxVein ..
      "-block cap - raise maxVein in config.lua to finish them.")
  end
  if a.veinsSkippedFuel > 0 then
    print("  " .. a.veinsSkippedFuel .. " vein(s) skipped to conserve fuel.")
  end
else
  -- a = err string, b = stats
  colour(colors and colors.red)
  print("ABORTED (" .. tostring(a) .. ") after " .. (b and b.cellsCleared or "?") ..
    " cells, " .. (b and b.ribsDone or "?") .. " ribs, " .. (b and b.oreMined or "?") .. " ore.")
  local p = nav:getPose()
  print(string.format("  stopped at (%d,%d,%d) h=%d relative to start.", p.x, p.y, p.z, p.h))
  if b and b.poseLost then
    print("  WARNING: pose lost mid-vein - verify the turtle's position before restarting.")
  end
  reset()
end
