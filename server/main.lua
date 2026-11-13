--[[
    whip_rope — WHAT PLAYERS ASK, CHECKED

    Every request from a player's game is a whip SecureEvent (typed, rate limited, refused for a dead
    player unless it says otherwise). Their game has already done what it asks, so a refusal sends it
    the rope as it really is (Ropes.correct) as well as the reason, which whip shows them.
]]

local WHICH = { 'origin', 'tail' }

local function other(which) return which == 'origin' and 'tail' or 'origin' end

-- Refused: their game puts the rope back as it is, and whip shows `why`
local function refuse(source, ropeId, why)
    Ropes.correct(source, ropeId)
    return false, why
end

-- A locked rope (a resource's: server/api.lua, `locked`, as a pump's hose) is that resource's to move: nobody grabs,
-- ties, puts down or coils it
local function mayHandle(source, rope)
    if Ropes.locked(rope) then return false end
    return Config.Rules.AnyoneCanHandle or rope.owner == source
end

local function holds(source, rope, which)
    if Ropes.locked(rope) then return false end
    local e = rope[which]
    return e.type == 'held' and e.heldBy == source
end

local function tieReach() return (Config.Rules.Reach or 3.0) + 7.0 end   -- the client's reach, plus ping

-- ============================================================================
-- THE ENDS
-- ============================================================================

-- Pick up a loose or put-down end, or untie a tied one
local function onTake(source, _, ropeId, which)
    local rope = Ropes.all[ropeId]
    if not rope then return refuse(source, ropeId, 'That rope is gone') end
    if rope[which].type == 'held' then return refuse(source, ropeId, 'Someone is holding that end') end
    if not mayHandle(source, rope) then return refuse(source, ropeId, "That rope isn't yours") end
    if rope.opts and rope.opts.noTake then return refuse(source, ropeId, "That rope can't be picked up") end
    if Ropes.heldBy(source) then return refuse(source, ropeId, 'Your hands are full') end
    if Ropes.hanging[source] then return refuse(source, ropeId, 'Let go of the rope first') end
    -- An end on a car only one game has: only that player has the car, and the server can't see where it went,
    -- so they are believed
    local e = rope[which]
    local localCar = e.type == 'vehicle' and (e.netId or 0) == 0
    if localCar and e.localTo ~= source then
        return refuse(source, ropeId, 'Only the player who tied it can untie that')
    end
    -- From the end itself (a tied end: its tie point), with room for ping. A loose end may have been dragged off from
    -- where it was let go: from the rope's ends (Ropes.near).
    local at = not localCar and e.type ~= 'free' and Ropes.endPos(e) or nil
    local me = Ropes.pedPos(source)
    if not me then return refuse(source, ropeId) end
    if at and #(me - at) > (Config.Grab.GrabRadius or 1.5) + 7.0 then
        return refuse(source, ropeId, 'Too far away')
    end
    if not at and not localCar and not Ropes.near(source, rope) then return refuse(source, ropeId, 'Too far away') end

    rope[which] = { type = 'held', heldBy = source }
    Ropes.sendEnds(rope, which == 'origin', which == 'tail', source)
end

-- Put the held end down at a spot on the ground
local function onPlace(source, _, ropeId, which, x, y, z)
    local rope = Ropes.all[ropeId]
    if not rope then return refuse(source, ropeId, 'That rope is gone') end
    if not holds(source, rope, which) then return refuse(source, ropeId) end
    local me = Ropes.pedPos(source)
    if not me or #(me - vector3(x, y, z)) > 10.0 then return refuse(source, ropeId, 'Too far away') end

    rope[which] = { type = 'fixed', pos = { x = x, y = y, z = z } }
    Ropes.takeOtherIfLoose(rope, which, source)
    Ropes.sendEnds(rope, true, true, source)
end

-- Tie the held end to the map itself, at a spot on a wall, a rock or the ground the player looks at (whip's aimBox
-- 'world'): it stays there, like a post. Config.Rules.TieToMap; within the tying reach of the spot itself.
local function onTieMap(source, _, ropeId, which, x, y, z)
    local rope = Ropes.all[ropeId]
    if not rope then return refuse(source, ropeId, 'That rope is gone') end
    if not holds(source, rope, which) then return refuse(source, ropeId) end
    if Config.Rules.TieToMap == false then return refuse(source, ropeId, "Ropes can't be tied to the map here") end
    local me = Ropes.pedPos(source)
    if not me or #(me - vector3(x, y, z)) > tieReach() then return refuse(source, ropeId, 'Too far away') end

    rope[which] = { type = 'fixed', pos = { x = x, y = y, z = z }, tied = true }
    Ropes.takeOtherIfLoose(rope, which, source)
    Ropes.sendEnds(rope, true, true, source)
