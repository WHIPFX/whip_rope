--[[
    whip_rope settings. A rope is an item players tie to cars and props; a taut rope pulls what it is tied to, and
    players can hang off it. It is a chain of nodes simulated every frame on every game near it. The settings most
    servers change are also on /whip → Settings → Rope; the rest are here only.
]]

Config = {}

-- The item

Config.Item = {
    Name = 'rope',              -- the item's key (whip_core's item list)
    Label = 'Rope',
    Weight = 2.0,               -- kg
    MaxStack = 5,

    -- How long coiling a rope back up takes (ms); it goes back to the coiler's pockets as an item.
    CoilDuration = 3000,

    -- A player who logs out (or disconnects) with ropes out gets them back as items.
    -- false: their ropes are simply gone.
    GiveBackOnLogout = true,
}

-- Who may do what

Config.Rules = {
    -- Anyone may grab, untie, hang off or coil up anyone's rope. false: only the
    -- player who put the rope out may grab, untie or coil it up (anyone may still hang off it).
    AnyoneCanHandle = true,

    -- Tying a rope to a car needs that car's keys (whip's vehicle keys). false: any car.
    NeedKeysToTie = false,

    -- A rope can be tied to the map itself (a wall, a rock, the ground). false: only to cars and props.
    TieToMap = true,

    -- How far a player can be from what they tie to (metres); the server checks again with a little more.
    Reach = 3.0,
}

