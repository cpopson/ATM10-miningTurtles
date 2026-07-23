-- update.lua — pull the latest project files from GitHub onto an in-game
-- computer/turtle.
--
-- Bootstrap (first time, on a fresh computer/turtle):
--   wget https://raw.githubusercontent.com/cpopson/ATM10-miningTurtles/master/update.lua update.lua
--   update
-- After every push, just run `update` again.
--
-- Note: raw.githubusercontent.com is served through a CDN with a ~5-minute
-- cache, so a file you just pushed may take a few minutes to appear here. If an
-- update doesn't show up, wait and re-run `update`.

-- Branch is `master`; the trailing slash is required (BASE .. name must yield
-- .../master/nav.lua).
local BASE = "https://raw.githubusercontent.com/cpopson/ATM10-miningTurtles/master/"

-- Every syncable file. update.lua includes itself so it can self-update; append
-- new modules here as they're added (quarry.lua, branch.lua, ... per CLAUDE.md).
local FILES = {
  "update.lua",
  "config.lua",
  "nav.lua",
  "mockturtle.lua",
  "test_nav.lua",
  "probe.lua",
  "quarry.lua",
  "test_quarry.lua",
  "mine.lua",
  "tunnel.lua",
  "test_tunnel.lua",
  "dig.lua",
  "comms.lua",
  "rednet_transport.lua",
  "mockbus.lua",
  "test_comms.lua",
  "partition.lua",
  "coordinator.lua",
  "worker.lua",
  "control.lua",
  "fleet.lua",
  "test_partition.lua",
  "test_coordinator.lua",
  "test_worker.lua",
  "test_fleet.lua",
  "store.lua",
  "mockstore.lua",
  "test_store.lua",
  "jobspec.lua",
  "setup.lua",
  "test_setup.lua",
}

local function fetch(name)
  local url = BASE .. name
  local res = http.get(url)
  if not res then
    return false, "no response"
  end
  local body = res.readAll()
  res.close()
  if not body or #body == 0 then
    return false, "empty body"
  end
  if fs.exists(name) then fs.delete(name) end
  local f = fs.open(name, "w")
  if not f then
    return false, "cannot open " .. name .. " for write"
  end
  f.write(body)
  f.close()
  return true
end

local total = #FILES
local okCount = 0
for i, name in ipairs(FILES) do
  local ok, err = fetch(name)
  if ok then
    okCount = okCount + 1
    print(string.format("[%d/%d] %s ... ok", i, total, name))
  else
    print(string.format("[%d/%d] %s ... FAILED (%s)", i, total, name, tostring(err)))
  end
end

print(okCount .. "/" .. total .. " files updated")
-- The running copy of update.lua is already loaded in memory, so overwriting
-- update.lua on disk is safe and takes effect on the next `update`.
