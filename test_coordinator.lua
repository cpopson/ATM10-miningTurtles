-- test_coordinator.lua — suite for coordinator.lua. Drives it against a MockBus
-- (real Comms endpoints for the turtles) and a fake clock. Runs under plain `lua`.
--
-- Run:  lua test_coordinator.lua

local Comms = require("comms")
local MockBus = require("mockbus")
local Coordinator = require("coordinator")
local MockStore = require("mockstore")

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
-- worker filters these). For assertions, pull the next message of a given type.
local function nextType(t, wantType)
  while true do
    local m = t:receive(0)
    if m == nil then return nil end
    if m.type == wantType then return m end
  end
end
local function nextAssign(t) return nextType(t, "ASSIGN") end
local function nextControl(t) return nextType(t, "CONTROL") end

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
  turtle(bus, 1):register({ x = 0, y = 0, z = 0, h = 0 }, "Alpha")
  turtle(bus, 2):register({ x = 2, y = 0, z = 0, h = 0 })
  turtle(bus, 3):register({ x = 4, y = 0, z = 0, h = 0 })
  coord:step()
  local roster = coord:getRoster()
  eq(count(roster), 3, "s01: 3 turtles in roster")
  ok(roster[1] and roster[1].pose.x == 0, "s01: pose recorded")
  eq(roster[1] and roster[1].label, "Alpha", "s01: label recorded in roster")
  eq(coord:getStatus().turtles[1].label, "Alpha", "s01: label exposed in status")
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
-- 10. auto-dispatch fires when a late turtle finally registers (heartbeat heals)
--------------------------------------------------------------------------------
local function s10_auto_dispatch_on_late_register()
  local bus = MockBus.new()
  local coord = Coordinator.new(control(bus),
    { clock = function() return 0 end, box = box6(), staleAfter = 100, expect = 2 })
  local t1, t2 = turtle(bus, 1), turtle(bus, 2)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  coord:step() -- only 1 of 2 registered -> no dispatch yet
  eq(nextAssign(t1), nil, "s10: no assign before the expected count is reached")
  -- the second turtle's REGISTER arrives late (e.g. its first one dropped)
  t2:register({ x = 3, y = 0, z = 0, h = 0 })
  coord:step() -- roster now 2 >= expect -> auto-dispatch
  local m1, m2 = nextAssign(t1), nextAssign(t2)
  ok(m1 ~= nil and m1.type == "ASSIGN", "s10: t1 assigned after auto-dispatch")
  ok(m2 ~= nil and m2.type == "ASSIGN", "s10: late t2 assigned after auto-dispatch")
end

--------------------------------------------------------------------------------
-- 11. a multi-box queue advances to the next box when one completes
--------------------------------------------------------------------------------
-- A box with no id (so enqueue assigns box1/box2); shared origin so both boxes'
-- strips match the same pre-placed turtles.
local function abox()
  return { origin = { x = 0, y = 0, z = 0 }, width = 6, length = 2, depth = 2 }
end

local function s11_multibox_queue_advances()
  local bus = MockBus.new()
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, staleAfter = 100 })
  local t1, t2 = turtle(bus, 1), turtle(bus, 2)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  t2:register({ x = 3, y = 0, z = 0, h = 0 })
  coord:step()
  coord:enqueue(abox()) -- box1
  coord:enqueue(abox()) -- box2
  coord:dispatch()      -- dispatches box1

  local a1, a2 = nextAssign(t1), nextAssign(t2)
  ok(a1 and a2, "s11: box1 strips assigned")
  ok(not coord:isComplete(), "s11: not complete while box2 queued")
  t1:done(a1.payload.job.id)
  t2:done(a2.payload.job.id)
  coord:step() -- drains DONEs, box1 terminal -> _advance pops+dispatches box2

  ok(not coord:isComplete(), "s11: not complete, box2 now running")
  local b1, b2 = nextAssign(t1), nextAssign(t2)
  ok(b1 and b1.type == "ASSIGN", "s11: t1 got a box2 strip")
  ok(b2 and b2.type == "ASSIGN", "s11: t2 got a box2 strip")
  ok(b1 and b1.payload.job.id ~= (a1 and a1.payload.job.id), "s11: box2 job id differs from box1")
  t1:done(b1.payload.job.id)
  t2:done(b2.payload.job.id)
  coord:step()
  ok(coord:isComplete(), "s11: complete after both boxes")
