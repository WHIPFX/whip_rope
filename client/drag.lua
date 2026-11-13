--[[
    whip_rope — A HELD END, PULLED: DRAGGED ALONG, OR OUT OF YOUR HANDS

    Every rope end this player holds is looked at with the hold loop (client/ui.lua, Rope.CheckHeldEnds), a resource's
    locked rope too (a pump's hose):

      DRAGGED ALONG (Config.Drag). The other end is tied to a car or a prop going away from you faster than
        Drag.MinSpeed, and the rope is stretched past its easy stretch (Coupling.ElasticStretch): you fall and are
        pulled along behind it for Drag.Seconds, then let go — at once if you die. Only your own game moves you.

      OUT OF YOUR HANDS. Not that (you walked off from a post, or a car is creeping): a metre past the easy stretch,
        it leaves your hands. A rope of whip_rope's own only: it stretched without end, and sprang back at hundreds of
        metres a second when let go. A resource's rope stretches as far as its own rules let it.

    LETTING GO: a rope of whip_rope's own drops its end (as letting go by hand does). A resource's rope is the
    resource's to let go its own way: whip_rope:pulledFromHand (serverRopeId, which, resource) on this game.
]]

local dragging = nil      -- the rope this player is being dragged by, while it lasts
local dragAfter = {}      -- [serverRopeId] = no new ride on it before this game time (a resource that keeps the end)

local function other(which) return which == 'origin' and 'tail' or 'origin' end

--- Where each end of a rope is: its first node, its last.
local function endPos(rope, which)
    local n = rope.nodes
    return which == 'origin' and n[1].position or n[#n].position
end

--- The rope's length along its nodes, and how far it stretches easily.
local function lengths(rope)
    local length = Rope.LinkLength(rope) * (#rope.nodes - 1)
    return length, length * (1.0 + (Config.Coupling.ElasticStretch or 0.15))
end

--- The car or prop at the other end, while it is here, or nil (a post, a hand, the ground).
local function otherEntity(rope, which)
    local o = other(which)
    local t = rope[o .. 'Type']
    if t ~= 'vehicle' and t ~= 'object' then return nil end
    local e = rope[o .. 'Entity']
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

--- How fast `entity` is going away from `from` (m/s along the line between them; negative: coming closer).
local function goingAway(entity, from)
    local at = GetEntityCoords(entity)
    local d = at - from
    local dist = #d
    if dist < 0.01 then return 0.0 end
    local v = GetEntityVelocity(entity)
    return (v.x * d.x + v.y * d.y + v.z * d.z) / dist
end

--- Is this player still holding that end?
local function stillHeld(rope, which)
    return Rope.System.ropes[rope.serverRopeId] == rope and rope[which .. 'Type'] == 'held'
        and rope[which .. 'HeldBy'] == Rope.MyServerId()
end

--- Let go of that end: whip_rope's own rope drops it; a resource's is told so on this game.
local function letGo(rope, which, said)
    if not stillHeld(rope, which) then return end
    if rope.opts and rope.opts.locked then
        dragAfter[rope.serverRopeId] = GetGameTimer() + 5000
        TriggerEvent('whip_rope:pulledFromHand', rope.serverRopeId, which, rope.resource)
    elseif Rope.LetGoHeldEnd() and said then
        Rope.Util.Notify(said, 'info')
    end
end

--- Dead, on this game's word or whip's.
local function isDead(ped)
    if IsPedDeadOrDying(ped, true) then return true end
    if not Whip.isReady() then return false end
    local ok, dead = pcall(function() return exports.whip_core:IsPlayerDead() end)
    return ok and dead == true
end

--- The ride: fallen and pulled after the other end, every frame, till Drag.Seconds are up or they die. Then let go.
local function drag(rope, which, entity)
    dragging = rope
    CreateThread(function()
        local untilAt = GetGameTimer() + math.max(0.0, tonumber(Config.Drag.Seconds) or 3.0) * 1000
        local length = lengths(rope)
        local pullPer = tonumber(Config.Drag.Pull) or 6.0
        local most = tonumber(Config.Drag.MaxSpeed) or 18.0
        local deadCheckAt = 0
        while GetGameTimer() < untilAt and stillHeld(rope, which) do
            local ped = PlayerPedId()
            local now = GetGameTimer()
            if now >= deadCheckAt then
                deadCheckAt = now + 250
                if isDead(ped) then break end
            end
            -- Down, and kept down
            if not IsPedRagdoll(ped) then SetPedToRagdoll(ped, 1000, 1000, 0, false, false, false) end
            ResetPedRagdollTimer(ped)
            -- After it: past the rope's length, towards where it is tied, at its speed and then some
            if DoesEntityExist(entity) then
                local me = GetEntityCoords(ped)
                local d = endPos(rope, other(which)) - me
                local dist = #d
                if dist > length and dist > 0.01 then
                    local dir = d / dist
                    local ov = GetEntityVelocity(entity)
                    local want = ov + dir * math.min(most, (dist - length) * pullPer)
                    local cur = GetEntityVelocity(ped)
                    local v = cur + (want - cur) * 0.3
                    SetEntityVelocity(ped, v.x, v.y, math.max(v.z, cur.z))
                end
            end
            Wait(0)
        end
        dragging = nil
        letGo(rope, which, nil)
    end)
end

--- Every end this player holds, looked at (the hold loop, five times a second).
function Rope.CheckHeldEnds()
    if dragging then return end
    local me = Rope.MyServerId()
    local now = GetGameTimer()
    for _, rope in pairs(Rope.System.ropes) do
        if rope.serverRopeId and rope.simulated ~= false then
            for _, which in ipairs({ 'origin', 'tail' }) do
                if rope[which .. 'Type'] == 'held' and rope[which .. 'HeldBy'] == me then
                    local _, easy = lengths(rope)
                    local stretched = #(endPos(rope, 'tail') - endPos(rope, 'origin'))
                    local entity = otherEntity(rope, which)
                    if Config.Drag.Enabled ~= false and entity and stretched > easy
                        and now >= (dragAfter[rope.serverRopeId] or 0)
                        and goingAway(entity, endPos(rope, which)) > (tonumber(Config.Drag.MinSpeed) or 2.0) then
                        drag(rope, which, entity)
                        return
                    end
                    if not (rope.opts and rope.opts.locked) and stretched > easy + 1.0 then
                        letGo(rope, which, 'The rope was pulled out of your hands')
                        return
                    end
                end
            end
        end
    end
    for id, at in pairs(dragAfter) do
        if now >= at then dragAfter[id] = nil end
    end
end
