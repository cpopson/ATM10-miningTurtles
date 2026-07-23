-- tunnel.lua — single-turtle corridor pattern generator.
--
-- Drives an injected `nav` to cut a straight W x L x H corridor the turtle
-- stands IN, then returns to its start pose. All world access goes through nav
-- (no turtle.* here), so the whole pattern is testable against mockturtle.
--
-- Geometry (relative to the turtle's FACING, unlike quarry's absolute box):
--   * Start pose S is captured from nav:getPose() at run() time. The turtle
--     already sits in the tunnel MOUTH — its own cell is corridor (l,w,u)=(0,0,0)
--     and is the entry/exit (never dug), so there is no initial entry move.
--   * length L runs FORWARD  (heading S.h),
--     width  W runs to the RIGHT ((S.h+1)%4),
--     height H runs UP        (+Y).
--   * Corridor cell (l,w,u) maps to world
--       (S.x + l*Fx + w*Rx,  S.y + u,  S.z + l*Fz + w*Rz)
--     with F = forward unit vector, R = right unit vector.
--
-- Features (each independently toggled by opts, all off-Minecraft-testable):
--   * Ender-chest auto-dump — an Ender Chest in the reserved chest slot dumps
--     loot in place when the loot region fills (reused from quarry, upward).
--   * Return to start — at the end, travel back to the mouth pose.
--   * Torch placement — a torch every `torchEvery` blocks along the length, on
--     the corridor floor (placed DOWN from the u=1 level, so needs H>=2).
--   * Floor filling — a filler block dropped DOWN over any gap under the floor.
--
-- Heading convention: 0=N(-Z) 1=E(+X) 2=S(+Z) 3=W(-X). We steer with
-- nav:turnTo(absoluteHeading), never raw deltas.

local Tunnel = {}
Tunnel.__index = Tunnel

-- Copied from nav.lua — MUST match (used to project the turtle's pose back into
-- corridor (l,w,u) coordinates for torch/floor-fill decisions).
local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

-- Loose match so it works regardless of the exact EnderStorage mod id.
local function isEnderChest(name)
  if type(name) ~= "string" then return false end
  local n = name:lower()
  return n:find("ender") ~= nil and n:find("chest") ~= nil
end

-- Tunnel.new(nav, opts) -> tunnel
--   nav  : REQUIRED nav instance — the only world access.
--   opts : optional {
--       chestSlot  = 16,           chestMatch = fn(name)->bool,
--       torchSlot  = 15,           torchEvery = 0,   -- 0 disables torches
--       fill       = false,        fillerSlot = 14,
--       onProgress = fn(info)->any -- returning exactly false aborts
--   }
function Tunnel.new(nav, opts)
  assert(nav, "tunnel: nav is required")
  opts = opts or {}
  local self = setmetatable({}, Tunnel)
  self.nav = nav
  self.opts = opts
  self.chestSlot = opts.chestSlot or 16
  self.chestMatch = opts.chestMatch or isEnderChest
  self.torchSlot = opts.torchSlot or 15
  self.torchEvery = opts.torchEvery or 0
  self.fill = opts.fill == true
  self.fillerSlot = opts.fillerSlot or 14
  -- Guard the obvious misconfig: an enabled feature sharing a reserved slot.
  if self.torchEvery > 0 then
    assert(self.torchSlot ~= self.chestSlot, "tunnel: torchSlot clashes with chestSlot")
  end
  if self.fill then
    assert(self.fillerSlot ~= self.chestSlot, "tunnel: fillerSlot clashes with chestSlot")
    if self.torchEvery > 0 then
      assert(self.fillerSlot ~= self.torchSlot, "tunnel: fillerSlot clashes with torchSlot")
    end
  end
  return self
end

local function flip(h)
  return (h + 2) % 4
end

local function validate(spec)
  if type(spec) ~= "table" then return nil end
  local W, L, H = spec.width, spec.length, spec.depth
  local function isPosInt(n)
    return type(n) == "number" and n >= 1 and n == math.floor(n)
  end
  if not (isPosInt(W) and isPosInt(L) and isPosInt(H)) then return nil end
  return W, L, H
end

-- True if the reserved chest slot holds a matching ender chest.
function Tunnel:_dumpAvailable()
  local d = self.nav:getItemDetail(self.chestSlot)
  return d ~= nil and self.chestMatch(d.name) == true
end

