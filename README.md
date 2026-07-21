# cc-fleet-miner

A UI-driven fleet mining control system for **CC:Tweaked**, targeting the
**All the Mods 10** modpack (Minecraft 1.21.1, NeoForge). A dedicated control
computer with a monitor commands a small fleet (2–5) of mining turtles through
three patterns: **quarry** (clear a box), **branch/strip mine**, and **tunnel**
(single corridor).

> Working title — rename the repo/project freely.

---

## Why this repo is structured the way it is

Three principles drive every design decision here:

1. **World interaction is separated from logic.** Every `turtle.*` call (move,
   dig, inspect, fuel, inventory) lives behind an injectable backend in
   `nav.lua`. Mining logic never touches `turtle` directly. This is what lets
   the _same_ code run against a real turtle in Minecraft or a simulated voxel
   world in tests.
2. **Sim-first development.** Patterns and logic are built and validated in the
   mock world (`mockturtle.lua`) before anything loads in Minecraft. In-game
   iteration is slow; the simulator turns a multi-minute test into milliseconds.
3. **Collision avoidance by design.** The coordinator partitions work into
   non-overlapping regions structurally (column-strips for quarry, alternating
   ribs for branch mining, separate entry points for tunnels) rather than
   relying on fragile runtime coordination between turtles.

---

## Repo layout

| File              | Role                                                                        | Status   |
| ----------------- | --------------------------------------------------------------------------- | -------- |
| `nav.lua`         | Position/heading tracking + collision-safe movement; injectable backend     | ✅ done  |
| `mockturtle.lua`  | In-memory voxel world implementing the turtle API subset (gravity, bedrock) | ✅ done  |
| `test_nav.lua`    | 12-scenario test suite for `nav` against the mock world                     | ✅ 12/12 |
| `probe.lua`       | Real-turtle smoke test: a round trip that must close to origin              | ✅ done  |
| `update.lua`      | Pulls the latest files from GitHub onto an in-game computer/turtle          | ✅ done  |
| `quarry.lua`      | Quarry pattern generator (single-turtle box clear)                          | ✅ done  |
| `test_quarry.lua` | 11-scenario suite for `quarry` (coverage, dump, edge cases)                  | ✅ 11/11 |
| `mine.lua`        | In-game driver: run a quarry on a turtle (`mine <w> <l> <d>`)                | ✅ done  |
| `branch.lua`      | Branch/strip pattern generator                                              | ⬜ todo  |
| `tunnel.lua`      | Tunnel pattern generator                                                    | ⬜ todo  |
| `comms.lua`       | rednet messaging protocol (shared by control + turtles); injectable transport | ✅ done |
| `rednet_transport.lua` | Real rednet/os adapter for `comms` (the only file touching `rednet`)    | ✅ done  |
| `mockbus.lua`     | In-memory deterministic message bus for testing `comms`                     | ✅ done  |
| `test_comms.lua`  | 9-scenario suite for `comms` against the mock bus                            | ✅ 9/9   |
| `partition.lua`   | Pure box → column-strip splitter (structural collision avoidance)           | ✅ done  |
| `test_partition.lua` | 8-scenario suite for `partition`                                         | ✅ 8/8   |
| `coordinator.lua` | Control station: box queue, assign, track, reassign, controls, persistence  | ✅ done  |
| `test_coordinator.lua` | 21-scenario suite for `coordinator`                                    | ✅ 21/21 |
| `worker.lua`      | Turtle side: register, run quarry, report, pause/stop mid-mine              | ✅ done  |
| `test_worker.lua` | 13-scenario suite for `worker`                                              | ✅ 13/13 |
| `test_fleet.lua`  | End-to-end: coordinator + N workers clear a box (+ reassign)                | ✅ 3/3   |
| `store.lua` / `mockstore.lua` | Injectable disk persistence + in-memory test store              | ✅ done  |
| `test_store.lua`  | 6-scenario suite for the store contract                                     | ✅ 6/6   |
| `jobspec.lua`     | Pure job-setup validation (dims/pattern/count)                              | ✅ done  |
| `test_setup.lua`  | 7-scenario suite for `jobspec`                                              | ✅ 7/7   |
| `control.lua` / `setup.lua` | Interactive control station + on-screen job setup (plain terminal) | ✅ done  |
| `fleet.lua`       | In-game turtle driver (`fleet <x> <y> <z>`)                                 | ✅ done  |
| `ui.lua`          | Basalt monitor UI (mouse/buttons) — polish over the plain-terminal station  | ⬜ todo  |

