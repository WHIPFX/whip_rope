--[[
    whip_rope — WHAT THE SERVER SAYS, AND KEEPING EVERY GAME'S ROPE ALIKE

    The server keeps each rope's two ends and who hangs off it; every game near a rope simulates it
    itself from those. A rope is built on this game only while one of its ends is held, tied or put
    down somewhere this game has (in scope), and dropped when none is any more; a list from the
    server every few seconds catches what came into scope since.
]]

local DebugPrint = Rope.Util.DebugPrint

-- A rope put down or tied to a map prop this far away is not built here
local KEEP_RANGE = 300.0

-- ============================================================================
-- IS A ROPE ANYWHERE NEAR THIS GAME?
-- ============================================================================

local function netEntityHere(netId)
    netId = tonumber(netId)
    if not netId or netId <= 0 or not NetworkDoesNetworkIdExist(netId) then return false end
    local e = NetworkGetEntityFromNetworkId(netId)
    return e ~= nil and e ~= 0 and DoesEntityExist(e)
end

local function nearHere(p)
    if type(p) ~= 'table' and type(p) ~= 'vector3' then return false end
    if not p.x or not p.y or not p.z then return false end
    return #(GetEntityCoords(PlayerPedId()) - vector3(p.x + 0.0, p.y + 0.0, p.z + 0.0)) < KEEP_RANGE
end

