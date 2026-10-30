; BBC Master port - memory map and hardware definitions.
; Master 128, shadow Mode 1 (MODE 129): the 20 KB screen lives in LYNNE, so main RAM
; &3000-&7FFF is free for the game as long as ACCCON bit 2 (X) is 0.  Whenever X is 1
; (only inside HAL_REFRESH's per-row critical sections, interrupts off) the CPU sees
; LYNNE there instead, so everything the renderer touches while X=1 lives below &3000
; or in the sideways bank it has paged in.  Verified from the Dabhand Master OS guide, ch.5.
;
; Screen: 40 x 32 cells = the whole 20 KB Mode 1 screen (the game window is 11 x 9 tiles, taller than the C64's 11 x 7).
; LOW  &0E00-&2FFF  always visible: HAL stubs, game variables, virtual screens
; MID  &3000-&7FFF  game code (visible when X=0)
; bank GFXBANK @ &8000  renderer, font, sprite images   (paged in only by HAL_REFRESH)
; bank DATABANK @ &8000 tile tables, level units + map  (permanently paged in)

GFXBANK   = 5           ; sideways RAM banks W..Z are 4..7 on the Master
DATABANK  = 4

ROMSEL    = $FE30
ROMSEL_SH = $F4         ; MOS's copy of ROMSEL
ACCCON    = $FE34
ACC_X     = %00000100   ; CPU access to &3000-&7FFF goes to LYNNE
OSWRCH    = $FFEE
OSBYTE    = $FFF4
OSCLI     = $FFF7
EVNTV     = $0220

; --- LOW RAM layout (&0E00-&2FFF) ---
GAMEVARS  = $1600       ; the C64 version's $0600-$07FF variable page lives here
VCOL      = $1800       ; virtual colour RAM  (1280 bytes)   C64: $D800
HALVARS   = $1200       ; HAL work area (1 KB; LOW code is below it, region size checked by bbc.cfg)
VSCR      = $2000       ; virtual screen RAM  (1280 bytes)   C64: $E000   (VCOL = VSCR - $0800 as on the C64)
SH_CH     = $2500       ; what is currently drawn: characters
SH_CO     = $2A00       ; what is currently drawn: colours
VIC       = $2F00       ; virtual VIC-II registers ($D000-$D02E); only the sprite ones are meaningful
VSPTR     = $2F40       ; virtual sprite pointers ($E3F8-$E3FF)

SCRTOP    = $3000       ; shadow-screen address of cell (0,0): Mode 1 starts at &3000
CELLROWS  = 32
CELLS     = CELLROWS * 40
WIN_W     = 11          ; game window in tiles
WIN_H     = 9
PRECALC   = $1D00       ; MAP_PRECALC (WIN_W*WIN_H bytes), moved out of the variable page

; --- zero page ---
; The C64 game's own zero page ($23-$3F) is kept as is.  Its $FB-$FE pointers are MOS
; territory on the BBC, so they live at $70-$73 (BBC user zero page).
ZP0       = $70
ZP1       = $71
ZP2       = $72
ZP3       = $73
; HAL zero page ($40-$5F)
P_CH      = $41
P_CO      = $43
P_SC      = $45
P_SO      = $47
P_D0      = $49
P_D8      = $4B
G_GLY     = $4D
G_MASK    = $4F
G_COL     = $50
G_TMP     = $51
S_N       = $52
S_SRC     = $55
G_M       = $59
G_V       = $5A
S_X       = $5B
S_Y       = $6C         ; (S_X is 16 bit: $5B-$5C)
S_MC      = $5D
S_B       = $5E
S_OFF     = $5F
S_T1      = $61
S_T2      = $62
G_CX      = $63         ; cell being drawn with sprites over it
G_CY      = $64
G_SM      = $65         ; bit mask of the sprites whose rows cover this cell row
S_K0      = $66
S_RY      = $67
S_Y8      = $68
S_H       = $69
S_K       = $6A
S_R3      = $6B
T_POS     = $74         ; tile fast path (hal_main.s)
T_TX      = $75
T_TY      = $76
T_IDX     = $77         ; (16 bit) cell index of the tile's top-left cell
T_TILE    = $79
P_S       = $7A         ; (16 bit) source pointer in the tile cache
BL_BANK   = $7C
T_K       = $7D
T_J       = $7E
CACHEB5   = $A800       ; tile cache: tiles 0-112 bank 6, 113-225 bank 7 (both at &8000), 226-255 bank 5 from here
TILEBYTES = 144         ; 3 strips of 3 cells x 16 bytes
