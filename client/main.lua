--[[
    whip_rope — THE LOOPS, THE COMMANDS, CLEANING UP

    The physics steps once a frame, by the game's own frame time, so the rope moves in time with what it holds (a
    hand, a car, a ragdoll hanging off it, all moved by the game every frame): at a fixed rate they fall out of step
    and a hanging body is jerked. Config.Physics.MaxFps caps it (0: none). A frame longer than 1/60 s
    is split into equal steps no longer than that, at most MAX_STEPS. With no rope about, the loop sleeps. A rope
    further than Config.Rope.SimulateRange from you waits where it is (unless you hold it or hang off it, or it is
    tied to a car your game moves), and is laid out afresh between its ends when you come back. A slack rope lying
    still near you rests until something could move it (A ROPE AT REST, below).
]]

local REF_DT = Rope.Const.REF_DT
local MAX_STEPS = Rope.Const.MAX_STEPS
local JUMP = 22

local debugOn = Config.Debug == true
-- Is the overlay up (client/visuals.lua)? The physics works out its numbers only then (client/physics.lua).
Rope.DebugShown = debugOn
local failed = {}   -- [ropeKey] = true once its error was printed

local function report(ropeKey, what, err)
    if failed[ropeKey] then return end
    failed[ropeKey] = true
    print(('[whip_rope] rope %s: %s failed: %s'):format(tostring(ropeKey), what, tostring(err)))
end

-- Below this speed (m/s) what an end is tied to is at rest: nothing pulls the rope, so this game owning it is no
-- reason to simulate it from far away (a hose's nozzle left on the ground at the pump, still this game's object).
local MOVING = 0.2

