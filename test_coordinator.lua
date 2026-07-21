-- test_coordinator.lua — suite for coordinator.lua. Drives it against a MockBus
-- (real Comms endpoints for the turtles) and a fake clock. Runs under plain `lua`.
--
-- Run:  lua test_coordinator.lua

local Comms = require("comms")
local MockBus = require("mockbus")
local Coordinator = require("coordinator")

local passed, failed = 0, 0

local function ok(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("  FAIL: " .. msg) end
end

local function eq(actual, expected, msg)
  if actual == expected then
    ok(true, msg)
  else
    ok(false, msg .. " (got " .. tostring(actual) .. " want " .. tostring(expected) .. ")")
  end
end

local function turtle(bus, id)
  return Comms.new(bus:_endpoint(id), { id = id, role = "turtle", controlId = 0 })
end

-- Turtle endpoints also receive sibling REGISTER broadcasts (real behavior; the
-- worker filters these). For assertions, pull the next ASSIGN, skipping the rest.
local function nextAssign(t)
  while true do
    local m = t:receive(0)
    if m == nil then return nil end
    if m.type == "ASSIGN" then return m end
  end
end

local function control(bus)
  return Comms.new(bus:_endpoint(0), { id = 0, role = "control" })
end

-- W=6,L=2,D=2 -> strips {2,2,2} at origins x=0,2,4.
local function box6()
  return { id = "q", origin = { x = 0, y = 0, z = 0 }, width = 6, length = 2, depth = 2 }
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--------------------------------------------------------------------------------
-- 1. discovery builds the roster
--------------------------------------------------------------------------------
local function s01_discovery_roster()
  local bus = MockBus.new()
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, box = box6(), staleAfter = 100 })
  turtle(bus, 1):register({ x = 0, y = 0, z = 0, h = 0 })
  turtle(bus, 2):register({ x = 2, y = 0, z = 0, h = 0 })
  turtle(bus, 3):register({ x = 4, y = 0, z = 0, h = 0 })
  coord:step()
  local roster = coord:getRoster()
  eq(count(roster), 3, "s01: 3 turtles in roster")
  ok(roster[1] and roster[1].pose.x == 0, "s01: pose recorded")
end

--------------------------------------------------------------------------------
-- 2. dispatch partitions and assigns one job each
--------------------------------------------------------------------------------
local function s02_dispatch_partitions_and_assigns()
  local bus = MockBus.new()
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, box = box6(), staleAfter = 100 })
  local t1, t2, t3 = turtle(bus, 1), turtle(bus, 2), turtle(bus, 3)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  t2:register({ x = 2, y = 0, z = 0, h = 0 })
  t3:register({ x = 4, y = 0, z = 0, h = 0 })
  coord:step()
  coord:dispatch()
  for i, t in ipairs({ t1, t2, t3 }) do
    local m = nextAssign(t)
    ok(m ~= nil and m.type == "ASSIGN", "s02: turtle " .. i .. " got ASSIGN")
    eq(nextAssign(t), nil, "s02: turtle " .. i .. " got exactly one")
  end
  eq(count(coord:getStatus().jobs), 3, "s02: 3 jobs")
end

--------------------------------------------------------------------------------
-- 3. PROGRESS updates the status table
--------------------------------------------------------------------------------
local function s03_progress_tracking()
  local bus = MockBus.new()
  local now = 7
  local coord = Coordinator.new(control(bus), { clock = function() return now end, box = box6(), staleAfter = 100 })
  local t1 = turtle(bus, 1)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  coord:step(); coord:dispatch()
  local asn = nextAssign(t1)
  t1:progress({ x = 1, y = 0, z = 0, h = 0 }, 500, 4, asn.payload.job.id)
  coord:step()
  local st = coord:getStatus().turtles[1]
  eq(st.state, "mining", "s03: state mining")
  eq(st.mined, 4, "s03: mined tracked")
  eq(st.fuel, 500, "s03: fuel tracked")
  eq(st.lastSeen, 7, "s03: lastSeen = clock")
end

--------------------------------------------------------------------------------
-- 4. DONE from all completes the run
--------------------------------------------------------------------------------
local function s04_done_completes()
  local bus = MockBus.new()
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, box = box6(), staleAfter = 100 })
  local ts = { turtle(bus, 1), turtle(bus, 2), turtle(bus, 3) }
  ts[1]:register({ x = 0, y = 0, z = 0, h = 0 })
  ts[2]:register({ x = 2, y = 0, z = 0, h = 0 })
  ts[3]:register({ x = 4, y = 0, z = 0, h = 0 })
  coord:step(); coord:dispatch()
  for _, t in ipairs(ts) do
    local asn = nextAssign(t)
    t:done(asn.payload.job.id)
  end
  coord:step()
  ok(coord:isComplete(), "s04: complete when all DONE")
  ok(coord:allDone(), "s04: all done (no failures)")
end

--------------------------------------------------------------------------------
-- 5. ERROR reassigns the strip to a free (pose-matching) spare
--------------------------------------------------------------------------------
local function s05_error_reassign_to_spare()
  local bus = MockBus.new()
  -- W=4 -> 2 strips at x=0,x=2. t1,t2 are the miners; t3 is a spare at x=0.
  local box4 = { id = "q", origin = { x = 0, y = 0, z = 0 }, width = 4, length = 2, depth = 2 }
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, box = box4, strips = 2, staleAfter = 100 })
  local t1, t2, t3 = turtle(bus, 1), turtle(bus, 2), turtle(bus, 3)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  t2:register({ x = 2, y = 0, z = 0, h = 0 })
  t3:register({ x = 0, y = 0, z = 0, h = 0 }) -- spare at strip-1's corner
  coord:step(); coord:dispatch()
  local asn1 = nextAssign(t1)            -- t1 got strip 1
  local job1 = asn1.payload.job.id
  t1:reportError("no_fuel", job1)
  coord:step()
  local m3 = nextAssign(t3)
  ok(m3 ~= nil and m3.type == "ASSIGN", "s05: spare got a reassigned job")
  eq(m3 and m3.payload.job.id, job1, "s05: same job.id reassigned to the spare")
  eq(coord:getStatus().turtles[1].state, "error", "s05: t1 marked error")
