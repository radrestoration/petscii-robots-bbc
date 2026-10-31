# PETSCII Robots - BBC Master port: technical notes

Target: BBC Master 128 (MOS 3.x), shadow Mode 1 (`MODE 129`), sideways RAM banks 4-7, DFS disc (`.ssd`, boot option 2).
Original game: *Attack of the PETSCII Robots* by David Murray. Copyright headers in `source/` are kept as in the sources
they derive from. The game is GPLv3 (the upstream repos carry the GPLv3 text; `LICENSE` here is the same file) and this port is released under the same licence, with the author's agreement.

## 1. Where the code comes from
- `source/robots.s` - `upstream/c64/C64ROBOTS.ASM` (ACME) translated to ca65 by `tools/acme2ca65.py`, then a mechanical pass
  (`tools/bbc_mechanical.py`) and hand edits marked `BBC`. From then on the source is maintained by hand; `upstream/` is the
  reference for diffs.
- `source/background_tasks.s` - the game logic. The C64 repo `!SOURCE`s a `BACKGROUND_TASKS.ASM` it doesn't contain; the copy
  from the PET repo (`upstream/pet`, zeropolis79/PETSCIIRobots-Pet) matches the C64 file's conventions exactly ($FB-$FE
  pointers, `LDA #n` sound ids, literal tile ids, the `CACULATE_AND_REDRAW` spelling). The Plus4/C64REU/C128 copies differ for
  their own platforms. One BBC hook: `HAL_TICK_REFRESH` at its entry.
- Assets: `tools/make_data.py` converts the C64 `tileset.gfx`, `gfxfont.prg`, `sprites.gfx`, `level-a..n` (formats verified from
  the C64 source: tileset = 20 pages of 256: destruct, attrib, 9 char pages TL..BR, 9 colour pages; level = $300 unit bytes +
  8 KB map; map window = 11x7 tiles of 3x3 characters on a 40x25 screen).
- `tools/fetch_upstream.sh` fetches the three upstream repos the build and tools read (c64, pet, vic20) at pinned commits into
  `upstream/` (git-ignored). The translated sources in `source/` are committed, so only `make data` needs `upstream/c64`.
- Other repos looked at (research only, not fetched; zeropolis79/PETSCIIRobots-{C64REU,Plus4,C128}, polluks/-III): polluks/PETSCIIRobots-BBC (Mode 7 reimplementation with procedurally generated levels - not used),
  polluks/PETSCIIRobots-III (ca65 PET port with a `PLAT_*` layer - read for ideas).

## 2. Architecture
The C64 game draws by writing screen RAM ($E000), colour RAM ($D800) and the VIC sprite registers. Those are plain RAM here
(`VSCR`, `VCOL`, `VIC`, `VSPTR` in `defs.s`), so almost all game code is unchanged.
- **Refresh** (`HAL_REFRESH`, throttled to every 3rd vsync by `HAL_TICK_REFRESH`, which is called from every place the game
  polls or waits): update sprite records, window-tile fast path, then scan VSCR/VCOL against `SH_CH`/`SH_CO` (what is on screen)
  and draw the differing 8x8 cells. A cell is 16 bytes in Mode 1 (left 4 pixels x 8 rows, then right 4 x 8).
- **Cell drawing**: 1-bit C64 font row -> two screen bytes via `LTAB`/`RTAB` (both bit planes set per lit pixel) ANDed with the
  colour mask ($0F/$F0/$FF = logical colour 1/2/3). The C64's 16 colours map onto 3 BBC colours + black (`CMAP`, first-pass).
- **Sprites** (cursor, 2+2 weapon/item icon sprites, 3-layer player) are composited in software *inside* the cell draw: a cell with
  sprites over it is built in `CBUF` (glyph, then sprites highest number first) and copied to the screen in one go, so sprites don't
  flicker. When a sprite changes, the cells under its old and new footprints are marked not-drawn.
