-- nav.lua — position/heading tracking + world-collision-safe movement.
--
-- The ONLY module allowed to touch a turtle backend. All movement, digging,
-- inspection, fuel, and inventory go through the injected `backend` so the
-- same code runs against a real CC:Tweaked turtle or the `mockturtle` sim.
--
-- Heading convention (fixed project-wide):
--   0 = N (-Z), 1 = E (+X), 2 = S (+Z), 3 = W (-X)
-- Coordinates match Minecraft/GPS axes.
--
-- Targets the Lua 5.1/5.2 common subset (CC:Tweaked is Cobalt ~5.1); also runs
-- under desktop Lua 5.4 for tests.

local Protect = require("protect")

-- Shared geometry. mockturtle.lua MUST define these identically — any drift
-- here is exactly the bug probe.lua exists to catch.
local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 } -- +X on East
local DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 } -- -Z on North

-- The three faces a turtle can act on, and the backend calls for each.
local DIG = { front = "dig", up = "digUp", down = "digDown" }
local DETECT = { front = "detect", up = "detectUp", down = "detectDown" }

local Nav = {}
Nav.__index = Nav

-- Nav.new(backend, startPose, opts) -> nav
--   backend   : injected turtle API subset (real `turtle` global or a mock). Required.
--   startPose : optional {x,y,z,h}; defaults to origin facing north. Copied, not aliased.
--   opts      : optional {
--       maxDigRetries = 16,
--       classify  = fn(name) -> "stop"|"skip",  -- see protect.lua
--       onBlocked = fn(entry),                  -- fired once per SKIP block found
--       detour    = true,                       -- false = abort instead of routing around
--     }
-- Does not touch the backend at construction (so tests can assert a clean start).
function Nav.new(backend, startPose, opts)
  assert(backend, "nav: backend is required")
  startPose = startPose or {}
  opts = opts or {}
  local self = setmetatable({}, Nav)
  self.b = backend
  self.pose = {
    x = startPose.x or 0,
    y = startPose.y or 0,
    z = startPose.z or 0,
    h = startPose.h or 0,
  }
  self.opts = {
    maxDigRetries = opts.maxDigRetries or 16,
    classify = opts.classify or Protect.classify,
    onBlocked = opts.onBlocked,
    detour = opts.detour ~= false,
  }
  self.digCount = 0
  self.dug = {}       -- log of {x,y,z,h,face} for each successful dig
  self.blocked = {}   -- {x,y,z,name,face,kind} per block we could not break
  self.blockedAt = {} -- "x,y,z" -> kind, so we never attack the same block twice
  self.detours = 0
  return self
end

--------------------------------------------------------------------------------
-- State queries (pure reads of tracked state — never call the backend)
--------------------------------------------------------------------------------

function Nav:getPos()
  return self.pose.x, self.pose.y, self.pose.z
end

function Nav:getPosT()
  return { x = self.pose.x, y = self.pose.y, z = self.pose.z }
end

function Nav:getHeading()
  return self.pose.h
end

function Nav:getPose()
  return { x = self.pose.x, y = self.pose.y, z = self.pose.z, h = self.pose.h }
end

-- setPose(pose) — re-anchor the tracked frame WITHOUT moving the turtle. Only
-- locate.lua uses this, to re-express nav's frame in GPS world coordinates once
-- it has worked out where the turtle actually is and which way it faces.
function Nav:setPose(pose)
  self.pose.x = pose.x or self.pose.x
  self.pose.y = pose.y or self.pose.y
  self.pose.z = pose.z or self.pose.z
  self.pose.h = pose.h or self.pose.h
  return true
end

-- The coordinates of the cell on `face` ("front" uses the CURRENT heading).
function Nav:faceCoord(face)
  if face == "up" then return self.pose.x, self.pose.y + 1, self.pose.z end
  if face == "down" then return self.pose.x, self.pose.y - 1, self.pose.z end
  local h = self.pose.h
  return self.pose.x + DX[h], self.pose.y, self.pose.z + DZ[h]
end

