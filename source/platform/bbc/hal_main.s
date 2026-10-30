; BBC Master port - HAL code that runs with ACCCON.X = 0 (so it can live in MID with the game):
; initialisation, the refresh driver, software-sprite change tracking, keyboard, the vsync
; tick, and data loading.  The critical sections themselves are in hal_low.s.

.segment "HALVARS"
SPR_OLD:        .res 64         ; 8 bytes per sprite: what is currently drawn
; per-sprite records for the cell renderer (built by SPR_UPDATE, read by SPR_IN_CELL in hal_gfx.s)
SP_BC0:         .res 8          ; first screen byte column (X-24)/4
SP_SY:          .res 8          ; top pixel row Y-50
SP_SRCL:        .res 8          ; image address in the GFX bank
SP_SRCH:        .res 8
SP_MODE:        .res 8          ; 1 = multicolour
SP_CM:          .res 8          ; hi-res colour mask
SP_MCV1:        .res 32         ; multicolour lookups, index sprite*4 + q (q = 0 stays 0 = transparent)
SP_MCV2:        .res 32
SP_MCM1:        .res 32
SP_MCM2:        .res 32
SPRROWS:        .res CELLROWS   ; per cell row: bit n = sprite n covers it
CBUF:           .res 16         ; cell being composed
SP_C0:          .res 8          ; footprint in cells (for the tile fast path)
SP_C1:          .res 8
SP_R0:          .res 8
SP_R1:          .res 8
SPR_EN:         .res 1          ; bit n = sprite n enabled
TILE_NEW:       .res WIN_W*WIN_H         ; tile id the game just drew at each window position, $FF = overlay/animated/unknown
TILE_SHOWN:     .res WIN_W*WIN_H         ; ... and what is on screen
TILE_VALID:     .res 256        ; tile image is in the cache
TBUF:           .res TILEBYTES  ; tile image being built
SIG:            .res 8          ; signature of the sprite being examined
; keyboard (stand-ins for the C64 KERNAL's variables the game pokes)
LSTX:           .res 1          ; $C5:  matrix code of the key now held, 64 = none; the game writes 64 to force a repeat
KBDENABLE:      .res 1          ; $0289: 0 = keyboard input off
KBDCOUNT:       .res 1          ; $C6:  number of keys queued
KEYQ:           .res 1          ; queued key (one slot)
KREPEAT:        .res 1          ; $028C
SIDVOL:         .res 1          ; $D418 stand-in
TICKS:          .res 1
VSYNCFLAG:      .res 1          ; set by every vsync, consumed by HAL_TICK_REFRESH
LASTREF:        .res 1          ; vsync counter
OLDEVNT:        .res 2

.segment "CODE"

; ---- start-up ------------------------------------------------------------------------------
VDU_INIT:       .byte 22,129            ; MODE 129: shadow Mode 1
                .byte 23,1,0,0,0,0,0,0,0,0   ; cursor off
VDU_INIT_LEN = * - VDU_INIT

HAL_INIT:
        sei                     ; the tile tables and level data live in DATABANK: keep it paged in from now on
        lda #DATABANK
        sta ROMSEL_SH
        sta ROMSEL
        ldx #0
:       lda VDU_INIT,x
        jsr OSWRCH
        inx
        cpx #VDU_INIT_LEN
        bne :-
        ldy #0                  ; palette: logical colour y -> physical PHYS[y]
:       lda #19
        jsr OSWRCH
        tya
        jsr OSWRCH
        lda PHYS,y
        jsr OSWRCH
        lda #0
        jsr OSWRCH
        jsr OSWRCH
        jsr OSWRCH
        iny
        cpy #4
        bne :-
        ldx #0                  ; buffers: blank screen, black, "drawn" = the same (MODE cleared it)
:       lda #32
        .repeat 5, p
        sta VSCR+p*256,x
        sta SH_CH+p*256,x
        .endrepeat
        lda #0
        .repeat 5, p
        sta VCOL+p*256,x
        sta SH_CO+p*256,x
        .endrepeat
        inx
        bne :-
        ldx #$4F                ; virtual VIC registers + sprite pointers
        lda #0
:       sta VIC,x
        dex
        bpl :-
        ldx #63
:       sta SPR_OLD,x
        dex
        bpl :-
        sta SPR_EN
        jsr HAL_TILES_INVALIDATE
        lda #0                  ; (the call used A)
        ldx #0
:       sta TILE_VALID,x
        inx
        bne :-
        ldx #31
:       sta SP_MCV1,x
        sta SP_MCV2,x
        sta SP_MCM1,x
        sta SP_MCM2,x
        dex
        bpl :-
        lda #64
        sta LSTX
        lda #1
        sta KBDENABLE
        lda #0
        sta KBDCOUNT
        sta KEYQ
        rts

; ---- refresh: make the screen show VSCR/VCOL and the virtual sprites -------------------------
HAL_REFRESH:
        pha
        txa
        pha
        tya
        pha
        jsr SPR_UPDATE
        jsr TILEPASS
        jsr SCAN
        pla
        tay
        pla
        tax
        pla
        rts

; SIG[0..7] = en, xlo, xmsb, y, pointer, colour, mc, mc colours   (all zero if disabled)
SIG_BUILD:
        ldx S_N
        ldy #7
        lda #0
:       sta SIG,y
        dey
        bpl :-
        lda VIC+$15
        and BITS,x
        beq @done
        lda #1
        sta SIG
        txa
        asl a
        tay
        lda VIC,y
        sta SIG+1
        lda VIC+1,y
        sta SIG+3
        lda VIC+$10
        and BITS,x
        beq :+
        lda #1
        sta SIG+2
:       lda VSPTR,x
        sta SIG+4
        lda VIC+$27,x
        and #$0F
        sta SIG+5
        lda VIC+$1C
        and BITS,x
        beq @done
        lda #1
        sta SIG+6
        lda VIC+$25
        asl a
        asl a
        asl a
        asl a
        sta G_V
        lda VIC+$26
        and #$0F
        ora G_V
        sta SIG+7
@done:  rts

; sprites whose appearance changed: force the cells under old and new footprints to be redrawn; then
; (re)build every enabled sprite's record and the per-row sprite masks for the cell renderer
SPR_UPDATE:
        ldx #CELLROWS-1
        lda #0
:       sta SPRROWS,x
        dex
        bpl :-
        sta S_N
@spr:   jsr SIG_BUILD
        lda S_N
        asl a
        asl a
        asl a
        sta S_OFF
        ldx #7
:       txa
        clc
        adc S_OFF
        tay
        lda SIG,x
        cmp SPR_OLD,y
        bne @diff
        dex
        bpl :-
        bmi @rec
@diff:  ldy S_OFF
        lda SPR_OLD,y           ; old footprint
        beq :+
        lda SPR_OLD+1,y
        sta S_X
        lda SPR_OLD+2,y
        sta S_X+1
        lda SPR_OLD+3,y
        sta S_Y
        jsr INVAL
:       lda SIG                 ; new footprint
        beq :+
        lda SIG+1
        sta S_X
        lda SIG+2
        sta S_X+1
        lda SIG+3
        sta S_Y
        jsr INVAL
:       lda S_N                 ; INVAL used S_OFF as scratch
        asl a
        asl a
        asl a
        tay
        ldx #0
:       lda SIG,x
        sta SPR_OLD,y
        iny
        inx
        cpx #8
        bne :-
@rec:   jsr SPR_RECORD
        inc S_N
        lda S_N
        cmp #8
        bne @spr
        rts

; record for sprite S_N from SIG (current state)
SPR_RECORD:
        ldx S_N
        lda SIG
        bne :+
        rts
:       lda SIG+1               ; sx = X-24 (clamped at 0); first byte column = sx>>2
        sec
        sbc #24
        sta G_V
        lda SIG+2
        sbc #0
        sta G_M
        bpl :+
        lda #0
        sta G_V
        sta G_M
:       lda G_M
        lsr a
        lda G_V
        ror a
        lsr a
        sta SP_BC0,x
        lda SIG+3               ; sy = Y-50 (clamped at 0)
        sec
        sbc #50
        bcs :+
        lda #0
:       sta SP_SY,x
        sta G_V
        lsr a
        lsr a
        lsr a
        tay                     ; first cell row
        lda G_V
        clc
        adc #20
        lsr a
        lsr a
        lsr a
        cmp #CELLROWS
        bcc :+
        lda #CELLROWS-1
:       sta S_T2                ; last cell row
        lda BITS,x
        sta G_TMP
        ora SPR_EN
        sta SPR_EN
        tya
        sta SP_R0,x
        lda S_T2
        sta SP_R1,x
        lda SP_BC0,x
        lsr a
        sta SP_C0,x
        lda SP_BC0,x
        clc
        adc #5
        lsr a
        sta SP_C1,x
:       lda SPRROWS,y
        ora G_TMP
        sta SPRROWS,y
        cpy S_T2
        beq :+
        iny
        bne :-
:       lda SIG+4               ; image = GFX bank SPRITES + (p-$90)*64
        sec
        sbc #$90
        sta G_V
        lsr a
        lsr a
        clc
        adc #>SPRITES
        sta SP_SRCH,x
        lda G_V
        and #3
        lsr a
        ror a
        ror a
        sta SP_SRCL,x
        lda SIG+6
        sta SP_MODE,x
        lda SIG+5
        tay
        lda CMASK,y
        sta SP_CM,x
        lda SIG+6
        beq @rts
        txa
        asl a
        asl a
        sta S_T1                ; sprite*4
        ldy #1
        lda VIC+$25
        jsr MCSET
        ldy #2
        lda SIG+5
        jsr MCSET
        ldy #3
        lda VIC+$26
        jsr MCSET
@rts:   rts

; A = C64 colour, Y = q (1..3): fill sprite S_N's multicolour lookups at index S_T1+q
MCSET:  and #$0F
        tax
        lda CMAP,x
        tax
        lda V1TAB,x
        sta G_V
        lda V2TAB,x
        sta G_M
        tya
        clc
        adc S_T1
        tax
        lda G_V
        sta SP_MCV1,x
        lda G_M
        sta SP_MCV2,x
        lda #$CC
        sta SP_MCM1,x
        lda #$33
        sta SP_MCM2,x
        ldx S_N
        rts

; mark the cells under a sprite at raw (S_X 16 bit, S_Y) as not-drawn
INVAL:  lda S_X                 ; sx = X-24 (clamped at 0), column range sx>>3 .. (sx+23)>>3
        sec
        sbc #24
        sta G_V
        lda S_X+1
        sbc #0
        sta G_M
        bpl :+
        lda #0
        sta G_V
        sta G_M
:       lda G_M
        lsr a
        lda G_V
        ror a
        lsr a
        lsr a
        sta G_COL               ; first column
        lda G_V
        clc
        adc #23
        sta G_TMP
        lda G_M
        adc #0
        lsr a
        lda G_TMP
        ror a
        lsr a
        lsr a
        cmp #40
        bcc :+
        lda #39
:       sec
        sbc G_COL
        sta S_B                 ; columns - 1
        lda S_Y                 ; sy = Y-50 (clamped), rows sy>>3 .. (sy+20)>>3
        sec
        sbc #50
        bcs :+
        lda #0
:       sta G_V
        lsr a
        lsr a
        lsr a
        sta S_T1                ; first row
        lda G_V
        clc
        adc #20
        lsr a
        lsr a
        lsr a
        cmp #CELLROWS
        bcc :+
        lda #CELLROWS-1
:       sec
        sbc S_T1
        sta S_T2                ; rows - 1
        ; P_CO = VCOL + row0*40 + col0, P_SO = SH_CO + same
        lda #0
        sta G_M
        lda S_T1                ; row0*40 = row0*32 + row0*8
        asl a
        asl a
        asl a
        sta G_V                 ; row0*8 (<= 192: fits a byte)
        lda #0
        sta G_M
        lda S_T1
        asl a
        asl a
        asl a
        asl a
        asl a
        sta G_TMP               ; low byte of row0*32
        lda S_T1
        lsr a
        lsr a
        lsr a
        sta S_OFF
        lda G_TMP
        clc
        adc G_V
        sta G_V
        lda S_OFF
        adc G_M
        sta G_M                 ; G_M:G_V = row0*40
        lda G_V
        clc
        adc G_COL
        sta P_CO
        sta P_SO
        lda G_M
        adc #0
        sta G_TMP
        clc
        adc #>VCOL
        sta P_CO+1
        lda G_TMP
        clc
        adc #>SH_CO
        sta P_SO+1
@row:   ldy S_B
:       lda (P_CO),y
        eor #$FF
        sta (P_SO),y
        dey
        bpl :-
        lda P_CO
        clc
        adc #40
        sta P_CO
        bcc :+
        inc P_CO+1
:       lda P_SO
        clc
        adc #40
        sta P_SO
        bcc :+
        inc P_SO+1
:       dec S_T2
        bpl @row
        rts

; Compare the virtual screen with what is drawn and draw what differs.  The scan runs with interrupts
; on and MID visible; only the drawing of a cell is a critical section.  VSCR/VCOL/SH_CH/SH_CO are page
; aligned, so each of their 5 pages is scanned with absolute,X compares (cell = 256*page + X) and has its
; own DRAWIDX_p (no pointers).
.macro SCANPAGE p
        .local loop, hit, cont
        ldx #0
loop:   lda VSCR+p*256,x
        cmp SH_CH+p*256,x
        bne hit
        lda VCOL+p*256,x
        cmp SH_CO+p*256,x
        beq cont
hit:    jsr .ident(.concat("DRAWIDX_", .string(p)))
cont:   inx
        bne loop
.endmacro

; cell 256*p + X differs: update SH_*, draw it (with sprites over it if its row has any).  X preserved.
.assert (SCRTOP .mod 256) = 0, error, "DRAWPAGE assumes SCRTOP is page aligned"
.macro DRAWPAGE p
        .local fast, done
.ident(.concat("DRAWIDX_", .string(p))):
        lda VSCR+p*256,x
        sta SH_CH+p*256,x
        tay                     ; Y = char
        lda VCOL+p*256,x
        sta SH_CO+p*256,x
        stx G_COL
        and #$0F
        tax
        lda CMASK,x
        sta G_MASK
        tya                     ; glyph = FONT + char*8
        asl a
        asl a
        asl a
        sta G_GLY
        tya
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a
        clc
        adc #>FONT
        sta G_GLY+1
        lda G_COL               ; P_D0 = SCRTOP + (256*p + X)*16
        asl a
        asl a
        asl a
        asl a
        clc
        adc #<SCRTOP
        sta P_D0
        lda G_COL
        lsr a
        lsr a
        lsr a
        lsr a
        clc                     ; (SCRTOP's low byte is 0, so the add above can't carry)
        adc #>SCRTOP + p*16
        sta P_D0+1
        lda P_D0
        clc
        adc #8
        sta P_D8
        lda P_D0+1
        adc #0
        sta P_D8+1
        lda G_COL               ; sprites over this cell row?
        lsr a
        lsr a
        tay
        lda ROWTAB+p*64,y
        tax
        lda SPRROWS,x
        beq fast
        sta G_SM
        stx G_CY
        lda G_COL
        and #3
        clc
        adc COLTAB+p*64,y
        sta G_CX
        jsr HAL_CELLSPR_CRIT
        jmp done
fast:   jsr HAL_CELL_CRIT
done:   ldx G_COL
        rts
.endmacro

SCAN:   SCANPAGE 0
        SCANPAGE 1
        SCANPAGE 2
        SCANPAGE 3
        SCANPAGE 4
        rts

        DRAWPAGE 0
        DRAWPAGE 1
        DRAWPAGE 2
        DRAWPAGE 3
        DRAWPAGE 4


; ---- display start (CRTC R12/R13) ----------------------------------------------------------------
; The game screen uses all 32 cell rows.  The full screens inherited from the C64 (intro, end, custom keys) are 25 rows;
; HAL_VIEW_CENTRE clears the 7 spare rows and starts the display at row 29, so rows 29-31 (blank) show above the 25 rows
; of the screen and 4 blank rows below, as the 25-row layout was centred before.  The video hardware wraps the start
; address back to the top of the screen memory.
HAL_VIEW_FULL:
        ldx #>(SCRTOP / 8)
        ldy #<(SCRTOP / 8)
        jmp SETSTART
HAL_VIEW_CENTRE:
        jsr HAL_CLEAR_TAIL
        ldx #>((SCRTOP + 29 * 640) / 8)
        ldy #<((SCRTOP + 29 * 640) / 8)
SETSTART:
        lda #12
        sta $FE00
        stx $FE01
        lda #13
        sta $FE00
        sty $FE01
        rts

; rows 25-31 := blank (the game screen leaves its lower rows there)
HAL_CLEAR_TAIL:
        ldx #0
:       lda #32
        sta VSCR+1000,x
        lda #0
        sta VCOL+1000,x
        inx
        bne :-
        ldx #(CELLS - 1000 - 256) - 1
:       lda #32
        sta VSCR+1000+256,x
        lda #0
        sta VCOL+1000+256,x
        dex
        bpl :-
        rts

; ---- window tile fast path --------------------------------------------------------------------
; DRAW_MAP_WINDOW records the base tile id it plotted at each of the 11x7 window positions in TILE_NEW
; ($FF where an overlay was plotted on top or the tile is animated).  A position whose plain tile changed
; is drawn by copying a cached 24x24 image (144 bytes) instead of drawing 9 cells; SH_* is brought up
; to date so the cell scan finds nothing to do there.  Positions with a sprite over them, overlays and
; animated tiles are left to the cell scan.  Tile images are rendered on first use from the cells the
; game plotted (VSCR/VCOL) and kept in sideways banks 6/7 (and 5), indexed directly by tile id.
TILEKIND:                       ; 1 = tile data is animated by the game (ANIMATE_WATER): never cached
        .repeat 256, i
        .byte (i = 20) | (i = 21) | (i = 22) | (i = 143) | (i = 148) | (i = 196) | (i = 197) | (i = 200) | (i = 201) | (i = 204) | (i = 221)
        .endrepeat

KOFF:   .byte 0,1,2,40,41,42,80,81,82

HAL_TILES_INVALIDATE:
        ldx #WIN_W*WIN_H-1
        lda #$FF
:       sta TILE_NEW,x
        sta TILE_SHOWN,x
        dex
        bpl :-
        rts

TILEPASS:
        lda #0
        sta T_TY
        sta T_POS
        sta T_IDX
        sta T_IDX+1
@row:   lda #0
        sta T_TX
@tile:  ldx T_POS
        lda TILE_NEW,x
        cmp TILE_SHOWN,x
        beq @next
        sta T_TILE
        cmp #$FF
        beq @set
        jsr TILE_BLIT
@set:   ldx T_POS
        lda T_TILE
        sta TILE_SHOWN,x
@next:  inc T_POS
        lda T_IDX
        clc
        adc #3
        sta T_IDX
        bcc :+
        inc T_IDX+1
:       inc T_TX
        lda T_TX
        cmp #11
        bne @tile
        lda T_IDX               ; next tile row: +120 cells - 33
        clc
        adc #87
        sta T_IDX
        bcc :+
        inc T_IDX+1
:       inc T_TY
        lda T_TY
        cmp #WIN_H
        bne @row
        rts

; draw tile T_TILE at window position (T_TX,T_TY) from the cache, unless a sprite is over it
TILE_BLIT:
        lda SPR_EN
        beq @free
        lda T_TX                ; tile covers cells c0..c0+2, r0..r0+2
        asl a
        clc
        adc T_TX
        sta S_T1                ; c0
        lda T_TY
        asl a
        clc
        adc T_TY
        sta S_T2                ; r0
        ldx #7
@s:     lda BITS,x
        and SPR_EN
        beq @ns
        lda S_T1
        clc
        adc #2
        cmp SP_C0,x
        bcc @ns
        lda SP_C1,x
        cmp S_T1
        bcc @ns
        lda S_T2
        clc
        adc #2
        cmp SP_R0,x
        bcc @ns
        lda SP_R1,x
        cmp S_T2
        bcc @ns
        rts                     ; a sprite is over it: the cell scan draws it with the sprite
@ns:    dex
        bpl @s
@free:  ldx T_TILE
        lda TILE_VALID,x
        bne @have
        jsr TILE_RENDER
@have:  ldx T_TILE
        jsr TILE_ADDR           ; P_S, BL_BANK
        lda T_IDX               ; P_D0 = SCRTOP + idx*16
        sta S_T1
        lda T_IDX+1
        sta S_T2
        asl S_T1
        rol S_T2
        asl S_T1
        rol S_T2
        asl S_T1
        rol S_T2
        asl S_T1
        rol S_T2
        lda S_T1
        clc
        adc #<SCRTOP
        sta P_D0
        lda S_T2
        adc #>SCRTOP
        sta P_D0+1
        jsr HAL_BLIT_CRIT
        jsr CELLS_SYNC
        rts

; SH_* := VSCR/VCOL for the 3x3 cells of the tile at T_IDX
CELLS_SYNC:
        clc
        lda T_IDX
        adc #<VSCR
        sta P_CH
        lda T_IDX+1
        adc #>VSCR
        sta P_CH+1
        lda T_IDX
        clc
        adc #<VCOL
        sta P_CO
        lda T_IDX+1
        adc #>VCOL
        sta P_CO+1
        lda T_IDX
        clc
        adc #<SH_CH
        sta P_SC
        lda T_IDX+1
        adc #>SH_CH
        sta P_SC+1
        lda T_IDX
        clc
        adc #<SH_CO
        sta P_SO
        lda T_IDX+1
        adc #>SH_CO
        sta P_SO+1
        lda #3
        sta T_K
@r:     ldy #2
:       lda (P_CH),y
        sta (P_SC),y
        lda (P_CO),y
        sta (P_SO),y
        dey
        bpl :-
        ldx #0                  ; all four pointers +40
:       lda P_CH,x
        clc
        adc #40
        sta P_CH,x
        bcc :+
        inc P_CH+1,x
:       inx
        inx
        cpx #8
        bne :--
        dec T_K
        bne @r
        rts

; X = tile id -> P_S = address of its image, BL_BANK = bank: tiles 0-112 bank 6, 113-225 bank 7, 226+ bank 5 at CACHEB5
TILE_ADDR:
        txa
        ldy #6
        cmp #113
        bcc @j
        ldy #7
        sbc #113
        cmp #113
        bcc @j
        ldy #5
        sbc #113
@j:     sty BL_BANK
        sta T_J                 ; j*144 = (j*9)<<4
        sta P_S
        lda #0
        sta P_S+1
        asl P_S
        rol P_S+1
        asl P_S
        rol P_S+1
        asl P_S
        rol P_S+1
        lda P_S
        clc
        adc T_J
        sta P_S
        bcc :+
        inc P_S+1
:       asl P_S
        rol P_S+1
        asl P_S
        rol P_S+1
        asl P_S
        rol P_S+1
        asl P_S
        rol P_S+1
        lda BL_BANK
        ldy #>$8000
        cmp #5
        bne :+
        ldy #>CACHEB5
:       tya
        clc
        adc P_S+1
        sta P_S+1
        rts

; render tile T_TILE from the cells just plotted at T_IDX into TBUF, then store it in the cache
TILE_RENDER:
        clc
        lda T_IDX
        adc #<VSCR
        sta P_CH
        lda T_IDX+1
        adc #>VSCR
        sta P_CH+1
        lda T_IDX
        clc
        adc #<VCOL
        sta P_CO
        lda T_IDX+1
        adc #>VCOL
        sta P_CO+1
        lda #0
        sta T_K
@k:     ldx T_K
        ldy KOFF,x
        lda (P_CO),y
        and #$0F
        tax
        lda CMASK,x
        sta G_MASK
        lda (P_CH),y
        sta G_TMP               ; glyph = FONT + char*8
        asl a
        asl a
        asl a
        sta G_GLY
        lda G_TMP
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a
        clc
        adc #>FONT
        sta G_GLY+1
        lda T_K                 ; P_D0 = TBUF + k*16
        asl a
        asl a
        asl a
        asl a
        clc
        adc #<TBUF
        sta P_D0
        lda #>TBUF
        adc #0
        sta P_D0+1
        lda P_D0
        clc
        adc #8
        sta P_D8
        lda P_D0+1
        adc #0
        sta P_D8+1
        jsr HAL_CELL_CRIT
        inc T_K
        lda T_K
        cmp #9
        bne @k
        ldx T_TILE
        jsr TILE_ADDR
        sei                     ; page the cache bank in just for the copy
        lda BL_BANK
        sta ROMSEL_SH
        sta ROMSEL
        ldy #0
:       lda TBUF,y
        sta (P_S),y
        iny
        cpy #TILEBYTES
        bne :-
        lda #DATABANK
        sta ROMSEL_SH
        sta ROMSEL
        cli
        ldx T_TILE
        lda #1
        sta TILE_VALID,x
        rts

; throttled HAL_REFRESH: at most every 3rd vsync (a full scan costs ~10-20 ms), and only started by the first poll after
; a vsync, so the redraw begins while the beam is at the top of the frame (the game polls far more often than 50 Hz).
; Called from every place the game polls or waits: HAL_GETKEY, BACKGROUND_TASKS.
HAL_TICK_REFRESH:
        pha
        lda VSYNCFLAG
        beq @no
        lda #0
        sta VSYNCFLAG
        lda TICKS
        sec
        sbc LASTREF
        cmp #3
        bcc @no
        lda TICKS
        sta LASTREF
        jsr HAL_REFRESH
@no:    pla
        rts


; ---- keyboard ------------------------------------------------------------------------------
; The C64 game reads the KERNAL key queue (JSR $F142 / $FFE4) and re-queues a held key when it
; pokes $C5 = 64.  HAL_GETKEY reproduces that on the OS keyboard buffer:
;   a new key in the OS buffer  -> PETSCII code, LSTX = code (a key is held)
;   LSTX forced to 64 by the game while the key is still down (OSBYTE &81 test) -> same code again
;   key released               -> LSTX = 64
; BBC internal key numbers are from b-em's keyboard matrix table (key_allegro2bbc).
KEYSET:                         ; OS code, internal key number, PETSCII
        .byte 32,$62,32         ; space
        .byte 13,$49,13         ; return
        .byte 27,$70,3          ; escape = RUN/STOP (*FX229,1 makes it a character)
        .byte 139,$39,$91       ; cursor up
        .byte 138,$29,$11       ; down
        .byte 136,$19,$9D       ; left
        .byte 137,$79,$1D       ; right
        .byte 193,$71,133       ; f1  (*FX225,192 moves the function keys to 192+n: no clash with COPY)
        .byte 195,$73,134       ; f3
        .byte 197,$74,135       ; f5
        .byte 199,$16,136       ; f7  (map)
        .byte 9,$60,223         ; tab = C= + * (cheat)
        .byte 127,$59,20        ; delete
KEYSET_N = 13
; digits '0'..'9'
KEYNUM_DIGIT: .byte $27,$30,$31,$11,$12,$13,$34,$24,$15,$26
; letters 'A'..'Z'
KEYNUM_LETTER: .byte $41,$64,$52,$32,$22,$43,$53,$54,$25,$45,$46,$56,$65,$55,$36,$37,$10,$33,$51,$23,$35,$63,$42,$21,$44,$61

HELD:   .byte 0                 ; internal key number of the key being tracked, 0 = none ($00 is SHIFT, never tracked)
HELDPET: .byte 0

; A = OS character -> A = PETSCII, X = internal key number; A = 0 if the key isn't used
KEYMAP:
        cmp #'a'
        bcc @notlow
        cmp #'z'+1
        bcs @notlow
        and #$DF                ; lower case -> upper case
@letter: sec
        sbc #'A'
        tax
        lda KEYNUM_LETTER,x
        tax
        lda OSCH
        and #$DF                ; PETSCII letter; the caller adds 128 if SHIFT is down.
        rts                     ; (CAPS LOCK makes the OS return upper case without SHIFT, so the case can't be trusted)
@notlow: cmp #'A'
        bcc @notup
        cmp #'Z'+1
        bcs @notup
        jmp @letter
@notup: cmp #'0'
        bcc @sp
        cmp #'9'+1
        bcs @sp
        sec
        sbc #'0'
        tax
        lda KEYNUM_DIGIT,x
        tax
        lda OSCH
        rts
@sp:    ldy #0
:       lda KEYSET,y
        cmp OSCH
        beq @found
        iny
        iny
        iny
        cpy #KEYSET_N*3
        bne :-
        lda #0
        rts
@found: ldx KEYSET+1,y
        lda KEYSET+2,y
        rts

OSCH:   .byte 0

; returns A = key (0 = none); X and Y preserved
HAL_GETKEY:
        txa
        pha
        tya
        pha
        jsr HAL_TICK_REFRESH    ; every key poll is a point where the screen catches up
        lda KBDENABLE
        bne :+
        jsr FLUSHKEYS           ; keyboard off: drop whatever is typed
        lda #0
        sta KEYQ
        jmp @out
:       lda HELD                ; still holding the last key?
        beq @new
        eor #$FF
        tax
        ldy #$FF
        lda #$81
        jsr OSBYTE
        cpx #$FF
        beq @still
        lda #0
        sta HELD
        lda #64
        sta LSTX
        jmp @new
@still: lda LSTX                ; the game cleared LSTX: queue the held key again
        cmp #64
        bne @new
        lda HELDPET
        sta KEYQ
        sta LSTX
@new:   lda KEYQ
        bne @out
        lda #$91                ; OSBYTE 145: get a byte from the keyboard buffer
        ldx #0
        jsr OSBYTE
        bcs @out                ; empty
        sty OSCH
        tya
        jsr KEYMAP
        beq @out
        cmp #'A'                ; a letter with SHIFT down is the shifted PETSCII letter ($C1-$DA)
        bcc @store
        cmp #'Z'+1
        bcs @store
        pha
        stx G_TMP
        ldx #$FF                ; INKEY(-1): SHIFT
        ldy #$FF
        lda #$81
        jsr OSBYTE
        lda #0
        cpx #$FF
        bne :+
        lda #128
:       sta G_V
        ldx G_TMP
        pla
        clc
        adc G_V
@store: sta KEYQ
        sta HELDPET
        sta LSTX
        stx HELD
@out:   lda KEYQ
        sta G_V
        lda #0
        sta KEYQ
        pla
        tay
        pla
        tax
        lda G_V
        rts

FLUSHKEYS:
        lda #15
        ldx #1
        jmp OSBYTE

; ---- OS setup, vsync tick ------------------------------------------------------------------
; OSBYTE A,X,Y to issue at start-up
OSB_INIT:
        .byte 4,1,0             ; cursor keys return 136-139, no editing
        .byte 225,192,0         ; function keys return 192+n
        .byte 229,1,0           ; ESCAPE is an ordinary character
        .byte 11,0,0            ; no auto-repeat: the game does its own
        .byte 15,1,0            ; flush the keyboard buffer
OSB_INIT_N = 5

HAL_OS_SETUP:
        lda #0
        sta G_TMP
:       ldy G_TMP
        lda OSB_INIT+1,y
        tax
        lda OSB_INIT+2,y
        sta G_V
        lda OSB_INIT,y
        ldy G_V
        jsr OSBYTE
        lda G_TMP
        clc
        adc #3
        sta G_TMP
        cmp #OSB_INIT_N*3
        bne :-
        ; vsync event -> EVT
        sei
        lda EVNTV
        sta OLDEVNT
        lda EVNTV+1
        sta OLDEVNT+1
        lda #<EVT
        sta EVNTV
        lda #>EVT
        sta EVNTV+1
        cli
        lda #14                 ; enable event 4 (vertical sync)
        ldx #4
        jmp OSBYTE

EVT:    cmp #4
        bne @chain
        pha
        txa
        pha
        tya
        pha
        inc TICKS
        lda #1
        sta VSYNCFLAG
        jsr RUNIRQ
        pla
        tay
        pla
        tax
        pla
@chain: jmp (OLDEVNT)

; ---- data loading --------------------------------------------------------------------------
; OSCLI command at X/Y (CR terminated).  *SRLOAD uses a HAZEL buffer, so user RAM is untouched.
HAL_OSCLI:
        jmp OSCLI