end

-- Let the held end go: it hangs loose where it is
local function onRelease(source, _, ropeId, which)
    local rope = Ropes.all[ropeId]
    if not rope then return refuse(source, ropeId, 'That rope is gone') end
    if not holds(source, rope, which) then return refuse(source, ropeId) end
    rope[which] = Ropes.loose(rope[which])   -- where their hand was
    Ropes.sendEnds(rope, which == 'origin', which == 'tail', source)
end

-- Tie the held end to a car, at a point on it
local function onTieVehicle(source, _, ropeId, which, netId, ox, oy, oz)
    local rope = Ropes.all[ropeId]
    if not rope then return refuse(source, ropeId, 'That rope is gone') end
    if not holds(source, rope, which) then return refuse(source, ropeId) end
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then
        return refuse(source, ropeId, "That car isn't there")
    end
    local me = Ropes.pedPos(source)
    if not me or #(me - GetEntityCoords(vehicle)) > tieReach() + 4.0 then
        return refuse(source, ropeId, 'Too far away')
    end
    if Config.Rules.NeedKeysToTie and not exports.whip_core:HasVehicleKey(source, { netId = netId }) then
        return refuse(source, ropeId, 'You need the keys to this car')
    end

    -- Which whip car it is, when it is one: a Director Test's car gives the rope back as it goes (server/item.lua)
    local car = Whip.call('GetVehicleBy', 'netId', netId)
    rope[which] = { type = 'vehicle', netId = netId, offset = { x = ox, y = oy, z = oz },
                    vehicleId = type(car) == 'table' and tonumber(car.vehicleId) or nil }
    Ropes.takeOtherIfLoose(rope, which, source)
    Ropes.sendEnds(rope, true, true, source)
end

-- Tie the held end to a car only this player's game has (a whip_scenes scene's: it is not networked). The
-- server can't see it: kept within reach of the player, its tie point on it. Their game finds it again by model
-- where it stood; no other game has it. No keys: whip keeps none for a car it doesn't know.
local function onTieLocalVehicle(source, _, ropeId, which, model, wx, wy, wz, ox, oy, oz, px, py, pz)
    local rope = Ropes.all[ropeId]
    if not rope then return refuse(source, ropeId, 'That rope is gone') end
    if not holds(source, rope, which) then return refuse(source, ropeId) end
    local me = Ropes.pedPos(source)
    if not me then return refuse(source, ropeId) end
    local worldPos, point = vector3(wx, wy, wz), vector3(px, py, pz)
    if #(me - worldPos) > tieReach() + 4.0 then return refuse(source, ropeId, 'Too far away') end
    if #(point - worldPos) > 15.0 then return refuse(source, ropeId) end

    rope[which] = {
        type = 'vehicle', netId = 0, model = model, localTo = source,
        worldPos = Ropes.wire(worldPos), offset = { x = ox, y = oy, z = oz }, point = Ropes.wire(point),
    }
    Ropes.takeOtherIfLoose(rope, which, source)
    Ropes.sendEnds(rope, true, true, source)
end

-- Tie the held end to a prop: a networked one (netId) or one of the map's (its model, where it stands)
local function onTieObject(source, _, ropeId, which, netId, model, wx, wy, wz, ox, oy, oz, px, py, pz)
    local rope = Ropes.all[ropeId]
    if not rope then return refuse(source, ropeId, 'That rope is gone') end
    if not holds(source, rope, which) then return refuse(source, ropeId) end
    local me = Ropes.pedPos(source)
    if not me then return refuse(source, ropeId) end

    local worldPos = vector3(wx, wy, wz)
    if netId > 0 then
        -- Networked: the server knows where it is and what it is
        local object = NetworkGetEntityFromNetworkId(netId)
        if not object or object == 0 or not DoesEntityExist(object) or GetEntityType(object) ~= 3 then
            return refuse(source, ropeId, "That isn't there")
        end
        worldPos = GetEntityCoords(object)
        model = GetEntityModel(object)
    end
    -- A map prop the server cannot see: kept within reach of the player, its tie point on it
    if #(me - worldPos) > tieReach() + 4.0 then return refuse(source, ropeId, 'Too far away') end
    local point = vector3(px, py, pz)
    if #(point - worldPos) > 15.0 then return refuse(source, ropeId) end

    rope[which] = {
        type = 'object', netId = netId, model = model,
        worldPos = Ropes.wire(worldPos), offset = { x = ox, y = oy, z = oz }, point = Ropes.wire(point),
    }
    Ropes.takeOtherIfLoose(rope, which, source)
    Ropes.sendEnds(rope, true, true, source)