end

--------------------------------------------------------------------------------
-- 12. a single enqueued box behaves exactly like before (queue-of-one)
--------------------------------------------------------------------------------
local function s12_single_box_regression()
  local bus = MockBus.new()
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, staleAfter = 100 })
  local t1, t2 = turtle(bus, 1), turtle(bus, 2)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  t2:register({ x = 3, y = 0, z = 0, h = 0 })
  coord:step()
  coord:enqueue(abox())
  coord:dispatch()
  local a1, a2 = nextAssign(t1), nextAssign(t2)
  t1:done(a1.payload.job.id)
  t2:done(a2.payload.job.id)
  coord:step()
  ok(coord:isComplete(), "s12: single box completes")
  ok(coord:allDone(), "s12: allDone")
end

--------------------------------------------------------------------------------
-- 13. pauseAll holds assignment; resumeAll releases it
--------------------------------------------------------------------------------
local function s13_pauseAll_then_resume()
  local bus = MockBus.new()
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, staleAfter = 100 })
  local t1 = turtle(bus, 1)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  coord:step()

  coord:pauseAll()
  local pc = nextControl(t1)
  ok(pc and pc.payload.cmd == "pause", "s13: pause broadcast to turtle")
  eq(coord.paused, true, "s13: paused flag set")

  coord:enqueue(abox())
  coord:dispatch() -- paused -> partitions but does NOT assign
  eq(nextAssign(t1), nil, "s13: no ASSIGN while paused")

  coord:resumeAll()
  local rc = nextControl(t1)
  ok(rc and rc.payload.cmd == "resume", "s13: resume broadcast")
  eq(coord.paused, false, "s13: paused cleared")
  local asn = nextAssign(t1)
  ok(asn and asn.type == "ASSIGN", "s13: held strip assigned after resume")
end

--------------------------------------------------------------------------------
-- 14. stopAll is terminal: broadcast STOP, clear queue, complete
--------------------------------------------------------------------------------
local function s14_stopAll_terminal()
  local bus = MockBus.new()
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, staleAfter = 100 })
  local t1, t2 = turtle(bus, 1), turtle(bus, 2)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  coord:step()
  coord:enqueue(abox())
  coord:enqueue(abox()) -- a second box in the queue
  coord:dispatch()
  nextAssign(t1) -- consume the assign

  coord:stopAll()
  local sc = nextControl(t1)
  ok(sc and sc.payload.cmd == "stop", "s14: stop broadcast")
  eq(coord.stopped, true, "s14: stopped flag")
  ok(coord:isComplete(), "s14: complete after stop")
  eq(#coord.boxQueue, 0, "s14: box queue cleared")
  local sawStopped = false
  for _, j in pairs(coord:getStatus().jobs) do
    if j.status == "stopped" then sawStopped = true end
  end
  ok(sawStopped, "s14: in-flight job marked stopped")
  -- a fresh REGISTER yields no ASSIGN once stopped
  t2:register({ x = 3, y = 0, z = 0, h = 0 })
  coord:step()
  eq(nextAssign(t2), nil, "s14: no ASSIGN after stop")
end

--------------------------------------------------------------------------------
-- 15. returnAll broadcasts RETURN (not STOP) but is otherwise terminal
--------------------------------------------------------------------------------
local function s15_returnAll_broadcasts_return()
  local bus = MockBus.new()
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, staleAfter = 100 })
  local t1 = turtle(bus, 1)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  coord:step()
  coord:enqueue(abox())
  coord:dispatch()
  nextAssign(t1)

  coord:returnAll()
  local rc = nextControl(t1)
  ok(rc and rc.payload.cmd == "return", "s15: return broadcast (not stop)")
  eq(coord.stopped, true, "s15: terminal like stop")
  ok(coord:isComplete(), "s15: complete after return")
