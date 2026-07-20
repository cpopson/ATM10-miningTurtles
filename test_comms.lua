-- test_comms.lua — scenario suite for comms.lua driven against mockbus.lua.
-- Runs under plain `lua`; prints "N passed, M failed"; mirrors the test_nav /
-- test_quarry harness.
--
-- Run:  lua test_comms.lua

local Comms = require("comms")
local MockBus = require("mockbus")

local passed, failed = 0, 0

local function ok(cond, msg)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print("  FAIL: " .. msg)
  end
end

local function eq(actual, expected, msg)
  if actual == expected then
    ok(true, msg)
  else
    ok(false, msg .. " (got " .. tostring(actual) .. " want " .. tostring(expected) .. ")")
  end
end

-- Wire an endpoint on the bus into a Comms instance.
local function wire(bus, id, opts)
  opts = opts or {}
  opts.id = opts.id or id
  return Comms.new(bus:_endpoint(id), opts)
end

--------------------------------------------------------------------------------
-- 1. envelope build + validate round-trip
--------------------------------------------------------------------------------
local function s01_envelope_build_validate_roundtrip()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local env = control:build(Comms.TYPES.ASSIGN, { job = { id = "J1", pattern = "quarry" } }, 1)
  eq(env.v, 1, "s01: version stamped")
  eq(env.type, "ASSIGN", "s01: type")
  eq(env.from, 0, "s01: from = my id")
  eq(env.to, 1, "s01: to = target")
  ok(env.payload ~= nil, "s01: payload present")
  local env2 = control:build(Comms.TYPES.ASSIGN, { job = { id = "J2" } }, 1)
  ok(env2.seq > env.seq, "s01: seq increments")
  eq(Comms.validate(env), true, "s01: validate ok")
  eq(Comms.validatePayload(env), true, "s01: validatePayload ok")
end

--------------------------------------------------------------------------------
-- 2. unknown / malformed messages rejected
--------------------------------------------------------------------------------
local function s02_unknown_and_malformed_rejected()
  local function rejected(env, wantErr, msg)
    local okv, err = Comms.validate(env)
    ok(okv == false and err == wantErr, msg .. " (err=" .. tostring(err) .. ")")
  end
  rejected(42, "not_a_table", "s02: non-table")
  rejected({ v = 2, type = "ASSIGN", from = 0, seq = 1, payload = {} }, "bad_version", "s02: bad version")
  rejected({ v = 1, type = "FOO", from = 0, seq = 1, payload = {} }, "unknown_type", "s02: unknown type")
  rejected({ v = 1, type = "ASSIGN", from = "x", seq = 1, payload = {} }, "bad_from", "s02: bad from")
  rejected({ v = 1, type = "ASSIGN", from = 0, seq = 1 }, "bad_payload", "s02: missing payload")

  local ctrlBad = { v = 1, type = "CONTROL", from = 0, to = 1, seq = 1, payload = { cmd = "halt" } }
  local pok, perr = Comms.validatePayload(ctrlBad)
  ok(pok == false and perr == "bad_control_cmd", "s02: bad control cmd (" .. tostring(perr) .. ")")

  local assignBad = { v = 1, type = "ASSIGN", from = 0, to = 1, seq = 1, payload = { job = {} } }
  local aok, aerr = Comms.validatePayload(assignBad)
  ok(aok == false and aerr == "bad_job_id", "s02: assign missing job.id (" .. tostring(aerr) .. ")")
end

--------------------------------------------------------------------------------
-- 3. directed send hits only the addressee
--------------------------------------------------------------------------------
local function s03_directed_send_addressing()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local t1 = wire(bus, 1, { role = "turtle", controlId = 0 })
  local t2 = wire(bus, 2, { role = "turtle", controlId = 0 })

  control:assign(1, { id = "J1" })
  local m1 = t1:receive(2)
  ok(m1 ~= nil and m1.type == "ASSIGN", "s03: turtle 1 got ASSIGN")
  ok(m1 ~= nil and m1.payload.job.id == "J1", "s03: correct job")
  eq(t2:receive(2), nil, "s03: turtle 2 got nothing")
  eq(bus:_pending(2), 0, "s03: turtle 2 inbox empty")
end

--------------------------------------------------------------------------------
-- 4. broadcast reaches all turtles but not the sender
--------------------------------------------------------------------------------
local function s04_broadcast_reaches_all_but_sender()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local t1 = wire(bus, 1, { role = "turtle", controlId = 0 })
  local t2 = wire(bus, 2, { role = "turtle", controlId = 0 })
  local t3 = wire(bus, 3, { role = "turtle", controlId = 0 })

  control:controlAll(Comms.CONTROLS.PAUSE)
  for i, t in ipairs({ t1, t2, t3 }) do
    local m = t:receive(2)
    ok(m ~= nil and m.type == "CONTROL" and m.payload.cmd == "pause", "s04: turtle " .. i .. " got pause")
  end
  eq(control:receive(2), nil, "s04: control did not receive its own broadcast")
end

--------------------------------------------------------------------------------
-- 5. receive timeout returns nil (no hang)
--------------------------------------------------------------------------------
local function s05_receive_timeout_returns_nil()
  local bus = MockBus.new()
  local c = wire(bus, 0)
  local m, err = c:receive(2)
  eq(m, nil, "s05: nil msg on timeout")
  eq(err, nil, "s05: nil err on timeout")
