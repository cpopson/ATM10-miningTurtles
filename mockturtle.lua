-- mockturtle.lua — in-memory voxel world implementing the subset of the
-- CC:Tweaked `turtle` API that nav.lua depends on, so mining logic can be
-- tested off-Minecraft. Models solid/air, unbreakable bedrock, gravity blocks
-- (gravel/sand), and fuel.
--
-- Turtle-API methods are the plain names nav calls (forward, dig, detect, ...).
-- Test-facing world authoring/assertion helpers are prefixed with `_` so they
-- can never be mistaken for the real turtle API.
--
-- Heading + geometry are BYTE-IDENTICAL to nav.lua. Do not let them drift.

local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 } -- +X on East
local DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 } -- -Z on North

local Mock = {}
Mock.__index = Mock

local function key(x, y, z)
  return x .. "," .. y .. "," .. z
end

-- Mock.new(cfg) -> mock
--   cfg : optional { fuel = <number|"unlimited">, pose = {x,y,z,h}, floorY = <int|nil> }
function Mock.new(cfg)
  cfg = cfg or {}
  local self = setmetatable({}, Mock)
  self.world = {}
  local p = cfg.pose or {}
  self.pos = { x = p.x or 0, y = p.y or 0, z = p.z or 0 }
  self.h = p.h or 0
  self.fuel = cfg.fuel or "unlimited"
  self.floorY = cfg.floorY -- any y <= floorY reads as bedrock (cheap infinite floor)
  self.inventory = {} -- slot -> {name, count, fuel}
  self.selected = 1
  self.digLog = {} -- array of {x,y,z,name}

  -- nav (and the real turtle API) call the backend as PLAIN functions —
  -- `backend.forward()`, not `backend:forward()` — so there is no implicit
  -- self. Bind the turtle-API subset to instance closures that supply self.
  -- (`_`-prefixed authoring/assertion helpers stay as colon-methods; tests
  -- call those with `mock:_foo()`.)
  local API = {
    "forward", "back", "up", "down", "turnLeft", "turnRight",
    "dig", "digUp", "digDown",
    "detect", "detectUp", "detectDown",
    "inspect", "inspectUp", "inspectDown",
    "getFuelLevel", "refuel", "select", "getItemCount", "getItemDetail",
  }
  for _, name in ipairs(API) do
    local m = Mock[name]
    self[name] = function(...) return m(self, ...) end
  end

  return self
end

--------------------------------------------------------------------------------
-- Block lookup (respects the optional bedrock floor)
--------------------------------------------------------------------------------

function Mock:_blockAt(x, y, z)
  local b = self.world[key(x, y, z)]
  if b then return b end
  if self.floorY and y <= self.floorY then
    return { name = "minecraft:bedrock", solid = true, breakable = false, gravity = false }
  end
  return nil
end

--------------------------------------------------------------------------------
-- Cell targeting (one place the geometry lives)
--------------------------------------------------------------------------------

function Mock:_frontCoord()
  return self.pos.x + DX[self.h], self.pos.y, self.pos.z + DZ[self.h]
end

function Mock:_backCoord()
  return self.pos.x - DX[self.h], self.pos.y, self.pos.z - DZ[self.h]
end

function Mock:_upCoord()
  return self.pos.x, self.pos.y + 1, self.pos.z
end

function Mock:_downCoord()
  return self.pos.x, self.pos.y - 1, self.pos.z
end

--------------------------------------------------------------------------------
-- Gravity
--------------------------------------------------------------------------------
-- After a cell (x,y,z) becomes air, let a contiguous column of gravity blocks
-- resting above it fall down. Vertical only, matching Minecraft gravel/sand.
function Mock:settleGravity(x, y, z)
  -- The empty cell is (x,y,z). Repeatedly pull the block directly above down
  -- into the current empty cell if it's a gravity block.
  local ey = y
  while true do
    local above = self:_blockAt(x, ey + 1, z)
    if above and above.gravity then
      self.world[key(x, ey, z)] = above
      self.world[key(x, ey + 1, z)] = nil
      ey = ey + 1
    else
      break
    end
  end
end

--------------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------------

function Mock:_move(nx, ny, nz)
  if self.fuel ~= "unlimited" and self.fuel < 1 then
    return false, "Out of fuel"
  end
  local b = self:_blockAt(nx, ny, nz)
  if b and b.solid then
    return false, "Movement obstructed"
  end
  self.pos.x, self.pos.y, self.pos.z = nx, ny, nz
  if self.fuel ~= "unlimited" then
    self.fuel = self.fuel - 1
  end
  return true
end

function Mock:forward()
  return self:_move(self:_frontCoord())
end

function Mock:back()
  return self:_move(self:_backCoord())
end

function Mock:up()
  return self:_move(self:_upCoord())
end

function Mock:down()
  return self:_move(self:_downCoord())
end

