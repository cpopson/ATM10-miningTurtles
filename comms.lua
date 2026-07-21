-- comms.lua — the rednet messaging layer for the fleet.
--
-- A dumb, typed pipe: envelopes, send/receive/broadcast over one named
-- protocol, plus validation. It is NOT the dispatch logic (partitioning, job
-- assignment, reassignment) — that's the coordinator, which uses comms.
--
-- Like nav.lua hides `turtle` behind an injected backend, comms hides `rednet`
-- and `os` behind an injected `transport`, so it runs against a mock bus off
-- Minecraft. NEVER call rednet.*/os.* here — the only file that does is the
-- rednet_transport adapter.
--
-- Transport contract (mock + real adapter both satisfy, called as PLAIN funcs):
--   transport.id() -> number
--   transport.send(toId, msg, protocol) -> bool        (fire-and-forget)
--   transport.broadcast(msg, protocol) -> nil          (all others, no self)
--   transport.receive(protocol, timeout) -> senderId, msg   (nil on timeout)

local Comms = {}
Comms.__index = Comms

Comms.VERSION = 1

-- The six protocol messages. value == key so the wire form is self-describing.
Comms.TYPES = {
  REGISTER = "REGISTER",
  ASSIGN   = "ASSIGN",
  PROGRESS = "PROGRESS",
  DONE     = "DONE",
  ERROR    = "ERROR",
  CONTROL  = "CONTROL",
}

-- CONTROL sub-commands.
Comms.CONTROLS = {
  PAUSE  = "pause",
  RESUME = "resume",
  STOP   = "stop",
  RETURN = "return",
}

-- Membership sets built once for O(1) validation.
local TYPE_SET = {}
for _, t in pairs(Comms.TYPES) do TYPE_SET[t] = true end
local CONTROL_SET = {}
for _, c in pairs(Comms.CONTROLS) do CONTROL_SET[c] = true end

-- Comms.new(transport, opts) -> comms
--   transport : REQUIRED transport instance (mock endpoint or rednet adapter).
--   opts : optional {
--       protocol  = "ccfleet",  -- single named protocol for all traffic
--       id        = <number>,   -- identity override; defaults to transport.id()
--       role      = "control"|"turtle"|nil,
--       controlId = <number>,   -- turtle side: hub id if known (else learned)
--   }
-- Does not touch the transport beyond reading identity, so tests start clean.
function Comms.new(transport, opts)
  assert(transport, "comms: transport is required")
  opts = opts or {}
  local self = setmetatable({}, Comms)
  self.transport = transport
  self.protocol = opts.protocol or "ccfleet"
  self.id = opts.id or transport.id()
  self.role = opts.role
  self.controlId = opts.controlId
  self.seq = 0
  return self
end

--------------------------------------------------------------------------------
-- Envelope build + validation
--------------------------------------------------------------------------------

-- build(type, payload, toId) -> env. Bumps the per-sender seq counter.
function Comms:build(msgType, payload, toId)
  self.seq = self.seq + 1
  return {
    v = Comms.VERSION,
    type = msgType,
    from = self.id,
    to = toId,
    seq = self.seq,
    payload = payload or {},
  }
end

-- validate(env) -> ok, err. STATIC (dot-call). Structural gate only.
function Comms.validate(env)
  if type(env) ~= "table" then return false, "not_a_table" end
  if env.v ~= Comms.VERSION then return false, "bad_version" end
  if type(env.type) ~= "string" or not TYPE_SET[env.type] then
    return false, "unknown_type"
  end
  if type(env.from) ~= "number" then return false, "bad_from" end
  if env.to ~= nil and type(env.to) ~= "number" then return false, "bad_to" end
  if type(env.seq) ~= "number" then return false, "bad_seq" end
  if type(env.payload) ~= "table" then return false, "bad_payload" end
  return true
end

