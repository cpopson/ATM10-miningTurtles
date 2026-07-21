-- mockstore.lua — in-memory persistence store for testing, mirroring store.lua's
-- contract. The disk analogue of mockbus.lua.
--
-- It deep-copies on BOTH save and load so it behaves like a real
-- serialize/deserialize boundary: a caller mutating its table after save (or a
-- loaded table) can never leak back into storage. That fidelity is what lets
-- tests catch aliasing bugs the real (textutils) store wouldn't have.
--
-- Turtle-... err, store-contract functions are plain (save/load/delete);
-- `_`-prefixed helpers are test-facing.

local MockStore = {}
MockStore.__index = MockStore

-- Deep copy of plain data (tables/scalars); good enough for serialize-safe state.
local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do out[k] = deepcopy(val) end
  return out
end

-- MockStore.new() -> store  (with plain save/load/delete + `_` helpers)
function MockStore.new()
  local self = setmetatable({}, MockStore)
  self.data = {}      -- name -> deep-copied table
  self.corrupt = {}   -- name -> true to simulate a corrupt file
  self.saves = 0      -- number of save() calls (for assertions)

  self.save = function(name, tbl)
    self.data[name] = deepcopy(tbl)
    self.saves = self.saves + 1
    return true
  end
  self.load = function(name)
    if self.corrupt[name] then return nil, "corrupt" end
    if self.data[name] == nil then return nil end
    return deepcopy(self.data[name])
  end
  self.delete = function(name)
    self.data[name] = nil
    return true
  end

  return self
end

--------------------------------------------------------------------------------
-- Test-facing helpers
--------------------------------------------------------------------------------

function MockStore:_get(name) return self.data[name] end       -- raw stored table
function MockStore:_corrupt(name) self.corrupt[name] = true end
function MockStore:_count()
  local n = 0
  for _ in pairs(self.data) do n = n + 1 end
  return n
end
function MockStore:_saves() return self.saves end

return MockStore