--------------------------------------------------------------------------------
-- Turning (update tracked heading after the backend call returns)
--------------------------------------------------------------------------------

function Nav:turnRight()
  self.b.turnRight()
  self.pose.h = (self.pose.h + 1) % 4
  return true
end

function Nav:turnLeft()
  self.b.turnLeft()
  self.pose.h = (self.pose.h + 3) % 4 -- +3, never -1, so it stays non-negative
  return true
end

-- turnTo(target) — minimal rotation to face `target` (0..3).
function Nav:turnTo(target)
  local diff = (target - self.pose.h) % 4
  if diff == 1 then
    self:turnRight()
  elseif diff == 2 then
    self:turnRight()
    self:turnRight()
  elseif diff == 3 then
    self:turnLeft()
  end
  return true
end

--------------------------------------------------------------------------------
-- Inspection / detection (pass-through, no state change)
--------------------------------------------------------------------------------
-- inspect returns (present, data|nil). Real CC returns a string as the 2nd
-- value on failure ("No block to inspect"), so we only surface `data` when
-- present is truthy — callers never index a string.

function Nav:inspect()
  local present, data = self.b.inspect()
  if present then return true, data end
  return false, nil
end

function Nav:inspectUp()
  local present, data = self.b.inspectUp()
  if present then return true, data end
  return false, nil
end

function Nav:inspectDown()
  local present, data = self.b.inspectDown()
  if present then return true, data end
  return false, nil
end

function Nav:detect()
  return self.b.detect()
end

function Nav:detectUp()
  return self.b.detectUp()
end

function Nav:detectDown()
  return self.b.detectDown()
end

--------------------------------------------------------------------------------
-- Blocks we could not break
--------------------------------------------------------------------------------
-- Some modded ores (Allthemodium, Vibranium, Unobtainium) are simply harder than
-- a turtle's pickaxe: `dig` returns false and no amount of retrying helps. We
-- find that out the CHEAP way — try the dig first, and only inspect once it has
-- already failed — so the normal case costs exactly what it always did.

local function bkey(x, y, z)
  return x .. "," .. y .. "," .. z
end

-- The kind ("stop"/"skip") recorded for a world cell, or nil if we've never
-- failed to dig it.
function Nav:blockedKindAt(x, y, z)
  return self.blockedAt[bkey(x, y, z)]
end

-- How many distinct blocks this nav has left standing (SKIP only — a `stop` is
-- the world floor, not something the player wants a list of).
function Nav:skippedCount()
  local n = 0
  for _, e in ipairs(self.blocked) do
    if e.kind == "skip" then n = n + 1 end
  end
  return n
end

