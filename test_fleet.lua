-- test_fleet.lua — end-to-end integration: a Coordinator + N Workers over one
-- MockBus, each Worker driving a real Quarry against its own mockturtle world,
-- clearing a whole box together. Also covers reassignment on error and on
-- staleness. Deterministic + single-threaded (no real concurrency): the mock bus
-- delivers synchronously, receive(0) pops-or-nil immediately, and the driver
-- runs workers in a fixed order pumping coord:step() at defined points. The only
-- "time" is the fake clock the test advances explicitly.
--
-- Run:  lua test_fleet.lua

local Comms = require("comms")
local MockBus = require("mockbus")
local Coordinator = require("coordinator")
local Worker = require("worker")
local Nav = require("nav")
local Mock = require("mockturtle")
local Partition = require("partition")
local Quarry = require("quarry")

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

local function quarryFactory(nav, opts)
  return Quarry.new(nav, opts)
end

-- Build a worker at a strip: its own solid mock world over the strip region, nav
-- started at the strip origin, real Quarry factory. fuel nil -> unlimited.
local function buildWorker(bus, id, job, fuel)
  local pose = { x = job.origin.x, y = job.origin.y, z = job.origin.z, h = 0 }
  local m = Mock.new({ pose = pose, fuel = fuel })
  local r = job.region
  m:_fillBox(r.x0, r.y0, r.z0, r.x1, r.y1, r.z1, "minecraft:stone")
  local nav = Nav.new(m, pose)
  local comms = Comms.new(bus:_endpoint(id), { id = id, role = "turtle" })
  local w = Worker.new(comms, nav, quarryFactory, { progressEvery = 4 })
  return w, m
end

-- Step a worker until it finishes the job it was assigned (or a bounded cap).
-- Sibling REGISTER broadcasts return "idle"; the ASSIGN is within the first few.
local function runWorker(w)
  for _ = 1, 50 do
    local tag = w:step(0)
    if tag == "done" or tag == "error" or tag == "stopped" then return tag end
  end
  return "timeout"
end

-- Assert every cell of a region was dug and is now air.
local function assertRegionCleared(m, region, tag)
  local allDug, allAir = true, true
  for x = region.x0, region.x1 do
    for y = region.y0, region.y1 do
      for z = region.z0, region.z1 do
        if not m:_wasDug(x, y, z) then allDug = false end
        if m:_blockAt(x, y, z) ~= nil then allAir = false end
      end
    end
  end
  ok(allDug, tag .. ": every strip cell dug")
  ok(allAir, tag .. ": every strip cell now air")
end

