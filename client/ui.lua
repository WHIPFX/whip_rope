--[[
    whip_rope — WHIP'S PROMPTS, THE F1 WHEEL AND THE HINT CAPSULE

    * Near a rope: a prompt on each end that is not held (pick it up, or untie it) and one on the
      rope itself, on the node nearest you (hang on). Put up within 15 m of a rope, taken down past 22.
    * Holding an end: a prompt WHERE YOU LOOK on the car or prop you aim at, or on the map itself (a wall, the
      ground: whip's aimBox), to tie the end exactly there; and on the F1 wheel, put it down, let it go, or coil
      the rope up.
    * The hint capsule says what you can do while you hold an end or hang off the rope.

    All of it is whip_core's, so it is registered again whenever whip_core starts (Whip.register).
]]

local GROUP = 'whip_rope'
local NEAR, FAR = 15.0, 22.0     -- a rope's prompts go up within NEAR of you, and down past FAR
-- whip catches a moving prompt up only while you are within its sight (5 m, and 2 to spare) of where it
-- last knew it: one whose end moved REMOUNT_DRIFT from where it went up, with you further than
-- REMOUNT_AWAY from that spot, is put up again where its end is
local REMOUNT_DRIFT, REMOUNT_AWAY = 3.0, 6.0

local COIL_TIMEOUT_MS = 10000     -- after the bar's own length, if the server never answered

-- The hint capsule's words, for the device in the player's hands: the prompt's key is whip's
-- (AcceptHint: [E], or A's picture), letting go is jump (KeyHint: Space, or X on a pad), and on a pad
-- the wheel is on whichever button the player's layout has it (GetPadActionButton), named if none.
local function holdText()
    local accept = Whip.core:AcceptHint()
    accept = type(accept) == 'string' and accept or '[E]'
    if Whip.core:IsControllerActive() == true then
        local slot, pictures = Whip.core:GetPadActionButton('radial')
        local wheel = (type(slot) == 'string' and type(pictures) == 'string') and (pictures .. ' Wheel') or 'Wheel'
        return 'Holding a rope end  |  ' .. accept .. ' Tie it where you look  |  ' .. wheel .. ': put it down, let go or coil up'
    end
    return 'Holding a rope end  |  ' .. accept .. ' Tie it where you look  |  [F1] Put it down, let go or coil up'
end
local function hangText()
    local letGo = Whip.core:KeyHint('Space', 'x')
    return 'Hanging on a rope  |  ' .. (type(letGo) == 'string' and letGo or '[Space]') .. ' Let go'
end

local up = false                  -- whip_core is up and has our wheel entries
local mounted = {}                -- [ropeId] = { origin = vector3, tail = vector3, hang = vector3|nil }: where each went up
local tieUp = false
local shownText = nil

-- ============================================================================
-- THE PROMPTS ON A ROPE
-- ============================================================================

local function endId(ropeId, which) return ('end:%d:%s'):format(ropeId, which) end
local function hangId(ropeId) return ('hang:%d'):format(ropeId) end

-- The middle node nearest the player (never an end)
local function nearestMidNode(rope)
    local me = GetEntityCoords(PlayerPedId())
    local best, bestPos = math.huge, nil
    for i = 2, #rope.nodes - 1 do
        local p = rope.nodes[i].position
        local d = #(me - p)
        if d < best then best, bestPos = d, p end
    end
    return bestPos
end

local function endAction(ropeId, which, pos)
    return {
        id = endId(ropeId, which),
        group = GROUP,
        at = {
            coords = pos,
            follow = function()
                local rope = Rope.System.ropes[ropeId]
                if not rope then return nil end
                local p = Rope.EndNode(rope, which).position
                return p.x, p.y, p.z
            end,
        },
        label = function()
            local rope = Rope.System.ropes[ropeId]
            local t = rope and rope[which .. 'Type']
            if t == 'vehicle' or t == 'object' or (t == 'fixed' and rope[which .. 'Tied']) then return 'Untie the rope' end
            return 'Pick up the rope end'
        end,
        icon = 'pickup',
        reach = Config.Grab.GrabRadius,
        require = { vehicle = 'out' },
        canInteract = function() return Rope.CanTakeEnd(ropeId, which) end,
        onSelect = function() Rope.TakeEnd(ropeId, which) end,
    }
end

local function hangAction(ropeId, pos)
    return {
        id = hangId(ropeId),
        group = GROUP,
        at = {
            coords = pos,
            follow = function()
                local rope = Rope.System.ropes[ropeId]
                local p = rope and nearestMidNode(rope)
                if not p then return nil end
                return p.x, p.y, p.z
            end,
        },
        label = 'Hang on the rope',
        reach = Config.PlayerHang.GrabRadius,
        require = { vehicle = 'out' },
        canInteract = function() return Rope.CanHang(ropeId) end,
        onSelect = function() Rope.HangOnRope(ropeId) end,
    }
end

local function unmountRope(ropeId)
    if not mounted[ropeId] then return end
    mounted[ropeId] = nil
    Whip.core:RemoveAction(endId(ropeId, 'origin'))
    Whip.core:RemoveAction(endId(ropeId, 'tail'))
    Whip.core:RemoveAction(hangId(ropeId))
end

local function mountEnd(ropeId, rope, which, m)
    local p = Rope.EndNode(rope, which).position
    if Whip.core:AddAction(endAction(ropeId, which, p)) then m[which] = p end   -- the id, or false and why
end

local function mountHang(ropeId, rope, m)
    local p = Config.PlayerHang.Enabled and nearestMidNode(rope)
    if not p then return end
    if Whip.core:AddAction(hangAction(ropeId, p)) then m.hang = p end
end

local function maintainPrompts()
    for ropeId in pairs(mounted) do
        if not Rope.System.ropes[ropeId] then unmountRope(ropeId) end
    end
    local me = GetEntityCoords(PlayerPedId())
    for ropeId, rope in pairs(Rope.System.ropes) do
        if rope.serverRopeId and not (rope.opts and rope.opts.locked) then   -- a locked rope offers nothing: its resource's
            local nodes = rope.nodes
            local o, t = nodes[1].position, nodes[#nodes].position
            local d = math.min(#(me - o), #(me - t), #(me - nodes[math.ceil(#nodes / 2)].position))
            local m = mounted[ropeId]
            if not m and d < NEAR then
                m = {}
                mounted[ropeId] = m
                mountEnd(ropeId, rope, 'origin', m)
                mountEnd(ropeId, rope, 'tail', m)
                mountHang(ropeId, rope, m)
            elseif m and d > FAR then
                unmountRope(ropeId)
            elseif m then
                local function stale(at, now)
                    return not at or (#(at - now) > REMOUNT_DRIFT and #(me - at) > REMOUNT_AWAY)
                end
                if stale(m.origin, o) then mountEnd(ropeId, rope, 'origin', m) end
                if stale(m.tail, t) then mountEnd(ropeId, rope, 'tail', m) end
                local mid = Config.PlayerHang.Enabled and nearestMidNode(rope)
                if mid and stale(m.hang, mid) then mountHang(ropeId, rope, m) end
            end
        end
    end
end

--- Rope.DeleteRope's call: its prompts go with it.
function Rope.UI.OnRopeRemoved(ropeId)
    if up then unmountRope(ropeId) else mounted[ropeId] = nil end
end

-- ============================================================================
-- WHILE HOLDING AN END: TIE IT WHERE YOU LOOK
-- ============================================================================
-- On the car or prop you aim at, on its box, exactly where the look meets it; or, with Config.Rules.TieToMap, on
-- the map itself (a wall, a rock, the ground: whip's aimBox 'world'), where the look meets it. Only while an end is
-- in your hand: while it exists whip casts a ray every frame.

--- What the tie prompt is on: cars and props, and the map while ropes may be tied to it (the kinds are the prompt's
--- own, so a change of the rule puts the prompt up again: below)
local function tieKinds()
    if Config.Rules.TieToMap ~= false then return { 'vehicle', 'object', 'world' } end
    return { 'vehicle', 'object' }
end

local TIE = {
    id = 'tie',
    group = GROUP,
    at = { aimBox = tieKinds() },
    label = function(ctx)
        if ctx and ctx.entity and IsEntityAVehicle(ctx.entity) then return 'Tie the rope to it' end
        return 'Tie the rope here'
    end,
    icon = 'place',
    reach = Config.Rules.Reach,   -- as it is when the prompt goes up; a change in /whip → Settings below
    require = { vehicle = 'out' },
    canInteract = function(ctx) return Rope.CanTieTo(ctx and ctx.entity, ctx and ctx.world) end,
    onSelect = function(ctx) Rope.TieHeldEnd(ctx.entity, ctx.coords, ctx.world, ctx.normal) end,
}

-- ============================================================================
-- THE F1 WHEEL (always there, offered only when it applies)
-- ============================================================================

local function holding() return Rope.MyHeld() ~= nil end

local WHEEL = {
    {
        id = 'wheel:putDown', at = { radial = true }, group = GROUP,
        label = 'Put the rope end down', icon = 'place',
        description = 'Lay the end you hold on the ground here',
        canInteract = holding,
        onSelect = function() Rope.PutDownHeldEnd() end,
    },
    {
        id = 'wheel:letGo', at = { radial = true }, group = GROUP,
        label = 'Let go of the rope end', icon = 'back',
        description = 'Drop it where it hangs',
        canInteract = holding,
        onSelect = function() Rope.LetGoHeldEnd() end,
    },
    {
        id = 'wheel:coil', at = { radial = true }, group = GROUP,
        label = 'Coil up the rope', icon = 'pickup',
        description = 'Back into your pockets',
        canInteract = function()
            local rope = Rope.MyHeld()
            if not rope or Rope.Coiling then return false end
            return Config.Rules.AnyoneCanHandle or rope.ownerServerId == Rope.MyServerId()
        end,
        onSelect = function() Rope.CoilHeldRope() end,
    },
    {
        id = 'wheel:unhang', at = { radial = true }, group = GROUP,
        label = 'Let go of the rope', icon = 'back',
        description = 'Drop off the rope you hang from',
        canInteract = function() return Rope.IsPlayerHanging() end,
        onSelect = function() Rope.DetachPlayerFromRope() end,
    },
}

-- ============================================================================
-- THE LOOP: the hold's walk and tie prompt, the hint capsule, the rope prompts
-- ============================================================================

local function tick(withPrompts)
    -- A held end pulled: dragged along behind a car going away, or out of your hands (client/drag.lua)
    Rope.CheckHeldEnds()
    local rope = Rope.MyHeld()

    Rope.SetHoldingWalk(rope ~= nil)
    if not up then return end

    local wantTie = rope ~= nil and rope.serverRopeId ~= nil
    if wantTie ~= tieUp then
        if wantTie then
            TIE.reach = Config.Rules.Reach
            TIE.at = { aimBox = tieKinds() }
            tieUp = Whip.core:AddAction(TIE) and true or false
        else
            Whip.core:RemoveAction('tie')
            tieUp = false
        end
    end

    -- A coil the server never answered stops holding the capsule back
    if Rope.Coiling and GetGameTimer() - Rope.Coiling > (Config.Item.CoilDuration or 3000) + COIL_TIMEOUT_MS then
        Rope.Coiling = false
    end

    local text = nil
    if Rope.IsPlayerHanging() then
        text = hangText()
    elseif rope and not Rope.Coiling then
        text = holdText()
    end
    if text ~= shownText then
        if text then
            Whip.core:ShowText(text, { icon = 'pickup' })
        else
            Whip.core:HideText()
        end
        shownText = text
    end

    if withPrompts then maintainPrompts() end
end

CreateThread(function()
    local n = 0
    while true do
        -- No rope anywhere and nothing of ours left up: nothing here can change, so a longer sleep
        Wait((next(Rope.System.ropes) or shownText or tieUp or next(mounted)) and 200 or Rope.Const.IDLE_MS)
        n = n + 1
        local ok, err = pcall(tick, n % 3 == 0)
        if not ok then print(('[whip_rope] the prompt loop failed: %s'):format(tostring(err))) end
    end
end)

-- ============================================================================
-- WHIP COMING
-- ============================================================================
-- (Going needs nothing: whip_core stopping stops whip_rope first, its dependency, and both start fresh.)

Whip.register(function()
    -- whip_core is ready: our prompts, our walk and our text from here on
    up = true
    mounted, tieUp, shownText = {}, false, nil
    Rope.ForgetHoldingWalk()
    for _, def in ipairs(WHEEL) do
        exports.whip_core:AddAction(def)
    end
end)

-- Reach changed in /whip → Settings: apply it to the tie prompt at once
Whip.onConfigChanged('Rules.Reach', function(value)
    TIE.reach = tonumber(value) or TIE.reach
    if tieUp then Whip.core:UpdateAction('tie', { reach = TIE.reach }) end
end)

-- Tying to the map turned on or off in /whip → Settings: a tie prompt up now is put up again with it (or without)
Whip.onConfigChanged('Rules.TieToMap', function()
    if tieUp then
        Whip.core:RemoveAction('tie')
        TIE.at = { aimBox = tieKinds() }
        tieUp = Whip.core:AddAction(TIE) and true or false
    end
end)

-- Hanging turned off in /whip → Settings: whoever hangs lets go (a hang already on is never left
-- half-drawn by the setting)
Whip.onConfigChanged('PlayerHang.Enabled', function(value)
    if value == false and Rope.IsPlayerHanging() then Rope.DetachPlayerFromRope() end
end)

-- Dying or logging out lets go; the server does its own side (whip_core:player:died / :logout)
AddEventHandler('whip_core:player:died', function()
    if Rope.IsPlayerHanging() then Rope.DetachPlayerFromRope(false) end
end)
AddEventHandler('whip_core:player:logout', function()
    if Rope.IsPlayerHanging() then Rope.DetachPlayerFromRope(false) end
end)
