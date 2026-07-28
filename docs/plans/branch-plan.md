# Plan: branch.lua — the branch/strip pattern with ore-vein following

> **Status: COMPLETED — historical record, not current documentation.**
>
> This is the build plan that produced `branch.lua`, kept for the design
> rationale (why ribs are cut mid-sweep, the vein depth-first search, the
> `onProgress` excursion contract it leans on, and the error-remap channel).
> It describes work that is already done.
>
> | Planned | Shipped as |
> | ------- | ---------- |
> | Step 1 — `tunnel.lua` contract doc + `_lootMax` extraction + 2 tests | `test_tunnel` 15 → **17/17** |
> | Step 2 — `branch.lua` | done |
> | Step 3 — `test_branch.lua`, 24 scenarios | **24/24** |
> | Step 4 — `strip.lua` driver | done |
> | Step 5 — `config.lua` keys, `update.lua` FILES, docs | done, incl. `docs/strip.html` |
>
> For how branch is *used*, see [`docs/strip.html`](../strip.html). For what the
> code does now, read `branch.lua` and `test_branch.lua` — they are the source of
> truth, not this file.

## Context

`nav`, `quarry`, `tunnel` and the fleet layer were built and green. Roadmap item
7 was the branch/strip pattern — a spine corridor with **paired ribs** off both
sides at a fixed spacing, plus **ore-vein following**: the turtle inspects the
faces it exposes and mines out any connected vein before continuing.

Vein following was new ground — nothing in the repo read block identity — but
`nav:inspect*` already returned `{name, state, tags}` and `mockturtle` already
stored and returned `tags`, so **no mock changes were needed**.

Fleet integration was explicitly out of scope (roadmap item 8): `jobspec.lua`,
`partition.lua`, `worker.lua`, `coordinator.lua`, `fleet.lua`, `setup.lua` and
`control.lua` are untouched, exactly as `tunnel.lua` shipped standalone.

**`branch.lua` composes `tunnel.lua`** rather than reimplementing the sweep: a
branch mine is one spine tunnel plus 2N rib tunnels. Torches, floor-fill,
ender-dump, serpentine coverage and return-to-start all come free with 15 already
passing scenarios behind them, and the repo avoids a third verbatim copy of
`sweepLayer` and `_dump`.

## Golden rules that constrained this work

- **No `turtle.*`** outside `nav.lua` — branch drives the world only through the
  injected `nav`.
- **Sim-first:** `test_branch.lua` passes under plain `lua` before "done".
- **Lua 5.1/5.2 subset**; never `os.exit` unguarded.
- Heading `0=N(-Z) 1=E(+X) 2=S(+Z) 3=W(-X)`; steer only with `nav:turnTo(h)`.
- **`nav:back()` can never dig** (`nav.lua` passes `digFn = nil`), and gravel can
  settle into a just-vacated cell — so every retreat is `turnTo(flip(h));
  forward()` or `up()`/`down()`, all of which auto-dig.
- Movers auto-dig; patterns never call `nav:dig*` explicitly.

---

## Step 1: the `onProgress` contract

Composing tunnel means branch cannot see tunnel's internal per-cell hook. The
only per-move hook exposed is `opts.onProgress(info)` — so **both** vein
excursions and rib sub-runs happen inside a branch-supplied `onProgress`.

**This is sound.** `tunnel.lua`'s `sweepLayer` and `run` keep no cursor: every
decision re-reads `nav:getPose()` (`project()`) and every turn is an absolute
`turnTo`. A callback that moves the turtle and restores the **exact** pose —
position *and* heading — is therefore invisible to the sweep.

Three edits made that explicit and tested:

1. The contract is documented in `tunnel.lua`'s header.
2. `Tunnel:_lootMax(dumpEnabled)` was extracted from a local inside `run` so both
   `run` and branch's mid-vein dump derive the loot region identically.
3. Two `test_tunnel.lua` scenarios pin it — `s16` (a hand-rolled pose-restoring
   excursion leaves `cellsCleared` identical to `s03`) and `s17` (a whole nested
   `Tunnel:run` from inside the hook — **branch's rib mechanism, proven in
   isolation**).

## Step 2: `branch.lua`

### Spec and geometry

Facing-relative like tunnel, **not** absolute like quarry — branch composes a
facing-relative module, and a mixed frame is a bug factory.

