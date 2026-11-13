--[[
    Rope physics: a chain of Verlet nodes held to length by a constraint solver, its ends pinned to what holds them,
    and the pull it puts on what it is tied to. Per-step numbers are tuned for a 1/60 s step and scaled by
    Rope.StepScale, so it feels the same at any frame rate.
]]

local DAMPING = Rope.Const.DAMPING
local REF_DT = Rope.Const.REF_DT

--- A step of `dt` seconds, in 1/60 s steps.
function Rope.StepScale(dt) return (dt or REF_DT) / REF_DT end

--- A share kept each 1/60 s step (`keep`: 0..1), for a step `r` of them long.
function Rope.KeptOver(keep, r) return keep ^ r end

--- A rope's link length: its own, as the server made it, not Config.Rope's.
local function linkOf(rope) return rope.linkLength end
Rope.LinkLength = linkOf

-- Hands

local HAND_BONE = 57005   -- SKEL_R_Hand

-- (The bone's index is asked each time, not kept per ped handle: a handle is reused for a new ped, whose
-- model may number its bones differently. Rope.AnchorThisFrame reads a hand once a frame anyway.)
function Rope.GetPlayerHandPosition()
    local ped = PlayerPedId()
    return GetWorldPositionOfEntityBone(ped, GetPedBoneIndex(ped, HAND_BONE))
end

--- Another player's right hand, or nil when they are not on this game (never our own hand instead).
function Rope.GetPlayerHandPositionByServerId(serverId)
    local ped = Rope.PedOf(serverId)
    if not ped then return nil end
    return GetWorldPositionOfEntityBone(ped, GetPedBoneIndex(ped, HAND_BONE))
end

-- Nodes

function Rope.CreateNode(position, pinned, mass)
    local nodeMass = mass or Config.Physics.DefaultNodeMass
    return {
        position = position,
        previousPosition = vector3(position.x, position.y, position.z),
        pinned = pinned or false,
        mass = nodeMass,
        invMass = 1.0 / nodeMass,
    }
end

--- A rope's `count` nodes, `link` metres apart, hanging straight down from `originPos`. Every game builds a rope the
--- same way, from the count and link the server gave that rope as it was made (Rope.AddRopeFromServer).
function Rope.BuildRopeNodes(originPos, count, link)
    local nodes = {}
    for i = 1, count do
        nodes[i] = Rope.CreateNode(originPos - vector3(0, 0, (i - 1) * link), false)
    end
    return nodes
end

--- An end node back to an ordinary node's mass (it carried a car's, or a hanging player's).
function Rope.ResetNodeMass(node)
    if not node then return end
    local m = Config.Physics.DefaultNodeMass or 0.5
    node.mass = m
    node.invMass = 1.0 / m
end

-- How taut it is

-- Stretch is measured against the rope's length, and only counts while the rope is straight (end-to-end distance over
-- length along the nodes): a sagging rope pulls nothing.
function Rope.ComputeRopeTension(rope)
    local nodes = rope.nodes
    local nodeCount = #nodes
    local theoretical = (nodeCount - 1) * linkOf(rope)

    local measured = 0.0
    for i = 1, nodeCount - 1 do
        measured = measured + #(nodes[i + 1].position - nodes[i].position)
    end

    local endpointDistance = #(nodes[nodeCount].position - nodes[1].position)
    local straightness = measured > 0.001 and endpointDistance / measured or 0.0
    local isTaut = straightness >= (Config.Physics.TautThreshold or 0.95)
    local overstretch = math.max(0, endpointDistance - theoretical)

    -- The rope's own answer table, filled again each time (twice a step): read it before the next call
    local t = rope.tensionReading
    if not t then t = {}; rope.tensionReading = t end
    t.endpointDistance = endpointDistance
    t.theoreticalLength = theoretical
    t.measuredLength = measured
    t.straightness = straightness
    t.isTaut = isTaut
    t.overstretch = overstretch
    t.overstretchRatio = isTaut and overstretch / theoretical or 0.0
    return t
end

-- The ends

-- Where an end ('origin' / 'tail') is held right now, or nil when it is loose.
local function ResolveEndAnchor(rope, which)
    local endType = rope[which .. 'Type']

    if endType == 'held' then
        local heldBy = rope[which .. 'HeldBy']
        -- A rope with `heldAt` ends on the prop in that hand (a pump's hose at its nozzle's back: client/api.lua)
        if rope.opts and rope.opts.heldAt then
            local p = Rope.HeldPropEnd(rope, heldBy)
            if p then return p end
        end
        if heldBy == Rope.MyServerId() then
            return Rope.GetPlayerHandPosition()
        elseif heldBy then
            return Rope.GetPlayerHandPositionByServerId(heldBy)
        end
    elseif endType == 'fixed' then
        return rope[which .. 'Position']
    elseif endType == 'vehicle' or endType == 'object' then
        local entity = rope[which .. 'Entity']
        local off = rope[which .. 'Offset']
        -- This game's copy of a take car gone (its take over): on the real car again, this frame
        if entity and Rope.CopyOf[entity] and not DoesEntityExist(entity) then entity = Rope.CopyGone(rope, which, entity) end
        if entity and DoesEntityExist(entity) and off then
            return GetOffsetFromEntityInWorldCoords(entity, off.x, off.y, off.z)
        end
        -- A world prop not found on this game (yet): where it was tied. Never for one being dragged —
        -- if it has gone, anchoring back at where it started would catapult whatever is on the other end.
        if endType == 'object' and not rope[which .. 'ObjectActivated'] and rope[which .. 'Point'] then
            return rope[which .. 'Point']
        end
    end

    return nil
end
Rope.ResolveEndPoint = ResolveEndAnchor

