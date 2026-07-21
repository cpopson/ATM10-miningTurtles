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
  self.box = opts.box
  self.strips = opts.strips -- fixed strip count; nil = one strip per rostered turtle
  self.staleAfter = opts.staleAfter or 5
  self.maxAttempts = opts.maxAttempts or 3
  self.expect = opts.expect
  self._hasClock = opts.clock ~= nil
  self._stepCount = 0
  self.clock = opts.clock or function() return self._stepCount end
  self.roster = {}  -- id -> { id, pose, at }
  self.status = {}  -- id -> { state, pos, fuel, mined, job, lastSeen }
  self.jobs = {}    -- jobId -> { job, status, assignedTo, attempts }
  self.queue = {}   -- FIFO of pending jobIds
  self.phase = "gather" -- gather | running | complete
  if opts.turtles then
    for _, id in ipairs(opts.turtles) do
      self.status[id] = { state = "idle", lastSeen = self.clock() }
    end
  end
  return self
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

-- Partition the box across the current roster and queue the jobs.
function Coordinator:dispatch()
  assert(self.box, "coordinator: no box configured")
  -- One strip per turtle by default; opts.strips caps it lower so surplus
  -- turtles stay as reassignment spares.
  local n = self.strips or self:_rosterCount()
  local jobs = Partition.split(self.box, n)
  self.jobs = {}
  self.queue = {}
  for _, job in ipairs(jobs) do
    self.jobs[job.id] = { job = job, status = "pending", assignedTo = nil, attempts = 0 }
    self.queue[#self.queue + 1] = job.id
  end
  self.phase = "running"
  self:_assignQueued()
  return #jobs
end

-- Assign as many queued jobs as there are free turtles.
function Coordinator:_assignQueued()
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
    return
  end
  j.status = "pending" -- keep assignedTo as the previous assignee (for exclusion)
  if not self:_inQueue(jobId) then
    self.queue[#self.queue + 1] = jobId
  end
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
    if self.phase == "running" then self:_assignQueued() end
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
end

function Coordinator:_livenessSweep()
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
  if self.phase == "gather" and self.expect and self:_rosterCount() >= self.expect then
    self:dispatch()
  end
  return n
end

function Coordinator:isComplete()
  if self.phase ~= "running" and self.phase ~= "complete" then return false end
  if self:_jobCount() == 0 then return false end
  for _, j in pairs(self.jobs) do
    if j.status ~= "done" and j.status ~= "failed" then return false end
  end
  self.phase = "complete"
  return true
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
  return { turtles = turtles, jobs = jobs, phase = self.phase, complete = self:isComplete() }
end

return Coordinator
