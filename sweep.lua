-- sweep.lua — the serpentine (boustrophedon) layer walk shared by quarry.lua
-- and tunnel.lua.
--
-- Both patterns clear a rectangle one level at a time in the same back-and-forth
-- order, and until now each carried its own copy of the walk (tunnel's copy said
-- so in a comment). It moved here because the walk has to do one thing both
-- copies got to ignore: cope with cells the turtle CANNOT occupy, because an ore
-- harder than its pickaxe is standing in one.
--
-- The walk is driven by ABSOLUTE cell targets rather than by counting moves.
-- That is the whole trick:
--   * a cell that must be skipped drops out of the itinerary without shifting
--     every cell after it — no cursor to repair, no special case for a blocked
--     cell at the end of a row;
--   * it keeps tunnel's documented onProgress contract intact, because the walk
--     holds no positional state at all. A hook that runs a whole nested Tunnel
--     and restores its pose is still invisible to it.
--
-- Travel between consecutive targets goes through nav:goTo(..., "xz"), which
-- stays at the current level and hops any unmineable block in the way. Both
-- endpoints are inside the rectangle, so an axis-aligned path between them is
-- too — the sweep never wanders outside its own layer.

local Sweep = {}

-- Sweep.layer(nav, rows, cols, cellAt, afterMove) -> ok, err, stats
--   rows, cols : the layer's size. The turtle ALREADY stands on cellAt(0, 0),
--                which is therefore never entered and never reported.
--   cellAt(r, c) -> x, y, z : absolute coordinates of layer cell (r, c), for
--                r in [0, rows-1] and c in [0, cols-1].
--   afterMove() -> ok, err : called once per cell entered. Returning false stops
--                the sweep and is reported verbatim.
--   stats = { entered, skipped } — `skipped` counts cells left standing.
function Sweep.layer(nav, rows, cols, cellAt, afterMove)
  local entered, skipped = 0, 0
  local function stats() return { entered = entered, skipped = skipped } end

  for r = 0, rows - 1 do
    for i = 0, cols - 1 do
      -- Serpentine: odd rows run back the way the previous one came.
      local c = (r % 2 == 0) and i or (cols - 1 - i)
      if r > 0 or i > 0 then -- (0,0) is where we already are
        local x, y, z = cellAt(r, c)
        local ok, err = nav:goTo(x, y, z, "xz")
        if ok then
          entered = entered + 1
          local aok, aerr = afterMove()
          if not aok then return false, aerr, stats() end
        elseif err == "unreachable" then
          -- An unmineable block is standing in this cell. Leave it for the
          -- player (nav has already recorded where it is) and carry on.
          skipped = skipped + 1
        else
          return false, err, stats()
        end
      end
    end
  end
  return true, nil, stats()
end

-- Sweep.cornerMap(px, pz, x0, x1, z0, z1) -> cellAt, rows, cols
--
-- Build a cellAt for the layer containing corner (px, pz), given the layer's
-- bounds. Each axis steps AWAY from the edge the turtle is standing on, so a
-- serpentine started from ANY of the four corners covers the whole rectangle —
-- which is what lets a pattern descend at a different corner when the floor
-- under its usual one turns out to be unmineable, with no direction bookkeeping.
--
-- Rows run along X, columns along Z. (tunnel.lua passes its corridor's
-- length/width axes through the same helper by mapping them onto x/z itself.)
function Sweep.cornerMap(px, py, pz, x0, x1, z0, z1)
  local sx = (px == x0) and 1 or -1
  local sz = (pz == z0) and 1 or -1
  local cellAt = function(r, c)
    return px + r * sx, py, pz + c * sz
  end
  return cellAt, (x1 - x0) + 1, (z1 - z0) + 1
end

-- Sweep.corners(x0, x1, z0, z1, fromX, fromZ) -> array of {x, z}
-- The layer's distinct corners, nearest first (Manhattan) from (fromX, fromZ).
-- Degenerate rectangles (a 1-wide or 1-long box) collapse to 2 corners, or 1.
function Sweep.corners(x0, x1, z0, z1, fromX, fromZ)
  local out, seen = {}, {}
  for _, cx in ipairs({ x0, x1 }) do
    for _, cz in ipairs({ z0, z1 }) do
      local k = cx .. "," .. cz
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = { x = cx, z = cz, d = math.abs(cx - fromX) + math.abs(cz - fromZ) }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if a.x ~= b.x then return a.x < b.x end -- stable, so tests are deterministic
    return a.z < b.z
  end)
  return out
end

return Sweep