end

-- The rope's owner saw the map prop an end was tied to break or go, or the player whose game alone had a car an
-- end was tied to saw it go (a scene removed): their game let it go already
local function onLost(source, _, ropeId, which)
    local rope = Ropes.all[ropeId]
    if not rope then return refuse(source, ropeId) end
    local e = rope[which]
    local mapProp = e.type == 'object' and (e.netId or 0) == 0 and rope.owner == source
    local localCar = e.type == 'vehicle' and (e.netId or 0) == 0 and e.localTo == source
    if not mapProp and not localCar then return refuse(source, ropeId) end
    rope[which] = Ropes.loose(e)   -- where it was tied
    Ropes.sendEnds(rope, which == 'origin', which == 'tail', source)
end

-- ============================================================================
-- HANGING
-- ============================================================================

local function refuseHang(source, why)
    TriggerClientEvent('whip_rope:unhung', source, source)
    return false, why
end

local function onHang(source, _, ropeId, nodeIndex)
    if not Config.PlayerHang.Enabled then return refuseHang(source, 'Hanging on ropes is off') end
    local rope = Ropes.all[ropeId]
    if not rope then return refuseHang(source, 'That rope is gone') end
    if Ropes.locked(rope) then return refuseHang(source) end
    if rope.opts and rope.opts.noHang then return refuseHang(source, "That rope can't be hung from") end
    if nodeIndex < 2 or nodeIndex > rope.nodes - 1 then return refuseHang(source) end
    if Ropes.heldBy(source) then return refuseHang(source, 'Your hands are full') end
    if not Ropes.near(source, rope) then return refuseHang(source, 'Too far away') end
    local ped = GetPlayerPed(source)
    if ped ~= 0 and GetVehiclePedIsIn(ped, false) ~= 0 then return refuseHang(source, 'Get out of the vehicle first') end

    -- (One hang at a time: a hang somewhere else before ends first, so whoever waits on it hears that)
    if Ropes.hanging[source] then Ropes.unhang(source, true) end
    Ropes.hanging[source] = { serverRopeId = ropeId, nodeIndex = nodeIndex }
    TriggerClientEvent('whip_rope:hung', -1, source, ropeId, nodeIndex)
    Ropes.changed('hang', rope, source)
end

local function onUnhang(source)
    Ropes.unhang(source, true)
end

-- The shooter's game saw its shot go through a hanging player's stand-in (client/interaction.lua).
-- Believed only if the target really hangs and the shooter is someone else, armed and within range;
-- then the target falls off on every game. A claim that fails is dropped silently.
local SHOT_RANGE = 300.0 + 20.0   -- the client's, plus ping

local function onShot(source, _, target)
    if not Config.PlayerHang.ShotKnocksOff then return false end
    if target == source or not Ropes.hanging[target] then return false end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    -- 0 when the server does not know yet: allowed, the range still holds
    if GetSelectedPedWeapon(ped) == `WEAPON_UNARMED` then return false end
    local me, them = Ropes.pedPos(source), Ropes.pedPos(target)
    if not me or not them or #(me - them) > SHOT_RANGE then return false end

    Ropes.debug('player', target, 'shot off the rope by', source)
    TriggerClientEvent('whip_rope:shotOff', target, me.x, me.y, me.z)
    Ropes.unhang(target, true)
end

-- ============================================================================
-- COILING IT UP (a bar the server times; the item to whoever coiled it)
-- ============================================================================

local function coilEnded(source) TriggerClientEvent('whip_rope:coilEnded', source) end

