--[[
    whip_rope — A RESOURCE'S ROPE, ON THIS GAME

    How a rope a resource made (server/api.lua) behaves here, from its `opts`:

      locked    nobody grabs, ties, coils or hangs off it: no prompts, and holding its end is not holding a rope
                (client/state.lua MyHeld, client/ui.lua, client/interaction.lua)
      look      its own pieces (client/visuals.lua, client/mesh.lua), loaded here before it is drawn
      collide   its own probing of the world (client/collision.lua)
      heldAt    a held end sits on the prop of that model in the hand (a nozzle's back), not the hand itself
                (client/physics.lua asks Rope.HeldPropEnd)
      watch     pulled past `stretch` for `holdMs`, said to the server (whip_rope:stretched) by the game that runs
                one of its ends — a car or prop's owner, or the player holding it; a map prop it is tied to blown up
                (`broken`), said by a game near it (whip_rope:endBroken). The server checks, and tells its resource.
]]

local WATCH_TICK_MS = 100
local HELD_LOOK_MS = 500   -- a hand with no such prop found in it is looked in again after this

--- Its own look's models in memory before it is drawn (client/interaction.lua's Rope.EnsureRopeProps): client/visuals.lua
--- draws in its own look only when loaded, and the rope's own when it will not load, so one drawn before they load
--- keeps the rope's own pieces for good. Waits: from a thread.
function Rope.LoadOwnLook(rope)
    local look = rope.opts and rope.opts.look
    if not look then return end
    for _, model in ipairs({ look.model, look.modelNoShadow }) do
        if model and IsModelInCdimage(model) and not HasModelLoaded(model) then Whip.call('LoadModel', model) end
    end
end

--- The model a rope's pieces are drawn in: its own look's (with shadows, or the no-shadow one when the rope's are
--- off: Visuals.SegmentShadows), or nil for the rope's own.
function Rope.OwnLookModel(rope)
    local look = rope.opts and rope.opts.look
    if not look then return nil end
    if Config.Visuals.SegmentShadows == false and look.modelNoShadow then return look.modelNoShadow end
    return look.model
end

--- Where a held end is, for a rope with `heldAt`: on the prop of that model in `heldBy`'s hand (on every game, tied
--- to the hand), at its offset — or nil when this game has none on them (the hand then, client/physics.lua). The prop
--- found is kept on the rope while it is still on that player.
function Rope.HeldPropEnd(rope, heldBy)
    local at = rope.opts and rope.opts.heldAt
    local ped = at and heldBy and Rope.PedOf(heldBy)
    if not ped then return nil end
    local n = rope.heldProp
    if not (n and DoesEntityExist(n) and IsEntityAttachedToEntity(n, ped)) then
        rope.heldProp = nil
        local now = GetGameTimer()
        if rope.heldPropLookAt and now < rope.heldPropLookAt then return nil end
        rope.heldPropLookAt = now + HELD_LOOK_MS
        local hand = GetWorldPositionOfEntityBone(ped, GetPedBoneIndex(ped, 57005))
        n = GetClosestObjectOfType(hand.x, hand.y, hand.z, 0.6, at.model, false, false, false)
        if not n or n == 0 or not IsEntityAttachedToEntity(n, ped) then return nil end
        rope.heldProp = n
    end
    local o = at.offset
    return GetOffsetFromEntityInWorldCoords(n, o.x + 0.0, o.y + 0.0, o.z + 0.0)
end

--- The car or prop a rope's end is tied to on this game, or nil (not tied to one, not streamed in here yet, or no such
--- rope here). An end moved with SetRopeEnd (server/api.lua) has reached this game once this answers the new one.
---@param id number   the rope's id, as CreateRope gave it
---@param which string 'origin' | 'tail'
---@return number|nil entity
exports('GetRopeEndEntity', function(id, which)
    local rope = Rope.GetRopeByServerId(tonumber(id))
    if not rope or (which ~= 'origin' and which ~= 'tail') then return nil end
    local entity = rope[which .. 'Entity']
    if entity and DoesEntityExist(entity) then return entity end
    return nil
end)

--- Does this game run one of the rope's ends (and so say how it is pulled)? A car or networked prop it owns, or a
--- hand that is this player's.
local function runsAnEnd(rope)
    local me = Rope.MyServerId()
    for _, which in ipairs({ 'origin', 'tail' }) do
        local t = rope[which .. 'Type']
        if t == 'held' and rope[which .. 'HeldBy'] == me then return true end
        local ent = (t == 'vehicle' or t == 'object') and rope[which .. 'Entity']
        if ent and DoesEntityExist(ent) and NetworkGetEntityIsNetworked(ent) and NetworkGetEntityOwner(ent) == PlayerId() then
            return true
        end
    end
    return false
end

-- The watch: one thread, ten times a second, for every watched rope here (resting while no rope is awake: asleep, far
-- away, a rope's stretch and its map props cannot change)
CreateThread(function()
    local since, told, brokenTold = {}, {}, {}
    while true do
        Wait(Rope.AnyAwake() and WATCH_TICK_MS or Rope.Const.IDLE_MS)
        local now = GetGameTimer()
        for key, rope in pairs(Rope.System.ropes) do
            local w = rope.opts and rope.opts.watch
            if w and rope.serverRopeId then
                -- Pulled past its stretch, held that long
                if w.stretch and runsAnEnd(rope) then
                    local nodes = rope.nodes
                    local length = (#nodes - 1) * Rope.LinkLength(rope)
                    local stretch = #(nodes[1].position - nodes[#nodes].position) / length - 1.0
                    if stretch > w.stretch then
                        since[key] = since[key] or now
                        if now - since[key] >= (w.holdMs or 250) and (not told[key] or now - told[key] > 3000) then
                            told[key] = now
                            TriggerServerEvent('whip_rope:stretched', rope.serverRopeId)
                        end
                    else
                        since[key] = nil
                    end
                else
                    since[key] = nil
                end
                -- A map prop an end is tied to, blown up where it stands
                if w.broken then
                    local toldAt = brokenTold[key] or {}
                    brokenTold[key] = toldAt
                    for _, which in ipairs({ 'origin', 'tail' }) do
                        local ent = rope[which .. 'Type'] == 'object' and not rope[which .. 'NetId'] and rope[which .. 'Entity']
                        if ent and DoesEntityExist(ent) and HasObjectBeenBroken(ent) then
                            if not toldAt[which] or now - toldAt[which] > 3000 then
                                toldAt[which] = now
                                TriggerServerEvent('whip_rope:endBroken', rope.serverRopeId, which)
                            end
                        else
                            toldAt[which] = nil
                        end
                    end
                end
            end
        end
        for key in pairs(since) do if not Rope.System.ropes[key] then since[key], told[key] = nil, nil end end
        for key in pairs(brokenTold) do if not Rope.System.ropes[key] then brokenTold[key] = nil end end
    end
end)
