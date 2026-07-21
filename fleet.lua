-- fleet.lua — in-game turtle driver. Registers with the control computer, waits
-- for its ASSIGN, and runs the quarry for its strip while reporting progress.
--
-- Usage (on a Mining Turtle with a wireless/ender modem + fuel):
--   fleet <x> <y> <z>
--   e.g.  fleet 2 1 0
--
-- The <x> <y> <z> are the turtle's position in the SHARED coordinate frame the
-- control computer uses (GPS-free: you supply them). Place turtle i one block
-- ABOVE the top corner of strip i and pass that corner's coords; the coordinator
-- position-matches the strip to you. Default (0,0,0) if omitted.
--
-- Put an Ender Chest in slot 16 for auto-dump (see mine.lua). Refuel first.

local Comms = require("comms")
local RT = require("rednet_transport")
local Nav = require("nav")
local Quarry = require("quarry")
local Worker = require("worker")

local args = { ... }
local x = tonumber(args[1]) or 0
local y = tonumber(args[2]) or 0
local z = tonumber(args[3]) or 0

local function findModem()
  for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
    if peripheral.getType(side) == "modem" then return side end
  end
end

local side = findModem()
if not side then
  print("No modem found. Attach a wireless (or ender) modem to this turtle.")
  return
end

local comms = Comms.new(RT.new(side), { role = "turtle" })
local nav = Nav.new(turtle, { x = x, y = y, z = z, h = 0 })
local factory = function(n, opts) return Quarry.new(n, opts) end
local worker = Worker.new(comms, nav, factory, { progressEvery = 8, jobOpts = { chestSlot = 16 } })

print(string.format("Turtle at (%d,%d,%d). Registering with control...", x, y, z))
worker:run({ timeout = 2 })
print("Worker stopped.")
