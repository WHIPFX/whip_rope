-- ============================================
-- whip_rope — the settings page in /whip → Settings → Rope
-- ============================================
-- What an owner changes, as a page in game (Whip.configPage). config.lua is the default; saved values win
-- and are written into Config on both sides, and take effect at once. How the rope pulls, moves and looks,
-- and how a player hangs off it, are config.lua's alone: tuned together, and changed together there.
-- The rope's length and node count are for ropes put out after a change. The server gives each rope its own
-- node count and link length as it is made (server/item.lua), and every game builds and simulates the rope
-- from those (client/interaction.lua), never from Config: a rope already out keeps its size on every game,
-- one that joins or comes near later too.
-- What a rope bumps into (props, cars, people) is read where its checks run (client/collision.lua), so a change
-- counts at once, for ropes already out too. The map is always checked: there is no setting for it.

-- The gap between two nodes is worked out from the length and the count (config.lua): again when either changes.
local function relink()
    Config.Rope.SegmentLength = Config.Rope.Length / (Config.Rope.SegmentCount - 1)
end
Whip.onConfigChanged('Rope.Length', relink)
Whip.onConfigChanged('Rope.SegmentCount', relink)

Whip.configPage({
    label = 'Rope',
    groups = {
        { label = 'Rope', settings = {
            { key = 'Rope.Length', type = 'number', min = 2, max = 30, step = 0.5, unit = 'm', label = 'Rope length',
              help = 'How long a rope is, end to end. Ropes put out from now on are this long; a rope already out keeps the length it was made with. Change Rope nodes with it: about 4 nodes for every metre looks best.' },
            { key = 'Rope.SegmentCount', type = 'int', min = 8, max = 64, label = 'Rope nodes',
              help = 'How many points a rope is made of. More nodes make a smoother, higher quality rope that bends and lies more naturally, at a cost in performance: every node is worked out on the game of every player near the rope, every frame. About 4 for every metre looks best (24 for a 6 m rope). Counts for ropes put out from now on; a rope already out keeps the nodes it was made with.' },
            { key = 'Rules.AnyoneCanHandle', type = 'bool', label = 'Anyone can handle any rope',
              help = 'Off: only the player who put a rope out may grab, untie or coil it up. Anyone may still hang off it.' },
            { key = 'Rules.NeedKeysToTie', type = 'bool', label = 'Tying to a car needs its keys' },
            { key = 'Rules.TieToMap', type = 'bool', label = 'Ropes can be tied to the map',
              help = 'Holding a rope end, look at a wall, a rock or the ground and tie it there: it stays put, like a post. Off: ropes tie only to cars and props (an end can still be put down on the ground).' },
            { key = 'Rules.Reach', type = 'number', min = 1, max = 6, step = 0.5, unit = 'm', label = 'Tying reach',
              help = 'How far away a car, prop or spot on the map can be tied to (the server allows a little more). Picking up an end and hanging on are config.lua\'s Grab.GrabRadius and PlayerHang.GrabRadius.' },
            { key = 'Rope.MaxRopes', type = 'int', min = 1, max = 20, label = 'Ropes out per player' },
            { key = 'Item.GiveBackOnLogout', type = 'bool', label = 'Give ropes back on logout',
              help = 'A player who logs out or disconnects with ropes out gets them back as items.' },
            { key = 'Coupling.FreeRolling', type = 'bool', label = 'Towed cars roll freely',
              help = 'A towed car nobody is driving has its handbrake let off while the rope pulls it.' },
            { key = 'Keep.Enabled', type = 'bool', label = 'The puller moves what it pulls',
              help = 'The player driving the car at one end of a rope (or holding it) is given what the rope pulls, so it follows their car straight away. Off: whoever the game picked moves it, from a late picture of the car, and a towed thing can throw the car it hangs off. Two cars someone drives each keep their own either way.' },
            { key = 'Physics.MaxFps', type = 'int', min = 0, max = 500, step = 10, unit = 'a second',
              label = 'Rope physics: most updates',
              help = '0: once every frame, so the rope moves in time with the hands, cars and bodies on it. A cap (120, say) saves a little on a very fast PC: past it, the rope moves every few frames. Under 60 fps, each frame is worked out in steps of 1/60 s.' },
        } },
        { label = 'What the rope bumps into', settings = {
            { key = 'WorldCollision.Props', type = 'bool', label = 'Props and objects',
              help = 'Ropes lie on props and stop against them: bins, crates, barriers, fences. Off can improve performance, as every game near a rope checks less, but the rope looks less real: it passes straight through them. The ground, roads and buildings are always checked, whatever is set here, so a rope never falls through the world.' },
            { key = 'WorldCollision.Vehicles', type = 'bool', label = 'Cars',
              help = 'Ropes lie on cars and slide off them. Off can improve performance where cars are near a rope, but the rope looks less real: it passes straight through them. Tying a rope to a car works either way, and a resource\'s rope (a pump\'s hose) may choose for itself.' },
            { key = 'PlayerInteraction.Enabled', type = 'bool', label = 'People push it',
              help = 'Players and NPCs walking or running through a rope push it about. Off can improve performance where many people are about, but the rope looks less real: they walk straight through it. Holding an end and hanging off a rope work either way.' },
            { key = 'RopeContact.Enabled', type = 'bool', label = 'Other ropes',
              help = 'Ropes do not pass through each other: one laid over another rests on it. Off: they pass straight through. Ropes apart cost next to nothing; it is only worked out where two ropes come close.' },
            { key = 'RopeContact.Carry', type = 'bool', label = 'Ropes take each other\'s weight (experimental)',
              shownWhen = { path = 'RopeContact.Enabled', equals = true },
              help = 'A rope caught on another pulls what it is tied to along the way it is bent. Two cars on a rope dropped onto a rope held across a hole are caught by it, or drag down the cars holding it. Off: a rope on another only rests on it, and what is tied to it never feels it. Costs a little more where two ropes are close.' },
            { key = 'WorldCollision.Ground', type = 'enum', label = 'How the ground is found',
              options = {
                  { value = 'rays', label = 'Rays (every step)' },
                  { value = 'grid', label = 'Grid (found once per spot, kept)' },
              },
              help = 'Rays: every other node looks for the ground with a ray, every step it moves. Grid: the ground is looked for once at each point of a 25 cm grid and kept, and every node reads it instead, so a rope moving over ground a rope has already been on casts no rays. Walls, cars and people are found the same way either way. Swap them to compare: /ropedebug shows the rays cast a second.' },
        } },
        { label = 'Players on a rope', settings = {
            { key = 'PlayerHang.Enabled', type = 'bool', label = 'Players can hang off a rope' },
            { key = 'PlayerHang.ShotKnocksOff', type = 'bool', label = 'A shot knocks a hanging player off',
              shownWhen = { path = 'PlayerHang.Enabled', equals = true },
              help = 'Shot while hanging: they let go and fall. Off: a hanging player cannot be hurt.' },
            { key = 'Holding.Speed', type = 'enum', label = 'Fastest while holding',
              options = {
                  { value = 'walk', label = 'Walk only' },
                  { value = 'jog', label = 'Walk or jog (no sprint)' },
                  { value = 'sprint', label = 'Any speed' },
              },
              help = 'How fast a player may go with a rope end in hand. Letting go gives sprinting back.' },
            { key = 'Drag.Enabled', type = 'bool', label = 'Dragged along by a car',
              help = 'Holding a rope whose other end is tied to a car (or a prop) going away: once it is stretched past its easy stretch, the player falls and is dragged behind it, then lets go. Any rope, a pump\'s hose too. Off: it is only pulled out of their hands.' },
            { key = 'Drag.Seconds', type = 'number', min = 0.5, max = 15, step = 0.5, unit = 's', label = 'The ride lasts',
              shownWhen = { path = 'Drag.Enabled', equals = true },
              help = 'How long they are dragged before they let go (at once if they die).' },
        } },
    },
})