-- validatePayload(env) -> ok, err. STATIC. Per-type required-key check, so a
-- malformed/typo'd payload is caught in tests rather than in-game. Assumes the
-- envelope already passed validate().
function Comms.validatePayload(env)
  local p = env.payload
  local t = env.type
  if t == Comms.TYPES.REGISTER then
    if type(p.pos) ~= "table" then return false, "bad_pos" end
  elseif t == Comms.TYPES.ASSIGN then
    if type(p.job) ~= "table" then return false, "bad_job" end
    if p.job.id == nil then return false, "bad_job_id" end
  elseif t == Comms.TYPES.PROGRESS then
    if type(p.pos) ~= "table" then return false, "bad_pos" end
    if p.fuel == nil then return false, "bad_fuel" end
    if type(p.mined) ~= "number" then return false, "bad_mined" end
  elseif t == Comms.TYPES.DONE then
    if p.job == nil then return false, "bad_job" end
  elseif t == Comms.TYPES.ERROR then
    if type(p.reason) ~= "string" then return false, "bad_reason" end
  elseif t == Comms.TYPES.CONTROL then
    if not CONTROL_SET[p.cmd] then return false, "bad_control_cmd" end
  end
  return true
end

--------------------------------------------------------------------------------
-- Send / broadcast / receive
--------------------------------------------------------------------------------

function Comms:send(toId, msgType, payload)
  local env = self:build(msgType, payload, toId)
  return self.transport.send(toId, env, self.protocol)
end

function Comms:broadcast(msgType, payload)
  local env = self:build(msgType, payload, nil)
  return self.transport.broadcast(env, self.protocol)
end

-- receive(timeout) -> msg, err. Three-way return:
--   timeout   -> nil, nil          (no packet within timeout; never hangs)
--   malformed -> nil, <reason>     (received but rejected by validate)
--   valid     -> env, nil          (the whole envelope table)
function Comms:receive(timeout)
  -- Capture into locals first — receive returns (sender, msg[, protocol]); a
  -- direct pass into another call would truncate the extra values.
  local from, raw = self.transport.receive(self.protocol, timeout)
  if from == nil then
    return nil, nil
  end
  local vok, verr = Comms.validate(raw)
  if not vok then
    return nil, verr
  end
  -- Trust the transport's routing over the self-reported field.
  raw.from = from
  -- Turtle side: learn the hub id from the first control->turtle message.
  if self.role == "turtle" and self.controlId == nil
      and (raw.type == Comms.TYPES.ASSIGN or raw.type == Comms.TYPES.CONTROL) then
    self.controlId = from
  end
  return raw, nil
end

--------------------------------------------------------------------------------
-- Convenience wrappers (thin — keep payload shapes un-typo-able)
--------------------------------------------------------------------------------

-- Turtle side. register is a BROADCAST so a fresh turtle that doesn't yet know
-- the hub id can still announce itself. `label` is optional (the turtle's
-- os.getComputerLabel(), read by the driver) so the dashboard can show names.
function Comms:register(pose, label)
  return self:broadcast(Comms.TYPES.REGISTER, { pos = pose, label = label })
end

function Comms:progress(pose, fuel, mined, jobId)
  return self:send(self.controlId, Comms.TYPES.PROGRESS,
    { pos = pose, fuel = fuel, mined = mined, job = jobId })
end

function Comms:done(jobId)
  return self:send(self.controlId, Comms.TYPES.DONE, { job = jobId })
end

function Comms:reportError(reason, jobId)
  return self:send(self.controlId, Comms.TYPES.ERROR, { reason = reason, job = jobId })
end

-- Control side.
function Comms:assign(toId, job)
  return self:send(toId, Comms.TYPES.ASSIGN, { job = job })
end

function Comms:control(toId, cmd)
  assert(CONTROL_SET[cmd], "comms: unknown control command " .. tostring(cmd))
  return self:send(toId, Comms.TYPES.CONTROL, { cmd = cmd })
end

function Comms:controlAll(cmd)
  assert(CONTROL_SET[cmd], "comms: unknown control command " .. tostring(cmd))
  return self:broadcast(Comms.TYPES.CONTROL, { cmd = cmd })
end

return Comms
