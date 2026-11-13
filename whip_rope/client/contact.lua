--[[
    whip_rope — ROPES AGAINST EACH OTHER

    Two ropes do not pass through each other (Config.RopeContact, also on the settings page). Once every rope has taken
    its step (client/main.lua), each link that has come within Gap of another rope's link is pushed apart from it: the
    nearest points of the two links, by moving the four nodes at their ends, each by how near it is to that point and
    how light it is (a pinned end, in a hand or tied to something, does not move). Their speed into each other is
    taken away and some of their slide along each other (Slide), so a rope laid over another rests on it and catches a
    little, rather than bouncing off.

    Cheap while ropes are apart: each rope's box is checked first, and only ropes whose boxes meet go further. Their
    links are then put in a grid of cells about a link across, and a link is only held against the links in its own
    cell and the 26 round it, never against every link of every rope.

    A rope against itself is not looked at: a rope lying in a coil can still pass through itself. Two links that go
    right past each other in one step, from about half a metre a step (some 28 m/s, a car towing one rope across
    another at 100 km/h), can be missed: links are put in cells by where they are now, and by then they can be too far
    apart for their cells to be neighbours.

    TAKING EACH OTHER'S WEIGHT (Config.RopeContact.Carry, off unless turned on). Held apart once a step, after each
    rope has pulled itself to length, a rope only moves the other's nodes: cars dropped onto a rope across a hole fall
    on as if it were not there, their rope is dragged down through it a little more each step and slips off. With
    Carry on (Rope.StepTogether, from client/main.lua), the ropes near each other are pulled to length a pass at a
    time and held apart after every pass, so neither can drag the other through; where two cross they are held apart
    as one crossing (CROSSINGS, below); and each rope remembers where it rests on another (rope.wrap), so its pull
    runs along that bent path to what it is tied to (client/physics.lua).

    What to expect: two cars dropped onto a rope held across a hole between two cars drag those two in; onto one tied
    to the hole's walls, they are caught and hang. Under that load (30 kN) the one on top dips up to 12 cm into the
    other for a step and comes back. A rope's pull is at most 2 g (Config.Coupling.MaxAcceleration), so cars caught
    falling fast stretch both ropes a long way first (twice their length from 8 m). A rope dragged sideways into
    another, curving along it, can come 2 cm into it for a moment (4 cm, the gap, without Carry).
]]

local EPS = 1e-9
local LEVER = 2.0   -- the most a node is moved, as a share of what two links are missing (touch: near a held end)
local REST = 0.02   -- m past the gap that two ropes still count as resting on each other (Carry: steadies rope.wrap)

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross(a, b) return vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) end
local function clamp01(v) if v < 0.0 then return 0.0 elseif v > 1.0 then return 1.0 end return v end

--- How much of a push a node takes: none pinned, else by how light it is.
local function give(node) return node.pinned and 0.0 or (node.invMass or 2.0) end

--- The nearest points of links p1-q1 and p2-q2, as how far along each (0..1).
local function nearest(p1, q1, p2, q2)
    local d1, d2, rr = q1 - p1, q2 - p2, p1 - p2
    local a, e, f = dot(d1, d1), dot(d2, d2), dot(d2, rr)
    if a <= EPS and e <= EPS then return 0.0, 0.0 end
    if a <= EPS then return 0.0, clamp01(f / e) end
    local c = dot(d1, rr)
    if e <= EPS then return clamp01(-c / a), 0.0 end
    local b = dot(d1, d2)
    local denom = a * e - b * b
    local s = denom > EPS and clamp01((b * f - c * e) / denom) or 0.0
    local t = (b * s + f) / e
    if t < 0.0 then
        return clamp01(-c / a), 0.0
    elseif t > 1.0 then
        return clamp01((b - c) / a), 1.0
    end
    return s, t
end

-- This pass's number. After each pass every node of a rope near another keeps where it was (node.touchAt) and the
-- pass (node.touchPass), so the next pass knows which side of each other two links were. Not the node's
-- previousPosition: the ground and the walls rewrite that to brake it (its speed into the ground taken away), so on
-- the ground it says nothing of where the node was.
local pass = 0

