-- protect.lua — the "leave it behind" registry.
--
-- A few All the Mods 10 ores cannot be broken by a mining turtle at all:
-- Allthemodium, Vibranium and Unobtainium need a higher tool tier than the
-- turtle's built-in pickaxe. `turtle.dig()` on one simply returns false, which
-- used to stall a whole job on nav's `blocked_unbreakable`.
--
-- The fix has two halves, both of which live here:
--   * the CLASSIFIER — decides whether a block nav failed to dig means STOP
--     (bedrock: there is nothing past it worth reaching) or SKIP (route around
--     it and carry on). Extendable from config.lua.
--   * the JOURNAL    — a deduplicated list of every skipped block, which renders
--     itself as a plain-text file for the player to go clean up later.
--
-- Deliberately dependency-free: no `turtle`, no `fs`, no `os`. Persistence goes
-- through an injected store (store.lua / mockstore.lua) and timestamps through
-- an injected `now`, so the whole module is testable off-Minecraft.
--
-- Heading/geometry constants are BYTE-IDENTICAL to nav.lua — the journal needs
-- them to rotate a nav-frame find into world coordinates.

local DX = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 } -- +X on East
local DZ = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 } -- -Z on North

local Protect = {}

--------------------------------------------------------------------------------
-- Classifier
--------------------------------------------------------------------------------

