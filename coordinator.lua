-- coordinator.lua — the control computer's fleet dispatcher.
--
-- Partitions one quarry box into column-strips, ASSIGNs each to a turtle, tracks
-- PROGRESS/DONE/ERROR into a status table (for the UI), and reassigns a strip
-- when its turtle errors or goes silent. Drives an injected `comms`; a `clock`
-- is injected so liveness timeouts are deterministic in tests (no `os.*` here).
--
-- Non-blocking `step()` design: the runner calls `while not coord:isComplete()
-- do coord:step(); render() end`, and tests pump it deterministically.
--
-- Assignment is POSITION-MATCHED: a turtle quarries relative to its own pose, so
-- it must receive the job whose origin matches where it is physically placed
-- (the pre-placed-at-strip-corner deployment). A pre-placed spare at a strip's
-- corner is what lets a failed strip be reassigned correctly.

local Comms = require("comms")     -- TYPES only
local Partition = require("partition")

local Coordinator = {}
Coordinator.__index = Coordinator

-- Coordinator.new(comms, opts) -> coordinator
--   opts = { clock?, staleAfter?=5, box?, turtles?, expect?, maxAttempts?=3 }
function Coordinator.new(comms, opts)
  assert(comms, "coordinator: comms is required")
  opts = opts or {}
  local self = setmetatable({}, Coordinator)
  self.comms = comms
  self.staleAfter = opts.staleAfter or 5
  self.maxAttempts = opts.maxAttempts or 3
  self.expect = opts.expect
  self._hasClock = opts.clock ~= nil
  self._stepCount = 0
  self.clock = opts.clock or function() return self._stepCount end
  self.roster = {}   -- id -> { id, pose, label, at }
  self.status = {}   -- id -> { state, pos, fuel, mined, job, label, lastSeen }
  self.jobs = {}     -- jobId -> { job, status, assignedTo, attempts } (current box)
  self.queue = {}    -- FIFO of pending jobIds (current box)
  self.boxQueue = {} -- FIFO of pending box records
  self.currentBox = nil
  self._boxSeq = 0
  self.phase = "gather" -- gather | running | complete
  self.paused = false
  self.stopped = false
  self.failedCount = 0
  self.store = opts.store         -- injected persistence (nil = no persistence)
  self.stateName = opts.stateName or "coordinator"
  self._dirty = false
  if opts.turtles then
    for _, id in ipairs(opts.turtles) do
      self.status[id] = { state = "idle", lastSeen = self.clock() }
    end
  end
  -- Backward-compat: a single opts.box becomes a queue-of-one. Do NOT flush here
  -- -- if the driver calls restore(), the on-disk state must win over this seed.
  if opts.box then
    local b = opts.box
    b.pattern = b.pattern or "quarry"
    b.strips = b.strips or opts.strips
    b.id = b.id or self:_nextBoxId()
    self.boxQueue[1] = b
  end
  return self
end

function Coordinator:_nextBoxId()
  self._boxSeq = self._boxSeq + 1
  return "box" .. self._boxSeq
end

--------------------------------------------------------------------------------
-- Persistence plumbing (no-op when no store is injected)
--------------------------------------------------------------------------------

function Coordinator:_markDirty()
  self._dirty = true
end

-- The durable job-state snapshot (roster/status are rebuilt from live traffic).
function Coordinator:_snapshot()
  return {
    boxQueue = self.boxQueue,
    currentBox = self.currentBox,
    jobs = self.jobs,
    queue = self.queue,
    phase = self.phase,
    paused = self.paused,
    stopped = self.stopped,
    boxSeq = self._boxSeq,
    failedCount = self.failedCount,
    expect = self.expect,
  }
end

function Coordinator:_flush()
  if self.store and self._dirty then
    self.store.save(self.stateName, self:_snapshot())
    self._dirty = false
  end
end

