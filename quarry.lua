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
-- Ender-chest auto-dump (optional): if the turtle is carrying an Ender Chest in
-- the reserved chest slot (default 16), the quarry dumps its loot into it in
-- place whenever the other 15 slots fill up, then resumes — no trip home. If no
-- ender chest is present, it mines without dumping (overflow drops on the floor).
--
-- Heading convention: 0=N(-Z) 1=E(+X) 2=S(+Z) 3=W(-X). We steer with
-- nav:turnTo(absoluteHeading), never raw deltas.

local Quarry = {}
Quarry.__index = Quarry

-- Loose match so it works regardless of the exact EnderStorage mod id.
local function isEnderChest(name)
  if type(name) ~= "string" then return false end
  local n = name:lower()
  return n:find("ender") ~= nil and n:find("chest") ~= nil
end

-- Quarry.new(nav, opts) -> quarry
--   nav  : REQUIRED nav instance — the only world access.
--   opts : optional { chestSlot = 16, chestMatch = fn(name)->bool }
function Quarry.new(nav, opts)
  assert(nav, "quarry: nav is required")
  opts = opts or {}
  local self = setmetatable({}, Quarry)
  self.nav = nav
  self.opts = opts
  self.chestSlot = opts.chestSlot or 16
  self.chestMatch = opts.chestMatch or isEnderChest
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

-- True if the reserved chest slot holds a matching ender chest.
function Quarry:_dumpAvailable()
  local d = self.nav:getItemDetail(self.chestSlot)
  return d ~= nil and self.chestMatch(d.name) == true
end

-- Dump every loot slot into an ender chest placed above the turtle, then break
-- the chest back into its reserved slot and restore the prior selection. The
-- turtle does not move. Returns ok, err.
function Quarry:_dump()
  local nav = self.nav
  local prev = nav:getSelectedSlot()

  nav:select(self.chestSlot)
  nav:digUp()                     -- clear the cell above (no-op if already air)
  local pok = nav:placeUp()       -- place the ender chest
  if not pok then
    nav:select(prev)
    return false, "dump_place_failed"
  end

  for s = 1, 16 do
    if s ~= self.chestSlot and nav:getItemCount(s) > 0 then
      nav:select(s)
      nav:dropUp()                -- teleport loot into the ender network
    end
  end

  nav:select(self.chestSlot)      -- retrieve the chest into its reserved slot
  local dok = nav:digUp()
  if not dok then
    return false, "dump_retrieve_failed"
  end
  nav:select(prev)
  return true
end

-- Sweep ONE already-entered layer in a serpentine (boustrophedon) pattern.
-- afterMove() is called after each successful forward; it returns ok, err (used
-- to fold in cell counting and the full-inventory dump). Returns ok, err, lastRowDir.
local function sweepLayer(nav, W, L, rowDir, stepDir, afterMove)
  local dir = rowDir
  for row = 1, W do
    nav:turnTo(dir)
    for _ = 1, L - 1 do -- L cells in a row = L-1 moves (already in the first)
      local ok, err = nav:forward()
      if not ok then return false, err, dir end
      local aok, aerr = afterMove()
      if not aok then return false, aerr, dir end
    end
    if row < W then -- step over into the next row
      nav:turnTo(stepDir)
      local ok, err = nav:forward()
      if not ok then return false, err, dir end
      local aok, aerr = afterMove()
      if not aok then return false, aerr, dir end
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
  local cells, layersDone, dumps = 0, 0, 0
  local dumpEnabled = self:_dumpAvailable()

  local function stats(pose)
    return {
      width = W, length = L, depth = D,
      layersDone = layersDone,
      cellsCleared = cells,
      dumps = dumps,
      pose = pose or nav:getPose(),
    }
  end

  -- Called after every successful move: count the cell, and dump if the loot
  -- slots are full. Returns ok, err so a failed dump aborts the quarry cleanly.
  local function afterMove()
    cells = cells + 1
    if dumpEnabled and nav:countEmptySlots(16, self.chestSlot) == 0 then
      local dok, derr = self:_dump()
      if not dok then return false, derr end
      dumps = dumps + 1
    end
    return true
  end

  -- Enter the top layer: down() digs the top-corner cell and descends into it.
  local ok, err = nav:down()
  if not ok then return false, err, stats() end
  local aok, aerr = afterMove()
  if not aok then return false, aerr, stats() end

  local rowDir, stepDir = 2, 1
  for layer = 1, D do
    local sok, serr, endDir = sweepLayer(nav, W, L, rowDir, stepDir, afterMove)
    if not sok then return false, serr, stats() end
    layersDone = layer

    if layer < D then
      local dok, derr = nav:down() -- descend into the next layer
      if not dok then return false, derr, stats() end
      local ok2, err2 = afterMove()
      if not ok2 then return false, err2, stats() end
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
