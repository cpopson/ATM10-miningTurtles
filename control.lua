-- control.lua — in-game control-computer driver. Runs the Coordinator over
-- rednet, partitions a box across the turtles that register, and prints a live
-- per-turtle status dashboard.
--
-- Usage (on a computer with a wireless/ender modem):
--   control <width> <length> <depth> <turtleCount>
--   e.g.  control 6 4 5 3
--
-- Deployment (GPS-free): the coordinator assigns each strip to the turtle whose
-- reported position matches the strip's corner. Since turtles have no shared
-- coordinate frame without GPS, you tell each turtle its position when you start
-- `fleet` on it (see fleet.lua). Use the SAME frame here: the box's top-NW
-- corner is (0, 1, 0) by convention, extending +X (width) and +Z (length) and
-- down (depth). Place turtle i one block above the top corner of strip i and
-- start it with those coordinates.

local Comms = require("comms")
local RT = require("rednet_transport")
local Coordinator = require("coordinator")

local args = { ... }
local W, L, D = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
local expect = tonumber(args[4])
if not (W and L and D and expect) then
  print("usage: control <width> <length> <depth> <turtleCount>")
  return
end

local function findModem()
  for _, side in ipairs({ "top", "bottom", "left", "right", "front", "back" }) do
    if peripheral.getType(side) == "modem" then return side end
  end
end

local side = findModem()
if not side then
  print("No modem found. Attach a wireless (or ender) modem to this computer.")
  return
end

local comms = Comms.new(RT.new(side), { role = "control" })
local clock = function() return os.epoch("utc") / 1000 end -- seconds
local box = { id = "quarry", origin = { x = 0, y = 1, z = 0 }, width = W, length = L, depth = D }
local coord = Coordinator.new(comms, { clock = clock, staleAfter = 30, box = box, expect = expect })

local function render()
  term.clear()
  term.setCursorPos(1, 1)
  local s = coord:getStatus()
  print(string.format("cc-fleet-miner  %dx%d deep %d  [%s]", W, L, D, s.phase))
  print("id   state     fuel   mined  job")
  local ids = {}
  for id in pairs(s.turtles) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local t = s.turtles[id]
    print(string.format("%-4d %-9s %-6s %-6s %s",
      id, t.state or "?", tostring(t.fuel or "-"), tostring(t.mined or 0), tostring(t.job or "-")))
  end
end

print(string.format("Control up. Waiting for %d turtles to register...", expect))
while not coord:isComplete() do
  coord:step()
  render()
  os.sleep(0.5)
end
render()
print("All strips complete.")