-- Reload persisted job-state after a control-computer reboot. Call right after
-- new(), before any step(). Returns true if state was restored, false if fresh.
-- roster/status are NOT persisted -- they rebuild from re-REGISTER/PROGRESS; we
-- only seed a status entry per in-flight job so a dead assignee still ages to
-- stale (the resync itself happens in _handle: a still-mining turtle re-attaches
-- via PROGRESS, a rebooted one gets its job re-ASSIGNed on REGISTER).
function Coordinator:restore()
  if not self.store then return false end
  local snap = self.store.load(self.stateName)
  if not snap then return false end
  self.boxQueue = snap.boxQueue or {}
  self.currentBox = snap.currentBox
  self.jobs = snap.jobs or {}
  self.queue = snap.queue or {}
  self.phase = snap.phase or "gather"
  self.paused = snap.paused or false
  self.stopped = snap.stopped or false
  self._boxSeq = snap.boxSeq or 0
  self.failedCount = snap.failedCount or 0
  if snap.expect ~= nil then self.expect = snap.expect end
  self.roster = {}
  self.status = {}
  local now = self.clock()
  for jobId, j in pairs(self.jobs) do
    if (j.status == "assigned" or j.status == "mining") and j.assignedTo then
      self.status[j.assignedTo] = { state = j.status, job = jobId, lastSeen = now }
    end
  end
  self._dirty = false
  return true
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

function Coordinator:_ensureStatus(id)
  local st = self.status[id]
  if not st then
    st = { state = "idle", lastSeen = self.clock() }
    self.status[id] = st
  end
  return st
end

function Coordinator:_rosterIds()
  local ids = {}
  for id in pairs(self.roster) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

function Coordinator:_rosterCount()
  local n = 0
  for _ in pairs(self.roster) do n = n + 1 end
  return n
end

function Coordinator:_jobCount()
  local n = 0
  for _ in pairs(self.jobs) do n = n + 1 end
  return n
end

function Coordinator:_inQueue(jobId)
  for _, id in ipairs(self.queue) do
    if id == jobId then return true end
  end
  return false
end

-- First in-flight (assigned/mining) job currently held by turtle `id`, or nil.
function Coordinator:_jobAssignedTo(id)
  for jobId, j in pairs(self.jobs) do
    if j.assignedTo == id and (j.status == "assigned" or j.status == "mining") then
      return jobId
    end
  end
  return nil
end

function Coordinator:_poseMatches(id, origin)
  local r = self.roster[id]
  if not r or not r.pose then return false end
  return r.pose.x == origin.x and r.pose.y == origin.y and r.pose.z == origin.z
end

-- Turtles currently occupied by an assigned/mining job.
function Coordinator:_busySet()
  local busy = {}
  for _, j in pairs(self.jobs) do
    if (j.status == "assigned" or j.status == "mining") and j.assignedTo then
      busy[j.assignedTo] = true
    end
  end
  return busy
end

-- Pick a free turtle for `job`, preferring one whose pose matches the strip
-- origin and isn't `exclude` (the job's previous, suspected-bad assignee).
function Coordinator:_pickTurtle(job, exclude)
  local busy = self:_busySet()
  local matchOther, matchAny, anyOther, anyFree
  for _, id in ipairs(self:_rosterIds()) do
    if not busy[id] then
      local pm = self:_poseMatches(id, job.origin)
      if pm and id ~= exclude then matchOther = matchOther or id end
      if pm then matchAny = matchAny or id end
      if id ~= exclude then anyOther = anyOther or id end
      anyFree = anyFree or id
    end
  end
  return matchOther or matchAny or anyOther or anyFree
end

--------------------------------------------------------------------------------
-- Dispatch + assignment
--------------------------------------------------------------------------------

