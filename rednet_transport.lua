-- rednet_transport.lua — the real transport adapter for comms.lua.
--
-- This is the ONLY file that references `rednet` / `os`, keeping comms.lua as
-- grep-clean of them as nav.lua is of `turtle`. It returns a table of
-- plain-function closures satisfying the transport contract:
--
--   id() -> number
--   send(toId, msg, protocol) -> bool
--   broadcast(msg, protocol) -> nil
--   receive(protocol, timeout) -> senderId, msg   (nil on timeout)
--
-- `rednet` and `os` are injectable (via `deps`) so even this adapter can be
-- unit-tested against fakes if desired; they default to the real globals.

local RednetTransport = {}

-- RednetTransport.new(side, deps) -> transport
--   side : modem side ("left"/"right"/"top"/"bottom"/"front"/"back") to open.
--   deps : optional { rednet = <api>, os = <api> } — defaults to the globals.
function RednetTransport.new(side, deps)
  deps = deps or {}
  local rn = deps.rednet or rednet
  local o = deps.os or os
  assert(rn, "rednet_transport: rednet API unavailable")
  assert(o, "rednet_transport: os API unavailable")

  -- Open the modem so rednet can send/receive. Errors if no modem on `side`.
  if side then
    rn.open(side)
  elseif not rn.isOpen() then
    error("rednet_transport: no modem side given and no modem is open", 0)
  end

  return {
    id = function()
      return o.getComputerID()
    end,
    send = function(toId, msg, protocol)
      return rn.send(toId, msg, protocol)
    end,
    broadcast = function(msg, protocol)
      return rn.broadcast(msg, protocol)
    end,
    receive = function(protocol, timeout)
      -- rednet.receive returns (senderId, message, protocol); comms captures
      -- only the first two. On timeout it returns nil.
      return rn.receive(protocol, timeout)
    end,
  }
end

return RednetTransport
