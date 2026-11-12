# Changelog

## v1.0.0 - 2026-11-12

First release: *Attack of the PETSCII Robots* (David Murray) on the BBC Master 128, from his C64 source.
Licensed under the GNU GPL v3, like the original.

- All 14 levels, from the intro menu to level play, the overview map (f6/f7/f8), the end and game-over screens.
- Shadow Mode 1 (320x256, 4 colours), 40x32 cells. The map window is 11 x 9 tiles, taller than the C64's 11 x 7.
  Sprites are drawn in software and the tile images are cached, so scrolling stays smooth.
- Sound effects and the C64's music on the SN76489: the original GoatTracker player runs unchanged and its SID output is
  converted to the BBC's sound chip. Shift+M turns the music off.
- Keyboard play: I/K/J/L or the cursor keys to move, W/S/A/D to fire, f1-f4 for weapons and items, and the custom-keys option
  in the intro menu. The key table is in the README.
- Needs a BBC Master 128 (sideways RAM banks 4 and 5). Put `robots.ssd` on a disc, hold Shift and tap Break; the zip also has
  a script to run it in b-em.
- Not in this port: the C64's screen shake and border/background flashes, and joystick support.

Bug reports: contact@radrestoration.com. Technical notes: PORTING.md.