---

## Conventions

- **Heading:** `0 = north (−Z)`, `1 = east (+X)`, `2 = south (+Z)`, `3 = west (−X)`.
  Coordinates match Minecraft/GPS axes.
- **No `turtle.*` outside `nav.lua`.** Everything goes through `nav`.
- **Every logic module ships with a `test_*.lua`** that runs against
  `mockturtle.lua` and passes under plain `lua` before it's considered done.
- **Modules return a table** and take injectable dependencies for testability.

---

## Develop & test (desktop — the fast loop)

No Minecraft required for logic work:

```bash
lua test_nav.lua        # expect: 12 passed, 0 failed
```

Plain Lua is enough for the tests. For higher fidelity (the real CC:Tweaked Lua
VM, terminal/monitor rendering), use **CraftOS-PC** (https://craftos-pc.cc) and
mount this folder so you can edit in VS Code and run instantly.

---

## Get code into Minecraft

1. Push this repo to GitHub.
2. Edit `BASE` in `update.lua` to your repo's raw-content URL (ending in `/`),
   e.g. `https://raw.githubusercontent.com/cpopson/ATM10-miningTurtles/master/`.
3. On a fresh in-game computer or turtle, bootstrap once:
   ```
   wget https://raw.githubusercontent.com/cpopson/ATM10-miningTurtles/master/update.lua update.lua
   update
   ```
4. After every push, just run `update` again.

CC:Tweaked has HTTP enabled by default and whitelists GitHub, so `wget` works
out of the box.

---

## In-game bring-up (current milestone)

Do this in **creative / a flat world** first — deploy to survival later with the
same code.

1. Place one **Mining Turtle** (Advanced Mining Turtle gives color output).
2. Fuel it: put coal/charcoal in a slot, run `refuel all`.
3. Pull the files (`update`), then run `probe`.
4. Watch it dig outward, turn around, and return. **PASS** means the turtle
   landed exactly on its start block facing its original heading — i.e. the real
   backend matches the sim and the heading convention is correct. A drift or
   wrong turn is a convention mismatch to fix in `nav.lua` before building more.

Deferred until needed:

- **GPS** — `nav` tracks from a known start pose, so GPS isn't required yet. Add
  it for absolute re-location after reboots (4 computers running `gps host`,
  placed high at known coordinates).
- **Modems / rednet / monitor** — nothing to coordinate with a single turtle.

---

## Run a quarry

Once `probe` passes, clear a box with **`mine.lua`** — a thin in-game driver
around the tested `quarry.lua` module.

1. Place the turtle at the **top corner** of the box you want dug — in the air,
   one block above the first layer to remove.
2. Fuel it (`refuel all`) and `update` to pull the latest files.
3. Run:
   ```
   mine <width> <length> <depth>
   ```
   e.g. `mine 3 3 5` clears a 3×3 area, 5 deep. It prints
   `DONE: cleared N cells, back at start`, or `ABORTED (reason)` if it hits
   bedrock or runs out of fuel.

**Geometry** — relative to how the turtle sits, the box extends **right** (`+X`)
for width, **behind** (`+Z`) for length, and **down** (`−Y`) for depth. The
turtle's own column is the entry/exit shaft; it returns to the start block when
finished.

`mine.lua` auto-`refuel`s and warns if fuel is short (it needs roughly
`width × length × depth` plus the return trip).

**Ender-chest auto-dump:** put an **Ender Chest in slot 16** and the turtle
dumps its loot into it in place whenever the other 15 slots fill up, then keeps
mining — no trip home. Pair that chest with one at your base (feeding a hopper /
ME import bus / RS importer) and the loot streams straight into storage. With no
ender chest present it still mines, but overflow drops on the ground once full.

---

## Messaging (comms)

`comms.lua` is the typed message pipe between the control computer and the
turtles. Just as `nav` hides `turtle`, `comms` hides `rednet` behind an
injectable transport, so it's tested off-Minecraft against `mockbus.lua`.
In-game it runs over a real modem via `rednet_transport.lua`.

### Setup (in-game)

Each machine needs a **modem** (wireless or ender) attached. Build a transport,
then a `comms`:

```lua
local Comms = require("comms")
local RednetTransport = require("rednet_transport")

-- open the modem on the side it's attached to ("left"/"right"/"top"/...)
local transport = RednetTransport.new("right")

local comms = Comms.new(transport, { role = "control" })  -- control computer
-- or:
local comms = Comms.new(transport, { role = "turtle" })   -- a turtle
```

All fleet traffic shares one named protocol (default `"ccfleet"`; override with
`opts.protocol`). Turtles are addressed by `os.getComputerID()`.

### The six messages (with their wrappers)

| Message    | Direction        | Wrapper                                     |
| ---------- | ---------------- | ------------------------------------------- |
| `REGISTER` | turtle → control | `comms:register(pose)` (broadcast)          |
| `ASSIGN`   | control → turtle | `comms:assign(turtleId, job)`               |
| `PROGRESS` | turtle → control | `comms:progress(pose, fuel, mined, jobId)`  |
| `DONE`     | turtle → control | `comms:done(jobId)`                         |
| `ERROR`    | turtle → control | `comms:reportError(reason, jobId)`          |
| `CONTROL`  | control → turtle | `comms:control(id, cmd)` / `comms:controlAll(cmd)` |

`cmd` is one of `pause` / `resume` / `stop` / `return` (see `Comms.CONTROLS`).

### Receiving

`comms:receive(timeout)` has a three-way return, so a receive loop never hangs
and bad packets are visibly rejected rather than crashing:

```lua
local msg, err = comms:receive(1)         -- wait up to 1 second
if msg then
  -- msg = { v, type, from, to, seq, payload }
  handle(msg.from, msg.type, msg.payload)
elseif err then
  print("dropped bad message: " .. err)   -- failed validation
else
  -- timeout: nothing arrived — loop again or do other work
end
```

### The typical handshake

1. A turtle boots and **broadcasts** `REGISTER` — it may not know the control
   id yet, so it learns it from the first `ASSIGN`/`CONTROL` it receives.
2. Control replies with `ASSIGN` carrying a job `{ id, pattern, region, origin }`.
3. The turtle sends `PROGRESS` every few blocks (this doubles as its heartbeat),
   then `DONE` when its region is clear, or `ERROR` if it gets stuck.
4. Control can steer one turtle with `control(id, cmd)` or the whole fleet with
   `controlAll(cmd)`.

### What comms does and doesn't do

`comms` is a **stateless codec + pipe**. Its one guarantee is that `receive`
never blocks past its timeout. It does **not** retry, ack, or track liveness —
that's the coordinator's job (idempotent, `job.id`-keyed re-assign; `PROGRESS`
as the heartbeat it times out on). Keeping that logic out of `comms` is what
makes `comms` deterministic and fully sim-testable.

---

## The control station

Run `control` on a computer with a modem. It walks an **on-screen job setup**
(pattern, box dimensions, origin, turtle count — add multiple boxes to a queue),
or offers to **resume** a saved job if the computer crashed mid-run. Then start
`fleet <x> <y> <z>` on each turtle.

While it runs, the dashboard shows every turtle (label or `#id`, state, fuel,
mined, job) and responds to live keys:

| Key | Action |
| --- | ------ |
| `P` | **Pause** the whole fleet (turtles park mid-strip; reversible) |
| `R` | **Resume** |
| `S` | **Stop** (terminal — turtles abort where they are) |
| `H` | **Home** — return all turtles, then stop |
| `Q` | Quit the station (turtles keep their last command) |

The coordinator saves its job-state to disk every pump, so a control-computer
reboot resumes automatically; turtles re-sync from their next heartbeat.

**Multi-box caveat:** each turtle mines relative to its own position, so a queue
of boxes tiles cleanly only when the boxes share an origin region (re-runs,
stacked layers). Boxes at *different* physical locations need the turtles
repositioned + restarted between them — full relocation waits on GPS.

Concurrency uses `parallel.waitForAny(comms, input, render)` — the CC-safe way to
receive rednet, read keys, and redraw at once without `os.sleep` dropping message
events. A **Basalt** mouse/button UI is a later polish pass over this.

---

## Design specs for upcoming work

### Message protocol (rednet)

> **Implemented** in `comms.lua` — see [Messaging (comms)](#messaging-comms)
> above for the API. This is the payload reference.

Control computer = server; turtles = clients keyed by `os.getComputerID()`;
communication over a single named protocol.

| Message    | Direction        | Payload                                |
| ---------- | ---------------- | -------------------------------------- |
| `REGISTER` | turtle → control | turtle id, position                    |
| `ASSIGN`   | control → turtle | job (pattern, region, origin)          |
| `PROGRESS` | turtle → control | position, fuel, blocks mined           |
| `DONE`     | turtle → control | job id                                 |
| `ERROR`    | turtle → control | reason                                 |
| `CONTROL`  | control → turtle | `pause` / `resume` / `stop` / `return` |

### Coordinator / partitioning

- **Quarry:** split the bounding box into column-strips by X range; each turtle
  clears its slab top-to-bottom — columns are never shared.
- **Branch/strip:** one turtle cuts the main tunnel, then each turtle takes
  alternating ribs (A: z = 0, 6, 12…; B: z = 3, 9, 15…).
- **Tunnel:** each turtle gets its own start point and heading.

### UI (Basalt on the monitor)

- **Dashboard screen:** one row per turtle — state, fuel bar, position, % done.
- **Job-setup screen:** pattern, origin, dimensions, turtle assignment, Start.
- **Global controls:** Pause / Resume / Stop / Return home.
- The control computer runs comms + UI concurrently via `parallel.waitForAny`.

### Persistence

- Each turtle writes its job + progress cursor to disk every few blocks; on boot
  it reloads and re-`REGISTER`s with the coordinator.
- Keep turtles chunk-loaded (chunky turtle / chunk loader) so they run while the
  player is away.

---

## Roadmap

1. ✅ `nav` + `mockturtle` + `test_nav` (12/12) + `probe` + `update`
2. ✅ Quarry pattern generator (+ sim tests) + `mine` driver + ender-chest auto-dump
3. ✅ Comms protocol (`comms` + `rednet_transport` + `mockbus` + `test_comms` 9/9)
4. ✅ Coordinator: partition + assign + track + reassign (`test_coordinator` 21/21, `test_fleet` 3/3)
5. ✅ Control station: multi-box queue, live Pause/Resume/Stop/Return, on-screen job setup, reboot persistence (`store` + `jobspec`)
6. ⬜ Branch + tunnel patterns (+ tests) ← **next**
7. ⬜ Basalt UI (mouse/buttons) over the plain-terminal station
8. ⬜ Turtle-side progress persistence (resume a strip mid-way, not from the top)
9. ⬜ Advanced Peripherals integration (Geo Scanner ore-seeking, ME/RS auto-dump)
