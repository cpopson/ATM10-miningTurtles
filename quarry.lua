-- quarry.lua — single-turtle box-clearing pattern generator.
--
-- Drives an injected `nav` to clear a W x L x D box, then returns to its start
-- pose. All world access goes through nav (no turtle.* here), so the whole
-- pattern is testable against mockturtle off-Minecraft.
--
-- Multi-turtle partitioning is the coordinator's job (later); this is a single
-- turtle clearing one box.
--
-- Geometry (pinned so coverage is unambiguous):
--   * Start pose S is captured from nav:getPose() at run() time — the caller has
--     already positioned the turtle. The turtle starts ONE BLOCK ABOVE the box's
--     min-X, min-Z top corner (it can't occupy a solid cell).
--   * The box = cells x in [S.x, S.x+W-1], z in [S.z, S.z+L-1], y in [S.y-D, S.y-1].
--   * The start cell (S.x, S.y, S.z) is the air entry/exit and is NOT in the box.
--
-- Heading convention: 0=N(-Z) 1=E(+X) 2=S(+Z) 3=W(-X). We steer with
-- nav:turnTo(absoluteHeading), never raw deltas.

local Quarry = {}
Quarry.__index = Quarry

-- Quarry.new(nav, opts) -> quarry
--   nav  : REQUIRED nav instance — the only world access.
--   opts : optional { } (reserved for future hooks, e.g. progress callbacks)
function Quarry.new(nav, opts)
  assert(nav, "quarry: nav is required")
  local self = setmetatable({}, Quarry)
  self.nav = nav
  self.opts = opts or {}
  return self
end

local function flip(h)
  return (h + 2) % 4
end

local function validate(spec)
  if type(spec) ~= "table" then return nil end
  local W, L, D = spec.width, spec.length, spec.depth
  local function isPosInt(n)
    return type(n) == "number" and n >= 1 and n == math.floor(n)
  end
  if not (isPosInt(W) and isPosInt(L) and isPosInt(D)) then return nil end
  return W, L, D
end

-- Sweep ONE already-entered layer in a serpentine (boustrophedon) pattern.
--   rowDir  : absolute heading a row is traversed along (2=+Z or 0=-Z)
--   stepDir : absolute heading of the one-cell step between rows (1=+X or 3=-X)
--   count   : callback bumped once per successful forward (cell entered)
-- Returns ok, err, lastRowDir. lastRowDir is the direction of the final row so
-- the caller can flip it for the next layer's first row.
local function sweepLayer(nav, W, L, rowDir, stepDir, count)
  local dir = rowDir
  for row = 1, W do
    nav:turnTo(dir)
    for _ = 1, L - 1 do -- L cells in a row = L-1 moves (already in the first)
      local ok, err = nav:forward()
      if not ok then return false, err, dir end
      count()
    end
    if row < W then -- step over into the next row
      nav:turnTo(stepDir)
      local ok, err = nav:forward()
      if not ok then return false, err, dir end
      count()
      dir = flip(dir) -- serpentine: next row runs the other way
    end
  end
  return true, nil, dir
end

-- quarry:run(spec)
--   spec = { width=W>=1, length=L>=1, depth=D>=1 }
-- Returns  true,  stats           on full clear + closed round trip
--          false, err, stats      on clean abort (stats.pose = stall pose)
function Quarry:run(spec)
  local nav = self.nav
  local W, L, D = validate(spec)
  if not W then
    return false, "bad_spec", nil
  end

  local S = nav:getPose()
  local cells = 0
  local layersDone = 0
  local function count() cells = cells + 1 end

  local function stats(pose)
    return {
      width = W, length = L, depth = D,
      layersDone = layersDone,
      cellsCleared = cells,
      pose = pose or nav:getPose(),
    }
  end

  -- Enter the top layer: down() digs the top-corner cell and descends into it.
  local ok, err = nav:down()
  if not ok then return false, err, stats() end
  count()

  local rowDir, stepDir = 2, 1
  for layer = 1, D do
    local sok, serr, endDir = sweepLayer(nav, W, L, rowDir, stepDir, count)
    if not sok then return false, serr, stats() end
    layersDone = layer

    if layer < D then
      local dok, derr = nav:down() -- descend into the next layer
      if not dok then return false, derr, stats() end
      count()
      -- Flip BOTH directions: after descending, the next layer sweeps back the
      -- way it came. Flipping only stepDir would walk the first row out of the
      -- box; endDir is the last row's direction, so flip it for the new first row.
      rowDir = flip(endDir)
      stepDir = flip(stepDir)
    end
  end

  -- Return home entirely through already-cleared cells: X then Z along the
  -- bottom layer, then straight up the cleared origin column. "xzy" avoids the
  -- ceiling over-dig that "yxz" (nav:returnTo's default) would cause.
  local rok, rerr = nav:goTo(S.x, S.y, S.z, "xzy")
  if not rok then return false, rerr, stats() end
  nav:turnTo(S.h)

  return true, stats(nav:getPose())
end

-- Ergonomic one-shot wrapper (the "pure function" form).
function Quarry.mine(nav, spec, opts)
  return Quarry.new(nav, opts):run(spec)
end

return Quarry
