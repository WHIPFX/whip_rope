fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'whip_rope'
description 'A physics rope: carry it as an item, tie it to cars, props and the map where you aim, tow with it, hang off it. A whip satellite.'
author 'Whippy'
version '1.0.0'
whip_updates 'WHIPFX/whip_rope'   -- whip_core checks this repository's releases for a newer version

-- Whip.register re-runs our registrations whenever whip_core starts; Whip.core is safe while it's down;
-- Whip.configPage puts config.lua in /whip.
shared_script '@whip_core/lib/satellite.lua'
shared_script 'config.lua'
shared_script 'shared/settings.lua'   -- the pulling and item settings as a page in /whip → Settings

client_scripts {
    '@whip_core/lib/cost.lua', -- WhipCost timers, read by whip_core's /whipcost
    'client/state.lua',        -- the Rope namespace every client file shares
    'client/physics.lua',      -- Verlet nodes, constraints, the ends, the pull on what it is tied to
    'client/collision.lua',    -- the ground, walls, people walking through it, explosions
    'client/contact.lua',      -- ropes against each other
    'client/mesh.lua',         -- the rope pieces (3D Clanker's model) and GTA's own rope, along ours
    'client/visuals.lua',      -- which look; a prop per node; someone hanging off it
    'client/hang_ragdoll.lua', -- someone hanging off it as GTA's ragdoll, held by the hand (Config.PlayerHang.Style)
    'client/interaction.lua',  -- making, grabbing, tying, untying and hanging
    'client/sync.lua',         -- server state, and keeping every game's rope alike
    'client/drag.lua',         -- a held end pulled: dragged along behind a car, or out of your hands
    'client/keep.lua',         -- what this game's player pulls, taken and kept (server/keep.lua names it)
    'client/ui.lua',           -- whip's prompts and wheel entries, the hint capsule
    'client/main.lua',         -- the loops, the commands, cleaning up
    'client/api.lua',          -- a resource's rope here: its look, its held end, the watch (server/api.lua)
}

server_scripts {
    'server/state.lua',   -- every rope's ends, who holds what, the checks
    'server/keep.lua',    -- who keeps what a rope pulls: the player pulling it (client/keep.lua takes it)
    'server/item.lua',    -- the rope as an inventory item: using it, getting it back
    'server/main.lua',    -- the events, each through whip's SecureEvent
    'server/api.lua',     -- ropes for every resource (whip_fuel's hose): CreateRope / SetRopeEnd / RemoveRope / GetRope
    'server/director.lua', -- the Director's rope cards: Make a Rope, Goal: Tie a Rope, Goal: Hang on a Rope...
}

-- The item's picture.
files {
    'html/img/items/*.webp',
}

-- The rope piece (3D Clanker's whip_rope_seg and its no-shadow twin, docs/whip_rope_seg.txt).
-- The models stream from stream/; this registers their archetypes.
data_file 'DLC_ITYP_REQUEST' 'stream/whip_rope_seg.ytyp'

dependencies { 'whip_core' }
whip_requires '1.0'   -- the whip_core it is built for: the setup report flags an older one
