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
local Config = require("config")

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

local comms = Comms.new(RT.new(side), { role = "control", protocol = Config.protocol })
local clock = function() return os.epoch("utc") / 1000 end -- seconds
local box = { id = "quarry", origin = { x = 0, y = 1, z = 0 }, width = W, length = L, depth = D }
local coord = Coordinator.new(comms, {
  clock = clock, box = box, expect = expect,
  staleAfter = Config.staleAfter, maxAttempts = Config.maxAttempts,
})

local function render()
  local s = coord:getStatus()
  local lines = {
    string.format("cc-fleet-miner  %dx%d deep %d  [%s]", W, L, D, s.phase),
    string.format("%-12s %-9s %-6s %-6s %s", "turtle", "state", "fuel", "mined", "job"),
  }
  local ids = {}
  for id in pairs(s.turtles) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local t = s.turtles[id]
    local name = t.label or ("#" .. id) -- label set via `label set <name>` on the turtle
    lines[#lines + 1] = string.format("%-12s %-9s %-6s %-6s %s",
      name, t.state or "?", tostring(t.fuel or "-"), tostring(t.mined or 0), tostring(t.job or "-"))
  end
  -- Repaint in place: overwrite each row padded to the full width, with no
  -- term.clear() between frames -- so the dashboard updates without the blink
  -- that a full-screen wipe causes. Blank any leftover rows below.
  local w, h = term.getSize()
  for i = 1, h do
    term.setCursorPos(1, i)
    local line = lines[i] or ""
    if #line < w then line = line .. string.rep(" ", w - #line) end
    term.write(string.sub(line, 1, w))
  end
end

print(string.format("Control up. Waiting for %d turtles to register...", expect))
render()
-- Pace the loop by BLOCKING on the receive (coord:step(1)), never os.sleep --
-- in CC os.sleep discards the rednet events carrying PROGRESS/REGISTER, which
-- would freeze the dashboard and stop reassignment. step(1) waits up to 1s for a
-- message (returning early when one arrives), processes it, then we redraw.
while not coord:isComplete() do
  coord:step(1)
  render()
end
render()
print("All strips complete.")