-- Does this game move what that end is tied to, and is it moving? (only the owner of a car pulls it; a car only this
-- game has, a scene's, only this game can)
local function weMoveEnd(rope, which)
    local t = rope[which .. 'Type']
    if t ~= 'vehicle' and t ~= 'object' then return false end
    local entity = rope[which .. 'Entity']
    if entity == nil or not DoesEntityExist(entity) then return false end
    if GetEntitySpeed(entity) < MOVING then return false end
    -- (A take car's copy is this game's own, but the rope never moves it: not a reason to simulate here)
    if not NetworkGetEntityIsNetworked(entity) then return t == 'vehicle' and not Rope.CopyOf[entity] end
    return NetworkGetEntityOwner(entity) == PlayerId()
end

-- One we hold or hang off; one tied to a car this game moves while it moves (or nobody would pull it); otherwise
-- one whose ends are within SimulateRange of us — and never one held or tied somewhere this game cannot
-- see (its end would hang from nothing, falling through ground far away that is not loaded)
local function shouldSimulate(rope, me, myId)
    if (rope.originType == 'held' and rope.originHeldBy == myId)
        or (rope.tailType == 'held' and rope.tailHeldBy == myId) then
        return true
    end
    local hang = Rope.HangingPlayers[myId]
    if hang and hang.serverRopeId == rope.serverRopeId then return true end
    if weMoveEnd(rope, 'origin') or weMoveEnd(rope, 'tail') then return true end

    -- Where its ends are NOW (a sleeping rope's nodes stay where it fell asleep)
    local a = Rope.AnchorThisFrame(rope, 'origin')
    local b = Rope.AnchorThisFrame(rope, 'tail')
    if (not a and rope.originType ~= 'free') or (not b and rope.tailType ~= 'free') then return false end
    local nodes = rope.nodes
    a, b = a or nodes[1].position, b or nodes[#nodes].position
    local range = Config.Rope.SimulateRange or 120.0
    return #(me - a) < range or #(me - b) < range
end

-- ============================================================================
-- A ROPE AT REST
-- ============================================================================
-- A slack rope lying still near you (on the ground, or hanging between two things that don't move) would cost its
-- whole step every frame for nothing: its passes, the ground and walls, its ends. So once no node of it has moved more
-- than REST_MOVE in REST_AFTER, it RESTS: it is not stepped, pulled or drawn again until something could
-- move it. Each frame a resting rope is looked at for that: an end moved, or held, tied or let go; someone hanging off
-- it; someone moving or fallen, a car moving or an explosion near it (Rope.DisturbedNear, client/collision.lua, with
-- the step's own margins); another rope stepping near it. It is then stepped again from where it lies (and so is one
-- laid out afresh or nudged by another game: Rope.WakeRope). A rope held, hung from, pulling or stretched, springing
-- back or resting on another rope (Config.RopeContact.Carry) never rests. /ropedebug shows which rest.

-- How far its nodes have really gone, not their speed: a node lying still keeps a little of each step's gravity and the
-- ground's push back as its Verlet speed (a few cm/s, more at a low frame rate), and never reads as still by it.
-- A rope with a part hanging off something (a hose from its pump) creeps on along the ground ever slower for a minute
-- or two as that part pulls it in; it rests once that creep is under about 7 mm a second, a few cm short of where it
-- would end up.
local REST_MOVE = 0.01     -- m: no node further than this from where it was...
local REST_AFTER = 1500    -- ms: ...this long ago, and the rope rests
local REST_ANCHOR = 0.01   -- m an end may move before a resting rope wakes
local REST_NEAR = 0.5      -- m between a resting rope's box and a stepping rope's that wakes it
local ENDS = { 'origin', 'tail' }

local function hungFrom(rope)
    for _, h in pairs(Rope.HangingPlayers) do
        if h.serverRopeId == rope.serverRopeId then return true end
    end
    return false
end

--- What an end is tied to (as Rope.AnchorThisFrame keys it): who holds it, where it is put down, or the car or prop.
local function endRef(rope, which)
    local t = rope[which .. 'Type']
    if t == 'held' then return rope[which .. 'HeldBy'] end
    if t == 'fixed' then return rope[which .. 'Position'] end
    return rope[which .. 'Entity']
end

--- May this rope rest, as it is now?
local function mayRest(rope)
    if rope.originType == 'held' or rope.tailType == 'held' then return false end
    if hungFrom(rope) then return false end
    if (rope.originPullN or 0) > 0 or (rope.tailPullN or 0) > 0 then return false end
    if rope.isSnapBackActive or (rope.storedEnergy or 0) > 0.05 or rope.wrap then return false end
    local nodes = rope.nodes
    local n = #nodes
    if n < 2 then return false end
    return #(nodes[n].position - nodes[1].position) <= (n - 1) * Rope.LinkLength(rope)
end

--- A rope's box, `pad` metres all round, into `out` ({ x0, y0, z0, x1, y1, z1 }).
local function boxOf(nodes, pad, out)
    local p = nodes[1].position
    local x0, y0, z0, x1, y1, z1 = p.x, p.y, p.z, p.x, p.y, p.z
    for i = 2, #nodes do
        p = nodes[i].position
        if p.x < x0 then x0 = p.x elseif p.x > x1 then x1 = p.x end
        if p.y < y0 then y0 = p.y elseif p.y > y1 then y1 = p.y end
        if p.z < z0 then z0 = p.z elseif p.z > z1 then z1 = p.z end
    end
    out[1], out[2], out[3], out[4], out[5], out[6] = x0 - pad, y0 - pad, z0 - pad, x1 + pad, y1 + pad, z1 + pad
    return out
end

local function boxesMeet(a, b)
    return a[1] <= b[4] and b[1] <= a[4] and a[2] <= b[5] and b[2] <= a[5] and a[3] <= b[6] and b[3] <= a[6]
end

--- The rope begins to rest: what its ends are tied to and where, and its box, kept to look at (stillResting).
local function beginRest(rope)
    local r = rope.rest or { box = {} }
    rope.rest = r
    for _, which in ipairs(ENDS) do
        r[which .. 'Type'] = rope[which .. 'Type']
        r[which .. 'Ref'] = endRef(rope, which)
        r[which .. 'Offset'] = rope[which .. 'Offset']
        r[which .. 'At'] = Rope.AnchorThisFrame(rope, which)
    end
    boxOf(rope.nodes, 0.0, r.box)
    rope.resting = true
    Rope.Util.DebugPrint('rope', rope.serverRopeId, 'is at rest')
end

--- Each frame a rope steps: free to rest, and no node further than REST_MOVE from where it was REST_AFTER ago (a
--- snapshot taken when it last moved more, rope.restSnap), it rests.
local function noteRest(rope, now)
    if not mayRest(rope) then rope.stillSince = nil return end
    local nodes, snap = rope.nodes, rope.restSnap
    if rope.stillSince and snap and #snap == #nodes then
        local lim2 = REST_MOVE * REST_MOVE
        for i = 1, #nodes do
            local p, q = nodes[i].position, snap[i]
            local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
            if dx * dx + dy * dy + dz * dz > lim2 then rope.stillSince = nil break end
        end
    else
        rope.stillSince = nil
    end
    if not rope.stillSince then
        snap = snap or {}
        for i = 1, #nodes do snap[i] = nodes[i].position end
        for i = #nodes + 1, #snap do snap[i] = nil end
        rope.restSnap, rope.stillSince = snap, now
        return
    end
    if now - rope.stillSince >= REST_AFTER then beginRest(rope) end
end

--- Is a resting rope still at rest? `boxes`: the boxes of the ropes stepping this frame (`count` of them). Answers
--- false and why once something could move it.
local function stillResting(rope, boxes, count)
    local r = rope.rest
    for _, which in ipairs(ENDS) do
        if rope[which .. 'Type'] ~= r[which .. 'Type'] or endRef(rope, which) ~= r[which .. 'Ref']
            or rope[which .. 'Offset'] ~= r[which .. 'Offset'] then
            return false, 'an end held, tied or let go'
        end
        local at, was = Rope.AnchorThisFrame(rope, which), r[which .. 'At']
        if (at == nil) ~= (was == nil) or (at and #(at - was) > REST_ANCHOR) then return false, 'an end moved' end
    end
    if hungFrom(rope) then return false, 'someone hangs off it' end
    local why = Rope.DisturbedNear(rope, r.box)
    if why then return false, why end
    for i = 1, count do
        if boxesMeet(r.box, boxes[i]) then return false, 'another rope near it' end
    end
    return true
end

local stepBoxes = {}   -- this frame's stepping ropes' boxes (restCheck), kept to be filled again

--- Each frame, before any rope steps: every resting rope looked at, and woken by anything that could move it.
local function restCheck(ropes)
    local anyResting, count = false, 0
    for _, rope in pairs(ropes) do
        if rope.simulated ~= false and rope.resting then anyResting = true break end
    end
    if not anyResting then return end
    for _, rope in pairs(ropes) do
        if rope.simulated ~= false and not rope.resting and rope.nodes[1] then
            count = count + 1
            stepBoxes[count] = boxOf(rope.nodes, REST_NEAR, stepBoxes[count] or {})
        end
    end
    for ropeKey, rope in pairs(ropes) do
        if rope.simulated ~= false and rope.resting then
            local ok, still, why = pcall(stillResting, rope, stepBoxes, count)
            if not ok then
                report(ropeKey, 'the rest check', still)
                Rope.WakeRope(rope)
            elseif not still then
                Rope.WakeRope(rope)
                Rope.Util.DebugPrint('rope', rope.serverRopeId, 'wakes:', why)
            end
        end
    end
end

-- ============================================================================
-- PHYSICS AND PROPS
-- ============================================================================

CreateThread(function()
    local acc = 0.0
    local ropes = Rope.System.ropes

    while true do
        if not next(ropes) then
            acc = 0.0
            Wait(250)
        else
            local frameCost = WhipCost.start()
            local now = GetGameTimer()
            -- The game's own frame time (a float: GetGameTimer's whole milliseconds are ±15% of a frame at 300 fps)
            local frameDt = math.min(math.max(GetFrameTime(), 0.0), 0.25)
            acc = acc + frameDt
            -- This frame, for what is read once a frame (Rope.AnchorThisFrame, client/physics.lua)
            Rope.Frame = Rope.Frame + 1

            -- Who sleeps, twice a second (where we are read only when a rope is due)
            local me
            local myId = Rope.MyServerId()
            for ropeKey, rope in pairs(ropes) do
                if now >= (rope.simCheckAt or 0) then
                    rope.simCheckAt = now + 500
                    me = me or GetEntityCoords(PlayerPedId())
                    local ok, sim = pcall(shouldSimulate, rope, me, myId)
                    if ok and sim and rope.simulated == false then
                        -- Waking: laid out afresh between its ends where they are now
                        local laid, err = pcall(Rope.SettleRope, rope)
                        if not laid then report(ropeKey, 'laying it out', err) end
                    end
                    if ok then
                        rope.simulated = sim
                    else
                        report(ropeKey, 'the range check', sim)
                    end
                end
            end

            -- Ropes at rest: still, or woken by what could move them (A ROPE AT REST, above)
            restCheck(ropes)

            -- The steps: the time since the last, once it is at least 1/MaxFps (every frame with no cap), in equal
            -- steps of 1/60 s at most, MAX_STEPS at most (a longer hitch drops its backlog)
            local maxFps = tonumber(Config.Physics.MaxFps) or 0
            local minDt = maxFps > 0 and 1.0 / maxFps or 0.0
            if acc > 0.0 and acc >= minDt then
                local total = math.min(acc, REF_DT * MAX_STEPS)
                local steps = math.max(1, math.ceil(total / REF_DT - 1e-6))
                local dt = total / steps
                for _ = 1, steps do
                    if Rope.Carrying() then
                        -- Ropes taking each other's weight: stepped together, held apart between passes (client/contact.lua)
                        Rope.StepTogether(ropes, dt, report)
                    else
                        for ropeKey, rope in pairs(ropes) do
                            if rope.simulated ~= false and not rope.resting then
                                local ok, err = pcall(Rope.UpdateRopePhysics, rope, dt)
                                if not ok then report(ropeKey, 'the physics', err) end
                            end
                        end
                        -- Ropes against each other, once every rope has taken this step (client/contact.lua)
                        local cost = WhipCost.start()
                        local ok, err = pcall(Rope.TouchRopes, ropes, dt)
                        if not ok then report('contact', 'ropes against each other', err) end
                        WhipCost.stop('rope: step, ropes against each other', cost)
                    end
                end
                acc = 0.0
            end

            for ropeKey, rope in pairs(ropes) do
                if rope.simulated ~= false and not rope.resting then
                    -- The rope's length, once a frame (it reads the speeds the game gives)
                    local cost = WhipCost.start()
                    local ok, err = pcall(Rope.ApplyRopeLimit, rope, frameDt)
                    if not ok then report(ropeKey, 'the length limit', err) end
                    WhipCost.stop('rope: frame, length limit', cost)
                    cost = WhipCost.start()
                    ok, err = pcall(Rope.UpdateRopeVisuals, rope)
                    if ok then ok, err = pcall(Rope.UpdateHangingVisuals, rope) end
                    if not ok then report(ropeKey, 'drawing it', err) end
                    WhipCost.stop('rope: frame, drawing', cost)
                    -- Drawn where it lies: still long enough, it rests from the next frame
                    ok, err = pcall(noteRest, rope, now)
                    if not ok then report(ropeKey, 'the rest check', err) end
                end
            end

            -- Hanging: jump lets go (move controls are blocked, so read the disabled one) — not in its
            -- first half second, so nothing pressed along with the hold drops it straight away
            if Rope.IsPlayerHanging() and now - (Rope.HangStartedAt or 0) > 500
                and IsDisabledControlJustPressed(0, JUMP) then
                Rope.DetachPlayerFromRope()
            end

            -- Someone hanging (a stand-in about): a shot of ours through them knocks them off
            if next(Rope.Clones) then
                local ok, err = pcall(Rope.CheckShotsAtHanging)
                if not ok then report('shots', 'looking for shots at hanging players', err) end
            end

            if debugOn then
                Rope.DrawDebugOverlay()
                if Config.DrawDebugLines or Config.DrawDebugSpheres then
                    for _, rope in pairs(ropes) do Rope.DrawRopeDebug(rope) end
                end
            end
            WhipCost.stop('rope: frame, everything', frameCost)

            -- Every rope asleep (all far away), nobody hanging or drawn hanging, no overlay: nothing to step or draw, so
            -- the loop looks again in a quarter of a second rather than every frame. The range check above still runs
            -- (twice a second per rope), and a rope that wakes is laid out afresh, so the time slept is not stepped.
            if not Rope.AnyAwake() and not Rope.IsPlayerHanging() and not next(Rope.Clones) and not debugOn then
                acc = 0.0
                Wait(250)
            else
                Wait(0)
            end
        end
    end
end)

-- ============================================================================
-- EXPLOSIONS NEAR A ROPE
-- ============================================================================

CreateThread(function()
    while true do
        Wait(Rope.AnyAwake() and 100 or Rope.Const.IDLE_MS)   -- only awake ropes are looked at
        local cfg = Config.ExplosionInteraction
        if cfg.Enabled and next(Rope.System.ropes) then
            for _, rope in pairs(Rope.System.ropes) do
                if rope.simulated ~= false then
                    local centre = rope.nodes[math.ceil(#rope.nodes / 2)].position
                    if IsExplosionInSphere(-1, centre.x, centre.y, centre.z, cfg.Radius) then
                        local at = Rope.FindExplosionPosition(centre, cfg.Radius)
                        if at then
                            local now = GetGameTimer()
                            local seen = false
                            for _, e in ipairs(Rope.System.recentExplosions) do
                                if #(e.position - at) < 5.0 and now - e.time < 200 then seen = true break end
                            end
                            if not seen then
                                table.insert(Rope.System.recentExplosions, { position = at, time = now })
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- ============================================================================
-- COMMANDS
-- ============================================================================

-- Developer mode only (whip_core decides).
local function devAllowed()
    if Whip.call('HasDevTools') == true then return true end
    Rope.Util.Notify('That command needs developer mode on (/w)', 'error')
    return false
end

-- The overlay, for yourself
RegisterCommand('ropedebug', function()
    if not devAllowed() then return end
    debugOn = not debugOn
    Rope.DebugShown = debugOn
    Rope.Util.Notify('Rope debug ' .. (debugOn and 'on' or 'off'), 'info')
end, false)

-- What this game has, in F8
RegisterCommand('ropestatus', function()
    if not devAllowed() then return end
    local _, heldKey, heldEnd = Rope.MyHeld()
    print('=== whip_rope ===')
    print('Look:', Rope.CurrentStyle() .. (Rope.CurrentStyle() == 'gta' and (' type ' .. Rope.GtaRopeType()) or ''))
    print('Holding:', heldKey and (heldEnd .. ' of rope ' .. tostring(heldKey)) or 'nothing')
    local hang = Rope.HangingPlayers[Rope.MyServerId()]
    print('Hanging:', hang and ('rope ' .. hang.serverRopeId .. ', node ' .. hang.nodeIndex) or 'no')
    for ropeKey, rope in pairs(Rope.System.ropes) do
        print(('  rope %s: origin=%s tail=%s owner=%s %s'):format(tostring(ropeKey),
            tostring(rope.originType), tostring(rope.tailType), tostring(rope.ownerServerId),
            rope.simulated == false and '(asleep)' or ''))
    end
end, false)

-- ============================================================================
-- CLEANING UP
-- ============================================================================
-- Whatever whip_core holds for us (the ped hold, the control block, the walk, the prompts, the text)
-- it lets go of itself when we stop; the ped's own flags, the rope's look and the stand-ins are ours.

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if Rope.IsPlayerHanging() then Rope.DetachPlayerFromRope(false) end
    Rope.DeleteAllClones()
    for ropeKey, rope in pairs(Rope.System.ropes) do
        Rope.DestroyRopeVisuals(rope)
        Rope.System.ropes[ropeKey] = nil
    end
    Rope.ReleaseLookModels()
end)
