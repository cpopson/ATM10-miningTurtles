-- mine.lua — in-game driver for the quarry pattern. Builds a nav over the REAL
-- turtle backend and runs quarry.lua to clear a box.
--
-- Usage (at the turtle prompt):
--   mine <width> <length> <depth>
--   e.g.  mine 3 3 5     -- a 3x3 area, 5 deep
--
-- Placement: put the turtle at the TOP corner of the box you want cleared, in
-- the AIR one block above the first layer to dig. Coverage doesn't depend on
-- which way it faces, but geometrically the box extends:
--   * to the turtle's RIGHT   for <width>   (+X)
--   * BEHIND the turtle        for <length>  (+Z)
--   * straight DOWN            for <depth>   (−Y)
-- The turtle's own column is the entry/exit shaft; it returns there when done.
--
-- Fuel: needs roughly width*length*depth + (depth+width+length) fuel. Refuel
-- first (`refuel all` with coal in a slot) — quarry aborts cleanly if it runs dry.
--
-- Ender Chest auto-dump: put an Ender Chest in slot 16. When the other 15 slots
-- fill, the turtle dumps its loot into the chest in place (no trip home) and
-- keeps going — set the chest's paired chest at your base to feed storage. With
-- no ender chest, it still mines but overflow drops on the ground once full.

local Nav = require("nav")
local Quarry = require("quarry")

local function colour(c)
  if term and term.isColor and term.isColor() then term.setTextColor(c) end
end
local function reset()
  if term and term.isColor and term.isColor() then term.setTextColor(colors.white) end
end

local args = { ... }
local W = tonumber(args[1])
local L = tonumber(args[2])
local D = tonumber(args[3])
if not (W and L and D) then
  print("usage: mine <width> <length> <depth>   (e.g. mine 3 3 5)")
  return
end

-- The only reference to the real `turtle` global.
local nav = Nav.new(turtle, { x = 0, y = 0, z = 0, h = 0 })

-- Fuel sanity check.
local est = W * L * D + (D + W + L)
local fuel = nav:getFuelLevel()
if fuel ~= "unlimited" and fuel < est then
  nav:refuel()
  fuel = nav:getFuelLevel()
  if fuel ~= "unlimited" and fuel < est then
    colour(colors and colors.red)
    print("Low fuel: have " .. tostring(fuel) .. ", need ~" .. est ..
      ". Add coal and `refuel all`, then retry.")
    reset()
    return
  end
end

local chest = nav:getItemDetail(16)
if chest and chest.name:lower():find("ender") and chest.name:lower():find("chest") then
  print("Ender Chest in slot 16 - will auto-dump loot when full.")
else
  print("No ender chest in slot 16 - overflow drops on the ground once full.")
end

print(string.format("Quarrying %dx%d, %d deep (~%d cells)...", W, L, D, W * L * D))
local ok, a, b = Quarry.new(nav):run({ width = W, length = L, depth = D })

if ok then
  colour(colors and colors.green)
  print("DONE: cleared " .. a.cellsCleared .. " cells, back at start.")
  reset()
else
  -- a = err string, b = stats
  colour(colors and colors.red)
  print("ABORTED (" .. tostring(a) .. ") after " .. (b and b.cellsCleared or "?") ..
    " cells, " .. (b and b.layersDone or "?") .. " layers.")
  local p = nav:getPose()
  print(string.format("  stopped at (%d,%d,%d) h=%d relative to start.", p.x, p.y, p.z, p.h))
  reset()
end