end

--------------------------------------------------------------------------------
-- 6. full REGISTER -> ASSIGN -> PROGRESS -> DONE handshake
--------------------------------------------------------------------------------
local function s06_full_handshake()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local turtle = wire(bus, 5, { role = "turtle" }) -- no controlId; must learn

  turtle:register({ x = 0, y = 0, z = 0, h = 0 })
  local reg = control:receive(2)
  ok(reg ~= nil and reg.type == "REGISTER", "s06: control got REGISTER")
  eq(reg and reg.from, 5, "s06: register from turtle 5")
  ok(reg ~= nil and reg.payload.pos ~= nil, "s06: register carried pos")

  control:assign(reg.from, { id = "J1", pattern = "quarry" })
  local asn = turtle:receive(2)
  ok(asn ~= nil and asn.type == "ASSIGN", "s06: turtle got ASSIGN")
  eq(turtle.controlId, 0, "s06: turtle learned controlId")

  turtle:progress({ x = 1, y = 0, z = 0, h = 0 }, 500, 3, "J1")
  turtle:done("J1")
  local prog = control:receive(2)
  ok(prog ~= nil and prog.type == "PROGRESS" and prog.payload.job == "J1", "s06: PROGRESS job J1")
  local don = control:receive(2)
  ok(don ~= nil and don.type == "DONE" and don.payload.job == "J1", "s06: DONE job J1")
end

--------------------------------------------------------------------------------
-- 7. multi-turtle addressing isolation
--------------------------------------------------------------------------------
local function s07_multi_turtle_addressing()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local t1 = wire(bus, 1, { role = "turtle", controlId = 0 })
  local t2 = wire(bus, 2, { role = "turtle", controlId = 0 })

  control:assign(1, { id = "J1" })
  control:assign(2, { id = "J2" })

  local m1 = t1:receive(2)
  ok(m1 ~= nil and m1.payload.job.id == "J1", "s07: turtle 1 gets J1")
  eq(t1:receive(2), nil, "s07: turtle 1 gets nothing more")
  local m2 = t2:receive(2)
  ok(m2 ~= nil and m2.payload.job.id == "J2", "s07: turtle 2 gets J2")
  eq(t2:receive(2), nil, "s07: turtle 2 gets nothing more")
end

--------------------------------------------------------------------------------
-- 8. CONTROL broadcast (pause) received + validated by all
--------------------------------------------------------------------------------
local function s08_control_broadcast_pause_all()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local turtles = {
    wire(bus, 1, { role = "turtle", controlId = 0 }),
    wire(bus, 2, { role = "turtle", controlId = 0 }),
    wire(bus, 3, { role = "turtle", controlId = 0 }),
  }
  control:controlAll(Comms.CONTROLS.PAUSE)
  for i, t in ipairs(turtles) do
    local m = t:receive(2)
    ok(m ~= nil and m.payload.cmd == "pause", "s08: turtle " .. i .. " got pause")
    ok(m ~= nil and Comms.validatePayload(m) == true, "s08: turtle " .. i .. " control payload valid")
  end
  eq(Comms.CONTROLS.PAUSE, "pause", "s08: PAUSE constant")
end

--------------------------------------------------------------------------------
-- 9. dropped ASSIGN then idempotent re-assign (retry lives above comms)
--------------------------------------------------------------------------------
local function s09_dropped_assign_then_resend()
  local bus = MockBus.new()
  local control = wire(bus, 0, { role = "control" })
  local t1 = wire(bus, 1, { role = "turtle", controlId = 0 })

  bus:_dropNext(1)
  control:assign(1, { id = "J1" })
  eq(t1:receive(2), nil, "s09: dropped ASSIGN not delivered")
  eq(bus:_pending(1), 0, "s09: turtle 1 inbox empty after drop")

  local sawDropped = false
  for _, e in ipairs(bus:_traffic()) do
    if e.type == "ASSIGN" and e.dropped then sawDropped = true end
  end
  ok(sawDropped, "s09: traffic log shows the dropped ASSIGN")

  -- Simulated coordinator retries the same idempotent job (not dropped now).
  control:assign(1, { id = "J1" })
  local m = t1:receive(2)
  ok(m ~= nil and m.payload.job.id == "J1", "s09: retry delivered J1")
  t1:done("J1")
  local don = control:receive(2)
  ok(don ~= nil and don.type == "DONE" and don.payload.job == "J1", "s09: control got DONE after retry")
end

--------------------------------------------------------------------------------

local scenarios = {
  s01_envelope_build_validate_roundtrip,
  s02_unknown_and_malformed_rejected,
  s03_directed_send_addressing,
  s04_broadcast_reaches_all_but_sender,
  s05_receive_timeout_returns_nil,
  s06_full_handshake,
  s07_multi_turtle_addressing,
  s08_control_broadcast_pause_all,
  s09_dropped_assign_then_resend,
}

local scPassed, scFailed = 0, 0
for i, scenario in ipairs(scenarios) do
  local before = failed
  local runOk, err = pcall(scenario)
  if runOk and failed == before then
    scPassed = scPassed + 1
  else
    scFailed = scFailed + 1
    if not runOk then
      print("  ERROR in scenario " .. i .. ": " .. tostring(err))
    end
  end
end

print(scPassed .. " passed, " .. scFailed .. " failed")
if os.exit then os.exit(scFailed == 0 and 0 or 1) end
