# Plan: quarry.lua — the first mining pattern (+ deploy the os.exit fix)

## Context

The foundation (`nav`, `mockturtle`, `test_nav`, `probe`, `update`) is built,
pushed, and green — `12 passed, 0 failed` on both desktop Lua 5.4 and, verified
via CraftOS-PC, the real CC:Tweaked (Cobalt ~5.1) VM. Running in CraftOS-PC
surfaced one real compat bug: CC's `os` table has no `os.exit`, so `test_nav`
crashed after printing its summary. That's **fixed locally** (guarded with
`if os.exit then os.exit(...) end`) but **not yet committed/pushed**, so the copy
on GitHub / computer 0 still crashes.

Per the roadmap (README + CLAUDE.md), the next milestone is the **quarry pattern
generator** — a single-turtle box-clearing routine that drives `nav` to clear a
W×L×D box, plus `test_quarry.lua` proving full coverage and a closed round trip
against `mockturtle`, sim-first before it ever loads in-game. Multi-turtle
partitioning is explicitly the coordinator's job later; quarry stays single-turtle.

## Golden rules that constrain this work

- **No `turtle.*`** — quarry drives the world ONLY through an injected `nav`.
- **Modules return a table, take injectable deps.**
- **Sim-first:** `test_quarry.lua` passes under plain `lua` before "done".
- **Lua 5.1/5.2 subset**; **never `os.exit` unguarded** (`if os.exit then ... end`).
- Heading: `0=N(-Z) 1=E(+X) 2=S(+Z) 3=W(-X)`; use `nav:turnTo(h)`, never raw deltas.

---

## Step 0 (prerequisite): deploy the os.exit fix

`test_nav.lua` is modified locally (the `os.exit` guard) and uncommitted; GitHub
`master` still has the buggy unguarded version. Commit + push it so computer 0 /
in-game get a clean `test_nav` after `update`. (Outward-facing — confirm at
execution.) Verify: on computer 0 run `update` then `test_nav` → `12 passed, 0
failed` with no crash.

## Step 1: `quarry.lua`

**Shape.** `Quarry.new(nav, opts) -> quarry` (metatable style, matches
`Nav.new`/`Mock.new`); instance method `quarry:run(spec)`. Optional ergonomic
wrapper `Quarry.mine(nav, spec, opts) = Quarry.new(nav, opts):run(spec)`. Do NOT
also define a bare `Quarry.run` — `function Quarry:run` already sets that key.

**Spec + geometry (pin exactly — the coverage tests depend on it):**

- `spec = { width=W>=1, length=L>=1, depth=D>=1 }`; validate ints ≥1 else
  `return false, "bad_spec"`.