- **Window tile fast path**: `DRAW_MAP_WINDOW` reports the cache slot of the tile it plotted per window position (`TILE_NEW`, from
  `HAL_TILE_KEY`; $FF for overlays and uncached tiles). A changed tile is copied from a cached 24x24 image (144 bytes: 3 strips of
  3 cells, rendered on first use from the cells the game plotted, kept in banks 6/7/5 indexed by slot) instead of drawing 9 cells.
  The tiles `ANIMATE_WATER` rewrites cycle through 2 or 3 images (water 204/221 and the trash compactor 148: period 3; fan 196/197/
  200/201 and server light 143: period 2), so each phase has its own slot: slot = `TSLOT[id]` + the phase of its `TILEKIND`
  (`HAL_ANIM_STEP` advances the phase counters `KPHASE` with every animation step, and `DRAW_MAP_WINDOW` keys and plots a tile with
  interrupts off so both see the same phase). Only the cinema screen (20-22, a 197-step ticker) is never cached. `make_data.py` assigns the
  slots and writes `tile_kind.inc`; `tools/anim_test.py` checks the periods against the game's own routine, that the screen
  equals the virtual screen over 8 animation steps, and the speed. `DECOMPRESS_SCREEN` invalidates it. A scroll step draws ~43
  tiles + a few cells (was ~350 cells).
- **Keyboard**: OS buffer (OSBYTE 145) + INKEY(-n) held-key test (OSBYTE &81) reproduce the C64 KERNAL queue and the game's
  `$C5 = 64` repeat trick. Internal key numbers come from b-em's matrix table. `*FX4,1`, `*FX225,192`, `*FX229,1`, `*FX11,0` at
  start-up. Letters are case-insensitive (Caps Lock); Shift is read with INKEY(-1).
- **Timing**: the vsync event (`EVNTV`, event 4) runs `RUNIRQ` (the C64 raster IRQ body) at 50 Hz; the game clock constant is 50.

### Memory map (`platform/bbc/defs.s`, `source/bbc.cfg`)
The screen is the whole 40 x 32 cell Mode 1 display (20 KB): the game window is **11 x 9 tiles** (the C64 shows 11 x 7), the info
panel and health sit in rows 27-30, row 31 is blank. The C64's 25-row full screens (intro, end, custom keys) are shown with the
CRTC start address moved (`HAL_VIEW_CENTRE`) so they sit centred; `HAL_VIEW_FULL` for the game screen.
| Area | Contents |
|---|---|
| &0E00-&11FF LOW (region size checked) | critical-section stubs, shared tables (CMAP/CMASK, ROWTAB/COLTAB, BITS...), ~850 bytes |
| &1200-&15FF | HAL variables (sprite records, tile tables, `TBUF`...), ~940 bytes; the loader (&1400) runs here before it is used |
| &1600-&17FF | the C64's $0600-$07FF variable page |
| &1800-&1CFF / &2000-&24FF | VCOL / VSCR (virtual colour / screen RAM, 1280 bytes each; VCOL = VSCR - &800 as on the C64) |
| &1D00 | `MAP_PRECALC` (99 bytes, moved out of the variable page) |
| &2500, &2A00 | `SH_CH`, `SH_CO` (what is on screen) |
| &2F00 | virtual VIC registers, sprite pointers |
| &1D80 / &1E00 | `SPRTILE` (99 bytes) / `MAPROW` (128 bytes) |
| &3000-&7F87 MID | game code and sound data (~19.7 KB, limit &8000: ~120 bytes spare) |
| bank 4 (&8000, always paged in) | tile tables, level units (&9500), map (&9800), compressed screens (&B800-&BFDB) - loaded with `*SRLOAD` |
| bank 5 | renderer, font, sprite images (paged in inside a cell draw); the music player, converter and tables (to &A7E8, paged in by the vsync handler); tile cache for slots 226+ at &A800 (24 slots); the current song's image at &B580-&BFFF |
| banks 6, 7 | tile image cache (slots 0-225; tiles with identical pictures share a slot: `TSLOT` at &9400 of bank 4) |
| shadow RAM | the 20 KB Mode 1 screen; cell (c,r) at &3000 + (r*40+c)*16 |

