--[[
    whip_rope — THE SERVER'S RECORD OF EVERY ROPE

    The server never simulates a rope: it keeps each one's two ends and who hangs off it, checks what
    players ask to do with them, and tells every game. Shared by server/item.lua and server/main.lua
    through the one `Ropes` table.

    A rope:   { id, owner (server id), ownerCharId, createdAt, originPosition = {x,y,z} (where it was
                made), origin = END, tail = END, coiling = source|nil,
                nodes, link (its node count and link length, set as it is made: every game builds it from
                these, and a change to Config.Rope later never resizes it), byResource? (a resource's:
                server/api.lua, it stays when its owner leaves and goes when that resource stops), opts?
                (server/api.lua: locked, noTake, noHang, look, collide, heldAt, watch) }
    An END:   { type = 'held', heldBy } | { type = 'free', at? = {x,y,z} (where it was let go: Ropes.loose) }
              | { type = 'fixed', pos = {x,y,z}, tied? (to the map) }
              | { type = 'vehicle', netId, offset = {x,y,z}, edge? ('front' | 'back': at its nose or tail, worked out
                from its model on every game, in place of offset), vehicleId? (whip's id for it, when it is a whip car) }
              | { type = 'vehicle', netId = 0, model, worldPos, point, offset, localTo } (a car only one
                player's game has, a whip_scenes scene's: found again there by model where it was tied)
              | { type = 'object', netId (0: a map prop), model, worldPos, offset, point, still? (a map prop
                that stays an anchor: never woken and dragged), mass? (kg: what it really weighs, server/api.lua) }
]]

Ropes = {
    all = {},        -- [id] = rope
    hanging = {},    -- [source] = { serverRopeId, nodeIndex }
    owed = {},       -- [charId] = ropes to hand back when they are next in (also in the resource's KVP)
    nextId = 1,
}

function Ropes.debug(...)
    if Config.Debug then print('[whip_rope]', ...) end
end

--- A locked rope is its resource's to move: nobody grabs, ties, puts down, coils or hangs off it (server/api.lua).
function Ropes.locked(rope)
    return rope.opts ~= nil and rope.opts.locked == true
end

local function wire(v)
    return { x = v.x + 0.0, y = v.y + 0.0, z = v.z + 0.0 }
end
Ropes.wire = wire

function Ropes.pedPos(source)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
    return GetEntityCoords(ped)
end

--- A rope's length: from its own node count and link length, as it was made.
function Ropes.length(rope)
    return (rope.nodes - 1) * rope.link
end

-- ============================================================================
-- WHO HAS WHAT
-- ============================================================================

--- The rope end this player holds: rope, 'origin' | 'tail' — or nil. Their hands are full with any. `unlocked`: only
--- a rope's they may handle, not a locked one's (a resource's, as a pump's hose: its end is that resource's thing in
--- the hand, moved only by it; client/state.lua MyHeld says the same). Death lets go of that one, and coils it.
function Ropes.heldBy(source, unlocked)
    for _, rope in pairs(Ropes.all) do
        if not (unlocked and Ropes.locked(rope)) then
            if rope.origin.type == 'held' and rope.origin.heldBy == source then return rope, 'origin' end
            if rope.tail.type == 'held' and rope.tail.heldBy == source then return rope, 'tail' end
        end
    end
    return nil
end

--- The ropes a player has out (a resource's rope is not one of them: Config.Rope.MaxRopes counts the item's).
function Ropes.countOf(source)
    local n = 0
    for _, rope in pairs(Ropes.all) do
        if rope.owner == source and not rope.byResource then n = n + 1 end
    end
    return n
end

-- ============================================================================
-- WHERE A ROPE IS, AS FAR AS THE SERVER KNOWS
-- ============================================================================

--- Where an end is held, put down or tied, or where a loose one was let go (`at`); nil when the server does not know
--- (a loose end with no `at`, or one on a car only one game has: only the games simulating it know). A tied end is
--- the tie point itself, not the entity's middle (the back of a bus is metres from it).
function Ropes.endPos(e)
    if e.type == 'fixed' and e.pos then
        return vector3(e.pos.x, e.pos.y, e.pos.z)
    elseif e.type == 'free' then
        local p = e.at
        return p and vector3(p.x, p.y, p.z) or nil
    elseif e.type == 'held' then
        return Ropes.pedPos(e.heldBy)
    elseif e.type == 'vehicle' and (e.netId or 0) == 0 then
        return nil
    elseif e.type == 'vehicle' or (e.type == 'object' and (e.netId or 0) > 0) then
        local entity = NetworkGetEntityFromNetworkId(e.netId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then
            -- The offset turned by the heading (a car's pitch and roll left out: centimetres)
            local c = GetEntityCoords(entity)
            local o = e.offset or { x = 0.0, y = 0.0, z = 0.0 }
            local h = math.rad(GetEntityHeading(entity))
            local cs, sn = math.cos(h), math.sin(h)
            return vector3(c.x + o.x * cs - o.y * sn, c.y + o.x * sn + o.y * cs, c.z + o.z)
        end
    elseif e.type == 'object' then
        local p = e.point or e.worldPos
        if p then return vector3(p.x, p.y, p.z) end
    end
    return nil
end

--- An end let go: loose, keeping where it was (`at`), so a rope with both ends loose can still be found, picked up and
--- built by games that come near it later. `at`: that spot if the caller knows it better (a car's last seen place),
--- else where the end was (Ropes.endPos), else where it was tied.
function Ropes.loose(e, at)
    local p = at or (e and (Ropes.endPos(e) or e.point or e.worldPos))
    return { type = 'free', at = p and wire(p) or nil }
end

--- Is the player within reach of this rope? Measured from its ends (a rope is never longer than
--- its length from either), with room for ping and a slack rope.
function Ropes.near(source, rope, slack)
    local me = Ropes.pedPos(source)
    if not me then return false end
    local reach = Ropes.length(rope) + (slack or 8.0)
    local any = false
    for _, which in ipairs({ 'origin', 'tail' }) do
        local p = Ropes.endPos(rope[which])
        if p then
            any = true
            if #(me - p) <= reach then return true end
        end
    end
    -- Neither end anywhere the server knows (both loose, with no spot kept): where it was made, or its owner
    if not any then
        local o = rope.originPosition
        if o and #(me - vector3(o.x, o.y, o.z)) <= reach + 50.0 then return true end
        local ownerAt = Ropes.pedPos(rope.owner)
        return ownerAt ~= nil and #(me - ownerAt) <= reach + 50.0
    end
    return false
end

-- ============================================================================
-- TELLING THE GAMES
-- ============================================================================

--- A rope as every game builds it.
function Ropes.payload(rope)
    return {
        serverRopeId = rope.id,
        owner = rope.owner,
        originPosition = rope.originPosition,
        origin = rope.origin,
        tail = rope.tail,
        -- Its own node count and link length (every rope's, as it was made), and a resource's rope's tag and how it
        -- behaves (server/api.lua)
        nodes = rope.nodes,
        link = rope.link,
        kind = rope.kind,
        opts = rope.opts,
        resource = rope.byResource,   -- told on the holder's game when its end is pulled from their hands
    }
end

-- ============================================================================
-- WHO HEARS OF A CHANGE (server/director.lua's cards wait on these)
-- ============================================================================

local listeners = {}

--- fn(what, rope, source) on every change: 'ends' (an end changed), 'hang' / 'unhang' (source began or stopped hanging
--- off it), 'stretched' (pulled past its watch, believed: server/api.lua), 'removed'.
function Ropes.onChange(fn) listeners[#listeners + 1] = fn end

--- Tell every listener. One that fails is printed; the rest still hear it.
function Ropes.changed(what, rope, source)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, what, rope, source)
        if not ok then print(('[whip_rope] a rope listener failed on %s: %s'):format(what, tostring(err))) end
    end
end

--- One end, or both, changed: every game, and who keeps what it pulls (server/keep.lua). `by`: the player who did it,
--- when one did (the listeners hear who).
function Ropes.sendEnds(rope, origin, tail, by)
    TriggerClientEvent('whip_rope:ends', -1, rope.id, {
        origin = origin and rope.origin or nil,
        tail = tail and rope.tail or nil,
    })
    Keepers.soon()
    Ropes.changed('ends', rope, by)
end

--- A player's game did something the server refused: the rope as it really is, for them.
function Ropes.correct(source, ropeId)
    local rope = ropeId and Ropes.all[ropeId]
    if rope then
        TriggerClientEvent('whip_rope:correction', source, Ropes.payload(rope))
    end
end

-- ============================================================================
-- CHANGES EVERY PATH SHARES
-- ============================================================================

--- Having put one end somewhere, the player takes the other when it is lying loose (as their game
--- did already). Answers whether they did.
function Ropes.takeOtherIfLoose(rope, which, source)
    local other = which == 'origin' and 'tail' or 'origin'
    if rope[other].type == 'free' and not Ropes.heldBy(source) and not Ropes.hanging[source] then
        rope[other] = { type = 'held', heldBy = source }
        return true
    end
    return false
end

--- Down off any rope they hang from. `notThem`: they let go themselves, so their own game is not told
--- (it already knows, and a late echo would tear down a hang they have since taken again).
function Ropes.unhang(source, notThem)
    local hang = Ropes.hanging[source]
    if not hang then return false end
    Ropes.hanging[source] = nil
    if Ropes.all[hang.serverRopeId] then Ropes.changed('unhang', Ropes.all[hang.serverRopeId], source) end
    if notThem then
        for _, id in ipairs(GetPlayers()) do
            local target = tonumber(id)
            if target ~= source then TriggerClientEvent('whip_rope:unhung', target, source) end
        end
    else
        TriggerClientEvent('whip_rope:unhung', -1, source)
    end
    return true
end

--- Let go of whatever rope end they hold (it hangs loose where it is). Not a locked rope's: its resource lets go
--- its own way (a pump's nozzle drops), and whip_rope never moves it behind its back.
function Ropes.letGo(source)
    local rope, which = Ropes.heldBy(source, true)
    if not rope then return false end
    ---@cast which -nil -- it comes with the rope
    rope[which] = Ropes.loose(rope[which])   -- where their hand was
    Ropes.sendEnds(rope, which == 'origin', which == 'tail')
    return true
end

--- A rope gone, everywhere. Whoever hung off it is let down by their own game as the rope goes.
---
--- A resource's rope taken away by whip_rope itself (`why`: an admin's /clearropes) tells that resource:
--- whip_rope:ropeRemoved (id, resource, why), a server event, so it stops moving a rope that is not there. Its own
--- RemoveRope, or its stopping, says nothing (it knows).
function Ropes.remove(ropeId, why)
    local rope = Ropes.all[ropeId]
    if not rope then return false end
    for src, hang in pairs(Ropes.hanging) do
        if hang.serverRopeId == ropeId then Ropes.hanging[src] = nil end
    end
    Ropes.all[ropeId] = nil
    TriggerClientEvent('whip_rope:despawned', -1, ropeId)
    Keepers.soon()
    if why and rope.byResource then TriggerEvent('whip_rope:ropeRemoved', ropeId, rope.byResource, why) end
    Ropes.changed('removed', rope)
    return true
end

-- ============================================================================
-- ROPES OWED BACK (kept on disk, in the resource's KVP, so a restart does not lose them)
-- ============================================================================

local OWED_KVP = 'owed'

local function saveOwed()
    local out = {}
    for charId, n in pairs(Ropes.owed) do out[tostring(charId)] = n end   -- JSON keys are strings
    if next(out) then SetResourceKvp(OWED_KVP, json.encode(out)) else DeleteResourceKvp(OWED_KVP) end
end

do
    local raw = GetResourceKvpString(OWED_KVP)
    local ok, t = pcall(json.decode, raw or '')
    if ok and type(t) == 'table' then
        for k, n in pairs(t) do
            local charId, count = tonumber(k), tonumber(n)
            if charId and count and count > 0 then Ropes.owed[charId] = count end
        end
    end
end

--- A rope owed back to a character, given when they are next in (server/item.lua hands it over).
function Ropes.owe(charId, n)
    if not charId then return end
    Ropes.owed[charId] = (Ropes.owed[charId] or 0) + (n or 1)
    saveOwed()
end

--- Take a character's debt off the books (to give it), answering how many.
function Ropes.takeOwed(charId)
    local n = charId and Ropes.owed[charId]
    if not n then return 0 end
    Ropes.owed[charId] = nil
    saveOwed()
    return n
end

--- A player leaving (logout, disconnect): down off ropes, ends let go, ends tied to cars only their game had
--- loose, their ropes gone — and owed back to the character when Config.Item.GiveBackOnLogout says so. Safe
--- to run twice (both paths call it).
function Ropes.playerGone(source)
    Ropes.unhang(source)
    Ropes.letGo(source)
    for _, rope in pairs(Ropes.all) do
        local o, t = rope.origin.localTo == source, rope.tail.localTo == source
        if o then rope.origin = Ropes.loose(rope.origin) end   -- where the car was tied
        if t then rope.tail = Ropes.loose(rope.tail) end
        if o or t then Ropes.sendEnds(rope, o, t) end
    end
    local mine = {}
    for id, rope in pairs(Ropes.all) do
        -- (A resource's rope is that resource's, not the player's it was made for: it says when it goes, server/api.lua)
        if rope.owner == source and not rope.byResource then mine[#mine + 1] = id end
    end
    for _, id in ipairs(mine) do
        local rope = Ropes.all[id]
        if Config.Item.GiveBackOnLogout and rope.ownerCharId then Ropes.owe(rope.ownerCharId, 1) end
        Ropes.remove(id)
    end
end