- Capture start pose `S = nav:getPose()` at the top of `run` (caller has already
  positioned the turtle). The turtle starts **one block ABOVE** the box's
  **min-X, min-Z** top corner (required — it can't occupy a solid cell).
- **The box** = cells `x∈[S.x, S.x+W-1]`, `z∈[S.z, S.z+L-1]`, `y∈[S.y-D, S.y-1]`.
  The start cell `(S.x, S.y, S.z)` is the air entry/exit and is **NOT** in the box.

**Rely on nav's auto-dig — no explicit `nav:dig*` calls.** `nav:forward()`
auto-digs ahead, `nav:down()` auto-digs below before descending. The path enters
every box cell exactly once, so every cell gets dug by the mover entering it.
Explicit digs would double-work and desync the deterministic move count.

**Algorithm (boustrophedon / serpentine):**

- Two absolute headings: `rowDir ∈ {2 (+Z), 0 (-Z)}` init `2`; `stepDir ∈ {1 (+X),
  3 (-X)}` init `1`. `flip(h) = (h+2)%4`.
- Enter top layer: `nav:down()` (digs+enters top corner). Abort on `false`.
- For each of D layers: `sweepLayer(nav, W, L, rowDir, stepDir)` —
  for row = 1..W: `turnTo(dir)`; `forward()` × (L-1); if row<W: `turnTo(stepDir)`,
  `forward()` (step over), `dir = flip(dir)`. Returns `ok, err, lastRowDir`.
- Between layers (layer < D): `nav:down()`, then **flip BOTH** `rowDir` and
  `stepDir`. **Critical:** omitting the `rowDir` flip walks layer 2 out of the box
  (traced on 3×3×2). `sweepLayer` returns `lastRowDir`; descent flips it for the
  next layer's first row. Correct for any parity of W (verified W=1 and W=3).
- Edge cases fall out for free: W=1 (no step-over), L=1 (`for _=1,L-1` is zero
  moves, rows are pure step-overs), 1×1×D (sweep is a no-op; `down()`s dig the
  shaft), 1×1×1 (leading `down()` digs the one cell).

**Return home (pin the order):** `nav:goTo(S.x, S.y, S.z, "xzy")` then
`nav:turnTo(S.h)`. From the bottom-layer end corner this moves in X, then Z (both
through already-cleared bottom-layer air), then straight up the cleared origin
column into the start cell — **entirely inside the cleared box, zero over-dig**.
(`nav:returnTo(S)` also works but uses `"yxz"`, which over-digs the ceiling plane;
if used, tests must not assert the `y=S.y` plane is untouched.)

**Return contract + failure:** `true, stats` on success; `false, err, stats` on
abort, `err` = nav's verbatim error, `stats.pose` = stall pose. Any mover
returning `false` (`no_fuel`, `blocked_unbreakable`, `blocked_retry_exceeded`) →
immediate clean return; **no quarry-level retry loop** (nav already bounds
retries, so quarry can't hang). On abort quarry does **not** auto-return (may be
out of fuel / walled in) — reports in place; recovery is the coordinator's job.
`stats = { width, length, depth, layersDone, cellsCleared, pose }`, where
`cellsCleared` is bumped after each successful `forward`/`down`. Invariant on
success: `cellsCleared == W*L*D` (counts moves, not digs — gravel makes the dig
log larger while `cellsCleared` is unchanged). Determinism: no `os.time`/`random`.

## Step 2: `test_quarry.lua`

Mirror `test_nav.lua`'s harness exactly: `passed/failed`, `ok(cond,msg)`, `eq`,
`poseEq(nav,mock,x,y,z,h,msg)`, per-scenario functions, scenario-level pcall loop,
footer `print(scPassed.." passed, "..scFailed.." failed")` and
`if os.exit then os.exit(scFailed==0 and 0 or 1) end`. Add a local
`assertBoxCleared(m, sx,sy,sz, W,L,D)` that asserts each box cell `_wasDug` AND
`_blockAt==nil`. Default start `(0,1,0,h)` ⇒ box `x∈[0,W-1] z∈[0,L-1] y∈[1-D,0]`.

Scenarios:

1. `s01_full_coverage_3x3x2` — `_fillBox(0,-1,0,2,0,2,"minecraft:stone")`, run
   3×3×2. Assert `ok`, `layersDone==2`, `cellsCleared==18`, all 18 cells cleared,
   start cell `(0,1,0)` NOT dug, an out-of-box cell (e.g. `(-1,0,0)`) NOT dug.
2. `s02_returns_to_start_pose` — start `(0,1,0,1)` (heading E), solid 2×4×3;
   `poseEq` back to `(0,1,0,1)` (round trip closes AND heading restored).
3. `s03_single_row_1xN` — 1×5×2 solid: full coverage + closed loop.
4. `s04_single_column_Nx1` — 5×1×2 solid: full coverage + closed loop.
5. `s05_single_block_1x1x1` — only `(0,0,0)` dug, `cellsCleared==1`, back to `(0,1,0,0)`.
6. `s06_vertical_shaft_1x1xN` — 1×1×4 solid: `(0,0,0)..(0,-3,0)` dug, `(1,0,0)`
   untouched, closed loop.
7. `s07_fuel_exhaustion_partial` — solid 3×3×3, `fuel=8`. Assert `ok==false`,
   `err=="no_fuel"`, `layersDone<3`, `cellsCleared>0`, final pose ≠ start
   (terminates — proves no hang).
8. `s08_bedrock_floor_stops` — solid 3×3×3 (box `y∈[-2,0]`) + `_setBedrockPlane(-2)`,
   ample fuel. Assert `ok==false`, `err=="blocked_unbreakable"`, `layersDone==2`,
   `y=0` and `y=-1` fully cleared, dig log has no bedrock, no hang.
9. (optional) `s09_gravel_inside_box` — 3×3×2 with interior `_setGravel` + a gravel
   column; ample fuel. Assert full coverage, `cellsCleared==18`, `#_getDigLog()>18`.

## Step 3: sync list

Add `"quarry.lua"` and `"test_quarry.lua"` to the `FILES` list in `update.lua`
so they sync in-game (per CLAUDE.md).

---

## Verification

1. `lua test_quarry.lua` → `9 passed, 0 failed` (or 8 if s09 skipped). Primary gate.
2. `lua test_nav.lua` → still `12 passed, 0 failed` (no regression).
3. Real-VM check via CraftOS-PC (mount the repo, run both suites) → same results,
   no `os.exit`/`os`-table crash. Command shape already proven this session:
   `CraftOS-PC_console.exe -i N --headless --mount-ro /repo=<path> --exec "shell.run('/repo/test_quarry')"`.
4. Once green: commit + push `quarry.lua`, `test_quarry.lua`, the `update.lua`
   FILES edit, and the Step 0 `test_nav.lua` fix. Then `update` on computer 0.
5. (Deferred, in-game) drive a small real quarry once the coordinator exists; not
   part of this milestone.