-- Box whose origin y is the turtle START level (one above the box's top layer),
-- matching quarry's start-above geometry.
local function fleetBox(W)
  return { id = "q", origin = { x = 0, y = 1, z = 0 }, width = W, length = 2, depth = 2 }
end

--------------------------------------------------------------------------------
-- 1. a fleet of 3 clears the whole box
--------------------------------------------------------------------------------
local function s01_full_box_cleared_by_fleet()
  local box = fleetBox(6) -- 3 strips {2,2,2}
  local jobs = Partition.split(box, 3)
  local bus = MockBus.new()
  local coord = Coordinator.new(Comms.new(bus:_endpoint(0), { id = 0, role = "control" }),
    { clock = function() return 0 end, box = box, staleAfter = 100 })

  local workers, mocks = {}, {}
  for i, job in ipairs(jobs) do
    workers[i], mocks[i] = buildWorker(bus, i, job)
  end

  for _, w in ipairs(workers) do w:register() end
  coord:step()     -- drain roster
  coord:dispatch() -- assign one strip each
  for _, w in ipairs(workers) do
    eq(runWorker(w), "done", "s01: worker finished its strip")
  end
  coord:step()     -- drain all PROGRESS/DONE

  for i, job in ipairs(jobs) do
    assertRegionCleared(mocks[i], job.region, "s01 strip " .. i)
  end
  ok(coord:isComplete(), "s01: coordinator complete")
  ok(coord:allDone(), "s01: all strips done")
  local status = coord:getStatus()
  for i = 1, 3 do
    eq(status.turtles[i].state, "done", "s01: turtle " .. i .. " done in status")
    ok((status.turtles[i].mined or 0) > 0, "s01: turtle " .. i .. " reported mined")
  end
end

--------------------------------------------------------------------------------
-- 2. a strip whose turtle ERRORs is reassigned to a pre-placed spare
--------------------------------------------------------------------------------
local function s02_reassign_on_error()
  local box = fleetBox(4) -- 2 strips {2,2} (strips=2 leaves a spare)
  local jobs = Partition.split(box, 2)
  local bus = MockBus.new()
  local coord = Coordinator.new(Comms.new(bus:_endpoint(0), { id = 0, role = "control" }),
    { clock = function() return 0 end, box = box, strips = 2, staleAfter = 100 })

  -- worker 1 (strip 1) is fuel-starved so its quarry fails; worker 2 (strip 2)
  -- is fine; worker 3 is a spare pre-placed at strip 1's corner.
  local w1, m1 = buildWorker(bus, 1, jobs[1], 3)
  local w2, m2 = buildWorker(bus, 2, jobs[2])
  local w3, m3 = buildWorker(bus, 3, jobs[1]) -- spare over strip 1's region

  for _, w in ipairs({ w1, w2, w3 }) do w:register() end
  coord:step(); coord:dispatch() -- w1->strip1, w2->strip2, w3 idle

  eq(runWorker(w1), "error", "s02: fuel-starved worker errors")
  eq(runWorker(w2), "done", "s02: worker 2 finishes strip 2")
  coord:step() -- ERROR -> reassign strip 1 to the spare (w3)
  eq(runWorker(w3), "done", "s02: spare finishes strip 1")
  coord:step()

  assertRegionCleared(m3, jobs[1].region, "s02 strip 1 (spare)")
  assertRegionCleared(m2, jobs[2].region, "s02 strip 2")
  ok(coord:isComplete(), "s02: coordinator complete after reassign")
  eq(coord:getStatus().turtles[1].state, "error", "s02: worker 1 marked error")
  eq(coord:getStatus().turtles[3].state, "done", "s02: spare done")
  -- worker 1's own world was only partially cleared (expected)
  ok(m1 ~= nil, "s02: worker 1 mock exists (partial, not asserted cleared)")
end

--------------------------------------------------------------------------------
-- 3. a silent (stale) turtle's strip is reassigned to the spare
--------------------------------------------------------------------------------
local function s03_reassign_on_stale()
  local box = fleetBox(4)
  local jobs = Partition.split(box, 2)
  local bus = MockBus.new()
  local now = 0
  local coord = Coordinator.new(Comms.new(bus:_endpoint(0), { id = 0, role = "control" }),
    { clock = function() return now end, box = box, strips = 2, staleAfter = 5 })

  local w1 = buildWorker(bus, 1, jobs[1])          -- healthy but will "hang" (never stepped)
  local w2, m2 = buildWorker(bus, 2, jobs[2])
  local w3, m3 = buildWorker(bus, 3, jobs[1])      -- spare at strip 1

  for _, w in ipairs({ w1, w2, w3 }) do w:register() end
  coord:step(); coord:dispatch()

  eq(runWorker(w2), "done", "s03: worker 2 finishes strip 2")
  -- worker 1 never runs (simulating chunk-unload / hang); advance the clock.
  now = 100
  coord:step() -- drains w2 DONE, then liveness sweep marks w1 stale -> reassign
  eq(runWorker(w3), "done", "s03: spare finishes strip 1")
  coord:step()

  assertRegionCleared(m3, jobs[1].region, "s03 strip 1 (spare)")
  assertRegionCleared(m2, jobs[2].region, "s03 strip 2")
  ok(coord:isComplete(), "s03: complete after stale reassign")
  eq(coord:getStatus().turtles[1].state, "stale", "s03: worker 1 marked stale")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_full_box_cleared_by_fleet,
  s02_reassign_on_error,
  s03_reassign_on_stale,
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
