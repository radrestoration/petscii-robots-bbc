# Attack of the PETSCII Robots - BBC Master

A port of David Murray's *Attack of the PETSCII Robots* to the BBC Master 128, in shadow Mode 1 (320x256, 4 colours).
Licensed under the GNU GPL v3 (see `LICENSE`), like the original game. It is built from his C64 source and game-logic files (see `upstream/` and the copyright headers in `source/`, which stay
as they are). Technical notes: `PORTING.md`.

**Status: playable proof of concept.** All 14 levels are on the disc and the game plays from the intro menu to level play
(seen in b-em as a Master 128; not yet on real hardware). Sound effects, music and the f7 overview map work; see the to-do list in
`PORTING.md`.

Email contact@radrestoration.com for bug reports.  This port was made with the help of Claude Code. 

David Murray is aware of this port, and has distributed PETSCII Robots under the terms of the GPLv3. 

<p align="center">
  <img src="screenshots/title.png" alt="The title screen" width="50%">
  <img src="screenshots/play1.png" alt="Level 1" width="50%">
</p>


## Building and running
Needs cc65 (`ca65`, `ld65`), python3 with numpy and Pillow, and git (to fetch the original sources).
    make ssd            # fetches the C64/PET sources it reads into upstream/ (tools/fetch_upstream.sh), converts the
                        # assets, assembles and writes build/robots.ssd
    ./run-bbc.sh        # b-em, Master 128, autoboot
Tool locations (cc65, b-em) can be set in `tools.cfg` (copy `tools.cfg.tmpl`); by default they are taken from your PATH.
`make test` runs the simulator tests (about 3 minutes).
On a real Master: put `robots.ssd` on a disc, hold Shift and tap Break. It needs sideways RAM banks 4 and 5 (both are
RAM on a stock Master 128).

## Keys
| Key | Action |
|---|---|
| I / K / J / L, or cursor keys | move up / down / left / right |
| W / S / A / D | fire up / down / left / right |
| f1 or f2 / f3 or f4 | cycle weapons / items |
| Space | use item |
| Z | search object |
| M | move object |
| Escape | pause (then Y quits the level, N or Escape resumes) |
| Return, cursor up/down | intro menu |
| f6, f7 or f8 | overview map (the same key again toggles robots / player, any other key returns) |
| Shift+M | music on/off |
| Tab | cheat (the C64's C= + *) |

The key table is `KEYSET` in `source/platform/bbc/hal_main.s`. b-em numbers the host function keys differently in its physical and
logical keyboard modes (host F1 is the BBC's f0 in one, f1 in the other), so each function is on two or three neighbouring keys.

## Layout
    source/            robots.s (the game), background_tasks.s (game logic), bbc.cfg (linker), loader.cfg
    source/platform/bbc/   defs.s (memory map), hal_low.s, hal_gfx.s, hal_main.s (renderer, sprites, keyboard, vsync), loader.s
    tools/             asset conversion, disc builder, simulator and tests
    upstream/          third-party sources fetched by tools/fetch_upstream.sh (not in this repo)
    docs/              screenshot from b-em
    build/             generated
`make help` lists the targets; `make test` runs the headless simulator tests.