```lua
spec = {
  length   = SL >= 1,  -- spine length in CELLS, INCLUDING the never-dug mouth
  ribReach = R  >= 0,  -- blocks each rib runs OUT from the spine (0 = plain tunnel)
  spacing  = SP >= 1,  -- spine cells between rib pairs
  height   = H  >= 1,  -- height of spine AND ribs
  width    = 1,        -- optional; MUST be 1 in v1, else "bad_spec"
}
```

| region | cells | sub-run |
| --- | --- | --- |
| spine | `l ∈ [0, SL-1]`, `w = 0`, `u ∈ [0, H-1]` | at `S`: `Tunnel:run{width=1, length=SL, depth=H}` |
| rib mouths | `l = k*SP`, `k = 1 .. floor((SL-1)/SP)` | — |
| right rib | `w ∈ [1, R]` | at `(l,0,0)` facing `(S.h+1)%4`: `Tunnel:run{width=1, length=R+1, depth=H}` |
| left rib | `w ∈ [-R, -1]` | at `(l,0,0)` facing `(S.h+3)%4`: same spec |

**Off-by-one:** tunnel's `length` includes its never-dug mouth, so a rib reaching
`R` blocks needs `length = R+1` — local `l'=0` is the spine cell, `l'=1..R` are
the new cells. `depth` means HEIGHT in tunnel's spec. `k` starts at 1, so the
operator's mouth cell never gets ribs.

`ribWidth` and spine `width > 1` were deliberately omitted (both make the two
sides asymmetric). `width` is *validated*, not silently ignored, so a later
version can lift it without breaking callers.

### Traversal: ribs are cut from inside the spine's hook

`branch:run` makes exactly **one** top-level call — the spine tunnel at `S`. Its
hook fires the rib pair when the current cell is a mouth. With `W = 1`,
`sweepLayer` runs a single row, so level 1 visits `(1,0,0) … (SL-1,0,0)` in
ascending order at heading `S.h`, hitting every mouth exactly once; levels 2..H
are all at `u ≥ 1`.

Why this and not "cut the spine, then walk back to each mouth":

- **Torches survive.** `serviceCell` places a spine torch at `u==1` via
  `placeDown()` — i.e. **into** the `u=0` corridor cell — during level 2. Cutting
  ribs during level 1 means the torch is placed *after* the rib exists, and
  nothing re-traverses `u=0` afterwards (tunnel's return is `"xzy"`, travelling
  at the top level and descending only the torch-free `l=0` column). **Sequential
  traversal digs every spine torch back out** when the turtle walks or descends
  to a mouth — with `spacing=4, torchEvery=8`, all of them. `test_branch` `s19`
  pins exactly this case, with mouths and torch positions coinciding.
- **Branch performs zero translation moves outside the vein DFS.** Its only
  motion is `turnTo` at rib mouths; the final return to `S` is entirely tunnel's.
- **`R = 0` degenerates to a vein-following tunnel** with no special case.

Rib order at a mouth is right, then left. `h = nav:getHeading()` is captured
before the pair and restored after — `sweepLayer` only re-orients at the top of a
row, so the heading **must** come back.

Safe by inspection: when a rib is cut, the spine above `u=0` is still solid, and
the rib's own `l'=0` column pre-digs `(l,0,u≥1)`. Tunnel counts **moves, not
digs**, so the spine's level-2 sweep just moves through air.

### Hook layering and the error channel

```
tunnel afterMove
  └─ branch hook
       1. st.cellsCleared + 1
       2. _report(info)          -- USER HOOK FIRST
       3. l,w,u = _project(...)
       4. _vein(...)             -- pose-restoring excursion
       5. if spine and mouth then _cutRibPair(l)