--- ResolveEndAnchor, cached once per frame (keyed on Rope.Frame and what the end is tied to).
local function anchorThisFrame(rope, which)
    local key = which .. 'Anchor'
    local c = rope[key]
    local endType = rope[which .. 'Type']
    local ref = endType == 'held' and rope[which .. 'HeldBy']
        or endType == 'fixed' and rope[which .. 'Position']
        or rope[which .. 'Entity']
    if c and c.frame == Rope.Frame and c.endType == endType and c.ref == ref
        and c.offset == rope[which .. 'Offset'] then
        return c.pos
    end
    local pos = ResolveEndAnchor(rope, which)
    if not c then c = {}; rope[key] = c end
    c.frame, c.endType, c.ref, c.offset, c.pos = Rope.Frame, endType, ref, rope[which .. 'Offset'], pos
    return pos
end
Rope.AnchorThisFrame = anchorThisFrame

--- Does this game move this entity? Every nearby game simulates the rope, but only the network owner of
--- a car or prop pulls it, or the games would fight. What a player pulls is made theirs (client/keep.lua).
local function weMove(entity)
    if not NetworkGetEntityIsNetworked(entity) then return true end
    return NetworkGetEntityOwner(entity) == PlayerId()
end

-- A rope two games move (two driven cars on one rope)
-- Each game sees the other end as it was a ping ago. So between two games the rope acts as a strap: it resists
-- stretching and gives nothing back once the two come together (Config.Keep.SplitRelease), and the pull uses where
-- the other end is guessed to be by now (pullPoint, Config.Keep.GuessShare). The games never see quite the same rope,
-- so each tells the other where it sees the far end (client/keep.lua) and both pull along the line halfway between
-- (sharedSpan): the same length, opposite ways, so neither can push or hold back the pair.

--- How late this game sees what an end is tied to (s): one another game moves, about the two players' pings
--- ago (Rope.Lag, from the server: client/keep.lua). 0 for one we move.
local function lagOf(rope, entity)
    if not entity or weMove(entity) then return 0.0 end
    return Rope.Lag[rope.serverRopeId] or 0.0
end

--- Where an end another game moves is by now, as best this game can tell: moved on by its own speed over
--- GuessShare of the lag. For the PULL only; the rope is drawn where things are seen.
local function pullPoint(rope, which, there)
    local share = Config.Keep and tonumber(Config.Keep.GuessShare) or 0.0
    if not there or share <= 0.0 then return there end
    local entity = rope[which .. 'Entity']
    local lag = lagOf(rope, entity) * share
    if lag <= 0.0 or not DoesEntityExist(entity) then return there end
    return there + GetEntityVelocity(entity) * lag
end

local SPAN_AVG_S = 0.5      -- s: this game's span is averaged over about this long before the two are compared
local SPAN_KEEP = 40        -- this game's averages kept to compare with (one each 50 ms: two seconds)
local THEIRS_FOR_MS = 1500  -- the other game's word is used this long after it came
local NO_SHIFT = vector3(0.0, 0.0, 0.0)