end

--------------------------------------------------------------------------------
-- 6. a stale turtle's strip is reassigned (liveness sweep on the clock)
--------------------------------------------------------------------------------
local function s06_stale_reassign()
  local bus = MockBus.new()
  local now = 0
  local box4 = { id = "q", origin = { x = 0, y = 0, z = 0 }, width = 4, length = 2, depth = 2 }
  local coord = Coordinator.new(control(bus), { clock = function() return now end, box = box4, strips = 2, staleAfter = 5 })
  local t1, t2, t3 = turtle(bus, 1), turtle(bus, 2), turtle(bus, 3)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  t2:register({ x = 2, y = 0, z = 0, h = 0 })
  t3:register({ x = 0, y = 0, z = 0, h = 0 }) -- spare at strip-1's corner
  coord:step(); coord:dispatch()
  local asn1 = nextAssign(t1)
  local asn2 = nextAssign(t2)
  local job1 = asn1.payload.job.id
  -- t2 keeps reporting; t1 goes silent. Advance the clock past staleAfter.
  now = 8
  t2:progress({ x = 3, y = 0, z = 0, h = 0 }, 400, 2, asn2.payload.job.id) -- refresh t2 lastSeen=8
  coord:step() -- drains t2 progress, then sweeps: t1 (lastSeen 0) is stale
  local m3 = nextAssign(t3)
  ok(m3 ~= nil and m3.type == "ASSIGN" and m3.payload.job.id == job1, "s06: spare got t1's stale strip")
  eq(coord:getStatus().turtles[1].state, "stale", "s06: t1 marked stale")
end

--------------------------------------------------------------------------------
-- 7. reassign to the SAME turtle (reboot path) keeps the job.id
--------------------------------------------------------------------------------
local function s07_idempotent_reassign_same_turtle()
  local bus = MockBus.new()
  local now = 0
  local box2 = { id = "q", origin = { x = 0, y = 0, z = 0 }, width = 2, length = 2, depth = 2 }
  local coord = Coordinator.new(control(bus), { clock = function() return now end, box = box2, staleAfter = 5, maxAttempts = 5 })
  local t1 = turtle(bus, 1)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  coord:step(); coord:dispatch()
  local asn1 = nextAssign(t1)
  now = 10
  coord:step() -- t1 stale, no spare -> reassign to t1 itself
  local asn2 = nextAssign(t1)
  ok(asn2 ~= nil and asn2.payload.job.id == asn1.payload.job.id, "s07: same job.id reassigned to same turtle")
end

--------------------------------------------------------------------------------
-- 8. exceeding maxAttempts marks the job failed (doesn't hang)
--------------------------------------------------------------------------------
local function s08_maxAttempts_failed()
  local bus = MockBus.new()
  local box2 = { id = "q", origin = { x = 0, y = 0, z = 0 }, width = 2, length = 2, depth = 2 }
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, box = box2, staleAfter = 100, maxAttempts = 2 })
  local t1 = turtle(bus, 1)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  coord:step(); coord:dispatch()
  local job1
  for _ = 1, 3 do
    local asn = nextAssign(t1)
    if asn then
      job1 = asn.payload.job.id
      t1:reportError("blocked_unbreakable", job1)
      coord:step()
    end
  end
  eq(coord:getStatus().jobs[job1].status, "failed", "s08: job failed after maxAttempts")
  ok(coord:isComplete(), "s08: complete (terminal) not hung")
  ok(not coord:allDone(), "s08: not allDone (a failure remains)")
end

--------------------------------------------------------------------------------
-- 9. surplus turtles stay idle when W < roster
--------------------------------------------------------------------------------
local function s09_extra_turtles_idle()
  local bus = MockBus.new()
  local box2 = { id = "q", origin = { x = 0, y = 0, z = 0 }, width = 2, length = 2, depth = 2 } -- 2 strips {1,1}
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, box = box2, staleAfter = 100 })
  local t1, t2, t3 = turtle(bus, 1), turtle(bus, 2), turtle(bus, 3)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  t2:register({ x = 1, y = 0, z = 0, h = 0 })
  t3:register({ x = 5, y = 0, z = 0, h = 0 }) -- no strip here
  coord:step(); coord:dispatch()
  eq(nextAssign(t3), nil, "s09: surplus turtle got no ASSIGN")
  eq(coord:getStatus().turtles[3].state, "idle", "s09: surplus turtle idle")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_discovery_roster,
  s02_dispatch_partitions_and_assigns,
  s03_progress_tracking,
  s04_done_completes,
  s05_error_reassign_to_spare,
  s06_stale_reassign,
  s07_idempotent_reassign_same_turtle,
  s08_maxAttempts_failed,
  s09_extra_turtles_idle,
}

local scPassed, scFailed = 0, 0
for i, scenario in ipairs(scenarios) do
  local before = failed
  local runOk, err = pcall(scenario)
  if runOk and failed == before then
    scPassed = scPassed + 1
  else
    scFailed = scFailed + 1
    if not runOk then print("  ERROR in scenario " .. i .. ": " .. tostring(err)) end
  end
end

print(scPassed .. " passed, " .. scFailed .. " failed")
if os.exit then os.exit(scFailed == 0 and 0 or 1) end
