-- mockbus.lua — in-memory deterministic message bus for testing comms.lua off
-- Minecraft. The network analogue of mockturtle.lua.
--
-- Wire up N endpoints keyed by computer id sharing one bus; messages deliver
-- synchronously at send time (no clock, no threads) so scenarios are fully
-- ordered and reproducible. Endpoints satisfy the transport contract comms
-- depends on, called as PLAIN functions (bound closures, like mockturtle).
--
-- Test-facing helpers are `_`-prefixed so they can't be mistaken for the
-- transport API.

local MockBus = {}
MockBus.__index = MockBus

-- MockBus.new(cfg) -> bus
function MockBus.new(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, MockBus)
  self.inboxes = {} -- id -> FIFO array of { from, message, protocol }
  self.ids = {}     -- set of registered endpoint ids (broadcast recipients)
  self.log = {}     -- ordered traffic: { from, to, type, protocol, dropped }
  self.dropCalls = 0 -- next N send/broadcast CALLS to silently drop
  self.dropTo = {}  -- id -> N: drop next N copies destined for that id
  return self
end

--------------------------------------------------------------------------------
-- Delivery (internal; synchronous, deterministic)
--------------------------------------------------------------------------------

function MockBus:_logType(message)
  return type(message) == "table" and message.type or nil
end

function MockBus:_send(from, to, message, protocol)
  local dropped = false
  if self.dropCalls > 0 then
    self.dropCalls = self.dropCalls - 1
    dropped = true
  elseif (self.dropTo[to] or 0) > 0 then
    self.dropTo[to] = self.dropTo[to] - 1
    dropped = true
  end
  self.log[#self.log + 1] =
    { from = from, to = to, type = self:_logType(message), protocol = protocol, dropped = dropped }
  if not dropped then
    self.inboxes[to] = self.inboxes[to] or {}
    local inbox = self.inboxes[to]
    inbox[#inbox + 1] = { from = from, message = message, protocol = protocol }
  end
  -- rednet.send is fire-and-forget: it reports the modem accepted the packet,
  -- not that it was delivered. So a dropped packet still returns true.
  return true
end

function MockBus:_broadcast(from, message, protocol)
  -- A whole-call drop loses the broadcast for everyone.
  if self.dropCalls > 0 then
    self.dropCalls = self.dropCalls - 1
    self.log[#self.log + 1] =
      { from = from, to = nil, type = self:_logType(message), protocol = protocol, dropped = true }
    return nil
  end
  self.log[#self.log + 1] =
    { from = from, to = nil, type = self:_logType(message), protocol = protocol, dropped = false }
  for id in pairs(self.ids) do
    if id ~= from then -- no modem loopback: sender never receives its own broadcast
      local drop = (self.dropTo[id] or 0) > 0
      if drop then
        self.dropTo[id] = self.dropTo[id] - 1
      else
        self.inboxes[id] = self.inboxes[id] or {}
        local inbox = self.inboxes[id]
        inbox[#inbox + 1] = { from = from, message = message, protocol = protocol }
      end
    end
  end
  return nil
end

function MockBus:_deliver(id, protocol)
  local inbox = self.inboxes[id]
  if not inbox then return nil end
  for i = 1, #inbox do
    if inbox[i].protocol == protocol then
      local e = table.remove(inbox, i)
      return e
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Endpoint factory
--------------------------------------------------------------------------------

-- _endpoint(id) -> transport. Registers `id` and returns a transport table of
-- PLAIN-function closures (dot-callable, like the real rednet globals).
function MockBus:_endpoint(id)
  self.ids[id] = true
  self.inboxes[id] = self.inboxes[id] or {}
  local bus = self
  return {
    id = function() return id end,
    send = function(to, m, p) return bus:_send(id, to, m, p) end,
    broadcast = function(m, p) return bus:_broadcast(id, m, p) end,
    receive = function(p, _timeout)
      -- Empty queue -> nil immediately (models "timeout expired"; never sleeps).
      -- Capture into a local before returning (multi-return truncation).
      local e = bus:_deliver(id, p)
      if e == nil then return nil end
      return e.from, e.message
    end,
  }
end

--------------------------------------------------------------------------------
-- Test-facing authoring / assertion helpers
--------------------------------------------------------------------------------

function MockBus:_inbox(id)
  return self.inboxes[id] or {}
end

function MockBus:_pending(id)
  local inbox = self.inboxes[id]
  return inbox and #inbox or 0
end

-- Drop the next n send/broadcast CALLS network-wide (models lost packets).
function MockBus:_dropNext(n)
  self.dropCalls = self.dropCalls + (n or 1)
  return self
end

-- Drop the next n copies destined for a specific id.
function MockBus:_dropTo(id, n)
  self.dropTo[id] = (self.dropTo[id] or 0) + (n or 1)
  return self
end

function MockBus:_traffic()
  return self.log
end

function MockBus:_reset()
  self.inboxes = {}
  for id in pairs(self.ids) do self.inboxes[id] = {} end
  self.log = {}
  self.dropCalls = 0
  self.dropTo = {}
  return self
end

return MockBus