-- Dump every loot slot (1..lootMax) into an ender chest placed above the turtle,
-- then break the chest back into its reserved slot and restore the prior
-- selection. Reserved slots (> lootMax) are never touched. The turtle does not
-- move. Returns ok, err.
function Tunnel:_dump(lootMax)
  local nav = self.nav
  local prev = nav:getSelectedSlot()

  nav:select(self.chestSlot)
  nav:digUp()                     -- clear the cell above (no-op if already air)
  local pok = nav:placeUp()       -- place the ender chest
  if not pok then
    nav:select(prev)
    return false, "dump_place_failed"
  end

  for s = 1, lootMax do
    if nav:getItemCount(s) > 0 then
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
-- afterMove() is called after each successful forward; it returns ok, err.
-- Returns ok, err, lastRowDir. (Identical to quarry.lua's sweepLayer.)
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

-- tunnel:run(spec)
--   spec = { width=W>=1, length=L>=1, depth=H>=1 }   (depth is HEIGHT/up)
-- Returns  true,  stats           on full clear + closed round trip
--          false, err, stats      on clean abort (stats.pose = stall pose)
--          false, "bad_spec", nil on an invalid spec
function Tunnel:run(spec)
  local nav = self.nav
  local W, L, H = validate(spec)
  if not W then
    return false, "bad_spec", nil
  end

  local S = nav:getPose()
  local cells, levelsDone, dumps, torches, fills = 0, 0, 0, 0, 0
  local dumpEnabled = self:_dumpAvailable()
  local torchEnabled = self.torchEvery > 0 and self.torchSlot ~= nil
  local fillEnabled = self.fill and self.fillerSlot ~= nil

  -- Forward (F) and right (R) unit vectors from the start heading.
  local F = { x = DX[S.h], z = DZ[S.h] }
  local R = { x = DX[(S.h + 1) % 4], z = DZ[(S.h + 1) % 4] }

  -- Loot region = 1..lootMax = one below the lowest ENABLED reserved slot, so
  -- countEmptySlots(lootMax) and _dump(lootMax) never see a reserved slot.
  local lootMax = 16
  if dumpEnabled then lootMax = math.min(lootMax, self.chestSlot - 1) end
  if torchEnabled then lootMax = math.min(lootMax, self.torchSlot - 1) end
  if fillEnabled then lootMax = math.min(lootMax, self.fillerSlot - 1) end

  -- The turtle's offset from S in corridor coords: l (forward), w (right), u (up).
  local function project()
    local p = nav:getPose()
    local dx, dz = p.x - S.x, p.z - S.z
    return dx * F.x + dz * F.z, dx * R.x + dz * R.z, p.y - S.y
  end

  -- Floor-fill (at u=0, over a gap) or torch (at u=1, on the near wall) for the
  -- cell the turtle currently occupies. Both consume from a reserved slot and
  -- restore the prior selection; both no-op silently if their slot is empty.
  local function serviceCell(l, w, u)
    if fillEnabled and u == 0 and (not nav:detectDown())
        and nav:getItemCount(self.fillerSlot) > 0 then
      local prev = nav:getSelectedSlot()
      nav:select(self.fillerSlot)
      if nav:placeDown() then fills = fills + 1 end
      nav:select(prev)
    elseif torchEnabled and u == 1 and w == 0 and l > 0
        and (l % self.torchEvery) == 0
        and nav:getItemCount(self.torchSlot) > 0 then
      local prev = nav:getSelectedSlot()
      nav:select(self.torchSlot)
      if nav:placeDown() then torches = torches + 1 end
      nav:select(prev)
    end
  end

  local function stats(pose)
    return {
      width = W, length = L, depth = H,
      levelsDone = levelsDone,
      cellsCleared = cells,
      dumps = dumps,
      torches = torches,
      fills = fills,
      pose = pose or nav:getPose(),
    }
  end

  -- Called after every successful move: count the cell, service it (torch/fill),
  -- dump if the loot region is full, then report progress. Returns ok, err so a
  -- failed dump or an onProgress abort stops the tunnel cleanly.
  local function afterMove()
    cells = cells + 1
    serviceCell(project())
    if dumpEnabled and nav:countEmptySlots(lootMax) == 0 then
      local dok, derr = self:_dump(lootMax)
      if not dok then return false, derr end
      dumps = dumps + 1
    end
    if self.opts.onProgress then
      local cont = self.opts.onProgress({
        pose = nav:getPose(), fuel = nav:getFuelLevel(), cells = cells,
        levelsDone = levelsDone, dumps = dumps, torches = torches, fills = fills,
        width = W, length = L, depth = H,
      })
      if cont == false then return false, "aborted" end
    end
    return true
  end

  -- The mouth cell (0,0,0) is never entered by a move, so afterMove never sees
  -- it — prime its floor gap once up front.
  serviceCell(0, 0, 0)

  -- Rows run FORWARD (length), stepping RIGHT (width). Sweep the bottom level in
  -- place (no entry move), then ascend and serpentine each level above it.
  local rowDir, stepDir = S.h, (S.h + 1) % 4
  for level = 1, H do
    local sok, serr, endDir = sweepLayer(nav, W, L, rowDir, stepDir, afterMove)
    if not sok then return false, serr, stats() end
    levelsDone = level

    if level < H then
      local uok, uerr = nav:up() -- ascend into the next level (digs the ceiling)
      if not uok then return false, uerr, stats() end
      local aok, aerr = afterMove()
      if not aok then return false, aerr, stats() end
      -- Flip BOTH directions, exactly like quarry's descent: the next level
      -- sweeps back the way it came.
      rowDir = flip(endDir)
      stepDir = flip(stepDir)
    end
  end

  -- Return home through already-cleared cells. "xzy" (Y travelled LAST) is
  -- mandatory: torches live at u=0, so the horizontal legs must stay at the
  -- torch-free TOP level and only the torch-free start column (l=0,w=0) is
  -- descended. A Y-first order would walk the torch row and dig the torches out.
  local rok, rerr = nav:goTo(S.x, S.y, S.z, "xzy")
  if not rok then return false, rerr, stats() end
  nav:turnTo(S.h)

  return true, stats(nav:getPose())
end

-- Ergonomic one-shot wrapper (the "pure function" form).
function Tunnel.mine(nav, spec, opts)
  return Tunnel.new(nav, opts):run(spec)
end

return Tunnel
