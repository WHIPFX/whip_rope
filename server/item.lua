--[[
    whip_rope — THE ROPE AS AN ITEM

    Using the item puts a rope out with its first end in your hand; the server creates it directly.
    Coiling it up gives the item to whoever coiled it (server/main.lua). Ropes still out when a player
    leaves, or when whip_rope stops, are owed back to their owner (Config.Item.GiveBackOnLogout) and
    paid at the next login. What is owed is kept in KVP, so it survives a restart.
]]

-- Why this player cannot put a rope out now, or nil
local function cannotMake(source)
    if Ropes.countOf(source) >= (Config.Rope.MaxRopes or 5) then
        return ('You already have %d ropes out'):format(Config.Rope.MaxRopes or 5)
    end
    if Ropes.heldBy(source) then return 'Your hands are full' end
    if Ropes.hanging[source] then return 'Let go of the rope first' end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return 'Not now' end
    if GetVehiclePedIsIn(ped, false) ~= 0 then return 'Get out of the vehicle first' end
    return nil
end

local function onUse(source, player)
    local why = cannotMake(source)
    if why then return false, why end   -- kept, and said

    local at = Ropes.pedPos(source)
    local id = Ropes.nextId
    Ropes.nextId = id + 1
    -- Its size as the settings say now, kept with it: every game builds it from these (client/interaction.lua),
    -- however late it comes near, so a change to the length or node count later never resizes it
    local nodes = math.max(2, math.floor(Config.Rope.SegmentCount))
    local rope = {
        id = id,
        owner = source,
        ownerCharId = player and player.charId or nil,
        createdAt = os.time(),
        originPosition = Ropes.wire(at),
        origin = { type = 'held', heldBy = source },
        tail = { type = 'free' },
        nodes = nodes,
        link = Config.Rope.Length / (nodes - 1),
    }
    Ropes.all[id] = rope
    Ropes.debug('rope', id, 'put out by', source)
    TriggerClientEvent('whip_rope:spawned', -1, Ropes.payload(rope))
    return true   -- the item is used up: the rope is out
end

--- A rope back into a player's pockets (coiled up, or owed). Answers where it went, or false.
function Ropes.giveItem(source, amount, reason)
    local where, err = Whip.call('AddItem', source, Config.Item.Name, amount or 1, nil, reason)
    if not where then
        print(('[whip_rope] could not give %s rope(s) back to %s: %s'):format(tostring(amount or 1),
            tostring(source), tostring(err)))
        return false
    end
    return where
end

--- Pay a character what they are owed. Taken off the books first (so two loads can't both pay) and put
--- back if the give fails. Call from a thread: AddItem may wait.
local function payOwed(source, charId)
    local owed = Ropes.takeOwed(charId)
    if owed <= 0 then return end
    if Ropes.giveItem(source, owed, 'ropes you had out') then
        Whip.call('NotifyPlayer', source, owed == 1 and 'The rope you had out is back in your pockets'
            or ('The %d ropes you had out are back in your pockets'):format(owed), 'info')
    else
        Ropes.owe(charId, owed)
    end
end

-- Owed ropes, handed over as the character loads
AddEventHandler('whip_core:player:loaded', function(e)
    local charId = type(e) == 'table' and e.charId
    if not charId or not Ropes.owed[charId] then return end
    local source = e.source
    CreateThread(function() payOwed(source, charId) end)
end)

-- ...and to everyone already in when whip_rope starts (a restart took their ropes in)
CreateThread(function()
    if not next(Ropes.owed) or not Whip.ready(60000) then return end
    for _, id in ipairs(GetPlayers()) do
        local source = tonumber(id)
        local sheet = Whip.call('GetPlayer', source)
        if type(sheet) == 'table' and sheet.charId and Ropes.owed[sheet.charId] then
            payOwed(source, sheet.charId)
        end
    end
end)

--- A rope whip_rope takes in itself: gone everywhere, and back in its owner's pockets. It is owed first (so it is never
--- lost, whatever happens next), then paid at once while they are still the character who put it out, else at that
--- character's next login. Never waits. A resource's rope (a pump's hose) was never an item: not this.
function Ropes.takeIn(ropeId)
    local rope = Ropes.all[ropeId]
    if not rope or rope.byResource then return false end
    Ropes.remove(ropeId)
    local charId, owner = rope.ownerCharId, rope.owner
    if not charId then return true end
    Ropes.owe(charId, 1)
    CreateThread(function()
        local sheet = Whip.call('GetPlayer', owner)
        if type(sheet) == 'table' and sheet.charId == charId then payOwed(owner, charId) end
    end)
    return true
end

-- ============================================================================
-- A DIRECTOR TEST'S CARS: a rope tied to one comes back as the car goes
-- ============================================================================
-- A builder's Test makes its cars again on every Reset, and takes them all away on Stop. A rope tied to one would be
-- left lying where the car stood, so it comes back to its owner's pockets instead, to try the scene again. Only a
-- Test's cars, and only a temporary car (one whip deletes as it lets it go). A car of a real run going (its end, a
-- garage, a despawn) leaves the rope where it was, as any car's does (server/main.lua).