function Mock:turnLeft()
  self.h = (self.h + 3) % 4
  return true
end

function Mock:turnRight()
  self.h = (self.h + 1) % 4
  return true
end

--------------------------------------------------------------------------------
-- Digging
--------------------------------------------------------------------------------

function Mock:_dig(x, y, z)
  local b = self:_blockAt(x, y, z)
  if not b then
    return false, "Nothing to dig here"
  end
  if b.breakable == false then
    return false, "Unbreakable block detected"
  end
  self.world[key(x, y, z)] = nil
  self.digLog[#self.digLog + 1] = { x = x, y = y, z = z, name = b.name }
  self:settleGravity(x, y, z)
  return true
end

function Mock:dig()
  return self:_dig(self:_frontCoord())
end

function Mock:digUp()
  return self:_dig(self:_upCoord())
end

function Mock:digDown()
  return self:_dig(self:_downCoord())
end

--------------------------------------------------------------------------------
-- Detection / inspection
--------------------------------------------------------------------------------

function Mock:_detect(x, y, z)
  local b = self:_blockAt(x, y, z)
  return b ~= nil and b.solid == true
end

function Mock:detect()
  return self:_detect(self:_frontCoord())
end

function Mock:detectUp()
  return self:_detect(self:_upCoord())
end

function Mock:detectDown()
  return self:_detect(self:_downCoord())
end

function Mock:_inspect(x, y, z)
  local b = self:_blockAt(x, y, z)
  if not b then
    return false, "No block to inspect"
  end
  return true, { name = b.name, state = {}, tags = b.tags or {} }
end

function Mock:inspect()
  return self:_inspect(self:_frontCoord())
end

function Mock:inspectUp()
  return self:_inspect(self:_upCoord())
end

function Mock:inspectDown()
  return self:_inspect(self:_downCoord())
end

--------------------------------------------------------------------------------
-- Fuel / inventory
--------------------------------------------------------------------------------

function Mock:getFuelLevel()
  return self.fuel
end

function Mock:refuel(count)
  local slot = self.inventory[self.selected]
  if not slot or not slot.fuel or slot.count <= 0 then
    return false, "No items to combust"
  end
  local n = count or slot.count
  if n > slot.count then n = slot.count end
  if self.fuel == "unlimited" then
    -- Already unlimited; just consume.
  else
    self.fuel = self.fuel + slot.fuel * n
  end
  slot.count = slot.count - n
  if slot.count <= 0 then
    self.inventory[self.selected] = nil
  end
  return true
end

function Mock:select(slot)
  self.selected = slot
  return true
end

function Mock:getItemCount(slot)
  local s = self.inventory[slot]
  return s and s.count or 0
end

function Mock:getItemDetail(slot)
  local s = self.inventory[slot]
  if not s then return nil end
  return { name = s.name, count = s.count }
end

--------------------------------------------------------------------------------
-- World authoring API (test-facing)
--------------------------------------------------------------------------------

function Mock:_setBlock(x, y, z, name, props)
  props = props or {}
  local solid = props.solid
  if solid == nil then solid = true end
  local breakable = props.breakable
  if breakable == nil then breakable = true end
  self.world[key(x, y, z)] = {
    name = name or "minecraft:stone",
    solid = solid,
    breakable = breakable,
    gravity = props.gravity or false,
    tags = props.tags,
  }
end

function Mock:_setGravel(x, y, z)
  self:_setBlock(x, y, z, "minecraft:gravel", { solid = true, breakable = true, gravity = true })
end

function Mock:_setBedrock(x, y, z)
  self:_setBlock(x, y, z, "minecraft:bedrock", { solid = true, breakable = false })
end

function Mock:_setBedrockPlane(y)
  self.floorY = y
end

function Mock:_fillBox(x0, y0, z0, x1, y1, z1, name, props)
  for x = math.min(x0, x1), math.max(x0, x1) do
    for y = math.min(y0, y1), math.max(y0, y1) do
      for z = math.min(z0, z1), math.max(z0, z1) do
        self:_setBlock(x, y, z, name, props)
      end
    end
  end
end

function Mock:_setFuel(n)
  self.fuel = n
end

function Mock:_setUnlimitedFuel()
  self.fuel = "unlimited"
end

function Mock:_addItem(slot, name, count, fuelValue)
  self.inventory[slot] = { name = name, count = count, fuel = fuelValue }
end

--------------------------------------------------------------------------------
-- Assertion / introspection API (test-facing)
--------------------------------------------------------------------------------

function Mock:_getPose()
  return { x = self.pos.x, y = self.pos.y, z = self.pos.z, h = self.h }
end

function Mock:_getFuel()
  return self.fuel
end

function Mock:_getDigLog()
  return self.digLog
end

function Mock:_wasDug(x, y, z)
  for _, d in ipairs(self.digLog) do
    if d.x == x and d.y == y and d.z == z then return true end
  end
  return false
end

return Mock
