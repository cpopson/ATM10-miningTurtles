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
| `test_quarry.lua` | 9-scenario suite for `quarry` against the mock world                        | ✅ 9/9   |
| `mine.lua`        | In-game driver: run a quarry on a turtle (`mine <w> <l> <d>`)                | ✅ done  |
| `branch.lua`      | Branch/strip pattern generator                                              | ⬜ todo  |
| `tunnel.lua`      | Tunnel pattern generator                                                    | ⬜ todo  |
| `comms.lua`       | rednet messaging protocol (shared by control + turtles)                     | ⬜ todo  |
| `coordinator.lua` | Fleet dispatcher: partition jobs, assign, track, reassign on failure        | ⬜ todo  |
| `ui.lua`          | Basalt monitor UI (dashboard + job setup)                                   | ⬜ todo  |
| `state.lua`       | Disk persistence + reboot/chunk-unload recovery                             | ⬜ todo  |

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

## Design specs for upcoming work

### Message protocol (rednet)

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
2. ⬜ Quarry pattern generator (+ sim tests) ← **next**
3. ⬜ Coordinator + comms protocol (fleet skeleton talks end-to-end)
4. ⬜ Branch + tunnel patterns (+ tests)
5. ⬜ Basalt UI (dashboard + job setup)
6. ⬜ State persistence + reboot recovery
7. ⬜ Advanced Peripherals integration (Geo Scanner ore-seeking, ME/RS auto-dump)
