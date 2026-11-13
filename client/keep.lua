--[[
    whip_rope — THE PULLER MOVES WHAT IT PULLS (server/keep.lua names who)

    Every car and prop is moved by one game: its network owner (client/physics.lua's weMove). A prop dragged by a
    car whose driver's game is not its owner is moved on another game, from a late picture of the car, while the
    driver's own game has it as a solid it cannot move: a towed thing could throw the car it hangs off. So the
    server names a KEEPER for what each rope pulls, and on the keeper's game this file takes control of it, stops
    GTA handing it on (SetNetworkIdCanMigrate), asks again if it is lost anyway, and lets it go when told.

    Until it is ours (a hand-over is a round trip; a server with sv_filterRequestControl set may refuse it for
    good), our car (or ped) does not touch it, so the late copy cannot throw us. A kept car someone sits in, or
    another player stands right by on foot, is let go: they must be able to get in and take it.
]]

local TICK_MS      = 250   -- how often control is looked at
local ASK_EVERY_MS = 500   -- control asked for again this often while it is not ours
local GETTING_IN_M = 4.0   -- another player on foot this near a kept car may be getting in: it is let go

local keeping = {}         -- [netId] = { askedAt }
local running = false

local function entityOf(netId)
    if not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if not e or e == 0 or not DoesEntityExist(e) then return nil end
    return e
end

--- Whether GTA may hand it on (unlocked) or not, said again at every look while it is ours. Only the game in control
--- can say, and the lock is on the THING: it goes with it to whoever gets it, comes back with it, and no native reads
--- it. Said only on a change, a game could think it unlocked while the lock was still on, and a player at the wheel
--- would never get control.
local function setLock(netId, entity, on)
    if entity and NetworkHasControlOfEntity(entity) then SetNetworkIdCanMigrate(netId, not on) end
end

--- A kept car someone else may be taking: somebody in its driver's seat, or another player on foot by it.
local function beingTaken(entity)
    if GetEntityType(entity) ~= 2 then return false end
    if GetPedInVehicleSeat(entity, -1) ~= 0 then return true end
    local at, me = GetEntityCoords(entity), PlayerId()
    for _, player in ipairs(GetActivePlayers()) do
        if player ~= me then
            local ped = GetPlayerPed(player)
            if ped ~= 0 and not IsPedInAnyVehicle(ped, false) and #(GetEntityCoords(ped) - at) < GETTING_IN_M then
                return true
            end
        end
    end
    return false
end

--- What of ours a kept thing must not touch until it is ours: the car we are in, or ourselves.
local function ourBody()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    return veh ~= 0 and veh or ped
end

--- One thread while anything is kept: control looked at every TICK_MS, and every frame while something is not
--- ours yet (the no-touching lasts a frame at a time).
local function run()
    if running then return end
    running = true
    CreateThread(function()
        local nextLook, notYet = 0, {}
        while next(keeping) do
            local now = GetGameTimer()
            if now >= nextLook then
                nextLook = now + TICK_MS
                for i = #notYet, 1, -1 do notYet[i] = nil end
                for netId, k in pairs(keeping) do
                    local e = entityOf(netId)
                    if e then
                        if beingTaken(e) then
                            setLock(netId, e, false)
                        elseif NetworkHasControlOfEntity(e) then
                            setLock(netId, e, true)
                        else
                            if now - k.askedAt >= ASK_EVERY_MS then
                                k.askedAt = now
                                NetworkRequestControlOfEntity(e)
                            end
                            notYet[#notYet + 1] = e
                        end
                    end
                end
            end
            if #notYet > 0 then
                local mine = ourBody()
                for i = 1, #notYet do
                    if DoesEntityExist(notYet[i]) then SetEntityNoCollisionEntity(notYet[i], mine, true) end
                end
                Wait(0)
            else
                Wait(math.max(0, nextLook - GetGameTimer()))
            end
        end
        running = false
    end)
end

local function release(netId)
    if not keeping[netId] then return end
    keeping[netId] = nil
    setLock(netId, entityOf(netId), false)
end

-- The server's whole list for this game: what is not on it any more is let go, what is new is taken
RegisterNetEvent('whip_rope:keep', function(list)
    if type(list) ~= 'table' then return end
    local want = {}
    for _, n in ipairs(list) do
        n = tonumber(n)
        if n and n > 0 then want[n] = true end
    end
    for netId in pairs(keeping) do
        if not want[netId] then release(netId) end
    end
    for netId in pairs(want) do
        if not keeping[netId] then keeping[netId] = { askedAt = 0 } end
    end
    if next(keeping) then run() end
end)

-- The server: a player has sat at the wheel of this a while and still has no control (server/keep.lua's watch). If
-- this game has it, its lock is lifted, whoever set it, so GTA hands it to the driver. Should this game still keep
-- it, its next look locks it again only once nobody is at the wheel.
RegisterNetEvent('whip_rope:letGo', function(netId)
    netId = tonumber(netId)
    if not netId then return end
    setLock(netId, entityOf(netId), false)
end)

-- The cars a Director take drives on this game (server/keep.lua): the recording moves them, the rope never pulls one
-- (client/physics.lua's bodyOf). The whole list each time it changes.
RegisterNetEvent('whip_rope:driven', function(list)
    if type(list) ~= 'table' then return end
    local driven = {}
    for _, n in ipairs(list) do
        n = tonumber(n)
        if n and n > 0 then driven[n] = true end
    end
    Rope.Driven = driven
end)

-- Where this game sees the far end of each rope two games move, for the other game (client/physics.lua's
-- sharedSpan meets the two halfway): a batch every SPAN_SEND_MS while the server says there is such a rope
local SPAN_SEND_MS = 250
local sendingSpans = false

local function sendSpans()
    if sendingSpans then return end
    sendingSpans = true
    CreateThread(function()
        while next(Rope.Lag) do
            local now, batch = GetGameTimer(), {}
            for id, rope in pairs(Rope.System.ropes) do
                local v = rope.spanAvg
                if v and id > 0 and Rope.Lag[id] and now - (rope.spanAvgAt or 0) < 2 * SPAN_SEND_MS then
                    batch[#batch + 1] = { r = id, x = v.x, y = v.y, z = v.z }
                end
            end
            if #batch > 0 then TriggerServerEvent('whip_rope:span', batch) end
            Wait(SPAN_SEND_MS)
        end
        sendingSpans = false
    end)
end

-- How late this game sees the other end of each rope two games move (server/keep.lua): client/physics.lua's pull
-- allows for it
RegisterNetEvent('whip_rope:lag', function(map)
    if type(map) ~= 'table' then return end
    local lag = {}
    for id, s in pairs(map) do
        id, s = tonumber(id), tonumber(s)
        if id and s and s >= 0 then lag[id] = math.min(s, 2.0) end
    end
    Rope.Lag = lag
    for id in pairs(Rope.TheirSpan) do
        if not lag[id] then Rope.TheirSpan[id] = nil end
    end
    if next(lag) then sendSpans() end
end)

-- Where the other game sees the far end of those ropes (sent on by the server)
RegisterNetEvent('whip_rope:theirSpan', function(list)
    if type(list) ~= 'table' then return end
    local now = GetGameTimer()
    for _, e in ipairs(list) do
        local id, x, y, z = tonumber(e.r), tonumber(e.x), tonumber(e.y), tonumber(e.z)
        if id and x and y and z then Rope.TheirSpan[id] = { v = vector3(x, y, z), at = now } end
    end
end)

-- Stopping: GTA may hand everything on again
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for netId in pairs(keeping) do release(netId) end
end)