```

**User hook first, deliberately** — a stop request must not kick off a 128-move
excursion before it is seen, so stop latency stays bounded at one corridor move.
The documented consequence is that `info.veins` / `info.oreMined` lag by one.

**`info.cells` is overwritten** with the monotone `cellsCleared + oreMined`.
Tunnel restarts its own `cells` at 1 on every `run()`, and `worker.lua` forwards
`info.cells` straight into PROGRESS as the mined count — an unfixed passthrough
would make the dashboard count jump backwards at every rib.

Tunnel collapses every hook `false` to `"aborted"`, so branch stashes the real
reason and swaps it back in `_unstash`. Traced: a user stop stays `"aborted"`; a
vein or rib running dry surfaces as `"no_fuel"`; spine bedrock passes through as
`"blocked_unbreakable"` verbatim. **No new error strings** — a lost pose is
reported as `stats.poseLost` alongside the underlying error.

**The torch-slot hazard.** Tunnel derives its loot region from which reserved
slots are *enabled*, so a sub-run with `torchEvery == 0` would leave `torchSlot`
inside the loot region and `_dump` would teleport the turtle's own torches into
the ender network. (`dig.lua` escapes this only because it always passes
`fill = true`, which drops `lootMax` to 13.) Sub-runs therefore pass a `NEVER`
sentinel instead of 0. Covered by `s16`.

### Vein following

At each corridor cell, probe the 6 neighbours **minus any inside the current
sub-run's corridor box** (`_inside`) — that is what keeps excursions clear of
torches, filler and un-cut cells. In a 1-wide × 2-high rib this yields floor +
both walls at `u=0`, and ceiling + both walls at `u=1`.

- **DFS, move-in → recurse → move-out.** The recursion *is* the return path; no
  breadcrumb list. **No visited set is needed** — a cell is entered only if
  `inspect` reports ore, and entering mines it, so it reads as air forever after.
  Mining is the visited-marking.
- **Invariant:** every exit path — success, budget stop, propagated failure —
  lands back on the cell the frame started from, unless a *retreat* failed.
- **Entry vs retreat failure.** A failed entry leaves the pose untouched (`nav`
  updates the pose only on a confirmed move), so `blocked_unbreakable` is
  recorded as `veinSkipped` and the scan continues — refusing to kill a 26-rib
  job over one protected block. A failed retreat sets `poseLost` and aborts.
- **Budget.** `maxVein` bounds ore per excursion, and therefore excursion fuel at
  `2*maxVein`, so a separate depth cap is redundant.
- **Pre-excursion fuel gate** (`veinFuelFloor`, default `2*maxVein`): late in a
  job the turtle stops chasing veins and finishes blind rather than stranding
  itself off-corridor, which is the worst failure mode this design has.
- **Mid-vein dump** reuses `ctx.tunnel:_dump(ctx.tunnel:_lootMax())` — branch
  owns the Tunnel it is running inside, so this is reuse across a boundary
  already crossed, not a third copy of the routine.
- **Post-excursion floor re-patch** covers the hole a floor vein leaves behind.

**Scan cost.** `inspect*` is free; turning costs no fuel but ~0.4 s of wall clock
each, and checking both walls costs 4 turns per cell — roughly 3× wall clock on a
realistic run, at **identical fuel**. Hence `veinScan`: `"sides"` (default),
`"vertical"`, `"none"`. There is no cheaper complete scan: in a 1-wide corridor
each wall cell is adjacent to exactly one corridor cell, so nothing is scanned
twice or deferrable.

**`oreMatch`** mirrors the `chestMatch` precedent — a loose module-local default,
overridable via opts. The tag test is a **prefix scan** (so `c:ores/iron` matches
without enumeration); the name fallback uses `"_ore"`/`":ore"` rather than a bare
`"ore"`, which would false-positive on `core`/`score`/`bore`; ancient debris gets
an exact name test since it carries no vanilla ore tag.

### Success invariants

```
spineDone == true;  ribsDone == 2*ribPairs;  subRuns == 1 + 2*ribPairs
poseLost == false;  pose deep-equals S (including heading)
cellsCleared == (SL*H - 1) + 2*ribPairs*((R+1)*H - 1)
```

The last one is a **move** count, not a distinct-cell count: each rib re-enters
`H-1` spine cells on its way back down. Hand-verified on `SL=4, SP=2, R=2, H=2`
→ `7 + 2*5 = 17`, matching `16 distinct − 1 mouth + 2 re-entries`.

## Step 3: `test_branch.lua`

24 scenarios on `test_tunnel.lua`'s harness, with an **independent oracle** —
`worldOf`/`planCells`/`expectedCells` are re-derived locally from the spec, never
imported from `branch.lua`, so the suite tests behaviour rather than mirroring
the implementation.

Coverage: rib geometry and the `length = R+1` off-by-one; rotation under a
non-zero start heading (asserted against hard-coded world coords to catch a sign
error); the `k*SP <= SL-1` mouth boundary; full vein extraction and the
non-ore stopping edge; pose restoration mid-sweep (the recorded call sequence is
compared to an independently computed serpentine order, headings included);
`oreMatch` rejection and the untagged-modded-ore name fallback with decoys;
`maxVein` capping; `_inside` (a corridor made entirely of ore mines zero veins);
fuel exhaustion mid-vein; unbreakable-ore skipping; spine bedrock; mid-vein
dumping; the torch-slot regression; abort passthrough from the spine and from
inside a rib; torches surviving ribs; floor re-patch; both `veinScan` knobs;
`nav:back()` never being called (asserted by wrapping the mock); gravel; and
`bad_spec` rejection before any movement.

Three assertions were wrong on the first run and were corrected in the **test**,
not the code:

- An unbreakable candidate adjacent to a mined vein cell is legitimately probed
  **twice** (once from the corridor, once from inside the vein), so the scenario
  now keeps them apart to isolate the skip-and-continue behaviour.
- Stocking a single torch let the spine legitimately empty slot 15.
- Tunnel's `#digLog > cellsCleared` check does **not** carry over: branch's move
  count *exceeds* its distinct cell count, so the gravel scenario counts gravel
  digs directly instead.

