-- test_worker.lua — suite for worker.lua. Drives the worker against a MockBus
-- (real Comms endpoints), a stub quarry factory, and a spy nav. Runs under
-- plain `lua`.
--
-- Run:  lua test_worker.lua

local Comms = require("comms")
local MockBus = require("mockbus")
local Worker = require("worker")

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

local function wire(bus, id, opts)
  opts = opts or {}
  opts.id = opts.id or id
  return Comms.new(bus:_endpoint(id), opts)
end

-- Spy nav: only the methods the worker calls.
local function stubNav(pose)
  local n = { _pose = pose or { x = 0, y = 0, z = 0, h = 0 }, returnCalls = 0 }
  function n:getPose() return self._pose end
  function n:getFuelLevel() return 1000 end
  function n:returnTo(_) self.returnCalls = self.returnCalls + 1; return true end
  return n
end

-- Stub quarry factory: run() calls onProgress `calls` times (aborting if it ever
-- returns false), then returns success or the given failure reason.
local function stubFactory(calls, result)
  return function(_nav, opts)
    return {
      run = function(_self, spec)
        for i = 1, calls do
          if opts.onProgress then
            local cont = opts.onProgress({
              cells = i, layersDone = 1, dumps = 0,
              pose = { x = i, y = 0, z = 0, h = 0 }, fuel = 1000,
              width = spec.width, length = spec.length, depth = spec.depth,
            })
            if cont == false then return false, "aborted", { cellsCleared = i } end
          end
        end
        if result == nil or result == "ok" then
          return true, { cellsCleared = calls }
        end
        return false, result, { cellsCleared = calls }
      end,
    }
  end
end

-- Drain a comms inbox, counting message types.
local function drainCounts(comms)
  local c = {}
  while true do
    local m = comms:receive(0)
    if not m then break end
    c[m.type] = (c[m.type] or 0) + 1
    c["_last_" .. m.type] = m
  end
  return c
end

--------------------------------------------------------------------------------
-- 1. register broadcasts pose
--------------------------------------------------------------------------------
local function s01_register_broadcasts()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local w = Worker.new(wire(bus, 1, { role = "turtle" }), stubNav({ x = 5, y = 1, z = 0, h = 2 }),
    stubFactory(0, "ok"), { label = "Digger" })
  w:register()
  local reg = control:receive(1)
  ok(reg ~= nil and reg.type == "REGISTER", "s01: control got REGISTER")
  eq(reg and reg.from, 1, "s01: from worker 1")
  ok(reg ~= nil and reg.payload.pos.x == 5, "s01: carried pose")
  ok(reg ~= nil and reg.payload.label == "Digger", "s01: carried the turtle's label")
end

--------------------------------------------------------------------------------
-- 2. assign runs the quarry and reports DONE
--------------------------------------------------------------------------------
local function s02_assign_runs_and_done()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local wcomms = wire(bus, 1, { role = "turtle" })
  local w = Worker.new(wcomms, stubNav(), stubFactory(20, "ok"), { progressEvery = 8 })
  control:assign(1, { id = "J1", width = 3, length = 3, depth = 2 })
  eq(w:step(1), "done", "s02: job ran to done")
  eq(wcomms.controlId, 0, "s02: worker learned controlId")
  local c = drainCounts(control)
  ok((c.PROGRESS or 0) > 0, "s02: control saw PROGRESS")
  ok(c.DONE == 1 and c._last_DONE.payload.job == "J1", "s02: control saw DONE for J1")
end

--------------------------------------------------------------------------------
-- 3. progress is throttled by progressEvery
--------------------------------------------------------------------------------
local function s03_progress_throttle()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local w = Worker.new(wire(bus, 1, { role = "turtle" }), stubNav(), stubFactory(20, "ok"),
    { progressEvery = 8 })
  control:assign(1, { id = "J1", width = 1, length = 1, depth = 1 })
  w:step(1)
  local c = drainCounts(control)
  -- 1 immediate (on accept) + 2 throttled (moves 8,16) + 1 final on success = 4
  eq(c.PROGRESS or 0, 4, "s03: immediate + 2 throttled + final PROGRESS")
end