end

--------------------------------------------------------------------------------
-- 16. a paused fleet is not swept for staleness
--------------------------------------------------------------------------------
local function s16_paused_suppresses_liveness()
  local bus = MockBus.new()
  local now = 0
  local coord = Coordinator.new(control(bus), { clock = function() return now end, staleAfter = 5 })
  local t1 = turtle(bus, 1)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  coord:step()
  coord:enqueue(abox())
  coord:dispatch()
  local asn = nextAssign(t1) -- t1 assigned at now=0
  local jobId = asn.payload.job.id

  coord:pauseAll()
  now = 100         -- long past staleAfter
  coord:step()      -- liveness suspended while paused -> no reassign fires
  eq(coord:getStatus().jobs[jobId].attempts, 0, "s16: paused suppresses the liveness sweep")

  coord:resumeAll()
  now = 200
  coord:step()      -- liveness resumes -> the stale strip is reassigned
  ok(coord:getStatus().jobs[jobId].attempts >= 1, "s16: liveness resumes after unpause")
end

--------------------------------------------------------------------------------
-- Persistence helpers
--------------------------------------------------------------------------------
-- Pre-seed a store with a mid-run snapshot: box1 dispatched (strip mining,
-- assigned to turtle 5), box2 still queued.
local function seedSnapshot(store)
  local box1 = { id = "box1", pattern = "quarry", origin = { x = 0, y = 0, z = 0 }, width = 6, length = 2, depth = 2 }
  local box2 = { id = "box2", pattern = "quarry", origin = { x = 0, y = 0, z = 0 }, width = 6, length = 2, depth = 2 }
  local job = {
    id = "box1-s1", pattern = "quarry", origin = { x = 0, y = 0, z = 0 },
    width = 6, length = 2, depth = 2, region = { x0 = 0, x1 = 5, z0 = 0, z1 = 1, y0 = -2, y1 = -1 },
  }
  store.save("coordinator", {
    boxQueue = { box2 },
    currentBox = box1,
    jobs = { ["box1-s1"] = { job = job, status = "mining", assignedTo = 5, attempts = 0 } },
    queue = {},
    phase = "running", paused = false, stopped = false, boxSeq = 2, failedCount = 0,
  })
end

--------------------------------------------------------------------------------
-- 17. persistence hooks fire: dispatch + progress produce saves
--------------------------------------------------------------------------------
local function s17_persistence_hooks_fire()
  local bus = MockBus.new()
  local store = MockStore.new()
  local coord = Coordinator.new(control(bus), { clock = function() return 0 end, staleAfter = 100, store = store })
  local t1 = turtle(bus, 1)
  t1:register({ x = 0, y = 0, z = 0, h = 0 })
  coord:step()
  coord:enqueue(abox())
  coord:dispatch()
  coord:step() -- flushes the dispatch
  local snap = store:_get("coordinator")
  ok(snap ~= nil, "s17: coordinator state saved")
  ok(snap and snap.jobs ~= nil and snap.phase == "running", "s17: durable fields present")
  local before = store:_saves()
  local asn = nextAssign(t1)
  t1:progress({ x = 1, y = 0, z = 0, h = 0 }, 500, 3, asn.payload.job.id)
  coord:step()
  ok(store:_saves() > before, "s17: a progress update triggers a new save")
end