local function onCoil(source, player, ropeId)
    local rope = Ropes.all[ropeId]
    if not rope then coilEnded(source) return false, 'That rope is gone' end
    local held = Ropes.heldBy(source, true)
    if held ~= rope then coilEnded(source) return false, 'Hold one of its ends first' end
    -- A resource's rope is never an item, locked or not: nobody spent one on it
    if rope.byResource or not mayHandle(source, rope) then coilEnded(source) return false, "That rope isn't yours to coil up" end
    if rope.coiling then coilEnded(source) return false, 'Someone is already coiling it up' end

    rope.coiling = source
    local done = Whip.call('Progress', source, {
        label = 'Coiling up the rope',
        duration = Config.Item.CoilDuration or 3000,
        icon = 'pickup',
        item = Config.Item.Name,   -- the rope's picture in the bar's disc (the glyph if it has none)
        canCancel = true,
    })
    if Ropes.all[ropeId] == rope then rope.coiling = nil end
    coilEnded(source)
    if done ~= true then return false end   -- cancelled, or gone: nothing to say

    -- The bar ran: is it still there, still in their hands?
    if Ropes.all[ropeId] ~= rope or Ropes.heldBy(source, true) ~= rope then return false end
    Ropes.remove(ropeId)
    -- Pockets that would not take it (whip saying no): owed instead, never lost
    if not Ropes.giveItem(source, 1, 'rope coiled up') then
        Ropes.owe(player and player.charId, 1)
    end
end

-- ============================================================================
-- KEEPING EVERY GAME'S ROPE ALIKE
-- ============================================================================