--------------------------------------------------------------------------------
-- 4. CONTROL stop aborts mid-mine with NO error
--------------------------------------------------------------------------------
local function s04_control_stop_aborts()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local w = Worker.new(wire(bus, 1, { role = "turtle" }), stubNav(), stubFactory(20, "ok"),
    { progressEvery = 8 })
  control:assign(1, { id = "J1", width = 1, length = 1, depth = 1 })
  control:control(1, "stop") -- queued after the ASSIGN
  eq(w:step(1), "stopped", "s04: worker stopped by CONTROL stop")
  ok(w:isStopped(), "s04: isStopped true")
  local c = drainCounts(control)
  ok((c.ERROR or 0) == 0, "s04: no ERROR on a user stop")
end

--------------------------------------------------------------------------------
-- 5. CONTROL return sends the turtle home
--------------------------------------------------------------------------------
local function s05_control_return_goes_home()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local nav = stubNav({ x = 0, y = 1, z = 0, h = 0 })
  local w = Worker.new(wire(bus, 1, { role = "turtle" }), nav, stubFactory(20, "ok"),
    { progressEvery = 8 })
  control:assign(1, { id = "J1", width = 1, length = 1, depth = 1 })
  control:control(1, "return")
  eq(w:step(1), "stopped", "s05: worker stopped by CONTROL return")
  ok(nav.returnCalls >= 1, "s05: nav:returnTo was called")
end

--------------------------------------------------------------------------------
-- 6. a quarry failure is reported as ERROR
--------------------------------------------------------------------------------
local function s06_failure_reports_error()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local w = Worker.new(wire(bus, 1, { role = "turtle" }), stubNav(), stubFactory(5, "no_fuel"),
    { progressEvery = 8 })
  control:assign(1, { id = "J1", width = 1, length = 1, depth = 1 })
  eq(w:step(1), "error", "s06: worker reports error")
  local c = drainCounts(control)
  ok(c.ERROR == 1 and c._last_ERROR.payload.reason == "no_fuel" and c._last_ERROR.payload.job == "J1",
    "s06: control saw ERROR no_fuel for J1")
end

--------------------------------------------------------------------------------
-- 7. duplicate ASSIGN is ignored (and a completed job re-acks DONE)
--------------------------------------------------------------------------------
local function s07_dedup_duplicate_assign()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local w = Worker.new(wire(bus, 1, { role = "turtle" }), stubNav(), stubFactory(3, "ok"),
    { progressEvery = 8 })
  local job = { id = "J1", width = 1, length = 1, depth = 1 }
  control:assign(1, job)
  eq(w:step(1), "done", "s07: first assign done")
  control:assign(1, job)
  eq(w:step(1), "duplicate", "s07: duplicate ignored")
  local c = drainCounts(control)
  eq(c.DONE or 0, 2, "s07: DONE re-acked on duplicate")
end

--------------------------------------------------------------------------------
-- 8. sibling broadcasts are ignored
--------------------------------------------------------------------------------
local function s08_ignores_sibling_broadcasts()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local other = wire(bus, 2, { role = "turtle" })
  local w = Worker.new(wire(bus, 1, { role = "turtle" }), stubNav(), stubFactory(3, "ok"),
    { progressEvery = 8 })
  other:register({ x = 0, y = 0, z = 0, h = 0 }) -- broadcast lands in worker 1's inbox
  control:assign(1, { id = "J1", width = 1, length = 1, depth = 1 })
  eq(w:step(1), "idle", "s08: sibling REGISTER ignored")
  eq(w:step(1), "done", "s08: ASSIGN processed after ignoring sibling")
end

--------------------------------------------------------------------------------
-- 9. tick re-registers each idle cycle (heartbeat so dropped/early REGISTER heals)
--------------------------------------------------------------------------------
local function s09_reregisters_while_idle()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local w = Worker.new(wire(bus, 1, { role = "turtle" }), stubNav(), stubFactory(3, "ok"),
    { progressEvery = 8 })
  eq(w:tick(0), "idle", "s09: idle tick (no work waiting)")
  eq(w:tick(0), "idle", "s09: second idle tick")
  local c = drainCounts(control)
  eq(c.REGISTER or 0, 2, "s09: re-registered on each idle tick")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_register_broadcasts,
  s02_assign_runs_and_done,
  s03_progress_throttle,
  s04_control_stop_aborts,
  s05_control_return_goes_home,
  s06_failure_reports_error,
  s07_dedup_duplicate_assign,
  s08_ignores_sibling_broadcasts,
  s09_reregisters_while_idle,
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