Verified from the Dabhand Master OS guide (ch.5): ACCCON bit 2 (X) sends CPU access to &3000-&7FFF to the shadow RAM, bit 0 (D)
displays it. In a shadow mode main RAM &3000-&7FFF is therefore free for code as long as X = 0. Drawing = one short critical
section per cell/tile: `SEI`, page bank 5 (or the cache bank) in with `ROMSEL`+`&F4`, set X, draw, restore, `CLI`. Everything that
runs with X = 1 lives below &3000 or in the paged bank; the vsync handler can never run inside a critical section.

## 3. Build and test
    make data | all | ssd | test | clean        (make help)
`make test` (~3 min) runs, in the headless simulator (`tools/sim6502.py` + `tools/sim_bbc.py`: shadow RAM, ROMSEL banks, OS
traps, 50 Hz vsync - no emulator or display):
- `render_test.py` - cell renderer and sprite compositing pixel-exact against an independent Python reference;
- `verify_test.py` - plays level A and checks the whole screen after 11 moves against an independent rendering of VSCR/VCOL +
  sprites (covers the tile fast path);
- `loader_test.py` - boot loader.
Also: `play_test.py` (drive keys, write `build/preview/play.png`), `intro_test.py`, `tiles_preview.py` (Mode 1 palette previews).
Bugs these caught, worth remembering: 6502 `bpl` loops can't count from above 127; a 16-bit zero-page pair aliased the next
variable; `LDA zp,Y` doesn't exist.

## 4. Status
Seen working in b-em (Master 128): boot, intro menu, level start, movement, scrolling, sprites, no flicker. Not tried on real
hardware, on a Master Compact, or past the first level.

## 5. To-do (roughly by value)
1. ~~Overview map (f7)~~ DONE - see 6c. (Possible polish: draw it at 2x2 pixels per tile; it is 128x64 pixels, as on the C64.)
2. ~~Sound effects~~ DONE (first version) - see 6c. Needs tuning by ear on real hardware: the effects are the Plus4 version's,
   converted; the C64's own SID effect data is a format of its SID driver and was not decoded.
3. ~~Music~~ DONE (6d) - the C64's own player and song data play, converted to the SN76489 every frame; see 6d. Needs listening
   tests on real hardware (envelope shapes, noise rates, bass notes folded up).
4. **Colour** - the palette is a first pass (black/red/blue/white; some tiles come out in odd colours, e.g. green foliage red).
   Per-level palettes via `VDU 19` at level load are cheap (tools already count colour use); a palette split by cell-row band
   (window vs side panel/text) would give two different colour sets on screen. Needs a per-level choice in `tools/make_data.py`.
5. **Border/background flashes and screen shake** (left for later by decision) - `VIC+$20/$21/$16` are written but inert. Flashes: briefly change logical
   colour 0 (or the whole palette); shake: move the CRTC start address / horizontal position (R2) for a few frames.
