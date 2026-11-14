--[[
    whip_rope — THE WORLD

    The ground and walls, people walking through the rope, explosions.

    Every probe here is the SYNCHRONOUS shape test, so its answer is there in the same step (the
    async one is often not ready on the frame it was started).

    What the checks see is read from Config each step, so the settings page's switches (props, cars, people:
    shared/settings.lua) count at once. The map is always probed, so a rope never falls through the world.

    Steps follow the frame rate (client/main.lua): a push is scaled by the step's length (`dt`) so it adds as much
    speed a second at any rate, and a friction is a share kept each 1/60 s (Rope.KeptOver).
]]

local REF_DT = Rope.Const.REF_DT

--- What a push of `force` moves a node by in a step of `dt`: force·dt at 1/60 s, so it adds the same speed a second.
local function pushOver(dt) return (dt or REF_DT) * Rope.StepScale(dt) end

-- Every ray the rope casts, counted for /ropedebug's rays a second (to compare the ground's two ways)
local Rays = { n = 0, perSecond = 0, at = 0 }

--- A synchronous ray: hit, hitPos, hitNormal, hitEntity.
local function SyncProbe(x1, y1, z1, x2, y2, z2, flags, ignoreEntity)
    Rays.n = Rays.n + 1
    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        x1, y1, z1, x2, y2, z2, flags, ignoreEntity or 0, 4)
    local _, hit, hitPos, hitNormal, hitEntity = GetShapeTestResult(handle)
    return hit == 1, hitPos, hitNormal, hitEntity
end
Rope.SyncProbe = SyncProbe

--- The rays cast in the last second (the count is rolled over when this is asked, once a second at most).
function Rope.RaysPerSecond()
    local now = GetGameTimer()
    if now - Rays.at >= 1000 then
        Rays.perSecond = Rays.at > 0 and math.floor(Rays.n * 1000 / (now - Rays.at) + 0.5) or 0
        Rays.n, Rays.at = 0, now
    end
    return Rays.perSecond
end

-- ============================================================================
-- PEOPLE WALKING THROUGH IT
-- ============================================================================

-- Who is about, and where, every PedCacheInterval: a step only reads a ped's live position once its
-- cached one is near the rope.
local function refreshPedCache()
    local cache = Rope.PedCache
    local now = GetGameTimer()
    if now - cache.lastUpdate <= cache.updateInterval then return end
    cache.lastUpdate = now
    -- Its entries filled again in place: a busy street makes no new table per ped each look
    local list, n = cache.peds, 0
    for _, ped in ipairs(GetGamePool('CPed')) do
        local c = GetEntityCoords(ped)
        n = n + 1
        local e = list[n]
        if not e then e = {}; list[n] = e end
        e.ped, e.x, e.y, e.z = ped, c.x, c.y, c.z
    end
    for i = #list, n + 1, -1 do list[i] = nil end
end

--- [ped] = serverRopeId: a stand-in hanging off that rope. It never pushes that rope: its body, just under the hand,
--- would shove the node below it up, and the rope would snap it back down.
Rope.OnRope = Rope.OnRope or {}