local testCars = {}   -- [vehicleId] = true: cars a Test made (whip_core:run:thingMade)

AddEventHandler('whip_core:run:thingMade', function(e)
    if GetInvokingResource() ~= 'whip_core' or type(e) ~= 'table' or e.kind ~= 'vehicle' then return end
    local vehicleId = tonumber(e.vehicleId)
    local test = e.test == true or (type(e.run) == 'table' and e.run.test == true)
    if vehicleId and test then testCars[vehicleId] = true end
end)

AddEventHandler('whip_core:vehicle:released', function(e)
    if GetInvokingResource() ~= 'whip_core' or type(e) ~= 'table' then return end
    local vehicleId = tonumber(e.vehicleId)
    if not vehicleId or not testCars[vehicleId] then return end
    testCars[vehicleId] = nil
    if e.temp ~= true then return end   -- (a car it claimed is handed back to GTA, still there: the rope stays on it)
    local ids = {}
    for id, rope in pairs(Ropes.all) do
        if not rope.byResource and (rope.origin.vehicleId == vehicleId or rope.tail.vehicleId == vehicleId) then
            ids[#ids + 1] = id
        end
    end
    for _, id in ipairs(ids) do
        Ropes.debug('rope', id, 'taken in: the Test car it was tied to went')
        Ropes.takeIn(id)
    end
end)

-- Stopping: every rope out is owed to its owner's character. Nothing here may wait.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, rope in pairs(Ropes.all) do
        if rope.ownerCharId then Ropes.owe(rope.ownerCharId, 1) end
    end
end)

-- The item; its description says how long a rope is now
local function registerItem()
    local ok, err = exports.whip_core:RegisterItem(Config.Item.Name, {
        name = Config.Item.Label,
        desc = ('A %g m rope. Use it to hold one end, then tie it to a car or a prop where you look.')
            :format(Config.Rope.Length),
        weight = Config.Item.Weight,
        type = 'tool',
        stack = true,
        maxStack = Config.Item.MaxStack,
        usable = true,
        cooldown = 2,
        image = 'html/img/items/rope.webp',
    })
    if not ok then print(('[whip_rope] the rope item was not registered: %s'):format(tostring(err))) end
end

Whip.register(function()
    registerItem()
    exports.whip_core:RegisterUseHandler(Config.Item.Name, onUse)
end)

-- A new length on the settings page: the description says it (ropes already out keep theirs). A tick later, so it is
-- not registered from inside whip_core's own settings call.
Whip.onConfigChanged('Rope.Length', function()
    SetTimeout(0, function()
        if Whip.isReady() then registerItem() end
    end)
end)