-- Is this end (as the server sends it) held, tied, put down or let go somewhere this game has?
-- 'yes', 'no', or 'loose' (it is not anchored anywhere, and nobody knows where it lies)
local function endHere(e)
    local t = type(e) == 'table' and e.type or 'free'
    if t == 'free' then
        if e and e.at then return nearHere(e.at) and 'yes' or 'no' end   -- where it was let go
        return 'loose'
    end
    if t == 'held' then return Rope.PedOf(tonumber(e.heldBy)) and 'yes' or 'no' end
    if t == 'fixed' then return nearHere(e.pos) and 'yes' or 'no' end
    if t == 'vehicle' then
        -- A car only one game has (a scene's): on that game, wherever it has gone; on no other
        if (tonumber(e.netId) or 0) <= 0 then return tonumber(e.localTo) == Rope.MyServerId() and 'yes' or 'no' end
        return netEntityHere(e.netId) and 'yes' or 'no'
    end
    if t == 'object' then
        if tonumber(e.netId) and tonumber(e.netId) > 0 then return netEntityHere(e.netId) and 'yes' or 'no' end
        return nearHere(e.worldPos) and 'yes' or 'no'
    end
    return 'loose'
end

--- Should this game have the rope? Either end anchored here; or, with neither end anchored at all,
--- its owner here, or where it was made near.
local function ropeHere(origin, tail, owner, madeAt)
    local a, b = endHere(origin), endHere(tail)
    if a == 'yes' or b == 'yes' then return true end
    if a == 'loose' and b == 'loose' then
        return Rope.PedOf(tonumber(owner)) ~= nil or nearHere(madeAt)
    end
    return false
end

-- The same question of a rope this game has, from its own fields
local function localEnd(rope, which)
    local t = rope[which .. 'Type']
    if t == 'held' then return { type = 'held', heldBy = rope[which .. 'HeldBy'] } end
    if t == 'fixed' then return { type = 'fixed', pos = rope[which .. 'Position'] } end
    if t == 'vehicle' then
        return { type = 'vehicle', netId = rope[which .. 'NetId'] or 0, localTo = rope[which .. 'LocalTo'] }
    end
    if t == 'object' then
        return { type = 'object', netId = rope[which .. 'NetId'] or 0, worldPos = rope[which .. 'WorldPos'] }
    end
    -- Loose: where its end node lies here
    return { type = 'free', at = Rope.EndNode(rope, which).position }
end

local function keepRope(rope)
    if not rope or not rope.nodes or #rope.nodes == 0 then return false end
    -- Ours, one we hold, or one we hang off: always
    if rope.isLocallyOwned then return true end
    local hang = Rope.HangingPlayers[Rope.MyServerId()]
    if hang and hang.serverRopeId == rope.serverRopeId then return true end
    return ropeHere(localEnd(rope, 'origin'), localEnd(rope, 'tail'), rope.ownerServerId,
        rope.nodes[math.ceil(#rope.nodes / 2)].position)
end

-- ============================================================================
-- ASKING FOR EVERY ROPE
-- ============================================================================

local lastSyncRequest = 0
local SYNC_COOLDOWN = 3000

--- Ask the server for every rope. `restarted`: this game's whip_rope has just started over, so a hang
--- the server still has for us is gone (only then: asking mid-hang must not drop us off the rope).
function Rope.RequestRopeSync(reason, restarted)
    local now = GetGameTimer()
    if now - lastSyncRequest < SYNC_COOLDOWN and not restarted then return false end
    lastSyncRequest = now
    DebugPrint('asking the server for every rope:', reason)
    TriggerServerEvent('whip_rope:ready', restarted == true)
    return true
end

-- In the world: on our start (a restart mid-session), and whenever a character loads or spawns. On our start only with a
-- character already in the world: joining, the character loading asks, and asking before that is refused (no player
-- session).
CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(500) end
    Wait(2000)
    if Whip.core:IsPlayerLoaded() == true then Rope.RequestRopeSync('resource start', true) end
end)
AddEventHandler('whip_core:player:loaded', function() Rope.RequestRopeSync('character loaded') end)
AddEventHandler('whip_core:player:spawned', function() Rope.RequestRopeSync('spawned') end)

-- ============================================================================
-- ROPES COMING AND GOING
-- ============================================================================

RegisterNetEvent('whip_rope:spawned', function(data)
    if type(data) ~= 'table' or not tonumber(data.serverRopeId) then return end
    if Rope.System.ropes[data.serverRopeId] then return end
    -- Ours always (we may not have our own ped's hand yet); anyone else's when it is near
    if data.owner ~= Rope.MyServerId() and not ropeHere(data.origin, data.tail, data.owner, data.originPosition) then
        return
    end
    Rope.AddRopeFromServer(data)
end)

RegisterNetEvent('whip_rope:despawned', function(serverRopeId)
    Rope.DeleteRope(serverRopeId)
end)

-- An end (or both) changed: everyone is told, the game that did it too (the same change again)
RegisterNetEvent('whip_rope:ends', function(serverRopeId, ends)
    if type(ends) ~= 'table' then return end
    local rope = Rope.System.ropes[serverRopeId]
    if not rope then
        -- Tied to something here now: ask for it rather than wait for the next list
        if (ends.origin and endHere(ends.origin) == 'yes') or (ends.tail and endHere(ends.tail) == 'yes') then
            Rope.RequestRopeSync('an end came here')
        end
        return
    end
    if ends.origin then Rope.ApplyEnd(rope, 'origin', ends.origin) end
    if ends.tail then Rope.ApplyEnd(rope, 'tail', ends.tail) end
end)

-- The server refused something this game already did: the rope as it really is. (whip has shown the
-- reason, if any.)
RegisterNetEvent('whip_rope:correction', function(data)
    if type(data) ~= 'table' then return end
    local rope = Rope.System.ropes[data.serverRopeId]
    if not rope then return end
    Rope.ApplyEnd(rope, 'origin', data.origin)
    Rope.ApplyEnd(rope, 'tail', data.tail)
    DebugPrint('rope', data.serverRopeId, 'put back as the server has it')
end)

-- A resource's rope's rules changed (server/api.lua SetRopeRules): who may pick it up and hang off it, its watch
RegisterNetEvent('whip_rope:opts', function(serverRopeId, opts)
    local rope = Rope.System.ropes[serverRopeId]
    if rope and type(opts) == 'table' then rope.opts = opts end
end)

RegisterNetEvent('whip_rope:coilEnded', function()
    Rope.Coiling = false
end)

-- ============================================================================
-- HANGING
-- ============================================================================

RegisterNetEvent('whip_rope:hung', function(serverId, serverRopeId, nodeIndex)
    serverId, nodeIndex = tonumber(serverId), tonumber(nodeIndex)
    if not serverId or not nodeIndex then return end
    -- Our own hang was set when we did it
    if serverId == Rope.MyServerId() then return end
    local rope = Rope.System.ropes[serverRopeId]
    if not rope or not rope.nodes[nodeIndex] then return end

    Rope.ForgetHanging(serverId)   -- a hang somewhere else before: that one ends
    Rope.HangingPlayers[serverId] = { serverRopeId = serverRopeId, nodeIndex = nodeIndex }
    Rope.SetHangingNodeMass(rope.nodes[nodeIndex])
    Rope.EnsureClone(serverId)
end)

-- Someone let go (for us: the server ended our hang — a refusal, a death)
RegisterNetEvent('whip_rope:unhung', function(serverId)
    Rope.ForgetHanging(tonumber(serverId))
end)

-- We were shot while hanging (every other game is told whip_rope:unhung): off the rope, limp
RegisterNetEvent('whip_rope:shotOff', function(x, y, z)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y or not z then return end
    Rope.KnockedOffRope(x, y, z)
end)

-- ============================================================================
-- KEEPING EVERY GAME'S ROPE ALIKE
-- ============================================================================
-- The game that put a rope out sends where a few nodes that matter are — those someone hangs from, a
-- loose end swinging fast — and every other game eases its own toward them.

CreateThread(function()
    while true do
        Wait(Rope.AnyAwake() and (Config.Sync.DriftRateMs or 250) or Rope.Const.IDLE_MS)   -- only awake ropes send
        if Config.Sync.DriftEnabled and next(Rope.System.ropes) then
            -- One batch for all our ropes, so the server's rate limit does not depend on how many we have out
            local batch = {}
            for _, rope in pairs(Rope.System.ropes) do
                if rope.isLocallyOwned and rope.serverRopeId and rope.simulated ~= false then
                    local nodes = rope.nodes
                    local out = {}
                    for _, hangData in pairs(Rope.HangingPlayers) do
                        if hangData.serverRopeId == rope.serverRopeId and #out < 8 then
                            local p = nodes[hangData.nodeIndex] and nodes[hangData.nodeIndex].position
                            if p then out[#out + 1] = { i = hangData.nodeIndex, x = p.x, y = p.y, z = p.z } end
                        end
                    end
                    for _, which in ipairs({ 'origin', 'tail' }) do
                        if rope[which .. 'Type'] == 'free' and #out < 8 then
                            local i = which == 'origin' and 1 or #nodes
                            local node = nodes[i]
                            if #(node.position - node.previousPosition) * 60.0 > 1.0 then
                                out[#out + 1] = { i = i, x = node.position.x, y = node.position.y, z = node.position.z }
                            end
                        end
                    end
                    if #out > 0 and #batch < 20 then
                        batch[#batch + 1] = { r = rope.serverRopeId, n = out }
                    end
                end
            end
            if #batch > 0 then TriggerServerEvent('whip_rope:drift', batch) end
        end
    end
end)

RegisterNetEvent('whip_rope:drift', function(serverRopeId, owner, nodes)
    if not Config.Sync.DriftEnabled or owner == Rope.MyServerId() or type(nodes) ~= 'table' then return end
    local rope = Rope.System.ropes[serverRopeId]
    if not rope or rope.simulated == false then return end
    Rope.WakeRope(rope)   -- moving on the game that sent it: stepped here again too (a rope at rest: client/main.lua)
    local lerp = Config.Sync.DriftLerp or 0.25
    for _, entry in ipairs(nodes) do
        local node = type(entry) == 'table' and rope.nodes[entry.i]
        if node and not node.pinned and entry.x and entry.y and entry.z then
            local target = vector3(entry.x + 0.0, entry.y + 0.0, entry.z + 0.0)
            local delta = target - node.position
            if #delta > 5.0 then
                node.position, node.previousPosition = target, target
            else
                -- Both moved together, so the nudge adds no speed
                local shift = delta * lerp
                node.position = node.position + shift
                node.previousPosition = node.previousPosition + shift
            end
        end
    end
end)

-- ============================================================================
-- THE LIST: WHAT CAME INTO SCOPE, WHAT WENT
-- ============================================================================
-- { maxId, ropes = { { id, owner, originPosition, origin, tail }, ... } } every few seconds.

RegisterNetEvent('whip_rope:list', function(list)
    if type(list) ~= 'table' or type(list.ropes) ~= 'table' then return end
    local known = {}
    local missing = false
    for _, info in ipairs(list.ropes) do
        known[info.id] = true
        if not Rope.System.ropes[info.id] and ropeHere(info.origin, info.tail, info.owner, info.originPosition) then
            missing = true
        end
    end

    local maxId = tonumber(list.maxId) or 0
    local gone = {}
    for ropeKey, rope in pairs(Rope.System.ropes) do
        -- Gone from the server (a rope made after the list was may not be on it yet), or nowhere near
        if (ropeKey <= maxId and not known[ropeKey]) or not keepRope(rope) then
            gone[#gone + 1] = ropeKey
        end
    end
    for _, ropeKey in ipairs(gone) do
        DebugPrint('rope', ropeKey, 'is gone, or nowhere near: dropped here')
        Rope.DeleteRope(ropeKey)
    end

    if missing then Rope.RequestRopeSync('a rope came into scope') end
end)