-- While you hold an end (letting go gives back sprinting and the player's own walk)

Config.Holding = {
    -- The fastest a player may go with a rope end in hand:
    --   'walk'   walk only (no jog, no sprint)
    --   'jog'    walk or jog, never sprint
    --   'sprint' any speed, as usual
    Speed = 'jog',

    -- The walk while holding: GTA's movement clipset. 'missfbi4prepp1_garbageman' is "Trash 2" in the
    -- /walk list; 'clipset@move@trash_fast_turn' is "Trash". 'none': the player's own walk.
    WalkStyle = 'missfbi4prepp1_garbageman',
}

-- Dragged along: a player holding a rope whose other end is tied to a car or prop going away is pulled over once the
-- rope is stretched past Coupling.ElasticStretch, dragged for Seconds, then let go (at once if they die). Applies to
-- any rope, a pump's hose too.
Config.Drag = {
    Enabled = true,
    Seconds = 3.0,      -- how long the ride lasts before they let go
    MinSpeed = 2.0,     -- m/s: the other end must be going away at least this fast (slower, it is only pulled out of
                        -- the hands, a metre past the easy stretch)
    Pull = 6.0,         -- how hard they are pulled after it: m/s for every metre past the rope's length
    MaxSpeed = 18.0,    -- m/s: never pulled faster than the other end plus this
}

-- Debug

Config.Debug = false              -- prints, and the overlay (/ropedebug toggles it for yourself)
Config.DrawDebugLines = false     -- lines between the nodes
Config.DrawDebugSpheres = false   -- a sphere at each node

-- The rope itself

Config.Rope = {
    -- Total length in metres, and how many physics nodes it has. Keep Length / (SegmentCount - 1) near 0.25 m for a
    -- smooth rope. More nodes cost more on every game near the rope, and need more Physics.ConstraintIterations to
    -- stay stiff. A change counts for ropes put out after it.
    Length = 6,
    SegmentCount = 24,

    -- Most ropes one player may have out at once (the server holds them to it).
    MaxRopes = 5,

    -- Metres from you past which a rope is not simulated on your game (it waits where it is).
    -- One you hold or hang off, or one tied to a car your game drives, always is.
    SimulateRange = 120.0,
}

-- The gap between two nodes, worked out from the two above. Change Length or SegmentCount instead.
Config.Rope.SegmentLength = Config.Rope.Length / (Config.Rope.SegmentCount - 1)

-- A petrol pump's hose is whip_fuel's: a rope of the rope API (server/api.lua), set in whip_fuel's config.lua.

-- Physics (a step every frame: the same feel at any frame rate)

Config.Physics = {
    -- The most physics steps a second. 0: one every frame. A cap (120, say) saves a little on a very fast PC.
    MaxFps = 0,

    Gravity = vector3(0.0, 0.0, -9.8),

    -- Velocity kept per 1/60 s (1.0 = none lost, 0.9 = heavy damping). Every per-step number here is for a
    -- 1/60 s step and is scaled to the step's real length.
    Damping = 0.99,

    -- Constraint passes per step: more = a stiffer rope that stretches less under load
    ConstraintIterations = 16,

    -- A free node's mass (kg); it only weights the constraints
    DefaultNodeMass = 0.5,

    -- How straight the rope must be (end-to-end distance / its length along the nodes)
    -- before it pulls at all: a rope that visibly sags never tows.
    TautThreshold = 0.95,

    -- A taut rope that is let go springs back a little (snap-back)
    EnergyStorageEnabled = true,
    EnergyAccumulationRate = 0.8,
    EnergyDecayRate = 0.95,
    SnapBackMultiplier = 2.0,
    SnapBackThreshold = 0.3,
}

-- Looks

Config.Visuals = {
    RenderProps = true,

    -- How the rope is drawn:
    --   'segments'  rope pieces (whip_rope_seg), one per gap between nodes, stretched to fit
    --   'gta'       GTA's own rope, every vertex pinned along this one
    --   'balls'     a tennis ball per node
    Style = 'segments',

    -- 'segments': the piece's model, its own length (m), how thick (1 = 3.5 cm; X and Z alike) and how
    -- far neighbours overlap (0: the rounded caps meet on the node; more puts lumps on the bends)
    SegmentModel = `whip_rope_seg`,
    SegmentModelNoShadow = `whip_rope_seg_ns`,
    SegmentShadows = true,           -- false: the no-shadow model, a little cheaper
    SegmentLength = 0.25,
    SegmentThickness = 1.0,
    SegmentOverlap = 0.0,

    -- 'gta': which of GTA's rope types to pin
    GtaRopeType = 4,

    -- 'balls'
    PropModel = `prop_tennis_ball`,   -- a prop per node (backticks = its hash)
    RotateProps = false,              -- turn each prop along the rope (not needed for a ball)

    -- Points drawn per gap between nodes, along a smooth curve (all styles): 1 the nodes only
    SplineSamplesPerSegment = 1,
}

-- The world

-- What a rope's world checks see. The map is always checked. Props, cars and people can each be turned off for less
-- work on every game near a rope; the rope then passes through them. A change counts at once.
Config.WorldCollision = {
    CheckSpacing = 2,         -- check every Nth node (2 = every other; the ends always)
    GroundOffset = 0.05,      -- how far above the ground a node rests (m)
    GroundFriction = 0.7,     -- 0 = slides freely, 1 = stops dead
    WallOffset = 0.06,        -- how far from a wall a node stays (m)
    Props = true,             -- props and objects too (bins, crates, fences): the rope lies on them and stops against
                              -- them (a resource's rope can say its own)
    Vehicles = true,          -- cars too: the rope lies on them and slides off (a resource's rope can say its own)
    -- How a node finds the ground:
    --   'rays'  every CheckSpacing'th node casts a ray down, every step it moves
    --   'grid'  the ground is looked up once per point of a 25 cm grid and kept a while. Walls, cars and people use rays.
    Ground = 'rays',
}

-- Ropes against each other (client/contact.lua): one laid over another rests on it instead of passing through
Config.RopeContact = {
    Enabled = true,           -- false: ropes pass through each other (also on the settings page)
    Gap = 0.04,               -- how close two ropes come (m): about the rope's thickness
    Slide = 0.85,             -- the share of their slide along each other kept per 1/60 s (1 = slippery, 0 = they catch)
    -- Ropes take each other's weight (needs Enabled). Off: a rope on another only moves its points. On: a rope caught
    -- on another pulls what it is tied to along that bent path. Costs a little more where two ropes are close.
    Carry = false,
}

-- People walking or running through the rope push it about (players and NPCs alike)
Config.PlayerInteraction = {
    Enabled = true,           -- false: people walk straight through a rope (holding and hanging work either way)
    Radius = 0.5,
    WalkForce = 1.5,
    RunForce = 3.0,
    RagdollForce = 5.0,
    PedCacheInterval = 300,   -- ms between looks at who is about
}

-- Explosions throw it
Config.ExplosionInteraction = {
    Enabled = true,
    Radius = 15.0,
    Force = 20.0,
    Falloff = true,
}

-- Ends and hanging

Config.Grab = {
    GrabRadius = 1.5,   -- metres from an end its prompt is offered within
}

Config.PlayerHang = {
    Enabled = true,
    GrabRadius = 1.5,   -- metres from the rope its Hang prompt is offered within
    -- How heavy a hanging player is to the rope's solver (kg). Keep it small, or the rope stretches like a bungee.
    SolverMass = 5.0,
    -- Extra pull down on the node they hang from, in g, so the rope sags under them
    ExtraWeight = 2.0,
    -- Shot while hanging: they let go and fall, limp for this long (ms). false: a hanging player can't be hurt.
    ShotKnocksOff = true,
    ShotRagdollMs = 3000,

    -- How a hanging player looks (counts from the next time someone hangs):
    --   'ragdoll'    GTA's body physics: hanging from the rope by the right hand, swaying and swinging
    --   'animation'  a looped hanging animation
    Style = 'ragdoll',
    -- The ragdoll's behaviour: 'balance' (keeps trying to find its feet), 'relax' (limp) or 'script' (not for online use)
    RagdollTask = 'balance',
    -- The hand on the rope: 'free' (it can turn about the rope), 'settle' (free until the arm has swung up the rope,
    -- then held at that angle) or 'locked' (held at its angle the moment it grabs: the wrist can kink)
    Hand = 'free',
    -- The point on the rope it hangs from: 'frozen' (put on the rope every frame) or 'driven' (pushed after it, looser)
    Point = 'frozen',
    -- Which bone number of the hand the hold uses: 'ped' or 'ragdoll'. 'ped' is right; 'ragdoll' is there to try.
    TieBone = 'ped',
    -- GTA's Euphoria "grab" (hands closed on the rope) and "dangle" (body hanging) message numbers. 0: not sent, and
    -- only the right hand holds.
    GrabMessage = 0,
    DangleMessage = 0,
    -- With the grab on: 'right' or 'both' hands on the rope
    GrabHands = 'right',
}

-- Pulling (the rope tows what it is tied to)
-- An elastic rope: slack, it pulls nothing; taut, it stretches easily up to ElasticStretch, then its pull climbs. Both
-- ends feel the same tension, so a light car moves more than a heavy truck. Pulls are given as the acceleration they
-- give a BaseMass (1.5 t) car; a car's own is about 3-5 m/s².

Config.Coupling = {
    Enabled = true,

    -- How far the rope stretches easily, as a share of its length added (0.15: a 6 m rope to 6.9 m)
    ElasticStretch = 0.15,

    -- Its pull at that stretch (m/s² on a 1.5 t car), about a car's own acceleration.
    ElasticPull = 5.0,

    -- How the pull grows over that stretch: 1 evenly, higher softer at first
    ElasticCurve = 1.0,

    -- Past ElasticStretch the pull climbs: StiffPull more per metre past it (m/s² on a 1.5 t car), up to MaxAcceleration.
    StiffPull = 24.0,

    -- How that climb grows: 1 evenly, higher gentle at first and steeper the further it goes
    StiffCurve = 1.0,

    -- Share of its pull the rope gives back while springing back (0-1); the rest is lost, so a car settles.
    Rebound = 0.6,

    -- The same past the easy stretch: most of it is lost, so a car is pulled back, not flung back
    StiffRebound = 0.15,

    -- Pull taken away per m/s the ends close in, so it does not slingshot (m/s² on a 1.5 t car, per m/s)
    Damping = 0.7,

    -- The share of Damping used while the rope is stretching (towing always stretches it)
    YankAbsorb = 0.25,

    -- The damping may raise the pull to at most this times the rope's own
    MaxDampingBoost = 1.5,

    -- How fast the pull follows changes per step (0-1): up quickly, down gently
    ForceRise = 0.5,
    ForceFall = 0.3,

    -- The rope's strongest pull before the backstop (m/s²; 20 is about 2 g), measured on the lighter end.
    MaxAcceleration = 20.0,

    -- The most the rope may accelerate any one VEHICLE (m/s²): a light bike is yanked, not launched
    VehicleMaxAcceleration = 60.0,

    -- The most the rope may accelerate a prop (m/s²), so a light one is not fired off.
    PropMaxAcceleration = 20.0,

    -- The backstop: past this share of its length added (1.0: a 6 m rope at 12 m) the rope pulls harder, up to BackstopPull.
    MaxStretch = 1.0,

    -- How hard the backstop pulls at most (m/s², about 4 g at 40).
    BackstopPull = 40.0,

    -- Over how many metres past the backstop that pull comes in (it does not start all at once)
    BackstopRamp = 0.5,

    -- A rope with a hard length (a fuel pump's hose): what it drags comes back inside the length at most this much
    -- faster (m/s). Higher snaps it back sooner.
    HardCatchUp = 2.0,

    -- How far a rope with a hard length stretches at most, as times its own (2: a hose that holds at 30% past its
    -- length stops at 60%). Up to there its pull is BackstopPull on a BaseMass car; there it gets no longer.
    HardCeiling = 2.0,

    -- Pull back: once nothing holds a stretched rope open, it draws its ends back to slack at ReturnRate m/s per metre
    -- stretched, capped at ReturnSpeed, building at ReturnAccel; ReturnPull is the most it uses to get a braked car
    -- moving. false: no pull back.
    PullBack = true,
    ReturnSpeed = 3.0,     -- m/s (about 11 km/h)
    ReturnRate = 1.0,      -- m/s for each metre stretched
    ReturnAccel = 6.0,     -- m/s²
    ReturnPull = 30.0,     -- m/s²

    -- A towed car nobody is driving rolls freely: its handbrake is let off while the rope pulls it
    FreeRolling = true,

    -- No pull for this long after an end is tied (ms), so the rope settles first
    AttachGraceMs = 400,

    -- The most a player holding the other end pulls a car or prop by hand (m/s²).
    HandPull = 2.0,

    -- A car on all its wheels is pulled along the ground: only this share of an upward pull is kept. A rope steeper
    -- than SteepRope (a helicopter above) lifts it properly.
    GroundLift = 0.15,
    SteepRope = 0.7,

    -- The car every pull above is described for (1.5 t), and the mass assumed when unknown (kg). Changing it changes every pull.
    BaseMass = 1500.0,
}

-- Who moves what a rope pulls: the player pulling a rope (driving the car at one end, or holding it) is given what it
-- pulls and keeps it while they pull, so a towed thing follows their car at once. A driver beats a hand. false:
-- whoever GTA picked moves it.
-- Two driven cars on one rope are each moved by their own game, and each sees the other late. Between them the rope is
-- a strap: it pulls as it is stretched and gives nothing back once the two come together faster than SplitRelease.
-- Each game works out the pull from where the other car is by now: moved on by its speed over GuessShare of the lag
-- (0: where it is seen, 1: the whole lag). The games also tell each other where they see the far end and both pull
-- along the line halfway between.
-- With a helicopter or plane at one end, each vehicle is pulled AircraftTwist of the way out from its middle to the
-- tie point (1: at the tie point; 0: never twisted).
Config.Keep = {
    Enabled = true,
    SplitRelease = 0.5,   -- m/s
    GuessShare = 1.0,
    AircraftTwist = 0.1,
}

-- Keeping every game's rope alike

Config.Sync = {
    -- The rope's owner sends where a few key nodes are (someone hanging, a fast loose end)
    DriftEnabled = true,
    DriftRateMs = 250,
    DriftLerp = 0.25,   -- how hard other games pull theirs toward it (0-1)
}