--- On a rope another game moves the other end of: this game's own span (`span`, from `which`), moved halfway to the
--- other game's (Rope.TheirSpan). Keeps rope.spanAvg (sent to the other game) and rope.spanShift.
local function sharedSpan(rope, which, span, dt)
    local sep = which == 'origin' and span or -span
    local k = 1.0 - math.exp(-(dt or REF_DT) / SPAN_AVG_S)
    local avg = rope.spanAvg and rope.spanAvg + (sep - rope.spanAvg) * k or sep
    local now = GetGameTimer()
    rope.spanAvg, rope.spanAvgAt = avg, now
    local hist = rope.spanHist
    if not hist then hist = {}; rope.spanHist = hist end
    if #hist == 0 or now - hist[#hist].at >= 50 then
        hist[#hist + 1] = { at = now, v = avg }
        if #hist > SPAN_KEEP then table.remove(hist, 1) end
    end
    local theirs = Rope.TheirSpan[rope.serverRopeId]
    if not theirs or now - theirs.at > THEIRS_FOR_MS then
        rope.spanShift = NO_SHIFT
        return span
    end
    local made = theirs.at - (Rope.Lag[rope.serverRopeId] or 0.0) * 1000
    local mine = hist[1].v
    for i = #hist, 1, -1 do
        if hist[i].at <= made then mine = hist[i].v break end
    end
    local shift = (theirs.v - mine) * 0.5
    rope.spanShift = shift
    return which == 'origin' and span + shift or span - shift
end

--- What an end is tied to, as something the rope pulls: entity, mass, isVehicle — or nil (held,
--- put down, loose, a frozen prop, or not on this game).
local function bodyOf(rope, which)
    local endType = rope[which .. 'Type']
    local isVehicle = endType == 'vehicle'
    -- A networked prop, or a map prop this game woke up to drag (a frozen one is an anchor)
    local isObject = endType == 'object' and (rope[which .. 'NetId'] ~= nil or rope[which .. 'ObjectActivated'])
    if not isVehicle and not isObject then return nil end
    local entity = rope[which .. 'Entity']
    if not entity or not DoesEntityExist(entity) then return nil end
    if isObject and IsEntityPositionFrozen(entity) then return nil end
    -- A car a Director take drives goes where its recording says: on the game playing it (Rope.Driven, from the server)
    -- and as this game's copy of it (Rope.CopyOf), it never takes the rope's pull. It pulls, as a hand does.
    if isVehicle and (Rope.Driven[rope[which .. 'NetId'] or 0] or Rope.CopyOf[entity]) then return nil end
    return entity, rope[which .. 'Mass'] or Config.Coupling.BaseMass or 1500.0, isVehicle
end
Rope.BodyOf = bodyOf

-- Is an end an anchor?
-- A rope pulls either a body it moves (a car, a prop) or an anchor it pulls against (a post): the pull is then capped
-- by the puller's own mass, and the backstop's and pull-back's push goes to the end that can move.

local ENDS = { 'origin', 'tail' }

-- Where an end's tie point has been: it MOVED when it has gone 15 cm since last seen
local function trackStill(rope, which, at)
    local posKey, timeKey = which .. 'StillPos', which .. 'MovedAt'
    local seen = rope[posKey]
    if not seen or #(at - seen) > 0.15 then rope[posKey], rope[timeKey] = at, GetGameTimer() end
end

--- STILL: its tie point has not gone 15 cm in 250 ms (wedged, held by the world, moved by no game).
--- (By position: this game's own push this frame would make a stuck thing's speed look like moving.)
local function isStill(rope, which)
    local movedAt = rope[which .. 'MovedAt']
    return movedAt ~= nil and GetGameTimer() - movedAt > 250
end

--- How hard OTHER ropes tied to `entity` pull it against `myDir` (N), from what each pulled with last
--- (a rope asleep pulls nothing).
local function pullAgainst(rope, entity, myDir)
    local against = 0.0
    for _, other in pairs(Rope.System.ropes) do
        if other ~= rope and other.simulated ~= false then
            for _, w in ipairs(ENDS) do
                local pull, d = other[w .. 'PullN'], other[w .. 'PullDir']
                if other[w .. 'Entity'] == entity and pull and pull > 0.0 and d then
                    local c = -(d.x * myDir.x + d.y * myDir.y + d.z * myDir.z)
                    if c > 0.0 then against = against + c * pull end
                end
            end
        end
    end
    return against
end

--- Held by other ropes: they pull it the other way with at least half this one's pull. Once held it stays held for
--- half a second, so a car shuttling between two ropes does not flicker.
local function heldByOthers(rope, which)
    local entity = rope[which .. 'Entity']
    local mine, myDir = rope[which .. 'PullN'] or 0.0, rope[which .. 'PullDir']
    if not entity or mine <= 0.0 or not myDir then return false end
    local against = pullAgainst(rope, entity, myDir)
    local now, key = GetGameTimer(), which .. 'HeldUntil'
    if against >= mine * 0.5 then rope[key] = now + 500 end
    if against < mine * 0.1 then rope[key] = nil end
    return now < (rope[key] or 0)
end
Rope.HeldByOthers = heldByOthers

-- An aircraft and a driver at the other end: with two games moving the ends, twisting from a late picture of the other
-- vehicle makes a car hanging under a helicopter spin. So on such a rope both vehicles are pushed nearer their middles
-- (Config.Keep.AircraftTwist of the way out to the tie point): the same pull, less twist.

local function isAircraft(entity)
    local class = GetVehicleClass(entity)
    return class == 15 or class == 16   -- helicopters, planes
end

--- How much of the rope's twist the vehicles at its ends get (1: all). Once a frame.
local function twistOf(rope)
    if rope.twistFrame == Rope.Frame then return rope.twist end
    local twist = 1.0
    local eA = rope.originType == 'vehicle' and rope.originEntity
    local eB = rope.tailType == 'vehicle' and rope.tailEntity
    if eA and eB and DoesEntityExist(eA) and DoesEntityExist(eB) and weMove(eA) ~= weMove(eB)
        and (isAircraft(eA) or isAircraft(eB)) then
        twist = tonumber(Config.Keep and Config.Keep.AircraftTwist) or 1.0
    end
    rope.twist, rope.twistFrame = twist, Rope.Frame
    return twist
end

--- Hand a change in speed (m/s, world axes) to what an end is tied to.
local function push(rope, which, entity, isVehicle, wx, wy, wz)
    local cpl = Config.Coupling
    -- ALONG THE GROUND for a car on its wheels: only GroundLift of an upward pull is kept, so it never
    -- lifts the wrong wheels — unless the rope is steep (a helicopter above), which lifts it properly
    if isVehicle and wz > 0 then
        local len = math.sqrt(wx * wx + wy * wy + wz * wz)
        if len > 0 and wz / len < (cpl.SteepRope or 0.7) and IsVehicleOnAllWheels(entity) then
            wz = wz * (cpl.GroundLift or 0.15)
        end
    end
    -- A towed car nobody drives rolls: its handbrake is let off while the rope pulls it
    if isVehicle and cpl.FreeRolling ~= false and GetPedInVehicleSeat(entity, -1) == 0 then
        SetVehicleHandbrake(entity, false)
    end
    -- A car: at the tie point's X/Y but the origin's height, so it turns toward the rope without tipping. A prop: at
    -- the tie point itself, so one pulled high tips over. The push is converted into the entity's own frame.
    local fwd, right, up = GetEntityMatrix(entity)
    local lx = wx * right.x + wy * right.y + wz * right.z
    local ly = wx * fwd.x + wy * fwd.y + wz * fwd.z
    local lz = wx * up.x + wy * up.y + wz * up.z
    local offset = rope[which .. 'Offset'] or vector3(0.0, 0.0, 0.0)
    local twist = isVehicle and twistOf(rope) or 1.0
    if twist < 1.0 then offset = offset * twist end
    ApplyForceToEntity(entity, 1, lx, ly, lz, offset.x, offset.y, isVehicle and 0.0 or offset.z,
        0, true, true, true, false, true)
end

-- A rope caught on another (Config.RopeContact.Carry): stretch and pull come from the path to where it rests
-- (rope.wrap, from client/contact.lua) rather than the straight line between its ends. A rope with one node lifted by
-- anything else still pulls along the straight line.

--- How long a caught rope runs from `here` (the `which` end) to `there` (the other) through where it rests, and which
--- way it leaves `here`; nil when it rests on nothing (or right at this end).
local function wrapped(rope, which, here, there)
    local w = rope.wrap
    if not w then return nil end
    local near, far = w.first, w.last
    if which == 'tail' then near, far = w.last, w.first end
    local toNear = near - here
    local d = #toNear
    if d < 0.01 then return nil end
    return d + w.inner + #(there - far), toNear / d
end

--- The rope's pull at this stretch (m), as the acceleration it gives a BaseMass car: up to ElasticPull over the first
--- ElasticStretch of its length, then climbing by StiffPull × (metres past it)^StiffCurve without limit.
function Rope.ElasticPull(stretch, naturalLength)
    local cpl = Config.Coupling
    local give = math.max(naturalLength * (cpl.ElasticStretch or 0.15), 0.01)
    local pull = cpl.ElasticPull or 5.0
    if stretch <= give then
        return pull * (stretch / give) ^ (cpl.ElasticCurve or 1.0)
    end
    return pull + (cpl.StiffPull or 24.0) * (stretch - give) ^ (cpl.StiffCurve or 1.0)
end

-- The pull on what an end is tied to. Stretched past its length the rope pulls (Rope.ElasticPull) with the same
-- tension on both ends, damped as the ends close and smoothed, applied as this step's change in speed. The direction
-- is the straight line to the other end. Rope.ApplyRopeLimit handles the backstop and the pull back.
local function ApplyAnchorCoupling(rope, which, dt)
    local cpl = Config.Coupling
    if not cpl or not cpl.Enabled then return end
    local r = Rope.StepScale(dt)

    local smoothKey = which .. 'SmoothedForce'
    local function noForce()
        rope[smoothKey] = (rope[smoothKey] or 0) * Rope.KeptOver(0.75, r)
        rope[which .. 'PullN'] = 0.0
        if which == 'origin' then rope.debugOriginForce = 0 else rope.debugTailForce = 0 end
    end

    local endType = rope[which .. 'Type']
    local entity, mass, isVehicle = bodyOf(rope, which)
    if not entity then return noForce() end

    -- Just tied: let the rope settle before it pulls — either end just tied holds both, so one end is
    -- never pulled alone
    local stateKey, graceKey = which .. 'LastCoupleType', which .. 'CoupleGraceUntil'
    if rope[stateKey] ~= endType then
        rope[stateKey] = endType
        rope[graceKey] = GetGameTimer() + (cpl.AttachGraceMs or 400)
    end
    local nowMs = GetGameTimer()
    if nowMs < (rope.originCoupleGraceUntil or 0) or nowMs < (rope.tailCoupleGraceUntil or 0) then
        return noForce()
    end

    -- A rope only carries a load between two held ends
    local nodes = rope.nodes
    local nodeCount = #nodes
    if not nodes[1].pinned or not nodes[nodeCount].pinned then return noForce() end
    local here = which == 'origin' and nodes[1].position or nodes[nodeCount].position
    local seenThere = which == 'origin' and nodes[nodeCount].position or nodes[1].position
    local otherEnd = which == 'origin' and 'tail' or 'origin'
    -- Another game's end: where it is by now (pullPoint), and on the end this game moves, the line halfway between
    -- what the two games see (sharedSpan)
    local there = pullPoint(rope, otherEnd, seenThere)
    local span = there - here
    local otherEntity, otherMass, otherIsVehicle = bodyOf(rope, otherEnd)
    -- Caught on another rope: as long as the way it runs, pulled toward where it rests
    local pathLength, pathDir = wrapped(rope, which, here, there)
    if not pathLength and otherEntity and not weMove(otherEntity) and weMove(entity) then
        span = sharedSpan(rope, which, span, dt)
    end
    local endpointDist = pathLength or #span
    if endpointDist < 0.001 then return noForce() end
    local dir = pathDir or span / endpointDist

    local naturalLength = (nodeCount - 1) * linkOf(rope)
    local stretch = endpointDist - naturalLength
    if stretch <= 0 then return noForce() end

    -- Where the other end has been (is it still?), every step it is taut
    if otherEntity then trackStill(rope, otherEnd, seenThere) end

    -- Two games: a strap, nothing given back once the two come together faster than SplitRelease. Judged by
    -- their speeds, not by how the late picture moves, which flickers.
    if otherEntity and not weMove(otherEntity) then
        local rel = GetEntityVelocity(otherEntity) - GetEntityVelocity(entity)
        local release = Config.Keep and tonumber(Config.Keep.SplitRelease) or 0.5
        if rel.x * dir.x + rel.y * dir.y + rel.z * dir.z < -release then return noForce() end
    end

    -- The pull on a BaseMass car at this stretch, damped against the ends closing in (fully) or opening
    -- up (a little: towing always opens them), never more than MaxDampingBoost times the rope's own
    local spring = Rope.ElasticPull(stretch, naturalLength)
    local rate = rope.endpointRate or 0.0
    -- Springing back it returns only part of its pull: Rebound of the easy stretch's and StiffRebound of
    -- what is past it (capped at MaxAcceleration), so an overstretched rope doesn't fling the car back.
    if rate < -0.05 then
        local easy = math.min(spring, cpl.ElasticPull or 5.0)
        local past = math.max(math.min(spring, cpl.MaxAcceleration or 20.0) - easy, 0.0)
        spring = easy * (cpl.Rebound or 0.6) + past * (cpl.StiffRebound or 0.15)
    end
    local damping = cpl.Damping or 0.7
    if rate > 0 then damping = damping * (cpl.YankAbsorb or 0.25) end
    local base = math.min(spring + rate * damping, spring * (cpl.MaxDampingBoost or 1.5))
    if base <= 0 then return noForce() end
    local tension = base * (cpl.BaseMass or 1500.0)   -- newtons

    -- One tension on both ends (Newton), so a car's own pull can free a stuck bike.
    local closing = rate < -0.05
    local kg = math.max(mass, 50.0)

    -- The other end counts as a body only while it moves freely; still, or held by other ropes, it is an
    -- anchor like a post
    local otherKg = otherEntity and math.max(otherMass, 50.0) or nil
    if otherKg and (isStill(rope, otherEnd) or heldByOthers(rope, otherEnd)) then otherKg = nil end

    -- The ceiling: MaxAcceleration on the lighter of the two moving things (this one alone against an
    -- anchor), never less than a BaseMass car's worth, so a heavy truck is held as hard for its mass
    local ref = otherKg and math.min(kg, otherKg) or kg
    local ceiling = (cpl.MaxAcceleration or 20.0) * math.max(cpl.BaseMass or 1500.0, ref)
    -- Each thing's own most — a prop PropMaxAcceleration (never fired off), a vehicle VehicleMaxAcceleration
    -- (a light bike yanked, not launched): this one's, and the other's while it moves
    local function mostFor(vehicle)
        return vehicle and (cpl.VehicleMaxAcceleration or 60.0) or (cpl.PropMaxAcceleration or 20.0)
    end
    ceiling = math.min(ceiling, mostFor(isVehicle) * kg)
    if otherKg then ceiling = math.min(ceiling, mostFor(otherIsVehicle) * otherKg) end
    -- A player holding the other end pulls by hand: a car or a bus no faster than HandPull (a metre
    -- past the rope's give it leaves the hand, client/ui.lua)
    if rope[otherEnd .. 'Type'] == 'held' then ceiling = math.min(ceiling, (cpl.HandPull or 2.0) * kg) end
    -- Springing back, the ceiling scales by Rebound too (a safety net for unusual settings)
    if closing then ceiling = ceiling * (cpl.Rebound or 0.6) end
    -- The ceiling limits net acceleration: other ropes pulling the other way add to what this one may pull
    if rope[otherEnd .. 'Type'] ~= 'held' then ceiling = ceiling + pullAgainst(rope, entity, dir) end
    tension = math.min(tension, ceiling)
    local accel = tension / kg
    -- What the rope really pulls with, for /ropedebug (ApplyEndPhysics zeroes it before both ends)
    rope.debugTension = math.max(rope.debugTension or 0, tension)

    -- Follows changes quickly up, gently down (a share of the gap closed each 1/60 s)
    local prev = rope[smoothKey] or 0
    local smoothing = accel > prev and (cpl.ForceRise or 0.5) or (cpl.ForceFall or 0.3)
    smoothing = 1.0 - Rope.KeptOver(1.0 - smoothing, r)
    local smoothed = prev + (accel - prev) * smoothing
    rope[smoothKey] = smoothed
    -- What this end is pulled with, and which way (other ropes on the same thing read it: heldByOthers)
    rope[which .. 'PullN'], rope[which .. 'PullDir'] = smoothed * kg, dir
    if which == 'origin' then rope.debugOriginForce = smoothed else rope.debugTailForce = smoothed end
    -- Too little to bother with — judged on the force, so both ends stop at the same point
    if smoothed * kg < 0.05 * (cpl.BaseMass or 1500.0) then return end

    -- Only the game in charge of it moves it; the change in speed for this step, a·dt
    if not weMove(entity) then return end
    local dv = smoothed * dt
    push(rope, which, entity, isVehicle, dir.x * dv, dir.y * dv, dir.z * dv)
end

-- The rope's length (once a frame, from client/main.lua)
-- The backstop: past MaxStretch the opening speed between the ends is removed, shared by mass, at no more than
-- BackstopPull. It catches fast cars the elastic pull can't. Runs once per frame, since entity speeds only change
-- between frames.
-- The pull back: once nothing holds the rope open, it draws its ends back to slack (ReturnRate per metre stretched,
-- capped at ReturnSpeed, built up at ReturnAccel, at most ReturnPull). The spring alone can't: GTA holds a stopped car
-- on its brakes. A driver on the throttle away from the rope is left to the spring.

--- A car whose driver has the throttle on away from the rope (`away`: the way out from the other end).
local function drivenAway(rope, which, away)
    if rope[which .. 'Type'] ~= 'vehicle' then return false end
    local entity = rope[which .. 'Entity']
    if not entity or not DoesEntityExist(entity) or GetPedInVehicleSeat(entity, -1) == 0 then return false end
    local throttle = GetVehicleThrottleOffset(entity) or 0.0
    if math.abs(throttle) < 0.1 then return false end
    local fwd = GetEntityForwardVector(entity)
    return throttle * (fwd.x * away.x + fwd.y * away.y + fwd.z * away.z) > 0.05
end

function Rope.ApplyRopeLimit(rope, frameDt)
    local cpl = Config.Coupling
    if not cpl or not cpl.Enabled then return end
    rope.debugLimitDv, rope.debugReturnDv = 0, 0
    -- The pull back's speed so far: picked up again after a frame or two off (a car shuttling between two
    -- ropes opens this one now and then), started afresh after longer
    local returning = rope.returnCmd and GetGameTimer() - (rope.returnAt or 0) < 300 and rope.returnCmd or nil
    -- Held by a player: a hand is not something the rope moves (players are never pulled). The pull by
    -- hand is the spring's, and past the stretch the rope leaves the hand (client/ui.lua).
    if rope.originType == 'held' or rope.tailType == 'held' then return end
    local now = GetGameTimer()
    if now < (rope.originCoupleGraceUntil or 0) or now < (rope.tailCoupleGraceUntil or 0) then return end

    local a = anchorThisFrame(rope, 'origin')
    local b = anchorThisFrame(rope, 'tail')
    if not a or not b then return end
    a, b = pullPoint(rope, 'origin', a), pullPoint(rope, 'tail', b)   -- another game's end: where it is by now
    local eA, mA, vehA = bodyOf(rope, 'origin')
    local eB, mB, vehB = bodyOf(rope, 'tail')
    if not eA and not eB then return end
    -- How long it is, and which way each end is drawn in: nA the origin, nB the tail. Straight, toward each other;
    -- caught on another rope, each toward where it rests, and as long as the way it runs (Config.RopeContact.Carry).
    local d, nA, nB = wrapped(rope, 'origin', a, b)
    if d then
        local _, toward = wrapped(rope, 'tail', b, a)
        if toward then nB = toward else d = nil end
    end
    if not d then
        local span = b - a
        -- Two games: the line halfway between what the two see (sharedSpan)
        if eA and eB and weMove(eA) ~= weMove(eB) then span = span + (rope.spanShift or NO_SHIFT) end
        d = #span
        if d < 0.001 then return end
        nA = span / d
        nB = -nA
    end
    local naturalLength = (#rope.nodes - 1) * linkOf(rope)
    if d <= naturalLength then return end
    local invA = eA and 1.0 / math.max(mA, 50.0) or 0.0
    local invB = eB and 1.0 / math.max(mB, 50.0) or 0.0
    local zero = vector3(0.0, 0.0, 0.0)
    local vA = eA and GetEntityVelocity(eA) or zero
    local vB = eB and GetEntityVelocity(eB) or zero
    -- How fast it is getting longer: each end moving away from the way it is drawn in
    local opening = -(vA.x * nA.x + vA.y * nA.y + vA.z * nA.z) - (vB.x * nB.x + vB.y * nB.y + vB.z * nB.z)
    local dt = math.min(math.max(frameDt or REF_DT, 0.001), 0.1)

    -- Two bodies, one held by other ropes (or still) and the other not: it all goes to the one that moves.
    local heldA, heldB = eA and heldByOthers(rope, 'origin'), eB and heldByOthers(rope, 'tail')

    -- A hard length (a resource's rope: opts.maxStretch, a pump's hose). Past it one pull draws both ends together,
    -- each moved by it over what it weighs, so a car dragging a torn pump feels the pump's mass. The pull is at most
    -- BackstopPull on a BaseMass car's worth, and the hose may stretch to HardCeiling times maxStretch; there a prop
    -- on it is dragged along to keep it so. Against an anchor (a pump still on its island) a car driving away is
    -- never held: the pump comes away at its watch's stretch instead. An end other ropes hold back takes none of it.
    local hard = rope.opts and tonumber(rope.opts.maxStretch)
    if hard and d > naturalLength * (1.0 + hard) then
        local okA = eA ~= nil and not heldA
        local okB = eB ~= nil and not heldB
        if okA and vehA and not okB and drivenAway(rope, 'origin', -nA) then okA = false end
        if okB and vehB and not okA and drivenAway(rope, 'tail', -nB) then okB = false end
        if okA or okB then
            -- Closes back inside the length at up to HardCatchUp m/s faster. Worked out from the ends' speeds each
            -- frame, never added up: a prop let go far past the length would be thrown at the car.
            local catchUp = math.min((d - naturalLength * (1.0 + hard)) * 5.0, cpl.HardCatchUp or 2.0)
            local close = math.max(opening + catchUp, 0.0)
            local wA, wB = okA and invA or 0.0, okB and invB or 0.0
            -- The impulse that closes it this frame (kg m/s), at most the hose's strongest pull for this frame
            local jFull = close / (wA + wB)
            local j = math.min(jFull, (cpl.BackstopPull or 40.0) * (cpl.BaseMass or 1500.0) * dt)
            local dvA, dvB = j * wA, j * wB
            -- At the ceiling it gets no longer: what the pull could not do this frame a prop on it makes up (dragged
            -- along whatever it weighs), so a car still feels only the pull; with no prop on it, the pull has no limit
            local ceiling = naturalLength * (1.0 + hard * math.max(1.0, tonumber(cpl.HardCeiling) or 2.0))
            if j < jFull and d >= ceiling then
                local short = (jFull - j) * (wA + wB)
                local propA, propB = okA and not vehA, okB and not vehB
                if propA and not propB then dvA = dvA + short
                elseif propB and not propA then dvB = dvB + short
                else dvA, dvB = jFull * wA, jFull * wB end
            end
            -- A car pushed (as the backstop pushes it); a prop's speed topped up, so it slides upright as it did
            local function draw(e, which, veh, v, n, dv)
                if dv <= 0.0 or not weMove(e) then return end
                if veh then push(rope, which, e, true, n.x * dv, n.y * dv, n.z * dv)
                else SetEntityVelocity(e, v.x + n.x * dv, v.y + n.y * dv, v.z + n.z * dv) end
            end
            if okA then draw(eA, 'origin', vehA, vA, nA, dvA) end
            if okB then draw(eB, 'tail', vehB, vB, nB, dvB) end
            rope.debugLimitDv = dvA + dvB
            return
        end
    end
    local massA, massB = invA, invB
    if eA and eB then
        if heldA ~= heldB then
            if heldA then invA = 0.0 else invB = 0.0 end
        else
            local stillA, stillB = isStill(rope, 'origin'), isStill(rope, 'tail')
            if stillA ~= stillB then
                if stillA then invA = 0.0 else invB = 0.0 end
            end
        end
    end

    -- Takes `need` m/s out of the ends' opening (draws them together), shared by the masses; each game
    -- moves only what it is in charge of
    local function together(need, invOrigin, invTail)
        local share = need / (invOrigin + invTail)
        if eA and invOrigin > 0.0 and weMove(eA) then
            local dv = share * invOrigin
            push(rope, 'origin', eA, vehA, nA.x * dv, nA.y * dv, nA.z * dv)
        end
        if eB and invTail > 0.0 and weMove(eB) then
            local dv = share * invTail
            push(rope, 'tail', eB, vehB, nB.x * dv, nB.y * dv, nB.z * dv)
        end
    end

    -- The backstop: remove the opening speed, at most BackstopPull this frame, ramping in over BackstopRamp
    -- metres. Kept at least 0.5 past the easy give. It only resists; drawing back is the pull back's job.
    local beyond = math.max(cpl.MaxStretch or 1.0, (cpl.ElasticStretch or 0.15) + 0.5)
    local limit = naturalLength * (1.0 + beyond)
    if d > limit and opening > 0.0 and invA + invB > 0.0 then
        local ramp = math.min((d - limit) / math.max(cpl.BackstopRamp or 0.5, 0.01), 1.0)
        local need = math.min(opening, (cpl.BackstopPull or 40.0) * ramp * dt)
        rope.debugLimitDv = need
        return together(need, invA, invB)
    end

    -- The pull back: not while opening, while a driver pulls away, or while both travel together (a tow
    -- on the move is the spring's). Never between two games: a strap gives nothing back (ApplyAnchorCoupling).
    if cpl.PullBack == false or opening > 0.1 then return end
    if eA and eB and weMove(eA) ~= weMove(eB) then return end
    if drivenAway(rope, 'origin', -nA) or drivenAway(rope, 'tail', -nB) then return end
    local returnSpeed = cpl.ReturnSpeed or 3.0
    if math.max(#vA, #vB) > returnSpeed + 1.5 then return end
    -- Never pushes something other ropes hold, or a stuck prop. A still car is pushed: GTA holds it on
    -- its brakes.
    local inO, inT = heldA and 0.0 or massA, heldB and 0.0 or massB
    if inO > 0.0 and inT > 0.0 then
        local stuckA = rope.originType == 'object' and isStill(rope, 'origin')
        local stuckB = rope.tailType == 'object' and isStill(rope, 'tail')
        if stuckA ~= stuckB then
            if stuckA then inO = 0.0 else inT = 0.0 end
        end
    end
    if inO + inT <= 0.0 then return end
    local target = math.min(returnSpeed, (cpl.ReturnRate or 1.0) * (d - naturalLength))
    -- Speed builds at ReturnAccel from the current closing speed (a tug, not a snap); against GTA's
    -- brakes the push grows until it beats them
    local closingNow = -opening
    local cmd = math.min(target, math.max(returning or 0.0, closingNow) + (cpl.ReturnAccel or 6.0) * dt)
    rope.returnCmd, rope.returnAt = cmd, GetGameTimer()
    local need = math.min(cmd - closingNow, (cpl.ReturnPull or 30.0) * dt)
    if need <= 0.0 then return end
    rope.debugReturnDv = need
    together(need, inO, inT)
end

-- Pins each end to whatever holds it; with withCoupling, also pulls what it is tied to (over this step's `dt`).
local function ApplyEndPhysics(rope, withCoupling, dt)
    local nodes = rope.nodes
    local originNode, tailNode = nodes[1], nodes[#nodes]
    if not originNode or not tailNode then return end

    local originPos = anchorThisFrame(rope, 'origin')
    local tailPos = anchorThisFrame(rope, 'tail')

    -- A pinned end forgets the ground it last lay on, or its neighbour keeps using that stale floor
    if originPos then
        originNode.position, originNode.previousPosition, originNode.pinned = originPos, originPos, true
        originNode.ground = nil
    else
        originNode.pinned = false
    end
    if tailPos then
        tailNode.position, tailNode.previousPosition, tailNode.pinned = tailPos, tailPos, true
        tailNode.ground = nil
    else
        tailNode.pinned = false
    end

    if withCoupling then
        -- How fast the ends are opening (+) or closing (-), m/s, for the damping. Ends only move once a frame, so a
        -- frame split into steps spreads the change over the time since it last moved.
        local a, b = nodes[1].position, nodes[#nodes].position
        local pathLength = wrapped(rope, 'origin', a, b)
        local endpointDist = pathLength or #(b - a)
        if (pathLength ~= nil) ~= (rope.rateWrapped == true) then
            rope.rateWrapped = pathLength ~= nil
            rope.prevEndpointDist, rope.rateTime = endpointDist, 0.0
        end
        local prevDist = rope.prevEndpointDist or endpointDist
        rope.rateTime = (rope.rateTime or 0.0) + (dt or REF_DT)
        if math.abs(endpointDist - prevDist) > 1e-5 then
            rope.endpointRate = (endpointDist - prevDist) / rope.rateTime
            rope.prevEndpointDist, rope.rateTime = endpointDist, 0.0
        elseif rope.rateTime > 0.1 then
            rope.endpointRate = 0.0
            rope.prevEndpointDist = endpointDist
        end

        rope.debugTension = 0   -- each end below writes what it pulls with
        ApplyAnchorCoupling(rope, 'origin', dt or REF_DT)
        ApplyAnchorCoupling(rope, 'tail', dt or REF_DT)
        rope.debugForcesApplied = (rope.debugOriginForce or 0) > 0 or (rope.debugTailForce or 0) > 0
    end

    if not originPos or not tailPos then return end

    -- For /ropedebug, and read by nothing else: only while its overlay is up (a walk along every link, twice a step)
    if not Rope.DebugShown then return end
    local tension = Rope.ComputeRopeTension(rope)
    rope.debugRopeLength = tension.theoreticalLength
    rope.debugActualLength = tension.measuredLength
    rope.debugDistance = tension.endpointDistance
    rope.debugStraightness = tension.straightness
    rope.debugOverstretch = tension.overstretch
    rope.debugNodeCount = #nodes
end

-- Someone hanging off it

-- Their weight: a little extra gravity on the node they hang from, so the rope sags under them.
local function ApplyHangingNodeForces(rope, deltaTime)
    local serverRopeId = rope.serverRopeId
    if not serverRopeId then return end
    local extra = Config.Physics.Gravity * ((Config.PlayerHang.ExtraWeight or 2.0) * deltaTime * deltaTime)
    for _, hangData in pairs(Rope.HangingPlayers) do
        if hangData.serverRopeId == serverRopeId then
            local node = rope.nodes[hangData.nodeIndex]
            if node and not node.pinned then
                node.position = node.position + extra
            end
        end
    end
end

--- The node a hanging player is on: heavier to the solver, within reason (Config.PlayerHang.SolverMass).
function Rope.SetHangingNodeMass(node)
    if not node then return end
    local m = Config.PlayerHang.SolverMass or 5.0
    node.mass = m
    node.invMass = 1.0 / m
end

-- One step (once a frame, from client/main.lua: `deltaTime` is the frame's time, or a share of a slow frame's)
-- In four parts, so ropes taking each other's weight (client/contact.lua) can be held apart between passes: begun,
-- solved (pulled to length), against the world, and its ends. Rope.UpdateRopePhysics is all four in turn.

--- The ends pinned, people and explosions, and every node moved on by its speed and gravity.
function Rope.StepBegin(rope, deltaTime)
    local r = Rope.StepScale(deltaTime)
    -- The ends pinned first (no pull yet: the rope is not settled until the constraints have run)
    ApplyEndPhysics(rope, false)

    local cost = WhipCost.start()
    Rope.ApplyPlayerInteraction(rope, deltaTime)
    Rope.ApplyExplosionInteraction(rope, deltaTime)
    ApplyHangingNodeForces(rope, deltaTime)
    WhipCost.stop('rope: step, people + explosions', cost)

    cost = WhipCost.start()
    local nodes = rope.nodes
    local nodeCount = #nodes
    -- Verlet integration with time correction: this step carries a node on by this step's length over the previous
    -- one's, so steps of different length do not brake or fling the rope.
    local gStep = Config.Physics.Gravity * (deltaTime * deltaTime)
    local carry = math.min(math.max(deltaTime / (rope.lastStepDt or deltaTime), 0.5), 2.0)
        * Rope.KeptOver(DAMPING, r)
    rope.lastStepDt = deltaTime
    for i = 1, nodeCount do
        local node = nodes[i]
        if not node.pinned then
            local p = node.position
            local velocity = (p - node.previousPosition) * carry
            node.previousPosition = p
            node.position = p + velocity + gStep
        end
    end

    -- The constraints: how each link shares a correction, worked out once per step (Rope.StepSolve).
    -- M: 1 both move (by W1 / W2), 2 only the first, 3 only the second, 0 neither.
    local lastNode = nodeCount - 1
    local M, W1, W2 = rope.solveM or {}, rope.solveW1 or {}, rope.solveW2 or {}
    rope.solveM, rope.solveW1, rope.solveW2 = M, W1, W2
    for i = 1, lastNode do
        local n1, n2 = nodes[i], nodes[i + 1]
        local pin1, pin2 = n1.pinned, n2.pinned
        if not pin1 and not pin2 then
            local inv1, inv2 = n1.invMass or 2.0, n2.invMass or 2.0
            local total = inv1 + inv2
            if total > 0.0001 then
                M[i], W1[i], W2[i] = 1, inv1 / total, inv2 / total
            else
                M[i] = 0
            end
        elseif not pin1 then
            M[i] = 2
        elseif not pin2 then
            M[i] = 3
        else
            M[i] = 0
        end
    end
    WhipCost.stop('rope: step, solver', cost)
end

--- Constraint passes `from` to `to` of Rope.Const.CONSTRAINT_ITERATIONS. Each link pulls its two nodes back to its
--- length: all of a stretch, 30% of a squash (a rope, not a rod).
function Rope.StepSolve(rope, from, to)
    local cost = WhipCost.start()
    local nodes = rope.nodes
    local nodeCount = #nodes
    local lastNode = nodeCount - 1
    local segLen = linkOf(rope)
    local M, W1, W2 = rope.solveM, rope.solveW1, rope.solveW2
    local P = rope.solveP or {}
    rope.solveP = P
    for i = 1, nodeCount do P[i] = nodes[i].position end
    for _ = from, to do
        for i = 1, lastNode do
            local p1, p2 = P[i], P[i + 1]
            local delta = p2 - p1
            local distance = #delta
            if not (distance < 0.001) then   -- `not <`, not `>=`: a NaN distance is not skipped
                local difference = (segLen - distance) / distance
                local correctionStrength = distance < segLen and 0.3 or 1.0
                local m = M[i]
                if m == 1 then
                    local correction = delta * (difference * correctionStrength)
                    P[i] = p1 - correction * W1[i]
                    P[i + 1] = p2 + correction * W2[i]
                elseif m == 2 then
                    P[i] = p1 - delta * (difference * correctionStrength)
                elseif m == 3 then
                    P[i + 1] = p2 + delta * (difference * correctionStrength)
                end
            end
        end
    end
    for i = 1, nodeCount do nodes[i].position = P[i] end
    WhipCost.stop('rope: step, solver', cost)
end

--- The snap-back of a taut rope let go, then the ground and the walls.
function Rope.StepWorld(rope, deltaTime)
    local r = Rope.StepScale(deltaTime)
    local nodes = rope.nodes
    local nodeCount = #nodes
    local cost = WhipCost.start()
    -- A taut rope let go springs back a little
    if Config.Physics.EnergyStorageEnabled then
        local tension = Rope.ComputeRopeTension(rope)
        local currentTension = tension.overstretchRatio
        -- No reading before (new, or laid out afresh): no change, rather than all of it at once
        local tensionDelta = currentTension - (rope.prevTension or currentTension)

        if tensionDelta > 0.001 and currentTension > 0.05 then
            rope.storedEnergy = rope.storedEnergy + tensionDelta * Config.Physics.EnergyAccumulationRate * 10.0
            if currentTension > rope.peakTension then rope.peakTension = currentTension end
        end
        rope.prevTension = currentTension

        if currentTension < rope.peakTension * Config.Physics.SnapBackThreshold and rope.storedEnergy > 0.1 then
            rope.isSnapBackActive = true
        end

        -- (Not while it rests on another rope, Config.RopeContact.Carry: it would straighten itself through it)
        if rope.isSnapBackActive and rope.storedEnergy > 0.05 and not rope.wrap then
            local snapForce = rope.storedEnergy * Config.Physics.SnapBackMultiplier
            for i = 2, nodeCount - 1 do
                local node = nodes[i]
                if not node.pinned then
                    local toCenter = (nodes[i - 1].position + nodes[i + 1].position) * 0.5 - node.position
                    local d = #toCenter
                    if d > 0.01 then
                        -- At most to the midpoint, or a node near it jitters back and forth
                        -- (A push each step adds speed: by deltaTime × r, as much a second at any step length)
                        node.position = node.position
                            + toCenter * math.min(1.0, snapForce * node.invMass * deltaTime * r / d)
                    end
                end
            end
            rope.storedEnergy = rope.storedEnergy * Rope.KeptOver(Config.Physics.EnergyDecayRate, r)
        else
            rope.isSnapBackActive = false
        end

        if currentTension < 0.02 then
            rope.peakTension = rope.peakTension * Rope.KeptOver(0.98, r)
            rope.storedEnergy = rope.storedEnergy * Rope.KeptOver(0.99, r)
        end
        rope.debugEnergyTension = currentTension
        rope.debugTensionDelta = tensionDelta
    end
    WhipCost.stop('rope: step, solver', cost)

    -- The ground and walls have the last word
    cost = WhipCost.start()
    Rope.ApplyWorldCollision(rope, deltaTime)
    WhipCost.stop('rope: step, ground + walls', cost)
end

--- The ends pinned again, and the settled rope's pull on what it is tied to (once a step).
function Rope.StepEnds(rope, deltaTime)
    local cost = WhipCost.start()
    ApplyEndPhysics(rope, true, deltaTime)
    WhipCost.stop('rope: step, ends + pull', cost)
end

function Rope.UpdateRopePhysics(rope, deltaTime)
    Rope.StepBegin(rope, deltaTime)
    Rope.StepSolve(rope, 1, Rope.Const.CONSTRAINT_ITERATIONS)
    Rope.StepWorld(rope, deltaTime)
    Rope.StepEnds(rope, deltaTime)
end
