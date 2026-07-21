-- store.lua — the real disk-persistence adapter for the coordinator.
--
-- This is the ONLY new file that references `fs` / `textutils`, keeping the
-- coordinator as grep-clean of them as nav.lua is of `turtle`. It returns a
-- table of plain functions satisfying the store contract:
--
--   save(name, tbl)  -> ok, err        -- serialize + persist under `name`
--   load(name)       -> tbl|nil, err   -- nil (absent), or nil,"corrupt"
--   delete(name)     -> ok
--
-- `fs`/`textutils` are injectable (via `deps`) so the adapter itself can be
-- faked if desired; they default to the real globals. All logic tests use
-- mockstore instead.

local Store = {}

-- Store.new(deps) -> store
--   deps : optional { fs = fs, textutils = textutils }
function Store.new(deps)
  deps = deps or {}
  local fsapi = deps.fs or fs
  local tx = deps.textutils or textutils
  assert(fsapi, "store: fs API unavailable")
  assert(tx, "store: textutils API unavailable")

  local function path(name) return name .. ".dat" end
  local function tmp(name) return name .. ".tmp" end

  local function save(name, tbl)
    local body = tx.serialize(tbl)
    local f, err = fsapi.open(tmp(name), "w")
    if not f then return false, err or "cannot open temp file" end
    f.write(body)
    f.close()
    -- Atomic swap: a crash mid-write leaves the previous good .dat intact.
    if fsapi.exists(path(name)) then fsapi.delete(path(name)) end
    fsapi.move(tmp(name), path(name))
    return true
  end

  local function load(name)
    if not fsapi.exists(path(name)) then return nil end
    local f = fsapi.open(path(name), "r")
    if not f then return nil, "cannot open" end
    local body = f.readAll()
    f.close()
    local t = tx.unserialize(body)
    if type(t) ~= "table" then return nil, "corrupt" end
    return t
  end

  local function delete(name)
    if fsapi.exists(path(name)) then fsapi.delete(path(name)) end
    return true
  end

  return { save = save, load = load, delete = delete }
end

return Store
