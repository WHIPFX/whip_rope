--[[
    What a player does with a rope on this game: taking an end, putting it down, letting it go, tying it, hanging off
    it, and coiling it up. Each action changes the rope here at once and asks the server, which tells every game, or
    sends the real rope back (whip_rope:correction). Every end change goes through Rope.ApplyEnd, so an end's fields
    are never half one kind and half another.
]]

local DebugPrint = Rope.Util.DebugPrint
local Notify = Rope.Util.Notify

-- An end's fields on a rope, after its 'origin' / 'tail' prefix
local END_FIELDS = { 'HeldBy', 'Position', 'Entity', 'NetId', 'Offset', 'Edge', 'Mass', 'GivenMass', 'WorldPos',
                     'ObjectModel', 'Point', 'LocalTo', 'MissingSince', 'Still', 'Tied' }

local function v3(t)
    if type(t) ~= 'table' and type(t) ~= 'vector3' then return nil end
    if not t.x or not t.y or not t.z then return nil end
    return vector3(t.x + 0.0, t.y + 0.0, t.z + 0.0)
end

function Rope.EndNode(rope, which)
    return which == 'origin' and rope.nodes[1] or rope.nodes[#rope.nodes]
end

function Rope.OtherEnd(which)
    return which == 'origin' and 'tail' or 'origin'
end

-- How heavy things are (read on this game, never sent)

local CLASS_MASS = {
    [0] = 1200, [1] = 1400, [2] = 1600, [3] = 1300, [4] = 1500, [5] = 1400, [6] = 1300, [7] = 1200,
    [8] = 500, [9] = 1800, [10] = 2500, [11] = 2000, [12] = 2200, [13] = 100, [14] = 5000,
    [15] = 3000, [16] = 5000, [17] = 2000, [18] = 2500, [19] = 3000, [20] = 3500, [21] = 8000,
}

function Rope.GetVehicleMass(vehicle)
    local mass = GetVehicleHandlingFloat(vehicle, 'CHandlingData', 'fMass')
    if mass and mass > 0 then return mass end
    return CLASS_MASS[GetVehicleClass(vehicle)] or 1500
end

--- A frozen prop does not move (an anchor); anything else about 100 kg per cubic metre of its box. Only a guess
--- (the game can't read a prop's weight): a prop whose resource says what it weighs uses that (`mass`, GivenMass).
function Rope.GetObjectMass(object)
    if IsEntityPositionFrozen(object) then return 10000.0 end
    local min, max = GetModelDimensions(GetEntityModel(object))
    local size = max - min
    return math.max(50.0, size.x * size.y * size.z * 100.0)
end

-- What an end is tied to, on this game

-- A map prop has no network id: every game finds its own copy, by model, where it stood.
local function FindWorldProp(model, worldPos)
    if not model or not worldPos then return nil end
    local found = GetClosestObjectOfType(worldPos.x, worldPos.y, worldPos.z, 1.5, model, false, false, false)
    if found and found ~= 0 and DoesEntityExist(found) then return found end
    return nil
end

-- A map prop that is not frozen is dragged on every game that has it (each moves its own copy) and kept, or it is
-- culled and comes back where it started. A frozen one is an anchor and is left alone.
local function WakeWorldProp(object)
    if IsEntityPositionFrozen(object) then return false end
    local ok = pcall(function()
        SetEntityAsMissionEntity(object, true, true)
        SetEntityDynamic(object, true)
        SetEntityLodDist(object, 500)
        ActivatePhysics(object)
    end)
    return ok
end

-- A car only one game has (not networked): on that game, the one of its model nearest where it was tied, within
-- LOCAL_CAR_REACH. No other game has it.
local LOCAL_CAR_REACH = 1.5

local function FindLocalVehicle(model, worldPos)
    if not model or not worldPos then return nil end
    local best, bestD = nil, LOCAL_CAR_REACH
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if GetEntityModel(veh) == model and not NetworkGetEntityIsNetworked(veh) then
            local d = #(GetEntityCoords(veh) - worldPos)
            if d < bestD then best, bestD = veh, d end
        end
    end
    return best
end

--- Where on a car an `edge` end is: at its nose ('front') or tail ('back'), a third of the way up its body. From its
--- model, so every game works out the same point.
local function edgeOffset(entity, edge)
    local mn, mx = GetModelDimensions(GetEntityModel(entity))
    return vector3(0.0, edge == 'front' and mx.y or mn.y, mn.z + (mx.z - mn.z) * 0.3)
end

--- The car or prop an end is tied to, on this game now (nil while it is not streamed in here), and
--- its mass. Asked again by the watchdog until it is found.
function Rope.ResolveEndEntity(rope, which)
    local endType = rope[which .. 'Type']
    if endType ~= 'vehicle' and endType ~= 'object' then return nil end

    local entity
    local netId = rope[which .. 'NetId']
    if netId then
        if NetworkDoesNetworkIdExist(netId) then
            local e = NetworkGetEntityFromNetworkId(netId)
            if e and e ~= 0 and DoesEntityExist(e) then entity = e end
        end
        -- A take car shown here as this game's own copy (its real one hidden, a little behind): the rope is on the copy
        local copy = entity and endType == 'vehicle' and Rope.Copies[entity]
        if copy and DoesEntityExist(copy) then entity = copy end
    elseif endType == 'vehicle' then
        if rope[which .. 'LocalTo'] == Rope.MyServerId() then
            entity = FindLocalVehicle(rope[which .. 'ObjectModel'], rope[which .. 'WorldPos'])
        end
    elseif endType == 'object' then
        entity = FindWorldProp(rope[which .. 'ObjectModel'], rope[which .. 'WorldPos'])
        -- Woken to be dragged — unless the end says it stays an anchor (`still`: a pump's hose, server/api.lua)
        if entity and not rope[which .. 'ObjectActivated'] and not rope[which .. 'Still'] then
            rope[which .. 'ObjectActivated'] = WakeWorldProp(entity)
        end
    end

    rope[which .. 'Entity'] = entity
    if entity then
        rope[which .. 'Mass'] = endType == 'vehicle' and Rope.GetVehicleMass(entity)
            or rope[which .. 'GivenMass'] or Rope.GetObjectMass(entity)
        local edge = rope[which .. 'Edge']
        if edge and endType == 'vehicle' then rope[which .. 'Offset'] = edgeOffset(entity, edge) end
    end
    return entity
end

--- What a prop end's resource says it weighs (kg), or nil.
local function givenMass(e)
    local kg = tonumber(e.mass)
    return kg and kg > 0 and kg or nil
end

local function close(a, b) return a ~= nil and b ~= nil and #(a - b) < 0.01 end

-- Is `e` the end this rope already has? The server echoes both ends with every change; an unchanged end
-- keeps what this game found for it (a dragged map prop can't be re-found where it first stood).
local function sameEnd(rope, which, e)
    local t = type(e) == 'table' and e.type or 'free'
    if rope[which .. 'Type'] ~= t then return false end
    if t == 'free' then return true end
    if t == 'held' then return rope[which .. 'HeldBy'] == tonumber(e.heldBy) end
    if t == 'fixed' then
        return close(rope[which .. 'Position'], v3(e.pos)) and rope[which .. 'Tied'] == (e.tied == true or nil)
    end
    local netId = tonumber(e.netId)
    if netId and netId <= 0 then netId = nil end
    if rope[which .. 'NetId'] ~= netId or rope[which .. 'Edge'] ~= e.edge then return false end
    -- (An edge end's offset is this game's own, from the model: Rope.ResolveEndEntity)
    if not e.edge and not close(rope[which .. 'Offset'], v3(e.offset) or vector3(0.0, 0.0, 0.0)) then return false end
    if t == 'object' and rope[which .. 'GivenMass'] ~= givenMass(e) then return false end
    -- A map prop, or a car only one game has: by model, where it stood. (A networked prop is its id: it has no
    -- model or spot in the end, so asking for them here made every echo of one a new end, its pull started over.)
    if not netId then
        return rope[which .. 'ObjectModel'] == tonumber(e.model) and close(rope[which .. 'WorldPos'], v3(e.worldPos))
            and rope[which .. 'LocalTo'] == tonumber(e.localTo)
    end
    return true
end

--- Set one end. `e` is an end as the server sends it:
---   { type = 'held', heldBy } | { type = 'free' } | { type = 'fixed', pos, tied? } (tied: to the map, not put down)
---   | { type = 'vehicle', netId, offset } | { type = 'object', netId (0: a map prop), model, worldPos, offset, point }
---   | { type = 'vehicle', netId = 0, model, worldPos, offset, point, localTo } (a car only localTo's game has)
--- The end it already has changes nothing.
function Rope.ApplyEnd(rope, which, e)
    if sameEnd(rope, which, e) then return end
    for _, f in ipairs(END_FIELDS) do rope[which .. f] = nil end
    rope[which .. 'ObjectActivated'] = false

    local endType = type(e) == 'table' and e.type or 'free'
    local node = Rope.EndNode(rope, which)
    rope[which .. 'Type'] = endType

    if endType == 'held' then
        rope[which .. 'HeldBy'] = tonumber(e.heldBy)
    elseif endType == 'fixed' then
        rope[which .. 'Position'] = v3(e.pos) or (node and node.position)
        rope[which .. 'Tied'] = e.tied == true or nil
    elseif endType == 'vehicle' or endType == 'object' then
        local netId = tonumber(e.netId)
        rope[which .. 'NetId'] = (netId and netId > 0) and netId or nil
        rope[which .. 'Offset'] = v3(e.offset) or vector3(0.0, 0.0, 0.0)
        -- At a car's nose or tail: its offset worked out here from its model, once it is found (Rope.ResolveEndEntity)
        if endType == 'vehicle' and (e.edge == 'front' or e.edge == 'back') then rope[which .. 'Edge'] = e.edge end
        -- What a prop really weighs, when its resource said (server/api.lua); else Rope.GetObjectMass guesses
        if endType == 'object' then rope[which .. 'GivenMass'] = givenMass(e) end
        if endType == 'object' or not rope[which .. 'NetId'] then
            rope[which .. 'ObjectModel'] = tonumber(e.model)
            rope[which .. 'WorldPos'] = v3(e.worldPos)
            rope[which .. 'Point'] = v3(e.point)
            rope[which .. 'LocalTo'] = tonumber(e.localTo)
            rope[which .. 'Still'] = e.still == true or nil   -- a map prop that stays an anchor (server/api.lua)
        end
        Rope.ResolveEndEntity(rope, which)
    elseif endType ~= 'free' then
        rope[which .. 'Type'] = 'free'
    end

    -- An end node is an ordinary node again (it is pinned while held or tied), and the pull starts
    -- over, after its settling time
    Rope.ResetNodeMass(node)
    rope[which .. 'SmoothedForce'] = 0
    rope[which .. 'LastCoupleType'] = nil
end

-- The walk while holding an end

local holdWalk = false

--- The hold's walk as Config.Holding says, or off: the walk style through whip's walk override and the top speed
--- through its control block. Both are swept by whip_core if this resource stops.
local function applyHoldWalk()
    local h = Config.Holding or {}
    local style = holdWalk and h.WalkStyle or nil
    if style == 'none' or style == '' or style == false then style = nil end
    Whip.core:SetWalkOverride(style)
    local speed = holdWalk and h.Speed or nil
    if speed == 'walk' then
        Whip.core:BlockControls('holdWalk', { walk = true })
    elseif speed == 'jog' then
        Whip.core:BlockControls('holdWalk', { jog = true })
    else
        Whip.core:UnblockControls('holdWalk')
    end
end

--- On while this player holds an end (client/ui.lua follows the hold).
function Rope.SetHoldingWalk(on)
    if on == holdWalk then return end
    holdWalk = on
    applyHoldWalk()
end

-- Changed in /whip → Settings while holding: at once
Whip.onConfigChanged('Holding.Speed', function() if holdWalk then applyHoldWalk() end end)
Whip.onConfigChanged('Holding.WalkStyle', function() if holdWalk then applyHoldWalk() end end)

--- whip_core (re)started or stopped: it has forgotten the override, so the next SetHoldingWalk sets it again.
function Rope.ForgetHoldingWalk()
    holdWalk = false
end

-- Taking an end (a loose or put-down one, or untying a tied one)

local function busyReason()
    if Rope.IsPlayerHanging() then return 'Let go of the rope first' end
    if Rope.MyHeld() then return 'Your hands are full' end
    if IsPedInAnyVehicle(PlayerPedId(), false) then return 'Get out of the vehicle first' end
    return nil
end

--- May this player take this end now? (the prompt asks every frame: no waiting, no toasts)
function Rope.CanTakeEnd(ropeId, which)
    local rope = Rope.System.ropes[ropeId]
    if not rope or not rope.serverRopeId then return false end
    if rope[which .. 'Type'] == 'held' then return false end
    if rope.opts and rope.opts.noTake then return false end   -- (a resource's rope that may not be picked up)
    if not Config.Rules.AnyoneCanHandle and rope.ownerServerId ~= Rope.MyServerId() then return false end
    -- Tied to a car only one game has: only its player has it to untie
    if rope[which .. 'Type'] == 'vehicle' and not rope[which .. 'NetId']
        and rope[which .. 'LocalTo'] ~= Rope.MyServerId() then return false end
    return busyReason() == nil
end

function Rope.TakeEnd(ropeId, which)
    local rope = Rope.System.ropes[ropeId]
    if not rope or not rope.serverRopeId then return false end
    local why = busyReason()
    if why then Notify(why, 'error') return false end
    if rope[which .. 'Type'] == 'held' then Notify('Someone is holding that end', 'error') return false end
    if rope.opts and rope.opts.noTake then Notify("That rope can't be picked up", 'error') return false end

    Rope.ApplyEnd(rope, which, { type = 'held', heldBy = Rope.MyServerId() })
    TriggerServerEvent('whip_rope:take', rope.serverRopeId, which)
    return true
end

-- Putting the held end down, letting it go, tying it

-- Having put one end somewhere, you take the other if it is lying loose: put the rope out, tie it to
-- a car, and you are holding the other end ready to tie to the next. (The server decides the same.)
local function TakeOtherIfLoose(rope, which)
    local other = Rope.OtherEnd(which)
    if rope[other .. 'Type'] == 'free' then
        Rope.ApplyEnd(rope, other, { type = 'held', heldBy = Rope.MyServerId() })
    end
end

-- Where the held end goes when put down: the ground under the hand, or half a metre below it.
local function GroundUnderHand()
    local hand = Rope.GetPlayerHandPosition()
    local hit, hitPos = Rope.SyncProbe(hand.x, hand.y, hand.z, hand.x, hand.y, hand.z - 3.0, 1 + 16, PlayerPedId())
    if hit then return vector3(hitPos.x, hitPos.y, hitPos.z + (Config.WorldCollision.GroundOffset or 0.05)) end
    return hand - vector3(0, 0, 0.5)
end

function Rope.PutDownHeldEnd()
    local rope, _, which = Rope.MyHeld()
    if not rope or not rope.serverRopeId then return false end
    local pos = GroundUnderHand()
    Rope.ApplyEnd(rope, which, { type = 'fixed', pos = pos })
    TakeOtherIfLoose(rope, which)
    TriggerServerEvent('whip_rope:place', rope.serverRopeId, which, pos.x, pos.y, pos.z)
    return true
end

function Rope.LetGoHeldEnd()
    local rope, _, which = Rope.MyHeld()
    if not rope or not rope.serverRopeId then return false end
    Rope.ApplyEnd(rope, which, { type = 'free' })
    TriggerServerEvent('whip_rope:release', rope.serverRopeId, which)
    return true
end

--- Can the held end be tied to this? (the aim prompt asks every frame) `world`: it is the map itself (a wall, the
--- ground: whip's aimBox 'world', no entity), allowed by Config.Rules.TieToMap.
function Rope.CanTieTo(entity, world)
    local rope = Rope.MyHeld()
    if not rope or not rope.serverRopeId then return false end
    if world then return Config.Rules.TieToMap ~= false end
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    -- Any car: networked, or only this game's (a whip_scenes scene's)
    if IsEntityAVehicle(entity) then return true end
    -- Never to the rope's own props, nor to a prop something is carrying
    return IsEntityAnObject(entity) and GetEntityModel(entity) ~= Config.Visuals.PropModel
        and not IsEntityAttached(entity)
end

-- How far off the map's surface a rope tied to it ends (m): its end just clear of the wall, never in it
local MAP_TIE_OFF = 0.03

--- Tie the held end to `entity` at `point`, the spot the player looks at on it (whip's aimBox prompt). `world`: the
--- map itself there (no entity), its surface facing `normal`: the end stays at that spot, like a post.
function Rope.TieHeldEnd(entity, point, world, normal)
    local rope, _, which = Rope.MyHeld()
    if not rope or not rope.serverRopeId or not Rope.CanTieTo(entity, world) or not point then return false end
    if world then
        local out = normal
        if not out or #out < 0.5 then
            -- (No surface to go by: back toward where the look came from)
            local cam = GetFinalRenderedCamCoord()
            out = cam - point
            if #out < 0.001 then out = vector3(0.0, 0.0, 1.0) end
        end
        local pos = point + out / #out * MAP_TIE_OFF
        Rope.ApplyEnd(rope, which, { type = 'fixed', pos = pos, tied = true })
        TakeOtherIfLoose(rope, which)
        TriggerServerEvent('whip_rope:tieMap', rope.serverRopeId, which, pos.x, pos.y, pos.z)
        return true
    end
    local off = GetOffsetFromEntityGivenWorldCoords(entity, point.x, point.y, point.z)
    -- This game's copy of a take car (whip_core's recorded drives sync): tied to the real car it shows, at the same point
    -- on it (the copy is where the real one is). Not a car only this game has.
    local real = Rope.CopyOf[entity]
    if real and DoesEntityExist(real) and NetworkGetEntityIsNetworked(real) then entity = real end

    if IsEntityAVehicle(entity) and not NetworkGetEntityIsNetworked(entity) then
        -- A car only this game has: the server keeps its model and where it stood, and only this game finds it
        local model = GetEntityModel(entity)
        local at = GetEntityCoords(entity)
        Rope.ApplyEnd(rope, which, { type = 'vehicle', netId = 0, model = model, worldPos = at, offset = off,
                                     point = point, localTo = Rope.MyServerId() })
        rope[which .. 'Entity'] = entity   -- this one, not another of its model beside it
        rope[which .. 'Mass'] = Rope.GetVehicleMass(entity)
        TakeOtherIfLoose(rope, which)
        TriggerServerEvent('whip_rope:tieLocalVehicle', rope.serverRopeId, which, model, at.x, at.y, at.z,
            off.x, off.y, off.z, point.x, point.y, point.z)
    elseif IsEntityAVehicle(entity) then
        local netId = NetworkGetNetworkIdFromEntity(entity)
        Rope.ApplyEnd(rope, which, { type = 'vehicle', netId = netId, offset = off })
        TakeOtherIfLoose(rope, which)
        TriggerServerEvent('whip_rope:tieVehicle', rope.serverRopeId, which, netId, off.x, off.y, off.z)
    else
        local netId = NetworkGetEntityIsNetworked(entity) and NetworkGetNetworkIdFromEntity(entity) or 0
        local model = GetEntityModel(entity)
        local at = GetEntityCoords(entity)
        Rope.ApplyEnd(rope, which, { type = 'object', netId = netId, model = model, worldPos = at,
                                     offset = off, point = point })
        TakeOtherIfLoose(rope, which)
        TriggerServerEvent('whip_rope:tieObject', rope.serverRopeId, which, netId, model,
            at.x, at.y, at.z, off.x, off.y, off.z, point.x, point.y, point.z)
    end
    return true
end

-- Coiling it up (a server-timed bar; the item comes back from the server)

Rope.Coiling = false

function Rope.CoilHeldRope()
    local rope = Rope.MyHeld()
    if not rope or not rope.serverRopeId or Rope.Coiling then return false end
    if not Config.Rules.AnyoneCanHandle and rope.ownerServerId ~= Rope.MyServerId() then
        Notify("That rope isn't yours to coil up", 'error')
        return false
    end
    -- The bar draws in the hint capsule: ours steps aside until the server says it has ended
    Rope.Coiling = GetGameTimer()
    TriggerServerEvent('whip_rope:coil', rope.serverRopeId)
    return true
end

-- Hanging off it

-- What hanging changes on the ped beyond whip's ped hold, put back as it was when they let go. GTA's ped config flags,
-- by the names in citizenfx's natives list (SetPedConfigFlag).
local HANG_PED_FLAGS = {
    60,    -- IsStanding
    68,    -- IsSitting
    104,   -- OpenDoorArmIK
    72,    -- ClearRadarBlipOnDeath
}
local LET_GO_MS = 1000   -- our own ragdoll let go of the rope: limp this long as it falls, then up
local savedPed = nil

--- Our ped as it hangs. `own`: it is the body on the rope (a ragdoll hang): its ragdoll and collision stay, and it is
--- hidden from everyone else. Otherwise a stand-in hangs and our ped is hidden, put under the hand every frame. What it
--- changes is saved once and put back when they let go.
local function HangPedOn(ped, own)
    -- BOOL natives answer 1 or false, never true
    savedPed = savedPed or { ragdoll = CanPedRagdoll(ped) and true or false, flags = {} }
    Rope.HangOwnBody = own == true
    if own then
        -- Hidden from every other game (each hangs its own stand-in of us), unhurt
        Whip.core:HoldPlayerPed('hang', { hidden = true, invincible = true })
    else
        for _, f in ipairs(HANG_PED_FLAGS) do
            if savedPed.flags[f] == nil then savedPed.flags[f] = GetPedConfigFlag(ped, f, true) and true or false end
            SetPedConfigFlag(ped, f, true)
        end
        SetPedCanRagdoll(ped, false)
        SetPedCanRagdollFromPlayerImpact(ped, false)
        SetPedRagdollOnCollision(ped, false)
        -- Hidden (from everyone), no collision, unhurt: whip's one owner of these, so letting go never
        -- shows an admin who is invisible
        Whip.core:HoldPlayerPed('hang', { hidden = true, noCollision = true, invincible = true })
    end
    -- No walking, jumping or shooting; jump is read (disabled) to let go
    Whip.core:BlockControls('hang', { groups = { 'move', 'combat' } })
end
Rope.HangPedOn = HangPedOn

local function HangPedOff(ped)
    Whip.core:ReleasePlayerPed('hang')
    Whip.core:UnblockControls('hang')
    local saved = savedPed or { ragdoll = true, flags = {} }
    savedPed = nil
    local own = Rope.HangOwnBody
    Rope.HangOwnBody = false
    for f, was in pairs(saved.flags) do SetPedConfigFlag(ped, f, was == true) end
    SetPedCanRagdoll(ped, saved.ragdoll ~= false)
    SetPedCanRagdollFromPlayerImpact(ped, true)
    SetPedRagdollOnCollision(ped, true)
    if own and IsPedRagdoll(ped) and not IsEntityDead(ped) then
        -- The body it was lets go as one: its hang's ragdoll was asked for a minute, now a moment, falling
        SetPedToRagdoll(ped, LET_GO_MS, LET_GO_MS, 0, false, false, false)
    else
        ClearPedTasks(ped)
    end
end

--- The rope node nearest `pos` someone can hang from (never an end), within PlayerHang.GrabRadius.
function Rope.GetNearestRopeNode(pos, onlyRopeId)
    local best = Config.PlayerHang.GrabRadius
    local bestKey, bestIndex
    for ropeKey, rope in pairs(Rope.System.ropes) do
        -- (Nor a locked rope, nor one that may not be hung from)
        if (onlyRopeId == nil or ropeKey == onlyRopeId) and not (rope.opts and (rope.opts.locked or rope.opts.noHang)) then
            for i = 2, #rope.nodes - 1 do
                local d = #(pos - rope.nodes[i].position)
                if d < best then best, bestKey, bestIndex = d, ropeKey, i end
            end
        end
    end
    return bestKey, bestIndex, best
end

function Rope.CanHang(ropeId)
    if not Config.PlayerHang.Enabled then return false end
    local rope = Rope.System.ropes[ropeId]
    if not rope or not rope.serverRopeId then return false end
    if busyReason() then return false end
    return Rope.GetNearestRopeNode(GetEntityCoords(PlayerPedId()), ropeId) ~= nil
end

function Rope.HangOnRope(ropeId)
    if not Config.PlayerHang.Enabled then return false end
    local rope = Rope.System.ropes[ropeId]
    if not rope or not rope.serverRopeId then return false end
    local why = busyReason()
    if why then Notify(why, 'error') return false end
    local _, nodeIndex = Rope.GetNearestRopeNode(GetEntityCoords(PlayerPedId()), ropeId)
    if not nodeIndex then Notify('Stand closer to the rope', 'error') return false end

    local me = Rope.MyServerId()
    Rope.HangingPlayers[me] = { serverRopeId = rope.serverRopeId, nodeIndex = nodeIndex }
    -- main.lua's let-go (jump) waits half a second from here, so nothing pressed with the hold drops it
    Rope.HangStartedAt = GetGameTimer()
    Rope.SetHangingNodeMass(rope.nodes[nodeIndex])
    local ped = PlayerPedId()
    -- As a ragdoll, our own ped is the body on the rope (the camera follows it); by the animation, a stand-in
    HangPedOn(ped, (Config.PlayerHang.Style or 'ragdoll') == 'ragdoll')
    TriggerServerEvent('whip_rope:hang', rope.serverRopeId, nodeIndex)
    -- Our own stand-in in a thread of its own, as everyone else's (EnsureClone): it waits for its model, and the
    -- ragdoll's tie a few frames (client/hang_ragdoll.lua), and this runs in the Hang prompt's own callback
    Rope.EnsureClone(me)
    return true
end

--- Stop hanging, here. `tellServer` false when the server already knows (it said so, or a death or a
--- logout it handles itself).
function Rope.DetachPlayerFromRope(tellServer)
    local me = Rope.MyServerId()
    local hangData = Rope.HangingPlayers[me]
    if not hangData then return false end
    Rope.HangingPlayers[me] = nil

    local rope = Rope.System.ropes[hangData.serverRopeId]
    if rope then Rope.ResetNodeMass(rope.nodes[hangData.nodeIndex]) end
    Rope.DeletePlayerClone(me)
    HangPedOff(PlayerPedId())

    if tellServer ~= false then TriggerServerEvent('whip_rope:unhang') end
    return true
end

--- Someone else stops hanging (the server said so), or everyone off a rope that is going.
function Rope.ForgetHanging(serverId)
    if serverId == Rope.MyServerId() then
        return Rope.DetachPlayerFromRope(false)
    end
    local hangData = Rope.HangingPlayers[serverId]
    if not hangData then return false end
    Rope.HangingPlayers[serverId] = nil
    local rope = Rope.System.ropes[hangData.serverRopeId]
    if rope then Rope.ResetNodeMass(rope.nodes[hangData.nodeIndex]) end
    Rope.DeletePlayerClone(serverId)
    return true
end

function Rope.DetachAllPlayersFromRope(serverRopeId)
    if not serverRopeId then return end
    for serverId, hangData in pairs(Rope.HangingPlayers) do
        if hangData.serverRopeId == serverRopeId then Rope.ForgetHanging(serverId) end
    end
end

-- Shot while hanging: off the rope (Config.PlayerHang.ShotKnocksOff)
-- A hanging player is hidden and unhurt; every game shows a collisionless stand-in. The shooter's game checks whether
-- its shot passed through a stand-in with nothing solid in the way and tells the server, which checks again and
-- knocks them off. The shot itself does no damage.

local SHOT_RANGE  = 300.0   -- metres a shot's line is followed (about GTA's longest gun; server/main.lua's too)
local SHOT_REACH  = 0.45    -- metres from a stand-in's body line (hands to feet) a shot counts as hitting them
local SHOT_REPEAT = 1000    -- ms: one word to the server a second for each player, however fast the gun fires
local shotTold = {}         -- [serverId] = when we last told the server

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function clamp01(v) return v < 0.0 and 0.0 or (v > 1.0 and 1.0 or v) end

--- Where two segments, p1→q1 and p2→q2, come closest: the distance, and that point on the second.
local function closest(p1, q1, p2, q2)
    local d1, d2, r = q1 - p1, q2 - p2, p1 - p2
    local a, e, f = dot(d1, d1), dot(d2, d2), dot(d2, r)
    local s, t
    if a < 1e-8 and e < 1e-8 then
        s, t = 0.0, 0.0
    elseif a < 1e-8 then
        s, t = 0.0, clamp01(f / e)
    else
        local c = dot(d1, r)
        if e < 1e-8 then
            s, t = clamp01(-c / a), 0.0
        else
            local b = dot(d1, d2)
            local denom = a * e - b * b
            s = denom > 1e-8 and clamp01((b * f - c * e) / denom) or 0.0
            t = (b * s + f) / e
            if t < 0.0 then
                s, t = clamp01(-c / a), 0.0
            elseif t > 1.0 then
                s, t = clamp01((b - c) / a), 1.0
            end
        end
    end
    local on2 = p2 + d2 * t
    return #((p1 + d1 * s) - on2), on2
end

--- The way the camera looks (a shot goes where the crosshair is), as a unit vector.
local function camForward()
    local r = GetFinalRenderedCamRot(2)
    local x, z = math.rad(r.x), math.rad(r.z)
    return vector3(-math.sin(z) * math.cos(x), math.cos(z) * math.cos(x), math.sin(x))
end

--- Every frame while a stand-in is about (main.lua): a shot of ours that went through someone hanging.
function Rope.CheckShotsAtHanging()
    if not Config.PlayerHang.ShotKnocksOff then return end
    local ped = PlayerPedId()
    if not IsPedShooting(ped) then return end
    local me, now = Rope.MyServerId(), GetGameTimer()
    local cam, dir = GetFinalRenderedCamCoord(), camForward()
    -- The look's line from level with us (a third-person camera sits behind us) out to SHOT_RANGE
    local from = cam + dir * math.max(dot(GetEntityCoords(ped) - cam, dir), 0.0)
    local to = cam + dir * SHOT_RANGE
    for serverId, clone in pairs(Rope.Clones) do
        local told = shotTold[serverId]
        if serverId ~= me and Rope.HangingPlayers[serverId] and (not told or now - told >= SHOT_REPEAT)
            and DoesEntityExist(clone.ped) then
            local c = GetEntityCoords(clone.ped)
            -- The stand-in's body: hands up at the rope (HangSpot puts it 1 m under the node) to the feet
            local gap, at = closest(from, to, c + vector3(0.0, 0.0, 0.9), c - vector3(0.0, 0.0, 1.0))
            if gap <= SHOT_REACH then
                -- Nothing solid between our head and them: the map and props (not cars: ours, in a drive-by)
                local head = GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0)
                local span = #(at - head)
                local stop = span > 0.4 and (head + (at - head) * ((span - 0.3) / span)) or head
                if not Rope.SyncProbe(head.x, head.y, head.z, stop.x, stop.y, stop.z, 1 + 16, ped) then
                    shotTold[serverId] = now
                    TriggerServerEvent('whip_rope:shot', serverId)
                end
            end
        end
    end
end

--- We were shot off the rope (the server checked the shooter's word; whip_rope:shotOff): let go, and
--- fall limp, pushed a little away from the shot.
function Rope.KnockedOffRope(fromX, fromY, fromZ)
    if not Rope.IsPlayerHanging() then return end
    Rope.DetachPlayerFromRope(false)
    local ped = PlayerPedId()
    if IsEntityDead(ped) or not CanPedRagdoll(ped) then return end
    local ms = math.floor(tonumber(Config.PlayerHang.ShotRagdollMs) or 3000)
    SetPedToRagdoll(ped, ms, ms, 0, false, false, false)
    local away = GetEntityCoords(ped) - vector3(fromX, fromY, fromZ)
    local len = #away
    if len > 0.01 then
        away = away / len
        ApplyForceToEntity(ped, 1, away.x * 2.0, away.y * 2.0, 0.0, 0.0, 0.0, 0.0, 0,
            false, true, true, false, true)
    end
end

-- A rope on this game: made from what the server sends, and gone

--- Build a rope from the server's record of it: { serverRopeId, owner, originPosition, origin, tail, nodes, link }.
--- Its props come a moment later (the model may still be loading).
function Rope.AddRopeFromServer(data)
    local id = data.serverRopeId
    local start = v3(data.originPosition)
    if not id or not start or Rope.System.ropes[id] then return nil end

    -- Its own node count and link length, which the server gave it as it was made (every rope has them): built and
    -- simulated from those for as long as it lasts, so it matches every other game's, whatever Config.Rope says now
    local count = math.floor(tonumber(data.nodes) or Config.Rope.SegmentCount)
    local link = tonumber(data.link) or Config.Rope.SegmentLength
    local rope = {
        id = id,
        serverRopeId = id,
        -- A resource's rope (server/api.lua): its tag, how it behaves
        kind = data.kind,
        opts = type(data.opts) == 'table' and data.opts or nil,
        resource = type(data.resource) == 'string' and data.resource or nil,
        linkLength = link,
        nodes = Rope.BuildRopeNodes(start, count, link),
        props = {},
        propLastPos = {},
        isLocallyOwned = data.owner == Rope.MyServerId(),
        ownerServerId = data.owner,
        createdAt = GetGameTimer(),
        peakTension = 0,
        storedEnergy = 0,
        isSnapBackActive = false,
    }
    Rope.ApplyEnd(rope, 'origin', data.origin)
    Rope.ApplyEnd(rope, 'tail', data.tail)
    Rope.SettleRope(rope)
    Rope.System.ropes[id] = rope
    Rope.EnsureRopeProps(rope)
    return rope
end

--- Draw the rope once its look has loaded, in its own thread. The watchdog below retries ropes that
--- aren't drawn yet; a look changed mid-load is loaded in turn.
function Rope.EnsureRopeProps(rope)
    if not Config.Visuals.RenderProps or rope.lookReady or rope.propsLoading then return end
    rope.propsLoading = true
    CreateThread(function()
        for _ = 1, 3 do
            local generation = Rope.LookGeneration()
            local style = Rope.LoadLook()
            if not style or Rope.System.ropes[rope.id] ~= rope or rope.lookReady then break end
            -- A resource's rope in its own pieces (a pump's hose): those loaded first (client/api.lua)
            if style == 'segments' then Rope.LoadOwnLook(rope) end
            if Rope.System.ropes[rope.id] ~= rope or rope.lookReady then break end
            if generation == Rope.LookGeneration() then
                Rope.CreateRopeVisuals(rope, style)
                break
            end
        end
        rope.propsLoading = false
    end)
end

-- From `top`, nodes hanging straight down to the ground and then lying along it, away along `dir`. Never below the
-- ground. `flags`: what the collision check sees (Rope.WorldFlags).
local function hangFrom(top, n, seg, dir, flags)
    local hit, hitPos = Rope.SyncProbe(top.x, top.y, top.z + 0.5, top.x, top.y, top.z - 60.0, flags, 0)
    local floor = (hit and hitPos.z or (top.z - 1000.0)) + (Config.WorldCollision.GroundOffset or 0.05)
    local out = {}
    local p = top
    for i = 1, n do
        out[i] = p
        if p.z - seg >= floor then
            p = p - vector3(0, 0, seg)
        else
            -- Down to the ground, and the rest of this segment along it
            local drop = math.max(p.z - floor, 0.0)
            local along = math.sqrt(math.max(seg * seg - drop * drop, 0.0))
            p = vector3(p.x + dir.x * along, p.y + dir.y * along, floor)
        end
    end
    return out
end

--- Lay a rope's nodes out afresh, at rest: between its ends when both are held or tied, else hanging from the one
--- that is down to the ground and along it. For a new rope, and one waking after being out of range.
function Rope.SettleRope(rope)
    local nodes = rope.nodes
    local n = #nodes
    local a = Rope.ResolveEndPoint(rope, 'origin')
    local b = Rope.ResolveEndPoint(rope, 'tail')
    local line
    if not (a and b) then
        local top = a or b or nodes[1].position
        local me = GetEntityCoords(PlayerPedId())
        local d = vector3(top.x - me.x, top.y - me.y, 0.0)
        local len = #d
        line = hangFrom(top, n, Rope.LinkLength(rope), len > 0.1 and d / len or vector3(0.0, 1.0, 0.0),
            Rope.WorldFlags(rope))
    end
    for i = 1, n do
        local p
        if a and b then
            p = a + (b - a) * ((i - 1) / (n - 1))
        elseif b and not a then
            p = line[n - i + 1]
        else
            p = line[i]
        end
        nodes[i].position = p
        nodes[i].previousPosition = p
        nodes[i].ground = nil
    end
    rope.prevEndpointDist, rope.rateTime, rope.endpointRate = nil, nil, 0.0
    rope.originLastCoupleType, rope.tailLastCoupleType = nil, nil
    rope.originSmoothedForce, rope.tailSmoothedForce = 0, 0
    -- No stored spring carried over
    rope.storedEnergy, rope.peakTension, rope.prevTension, rope.isSnapBackActive = 0, 0, nil, false
    -- Laid out afresh: stepped from here (a rope at rest is not: client/main.lua)
    Rope.WakeRope(rope)
end

--- The only way a rope leaves this game: anyone hanging is let down (our own player fully restored),
--- its props go, and client/ui.lua's prompts with it.
function Rope.DeleteRope(ropeKey)
    local rope = Rope.System.ropes[ropeKey]
    if not rope then return false end
    Rope.DetachAllPlayersFromRope(rope.serverRopeId)
    Rope.DestroyRopeVisuals(rope)
    Rope.System.ropes[ropeKey] = nil
    if Rope.UI.OnRopeRemoved then Rope.UI.OnRopeRemoved(ropeKey) end
    return true
end

function Rope.DeleteAllRopes()
    for ropeKey in pairs(Rope.System.ropes) do Rope.DeleteRope(ropeKey) end
end

-- A tied prop that broke or went
-- A map prop can break or be culled. Every game re-finds its own copy; the rope's owner, near enough to see, says
-- when it is gone and the server lets the end go everywhere. A car only one game has is that game's to report, once
-- it has been gone LOCAL_CAR_GRACE_MS. Networked cars and props are the server's to watch.

local LOCAL_CAR_GRACE_MS = 3000

local function ReportLostEnd(rope, which)
    DebugPrint('what was tied to the', which, 'of rope', rope.serverRopeId, 'is gone')
    Rope.ApplyEnd(rope, which, { type = 'free' })
    Notify('The rope came loose from what it was tied to', 'info')
    TriggerServerEvent('whip_rope:lost', rope.serverRopeId, which)
end

local cloneTrying = {}   -- [serverId] = true while a stand-in is being made in its own thread

--- A hanging player's stand-in, in a thread of its own (it waits for the model and the animation).
function Rope.EnsureClone(serverId)
    if Rope.Clones[serverId] or cloneTrying[serverId] then return end
    local ped = Rope.PedOf(serverId)
    if not ped then return end
    cloneTrying[serverId] = true
    CreateThread(function()
        pcall(Rope.CreatePlayerClone, serverId, ped)
        cloneTrying[serverId] = nil
    end)
end

-- A take car's copy (whip_core's Experimental recorded drives sync)
-- A Director car playing a take is shown on this game as a copy only this game has, the real one hidden underneath. A
-- rope tied to the real car is drawn on the copy while it is there (client/physics.lua's ResolveEndAnchor).

--- Copies that have gone, forgotten (a handle is reused: a new car must not be taken for a copy).
local function forgetGoneCopies()
    for copy, real in pairs(Rope.CopyOf) do
        if not DoesEntityExist(copy) then
            Rope.CopyOf[copy] = nil
            if Rope.Copies[real] == copy then Rope.Copies[real] = nil end
        end
    end
end

--- Each rope end tied to this real car (or to its old copy), found again: on its copy now.
local function retieTo(real)
    for _, rope in pairs(Rope.System.ropes) do
        for _, which in ipairs({ 'origin', 'tail' }) do
            if rope[which .. 'Type'] == 'vehicle' and rope[which .. 'NetId'] then
                local e = rope[which .. 'Entity']
                if e == real or (e and Rope.CopyOf[e] == real) then Rope.ResolveEndEntity(rope, which) end
            end
        end
    end
end

AddEventHandler('whip_core:vehicle:copied', function(e)
    if type(e) ~= 'table' then return end
    local copy, real = tonumber(e.entity), tonumber(e.of)
    if not copy or not real or not DoesEntityExist(copy) then return end
    forgetGoneCopies()
    Rope.Copies[real], Rope.CopyOf[copy] = copy, real
    retieTo(real)
end)

--- A copy this rope end was on has gone (its take is over): forgotten, and the end on the real car again. Answers what
--- the end is on now, or nil.
function Rope.CopyGone(rope, which, copy)
    local real = Rope.CopyOf[copy]
    Rope.CopyOf[copy] = nil
    if real and Rope.Copies[real] == copy then Rope.Copies[real] = nil end
    return Rope.ResolveEndEntity(rope, which)
end

local function watch()
    if next(Rope.CopyOf) then forgetGoneCopies() end
    local playerPos = GetEntityCoords(PlayerPedId())
    for _, rope in pairs(Rope.System.ropes) do
        Rope.EnsureRopeProps(rope)
        for _, which in ipairs({ 'origin', 'tail' }) do
            local t = rope[which .. 'Type']
            if t == 'vehicle' or t == 'object' then
                local entity = rope[which .. 'Entity']
                if not (entity and DoesEntityExist(entity)) then
                    entity = Rope.ResolveEndEntity(rope, which)
                    if entity then
                        rope[which .. 'MissingSince'] = nil
                    elseif t == 'object' and not rope[which .. 'NetId']
                        and rope.isLocallyOwned and rope.serverRopeId then
                        local worldPos = rope[which .. 'WorldPos']
                        -- A verdict only from near enough for the prop to be streamed in
                        if worldPos and #(playerPos - worldPos) < 100.0 then
                            ReportLostEnd(rope, which)
                        end
                    elseif t == 'vehicle' and not rope[which .. 'NetId'] and rope.serverRopeId
                        and rope[which .. 'LocalTo'] == Rope.MyServerId() then
                        local since = rope[which .. 'MissingSince'] or GetGameTimer()
                        rope[which .. 'MissingSince'] = since
                        if GetGameTimer() - since > LOCAL_CAR_GRACE_MS then ReportLostEnd(rope, which) end
                    end
                end
            end
        end
    end
    -- Hanging players whose stand-in could not be made yet (their ped was not here)
    local me = Rope.MyServerId()
    for serverId in pairs(Rope.HangingPlayers) do
        if serverId ~= me then Rope.EnsureClone(serverId) end
    end
end

CreateThread(function()
    while true do
        Wait(next(Rope.System.ropes) and 500 or Rope.Const.IDLE_MS)
        if next(Rope.System.ropes) then
            local ok, err = pcall(watch)
            if not ok then print(('[whip_rope] the rope watchdog failed: %s'):format(tostring(err))) end
        end
    end
end)
