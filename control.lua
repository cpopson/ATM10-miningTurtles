-- control.lua — the interactive fleet control station.
--
-- On a computer with a wireless/ender modem:
--   control            (runs the on-screen setup, or offers to resume a saved job)
--
-- Live keyboard controls while running:
--   [P]ause  [R]esume  [S]top  [H]ome (return)  [Q]uit
--
-- Concurrency: parallel.waitForAny(commsLoop, inputLoop, renderLoop). This is
-- the CC-safe way to receive rednet AND read keys AND render at once -- each
-- pulled event is offered to every coroutine, so a sleeping renderLoop does NOT
-- starve the commsLoop's rednet.receive (unlike a single loop with os.sleep,
-- which drops the message events). Coroutines are cooperative, so coordinator
-- mutations never interleave.
--
-- Persistence: coordinator state is saved to disk each pump, so a crash/reboot
-- resumes where it left off.

local Comms = require("comms")
local RT = require("rednet_transport")
local Coordinator = require("coordinator")
local Store = require("store")
local Setup = require("setup")
local Config = require("config")

local STATE = "coordinator"

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
local store = Store.new()
local coord = Coordinator.new(comms, {
  clock = clock, store = store, stateName = STATE,
  staleAfter = Config.staleAfter, maxAttempts = Config.maxAttempts,
})

-- Startup: resume a saved job, or run setup for a new one.
local saved = store.load(STATE)
local resumed = false
if saved and saved.phase == "running" then
  term.write("Saved job found. [R]esume or [N]ew? ")
  if read():lower() ~= "n" then
    coord:restore()
    resumed = true
  end
end
if not resumed then
  store.delete(STATE)
  local job = Setup.run()
  coord.expect = job.expect
  for _, box in ipairs(job.boxes) do coord:enqueue(box) end
  print(("Waiting for %d turtles to register..."):format(job.expect))
end

--------------------------------------------------------------------------------
-- Rendering (in-place, flicker-free; hint bar pinned to the bottom row)
--------------------------------------------------------------------------------

local function render()
  local s = coord:getStatus()
  local w, h = term.getSize()
  local ctrl = s.stopped and " [STOPPED]" or (s.paused and " [PAUSED]" or "")
  local jc, done = 0, 0
  for _, j in pairs(s.jobs) do
    jc = jc + 1
    if j.status == "done" then done = done + 1 end
  end
  local lines = {
    "cc-fleet-miner  " .. s.phase .. ctrl,
    string.format("queued:%d  strips:%d (%d done)  failed:%d", s.boxesQueued, jc, done, s.failedCount),
    string.format("%-12s %-9s %-6s %-6s %s", "turtle", "state", "fuel", "mined", "job"),
  }
  local ids = {}
  for id in pairs(s.turtles) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local t = s.turtles[id]
    local name = t.label or ("#" .. id)
    lines[#lines + 1] = string.format("%-12s %-9s %-6s %-6s %s",
      name, t.state or "?", tostring(t.fuel or "-"), tostring(t.mined or 0), tostring(t.job or "-"))
  end
  local hint = "[P]ause [R]esume [S]top [H]ome [Q]uit"
  for i = 1, h do
    term.setCursorPos(1, i)
    local line = (i == h) and hint or (lines[i] or "")
    if #line < w then line = line .. string.rep(" ", w - #line) end
    term.write(string.sub(line, 1, w))
  end
end

--------------------------------------------------------------------------------
-- The three concurrent loops
--------------------------------------------------------------------------------

local function commsLoop()
  while not coord:isComplete() do coord:step(1) end
end

local function inputLoop()
  while true do
    local _, key = os.pullEvent("key")
    if key == keys.p then coord:pauseAll()
    elseif key == keys.r then coord:resumeAll()
    elseif key == keys.s then coord:stopAll()
    elseif key == keys.h then coord:returnAll()
    elseif key == keys.q then return end
  end
end

local function renderLoop()
  while true do
    render()
    os.sleep(0.3)
  end
end

render()
parallel.waitForAny(commsLoop, inputLoop, renderLoop)
render()
term.setCursorPos(1, select(2, term.getSize()))
print("")
print(coord:isComplete() and "Run complete." or "Station stopped.")
