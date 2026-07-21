-- worker.lua — the turtle side of the fleet. Registers with the control
-- computer, waits for an ASSIGN, runs the quarry for its region while reporting
-- PROGRESS and honoring a CONTROL stop, then reports DONE (or ERROR).
--
-- Injectable deps only (no turtle.*/rednet.* here):
--   comms         : a Comms instance (role "turtle")
--   nav           : a Nav instance (the real world access)
--   quarryFactory : function(nav, quarryOpts) -> quarry   (so tests inject a stub)
--
-- The quarry is blocking, so the ONLY place a mining turtle can notice a CONTROL
-- stop is from inside the pattern — the worker folds a non-blocking poll into a
-- throttled onProgress hook (stop latency <= progressEvery blocks).

local Comms = require("comms") -- for the TYPES/CONTROLS constants only

local Worker = {}
Worker.__index = Worker

-- Worker.new(comms, nav, quarryFactory, opts) -> worker
--   opts = { progressEvery = 8, chestSlot = 16, jobOpts = <table|nil> }
function Worker.new(comms, nav, quarryFactory, opts)
  assert(comms, "worker: comms is required")
  assert(nav, "worker: nav is required")
  assert(quarryFactory, "worker: quarryFactory is required")
  opts = opts or {}
  local self = setmetatable({}, Worker)
  self.comms = comms
  self.nav = nav
  self.quarryFactory = quarryFactory
  self.progressEvery = opts.progressEvery or 8
  self.chestSlot = opts.chestSlot or 16
  self.jobOpts = opts.jobOpts
  self.seen = {}      -- jobId -> "running" | "done" | "failed"
  self.current = nil
  self.state = "idle" -- idle | mining | stopped
  self.abort = nil
  self.home = nil
  return self
end

-- Announce ourselves (broadcast, since we may not know the control id yet).
function Worker:register()
  self.home = self.nav:getPose()
  return self.comms:register(self.home)
end

function Worker:isStopped()
  return self.state == "stopped"
end

-- Build the onProgress hook for a running job: throttled PROGRESS + a CONTROL
-- stop/return poll that aborts the quarry (by returning false).
function Worker:_makeOnProgress(jobId)
  local counter = 0
  return function(info)
    counter = counter + 1
    if counter % self.progressEvery == 0 then
      self.comms:progress(info.pose, info.fuel, info.cells, jobId)
      local m = self.comms:receive(0) -- non-blocking CONTROL poll
      if m and m.type == Comms.TYPES.CONTROL then
        local cmd = m.payload.cmd
        if cmd == Comms.CONTROLS.STOP or cmd == Comms.CONTROLS.RETURN then
          self.abort = cmd
          return false
        end
      end
    end
    return true
  end
end

function Worker:_quarryOpts(onProgress)
  local o = { chestSlot = self.chestSlot, onProgress = onProgress }
  if self.jobOpts then
    for k, v in pairs(self.jobOpts) do
      if o[k] == nil then o[k] = v end
    end
  end
  return o
end

-- Run a freshly-assigned job to completion. Returns an event tag.
function Worker:_onAssign(job)
  local jobId = job.id
  if self.seen[jobId] then
    if self.seen[jobId] == "done" then
      self.comms:done(jobId) -- re-ack a DONE that may have been lost
    end
    return "duplicate"
  end
  self.seen[jobId] = "running"
  self.current = job
  self.state = "mining"
  self.abort = nil

  -- Tell control we've started right away, so the dashboard flips to "mining"
  -- without waiting for the first throttled progress tick.
  self.comms:progress(self.nav:getPose(), self.nav:getFuelLevel(), 0, jobId)

  local start = self.nav:getPose()
  local onProgress = self:_makeOnProgress(jobId)
  local quarry = self.quarryFactory(self.nav, self:_quarryOpts(onProgress))
  -- quarry:run returns (true, stats) on success, or (false, err, stats) on abort.
  local ok, res, stats = quarry:run({ width = job.width, length = job.length, depth = job.depth })

  if ok then
    self.seen[jobId] = "done"
    self.current = nil
    self.state = "idle"
    -- final telemetry so the coordinator's `mined` count is accurate
    self.comms:progress(self.nav:getPose(), self.nav:getFuelLevel(), res.cellsCleared, jobId)
    self.comms:done(jobId)
    return "done"
  elseif res == "aborted" then
    self.current = nil
    if self.abort == Comms.CONTROLS.RETURN then
      self.nav:returnTo(start)
    end
    self.state = "stopped"
    return "stopped"
  else
    self.seen[jobId] = "failed"
    self.current = nil
    self.state = "idle"
    self.comms:reportError(res, jobId)
    return "error"
  end
end

-- Handle a CONTROL received while idle.
function Worker:_onControl(cmd)
  if cmd == Comms.CONTROLS.STOP then
    self.state = "stopped"
  elseif cmd == Comms.CONTROLS.RETURN then
    if self.home then self.nav:returnTo(self.home) end
    self.state = "stopped"
  end
  -- pause/resume have no effect while idle (there's no job to suspend); mid-job
  -- pause is a known limitation deferred to the persistence milestone.
  return "control"
end

-- Receive and act on ONE message. Only ASSIGN/CONTROL are acted on; sibling
-- REGISTER/PROGRESS/DONE broadcasts are ignored. Returns an event tag.
function Worker:step(timeout)
  local msg = self.comms:receive(timeout)
  if not msg then return "idle" end
  if msg.type == Comms.TYPES.ASSIGN then
    return self:_onAssign(msg.payload.job)
  elseif msg.type == Comms.TYPES.CONTROL then
    return self:_onControl(msg.payload.cmd)
  end
  return "idle"
end

-- One idle cycle: re-announce ourselves, then process one message. The repeated
-- register is a heartbeat — because rednet is lossy and REGISTER may be sent
-- before control is listening, re-broadcasting until we get work makes a dropped
-- or early registration self-heal (and lets a rebooted turtle rejoin on its own).
-- During a quarry the turtle is busy inside step() and sends none.
function Worker:tick(timeout)
  self:register()
  return self:step(timeout)
end

-- In-game loop.
function Worker:run(opts)
  opts = opts or {}
  local timeout = opts.timeout or 2
  while self.state ~= "stopped" do
    self:tick(timeout)
  end
end

return Worker