--- Where a link's point `s` along it was at the last pass, if both its nodes were seen then.
local function wasAt(n0, n1, s)
    local last = pass - 1
    if n0.touchPass ~= last or n1.touchPass ~= last then return nil end
    return n0.touchAt * (1.0 - s) + n1.touchAt * s
end

--- Push link `ka` of rope nodes `na` and link `kb` of `nb` apart if they are closer than `gap`, on the side each was
--- on at the last pass. `keep`: the share of their slide along each other kept. `speed`: their speed into each other
--- taken away too (once a step: between the passes, only their places). `rest`: how far past the gap they still count
--- as resting on each other (0 unless Carry). `across` (Carry): the way the two ropes are apart where they cross
--- (acrossOf), from A to B. Answers whether they were pushed, whether they rest on each other, and where (s, t).
---
--- The side is the last pass's, not now's: a rope falling onto another moves further than the gap in a step, and by
--- now may be just past it. Pushed apart the way they now are, it would go on through (and the one below come to rest
--- on top of it). For the same reason a pair is looked at as far apart as the gap plus how far they moved against
--- each other since.
---
--- Where two ropes cross (Carry): they touch where they cross seen along `across`, and are apart along it, however
--- far one has been dragged past the other. Links only beside each other seen that way are not touching.
local function touch(na, ka, nb, kb, gap, keep, speed, rest, across)
    local a0, a1, b0, b1 = na[ka], na[ka + 1], nb[kb], nb[kb + 1]
    local pa0, pa1, pb0, pb1 = a0.position, a1.position, b0.position, b1.position
    local s, t
    local n = across
    if n then
        -- Seen along `across`: flattened onto the plane square to it
        local fa0, fa1 = pa0 - n * dot(pa0, n), pa1 - n * dot(pa1, n)
        local fb0, fb1 = pb0 - n * dot(pb0, n), pb1 - n * dot(pb1, n)
        s, t = nearest(fa0, fa1, fb0, fb1)
        if #((fb0 + (fb1 - fb0) * t) - (fa0 + (fa1 - fa0) * s)) >= gap then return false, false end
    else
        s, t = nearest(pa0, pa1, pb0, pb1)
    end
    local pa = pa0 + (pa1 - pa0) * s
    local pb = pb0 + (pb1 - pb0) * t
    local d = pb - pa

    if not n then
        local qa, qb = wasAt(a0, a1, s), wasAt(b0, b1, t)
        local was = (qa and qb) and (qb - qa) or nil
        local dist = #d
        if dist >= gap + math.max(was and #(d - was) or 0.0, rest) then return false, false end
        -- The side B was on: the last pass's way from A to B, or now's if not seen then or on top of each other then
        local wasDist = was and #was or 0.0
        if wasDist > 1e-5 then
            n = was / wasDist
        elseif dist > 1e-5 then
            n = d / dist
        else
            -- Right on top of each other, then and now: apart across both links
            local c = cross(pa1 - pa0, pb1 - pb0)
            local cl = #c
            n = cl > 1e-6 and c / cl or vector3(0.0, 0.0, 1.0)
        end
    end

    -- Each node's share: how near it is to the touching point, times how light it is
    local wa0, wa1, wb0, wb1 = (1.0 - s) * give(a0), s * give(a1), (1.0 - t) * give(b0), t * give(b1)
    local W = (1.0 - s) * wa0 + s * wa1 + (1.0 - t) * wb0 + t * wb1
    if W < 1e-6 then return false, false end   -- all four held fast

    local along = dot(d, n)   -- how far apart they are now on that side (below 0: past each other)
    if along >= gap then return false, along < gap + rest, s, t end

    -- Apart, to the gap on that side: the nearest points move by exactly what was missing. Except near a held end: a
    -- point there moves its free node a long way (a lever), and two ropes tied to one hook would kick each other
    -- about. No node moves more than LEVER times what is missing; such a pair eases apart over a few steps instead.
    local share = math.max(wa0, wa1, wb0, wb1) / W
    local ease = share > LEVER and LEVER / share or 1.0
    local lambda = (gap - along) / W * ease
    a0.position = pa0 - n * (lambda * wa0)
    a1.position = pa1 - n * (lambda * wa1)
    b0.position = pb0 + n * (lambda * wb0)
    b1.position = pb1 + n * (lambda * wb1)
    if not speed then return true, true, s, t end

    -- Their speed into (and off) each other taken away, and some of their slide along each other: a change J to how
    -- the two points move against each other, shared as the push was (a node's speed is its position less its last)
    local va = (a0.position - a0.previousPosition) * (1.0 - s) + (a1.position - a1.previousPosition) * s
    local vb = (b0.position - b0.previousPosition) * (1.0 - t) + (b1.position - b1.previousPosition) * t
    local rel = vb - va
    local vn = dot(rel, n)
    local J = (n * (-vn) - (rel - n * vn) * (1.0 - keep)) * ease
    a0.previousPosition = a0.previousPosition + J * (wa0 / W)
    a1.previousPosition = a1.previousPosition + J * (wa1 / W)
    b0.previousPosition = b0.previousPosition - J * (wb0 / W)
    b1.previousPosition = b1.previousPosition - J * (wb1 / W)
    return true, true, s, t
end

local function boxOf(nodes, pad)
    local p = nodes[1].position
    local x0, y0, z0, x1, y1, z1 = p.x, p.y, p.z, p.x, p.y, p.z
    for i = 2, #nodes do
        p = nodes[i].position
        local x, y, z = p.x, p.y, p.z
        if x < x0 then x0 = x elseif x > x1 then x1 = x end
        if y < y0 then y0 = y elseif y > y1 then y1 = y end
        if z < z0 then z0 = z elseif z > z1 then z1 = z end
    end
    return { x0 - pad, y0 - pad, z0 - pad, x1 + pad, y1 + pad, z1 + pad }
end

local function boxesMeet(a, b)
    return a[1] <= b[4] and b[1] <= a[4] and a[2] <= b[5] and b[2] <= a[5] and a[3] <= b[6] and b[3] <= a[6]
end

-- Ropes this near each other (m, past the gap) are looked at, and their nodes' places kept from pass to pass, so that
-- by the time two links touch, where they were the pass before is known
local NEAR = 0.3

--- A cell's key: a number. x and y within ±32 km of cells, z within ±4 km.
local function cellKey(ix, iy, iz) return ((ix + 131072) * 262144 + (iy + 131072)) * 32768 + (iz + 16384) end

-- A link's place in a cell: its rope's number in this step's list × LINKS + its first node
local LINKS = 4096

--- How many links touched another rope's in the last step (/ropedebug).
Rope.Touching = 0

-- This step's ropes (Rope.TouchFind), the ones near another, and the pairs of their links near enough to look at:
-- link KA[c] of rope LIST[PA[c]] against link KB[c] of rope LIST[PB[c]], PAIRS of them
local LIST, NEARBY = {}, {}
local PA, KA, PB, KB, PAIRS = {}, {}, {}, {}, 0
local GAP, KEEP, RESTING, CARRY = 0.04, 1.0, 0.0, false

-- WHERE TWO ROPES CROSS (Carry). Under a load, both ropes bend sharply where one rests on the other, and each pair of
-- links there makes its own way apart (tilted by the bend). Pushed each its own way they fight, and the rope on top
-- wanders off sideways and through; and the arms of the one on top hang steeply either side of the other, their
-- links nearer it than the gap for a way down. So each pair of ropes near each other (rope LIST[i] and LIST[j], their
-- pairs of links near each other in `pairs`) is one crossing, CROSSINGS[x]: the one place they touch (u along rope i,
-- v along rope j, a link and how far along it), followed from pass to pass among the links round it (crossAt); and
-- one way the two are apart there (n, from i toward j: from the bend of the one to the bend of the other, acrossOf),
-- on a side that sticks for as long as they stay near. Kept from step to step in KEPT: a rope dragged a long way past
-- the other is still pushed back to its side, at the place it crosses. Two ropes lying side by side there are not a
-- crossing: link by link, as without Carry.
local CROSSINGS, NCROSS, CROSSING_OF = {}, 0, {}
local KEPT = {}     -- [rope a][rope b] = { side (from a to b), u (along a), v (along b) } at the last step's end
local WINDOW = 2    -- links either side of where a crossing was that are looked at for where it is now

--- Do ropes take each other's weight (Config.RopeContact.Carry, with contact on)?
function Rope.Carrying()
    local cfg = Config.RopeContact
    return cfg ~= nil and cfg.Enabled == true and cfg.Carry == true
end

--- This step's pairs of links to look at, of every rope stepping in `ropes`. `dt`: the step's length. Answers the
--- ropes near another (an array, kept until the next call).
function Rope.TouchFind(ropes, dt)
    PAIRS, NCROSS = 0, 0
    for i = #NEARBY, 1, -1 do NEARBY[i] = nil end
    for i = #LIST, 1, -1 do LIST[i] = nil end
    -- (Where each rested the step before is kept until this step's end, Rope.TouchDone: its snap-back reads it)
    for _, rope in pairs(ropes) do rope.restCount = 0 end
    local cfg = Config.RopeContact
    if not cfg or not cfg.Enabled then
        for _, rope in pairs(ropes) do rope.wrap = nil end
        Rope.Touching = 0
        return NEARBY
    end
    local gap = tonumber(cfg.Gap) or 0.04
    GAP, KEEP = gap, Rope.KeptOver(tonumber(cfg.Slide) or 0.85, Rope.StepScale(dt))
    CARRY = cfg.Carry == true
    RESTING = CARRY and REST or 0.0

    -- The ropes stepping, and which of them have another rope's box meeting theirs
    local list = LIST
    for _, rope in pairs(ropes) do
        local nodes = rope.nodes
        -- (Not one at rest: it is woken before another rope comes near it, client/main.lua)
        if rope.simulated ~= false and not rope.resting and nodes and #nodes >= 2 and #nodes < LINKS then
            list[#list + 1] = rope
        end
    end
    if #list < 2 then Rope.Touching = 0 return NEARBY end
    pass = pass + 1
    local boxes = {}
    for i = 1, #list do boxes[i] = boxOf(list[i].nodes, gap + NEAR) end
    local near, any = {}, false
    for i = 1, #list - 1 do
        for j = i + 1, #list do
            if boxesMeet(boxes[i], boxes[j]) then near[i], near[j], any = true, true, true end
        end
    end
    if not any then Rope.Touching = 0 return NEARBY end

    -- Their links into cells a link (and the gap) across, by the link's middle: two links within the gap of each other
    -- are then in the same cell or neighbouring ones
    local size = gap
    for i in pairs(near) do size = math.max(size, Rope.LinkLength(list[i]) + gap) end
    -- (Carry: by the longest link as it is now. A rope holding a load is stretched, its links longer than their
    -- length, and two of them touching can then be further apart by their middles than one cell.)
    if CARRY then
        for i in pairs(near) do
            local nodes = list[i].nodes
            for k = 1, #nodes - 1 do
                local l = #(nodes[k + 1].position - nodes[k].position) + gap
                if l > size then size = l end
            end
        end
    end
    local cells = {}
    for i in pairs(near) do
        local nodes = list[i].nodes
        for k = 1, #nodes - 1 do
            local a, b = nodes[k].position, nodes[k + 1].position
            local key = cellKey(math.floor((a.x + b.x) * 0.5 / size), math.floor((a.y + b.y) * 0.5 / size),
                math.floor((a.z + b.z) * 0.5 / size))
            local cell = cells[key]
            if not cell then cell = {}; cells[key] = cell end
            cell[#cell + 1] = i * LINKS + k
        end
    end

    -- Each link against the other ropes' links round it, each pair once (the lower-numbered rope's link asks)
    local byPair = CARRY and {} or nil
    for i in pairs(near) do
        local nodes = list[i].nodes
        for k = 1, #nodes - 1 do
            local pa, pb = nodes[k].position, nodes[k + 1].position
            local cx = math.floor((pa.x + pb.x) * 0.5 / size)
            local cy = math.floor((pa.y + pb.y) * 0.5 / size)
            local cz = math.floor((pa.z + pb.z) * 0.5 / size)
            for dx = -1, 1 do
                for dy = -1, 1 do
                    for dz = -1, 1 do
                        local cell = cells[cellKey(cx + dx, cy + dy, cz + dz)]
                        if cell then
                            for c = 1, #cell do
                                local packed = cell[c]
                                local j = packed // LINKS
                                if j > i then
                                    local p, m = PAIRS + 1, packed % LINKS
                                    PAIRS = p
                                    PA[p], KA[p], PB[p], KB[p] = i, k, j, m
                                    if byPair then
                                        -- (Carry: the crossing of ropes i and j)
                                        local key = i * LINKS + j
                                        local x = byPair[key]
                                        if not x then
                                            NCROSS = NCROSS + 1
                                            local mine = KEPT[list[i]]
                                            local was = mine and mine[list[j]]
                                            x = { i = i, j = j, pairs = {},
                                                side = was and was.side, u = was and was.u, v = was and was.v }
                                            CROSSINGS[NCROSS], byPair[key] = x, x
                                        end
                                        x.pairs[#x.pairs + 1] = p
                                        CROSSING_OF[p] = x
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    for i in pairs(near) do NEARBY[#NEARBY + 1] = list[i] end
    return NEARBY
end

--- Where `rope` rests on another this step: on link `k`, `s` along it, at `at`. Not on its first or last link: there
--- it is leaving what holds it, not resting on anything.
local function restsAt(rope, k, s, at)
    if k <= 1 or k >= #rope.nodes - 1 then return end
    local n = (rope.restCount or 0) + 1
    rope.restCount = n
    local A, P = rope.restAlong, rope.restAt
    if not A then A, P = {}, {}; rope.restAlong, rope.restAt = A, P end
    A[n], P[n] = k + s, at
end

--- Where a crossing's two ropes first met: of its links, the two nearest each other, the way from the first to the
--- second there at the last pass (or now, not seen then), and the place (along each).
local function metAt(x)
    local na, nb = LIST[x.i].nodes, LIST[x.j].nodes
    local best, side, u, v = math.huge, nil, nil, nil
    for _, c in ipairs(x.pairs) do
        local ka, kb = KA[c], KB[c]
        local a0, a1, b0, b1 = na[ka], na[ka + 1], nb[kb], nb[kb + 1]
        local s, t = nearest(a0.position, a1.position, b0.position, b1.position)
        local d = (b0.position + (b1.position - b0.position) * t) - (a0.position + (a1.position - a0.position) * s)
        local dist = #d
        if dist < best then
            local qa, qb = wasAt(a0, a1, s), wasAt(b0, b1, t)
            best, side, u, v = dist, (qa and qb) and (qb - qa) or d, ka + s, kb + t
        end
    end
    return side, u, v
end

--- Which way a rope runs at `u` along it (a link and how far along it): at the node nearest, the way in and the way
--- out of it, each as a direction, added. Where it is bent over another rope with its arms hanging straight down, it
--- still runs level across the top, however short its arms' offset either side.
local function runsAt(nodes, u)
    local k = math.max(1, math.min(#nodes, math.floor(u + 0.5)))
    local p = nodes[k].position
    local way = vector3(0.0, 0.0, 0.0)
    if k < #nodes then
        local d = nodes[k + 1].position - p
        local l = #d
        if l > 1e-6 then way = way + d / l end
    end
    if k > 1 then
        local d = p - nodes[k - 1].position
        local l = #d
        if l > 1e-6 then way = way + d / l end
    end
    return way
end

--- How a rope is bent round `u` along it: the way it runs into the links round there (two either side) less the way
--- it runs out. Laid over another rope, its arms going down either side, it is bent up (the way into the bend
--- climbs, the way out falls), however its arms hang; a rope run straight there is not bent (about nothing).
local function bentAt(nodes, u)
    local k = math.floor(u)
    local k0, k1 = math.max(k - 2, 1), math.min(k + 2, #nodes - 1)
    local into = nodes[k0 + 1].position - nodes[k0].position
    local out = nodes[k1 + 1].position - nodes[k1].position
    local li, lo = #into, #out
    if li < 1e-6 or lo < 1e-6 then return vector3(0.0, 0.0, 0.0) end
    return into / li - out / lo
end

--- A crossing's way apart now (x.n), on its side. Where they bend over each other (the one on top bent up over the
--- other, which is bent down under it), from the bend of the one to the bend of the other; two ropes run straight
--- across each other, square to the way both run there. None while the two run nearly alongside each other there
--- (link by link then).
local function acrossOf(x)
    x.n = nil
    if not x.u or not x.side then
        local side, u, v = metAt(x)
        x.side, x.u, x.v = x.side or side, u, v
    end
    if not x.side or not x.u then return end
    local na, nb = LIST[x.i].nodes, LIST[x.j].nodes
    local n
    local bent = bentAt(nb, x.v) - bentAt(na, x.u)
    local bl = #bent
    if bl > 0.3 then
        n = bent / bl
    else
        local ra, rb = runsAt(na, x.u), runsAt(nb, x.v)
        local c = cross(ra, rb)
        local cl = #c
        if cl <= 0.25 * #ra * #rb then return end   -- (nearly the same way, and not bent: link by link)
        n = c / cl
    end
    -- Lying side by side there rather than across (two links round it touching that, seen along n, run within about
    -- 30 degrees of each other: a rope curving into another as it is dragged across it): link by link. A link
    -- hanging nearly along n (an arm hanging down beside the other rope) runs no way seen along it, and is left out.
    local ua, ub = math.floor(x.u), math.floor(x.v)
    local near = GAP + REST
    for ka = math.max(ua - WINDOW, 1), math.min(ua + WINDOW, #na - 1) do
        local pa0, pa1 = na[ka].position, na[ka + 1].position
        local la = pa1 - pa0
        local fa = la - n * dot(la, n)
        local lfa = #fa
        if lfa > 0.3 * #la then
            for kb = math.max(ub - WINDOW, 1), math.min(ub + WINDOW, #nb - 1) do
                local pb0, pb1 = nb[kb].position, nb[kb + 1].position
                local lb = pb1 - pb0
                local fb = lb - n * dot(lb, n)
                local lfb = #fb
                if lfb > 0.3 * #lb and #cross(fa, fb) <= 0.5 * lfa * lfb then
                    local s, t = nearest(pa0, pa1, pb0, pb1)
                    if #((pb0 + lb * t) - (pa0 + la * s)) < near then return end
                end
            end
        end
    end
    if dot(x.side, n) < 0.0 then n = -n end
    x.n, x.side = n, n
end

--- A crossing's two ropes pushed apart where they cross (touch along x.n): of the links round where they crossed
--- last, those that cross seen along x.n, and of them where the second is furthest out on its side. Where a rope
--- rests on another it is bent over it, and its arms hang down either side of the other (straight down, once what
--- hangs from them has swung in under it), close by it seen from above: they are not where it rests, its bend is.
--- Where that is now is kept (x.u, x.v); x.found says whether they still cross there. Answers whether they were
--- pushed, whether they rest on each other, and where (link, s, t).
local function crossAt(x, gap, keep, speed, rest)
    x.found = false
    local n = x.n
    if not n then return false end
    local na, nb = LIST[x.i].nodes, LIST[x.j].nodes
    local ua, ub = math.floor(x.u), math.floor(x.v)
    local best, bk, bm = -math.huge, nil, nil
    for ka = math.max(ua - WINDOW, 1), math.min(ua + WINDOW, #na - 1) do
        local pa0, pa1 = na[ka].position, na[ka + 1].position
        local fa0, fa1 = pa0 - n * dot(pa0, n), pa1 - n * dot(pa1, n)
        for kb = math.max(ub - WINDOW, 1), math.min(ub + WINDOW, #nb - 1) do
            local pb0, pb1 = nb[kb].position, nb[kb + 1].position
            local fb0, fb1 = pb0 - n * dot(pb0, n), pb1 - n * dot(pb1, n)
            local s, t = nearest(fa0, fa1, fb0, fb1)
            if #((fb0 + (fb1 - fb0) * t) - (fa0 + (fa1 - fa0) * s)) < gap then
                local along = dot((pb0 + (pb1 - pb0) * t) - (pa0 + (pa1 - pa0) * s), n)
                if along > best then best, bk, bm = along, ka, kb end
            end
        end
    end
    if not bk then
        -- No longer crossing there (slid off the end, or apart): found afresh next pass
        x.u = nil
        return false
    end
    x.found, x.ka, x.kb = true, bk, bm
    local pushed, rests, s, t = touch(na, bk, nb, bm, gap, keep, speed, rest, n)
    if s then x.u, x.v = bk + s, bm + t end
    return pushed, rests, bk, bm, s, t
end

--- Link `ka` of rope `ra` (`s` along it) rests on link `kb` of `rb` (`t` along): kept for both.
local function rested(ra, ka, rb, kb, s, t)
    local na, nb = ra.nodes, rb.nodes
    local a0, b0 = na[ka].position, nb[kb].position
    restsAt(ra, ka, s, a0 + (na[ka + 1].position - a0) * s)
    restsAt(rb, kb, t, b0 + (nb[kb + 1].position - b0) * t)
end

--- Every pair found, pushed apart where closer than the gap. `speed`: their speed into each other taken away too, the
--- pairs that touched counted (/ropedebug), and with Carry where each rests on another kept (once a step, last).
function Rope.TouchPairs(speed)
    local gap, keep, rest = GAP, KEEP, RESTING
    local keepRests = speed and CARRY
    local touched = 0
    -- Carry: each crossing where it crosses
    for x = 1, CARRY and NCROSS or 0 do
        local cx = CROSSINGS[x]
        acrossOf(cx)
        local pushed, rests, ka, kb, s, t = crossAt(cx, gap, keep, speed, rest)
        if pushed then touched = touched + 1 end
        if rests and keepRests then rested(LIST[cx.i], ka, LIST[cx.j], kb, s, t) end
    end
    -- Every other pair link by link: not those round where a crossing was found (they are its: a rope bent over
    -- another has its arms close by it there, and pushed their own ways they would fight the crossing)
    for c = 1, PAIRS do
        local ka, kb = KA[c], KB[c]
        local cx = CARRY and CROSSING_OF[c] or nil
        if not (cx and cx.found and math.abs(ka - cx.ka) <= WINDOW + 1 and math.abs(kb - cx.kb) <= WINDOW + 1) then
            local ra, rb = LIST[PA[c]], LIST[PB[c]]
            local pushed, rests, s, t = touch(ra.nodes, ka, rb.nodes, kb, gap, keep, speed, rest, nil)
            if pushed then touched = touched + 1 end
            if rests and keepRests then rested(ra, ka, rb, kb, s, t) end
        end
    end
    if speed then Rope.Touching = touched end
end

--- A rope's way through where it rests on others (rope.wrap): the first and last of those points along it, and how
--- far it runs between them, straight from point to point.
local function wrapOf(rope)
    local n = rope.restCount or 0
    if n == 0 then rope.wrap = nil return end
    local A, P = rope.restAlong, rope.restAt
    -- In order along the rope (a few points: sorted in place)
    for i = 2, n do
        local a, p = A[i], P[i]
        local j = i - 1
        while j >= 1 and A[j] > a do
            A[j + 1], P[j + 1] = A[j], P[j]
            j = j - 1
        end
        A[j + 1], P[j + 1] = a, p
    end
    local inner = 0.0
    for i = 2, n do inner = inner + #(P[i] - P[i - 1]) end
    local w = rope.wrapKept or {}
    rope.wrapKept = w
    w.first, w.last, w.inner = P[1], P[n], inner
    rope.wrap = w
end

--- The step's end: where each node of the ropes near another is now (the next step's side: wasAt), and with Carry,
--- each stepping rope's way through where it rests now (rope.wrap, read by its pull: client/physics.lua; none for one
--- resting on nothing).
function Rope.TouchDone()
    for _, rope in ipairs(NEARBY) do
        for _, node in ipairs(rope.nodes) do node.touchAt, node.touchPass = node.position, pass end
    end
    for _, rope in ipairs(LIST) do
        if CARRY then wrapOf(rope) else rope.wrap = nil end
    end
    -- Each crossing's side and place, for the next step (only those still near then are looked up). Only with Carry: no
    -- crossings without it, and no new table every step for none.
    if not CARRY then
        if next(KEPT) then KEPT = {} end
        return
    end
    local kept = {}
    for x = 1, CARRY and NCROSS or 0 do
        local c = CROSSINGS[x]
        if c.side and c.u then
            local a, b = LIST[c.i], LIST[c.j]
            kept[a] = kept[a] or {}
            kept[b] = kept[b] or {}
            kept[a][b] = { side = c.side, u = c.u, v = c.v }
            kept[b][a] = { side = -c.side, u = c.v, v = c.u }
        end
    end
    KEPT = kept
end

--- Every rope that is stepping, against every other near it, once it has taken its step. `dt`: the step's length.
function Rope.TouchRopes(ropes, dt)
    Rope.TouchFind(ropes, dt)
    Rope.TouchPairs(true)
    Rope.TouchDone()
end

-- (Rope.StepTogether's parts, each run under pcall)
local function solveTogether(nearby, passes)
    for p = 1, passes do
        for _, rope in ipairs(nearby) do Rope.StepSolve(rope, p, p) end
        Rope.TouchPairs(false)
    end
end
local function finishTogether()
    Rope.TouchPairs(true)
    Rope.TouchDone()
end

--- One step of every rope stepping, with Carry on (client/main.lua): as Rope.UpdateRopePhysics each, but the ropes
--- near another are pulled to length a pass at a time, all of them held apart after every pass, so none can drag
--- another through. `report(key, what, err)` is told of a part that fails.
function Rope.StepTogether(ropes, dt, report)
    local live = {}
    for key, rope in pairs(ropes) do
        if rope.simulated ~= false and not rope.resting then
            local ok, err = pcall(Rope.StepBegin, rope, dt)
            if ok then live[key] = rope else report(key, 'the physics', err) end
        end
    end
    local cost = WhipCost.start()
    local found, nearby = pcall(Rope.TouchFind, live, dt)
    if not found then report('contact', 'ropes against each other', nearby) end
    WhipCost.stop('rope: step, ropes against each other', cost)
    nearby = found and nearby or {}
    local together = {}
    for _, rope in ipairs(nearby) do together[rope] = true end

    local passes = Rope.Const.CONSTRAINT_ITERATIONS
    for key, rope in pairs(live) do
        if not together[rope] then
            local ok, err = pcall(Rope.StepSolve, rope, 1, passes)
            if not ok then report(key, 'the physics', err); live[key] = nil end
        end
    end
    if nearby[1] then
        local ok, err = pcall(solveTogether, nearby, passes)
        if not ok then report('contact', 'ropes against each other', err) end
    end
    for key, rope in pairs(live) do
        local ok, err = pcall(Rope.StepWorld, rope, dt)
        if not ok then report(key, 'the physics', err); live[key] = nil end
    end
    if found then
        cost = WhipCost.start()
        local ok, err = pcall(finishTogether)
        if not ok then report('contact', 'ropes against each other', err) end
        WhipCost.stop('rope: step, ropes against each other', cost)
    end
    for key, rope in pairs(live) do
        local ok, err = pcall(Rope.StepEnds, rope, dt)
        if not ok then report(key, 'the physics', err) end
    end
end
