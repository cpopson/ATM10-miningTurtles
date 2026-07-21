-- partition.lua — pure box -> column-strip splitter for the quarry coordinator.
--
-- Splits a quarry bounding box into contiguous, non-overlapping column-strips by
-- X range so each turtle clears its own slab top-to-bottom (columns are never
-- shared). This is the structural collision avoidance: a turtle stays inside its
-- X-strip, so no runtime turtle-to-turtle pathfinding is ever needed.
--
-- Pure, dependency-free, deterministic (same input -> same jobs, incl. ids), so
-- it's the "pure function" the project calls for. No state, no `.new`.
--
-- Deployment contract: each turtle is pre-placed at its strip's start corner —
-- one block ABOVE the strip's min-X, min-Z top cell — matching quarry.lua's
-- start-above geometry. (GPS-free; the worker never travels between strips.)

local Partition = {}

-- widths(W, n) -> { w1, w2, ... }
-- Balanced strip widths: k = min(n, W) strips, each floor(W/k) wide, with the
-- first (W % k) strips one wider. Sum == W; any two differ by at most 1.
function Partition.widths(W, n)
  if type(W) ~= "number" or type(n) ~= "number" then return {} end
  if W <= 0 or n <= 0 then return {} end
  local k = math.min(n, W)
  local base = math.floor(W / k)
  local rem = W % k
  local ws = {}
  for i = 1, k do
    ws[i] = base + (i <= rem and 1 or 0)
  end
  return ws
end

-- split(box, n) -> jobs, count
--   box = { id?, origin = {x,y,z}, width = W, length = L, depth = D }
--   n   = turtle count
-- Returns an array of job tables (one per strip) and their count. Each job:
--   {
--     id      = "<box.id or 'quarry'>-s<i>",   -- deterministic => idempotent re-assign
--     pattern = "quarry",
--     origin  = { x, y, z },                    -- strip's min-X,min-Z top corner (start-above cell)
--     width, length, depth,                     -- dims the worker passes to quarry:run
--     region  = { x0, x1, z0, z1, y0, y1 },     -- absolute cell box (matches quarry geometry)
--   }
-- W < n  -> W width-1 jobs (surplus turtles stay idle). W<=0 / n<=0 -> {}, 0.
function Partition.split(box, n)
  if type(box) ~= "table" or type(box.origin) ~= "table" then return {}, 0 end
  local W, L, D = box.width, box.length, box.depth
  local ws = Partition.widths(W, n)
  local jobs = {}
  local cursor = 0
  local prefix = box.id or "quarry"
  local ox, oy, oz = box.origin.x, box.origin.y, box.origin.z
  for i = 1, #ws do
    local wi = ws[i]
    local x0 = ox + cursor
    jobs[i] = {
      id = string.format("%s-s%d", prefix, i),
      pattern = "quarry",
      origin = { x = x0, y = oy, z = oz },
      width = wi,
      length = L,
      depth = D,
      region = {
        x0 = x0, x1 = x0 + wi - 1,
        z0 = oz, z1 = oz + L - 1,
        y0 = oy - D, y1 = oy - 1,
      },
    }
    cursor = cursor + wi
  end
  return jobs, #jobs
end

return Partition
