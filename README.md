# whip_rope

A physics rope for [WHIP](https://github.com/WHIPFX/txAdmin-recipe). Players carry it as an item, tie it to cars,
props and the map, tow with it and hang off it. Other resources make ropes of their own:
[whip_fuel](https://github.com/WHIPFX/whip_fuel)'s pump hose is one.

## Features

- **Tie it anywhere.** Tie an end to a car, a prop, or the wall, rock or ground you look at.
- **Towing.** A taut rope stretches a little, then pulls. A light car moves more than a heavy truck, and a towed car
  nobody drives rolls freely.
- **Hanging.** Players hang off a rope and swing on it.
- **Dragged along.** Hold an end tied to a car that drives off, and you're dragged behind it for a few seconds.
- **Part of the world.** The rope lies on the ground, props and cars. People push it aside, explosions throw it, and
  ropes rest on each other.
- **The same for everyone.** Every player sees the same rope, and a towed car follows the car pulling it at any ping.
- **In the Director.** Cards to make, move and remove ropes, and goals for tying a rope, hanging on one or pulling one
  too far.
- **Nothing lost.** A player who leaves with ropes out gets them back as items.

## Requirements

- `whip_core`.

## Installation

WHIP's txAdmin recipe installs it.

By hand, put `whip_rope` in your `resources` folder and add this line to `server.cfg`, after `ensure whip_core`:

```cfg
ensure whip_rope
```

## For players

| To | Do |
| --- | --- |
| Put a rope out | Use the **Rope** item. You hold one end. |
| Tie the end you hold | Look at a car, a prop or the map within reach, and press the prompt's key. |
| Pick up or untie an end | Use the prompt on the end. |
| Hang on | Use the prompt on the rope. **Jump** lets go. |
| Put the end down, let go, or coil the rope up | Open the wheel (**F1**). Coiling puts the rope back in your pockets. |

While you hold an end, you can walk or jog but not sprint.

## Configuration

- **`/whip` → Settings → Rope:** who may handle a rope, whether tying to a car needs its keys, tying to the map,
  reach, the rope's length and node count, ropes per player, what a rope bumps into, hanging and holding.
- **`config.lua`:** how the rope pulls, moves and looks. Each setting is explained there.

See **Rope System** in WHIP's docs (`whip_core/docs.html`).

## Admin commands

These need developer mode on (`/w`).

| Command | Does |
| --- | --- |
| `/ropedebug` | Shows each rope's ends, stretch and pull, for you only |
| `/ropestatus` | Prints the ropes your game has in the F8 console |
| `/ropes` | Lists every rope out, in the server console |
| `/clearropes` | Takes every rope in. Each owner gets theirs back as an item. |

`/ropes` and `/clearropes` also run from the server console.

## For developers

Other resources make and control ropes through `exports.whip_rope`: `CreateRope`, `SetRopeEnd`, `SetRopeRules`,
`RemoveRope` and `GetRope` on the server, and `GetRopeEndEntity` on the client. Events such as
`whip_rope:ropeStretched` report what happens to them. See **Rope Exports (whip_rope)** and **Learning from rope** in
WHIP's docs. whip_fuel's `server/hose.lua` is a complete example.

## License

whip_rope is licensed under the GNU LGPL 3.0; see `COPYING.LESSER`, and `COPYING` for the GPL 3.0 it builds on.
`NOTICE.md` says what the licence doesn't cover; `whip_core`'s `NOTICE.md` is the full list.