6. **Joystick** - dropped by decision (the C64's SNES-pad code is stubbed; `SNES_CONTROLER_READ` returns).
7. **Speed** - three rounds done (6c): a movement step is ~225K cycles of work in the simulator (about 110 ms, was ~210 ms
   at the start). Where it goes now: tile copy (~55 tiles) ~92 K (41%), sprite cells ~32 K, the game's window plot ~25 K,
   `CELLS_SYNC` 9 K, tile addressing 2.6 K, the rest ~65 K. Measured and rejected: shifting VSCR/VCOL when the window moves
   (the shift costs >= 16 K cycles, about what the skipped plotting saves). What is left is the copy itself (9 cycles a
   byte is the 6502's floor); only a hardware scroll (CRTC start address + redrawing just the new edge row/column) would
   change the picture much. It needs a split screen or a panel redraw for the info area. The C64 runs its clock at 60 Hz,
   this at 50: game timers are 17% slower (as on a PAL C64); tune `KEYTIMER`/clock constants if wanted.
7a. **Seen in b-em, not yet fixed/checked**: "scroll when leaving the title for the game" - changed (the display start address
   now changes only after the new screen is drawn, display blanked meanwhile); needs checking in b-em.
8. **Text** - intro message says "welcome to bbc-robots!" (credit line unchanged); check the custom-keys screen, end/win/lose
   screens and every info message after the PETSCII->BBC key changes (`MSG_*` mention C64 keys like "f7").
9. **Verification** - run all levels A-N, game over and win screens in b-em and on a real Master; Master Compact; other MOS
   versions (ACCCON read-modify-write, `*SRLOAD` behaviour). Add a CI-style `make test` run to the routine.
10. **Housekeeping** - `make ssd` is single-sided (155 KB of 200 KB).

## 6. Other graphics modes (Mode 1 stays; ideas for it are in 6a)
The structure (virtual 40x25 character screen -> cell diff -> blit, software sprites, tile cache) is mode-independent; what
changes is the cell-drawing and sprite-expansion code in `hal_gfx.s` and the tile-image size.

| Mode | Resolution / colours / RAM | Fit | Notes |
|---|---|---|---|
| **1** (current) | 320x256, 4 colours, 20 KB | exact C64 geometry | colours are the problem: 3 + black for the whole screen (no per-cell colour). |
| **2** | 160x256, 8 colours, 20 KB | best colour, half horizontal resolution | Each C64 character becomes 4x8 pixels, so the font must be down-sampled (text such as "INFORMATION", digits, key names turns to mush at 4 px; would need a hand-drawn 4x8 font for text cells, and the tile art loses detail). Multicolour sprites (12 px wide) map 1:1 and the C64's 16 colours fold into 8 much better. Cell = 4 px x 8 rows = 16 bytes, so the draw cost and the tile cache (144 bytes per 3x3 tile) are unchanged; screen 20 KB, still wants shadow RAM. This is the mode the Undead BBC port uses. Worth a preview run (`tools/tiles_preview.py`-style) before committing. |
| **5** | 160x256, 4 colours, 10 KB | half horizontal resolution, small screen | Same down-sampling problem as Mode 2 with only 4 colours; the attraction is memory: a 10 KB screen at &5800 leaves &1900-&57FF for code. Not enough without sideways RAM (code is 19.7 KB, data 14 KB). |
| **4** | 320x256, 2 colours, 10 KB | exact geometry, monochrome | Halves the bytes drawn per cell (8 vs 16) and the screen; no colour at all (fine for a clean "mono" version); same memory problem as Mode 5 on a 32 KB machine. |
| **0** | 640x256, 2 colours, 20 KB | no gain | |
| **7** | teletext | cheap, ugly | the existing polluks port; no tile art, 40x25 with attribute bytes, not worth revisiting. |
| custom CRTC (25 rows of Mode 1) | 320x200, 16 KB | exact | The game only uses 25 character rows; reprogramming the CRTC to 25 rows frees 4.4 KB and removes the black bars, which matters only on machines without shadow RAM. |

**Mode 2 preview (2026-10-24, `tools/mode2_preview.py`, images in `docs/previews/`)** - level A start, C64 art folded onto the
8 BBC colours (nearest RGB), also the VIC-20 version's own tileset/font (`upstream/vic20`: hi-res 8x8 characters, 25x25
screen, 7x7-tile window, only VIC colours 0-7, which are exactly the BBC's 8 colours).
- 40x25 of 4-pixel cells (same cell shape on screen as Mode 1; each glyph row folded 8->4 pixels, lit if either source pixel
  is lit): the **map art survives well** and the colours are far better (green grass, cyan/white lander). The **text does not**:
  "WEAPON", "INFORMATION", the messages and digits are close to illegible at 4x8. Needs a purpose-drawn 4x8 text font (still
  cramped) or keeping text out of the 4-pixel layout.
- VIC-20 style, 20x25 of 8-pixel cells (wide pixels, full glyph detail, readable text): crisp and colourful, but only 20 columns,
  so a 6x7-tile window (the C64 shows 11x7, the VIC-20 itself 7x7).
- `ideal_8colour_320px.png` = what the current Mode 1 build would look like with 8 colours at full resolution (not available on a
  BBC): the colour target.
- The VIC-20 art needs no colour mapping (its colours are already 0-7) and sits slightly better in 8 colours, but it is a different
  tileset, so level tile ids would have to match (the maps are the same format; chars differ in ~20 of 256 tiles per page).
Verdict: Mode 2 wins on colour, loses on text and (in the VIC-20 layout) on view size. A mixed design is the interesting one:
window in Mode 2 colour, text/panel in a legible form (e.g. text drawn into the window's 8-pixel-wide cells only in a 20-column
variant, or a custom 4x8 font). Cost of the port: new cell/sprite expansion code (Mode 2 pixel interleave, 16-entry tables),
tile cache 144 bytes per tile unchanged, same memory.

**Follow-up (user: down-sampling unacceptable; current Mode 1 "still pretty good"; try the VIC-20 way with more tiles)** -
`tools/mode2_vic_layouts.py`, `docs/previews/vic_layouts.png`: VIC-20 tileset/font, 8x8-pixel cells (32 bytes each in Mode 2), no
down-sampling, 8 colours, readable text. Memory limit: cols x rows x 32 <= 20480.
| Layout | Screen | Window | Notes |
|---|---|---|---|
| L1 | 20 x 32 cells (standard Mode 2) | 6 x 9 tiles (54) + 5 text rows + 2-column strip | no CRTC changes |
| L2 | 22 x 29 (CRTC R1=88) | 7 x 8 tiles (56) | needs a widened display; not tried on hardware |
| L3 | 25 x 25 (CRTC R1=100, overscan; the VIC-20 version's own 25x25) | 8 x 7 tiles (56) | overscan may clip on real monitors; not tried |
For comparison: Mode 1 now 11 x 7 = 77 tiles, VIC-20 original 7 x 7 = 49, C64 11 x 7. Mode 2 cells are 2.1:1 (wide) on a 4:3
monitor, against about 1.1:1 for Mode 1 and ~1.3:1 on the VIC-20, so the art looks stretched wider than on any other version. Cell
cost doubles (32 bytes), tile cache images are 288 bytes (3 banks hold ~170 of them), but fewer cells are drawn per step.
CRTC widening/overscan claims are from general BBC knowledge, not checked against a source or hardware.

Other thoughts:
- **Per-region palettes** are the cheapest big win for Mode 1: re-programme the video ULA palette at a raster split (system
  VIA timer synchronised to vsync) so the window and the panel/text bands use different colour sets.
- **Mode 2 hybrid**: use Mode 1 for text and the panel and Mode 2 for the window needs a mid-frame mode switch; not practical with
  the OS, possible in principle by writing the ULA control register and CRTC at a raster split. Risky; probably not worth it.
- **Other machines**: a **BBC B+128** has shadow RAM and sideways RAM, so the same architecture should port with different
  `ACCCON` (bit 7 only, write-only), `ROMSEL` private-RAM bit and bank numbers (11,12,0,1). A plain **BBC B** or **Electron**
  with sideways RAM but no shadow screen cannot hold a 20 KB screen and the game together in main RAM; it would need all game
  code in sideways RAM (two banks plus trampolines) - a large restructuring - or Mode 4/5 plus that. A **Master Compact** shares the Master 128's
  ACCCON/ROMSEL scheme (per the Dabhand guide) but is untested here, and whether it has the sideways RAM banks 4 and 5 was not checked.

## 6a. Tricks for Mode 1 (discussion 2026-10-24)
Decision: Mode 1 remains the build. Ideas, roughly by value / certainty:
1. **Per-level palettes** (certain, cheap): choose the 3 colours per level in `tools/make_data.py`, `VDU 19` at level load.
2. **Palette split for the bottom rows**: the side panel shares scanlines with the window, so a raster-timed palette change only
   helps the bottom 4 cell rows (info text, health). A one-shot timer started from the vsync event (user VIA) is the usual way;
   not tried here, the timing/jitter details are unverified. Whole-window needs (white + blue for the panel) still constrain the
   window palette, so gain is modest.
3. **Taller window** (DONE 2026-10-24: 11 x 9 tiles; description kept here for the record): only 25 of the 32 cell rows are used. A 11 x 9 tile window (27 rows) + 5
   text rows fills the 20 KB screen exactly: 99 tiles instead of 77. Needs the window height constants (7 -> 9), centre row,
   `MAP_PRECALC` (77 bytes -> 99, relocate), cursor Y range and scroll limits changed in the game code, and slightly changes
   difficulty (you see further) - make it optional. PAL overscan may clip the extreme top/bottom rows.
4. **Dithering to synthesise colours** (tried, `tools/dither_preview.py`, `docs/previews/dither_comparison.png`): lit pixels of a
   cell alternate between two palette colours (white+black = grey, red+white = pink, red+green = yellow/brown...). With the C64's
   sparse single-pixel tile art it mostly produces speckle; only the filled shapes (grey shading on the lander) gain visibly. The
   renderer change is small (two masks per cell, alternate by row/column) but the benefit is marginal - maybe greys only.
5. **Flash colours** (physical 8-15 alternate two colours): possible for the cursor or a health warning; minor.
6. Not worth it: hardware (CRTC) scrolling - it moves the whole screen including the side panel; mid-line palette changes
   (cycle-exact, fragile); alternating palettes per frame (flicker).
7. Timing: starting each refresh just after vsync would line the redraw "wipe" up with the beam; small gain.

## 6b. Taller window and vsync-aligned refresh (done 2026-10-24)
- Window 11 x 9 tiles (`WIN_W`/`WIN_H` in `defs.s`). Game-code edits (all marked `BBC`): window centre row (`CACULATE_AND_REDRAW`, elevator
  placement, `USER_SELECT_OBJECT` cursor start), `MAP_PRE_CALCULATE` (99 entries, `PRECALC_ROWS`), `MAP_CHART_L/H` and the
  `DRAW_MAP_WINDOW` row count, the three "is this unit in the window" tests (now wrap-safe, since the window can start above the
  map: it starts at player Y-4 and walkable rows begin at row 3), player sprite Y (146), cursor sprite row table, info rows moved
  down by 6 cell rows (`VSCR+$4B0` etc.), game screen data regenerated at 40x32 by `tools/make_data.py` (6 rows inserted below row 20).
  `DRAW_MAP_WINDOW` repeats the map's edge rows when the window runs off the map.
- It changes the game slightly: you see 4 tiles up and down instead of 3 (more warning of robots). Not switchable at run time;
  reverting needs the edits above undone (`WIN_H` alone is not enough).
- Possible issues to check on a real machine: the top and bottom cell rows may be cut by PAL overscan on some monitors; the
  CRTC start-address trick for the 25-row screens relies on the video hardware wrapping the address (b-em does; the Dabhand
  guide was not checked for it).
- Refresh start: `HAL_TICK_REFRESH` now starts a refresh only on the first poll after a vsync (`VSYNCFLAG`, set by the vsync
  event) and at most every 3rd vsync. Because the game polls far more often than 50 Hz this aligns the start of the redraw with the
  top of the frame; it does not make the redraw itself faster.
- Colour dithering was tried (`tools/dither_preview.py`) and rejected: the art is unsuited to it.

## 6c. Overview map, sound, speed-ups (2026-10-29/30)
- **Licence**: GPLv3 (`LICENSE`), as the original game; confirmed with its author.
- **Display start change** (`HAL_VIEW_FULL` / `HAL_VIEW_CENTRE`): now queued; the palette is set to black until the next refresh has
  drawn the new screen, then the CRTC start address is changed and the palette restored (`APPLY_VIEW`). Previously the display
  jumped three rows when going from a 25-row screen to the game screen before the new screen was drawn.
- **Overview map (f7)**: the C64 shows the 128x64 map as 128 redefined characters. Here `HAL_MAP_RENDER` builds each of the 8 cell
  rows of the picture as 8-byte glyphs in `MAPROW` (&1E00) from the tile attributes (one white pixel per tile that can't be walked
  on) and draws them with the normal cell code straight into the screen memory over cells the scan believes are blank
  (`HAL_MAP_BLANK`); the blinking 2x2 dots are single-pixel read-modify-writes (`HAL_MAP_PIXEL` -> `HAL_PIXEL_CRIT`). The game's own
  map code (`DISPLAY_MAP`, `BLINK_PLAYER`, `BLINK_ROBOTS`, `TURN_DOT_*`) is unchanged apart from `MAP_RENDER`/`BIT_PLOT_*`.
  `tools/map_test.py` checks the picture against the map data (0 wrong pixels of 8188) and the dot blinking.
- **Memory moved to make room**: the compressed intro/game/map screens (2 KB) now live in bank 4 at &B800 (`SCREENS` segment,
  file `SCREENS`, `*SRLOAD`ed by the loader); main memory now ends about &7B23 (about 1.2 KB spare).
- **Sound** (`HAL_PLAY_SOUND`, `SOUND_TICK`, SN76489 routines in `hal_main.s`): the game's 19 sound ids map onto the 15 effects of
  the Plus4 version (TED: one voice, 10-bit pitch, noise); `tools/make_sound.py` converts them (TED period -> SN76489 period =
  1.1277 x (1024 - reg), volume 0-8 -> 0-15, noise -> white noise clocked by channel 2) into `build/data/sound.inc`. The engine runs
  from the vsync event (interrupts off, so the keyboard's use of port A is never interleaved) and keeps the Plus4 engine's
  semantics: priority (larger = more important), per-note timer, pitch steps, fade-out. Port A direction is restored to &7F after
  each update. `tools/sound_test.py` plays all 19 ids in the simulator and compares the SN76489 byte stream with an independent
  Python player (all identical), plus the priority behaviour. Not heard on a real machine: pitch conversion is from the TED
  documentation as remembered, and the SN76489 write timing (6 NOPs of /WE low) is the usual value, unverified here.
- **Speed**: (1) `DRAW_MAP_WINDOW` calls `HAL_WANT_REFRESH`, so a window change is drawn at the next vsync instead of waiting for
  the 3-tick throttle; (2) `DRAW_MAP_WINDOW` skips `PLOT_TILE` when the same plain tile is already there (`TILE_NEW`); (3) the
  tile pass tests a per-tile "sprite over it" table built once per refresh (`SPRTILE`, &1D80) and syncs `SH_*` with unrolled
  copies; (4) the 48-byte strip copy is unrolled x4. `tools/step_timing.py` measures key-to-last-draw latency in the simulator:
  209 ms -> 163 ms average. (5) `SPR_IN_CELL` rewritten: row/byte ranges worked out once per sprite and cell, transparent source
  bytes skipped, multicolour lookups by table (`MQL1`..`MQR2`, `SP_MC*` indexed q*8+sprite): 178 -> 144 ms. (6) `HAL_BLIT_CRIT` copies the three strips in one loop with its six operands patched per tile (9 cycles a
  byte, was 13); `TILE_ADDR` reads `J144LO/HI` tables; `CELLS_SYNC` is one unrolled copy per cell-index page (abs,X). Together
  ~71 K cycles less per step (296 K -> 225 K).

## 6d. Music (done 2026-10-30)
The C64 version's music is a stripped GoatTracker 2 play routine (SID) plus the song data, `upstream/c64/music.c64`
(player $A000-$A3D8, tables $A442-$A9B4, order lists and patterns $A9B5-$C8C9; $A3D9-$A441 is the SID sound-effect path, dropped -
the effects are the Plus4 version's). Nothing was re-composed or re-implemented:
- `tools/music_port.py` translates the player instruction by instruction into ca65 (`build/data/music_core.inc`): same code, same
  page layout (the player patches a JSR's low byte to dispatch its commands), SID stores go to shadow registers `SIDSH`, its
  scratch pointer is $3E/$3F (saved around each call - the game's own zero page). `tools/music_test.py` runs the original and the
  translation side by side and compares the 25 SID registers after every frame: identical for the full length of all 8 songs
  (up to 23,426 frames). The player reads 32 bytes past its 96-entry frequency table (note numbers reach 127); songs 0, 3 and 4 do
  this, so those bytes are kept.
- `tools/music_conv.py` is the model of the SID -> SN76489 conversion, `platform/bbc/music.s` the 6502 version
  (`tools/music_conv_test.py`: write for write identical to the model over the real register streams). Pitch: the SID frequency
  register converted to the SN's 10-bit period (K / F, PAL clock - the song's note table is tuned for it, A4 = 440.09 Hz; worst
  error 22 cents, at the highest notes, from the SN's integer period). The SN cannot go below 122 Hz: lower notes are folded up
  whole octaves. Loudness: the SID envelope (attack/decay/sustain/release, gate, datasheet times, linear) in 16 bits, mapped to
  the SN's 16 attenuation steps. Waveforms: all square except noise (a voice with the noise waveform drives the SN noise channel,
  white, one of three rates picked from its frequency; the louder noise voice wins). No filter, no ring modulation, no pulse width.
  Two by-ear corrections from the first hardware test (level music was quiet and staticky): the level songs (0-3) are mixed about
  10 dB lower than the title tune, so they are played `LEVEL_GAIN` = 4 attenuation steps louder (`MUS_GAIN`, set by `HAL_MUSIC_START`);
  and a noise voice the song routes through the SID's low-pass filter (reg 23 bit n, reg 24 bit 4 - the level songs' drum voice) is a
  low thump on the C64, so it gets the lowest SN noise rate and `FILT_ATT` = 2 steps less loudness instead of full-range hiss.
  All of that is a model, not a measurement: **tune by ear** (decay is linear here, the SID's is not; the noise rates are guesses).
- Sound effects over music: while an effect plays it owns channel 0 (tone effects) or channel 2 and the noise channel (noise
  effects); the music skips them and rewrites them afterwards (`tools/music_game_test.py`: the chip equals what the music alone
  sets, 141 frames after a walk and an explosion over song 1).
- Memory: ~3.1 KB of bank 5 for the player, tables and converter, so only **one song is resident at a time**: `HAL_MUSIC_START`
  loads `MUSn` (built by `music_port.py songs` after linking: pointer tables, order lists and patterns of that song only, patterns
  renumbered) with `*SRLOAD MUSn B580 5` when the song changes (title, each level, game over: a short disc access; the blank song 5 needs none).
  To make room for the song (max 2.5 KB) the tile cache shrank: `tools/make_data.py` gives tiles with identical pictures one cache
  slot (231 distinct plain images, plus 19 for the phases of the animated tiles = 250 slots), so the cache needs 24 slots in bank 5, not 30.
- CPU: the vsync handler's music frame (player ~730 + converter ~1,300 cycles, two to three thousand with note changes) is about
  2,150 cycles on average, 3,600 at most: 5.4% of the CPU. Cheap to cut further (skip silent voices) if the redraw needs it.
- Tempo: the player is stepped once per 50 Hz vsync, as on a PAL C64 (the game's own clocks run at 50 Hz here too).
