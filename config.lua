-- config.lua — central tuning knobs for the fleet.
--
-- The DRIVERS (fleet, control, mine, probe) read these and pass them into the
-- module constructors' opts. The logic modules keep their OWN fallback defaults
-- (e.g. `opts.staleAfter or 5`), so they stay standalone-testable without this
-- file — this is just the one place to tune a live deployment.
--
-- Change a value here, `update` on the turtles + control computer, and it takes
-- effect everywhere that reads it.

return {
  -- rednet protocol name shared by the control computer and every turtle.
  protocol = "ccfleet",

  -- Turtle idle re-register heartbeat, in seconds. While waiting for work a
  -- turtle re-announces itself this often so a dropped/early REGISTER heals.
  -- (Incoming ASSIGN/CONTROL still wake it immediately.)
  heartbeat = 10,

  -- Coordinator: reassign a turtle's strip after this many seconds of silence
  -- (no PROGRESS/REGISTER). Keep it comfortably above `heartbeat` and the
  -- typical time between PROGRESS pings.
  staleAfter = 30,

  -- Blocks mined between PROGRESS pings (also the worker's CONTROL-stop poll
  -- interval, so stop latency is at most this many blocks).
  progressEvery = 8,

  -- Inventory slot reserved for the Ender Chest used by quarry auto-dump.
  chestSlot = 16,

  -- Coordinator: reassignment attempts before a strip is marked permanently
  -- failed (so a hopeless job can't stall completion forever).
  maxAttempts = 3,

  -- Minimum fuel `probe` requires before it will run its round trip.
  minFuel = 8,
}