--------------------------------------------------------------------------------
-- 18. restore() rehydrates durable fields + seeds liveness for the assignee
--------------------------------------------------------------------------------
local function s18_restore_rehydrates()
  local bus = MockBus.new()
  local store = MockStore.new()
  seedSnapshot(store)
  local coord = Coordinator.new(control(bus), { clock = function() return 42 end, staleAfter = 100, store = store })
  eq(coord:restore(), true, "s18: restored from disk")
  eq(coord.phase, "running", "s18: phase rehydrated")
  eq(#coord.boxQueue, 1, "s18: boxQueue rehydrated")
  eq(coord.currentBox and coord.currentBox.id, "box1", "s18: currentBox rehydrated")
  ok(coord.jobs["box1-s1"] ~= nil, "s18: jobs rehydrated")
  local st5 = coord:getStatus().turtles[5]
  eq(st5 and st5.state, "mining", "s18: seeded liveness for the assignee")
  eq(st5 and st5.lastSeen, 42, "s18: seeded lastSeen = clock")
end

--------------------------------------------------------------------------------
-- 19. a still-mining turtle re-attaches via PROGRESS (no re-ASSIGN)
--------------------------------------------------------------------------------
local function s19_resync_via_progress()
  local bus = MockBus.new()
  local store = MockStore.new()
  seedSnapshot(store)
  local coord = Coordinator.new(control(bus), { clock = function() return 42 end, staleAfter = 100, store = store })
  coord:restore()
  local t5 = turtle(bus, 5)
  t5:progress({ x = 1, y = 0, z = 0, h = 0 }, 500, 3, "box1-s1")
  coord:step()
  eq(coord.jobs["box1-s1"].status, "mining", "s19: re-attached via progress")
  eq(coord.jobs["box1-s1"].assignedTo, 5, "s19: still assigned to 5")
  eq(nextAssign(t5), nil, "s19: no re-ASSIGN to a still-mining turtle")
end

--------------------------------------------------------------------------------
-- 20. a rebooted turtle re-registers and gets its job re-ASSIGNed (same id)
--------------------------------------------------------------------------------
local function s20_resync_via_register_reassigns()
  local bus = MockBus.new()
  local store = MockStore.new()
  seedSnapshot(store)
  local coord = Coordinator.new(control(bus), { clock = function() return 42 end, staleAfter = 100, store = store })
  coord:restore()
  local t5 = turtle(bus, 5)
  t5:register({ x = 0, y = 0, z = 0, h = 0 }) -- pose matches box1-s1's origin
  coord:step()
  local asn = nextAssign(t5)
  ok(asn and asn.payload.job.id == "box1-s1", "s20: rebooted turtle re-ASSIGNed the same job")
end

--------------------------------------------------------------------------------
-- 21. a dead assignee's strip goes stale and reassigns to a spare
--------------------------------------------------------------------------------
local function s21_restore_stale_reassign()
  local bus = MockBus.new()
  local store = MockStore.new()
  seedSnapshot(store)
  local now = 42
  local coord = Coordinator.new(control(bus), { clock = function() return now end, staleAfter = 5, store = store })
  coord:restore()
  local t6 = turtle(bus, 6)                    -- a spare at box1-s1's corner
  t6:register({ x = 0, y = 0, z = 0, h = 0 })
  now = 100                                    -- turtle 5 never pings; go past staleAfter
  coord:step()
  local asn = nextAssign(t6)
  ok(asn and asn.payload.job.id == "box1-s1", "s21: dead assignee's strip reassigned to the spare")
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
  s10_auto_dispatch_on_late_register,
  s11_multibox_queue_advances,
  s12_single_box_regression,
  s13_pauseAll_then_resume,
  s14_stopAll_terminal,
  s15_returnAll_broadcasts_return,
  s16_paused_suppresses_liveness,
  s17_persistence_hooks_fire,
  s18_restore_rehydrates,
  s19_resync_via_progress,
  s20_resync_via_register_reassigns,
  s21_restore_stale_reassign,
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