-- Is this ped someone hanging off this rope or holding one of its ends? (They move with it; they
-- never push it — a holder's own legs kicked the nodes by their hand as they walked.)
local function onTheRope(ped, rope)
    if rope.serverRopeId and Rope.OnRope[ped] == rope.serverRopeId then return true end
    for _, which in ipairs({ 'origin', 'tail' }) do
        if rope[which .. 'Type'] == 'held' and Rope.PedOf(rope[which .. 'HeldBy']) == ped then return true end
    end
    local serverRopeId = rope.serverRopeId
    for serverId, hangData in pairs(Rope.HangingPlayers) do
        if hangData.serverRopeId == serverRopeId and Rope.PedOf(serverId) == ped then
            return true
        end
    end
    return false
end

function Rope.ApplyPlayerInteraction(rope, dt)
    local cfg = Config.PlayerInteraction
    if not cfg.Enabled then return end
    local k = pushOver(dt)

    local nodes = rope.nodes
    local nodeCount = #nodes
    if nodeCount == 0 then return end
    local link = Rope.LinkLength(rope)

    refreshPedCache()

    -- The rope's box, from a node every 4 m or so
    local bboxSpacing = math.max(1, math.floor(4.0 / link))
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    for i = 1, nodeCount, bboxSpacing do
        local pos = nodes[i].position
        if pos.x < minX then minX = pos.x end
        if pos.y < minY then minY = pos.y end
        if pos.z < minZ then minZ = pos.z end
        if pos.x > maxX then maxX = pos.x end
        if pos.y > maxY then maxY = pos.y end
        if pos.z > maxZ then maxZ = pos.z end
    end
    local last = nodes[nodeCount].position
    if last.x < minX then minX = last.x end
    if last.y < minY then minY = last.y end
    if last.z < minZ then minZ = last.z end
    if last.x > maxX then maxX = last.x end
    if last.y > maxY then maxY = last.y end
    if last.z > maxZ then maxZ = last.z end

    -- A cached position may be a PedCacheInterval old: a running ped covers a few metres in that
    local r = cfg.Radius + 2.0 + 4.0
    local nodeCheckSpacing = math.max(1, math.floor(cfg.Radius / link))

    for _, entry in ipairs(Rope.PedCache.peds) do
        if entry.x >= minX - r and entry.x <= maxX + r
            and entry.y >= minY - r and entry.y <= maxY + r
            and entry.z >= minZ - r and entry.z <= maxZ + r then
            local ped = entry.ped
            if DoesEntityExist(ped) and not IsEntityDead(ped) and not onTheRope(ped, rope) then
                local pedVel = GetEntityVelocity(ped)
                local pedSpeed = #pedVel
                local isRagdoll = IsPedRagdoll(ped)

                if pedSpeed >= 0.3 or isRagdoll then
                    local pedPos = GetEntityCoords(ped)
                    local force
                    if isRagdoll then
                        force = cfg.RagdollForce
                    elseif pedSpeed > 5.0 then
                        force = cfg.RunForce
                    else
                        force = cfg.WalkForce
                    end

                    for i = 1, nodeCount, nodeCheckSpacing do
                        local node = nodes[i]
                        if not node.pinned then
                            local pushDir = node.position - pedPos
                            local dist = #pushDir
                            if dist < cfg.Radius and dist > 0.01 then
                                pushDir = pushDir / dist
                                local pushStrength = force * (1.0 - dist / cfg.Radius) * k
                                node.position = node.position + pushDir * pushStrength
                                if pedSpeed > 0.5 then
                                    node.position = node.position + (pedVel / pedSpeed) * (pushStrength * 0.5)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- EXPLOSIONS
-- ============================================================================

function Rope.ApplyExplosionInteraction(rope, dt)
    local cfg = Config.ExplosionInteraction
    if not cfg.Enabled then return end
    local k = pushOver(dt)

    local recentExplosions = Rope.System.recentExplosions
    if #recentExplosions == 0 then return end
    local currentTime = GetGameTimer()

    for i = #recentExplosions, 1, -1 do
        local explosion = recentExplosions[i]
        if currentTime - explosion.time > 100 then
            table.remove(recentExplosions, i)
        else
            for _, node in ipairs(rope.nodes) do
                if not node.pinned then
                    local pushDir = node.position - explosion.position
                    local dist = #pushDir
                    if dist < cfg.Radius and dist > 0.01 then
                        pushDir = pushDir / dist
                        local force = cfg.Force
                        if cfg.Falloff then
                            force = force * (1.0 - dist / cfg.Radius)
                        end
                        node.position = node.position + pushDir * (force * k)
                            + vector3(0, 0, force * 0.3 * k)   -- and up a little
                    end
                end
            end
        end
    end
end

--- Where an explosion near `center` is, by halving spheres (at most ~35 IsExplosionInSphere calls),
--- or nil when it never narrowed down at all (never "at the rope's middle").
function Rope.FindExplosionPosition(center, radius)
    local pos = center
    local r = radius
    local located = false

    for _ = 1, 5 do
        local half = r * 0.5
        local candidates = {
            pos,
            pos + vector3(half, 0, 0), pos - vector3(half, 0, 0),
            pos + vector3(0, half, 0), pos - vector3(0, half, 0),
            pos + vector3(0, 0, half), pos - vector3(0, 0, half),
        }

        local found = nil
        for _, candidate in ipairs(candidates) do
            if IsExplosionInSphere(-1, candidate.x, candidate.y, candidate.z, half) then
                found = candidate
                break
            end
        end

        if not found then break end
        located = true
        pos = found
        r = half
    end

    return located and pos or nil
end

-- ============================================================================
-- THE GROUND AND WALLS
-- ============================================================================

local MAP_FLAG = 1           -- the map itself (the ground, roads, buildings): always probed
local PROPS_FLAG = 16        -- props and objects: Config.WorldCollision.Props
local IGNORE_NEAR = 1.5      -- metres: a node's probes look through an anchor (rope.probeIgnore) this near it

--- What a rope's ground and wall probes see: the map always, so a rope never falls through the world, and props
--- unless Config.WorldCollision.Props is off (read each time: the settings page changes it live). A resource's rope
--- may say its own (opts.collide.props: server/api.lua).
function Rope.WorldFlags(rope)
    local props = Config.WorldCollision.Props ~= false
    local own = rope and rope.opts and rope.opts.collide
    if own and own.props ~= nil then props = own.props == true end
    return props and (MAP_FLAG + PROPS_FLAG) or MAP_FLAG
end
-- A node resting where it was last probed reuses that ground for this many 1/60 s steps (as long, at any rate)
local GROUND_REUSE_STEPS = 8
local GROUND_REUSE_MOVE = 0.05   -- metres it may have slid since

-- The ground under a node: a probe, or the last one's answer while the node rests where it was. `ignore`: an entity
-- the probe looks through (the rope's probeIgnore). `r`: this step in 1/60 s steps.
local function groundUnder(node, x, y, z, flags, ignore, r)
    local g = node.ground
    if g and g.steps > 0 and math.abs(x - g.x) < GROUND_REUSE_MOVE and math.abs(y - g.y) < GROUND_REUSE_MOVE
        and z < g.z + 0.2 and z > g.z - 0.2 then
        g.steps = g.steps - 1
        return g.hit, g.z
    end
    local hit, hitPos = SyncProbe(x, y, z + 0.2, x, y, z - 0.2, flags, ignore or 0)
    if not g then g = {}; node.ground = g end
    g.x, g.y, g.hit = x, y, hit
    g.z = hit and hitPos.z or z
    g.steps = hit and math.max(1, math.floor(GROUND_REUSE_STEPS / r + 0.5)) or 0
    return hit, g.z
end

-- ============================================================================
-- THE GROUND FROM A GRID (Config.WorldCollision.Ground = 'grid')
-- ============================================================================
-- The other way to find the ground, to compare with the rays above: the settings page swaps them, at once. The ground
-- is looked for once at each point of a grid GRID_CELL apart, every surface found down that point's column is kept,
-- and a node reads the four points round it (blended by how near it is to each) instead of casting a ray. Every rope
-- and every node there reads the same answers, so a rope moving over ground a rope has been on casts no ray. Every
-- node reads it (not only every CheckSpacing'th), as a read costs no ray. Walls, cars and people are found by rays.
--
-- A column is looked down a GRID_BAND at a time, as nodes come to it: a ray from the top of the slice, then on from
-- just under each surface it hits, so a node under a table or a bridge finds the floor it is on. What was found is
-- kept GRID_KEEP_MS (a column that found nothing, GRID_KEEP_EMPTY_MS: the map may not have loaded there yet), then
-- looked for again, so a prop moved or knocked over is seen again soon. Kept apart for the map alone and the map with
-- props (Rope.WorldFlags), which see different ground. A node near an anchor its rope looks through
-- (rope.probeIgnore) casts a ray: a kept column is every rope's, and cannot look through one rope's anchor.

local GRID_CELL = 0.25          -- metres between the grid's points
local GRID_BAND = 1.0           -- a column is looked down this much at a time (m)
local GRID_SURFACES = 4         -- the most surfaces one look down a slice finds (a ray each)
local GRID_KEEP_MS = 10000
local GRID_KEEP_EMPTY_MS = 1000
local GRID_MAX_COLUMNS = 40000  -- past this many kept, all are let go (a rope towed across the city)
local GRID_REACH = 0.2          -- a surface this far above or below a node is its ground (as the ray's two ends)

local Grid = { byFlags = {}, count = 0, tidiedAt = 0 }

--- A grid point's key: a number (no string made per read). x and y are within ±16 km in quarter metres.
local function columnKey(ix, iy) return (ix + 65536) * 131072 + (iy + 65536) end

--- Look down a column at (x, y) from `top` to `bottom`, adding each surface found.
local function lookDown(col, x, y, top, bottom, flags)
    local from = top
    for _ = 1, GRID_SURFACES do
        if from <= bottom then return end
        local hit, at = SyncProbe(x, y, from, x, y, bottom, flags, 0)
        if not hit then return end
        local z, s, seen = at.z, col.s, false
        for k = 1, #s do
            if math.abs(s[k] - z) < 0.01 then seen = true break end
        end
        if not seen then s[#s + 1] = z end
        from = z - 0.02
    end
end

--- Grid point (ix, iy)'s column, looked down far enough to cover zLo..zHi (looked for afresh once its time is up).
local function column(cols, ix, iy, zLo, zHi, flags, now)
    local key = columnKey(ix, iy)
    local col = cols[key]
    local x, y = ix * GRID_CELL, iy * GRID_CELL
    if not col or now > col.keep then
        if not col then Grid.count = Grid.count + 1 end
        local lo, hi = math.floor(zLo / GRID_BAND) * GRID_BAND, math.ceil(zHi / GRID_BAND) * GRID_BAND
        col = { lo = lo, hi = hi, s = {} }
        lookDown(col, x, y, hi, lo, flags)
        col.found = #col.s > 0
        col.keep = now + (col.found and GRID_KEEP_MS or GRID_KEEP_EMPTY_MS)
        cols[key] = col
        return col
    end
    if zHi > col.hi then
        local hi = math.ceil(zHi / GRID_BAND) * GRID_BAND
        lookDown(col, x, y, hi, col.hi, flags)
        col.hi = hi
    end
    if zLo < col.lo then
        local lo = math.floor(zLo / GRID_BAND) * GRID_BAND
        lookDown(col, x, y, col.lo, lo, flags)
        col.lo = lo
    end
    -- First looked at in the air (nothing found, kept a moment), and the ground found since: kept as long as any
    if not col.found and #col.s > 0 then
        col.found = true
        col.keep = now + GRID_KEEP_MS
    end
    return col
end

--- The ground under a node from the grid: (hit, z), as groundUnder answers. Each of the four points round it gives
--- its highest surface within GRID_REACH of the node; those it has are blended by nearness.
local function gridGround(x, y, z, flags, now)
    local cols = Grid.byFlags[flags]
    if not cols then cols = {}; Grid.byFlags[flags] = cols end
    local fx, fy = x / GRID_CELL, y / GRID_CELL
    local ix, iy = math.floor(fx), math.floor(fy)
    local tx, ty = fx - ix, fy - iy
    local top, bottom = z + GRID_REACH, z - GRID_REACH
    local sum, weights = 0.0, 0.0
    for c = 0, 3 do
        local dx, dy = c % 2, c // 2
        local w = (dx == 1 and tx or 1.0 - tx) * (dy == 1 and ty or 1.0 - ty)
        if w > 0.0 then
            local s = column(cols, ix + dx, iy + dy, bottom, top, flags, now).s
            local best = nil
            for k = 1, #s do
                local h = s[k]
                if h <= top and h >= bottom and (not best or h > best) then best = h end
            end
            if best then sum, weights = sum + best * w, weights + w end
        end
    end
    if weights < 1e-6 then return false, z end
    return true, sum / weights
end

--- Columns past their time let go every few seconds; all of them past GRID_MAX_COLUMNS, or once the rays are back.
local function tidyGrid(now, inUse)
    if not inUse then
        if Grid.count > 0 then Grid.byFlags, Grid.count = {}, 0 end
        return
    end
    if now - Grid.tidiedAt < 5000 then return end
    Grid.tidiedAt = now
    if Grid.count > GRID_MAX_COLUMNS then Grid.byFlags, Grid.count = {}, 0 return end
    local n = 0
    for _, cols in pairs(Grid.byFlags) do
        for key, col in pairs(cols) do
            if now > col.keep then cols[key] = nil else n = n + 1 end
        end
    end
    Grid.count = n
end

--- How many grid points are kept (/ropedebug).
function Rope.GridPoints() return Grid.count end

-- ============================================================================
-- CARS
-- ============================================================================

-- A car is curved and sloped all over, so the map's two probes don't suit it: straight down would lift a node that
-- touches a car's side up onto it (as much as 20 cm at a time), and the links would yank its neighbours after it,
-- so the rope never rests. On a car a node is pushed out along the car's own surface instead:
--   * moving, its move this step is swept: a ray from where the last step left it (outside) to a gap past where
--     it is now. A hit puts it that gap out from the surface, along the surface's normal.
--   * touching, it looks along that normal the next step (from a little outside the surface to a little inside),
--     so one lying on a slope stays where it lies instead of creeping in and being pushed back out. That surface is
--     kept a few steps while the node and the car stay put, as the ground's is.
-- Either way its speed into the car is taken away (nothing bounces back), the surface holds it against gravity as
-- the ground does (less the steeper it is: none up a car's side), and along it it slides with the ground's
-- friction. Only nodes within a car's reach look at all.

local CAR_FLAG = 2
local CAR_GAP = 0.05       -- how far off a car's surface a node rests (m)
local CAR_WINDOW = 0.15    -- a node touching a car looks this far either side of its surface (m)
local CAR_NEAR = 0.5       -- a node is looked at this far past a car's reach (m)
local CAR_STILL = 0.25     -- m/s: a node slower than this that isn't touching a car is lying still: not swept
local CAR_REUSE_STEPS = 8  -- a touching node reuses its surface this many 1/60 s steps (as long, at any rate)
local CAR_REUSE_MOVE = 0.05   -- metres it may have slid since
local CAR_HOLD_FLAT = 0.7  -- the surface's normal this upright (~45° or flatter) holds a node against gravity fully
local CAR_HOLD_STEEP = 0.3 -- this little upright (~72° or steeper) not at all

local Cars = { at = 0, list = {} }
local reachOf = {}         -- [model] = how far its furthest corner is from its middle (m)

local function carReach(model)
    local r = reachOf[model]
    if not r then
        local mn, mx = GetModelDimensions(model)
        r = math.max(#mn, #mx)
        reachOf[model] = r
    end
    return r
end

-- The cars about, and where, every 250 ms: a step reads a car's live position only once its cached one is near
local function refreshCars()
    local now = GetGameTimer()
    if now - Cars.at <= 250 then return end
    Cars.at = now
    -- Its entries filled again in place, as the ped cache's
    local list, n = Cars.list, 0
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        local c = GetEntityCoords(veh)
        n = n + 1
        local e = list[n]
        if not e then e = {}; list[n] = e end
        e.e, e.x, e.y, e.z, e.r = veh, c.x, c.y, c.z, carReach(GetEntityModel(veh))
    end
    for i = #list, n + 1, -1 do list[i] = nil end
end

-- The cars near this rope now, { e, x, y, z, r2 } (r2: how near a node must be to look, squared), or nil
local function carsNear(nodes)
    refreshCars()
    local list = Cars.list
    if not list[1] then return nil end
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    for i = 1, #nodes do
        local p = nodes[i].position
        if p.x < minX then minX = p.x end
        if p.y < minY then minY = p.y end
        if p.z < minZ then minZ = p.z end
        if p.x > maxX then maxX = p.x end
        if p.y > maxY then maxY = p.y end
        if p.z > maxZ then maxZ = p.z end
    end
    local near = nil
    for _, c in ipairs(list) do
        -- The cached spot may be 250 ms old: a car at 30 m/s is 7.5 m on
        local m = c.r + CAR_NEAR + 8.0
        if c.x > minX - m and c.x < maxX + m and c.y > minY - m and c.y < maxY + m
            and c.z > minZ - m and c.z < maxZ + m and DoesEntityExist(c.e) then
            local p = GetEntityCoords(c.e)
            local reach = c.r + CAR_NEAR
            near = near or {}
            near[#near + 1] = { e = c.e, x = p.x, y = p.y, z = p.z, r2 = reach * reach }
        end
    end
    return near
end

--- Does this rope look at cars (Config.WorldCollision.Vehicles, or its resource's opts.collide.vehicles)?
local function looksAtCars(rope)
    local vehicles = Config.WorldCollision.Vehicles == true
    local own = rope.opts and rope.opts.collide
    if own and own.vehicles ~= nil then vehicles = own.vehicles == true end
    return vehicles
end

--- Would anything about move a rope lying still in `box` ({ x0, y0, z0, x1, y1, z1 }: a rope at rest, client/main.lua)?
--- What its step answers to, with the step's own margins and speeds: someone near it moving or fallen
--- (ApplyPlayerInteraction), a car near it moving (pushOffCars, when the rope looks at cars), an explosion
--- (ApplyExplosionInteraction). Answers what, or nil.
---@return string|nil
function Rope.DisturbedNear(rope, box)
    if Rope.System.recentExplosions[1] then return 'an explosion' end
    local pi = Config.PlayerInteraction
    if pi.Enabled then
        refreshPedCache()
        local m = pi.Radius + 2.0 + 4.0
        for _, e in ipairs(Rope.PedCache.peds) do
            if e.x >= box[1] - m and e.x <= box[4] + m and e.y >= box[2] - m and e.y <= box[5] + m
                and e.z >= box[3] - m and e.z <= box[6] + m and DoesEntityExist(e.ped) and not IsEntityDead(e.ped)
                and (GetEntitySpeed(e.ped) >= 0.3 or IsPedRagdoll(e.ped)) then
                return 'someone moving near it'
            end
        end
    end
    if looksAtCars(rope) then
        refreshCars()
        for _, c in ipairs(Cars.list) do
            local m = c.r + CAR_NEAR + 8.0
            if c.x > box[1] - m and c.x < box[4] + m and c.y > box[2] - m and c.y < box[5] + m
                and c.z > box[3] - m and c.z < box[6] + m and DoesEntityExist(c.e) and GetEntitySpeed(c.e) > 0.2 then
                return 'a car moving near it'
            end
        end
    end
    return nil
end

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

local function nearACar(p, near)
    for i = 1, #near do
        local c = near[i]
        local dx, dy, dz = p.x - c.x, p.y - c.y, p.z - c.z
        if dx * dx + dy * dy + dz * dz < c.r2 then return true end
    end
    return false
end

-- The car `e` among those near, where it is this step (nil: not near)
local function carAt(near, e)
    for i = 1, #near do
        if near[i].e == e then return near[i] end
    end
    return nil
end

-- Every loose node near a car, off it. `friction`: the ground's, kept per this step. node.onCar = the normal of the
-- car's surface it touched last step (nil: none); node.carPlane = that surface as last probed, and where the node
-- and the car were then.
local function pushOffCars(nodes, near, dt, r, friction)
    local kept = Rope.KeptOver
    local still = CAR_STILL * dt
    local gStep = Config.Physics.Gravity * (dt * dt)
    local reuse = math.max(1, math.floor(CAR_REUSE_STEPS / r + 0.5))
    for i = 1, #nodes do
        local node = nodes[i]
        if not node.pinned then
            local to = node.position
            local touching = node.onCar
            if not nearACar(to, near) then
                node.onCar, node.carPlane = nil, nil
            else
                local from = node.previousPosition
                local move = to - from
                local len = #move
                local hit, at, n = false, nil, nil
                -- Touching: its surface again (kept while it and the car stay put, else probed along its normal)
                if touching then
                    local pl = node.carPlane
                    local car = pl and pl.steps > 0 and carAt(near, pl.e)
                    if car and math.abs(car.x - pl.cx) < 0.01 and math.abs(car.y - pl.cy) < 0.01
                        and math.abs(car.z - pl.cz) < 0.01 and #(to - pl.p) < CAR_REUSE_MOVE then
                        pl.steps = pl.steps - 1
                        hit, at, n = true, pl.at, pl.n
                    else
                        local c = touching
                        local h, hp, hn, he = SyncProbe(
                            to.x + c.x * CAR_WINDOW, to.y + c.y * CAR_WINDOW, to.z + c.z * CAR_WINDOW,
                            to.x - c.x * CAR_WINDOW, to.y - c.y * CAR_WINDOW, to.z - c.z * CAR_WINDOW, CAR_FLAG, 0)
                        node.carPlane = nil
                        if h then
                            if #hn < 0.5 then hn = c elseif dot(hn, c) < 0 then hn = hn * -1.0 end
                            hit, at, n = true, hp, hn / #hn
                            local carNow = carAt(near, he)
                            if carNow then
                                node.carPlane = { e = he, cx = carNow.x, cy = carNow.y, cz = carNow.z, p = to,
                                                  at = at, n = n, steps = reuse }
                            end
                        end
                    end
                end
                -- Moving, and not on that surface: its move swept
                if not hit and (len > still or (touching and len > 0.0001)) then
                    local d = move / len
                    local h, hp, hn = SyncProbe(from.x, from.y, from.z,
                        to.x + d.x * CAR_GAP, to.y + d.y * CAR_GAP, to.z + d.z * CAR_GAP, CAR_FLAG, 0)
                    if h then
                        if #hn < 0.5 then hn = d * -1.0 elseif dot(hn, d) > 0 then hn = hn * -1.0 end
                        hit, at, n = true, hp, hn / #hn
                    end
                end
                if not hit then
                    node.onCar, node.carPlane = nil, nil
                else
                    ---@cast n -nil -- set with hit
                    local dist = dot(to - at, n)
                    if dist > CAR_GAP * 2 then
                        node.onCar, node.carPlane = nil, nil   -- lifted off it
                    else
                        node.onCar = n
                        if dist < CAR_GAP + 0.01 then
                            -- Held against gravity: its slide down the slope this step taken back
                            local hold = (n.z - CAR_HOLD_STEEP) / (CAR_HOLD_FLAT - CAR_HOLD_STEEP)
                            hold = math.min(math.max(hold, 0.0), 1.0)
                            local v = move
                            if hold > 0 then
                                local slide = (gStep - n * dot(gStep, n)) * hold
                                to = to - slide
                                v = v - slide
                            end
                            local pos = dist < CAR_GAP and (to + n * (CAR_GAP - dist)) or to
                            local vn = dot(v, n)
                            if vn < 0 then v = v - n * vn end
                            local speed = #v
                            local f = friction
                            if speed < 0.05 * r then
                                f = kept(0.3, r)
                            elseif speed < 0.1 * r then
                                f = kept(0.5, r)
                            end
                            node.position = pos
                            node.previousPosition = pos - v * f
                        end
                    end
                end
            end
        end
    end
end

function Rope.ApplyWorldCollision(rope, dt)
    local cfg = Config.WorldCollision
    -- This step in 1/60 s steps: a node's move this step is its speed × this step's length, so the speeds below
    -- (read as moves in a 1/60 s step) are scaled by it, and each friction is a share kept per 1/60 s
    local r = Rope.StepScale(dt)
    local kept = Rope.KeptOver

    -- A resource's rope may probe its own way (opts.collide: every Nth node, cars or not, props or not: a pump's hose)
    local own = rope.opts and rope.opts.collide
    local checkSpacing = own and own.spacing or cfg.CheckSpacing or 2
    local vehicles = looksAtCars(rope)
    local flags = Rope.WorldFlags(rope)
    local groundOffset = cfg.GroundOffset or 0.05
    local groundFriction = kept(cfg.GroundFriction or 0.7, r)
    local wallOffset = cfg.WallOffset or 0.06
    local wallFriction = kept(0.5, r)
    -- What this rope's probes look through (rope.probeIgnore = { [entity] = true }): what a body hangs from on it, an
    -- invisible anchor with collision, which the node beside it would take for ground and be lifted onto.
    -- A probe can look through one entity, so each node looks through the anchor nearest it (within IGNORE_NEAR):
    -- several people hanging off one rope each have their own.
    local anchors = nil
    if rope.probeIgnore then
        for e in pairs(rope.probeIgnore) do
            if DoesEntityExist(e) then
                anchors = anchors or {}
                anchors[#anchors + 1] = { e = e, at = GetEntityCoords(e) }
            else
                rope.probeIgnore[e] = nil
            end
        end
    end
    local function ignoreNear(pos)
        if not anchors then return 0 end
        local best, bestD = 0, IGNORE_NEAR * IGNORE_NEAR
        for _, a in ipairs(anchors) do
            local dx, dy, dz = a.at.x - pos.x, a.at.y - pos.y, a.at.z - pos.z
            local d = dx * dx + dy * dy + dz * dz
            if d < bestD then best, bestD = a.e, d end
        end
        return best
    end

    local nodes = rope.nodes
    local nodeCount = #nodes

    -- Cars first: a node's move this step is still from where the last step left it (the ground's friction below
    -- moves that start)
    local near = vehicles and carsNear(nodes) or nil
    if near then
        pushOffCars(nodes, near, dt or REF_DT, r, groundFriction)
        rope.nearCars = true
    elseif rope.nearCars then
        rope.nearCars = nil
        for i = 1, nodeCount do nodes[i].onCar = nil end
    end

    -- The ground from the grid (Config.WorldCollision.Ground, the settings page) or by rays
    local grid = cfg.Ground == 'grid'
    local now = GetGameTimer()
    tidyGrid(now, grid)

    for i = 1, nodeCount do
        local node = nodes[i]
        -- Every Nth node, and both ends (a loose end is the part most likely to hit something). On the grid every
        -- node reads the ground (no ray to it); walls stay with the checked nodes.
        local checked = i % checkSpacing == 0 or i == 1 or i == nodeCount
        if not node.pinned and (checked or grid) then
            local velocity = node.position - node.previousPosition

            if #velocity >= 0.001 * r then
                local pos = node.position

                -- The ground: the grid's, or a ray (always a ray beside an anchor this rope looks through)
                local ignore = ignoreNear(pos)
                local groundHit, hitZ
                if grid and ignore == 0 then
                    groundHit, hitZ = gridGround(pos.x, pos.y, pos.z, flags, now)
                else
                    groundHit, hitZ = groundUnder(node, pos.x, pos.y, pos.z, flags, ignore, r)
                end
                if groundHit then
                    local groundZ = hitZ + groundOffset
                    local penetration = groundZ - pos.z

                    if penetration > 0 then
                        node.position = vector3(pos.x, pos.y, groundZ)
                        if velocity.z < 0 then
                            velocity = vector3(velocity.x, velocity.y, 0)
                        end
                        velocity = vector3(velocity.x * groundFriction, velocity.y * groundFriction, velocity.z)
                        node.previousPosition = node.position - velocity
                    elseif penetration > -0.1 then
                        local hSpeed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
                        local friction = groundFriction
                        if hSpeed < 0.05 * r then
                            friction = kept(0.3, r)
                        elseif hSpeed < 0.1 * r then
                            friction = kept(0.5, r)
                        end
                        velocity = vector3(velocity.x * friction, velocity.y * friction, velocity.z)
                        node.previousPosition = node.position - velocity
                    end
                end

                -- Walls, only while it moves sideways: one ray the way it is going, from the height the
                -- ground check left it at (not the old height, which would sink it again).
                local hSpeed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
                if checked and hSpeed >= 0.005 * r then
                    pos = node.position
                    local dirX, dirY = velocity.x / hSpeed, velocity.y / hSpeed
                    local wallHit, wallHitPos = SyncProbe(
                        pos.x, pos.y, pos.z,
                        pos.x + dirX * 0.15, pos.y + dirY * 0.15, pos.z,
                        flags, ignore or 0)

                    if wallHit then
                        local dx, dy = pos.x - wallHitPos.x, pos.y - wallHitPos.y
                        if math.sqrt(dx * dx + dy * dy) < wallOffset then
                            -- Straight back along the ray
                            node.position = vector3(
                                wallHitPos.x - dirX * wallOffset,
                                wallHitPos.y - dirY * wallOffset,
                                pos.z)
                            local velIntoWall = velocity.x * dirX + velocity.y * dirY
                            if velIntoWall > 0 then
                                velocity = velocity - vector3(dirX * velIntoWall, dirY * velIntoWall, 0)
                                velocity = velocity * wallFriction
                            end
                            node.previousPosition = node.position - velocity
                        end
                    end
                end
            end
        end
    end

    -- On the grid every node has read its own ground (above)
    if grid then return end

    -- The unchecked nodes in between: never below the lower of their neighbours' ground. No probes of
    -- their own; only a loose neighbour's reading taken right beside this node counts (a pinned end's
    -- reading is stale).
    local function groundBeside(other, p)
        if other.pinned then return nil end
        local g = other.ground
        if not g or not g.hit then return nil end
        local dx, dy = g.x - p.x, g.y - p.y
        if dx * dx + dy * dy > 0.6 * 0.6 or math.abs(g.z - p.z) > 1.0 then return nil end
        return g.z
    end
    for i = 2, nodeCount - 1 do
        local node = nodes[i]
        if not node.pinned and i % checkSpacing ~= 0 then
            local p = node.position
            local za, zb = groundBeside(nodes[i - 1], p), groundBeside(nodes[i + 1], p)
            local floorZ = za
            if zb and (not floorZ or zb < floorZ) then floorZ = zb end
            if floorZ then
                floorZ = floorZ + groundOffset
                if p.z < floorZ then
                    local v = p - node.previousPosition
                    node.position = vector3(p.x, p.y, floorZ)
                    node.previousPosition = node.position
                        - vector3(v.x * groundFriction, v.y * groundFriction, math.max(v.z, 0.0))
                end
            end
        end
    end
end