-- The players near enough to a rope to simulate it (the drift is theirs only)
local function playersNear(rope)
    local points = {}
    for _, which in ipairs(WHICH) do
        local p = Ropes.endPos(rope[which])
        if p then points[#points + 1] = p end
    end
    local ownerAt = Ropes.pedPos(rope.owner)
    if ownerAt then points[#points + 1] = ownerAt end
    local range = (Config.Rope.SimulateRange or 120.0) + Ropes.length(rope) + 20.0
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local at = src and Ropes.pedPos(src)
        if at then
            for _, p in ipairs(points) do
                if #(at - p) <= range then out[#out + 1] = src break end
            end
        end
    end
    return out
end

-- How far a rope's node can be from one of its ends (m): its length stretched to the backstop and past it, and room for
-- ping. A node said to be further is not believed: every other game moves its own node there, and a player hanging
-- from that node with it.
local function driftReach(rope) return Ropes.length(rope) * 2.0 + 5.0 end

--- The nodes of `nodes` (the owner's word) that can be where it says: a node of this rope, within driftReach of an end
--- the server knows (held, put down, tied, or let go), or of the owner when it knows none.
local function believable(rope, nodes)
    local points = {}
    for _, which in ipairs(WHICH) do
        local p = Ropes.endPos(rope[which])
        if p then points[#points + 1] = p end
    end
    if not points[1] then points[1] = Ropes.pedPos(rope.owner) end
    if not points[1] then return {} end
    local reach, out = driftReach(rope), {}
    for _, n in ipairs(nodes) do
        if n.i <= rope.nodes then
            local at = vector3(n.x, n.y, n.z)
            for _, p in ipairs(points) do
                if #(at - p) <= reach then out[#out + 1] = n break end
            end
        end
    end
    return out
end

-- One batch a tick from a rope's owner: { { r = ropeId, n = { { i, x, y, z }, ... } }, ... }. Each rope
-- once (its game sends it once): a batch naming one rope twenty times is not twenty sends to everyone near.
local function onDrift(source, _, batch)
    local seen = {}
    for _, entry in ipairs(batch) do
        local rope = not seen[entry.r] and Ropes.all[entry.r]
        seen[entry.r] = true
        local nodes = rope and rope.owner == source and believable(rope, entry.n) or {}
        if nodes[1] then
            for _, target in ipairs(playersNear(rope)) do
                if target ~= source then
                    TriggerClientEvent('whip_rope:drift', target, entry.r, source, nodes)
                end
            end
        end
    end
end

-- A game asks for every rope: as it starts, as a character loads, or when one came near it.
-- `restarted`: its game has just started over (whip_rope restarted there), so any hang it had is gone.
local function onReady(source, _, restarted)
    if restarted then
        Ropes.unhang(source)
        Keepers.resend(source)   -- what it kept went with its old start
    end
    for _, rope in pairs(Ropes.all) do
        TriggerClientEvent('whip_rope:spawned', source, Ropes.payload(rope))
    end
    for hangingSource, hang in pairs(Ropes.hanging) do
        TriggerClientEvent('whip_rope:hung', source, hangingSource, hang.serverRopeId, hang.nodeIndex)
    end
end

-- ============================================================================
-- REGISTERED WITH WHIP
-- ============================================================================

Whip.register(function()
    local SE = function(name, schema, fn) exports.whip_core:SecureEvent('whip_rope:' .. name, schema, fn) end
    local ID = { 'ropeId', 'id', 1, 2147483647 }
    local END = { 'which', 'enum', WHICH }
    local function coord(name) return { name, 'number', -20000.0, 20000.0 } end
    local function off(name) return { name, 'number', -20.0, 20.0 } end
    -- A refusal before the handler (rate, a bad value): their game puts the rope back
    local function correctOnReject(src, _, raw)
        Ropes.correct(src, tonumber(type(raw) == 'table' and raw[1]))
    end
    -- Picking up and putting down come in quick runs; a refusal is corrected, never stuck
    local endSchema = function(params)
        return { rateLimit = 150, burst = 6, onReject = correctOnReject, params = params }
    end

    SE('take', endSchema({ ID, END }), onTake)
    SE('place', endSchema({ ID, END, coord('x'), coord('y'), coord('z') }), onPlace)
    SE('tieMap', endSchema({ ID, END, coord('x'), coord('y'), coord('z') }), onTieMap)
    SE('release', endSchema({ ID, END }), onRelease)
    SE('tieVehicle', endSchema({ ID, END, { 'netId', 'id', 1, 2147483647 }, off('ox'), off('oy'), off('oz') }), onTieVehicle)
    SE('tieLocalVehicle', endSchema({ ID, END, { 'model', 'number', -2147483648, 4294967295 },
        coord('wx'), coord('wy'), coord('wz'), off('ox'), off('oy'), off('oz'),
        coord('px'), coord('py'), coord('pz') }), onTieLocalVehicle)
    SE('tieObject', endSchema({ ID, END, { 'netId', 'id', 0, 2147483647 },   -- 0: a map prop
        { 'model', 'number', -2147483648, 4294967295 },
        coord('wx'), coord('wy'), coord('wz'), off('ox'), off('oy'), off('oz'),
        coord('px'), coord('py'), coord('pz') }), onTieObject)
    -- An explosion can take several tied props at once
    SE('lost', { rateLimit = 250, burst = 10, onReject = correctOnReject, params = { ID, END } }, onLost)

    SE('hang', {
        rateLimit = 500, burst = 3,
        onReject = function(src) TriggerClientEvent('whip_rope:unhung', src, src) end,
        params = { ID, { 'nodeIndex', 'id', 1, 4096 } },
    }, onHang)
    -- Letting go must never be refused: down, dead or not, however often
    SE('unhang', { rateLimit = false, whileDead = true }, onUnhang)
    -- At most one a second for each player shot at (the client's), a few people hanging at once
    SE('shot', { rateLimit = 200, burst = 5, params = { { 'target', 'id', 1, 2147483647 } } }, onShot)

    SE('coil', {
        rateLimit = 1000, burst = 2,
        onReject = function(src) TriggerClientEvent('whip_rope:coilEnded', src) end,
        params = { ID },
    }, onCoil)

    -- One batch every DriftRateMs (250 by default), however many ropes the owner has out
    SE('drift', {
        rateLimit = 100, burst = 4, sheet = 'light',
        params = { { 'batch', 'list', {
            { 'r', 'id', 1, 2147483647 },
            { 'n', 'list', { { 'i', 'id', 1, 4096 }, coord('x'), coord('y'), coord('z') }, 8 },
        }, 20 } },
    }, onDrift)

    -- A rope two games move: each game's batch every 250 ms, passed on to the other (server/keep.lua)
    SE('span', {
        rateLimit = 100, burst = 4, sheet = 'light',
        params = { { 'batch', 'list', {
            { 'r', 'id', 1, 2147483647 },
            { 'x', 'number', -1000.0, 1000.0 }, { 'y', 'number', -1000.0, 1000.0 }, { 'z', 'number', -1000.0, 1000.0 },
        }, 20 } },
    }, Keepers.onSpan)

    SE('ready', { rateLimit = 2000, burst = 2, whileDead = true, params = { { 'restarted', 'bool', false } } }, onReady)
end)

-- ============================================================================
-- THINGS NOBODY ASKED FOR
-- ============================================================================

-- A car or networked prop an end was tied to stopped existing (despawned, put in a garage, deleted):
-- that end hangs loose, where it was last seen (rope.seen, the server's own: never sent)
CreateThread(function()
    while true do
        Wait(2000)
        for _, rope in pairs(Ropes.all) do
            local changed = { origin = false, tail = false }
            for _, which in ipairs(WHICH) do
                local e = rope[which]
                if (e.type == 'vehicle' or e.type == 'object') and (e.netId or 0) > 0 then
                    local entity = NetworkGetEntityFromNetworkId(e.netId)
                    local seen = rope.seen and rope.seen[which]
                    if not entity or entity == 0 or not DoesEntityExist(entity) then
                        rope[which] = Ropes.loose(e, seen and seen.netId == e.netId and seen.at or nil)
                        changed[which] = true
                    else
                        rope.seen = rope.seen or {}
                        rope.seen[which] = { netId = e.netId, at = Ropes.endPos(e) }
                    end
                end
            end
            if changed.origin or changed.tail then
                Ropes.debug('rope', rope.id, 'came loose: what it was tied to is gone')
                Ropes.sendEnds(rope, changed.origin, changed.tail)
            end
        end
    end
end)

-- Every few seconds, every game is told which ropes there are and where their ends are: it builds
-- the ones that came near it and drops the ones that are gone. Once more after the last one goes.
CreateThread(function()
    local sentEmpty = true
    while true do
        Wait(5000)
        if next(Ropes.all) or not sentEmpty then
            local list = {}
            for id, rope in pairs(Ropes.all) do
                list[#list + 1] = { id = id, owner = rope.owner, originPosition = rope.originPosition,
                                    origin = rope.origin, tail = rope.tail }
            end
            TriggerClientEvent('whip_rope:list', -1, { maxId = Ropes.nextId - 1, ropes = list })
            sentEmpty = #list == 0
        end
    end
end)

-- Dying lets go of the rope, both ways
AddEventHandler('whip_core:player:died', function(e)
    local source = type(e) == 'table' and e.source
    if not source then return end
    Ropes.unhang(source)
    Ropes.letGo(source)
end)

-- Leaving (logout or disconnect: both fire this, and playerDropped too — playerGone is safe twice)
AddEventHandler('whip_core:player:logout', function(e)
    local source = type(e) == 'table' and e.source
    if source then Ropes.playerGone(source) end
end)
AddEventHandler('playerDropped', function()
    local src = source
    Ropes.playerGone(src)
end)
-- (whip_core stopping needs nothing here: it stops whip_rope first, its dependency, and this resource's own stop
-- handler owes back what was out.)

-- ============================================================================
-- ADMIN COMMANDS: the console, and whip.devtools with developer mode on (whip_core decides: Whip.command's dev gate)
-- ============================================================================

Whip.command('ropes', { dev = true, whileDead = true }, function()
    local n = 0
    print('=== whip_rope: ropes out ===')
    for id, rope in pairs(Ropes.all) do
        local function say(e)
            if e.type == 'held' then return 'held by #' .. tostring(e.heldBy) end
            if e.type == 'vehicle' or e.type == 'object' then return ('%s (net %s)'):format(e.type, tostring(e.netId)) end
            return e.type
        end
        print(('  #%d  owner %s (%s)  origin: %s  tail: %s  %ds old'):format(id,
            GetPlayerName(rope.owner) or '?', tostring(rope.owner), say(rope.origin), say(rope.tail),
            os.time() - rope.createdAt))
        n = n + 1
    end
    print(('%d rope(s); %d player(s) hanging'):format(n, (function()
        local h = 0
        for _ in pairs(Ropes.hanging) do h = h + 1 end
        return h
    end)()))
end)

-- Every rope taken in; each owner gets theirs back (now, or at their next login). A resource's rope (a pump's hose)
-- was never an item: it goes, and its resource is told (whip_rope:ropeRemoved)
Whip.command('clearropes', { dev = true, whileDead = true }, function()
    local ids = {}
    for id in pairs(Ropes.all) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do
        local rope = Ropes.all[id]
        local charId = not rope.byResource and Whip.call('GetCharId', rope.owner)
        if rope.byResource then
            Ropes.remove(id, 'cleared by an admin')
        elseif charId and charId == rope.ownerCharId then
            Ropes.remove(id)
            if not Ropes.giveItem(rope.owner, 1, 'ropes cleared by an admin') then
                Ropes.owe(rope.ownerCharId, 1)
            end
        else
            Ropes.owe(rope.ownerCharId, 1)
            Ropes.remove(id)
        end
    end
    print(('[whip_rope] cleared %d rope(s)'):format(#ids))
end)
