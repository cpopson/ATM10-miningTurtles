-- dig.lua — in-game driver for the tunnel pattern. Builds a nav over the REAL
-- turtle backend and runs tunnel.lua to cut a straight corridor.
--
-- Usage (at the turtle prompt):
--   dig <length> [width] [height]
--   e.g.  dig 20        -- a 1-wide, 2-tall corridor 20 long
--         dig 20 3 3    -- a 3-wide, 3-tall corridor 20 long
--
-- Placement: put the turtle IN the tunnel mouth, facing the way you want to dig.
-- Its own cell is the start of the corridor; it extends:
--   * FORWARD (its facing) for <length>
--   * to its RIGHT          for <width>   (default 1)
--   * UP                    for <height>  (default 2)
-- The turtle returns to the mouth, facing its original heading, when done.
--
-- Fuel: needs roughly width*length*height + (height+width+length). Refuel first
-- (`refuel all` with coal in a slot) — dig aborts cleanly if it runs dry.
--
-- Reserved inventory slots (auto-used only if stocked):
--   * slot 16 — Ender Chest: auto-dumps loot in place when the loot slots fill.
--   * slot 15 — Torches: one placed on the floor every few blocks (needs height >= 2).
--   * slot 14 — Filler blocks (cobble): patches gaps in the corridor floor.

local Nav = require("nav")
local Tunnel = require("tunnel")
local Config = require("config")

local function colour(c)
  if term and term.isColor and term.isColor() then term.setTextColor(c) end
end
local function reset()
  if term and term.isColor and term.isColor() then term.setTextColor(colors.white) end
end

local args = { ... }
local L = tonumber(args[1])
local W = tonumber(args[2]) or 1
local H = tonumber(args[3]) or 2
if not L then
  print("usage: dig <length> [width] [height]   (e.g. dig 20 1 2)")
  return
end

-- The only reference to the real `turtle` global.
local nav = Nav.new(turtle, { x = 0, y = 0, z = 0, h = 0 })

-- Fuel sanity check (placements cost no fuel; only moves do).
local est = W * L * H + (H + W + L)
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

local torchSlot = Config.torchSlot or 15
local fillerSlot = Config.fillerSlot or 14
local torchEvery = Config.torchEvery or 8

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
  print("Torches in slot " .. torchSlot .. " - placing one every " .. torchEvery .. " blocks.")
else
  print("No torches in slot " .. torchSlot .. " - corridor will be unlit.")
end
if nav:getItemCount(fillerSlot) > 0 then
  print("Filler in slot " .. fillerSlot .. " - floor gaps will be patched.")
else
  print("No filler in slot " .. fillerSlot .. " - floor gaps left open.")
end

print(string.format("Tunnelling %d long, %d wide, %d tall (~%d cells)...", L, W, H, W * L * H))
local ok, a, b = Tunnel.new(nav, {
  chestSlot = Config.chestSlot,
  torchSlot = torchSlot,
  torchEvery = (H >= 2) and torchEvery or 0,
  fill = true,
  fillerSlot = fillerSlot,
}):run({ width = W, length = L, depth = H })

if ok then
  colour(colors and colors.green)
  print(string.format("DONE: cleared %d cells (%d torches, %d fills, %d dumps), back at start.",
    a.cellsCleared, a.torches, a.fills, a.dumps))
  reset()
else
  -- a = err string, b = stats
  colour(colors and colors.red)
  print("ABORTED (" .. tostring(a) .. ") after " .. (b and b.cellsCleared or "?") ..
    " cells, " .. (b and b.levelsDone or "?") .. " levels.")
  local p = nav:getPose()
  print(string.format("  stopped at (%d,%d,%d) h=%d relative to start.", p.x, p.y, p.z, p.h))
  reset()
end
