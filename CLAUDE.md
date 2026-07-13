# CLAUDE.md — cc-fleet-miner

UI-driven fleet mining control for **CC:Tweaked** on **All the Mods 10**
(Minecraft 1.21.1, NeoForge). A control computer + monitor commands 2–5 mining
turtles through quarry, branch/strip, and tunnel patterns. See `README.md` for
full design detail.

## Golden rules (do not break these)

- **Never call `turtle.*` outside `nav.lua`.** All movement, digging,
  inspection, fuel, and inventory go through `nav`'s injectable backend. This is
  the whole reason the code is testable off-Minecraft.
- **Sim-first.** Any new logic/pattern module MUST have a matching
  `test_*.lua` that runs against `mockturtle.lua` and passes under plain `lua`
  before it is considered done. Do not use in-game testing to find logic bugs.
- **Heading convention is fixed:** `0 = N (−Z)`, `1 = E (+X)`, `2 = S (+Z)`,
  `3 = W (−X)`. Coordinates match Minecraft/GPS axes.
- **Collision avoidance is structural**, not runtime — the coordinator assigns
  non-overlapping regions (column-strips / alternating ribs / separate entry
  points). Do not add runtime turtle-to-turtle pathfinding.
- **Modules return a table** and take injectable dependencies so they can be
  tested with a mock.

## Commands

- Run the test suite: `lua test_nav.lua` (expect `N passed, 0 failed`).
- Sync into the game: push to GitHub, then run `update` on the turtle/computer.
- Real-turtle smoke test: `probe` (must return to origin and print `PASS`).

## File map

- `nav.lua` — position/heading tracking + collision-safe movement (backend-injectable).
- `mockturtle.lua` — in-memory voxel world (turtle API subset; gravity, bedrock).
- `test_nav.lua` — 12-scenario suite for `nav`.
- `probe.lua` — in-game backend smoke test.
- `update.lua` — GitHub → in-game file sync (set `BASE` to the repo raw URL).

## When adding a module

1. Write the module with all world access via `nav`.
2. Add a `test_*.lua` that drives it against `mockturtle.lua`.
3. Add the new filename to the `FILES` list in `update.lua` so it syncs in-game.

## Current state

Foundation is done and green (`nav`, `mockturtle`, `test_nav` 12/12, `probe`,
`update`). **Next task: the quarry pattern generator (`quarry.lua`) with sim
tests** — a pure function that emits a move/dig sequence against `nav`, then a
`test_quarry.lua` that verifies coverage and final position in the mock world.