## Steps 4–5: driver, config, sync list, docs

`strip.lua` (modelled on `dig.lua`) with a fuel estimate that includes a
vein-following allowance and warnings for `spacing == 1`, `height < 2` and the
`"sides"` wall-clock cost. `config.lua` gains `ribReach`, `ribSpacing`,
`veinFollow`, `maxVein`, `veinScan`. `update.lua` gains `branch.lua`,
`test_branch.lua`, `strip.lua`. Docs: `docs/strip.html` (on `dig.html`'s
9-section skeleton, with a top-down rib map instead of a side view), plus rows in
the root `README.md`, `docs/README.md` and `docs/index.html`.

---

## Verification

1. `lua test_branch.lua` → `24 passed, 0 failed`. **Primary gate.**
2. `lua test_tunnel.lua` → `17 passed, 0 failed` (was 15).
3. Every other suite unchanged and green (`nav` 12, `quarry` 12, `comms` 9,
   `coordinator` 21, `worker` 13, `partition` 8, `setup` 7, `store` 6, `fleet` 3).
4. `strip.lua` driven end to end offline against `mockturtle` with a stubbed
   `turtle` global — corridor count matched the oracle formula, veins were
   extracted, the torch survived, and the round trip closed.
5. Deferred: a real-VM check via CraftOS-PC, and the in-game smoke test
   (`strip 12 4 4 2` with slots 14/15/16 stocked).
6. Deferred: fleet integration (roadmap item 8) — `jobspec.lua`,
   `partition.lua`, `worker.lua`, `coordinator.lua` are untouched here.

## Rejected alternatives

| Alternative | Why rejected |
| --- | --- |
| Sequential traversal (spine, then walk to each mouth) | Destroys spine torches at `u=0`. Repair needs top-level travel + torch re-placement + a hand-rolled return: ~60 extra lines for identical coverage and 2× the spine travel. |
| Far→near rib ordering | Provably identical travel (`2*l_max` either way). Near→far also gives a monotone `ribsDone` cursor and a trivial test oracle. |
| A third `_dump` copy in `branch.lua` | Branch owns the `Tunnel` it runs inside; `ctx.tunnel:_dump()` is reuse across a boundary already crossed. |
| Explicit stack for the flood fill | The move-in/recurse/move-out shape *is* the return path. A stack must store the retreat per frame anyway; depth is bounded at 64. |
| A `visited` set | Unnecessary — entering a cell mines it, so it reads as air forever. |
| Aborting on an unbreakable ore candidate | Kills a whole job over one protected block. Entry failures leave the pose untouched, so skipping is provably safe. |
| Hard-failing on a mid-vein dump failure | Invents a second failure path for the same condition. Unwinding lets tunnel's own gate produce the canonical `dump_place_failed` next move. |
| `maxVeinDepth` alongside `maxVein` | Redundant — `maxVein` already bounds excursion fuel and walk-back distance. |
| Sub-runs with `torchEvery = 0` | Makes `torchSlot` part of the loot region and teleports the turtle's torches away. Use the `NEVER` sentinel. |
| A new error string for a lost pose | `stats.poseLost` plus the verbatim underlying error carries the same information with a smaller vocabulary. |