-- Blocks a mining turtle's pickaxe cannot break. Matched as lowercase
-- SUBSTRINGS of the registry name, so "allthemodium" covers the whole mod
-- namespace (allthemodium:allthemodium_ore, :vibranium_ore, :unobtainium_ore and
-- every dimension variant) without enumerating them.
--
-- This list is NOT the safety net — nav treats anything it fails to dig as
-- unmineable regardless (see classify below), so an ore nobody listed still gets
-- routed around the first time it is met. The list buys two other things: a name
-- we can refuse to even attempt (branch's vein scanner uses it) and a place for
-- the player to add their own, via config.protectedBlocks.
Protect.UNMINEABLE = {
  "allthemodium",
  "vibranium",
  "unobtainium",
}

-- Blocks that mean STOP, not "go around": the world floor and admin blocks.
-- Routing around bedrock is pointless — a quarry that reaches it is finished —
-- and it would turn one honest abort into a long, futile detour hunt.
Protect.STOP = {
  "bedrock",
  "barrier",
  "command_block",
  "structure_block",
  "structure_void",
  "jigsaw",
  "end_portal",
}

-- concat(a, b) -> a new array with b appended to a. (Lua 5.1 has no table.move.)
function Protect.concat(a, b)
  local out = {}
  for _, v in ipairs(a or {}) do out[#out + 1] = v end
  for _, v in ipairs(b or {}) do out[#out + 1] = v end
  return out
end

-- matcher(list) -> fn(name) -> bool. Plain (non-pattern) substring find on the
-- lowercased name, so mod ids with punctuation are safe to list verbatim.
function Protect.matcher(list)
  local needles = {}
  for i, s in ipairs(list or {}) do needles[i] = tostring(s):lower() end
  return function(name)
    if type(name) ~= "string" then return false end
    local n = name:lower()
    for _, needle in ipairs(needles) do
      if n:find(needle, 1, true) then return true end
    end
    return false
  end
end

Protect.isUnmineable = Protect.matcher(Protect.UNMINEABLE)
Protect.isStop = Protect.matcher(Protect.STOP)

-- classify(name) -> "stop" | "skip"
--
-- Called by nav ONLY after a dig has already failed, so the question is never
-- "can this be mined" (we just proved it cannot) but "is it worth going around".
-- Everything not on the STOP list is worth going around — that is what makes an
-- unlisted modded ore behave correctly the very first time it is met.
function Protect.classify(name)
  if Protect.isStop(name) then return "stop" end
  return "skip"
end

-- newClassifier(opts) -> fn(name) -> "stop"|"skip"
--   opts = { skip = {names to always route around}, stop = {extra STOP names} }
-- Lets the drivers fold config.protectedBlocks in without editing this file. The
-- extra `skip` names are checked first, so a player can un-stop a listed block.
function Protect.newClassifier(opts)
  opts = opts or {}
  local extraSkip = Protect.matcher(opts.skip)
  local isStop = Protect.matcher(Protect.concat(Protect.STOP, opts.stop))
  return function(name)
    if extraSkip(name) then return "skip" end
    if isStop(name) then return "stop" end
    return "skip"
  end
end

--------------------------------------------------------------------------------
-- Journal
--------------------------------------------------------------------------------
-- A find is recorded in the NAV FRAME (whatever coordinates the turtle's nav was
-- built with). If the journal is given an `origin` — the world pose that nav's
-- (0,0,0) facing 0 actually corresponds to, which locate.lua derives from GPS —
-- every entry also carries world coordinates and the rendered file becomes
-- something the player can fly straight to.

local Journal = {}
Journal.__index = Journal

local function keyOf(e)
  if e.wx then return e.wx .. "," .. e.wy .. "," .. e.wz end
  -- No world fix: nav-frame coordinates only mean something per turtle, so the
  -- reporting turtle is part of the identity.
  return tostring(e.by or "?") .. "@" .. e.x .. "," .. e.y .. "," .. e.z
end

-- Protect.newJournal(opts) -> journal
--   opts = {
--     store    = <store contract: save/load[/writeText]>  (nil = memory only)
--     name     = "ores",         -- base filename (<name>.dat + <name>.txt)
--     by       = <turtle label>, -- stamped on entries this journal records
--     origin   = {x,y,z,h},      -- world pose of nav's (0,0,0,h=0), optional
--     now      = fn() -> string, -- timestamp source, optional
--     max      = 512,            -- cap, so a pathological run can't fill the disk
--     autosave = true,           -- persist on every new find
--   }
function Protect.newJournal(opts)
  opts = opts or {}
  local j = setmetatable({}, Journal)
  j.name = opts.name or "ores"
  j.store = opts.store
  j.by = opts.by
  j.now = opts.now
  j.max = opts.max or 512
  j.autosave = opts.autosave ~= false
  j.entries = {}
  j.index = {}
  j.pending = {} -- new finds not yet shipped to the control computer
  j.dropped = 0
  j.origin = opts.origin
  return j
end

-- The world position of a nav-frame point, or nil when there is no fix.
-- nav's local +X axis points along world heading (origin.h + 1) and its local +Z
-- along (origin.h + 2) — the same quarter-turn rotation nav's own DX/DZ tables
-- encode, applied once to the whole frame.
function Journal:world(e)
  local o = self.origin
  if not o then return nil end
  local a, b = (o.h + 1) % 4, (o.h + 2) % 4
  return o.x + e.x * DX[a] + e.z * DX[b],
      o.y + e.y,
      o.z + e.x * DZ[a] + e.z * DZ[b]
end

-- Attach (or replace) the world fix and backfill every entry recorded so far, so
-- a fix obtained late is worth exactly as much as one obtained up front.
function Journal:setOrigin(origin)
  self.origin = origin
  self.index = {}
  for _, e in ipairs(self.entries) do
    e.wx, e.wy, e.wz = self:world(e)
    self.index[keyOf(e)] = e
  end
  if self.autosave then self:save() end
  return true
end

-- record(e) -> entry, isNew.  e = { x, y, z, name, face?, by?, at?, wx?,wy?,wz? }
-- Pre-supplied world coordinates (from a turtle that had its own fix) are kept
-- verbatim — that is what lets the control computer merge the whole fleet's finds
-- into one file without re-projecting them through its own frame.
function Journal:record(e)
  if type(e) ~= "table" then return nil, false end
  local rec = {
    x = e.x or 0, y = e.y or 0, z = e.z or 0,
    name = e.name or "unknown",
    face = e.face,
    by = e.by or self.by,
    at = e.at or (self.now and self.now()) or nil,
  }
  if e.wx then
    rec.wx, rec.wy, rec.wz = e.wx, e.wy, e.wz
  else
    rec.wx, rec.wy, rec.wz = self:world(rec)
  end
  local k = keyOf(rec)
  local seen = self.index[k]
  if seen then return seen, false end
  if #self.entries >= self.max then
    self.dropped = self.dropped + 1
    return nil, false
  end
  self.entries[#self.entries + 1] = rec
  self.index[k] = rec
  self.pending[#self.pending + 1] = rec
  if self.autosave then self:save() end
  return rec, true
end

-- merge(list) -> nAdded. Fold another journal's entries in (control computer).
function Journal:merge(list)
  local added = 0
  local auto = self.autosave
  self.autosave = false -- one save at the end, not one per entry
  for _, e in ipairs(list or {}) do
    local _, isNew = self:record(e)
    if isNew then added = added + 1 end
  end
  self.autosave = auto
  if auto and added > 0 then self:save() end
  return added
end

function Journal:count() return #self.entries end

function Journal:list() return self.entries end

-- Hand over the finds recorded since the last call and clear the buffer. The
-- worker ships these to the control computer; nothing else consumes them, so a
-- lost radio packet costs the fleet-wide file one line, never the turtle's own.
function Journal:takePending()
  local p = self.pending
  self.pending = {}
  return p
end

--------------------------------------------------------------------------------
-- Rendering / persistence
--------------------------------------------------------------------------------

local COMPASS = { [0] = "north", [1] = "east", [2] = "south", [3] = "west" }

local function fmtOrigin(o)
  return string.format("(%d,%d,%d) facing %s", o.x, o.y, o.z, COMPASS[o.h] or "?")
end

-- lines() -> array of plain-text lines. Written to <name>.txt so it can be read
-- in-game with `edit ores.txt` and skimmed without any tooling.
function Journal:lines()
  local out = {}
  out[#out + 1] = "# cc-fleet-miner - blocks left in place"
  out[#out + 1] = "# A mining turtle cannot break these, so it dug around them and left"
  out[#out + 1] = "# them standing for you. Bring a better pickaxe."
  out[#out + 1] = "#"
  if self.origin then
    out[#out + 1] = "# WORLD coordinates (GPS fix: start " .. fmtOrigin(self.origin) .. ")"
  else
    out[#out + 1] = "# NO GPS FIX - coordinates are RELATIVE to where the turtle started,"
    out[#out + 1] = "# measured +X east, +Z south, +Y up from its starting block."
  end
  out[#out + 1] = string.format("# %d found%s", #self.entries,
    self.dropped > 0 and (" (" .. self.dropped .. " more not listed: hit the " ..
      self.max .. "-entry limit)") or "")
  out[#out + 1] = string.format("#%7s %6s %7s  %-38s %-12s %s",
    "x", "y", "z", "block", "turtle", "found")
  for _, e in ipairs(self.entries) do
    out[#out + 1] = string.format(" %7d %6d %7d  %-38s %-12s %s",
      e.wx or e.x, e.wy or e.y, e.wz or e.z,
      e.name, tostring(e.by or "-"), tostring(e.at or "-"))
  end
  return out
end

function Journal:text()
  return table.concat(self:lines(), "\n") .. "\n"
end

-- Persist both forms: <name>.dat is what a rebooted turtle reloads, <name>.txt is
-- what the player reads. A store with no writeText (an older adapter, or a mock
-- in a test that doesn't care) simply gets the .dat half.
function Journal:save()
  if not self.store then return false, "no_store" end
  local ok, err = self.store.save(self.name, {
    origin = self.origin, entries = self.entries, dropped = self.dropped,
  })
  if self.store.writeText then self.store.writeText(self.name, self:text()) end
  return ok, err
end

-- Reload a previous run's finds so a rebooted turtle keeps (and keeps
-- deduplicating against) what it already knows. Returns true if anything loaded.
function Journal:load()
  if not self.store then return false end
  local t = self.store.load(self.name)
  if type(t) ~= "table" then return false end
  self.origin = t.origin or self.origin
  self.entries, self.index, self.pending = {}, {}, {}
  self.dropped = t.dropped or 0
  for _, e in ipairs(t.entries or {}) do
    if type(e) == "table" then
      self.entries[#self.entries + 1] = e
      self.index[keyOf(e)] = e
    end
  end
  return true
end

return Protect