-- Add a box to the run queue. Does not dispatch (that happens via step's
-- auto-dispatch or _advance). Returns the box id.
function Coordinator:enqueue(box)
  box.pattern = box.pattern or "quarry"
  box.id = box.id or self:_nextBoxId()
  self.boxQueue[#self.boxQueue + 1] = box
  self:_markDirty()
  self:_flush()
  return box.id
end

-- Partition the current box across the roster and queue its strip-jobs, popping
-- the next box from boxQueue if none is current. One strip per turtle by default;
-- box.strips caps it lower so surplus turtles stay as reassignment spares.
function Coordinator:dispatch()
  if self.stopped then return 0 end
  if not self.currentBox then
    if #self.boxQueue == 0 then return 0 end
    self.currentBox = table.remove(self.boxQueue, 1)
  end
  local box = self.currentBox
  local n = box.strips or self:_rosterCount()
  local jobs = Partition.split(box, n)
  self.jobs = {}
  self.queue = {}
  for _, job in ipairs(jobs) do
    self.jobs[job.id] = { job = job, status = "pending", assignedTo = nil, attempts = 0 }
    self.queue[#self.queue + 1] = job.id
  end
  self.phase = "running"
  if not self.paused then self:_assignQueued() end
  self:_markDirty()
  return #jobs
end

-- True when every strip of the current box is terminal (done/failed/stopped).
function Coordinator:_currentBoxTerminal()
  if not self.currentBox then return false end
  if self:_jobCount() == 0 then return false end
  for _, j in pairs(self.jobs) do
    local s = j.status
    if s ~= "done" and s ~= "failed" and s ~= "stopped" then return false end
  end
  return true
end

-- When the current box finishes, pop+dispatch the next box, or mark complete.
function Coordinator:_advance()
  if self.paused or self.stopped then return end
  if not self:_currentBoxTerminal() then return end
  if #self.boxQueue > 0 then
    self.currentBox = nil
    self:dispatch()
  else
    self.phase = "complete"
  end
  self:_markDirty()
end

-- Assign as many queued jobs as there are free turtles.
function Coordinator:_assignQueued()
  if self.paused or self.stopped then return end
  local remaining = {}
  for _, jobId in ipairs(self.queue) do
    local rec = self.jobs[jobId]
    local pick = self:_pickTurtle(rec.job, rec.assignedTo)
    if pick then
      self.comms:assign(pick, rec.job)
      rec.status = "assigned"
      rec.assignedTo = pick
      local st = self:_ensureStatus(pick)
      st.state = "assigned"
      st.job = jobId
      st.lastSeen = self.clock()
      self:_markDirty() -- only a real assignment dirties durable state
    else
      remaining[#remaining + 1] = jobId
    end
  end
  self.queue = remaining
end

-- Requeue a job for reassignment (idempotent job.id; bounded attempts).
function Coordinator:_reassign(jobId)
  local j = self.jobs[jobId]
  if not j or j.status == "done" then return end
  j.attempts = j.attempts + 1
  if j.attempts > self.maxAttempts then
    j.status = "failed" -- permanent, so isComplete can't hang
    self.failedCount = self.failedCount + 1
    self:_markDirty()
    return
  end
  j.status = "pending" -- keep assignedTo as the previous assignee (for exclusion)
  if not self:_inQueue(jobId) then
    self.queue[#self.queue + 1] = jobId
  end
  self:_markDirty()
  self:_assignQueued()
end

--------------------------------------------------------------------------------
-- Message handling + liveness
--------------------------------------------------------------------------------

function Coordinator:_handle(msg)
  local from = msg.from
  local now = self.clock()
  local T = Comms.TYPES
  if msg.type == T.REGISTER then
    self.roster[from] = { id = from, pose = msg.payload.pos, label = msg.payload.label, at = now }
    local st = self:_ensureStatus(from)
    st.state = "idle"
    st.label = msg.payload.label
    st.lastSeen = now
    -- Resync after a coordinator reboot: if this turtle still holds an in-flight
    -- job (persisted), re-ASSIGN the SAME job.id to it (idempotent). Otherwise
    -- let a free turtle pick up queued work.
    local held = self:_jobAssignedTo(from)
    if held and not self.paused and not self.stopped then
      local rec = self.jobs[held]
      self.comms:assign(from, rec.job)
      rec.status = "assigned"
      rec.assignedTo = from
      st.state = "assigned"
      st.job = held
    elseif self.phase == "running" then
      self:_assignQueued()
    end
  elseif msg.type == T.PROGRESS then
    local st = self:_ensureStatus(from)
    st.state = "mining"
    st.pos = msg.payload.pos
    st.fuel = msg.payload.fuel
    st.mined = msg.payload.mined
    st.job = msg.payload.job
    st.lastSeen = now
    local j = self.jobs[msg.payload.job]
    if j and j.status ~= "done" then
      j.status = "mining"
      j.assignedTo = from
    end
  elseif msg.type == T.DONE then
    local st = self:_ensureStatus(from)
    local j = self.jobs[msg.payload.job]
    if j then j.status = "done" end
    st.state = "done"
    st.job = nil
    st.lastSeen = now
    self:_assignQueued()
  elseif msg.type == T.ERROR then
    local st = self:_ensureStatus(from)
    st.state = "error"
    st.lastSeen = now
    local jobId = msg.payload.job
    if jobId and self.jobs[jobId] and self.jobs[jobId].status ~= "done" then
      self:_reassign(jobId)
    end
  end
  -- unknown types ignored (harmless sibling traffic)
  self:_markDirty()
end

function Coordinator:_livenessSweep()
  -- Don't reassign a deliberately paused/stopped fleet whose turtles stop pinging.
  if self.paused or self.stopped then return end
  local now = self.clock()
  for _, st in pairs(self.status) do
    if (st.state == "mining" or st.state == "assigned") and st.lastSeen
        and (now - st.lastSeen) > self.staleAfter then
      st.state = "stale"
      if st.job then self:_reassign(st.job) end
    end
  end
end

--------------------------------------------------------------------------------
-- Global controls (broadcast a CONTROL command + set the run flag + persist)
--------------------------------------------------------------------------------

-- Reversible hold: no new strips dispatched, no box advance, liveness suspended,
-- boxQueue intact, in-flight turtles park mid-strip.
function Coordinator:pauseAll()
  self.comms:controlAll(Comms.CONTROLS.PAUSE)
  self.paused = true
  self:_markDirty()
  self:_flush()
end

function Coordinator:resumeAll()
  self.comms:controlAll(Comms.CONTROLS.RESUME)
  self.paused = false
  self:_assignQueued() -- catch up any strips held back while paused
  self:_markDirty()
  self:_flush()
end

-- Terminal abandon (STOP) / terminal go-home (RETURN): broadcast the command,
-- clear the queue, mark non-terminal jobs stopped, complete the run.
function Coordinator:_terminate(cmd)
  self.comms:controlAll(cmd)
  self.stopped = true
  self.boxQueue = {}
  for _, j in pairs(self.jobs) do
    if j.status ~= "done" and j.status ~= "failed" then j.status = "stopped" end
  end
  self.queue = {}
  self.phase = "complete"
  self:_markDirty()
  self:_flush()
end

function Coordinator:stopAll() self:_terminate(Comms.CONTROLS.STOP) end
function Coordinator:returnAll() self:_terminate(Comms.CONTROLS.RETURN) end

--------------------------------------------------------------------------------
-- Public loop / queries
--------------------------------------------------------------------------------

-- Drain all available messages, sweep liveness, drain the reassign queue,
-- auto-dispatch when the expected roster has gathered. Returns nProcessed.
--   waitTimeout : optional seconds the FIRST receive may block for. A driver
--     passes this so it can pace its loop on the receive itself instead of
--     os.sleep (which drops rednet events in CC). Default 0 = fully
--     non-blocking, so tests are unaffected.
function Coordinator:step(waitTimeout)
  if not self._hasClock then self._stepCount = self._stepCount + 1 end
  local n = 0
  local first = true
  while true do
    local t = first and waitTimeout or 0
    first = false
    local m, e = self.comms:receive(t)
    if m == nil and e == nil then break end -- inbox empty
    if m then
      self:_handle(m)
      n = n + 1
    end
  end
  self:_livenessSweep()
  self:_assignQueued()
  if self.phase == "gather" and not self.paused and not self.stopped
      and self.expect and self:_rosterCount() >= self.expect then
    self:dispatch()
  end
  if not self.paused and not self.stopped and self:_currentBoxTerminal() then
    self:_advance()
  end
  self:_flush()
  return n
end

function Coordinator:isComplete()
  if self.stopped then return true end
  if self.phase == "complete" then return true end
  if #self.boxQueue > 0 then return false end -- more boxes queued
  if not self.currentBox then return false end -- nothing dispatched yet
  if self:_currentBoxTerminal() then
    self.phase = "complete"
    self:_markDirty()
    self:_flush()
    return true
  end
  return false
end

function Coordinator:allDone()
  if self:_jobCount() == 0 then return false end
  for _, j in pairs(self.jobs) do
    if j.status ~= "done" then return false end
  end
  return true
end

function Coordinator:getRoster()
  local out = {}
  for id, r in pairs(self.roster) do
    out[id] = { id = r.id, pose = r.pose, label = r.label, at = r.at }
  end
  return out
end

function Coordinator:getStatus()
  local turtles = {}
  for id, st in pairs(self.status) do
    turtles[id] = {
      state = st.state, pos = st.pos, fuel = st.fuel,
      mined = st.mined, job = st.job, label = st.label, lastSeen = st.lastSeen,
    }
  end
  local jobs = {}
  for id, j in pairs(self.jobs) do
    jobs[id] = { status = j.status, assignedTo = j.assignedTo, attempts = j.attempts }
  end
  return {
    turtles = turtles, jobs = jobs, phase = self.phase,
    paused = self.paused, stopped = self.stopped,
    boxesQueued = #self.boxQueue, failedCount = self.failedCount,
    complete = self:isComplete(),
  }
end

return Coordinator