-- Record the block on `face` as unbreakable and return its kind. Idempotent per
-- cell: the onBlocked hook (which the drivers wire to the find journal) fires at
-- most once per block, however many times we bump into it.
function Nav:noteBlocked(face, name)
  local x, y, z = self:faceCoord(face)
  local k = bkey(x, y, z)
  local seen = self.blockedAt[k]
  if seen then return seen end
  local kind = self.opts.classify(name) or "skip"
  self.blockedAt[k] = kind
  local entry = { x = x, y = y, z = z, name = name, face = face, kind = kind }
  self.blocked[#self.blocked + 1] = entry
  if kind == "skip" and self.opts.onBlocked then
    self.opts.onBlocked(entry)
  end
  return kind
end

function Nav:_inspectFace(face)
  if face == "up" then return self:inspectUp() end
  if face == "down" then return self:inspectDown() end
  return self:inspect()
end

--------------------------------------------------------------------------------
-- Digging (call backend; track blocks dug; no position change)
--------------------------------------------------------------------------------

function Nav:_logDig(face)
  self.digCount = self.digCount + 1
  local dug = self:getPose()
  dug.face = face
  self.dug[#self.dug + 1] = dug
end

-- The single dig path, shared by the public dig* methods and by tryMove.
-- Returns true, or false plus a reason:
--   "skip" / "stop"  the block is unbreakable (already recorded)
--   <backend error>  nothing there, or some other refusal
function Nav:_digFace(face)
  local x, y, z = self:faceCoord(face)
  local known = self.blockedAt[bkey(x, y, z)]
  if known then return false, known end -- proven unbreakable; don't spend a call

  local ok, err = self.b[DIG[face]]()
  if ok then
    self:_logDig(face)
    return true
  end

  -- The dig failed. ONE inspect tells us whether that's because the cell is
  -- empty (nothing to do) or because the block is beyond our pickaxe.
  local present, data = self:_inspectFace(face)
  if present and type(data) == "table" and type(data.name) == "string" then
    return false, self:noteBlocked(face, data.name)
  end
  return false, err
end

function Nav:dig() return self:_digFace("front") end

function Nav:digUp() return self:_digFace("up") end

function Nav:digDown() return self:_digFace("down") end

--------------------------------------------------------------------------------
-- Fuel
--------------------------------------------------------------------------------

function Nav:getFuelLevel()
  return self.b.getFuelLevel() -- may be the string "unlimited" — returned verbatim
end

-- hasFuel(n) — true if fuel is unlimited or numerically >= n. Guards against
-- doing arithmetic on the string "unlimited".
function Nav:hasFuel(n)
  local level = self.b.getFuelLevel()
  if level == "unlimited" then return true end
  return level >= n
end

-- refuel(count) -> ok, level. Consumes items in the currently selected slot(s)
-- via the backend, then reports the new fuel level.
function Nav:refuel(count)
  local ok, err = self.b.refuel(count)
  return ok, self.b.getFuelLevel(), err
end

--------------------------------------------------------------------------------
-- Inventory / placing (thin pass-throughs — the only path to these turtle ops)
--------------------------------------------------------------------------------

function Nav:select(slot) return self.b.select(slot) end
function Nav:getSelectedSlot() return self.b.getSelectedSlot() end
function Nav:getItemCount(slot) return self.b.getItemCount(slot) end
function Nav:getItemDetail(slot) return self.b.getItemDetail(slot) end

function Nav:place() return self.b.place() end
function Nav:placeUp() return self.b.placeUp() end
function Nav:placeDown() return self.b.placeDown() end

function Nav:drop(count) return self.b.drop(count) end
function Nav:dropUp(count) return self.b.dropUp(count) end
function Nav:dropDown(count) return self.b.dropDown(count) end

-- countEmptySlots(maxSlot, exceptSlot) -> number of empty inventory slots in
-- 1..maxSlot (default 16), skipping `exceptSlot` if given. Used to decide when
-- the loot slots are full.
function Nav:countEmptySlots(maxSlot, exceptSlot)
  maxSlot = maxSlot or 16
  local empty = 0
  for s = 1, maxSlot do
    if s ~= exceptSlot and self.b.getItemCount(s) == 0 then
      empty = empty + 1
    end
  end
  return empty
end

--------------------------------------------------------------------------------
-- Core: world-collision-safe movement primitive
--------------------------------------------------------------------------------
-- tryMove runs the retry loop shared by all four movers. Pose updates ONLY on a
-- confirmed successful backend move — the invariant that makes round trips close.
--
--   face     : "front"/"up"/"down" (which dig+detect to use), or nil for back()
--   moveFn   : backend move (forward/back/up/down)
--   dx,dy,dz : tracked-pose delta applied on success
local function tryMove(self, face, moveFn, dx, dy, dz)
  if not self:hasFuel(1) then
    return false, "no_fuel"
  end

  local attempts = self.opts.maxDigRetries + 1
  for _ = 1, attempts do
    local ok = moveFn()
    if ok then
      self.pose.x = self.pose.x + dx
      self.pose.y = self.pose.y + dy
      self.pose.z = self.pose.z + dz
      return true
    end

    -- Move failed. Figure out why and try to clear the way.
    if face == nil then
      -- back(): no dig available. Caller should turn-and-forward instead.
      return false, "blocked_back"
    end

    if self.b[DETECT[face]]() then
      -- A block is in the way.
      local dok, why = self:_digFace(face)
      if not dok then
        -- Give up now rather than burn every retry on something we can't clear.
        -- A "skip" is an ore harder than our pickaxe: the caller can route
        -- around it and leave it standing. Anything else (bedrock, an empty
        -- cell) keeps the original, blunter verdict.
        if why == "skip" then return false, "blocked_protected" end
        return false, "blocked_unbreakable"
      end
      -- Dug it; loop and retry. A falling gravel/sand column refills the cell,
      -- so we may dig several times before the move succeeds.
    else
      -- Move failed but nothing detected: likely a mob/entity. CC dig also
      -- attacks, so try that, then retry.
      self:_digFace(face)
    end
  end

  return false, "blocked_retry_exceeded"
end

-- Heading is read fresh each call so a turn between moves is respected.
function Nav:forward()
  local h = self.pose.h
  return tryMove(self, "front", self.b.forward, DX[h], 0, DZ[h])
end

function Nav:back()
  local h = self.pose.h
  return tryMove(self, nil, self.b.back, -DX[h], 0, -DZ[h])
end

function Nav:up()
  return tryMove(self, "up", self.b.up, 0, 1, 0)
end

function Nav:down()
  return tryMove(self, "down", self.b.down, 0, -1, 0)
end

--------------------------------------------------------------------------------
-- Routing around a block that cannot be mined
--------------------------------------------------------------------------------
-- For horizontal travel the rule is VERTICAL-ONLY detours: climb over the block
-- (preferred) or drop under it, landing on exactly the cell forward() was aiming
-- for. The turtle's X/Z footprint never changes, so a fleet turtle cannot wander
-- out of the region the coordinator assigned it — collision avoidance stays
-- structural, as CLAUDE.md requires. (We are avoiding a BLOCK here, not another
-- turtle; this adds no runtime turtle-to-turtle pathfinding.)
--
-- There is deliberately NO single-cell detour for up/down: when an up() reports
-- `blocked_protected` the unbreakable block IS the destination, so no three-move
-- excursion can reach it. Vertical obstructions are handled by whoever owns the
-- geometry — goTo's column bypass below, and the patterns' choose-another-corner
-- logic for layer changes.

local function flip(h) return (h + 2) % 4 end

-- Retreat one cell the way we came, keeping our heading. back() cannot dig, so
-- fall back to a 180 + forward (which can) if something settled in behind us.
function Nav:_reverse()
  if self:back() then return true end
  local h = self.pose.h
  self:turnTo(flip(h))
  local ok, err = self:forward()
  self:turnTo(h)
  return ok, err
end

-- _stepOver(v) — hop the cell directly ahead: rise (v=1 over / v=-1 under),
-- forward, forward, drop back in. Ends TWO cells along, with the obstruction
-- left standing in between — the block occupies a whole cell, so "around" can
-- never mean "onto it". Restores the starting cell on any failure.
function Nav:_stepOver(v)
  local rise = (v == 1) and self.up or self.down
  local fall = (v == 1) and self.down or self.up
  if not rise(self) then return false end
  local moved = 0
  while moved < 2 and self:forward() do moved = moved + 1 end
  if moved == 2 and fall(self) then return true end
  -- Couldn't clear it, or couldn't drop back in past it: undo the excursion.
  for _ = 1, moved do
    if not self:_reverse() then return false end
  end
  fall(self)
  return false
end

-- around() — get PAST the unmineable block directly ahead, leaving it standing.
-- Ends two cells forward. Returns true, or false,err from the starting cell.
function Nav:around()
  if not self.opts.detour then return false, "detour_disabled" end
  if self:_stepOver(1) then self.detours = self.detours + 1; return true end
  if self:_stepOver(-1) then self.detours = self.detours + 1; return true end
  return false, "detour_failed"
end

-- step(face, budget) -> ok, err, advanced
-- The movement primitive the patterns use: move one cell, hopping an unmineable
-- block if one is in the way.
--   budget : how many cells forward we may end up (default 2 — room for one
--            hop). Callers pass the exact distance left to their target, so a
--            block sitting ON the target is reported as "unreachable" instead of
--            being jumped clean past it.
--   advanced : cells actually covered (2 after a hop), so a caller driving by
--            distance stays in step with reality.
function Nav:step(face, budget)
  local mover = (face == "up") and self.up or (face == "down") and self.down or self.forward
  local ok, err = mover(self)
  if ok then return true, nil, 1 end
  if err ~= "blocked_protected" then return false, err, 0 end
  -- A blocked vertical move has the obstruction ON the destination: there is no
  -- hop that reaches it. Same when the destination itself is what is blocked.
  if face == "up" or face == "down" then return false, "unreachable", 0 end
  if (budget or 2) < 2 then return false, "unreachable", 0 end
  local aok, aerr = self:around()
  if aok then return true, nil, 2 end
  return false, aerr, 0
end

--------------------------------------------------------------------------------
-- High-level helpers
--------------------------------------------------------------------------------

-- goTo(x,y,z, order) — travel to a target by digging straight lines.
--   order : permutation of "xyz" giving axis travel order (default "yxz":
--           vertical first to avoid dropping into gravel, then X, then Z).
-- Returns true on success, or false,err,pose at the point it stalled. Does not
-- restore heading.
function Nav:goTo(x, y, z, order)
  order = order or "yxz"

  -- Driven by the REMAINING distance, re-read from the pose each time, because a
  -- hop over an unmineable block covers two cells rather than one.
  local function runAxis(axis, target, hPos, hNeg)
    while self.pose[axis] ~= target do
      local d = target - self.pose[axis]
      self:turnTo(d > 0 and hPos or hNeg)
      local ok, err = self:step("front", math.abs(d))
      if not ok then return false, err end
    end
    return true
  end

  local function runX() return runAxis("x", x, 1, 3) end

  local function runZ() return runAxis("z", z, 2, 0) end

  -- The vertical leg gets a COLUMN BYPASS rather than a per-cell detour: step
  -- one column sideways, finish the climb there, and step back at the end. The
  -- quarry's trip home climbs its entry shaft, and a skipped ore the sweep dug
  -- around earlier can be sitting in it — without this, the turtle gets home
  -- every time except the one time it matters.
  local function runY()
    local d = y - self.pose.y
    if d == 0 then return true end
    local mover = (d > 0) and self.up or self.down
    local off = nil -- heading we sidestepped along; nil while on the target column

    -- Back to the target column. Plain forward(), never step(): a vertical
    -- detour here would silently undo a level of the climb.
    local function rejoin()
      if not off then return true end
      self:turnTo(flip(off))
      off = nil
      return self:forward()
    end

    local function sidestep()
      local h0 = self.pose.h
      for i = 0, 3 do
        self:turnTo((h0 + i) % 4)
        if self:forward() then return (h0 + i) % 4 end
      end
      return nil
    end

    local function oneLevel()
      local ok, err = mover(self)
      if ok then return true end
      if err ~= "blocked_protected" or not self.opts.detour then return false, err end
      if off then
        -- Already off-column and blocked again: the target column may well be
        -- clear at this level, so try there before stepping further afield.
        if not rejoin() then return false, err end
        local ok2, err2 = mover(self)
        if ok2 then return true end
        if err2 ~= "blocked_protected" then return false, err2 end
      end
      off = sidestep()
      if not off then return false, "detour_failed" end
      self.detours = self.detours + 1
      return mover(self)
    end

    for _ = 1, math.abs(d) do
      local ok, err = oneLevel()
      if not ok then
        rejoin()
        return false, err
      end
    end
    return rejoin()
  end

  local steps = { x = runX, y = runY, z = runZ }
  for i = 1, #order do
    local axis = order:sub(i, i)
    local step = steps[axis]
    if step then
      local ok, err = step()
      if not ok then return false, err, self:getPose() end
    end
  end
  return true
end

-- returnTo(pose) — go to pose.x/y/z then face pose.h. Used by probe.
function Nav:returnTo(pose)
  local ok, err = self:goTo(pose.x, pose.y, pose.z)
  if not ok then return false, err, self:getPose() end
  self:turnTo(pose.h)
  return true
end

return Nav
