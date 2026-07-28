-- branch.lua — single-turtle branch/strip mining pattern.
--
-- Cuts a SPINE corridor forward from the start pose and, every `spacing` cells,
-- a PAIR of RIBS running `ribReach` blocks out to the right and to the left.
-- While it digs it watches the faces it exposes and mines out any connected ore
-- VEIN it uncovers. All world access goes through the injected `nav` (no
-- turtle.* here), so the whole pattern is testable against mockturtle.
--
-- Geometry (relative to the turtle's FACING, like tunnel.lua):
--   * Start pose S is captured at run() time. The turtle stands IN the spine
--     mouth (l,w,u)=(0,0,0), which is never dug.
--   * l runs FORWARD (heading S.h), w runs RIGHT ((S.h+1)%4), u runs UP.
--   * Cell (l,w,u) maps to world
--       (S.x + l*Fx + w*Rx,  S.y + u,  S.z + l*Fz + w*Rz)
--   * spine     : l in [0, SL-1], w = 0,        u in [0, H-1]
--   * rib mouth : l = k*spacing for k = 1..floor((SL-1)/spacing)
--   * right rib : w in [1, R]   \  each cut as a tunnel of length R+1, whose
--   * left rib  : w in [-R, -1] /  own mouth IS the spine cell (never dug).
--
-- Composition: branch does not reimplement the sweep. It runs ONE Tunnel for
-- the spine and one Tunnel per rib, relying on tunnel.lua's documented
-- onProgress contract — a hook may move the turtle, including running a nested
-- Tunnel, as long as it restores the exact pose before returning. Torches,
-- floor-fill, ender-dump, coverage and return-to-start all come from tunnel.
--
-- Ribs are cut from INSIDE the spine's hook, during the u=0 level, rather than
-- after the spine finishes. That is what keeps spine torches alive: tunnel
-- places them from u=1 DOWN into the u=0 corridor cell during the second level,
-- so any traversal of u=0 afterwards would dig them straight back out.
--
-- Heading convention: 0=N(-Z) 1=E(+X) 2=S(+Z) 3=W(-X). We steer with
-- nav:turnTo(absoluteHeading), never raw deltas.

local Tunnel = require("tunnel")

local Branch = {}
Branch.__index = Branch

-- Copied from nav.lua — MUST match (used to project the turtle's pose back into
-- sub-run (l,w,u) coordinates and to aim the horizontal vein probes).
local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

-- A torch spacing that can never fire (probe l is always < this, and the l > 0
-- guard rules out l == 0). Sub-runs with torches DISABLED must still pass a
-- non-zero torchEvery: tunnel derives its loot region from which reserved slots
-- are ENABLED, so torchEvery == 0 would leave torchSlot inside the loot region
-- and _dump would teleport the turtle's own torches into the ender network.
local NEVER = 1000000000

-- Loose + overridable, like tunnel's isEnderChest. Prefer tags; fall back to the
-- name so modded ores carrying no common tag still register. Target is All the
-- Mods 10 / MC 1.21.1 / NeoForge, where the common-tag namespace is `c:`.
local function isOre(name, tags)
  if type(tags) == "table" then
    for tag, v in pairs(tags) do
      if v and type(tag) == "string" then
        local t = tag:lower()
        -- Prefix scan, not an exact set, so c:ores/iron and c:ores_in_ground/*
        -- match without enumerating every ore tag in the pack.
        if t:find("^c:ores") or t:find("^forge:ores")
            or t:find("^c:raw_materials") or t:find("^forge:raw_materials")
            or t:find("_ores$") then
          return true
        end
      end
    end
  end
  if type(name) ~= "string" then return false end
  local n = name:lower()
  -- "_ore"/":ore" rather than a bare "ore", which would match core/score/bore.
  return n:find("_ore", 1, true) ~= nil
      or n:find(":ore", 1, true) ~= nil
      or n:find("ancient_debris", 1, true) ~= nil
end

-- Vein probes as neighbour deltas in sub-run (l,w,u) space. Vertical probes need
-- no turn; horizontal ones are aimed with an absolute heading derived from the
-- sub-run's start heading, so they stay deterministic even though the turtle's
-- heading drifts inside a vein (a horizontal retreat leaves it facing backwards).
local VERT = {
  { dl = 0, dw = 0, du = -1 },
  { dl = 0, dw = 0, du = 1 },
}
local HORIZ = {
  { k = 0, dl = 1, dw = 0 },
  { k = 1, dl = 0, dw = 1 },
  { k = 2, dl = -1, dw = 0 },
  { k = 3, dl = 0, dw = -1 },
}

-- Branch.new(nav, opts) -> branch
--   nav  : REQUIRED nav instance — the only world access.
--   opts : optional {
--       chestSlot  = 16,          chestMatch = fn(name)->bool,
--       torchSlot  = 15,          torchEvery = 0,   -- SPINE torches (0 = none)
--       ribTorchEvery = 0,                          -- RIB torches   (0 = none)
--       fill       = false,       fillerSlot = 14,
--       oreMatch   = fn(name, tags)->bool,
--       veinFollow = true,        veinScan   = "sides"|"vertical"|"none",
--       maxVein    = 64,          veinFuelFloor = 2*maxVein,
--       veinProgress = true,      -- tick onProgress per ore block mined
--       onProgress = fn(info)->any -- returning exactly false aborts
--   }
function Branch.new(nav, opts)
  assert(nav, "branch: nav is required")
  opts = opts or {}
  local self = setmetatable({}, Branch)
  self.nav = nav
  self.opts = opts
  self.chestSlot = opts.chestSlot or 16
  self.chestMatch = opts.chestMatch -- nil -> tunnel's own isEnderChest default
  self.torchSlot = opts.torchSlot or 15
  self.torchEvery = opts.torchEvery or 0
  self.ribTorchEvery = opts.ribTorchEvery or 0
  self.fill = opts.fill == true
  self.fillerSlot = opts.fillerSlot or 14
  self.oreMatch = opts.oreMatch or isOre
  self.veinFollow = opts.veinFollow ~= false
  self.veinScan = opts.veinScan or "sides"
  self.maxVein = opts.maxVein or 64
  self.veinProgress = opts.veinProgress ~= false
  self.veinFuelFloor = opts.veinFuelFloor or (2 * self.maxVein)

  -- Guard the obvious misconfig: an enabled feature sharing a reserved slot.
  local anyTorch = self.torchEvery > 0 or self.ribTorchEvery > 0
  if anyTorch then
    assert(self.torchSlot ~= self.chestSlot, "branch: torchSlot clashes with chestSlot")
  end
  if self.fill then
    assert(self.fillerSlot ~= self.chestSlot, "branch: fillerSlot clashes with chestSlot")
    assert(self.fillerSlot ~= self.torchSlot, "branch: fillerSlot clashes with torchSlot")
  end
  return self
end

local function isPosInt(n)
  return type(n) == "number" and n >= 1 and n == math.floor(n)
end

local function isNonNegInt(n)
  return type(n) == "number" and n >= 0 and n == math.floor(n)
end

-- Returns SL, R, SP, H or nil. Validated BEFORE any movement.
local function validate(spec)
  if type(spec) ~= "table" then return nil end
  local SL, R, SP, H = spec.length, spec.ribReach, spec.spacing, spec.height
  local W = spec.width or 1
  if not (isPosInt(SL) and isNonNegInt(R) and isPosInt(SP) and isPosInt(H)) then
    return nil
  end
  -- v1 cuts 1-wide spines and ribs. Validated rather than silently ignored so a
  -- later version can lift it without breaking callers.
  if W ~= 1 then return nil end
  return SL, R, SP, H
end

--------------------------------------------------------------------------------
-- Stats
--------------------------------------------------------------------------------

function Branch:_stats(pose)
  local st = self.st
  return {
    length = self.SL, ribReach = self.R, spacing = self.SP, height = self.H,
    width = 1, ribPairs = self.ribPairs,
    spineDone = st.spineDone, ribsDone = st.ribsDone, subRuns = st.subRuns,
    cellsCleared = st.cellsCleared,
    dumps = st.dumps, torches = st.torches, fills = st.fills,
    veins = st.veins, oreMined = st.oreMined,
    veinSkipped = st.veinSkipped, veinCapped = st.veinCapped,
    veinDumps = st.veinDumps, veinsSkippedFuel = st.veinsSkippedFuel,
    dumpFailures = st.dumpFailures, poseLost = st.poseLost,
    pose = pose or self.nav:getPose(),
  }
end

-- Fold a finished sub-run's stats in. Only what branch cannot see itself:
-- cellsCleared is counted in the hook (single source, no lag, no double count).
function Branch:_fold(s)
  local st = self.st
  st.subRuns = st.subRuns + 1
  if type(s) ~= "table" then return end
  st.dumps = st.dumps + (s.dumps or 0)
  st.torches = st.torches + (s.torches or 0)
  st.fills = st.fills + (s.fills or 0)
end

--------------------------------------------------------------------------------
-- Error channel: tunnel collapses every hook `false` to "aborted", so branch
-- stashes the real reason on the way out and swaps it back in.
--------------------------------------------------------------------------------

function Branch:_unstash(terr)
  if terr == "aborted" and self._err then
    local e = self._err
    self._err = nil
    return e
  end
  self._err = nil
  return terr
end

--------------------------------------------------------------------------------
-- Sub-run wiring
--------------------------------------------------------------------------------

function Branch:_subOpts(ctx, torchEvery)
  return {
    chestSlot = self.chestSlot,
    chestMatch = self.chestMatch,
    torchSlot = self.torchSlot,
    torchEvery = (torchEvery > 0) and torchEvery or NEVER,
    fill = self.fill,
    fillerSlot = self.fillerSlot,
    onProgress = self:_hook(ctx),
  }
end

-- The turtle's offset from the sub-run's own start pose, in (l, w, u).
function Branch:_project(ctx, p)
  local S = ctx.S
  local Fx, Fz = DX[S.h], DZ[S.h]
  local Rx, Rz = DX[(S.h + 1) % 4], DZ[(S.h + 1) % 4]
  local dx, dz = p.x - S.x, p.z - S.z
  return dx * Fx + dz * Fz, dx * Rx + dz * Rz, p.y - S.y
end

-- True if (l,w,u) is a cell of the sub-run's own corridor box. Those are the
-- cells the sweep will dig itself, so a vein excursion must never enter one —
-- that is what keeps excursions clear of torches, filler and un-cut cells.
function Branch:_inside(ctx, l, w, u)
  return l >= 0 and l < ctx.L and w >= 0 and w < ctx.W and u >= 0 and u < ctx.H
end

-- Report to the caller's hook. Mutates tunnel's info in place (tunnel builds a
-- fresh table per call and discards it). Returns false iff the caller aborts.
function Branch:_report(info, ctx, inVein)
  if not self.opts.onProgress then return true end
  local st = self.st
  info = info or {}
  info.pose = info.pose or self.nav:getPose()
  info.fuel = info.fuel or self.nav:getFuelLevel()
  info.phase = ctx.phase
  info.inVein = inVein == true
  info.ribL, info.ribSide = ctx.ribL, ctx.side
  info.ribsDone, info.ribPairs = st.ribsDone, self.ribPairs
  info.veins, info.oreMined = st.veins, st.oreMined
  info.corridorCells = st.cellsCleared
  -- MUST overwrite: tunnel restarts its own `cells` at 1 for every run(), and
  -- worker.lua forwards info.cells straight into PROGRESS as the mined count —
  -- an unfixed passthrough would make the dashboard count jump backwards at
  -- every rib. This one is monotone across every sub-run and vein.
  info.cells = st.cellsCleared + st.oreMined
  info.sub = { width = ctx.W, length = ctx.L, depth = ctx.H }
  info.length, info.ribReach = self.SL, self.R
  info.spacing, info.height = self.SP, self.H
  return self.opts.onProgress(info) ~= false
end

-- The hook installed on every sub-run. Order matters: the USER hook runs first
-- so a stop request cannot kick off a full vein excursion before it is seen —
-- stop latency stays bounded at one corridor move. The documented consequence is
-- that info.veins / info.oreMined lag the current cell by one.
function Branch:_hook(ctx)
  return function(info)
    local st = self.st
    st.cellsCleared = st.cellsCleared + 1

    if not self:_report(info, ctx, false) then
      self._err = "aborted"
      return false
    end

    local l, w, u = self:_project(ctx, self.nav:getPose())

    local vok, verr = self:_vein(ctx, l, w, u)
    if not vok then
      self._err = verr
      return false
    end

    if ctx.phase == "spine" and self.R > 0 and u == 0 and w == 0 and l > 0
        and (l % self.SP) == 0 and not self.ribDone[l] then
      local rok, rerr = self:_cutRibPair(l)
      if not rok then
        self._err = rerr
        return false
      end
    end
    return true
  end
end

-- Cut the right rib then the left rib off spine cell l, restoring the sweep's
-- heading afterwards (sweepLayer only re-orients at the top of a row).
function Branch:_cutRibPair(l)
  local nav = self.nav
  local h = nav:getHeading()
  local sides = {
    { name = "right", h = (self.S.h + 1) % 4 },
    { name = "left", h = (self.S.h + 3) % 4 },
  }
  for _, side in ipairs(sides) do
    nav:turnTo(side.h) -- BEFORE run(): Tunnel captures its start pose on entry
    local rctx = {
      phase = "rib", S = nav:getPose(), W = 1, L = self.R + 1, H = self.H,
      ribL = l, side = side.name,
    }
    local t = Tunnel.new(nav, self:_subOpts(rctx, self.ribTorchEvery))
    rctx.tunnel = t -- the hook closes over rctx by reference, so this is visible
    local ok, a, b = t:run({ width = 1, length = self.R + 1, depth = self.H })
    if not ok then
      self:_fold(b)
      return false, self:_unstash(a)
    end
    self:_fold(a)
    self.st.ribsDone = self.st.ribsDone + 1
  end
  self.ribDone[l] = true
  nav:turnTo(h)
  return true
end

--------------------------------------------------------------------------------
-- Vein following
--------------------------------------------------------------------------------

function Branch:_probes(ctx)
  if ctx._probes then return ctx._probes end
  local p = { VERT[1], VERT[2] }
  if self.veinScan ~= "vertical" then
    for _, hp in ipairs(HORIZ) do
      p[#p + 1] = { dl = hp.dl, dw = hp.dw, du = 0, h = (ctx.S.h + hp.k) % 4 }
    end
  end
  ctx._probes = p
  return p
end

function Branch:_look(pr)
  local nav = self.nav
  if pr.du == 1 then return nav:inspectUp() end
  if pr.du == -1 then return nav:inspectDown() end
  nav:turnTo(pr.h)
  return nav:inspect()
end

function Branch:_enter(pr)
  local nav = self.nav
  if pr.du == 1 then return nav:up() end
  if pr.du == -1 then return nav:down() end
  nav:turnTo(pr.h)
  return nav:forward()
end

-- The inverse of _enter. Never nav:back(): it cannot dig (nav returns
-- "blocked_back"), and gravel can settle into the cell we just vacated.
function Branch:_retreat(pr)
  local nav = self.nav
  if pr.du == 1 then return nav:down() end
  if pr.du == -1 then return nav:up() end
  nav:turnTo((pr.h + 2) % 4)
  return nav:forward()
end

-- Cached per sub-run: does a chest back this run, and where does loot end?
function Branch:_lootRegion(ctx)
  if ctx._lootMax == nil then
    local t = ctx.tunnel
    ctx._dumpOk = t:_dumpAvailable()
    ctx._lootMax = t:_lootMax(ctx._dumpOk)
  end
  return ctx._dumpOk, ctx._lootMax
end

-- Dump mid-vein if the loot region just filled. Branch owns the Tunnel it is
-- running inside, so this reuses tunnel's dump rather than carrying a third copy
-- of it. Returns false on a failed dump.
function Branch:_veinDump(ctx)
  local dumpOk, lootMax = self:_lootRegion(ctx)
  if not dumpOk then return true end
  if self.nav:countEmptySlots(lootMax) > 0 then return true end
  if not ctx.tunnel:_dump(lootMax) then return false end
  self.st.veinDumps = self.st.veinDumps + 1
  return true
end

-- After an excursion that broke through the floor, patch the cell we stand on
-- back up. Top cell only — we want a floor, not a backfill.
function Branch:_repatchFloor(ctx, u)
  if not self.fill or u ~= 0 then return end
  local nav = self.nav
  if nav:detectDown() then return end
  if nav:getItemCount(self.fillerSlot) <= 0 then return end
  local prev = nav:getSelectedSlot()
  nav:select(self.fillerSlot)
  if nav:placeDown() then self.st.fills = self.st.fills + 1 end
  nav:select(prev)
end

-- Depth-first vein extraction from the cell the turtle currently occupies.
-- move-in -> recurse -> move-out, so the return path is the recursion itself and
-- no breadcrumb list is needed. No visited set is needed either: a cell is only
-- entered if inspect reports ore there, and entering mines it, so it reads as
-- air forever after — mining IS the visited-marking.
--
-- INVARIANT: on every exit path — success, budget stop, or propagated failure —
-- the turtle is back on the cell this frame started from, unless a RETREAT move
-- failed (which sets poseLost and aborts the run).
function Branch:_expand(ctx, l, w, u, budget)
  local st = self.st
  for _, pr in ipairs(self:_probes(ctx)) do
    if budget.stop then return true end
    if budget.left <= 0 then
      budget.capped, budget.stop = true, true
      return true
    end

    local nl, nw, nu = l + pr.dl, w + pr.dw, u + pr.du
    if not self:_inside(ctx, nl, nw, nu) then
      local present, data = self:_look(pr)
      if present and data and self.oreMatch(data.name, data.tags) == true then
        local mok, merr = self:_enter(pr)
        if not mok then
          -- A failed ENTRY leaves the pose untouched (nav only updates the pose
          -- on a confirmed move), so it is safe to skip and carry on. Refusing
          -- to kill a whole job over one protected block is the right trade.
          if merr == "no_fuel" then return false, merr end
          st.veinSkipped = st.veinSkipped + 1
        else
          budget.left = budget.left - 1
          budget.mined = budget.mined + 1
          st.oreMined = st.oreMined + 1

          local err = nil
          if not self:_veinDump(ctx) then
            -- Stop descending and unwind as success: tunnel's own dump gate hits
            -- the same failure on the next corridor move and reports the single
            -- canonical dump_place_failed. One failure path, not two.
            st.dumpFailures = st.dumpFailures + 1
            budget.stop = true
          elseif self.veinProgress and not self:_report(nil, ctx, true) then
            err = "aborted"
          else
            local rok, rerr = self:_expand(ctx, nl, nw, nu, budget)
            if not rok then err = rerr end
          end

          local bok, berr = self:_retreat(pr)
          if not bok then
            st.poseLost = true
            return false, err or berr
          end
          if err then return false, err end
        end
      end
    end
  end
  return true
end

-- One excursion anchored on the corridor cell the turtle occupies. Restores the
-- heading on the way out; _expand restores the position.
function Branch:_vein(ctx, l, w, u)
  if not self.veinFollow or self.veinScan == "none" then return true end
  local nav = self.nav
  local st = self.st

  -- Degrade gracefully rather than strand the turtle off-corridor deep
  -- underground: late in a job it stops chasing veins and finishes blind.
  if not nav:hasFuel(self.veinFuelFloor) then
    st.veinsSkippedFuel = st.veinsSkippedFuel + 1
    return true
  end

  local h0 = nav:getHeading()
  local budget = { left = self.maxVein, mined = 0, capped = false, stop = false }
  local ok, err = self:_expand(ctx, l, w, u, budget)
  nav:turnTo(h0)

  if budget.mined > 0 then
    st.veins = st.veins + 1
    self:_repatchFloor(ctx, u)
  end
  if budget.capped then st.veinCapped = st.veinCapped + 1 end
  if not ok then return false, err end
  return true
end

--------------------------------------------------------------------------------

-- branch:run(spec)
--   spec = { length=SL>=1, ribReach=R>=0, spacing=SP>=1, height=H>=1, width=1 }
--     length   — spine length in CELLS, INCLUDING the never-dug mouth
--     ribReach — blocks each rib runs OUT from the spine (0 = a plain tunnel)
-- Returns  true,  stats           on full clear + closed round trip
--          false, err, stats      on clean abort (stats.pose = stall pose)
--          false, "bad_spec", nil on an invalid spec (before any movement)
function Branch:run(spec)
  local nav = self.nav
  local SL, R, SP, H = validate(spec)
  if not SL then
    return false, "bad_spec", nil
  end

  local S = nav:getPose()
  self.S, self.SL, self.R, self.SP, self.H = S, SL, R, SP, H
  self.ribPairs = (R > 0) and math.floor((SL - 1) / SP) or 0
  self.ribDone = {}
  self._err = nil
  self.st = {
    cellsCleared = 0, dumps = 0, torches = 0, fills = 0,
    subRuns = 0, ribsDone = 0, spineDone = false,
    veins = 0, oreMined = 0, veinSkipped = 0, veinCapped = 0,
    veinDumps = 0, veinsSkippedFuel = 0, dumpFailures = 0, poseLost = false,
  }

  -- Exactly ONE top-level call. The ribs happen inside its hook, and so does the
  -- final return to S (tunnel's own goTo(...,"xzy") + turnTo) — branch performs
  -- no translation moves of its own outside the vein DFS.
  local ctx = { phase = "spine", S = S, W = 1, L = SL, H = H }
  local t = Tunnel.new(nav, self:_subOpts(ctx, self.torchEvery))
  ctx.tunnel = t
  local ok, a, b = t:run({ width = 1, length = SL, depth = H })
  if not ok then
    self:_fold(b)
    return false, self:_unstash(a), self:_stats()
  end
  self:_fold(a)
  self.st.spineDone = true
  return true, self:_stats()
end

-- Ergonomic one-shot wrapper (the "pure function" form).
function Branch.mine(nav, spec, opts)
  return Branch.new(nav, opts):run(spec)
end

return Branch
