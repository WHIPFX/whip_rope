--[[
    whip_rope — ROPES FOR EVERY RESOURCE

    Any resource can tie a rope between two things — a hand, a car, a prop (a map prop where it stands, or a
    networked one), a fixed point — and move its ends as it likes. Built and simulated as every rope is; the
    resource decides how it behaves:

      CreateRope(spec)              its id. spec = {
                                       origin, tail      ENDs (server/state.lua): { type = 'held', heldBy },
                                                         { type = 'vehicle', netId, offset | edge = 'front' | 'back' },
                                                         { type = 'object', netId (0: a map prop), model, worldPos,
                                                           offset, point, still?, mass? }, { type = 'fixed', pos }
                                                         mass: what a prop really weighs (kg). The game can't read
                                                         a prop's weight, so the rope guesses from its box (100 kg a
                                                         cubic metre); a heavy prop's resource says, or the rope
                                                         throws it about like a light one (a torn pump)
                                       length = 3.0      metres (the item rope's, Config.Rope.Length, when left out)
                                       link = 0.25       metres between its nodes (the item rope's when left out).
                                                         Never more than 64 nodes: past that the links are longer.
                                                         Kept with the rope as it is made: a change to Config.Rope
                                                         later (the settings page) never resizes it
                                       player = source   the player it is for (whose game builds it first, and
                                                         whose nearness keeps it simulated)
                                       kind = 'hose'     a tag of the resource's own, for its own finding
                                       locked = true     nobody grabs, ties, puts down, coils or hangs off it: the
                                                         resource moves it (SetRopeEnd)
                                       take = false      (unlocked) nobody picks its ends up or unties them
                                       hang = false      (unlocked) nobody hangs off it
                                       look = { model, modelNoShadow, thickness }   its own pieces (model space
                                                         as whip_rope_seg's, docs/whip_rope_seg.txt)
                                       collide = { spacing = 1, vehicles = true, props = true }   every Nth node
                                                         probed against the world; cars or not, props or not
                                                         (left out: whip_rope's Config.WorldCollision.Vehicles,
                                                         and .Props). The map is always probed
                                       heldAt = { model, offset }   a held end sits at `offset` on the prop of
                                                         `model` in that hand (a nozzle's back), not the hand
                                       watch = { stretch = 0.35, holdMs = 250, broken = true }   say when it is
                                                         pulled that far past its length (whip_rope:ropeStretched),
                                                         and when a map prop it is tied to is blown up
                                                         (whip_rope:ropeEndBroken)
                                       maxStretch = 0.2  a hard length: past 20% the two ends are drawn together
                                                         by one pull, each by what it weighs (a car feels the
                                                         prop it drags), at most a very strong hose's pull. Not
                                                         one other ropes hold back, nor a car driving away from
                                                         something that does not move. Left out, the rope is
                                                         elastic with no hard end, as every rope of whip_rope's own
                                    }
      SetRopeEnd(id, which, end)    'origin' | 'tail'
      SetRopeRules(id, rules)       { take?, hang?, stretch? }: from now on (stretch: watch.stretch; false stops it)
      RemoveRope(id)
      GetRope(id)                   { kind, origin, tail, length } — or nil

    A resource's rope is the resource's: it stays when the player it was for leaves, and goes when the resource
    stops. Only its resource changes it — an admin's /clearropes aside, which takes it away and says so. Never an
    item: nobody coils it up, locked or not. A player who dies holding a locked rope's end keeps it till the resource
    moves it.

    THE NOTICES are server events, for whoever listens (the resource looks for its own ids):
      whip_rope:ropeStretched (id, resource)          believed when its ends really are that far apart, and the
                                                      player saying so is near it
      whip_rope:ropeEndBroken (id, which, resource)
      whip_rope:ropeRemoved (id, resource, why)       whip_rope took it away itself (an admin's /clearropes): the id
                                                      is gone, forget it
    ...and one on the game of the player holding an end (client/drag.lua):
      whip_rope:pulledFromHand (id, which, resource)  its other end, tied to a car or prop going away, dragged them
                                                      along (Config.Drag) and they let go — or died. A locked rope's
                                                      end stays theirs till the resource moves it (SetRopeEnd): letting
                                                      go is the resource's to do, its own way

    ON A GAME (client/api.lua):
      GetRopeEndEntity(id, which)   the car or prop that end is tied to on this game, or nil (not tied to one, not
                                    streamed in here yet, or no such rope here): an end moved with SetRopeEnd has
                                    reached this game once it answers the new one
]]

local WHICH = { origin = true, tail = true }

local function vec(t)
    if type(t) ~= 'table' and type(t) ~= 'vector3' then return nil end
    local x, y, z = tonumber(t.x or t[1]), tonumber(t.y or t[2]), tonumber(t.z or t[3])
    if not (x and y and z) then return nil end
    return { x = x + 0.0, y = y + 0.0, z = z + 0.0 }
end

--- An end as a resource wrote it, made one the games read. Nil and why when it is not one.
local function endOf(e)
    if type(e) ~= 'table' then return nil, 'an end is a table: { type = ... }' end
    local t = e.type
    if t == 'held' then
        local src = tonumber(e.heldBy)
        if not src then return nil, 'a held end names heldBy (a player)' end
        return { type = 'held', heldBy = src }
    elseif t == 'fixed' then
        local pos = vec(e.pos)
        if not pos then return nil, 'a fixed end names pos' end
        -- tied: to the map there (players see "Untie the rope"), not put down
        return { type = 'fixed', pos = pos, tied = e.tied == true or nil }
    elseif t == 'vehicle' then
        local netId = tonumber(e.netId)
        if not netId or netId <= 0 then return nil, 'a vehicle end names netId' end
        if e.edge ~= nil and e.edge ~= 'front' and e.edge ~= 'back' then return nil, "a vehicle end's edge is 'front' or 'back'" end
        return { type = 'vehicle', netId = netId, offset = vec(e.offset) or { x = 0.0, y = 0.0, z = 0.0 }, edge = e.edge }
    elseif t == 'object' then
        local netId = tonumber(e.netId) or 0
        local out = { type = 'object', netId = netId, offset = vec(e.offset) or { x = 0.0, y = 0.0, z = 0.0 } }
        local kg = tonumber(e.mass)
        if kg and kg > 0 then out.mass = math.min(kg, 100000.0) + 0.0 end
        if netId <= 0 then
            -- A map prop: by its model where it stands (every game has its own)
            out.model = tonumber(e.model)
            out.worldPos = vec(e.worldPos)
            if not out.model or not out.worldPos then return nil, 'a map prop end names model and worldPos' end
            out.point = vec(e.point) or out.worldPos
            out.still = e.still == true or nil
        end
        return out
    elseif t == 'free' then
        return { type = 'free' }
    end
    return nil, ('unknown end type "%s"'):format(tostring(t))
end

--- Where a rope is first laid out: its origin's point, else its tail's.
local function startOf(rope)
    for _, which in ipairs({ 'origin', 'tail' }) do
        local e = rope[which]
        local p = e.point or e.pos or e.worldPos
        if p then return { x = p.x, y = p.y, z = p.z } end
        local at = Ropes.endPos(e)
        if at then return Ropes.wire(at) end
    end
    return nil
end

--- How a resource's rope behaves, from its spec: only what the games read.
local function optsOf(spec)
    local o = {}
    o.locked = spec.locked == true or nil
    -- Unlocked, what players may still not do: pick its ends up (or untie them), hang off it
    o.noTake = spec.take == false or nil
    o.noHang = spec.hang == false or nil
    if type(spec.look) == 'table' then
        o.look = {
            model = tonumber(spec.look.model),
            modelNoShadow = tonumber(spec.look.modelNoShadow),
            thickness = tonumber(spec.look.thickness),
        }
    end
    if type(spec.collide) == 'table' then
        local vehicles, props = spec.collide.vehicles, spec.collide.props
        if vehicles ~= nil then vehicles = vehicles == true end
        if props ~= nil then props = props == true end
        o.collide = { spacing = math.max(1, math.floor(tonumber(spec.collide.spacing) or 2)), vehicles = vehicles,
                      props = props }
    end
    if type(spec.heldAt) == 'table' and spec.heldAt.model then
        local m = spec.heldAt.model
        o.heldAt = { model = type(m) == 'number' and m or GetHashKey(tostring(m)), offset = vec(spec.heldAt.offset) or { x = 0.0, y = 0.0, z = 0.0 } }
    end
    if type(spec.watch) == 'table' then
        o.watch = {
            stretch = tonumber(spec.watch.stretch),
            holdMs = tonumber(spec.watch.holdMs) or 250,
            broken = spec.watch.broken == true or nil,
        }
    end
    local hard = tonumber(spec.maxStretch)
    if hard then o.maxStretch = math.max(0.0, math.min(2.0, hard)) end
    return o
end

--- The most nodes a resource's rope has (the item rope has 24 by default, a pump's hose 25). A longer or finer one gets
--- longer links instead, said once per resource.
local MAX_NODES = 64
local clampSaid = {}

--- A rope for `resource`. Its id, or nil and why. (whip_rope's own code calls this as the exports do.)
function Ropes.create(spec, resource)
    if type(spec) ~= 'table' then return nil, 'spec is a table' end
    local origin, why = endOf(spec.origin)
    if not origin then return nil, 'origin: ' .. why end
    local tail
    tail, why = endOf(spec.tail)
    if not tail then return nil, 'tail: ' .. why end

    local length = math.max(0.5, math.min(100.0, tonumber(spec.length) or Config.Rope.Length))
    local link = math.max(0.05, tonumber(spec.link) or Config.Rope.SegmentLength)
    local nodes = math.max(4, math.floor(length / link + 0.5) + 1)
    -- Every node is simulated and probed on every game near it, every frame: MAX_NODES at most, the links longer
    if nodes > MAX_NODES then
        if not clampSaid[resource] then
            clampSaid[resource] = true
            print(('[whip_rope] %s asked for a rope of %d nodes (%.1f m at %.2f m links): made with %d, links of %.2f m'):format(
                tostring(resource), nodes, length, link, MAX_NODES, length / (MAX_NODES - 1)))
        end
        nodes = MAX_NODES
    end

    local id = Ropes.nextId
    Ropes.nextId = id + 1
    local rope = {
        id = id, owner = tonumber(spec.player) or 0, createdAt = os.time(),
        kind = type(spec.kind) == 'string' and spec.kind:sub(1, 32) or nil,
        nodes = nodes, link = length / (nodes - 1),
        origin = origin, tail = tail,
        byResource = resource,
        opts = optsOf(spec),
    }
    rope.originPosition = startOf(rope)
    if not rope.originPosition then return nil, 'neither end is anywhere yet' end
    -- A loose end lies where the rope is laid out (Ropes.loose: so it can be found)
    for _, which in ipairs({ 'origin', 'tail' }) do
        if rope[which].type == 'free' and not rope[which].at then rope[which].at = rope.originPosition end
    end
    Ropes.all[id] = rope
    TriggerClientEvent('whip_rope:spawned', -1, Ropes.payload(rope))
    return id
end

--- Move one end of `resource`'s rope.
function Ropes.setEnd(id, which, e, resource)
    local rope = Ropes.all[tonumber(id)]
    if not rope or rope.byResource ~= resource then return false, 'not your rope' end
    if not WHICH[which] then return false, "which is 'origin' or 'tail'" end
    local made, why = endOf(e)
    if not made then return false, why end
    -- Let go: loose where that end was, so the rope can still be found (Ropes.loose)
    if made.type == 'free' then made = Ropes.loose(rope[which]) end
    rope[which] = made
    Ropes.sendEnds(rope, which == 'origin', which == 'tail')
    return true
end

--- What `resource`'s rope lets players do, and how far it may be pulled before it says so, from now on: `rules` =
--- { take?, hang?, stretch? }. A field left out stays as it was; stretch false stops the stretch watch. Every game is told.
function Ropes.setRules(id, rules, resource)
    local rope = Ropes.all[tonumber(id)]
    if not rope or rope.byResource ~= resource then return false, 'not your rope' end
    if type(rules) ~= 'table' then return false, 'rules is { take?, hang?, stretch? }' end
    local o = rope.opts or {}
    rope.opts = o
    if rules.take ~= nil then o.noTake = rules.take == false or nil end
    if rules.hang ~= nil then o.noHang = rules.hang == false or nil end
    if rules.stretch == false then
        if o.watch then o.watch.stretch = nil end
    elseif rules.stretch ~= nil then
        local s = tonumber(rules.stretch)
        if not s or s <= 0 then return false, 'stretch is how far past its length, 0.35 for 35%' end
        o.watch = o.watch or {}
        o.watch.stretch = math.min(s, 2.0)
        o.watch.holdMs = o.watch.holdMs or 250
    end
    TriggerClientEvent('whip_rope:opts', -1, rope.id, o)
    return true
end

--- Take `resource`'s rope away.
function Ropes.removeOwn(id, resource)
    local rope = Ropes.all[tonumber(id)]
    if not rope or rope.byResource ~= resource then return false end
    Ropes.remove(rope.id)
    return true
end

-- ============================================================================
-- THE EXPORTS
-- ============================================================================

exports('CreateRope', function(spec)
    local id, why = Ropes.create(spec, GetInvokingResource() or GetCurrentResourceName())
    if not id then return false, why end
    return id
end)

exports('SetRopeEnd', function(id, which, e)
    return Ropes.setEnd(id, which, e, GetInvokingResource() or GetCurrentResourceName())
end)

exports('RemoveRope', function(id)
    return Ropes.removeOwn(id, GetInvokingResource() or GetCurrentResourceName())
end)

exports('SetRopeRules', function(id, rules)
    return Ropes.setRules(id, rules, GetInvokingResource() or GetCurrentResourceName())
end)

exports('GetRope', function(id)
    local rope = Ropes.all[tonumber(id)]
    if not rope then return nil end
    return { kind = rope.kind, origin = rope.origin, tail = rope.tail, length = Ropes.length(rope) }
end)

-- A resource stopping takes its ropes with it
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end
    local theirs = {}
    for id, rope in pairs(Ropes.all) do
        if rope.byResource == res then theirs[#theirs + 1] = id end
    end
    for _, id in ipairs(theirs) do Ropes.remove(id) end
end)

-- ============================================================================
-- THE NOTICES (client/api.lua's watch says; the server believes what it can check)
-- ============================================================================

--- Pulled past its `watch.stretch`: believed when its ends really are most of that far apart (some of the stretch
--- is the pull taking up slack), and the player saying so is near it.
local function onStretched(source, _, ropeId)
    local rope = Ropes.all[ropeId]
    local w = rope and rope.opts and rope.opts.watch
    if not w or not w.stretch then return end
    local a, b = Ropes.endPos(rope.origin), Ropes.endPos(rope.tail)
    if not a or not b then return end
    if #(a - b) < Ropes.length(rope) * (1.0 + w.stretch * 0.6) then return end
    if not Ropes.near(source, rope) then return end
    TriggerEvent('whip_rope:ropeStretched', rope.id, rope.byResource)
    Ropes.changed('stretched', rope, source)
end

-- Explosions the server has seen lately: { { x, y, z, at }, ... }. OneSync routes every game's explosion through the
-- server (explosionEvent), so a map prop said to be blown up is believed only with one near it just now.
local BLAST_REACH = 15.0     -- m from the prop
local BLAST_KEEP_MS = 10000
local blasts = {}

AddEventHandler('explosionEvent', function(_, ev)
    if type(ev) ~= 'table' then return end
    local x, y, z = tonumber(ev.posX), tonumber(ev.posY), tonumber(ev.posZ)
    if not (x and y and z) then return end
    local now = GetGameTimer()
    for i = #blasts, 1, -1 do
        if now - blasts[i].at > BLAST_KEEP_MS then table.remove(blasts, i) end
    end
    blasts[#blasts + 1] = { x = x, y = y, z = z, at = now }
end)

local function blastNear(p)
    local now = GetGameTimer()
    for _, b in ipairs(blasts) do
        if now - b.at <= BLAST_KEEP_MS and #(vector3(b.x, b.y, b.z) - p) <= BLAST_REACH then return true end
    end
    return false
end

--- A map prop one of its ends is tied to was blown up, says a game near it: believed when the server saw an explosion
--- by it just now (a game saying so with none is not).
local function onEndBroken(source, _, ropeId, which)
    local rope = Ropes.all[ropeId]
    local w = rope and rope.opts and rope.opts.watch
    if not w or not w.broken or not WHICH[which] then return end
    local e = rope[which]
    local at = e.type == 'object' and Ropes.endPos(e)
    if not at or not blastNear(at) then return end
    if not Ropes.near(source, rope) then return end
    TriggerEvent('whip_rope:ropeEndBroken', rope.id, which, rope.byResource)
end

Whip.register(function()
    exports.whip_core:SecureEvent('whip_rope:stretched', {
        rateLimit = 500, burst = 2, params = { { 'ropeId', 'id', 1, 2147483647 } },
    }, onStretched)
    exports.whip_core:SecureEvent('whip_rope:endBroken', {
        rateLimit = 500, burst = 2,
        params = { { 'ropeId', 'id', 1, 2147483647 }, { 'which', 'enum', { 'origin', 'tail' } } },
    }, onEndBroken)
end)
