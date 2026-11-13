--[[
    whip_rope — CLIENT STATE

    The one `Rope` namespace every client file shares (fxmanifest's order: state -> physics -> collision -> contact
    -> mesh -> visuals -> hang_ragdoll -> interaction -> sync -> drag -> keep -> ui -> main -> api).

    A rope (Rope.System.ropes[id]), built from what the server sends (client/interaction.lua Rope.AddRopeFromServer):
    {
        id = number,                  -- the server's id, and its key
        serverRopeId = number,        -- the same id (the name every message to the server uses)
        nodes = { { position, previousPosition, pinned, mass, invMass }, ... },
        linkLength = number,          -- metres between two nodes: the server's for this rope, as it was made
                                      -- (never Config.Rope's, which may have changed since: Rope.LinkLength)
        -- HOW IT IS DRAWN (client/visuals.lua, client/mesh.lua)
        lookStyle = 'segments' | 'gta' | 'balls' | nil, lookReady = boolean, propsLoading = boolean,
        props = { entity, ... },      -- 'balls': one per node (or more, along a spline)
        segments = { entity, ... },   -- 'segments': one rope piece per gap
        gtaRope = number|nil,         -- 'gta': GTA's rope, pinned along this one
        isLocallyOwned = boolean,     -- this game's player put it out
        ownerServerId = number,
        createdAt = number,

        -- ITS FIRST END ('origin') and ITS LAST ('tail'): the same fields, with that prefix
        originType = 'held' | 'free' | 'fixed' | 'vehicle' | 'object',
        originHeldBy = number|nil,    -- the server id of whoever holds it
        originPosition = vector3|nil, -- where a fixed end is
        originEntity = number|nil,    -- the car or prop it is tied to, on this game
        originNetId = number|nil,
        originOffset = vector3|nil,   -- where on it, in its own space
        originMass = number|nil,      -- read on this game: a car's handling, a prop's box (or originGivenMass)
        originGivenMass = number|nil, -- what a prop really weighs, from the resource that tied it (server/api.lua)
        originWorldPos = vector3|nil, -- a world prop's own spot (it has no network id)
        originObjectModel = number|nil,
        originObjectActivated = boolean, -- a world prop this game woke up to be dragged

        -- Its stored spring (the snap-back: client/physics.lua Rope.StepWorld)
        peakTension, prevTension, storedEnergy, isSnapBackActive,
    }
]]

Rope = {
    System = {
        ropes = {},              -- [serverRopeId] = rope
        recentExplosions = {},   -- { { position, time }, ... }
    },

    -- Who hangs off which rope: [serverId] = { serverRopeId, nodeIndex }
    HangingPlayers = {},

    -- How late this game sees the other end of a rope two games move (s): [serverRopeId] = s, from the server
    -- (server/keep.lua, client/keep.lua). Read by client/physics.lua's pullPoint.
    Lag = {},

    -- Where the OTHER game sees the tail from the origin on each of those ropes: [serverRopeId] = { v = vector3,
    -- at = when it came }, from that game through the server (client/keep.lua). client/physics.lua's sharedSpan
    -- meets it halfway.
    TheirSpan = {},

    -- Cars a Director take (a recorded drive) drives on this game: [netId] = true, from the server (server/keep.lua,
    -- client/keep.lua). The recording moves them: the rope never pulls one (client/physics.lua's bodyOf).
    Driven = {},

    -- This game's own copies of take cars (whip_core's Experimental recorded drives sync: the real car hidden here):
    -- [real car] = its copy, and CopyOf [copy] = the real car. A rope tied to the real car is drawn on its copy, and never
    -- pulls it (client/interaction.lua's Rope.ResolveEndEntity, client/physics.lua's bodyOf).
    Copies = {},
    CopyOf = {},

    -- The stand-in peds drawn for hanging players: [serverId] = { ped, realPed }. Ours, hanging as a ragdoll, is our
    -- real ped itself ({ ped = realPed, own = true }: client/visuals.lua), never deleted.
    Clones = {},

    -- We hang as a ragdoll, our own ped the body on the rope (client/interaction.lua HangPedOn)
    HangOwnBody = false,

    -- Who is about, looked at every Config.PlayerInteraction.PedCacheInterval
    PedCache = {
        peds = {},       -- { { ped, x, y, z }, ... }
        lastUpdate = 0,
        updateInterval = Config.PlayerInteraction.PedCacheInterval,
    },

    -- Read every step
    Const = {
        DAMPING = Config.Physics.Damping,
        CONSTRAINT_ITERATIONS = Config.Physics.ConstraintIterations,
        -- A 1/60 s step: the longest one step may be (a slower frame is split), and what every per-step number
        -- (the damping, a push, the friction) is tuned for: a step of another length scales them (Rope.StepScale).
        REF_DT = 1.0 / 60.0,
        MAX_STEPS = 4,   -- most steps in one frame: a longer hitch drops its backlog
        -- How long the slow loops (explosions, watchdog, drift, prompts) sleep while no rope exists.
        IDLE_MS = 1000,
    },

    Util = {},
    UI = {},   -- client/ui.lua: whip's prompts and the hint capsule

    -- The loop's frame number (client/main.lua): what is read once a frame is kept with it (Rope.AnchorThisFrame)
    Frame = 0,
}

local cachedServerId = nil
function Rope.MyServerId()
    if not cachedServerId then
        cachedServerId = GetPlayerServerId(PlayerId())
    end
    return cachedServerId
end

function Rope.Util.DebugPrint(...)
    if Config.Debug then
        print('[whip_rope]', ...)
    end
end

--- A toast through whip (nothing when whip_core is down).
function Rope.Util.Notify(msg, kind)
    Whip.call('Notify', msg, kind or 'info')
end

function Rope.GetRopeByServerId(serverRopeId)
    return Rope.System.ropes[serverRopeId]
end

function Rope.IsPlayerHanging()
    return Rope.HangingPlayers[Rope.MyServerId()] ~= nil
end

--- Is any rope here awake (client/main.lua's range check)? One that has not been checked yet counts as awake, and so does
--- one resting near us (it is looked at every frame for what could move it). With every rope asleep (all far away, a
--- hose left at its pump) nothing about them can change, so the loops slow down.
---@return boolean
function Rope.AnyAwake()
    for _, rope in pairs(Rope.System.ropes) do
        if rope.simulated ~= false then return true end
    end
    return false
end

--- A resting rope stepped again from the next frame (client/main.lua, A ROPE AT REST): for anything that moves its nodes
--- from outside the step (laid out afresh, another game's nudge).
function Rope.WakeRope(rope)
    rope.resting, rope.stillSince = nil, nil
end

--- The rope end this player holds: rope, its key, 'origin' | 'tail' — or nil. Read from the ropes
--- themselves so it can't go stale. Not a locked rope (a resource's, as a pump's hose: client/api.lua): its end is
--- that resource's thing in the hand, so holding it is not holding a rope (no slower walk, no prompts, never pulled
--- out of the hand: the resource's own rules are).
function Rope.MyHeld()
    local me = Rope.MyServerId()
    for key, rope in pairs(Rope.System.ropes) do
        if not (rope.opts and rope.opts.locked) then
            if rope.originType == 'held' and rope.originHeldBy == me then return rope, key, 'origin' end
            if rope.tailType == 'held' and rope.tailHeldBy == me then return rope, key, 'tail' end
        end
    end
    return nil
end

--- A player's ped on this game, or nil — never our own when they are out of range (GetPlayerFromServerId
--- answers -1 then, or 0 on Enhanced, and GetPlayerPed of either can be the local player: Whip.playerIndex).
function Rope.PedOf(serverId)
    if serverId == Rope.MyServerId() then return PlayerPedId() end
    local player = Whip.playerIndex(serverId)
    if not player then return nil end
    local ped = GetPlayerPed(player)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
    return ped
end
