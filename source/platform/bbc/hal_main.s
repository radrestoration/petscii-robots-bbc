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
SP_MCV1:        .res 32         ; multicolour lookups, index q*8 + sprite (q = 0 stays 0 = transparent)
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
TILE_NEW:       .res WIN_W*WIN_H         ; cache slot (HAL_TILE_KEY) of the tile the game just drew at each window position, $FF = overlay/uncached/unknown
TILE_SHOWN:     .res WIN_W*WIN_H         ; ... and what is on screen
TILE_VALID:     .res 256        ; per cache slot: the tile image is in the cache
KPHASE:         .res 4          ; per TILEKIND: the animation phase now (kind 2 counts 0-2, kind 3 counts 0-1; HAL_ANIM_STEP)
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
SND_ID:         .res 1          ; effect playing ($FF none)
SND_PRIO_CUR:   .res 1
SND_TIMER:      .res 1          ; frames until the next note / step
SND_TIMER_R:    .res 1
SND_STEP_L:     .res 1          ; signed 16-bit period change per step
SND_STEP_H:     .res 1
SND_NSTEP:      .res 1
SND_N_L:        .res 1          ; current period
SND_N_H:        .res 1
SND_VOL:        .res 1          ; current loudness 0-15
SND_NOISE:      .res 1          ; 0 tone, $40 noise
SND_FADE:       .res 1          ; non-zero: fading out, value = loudness
VIEW_PENDING:   .res 1          ; display start change waiting for the next completed refresh: 0 none, 1 full, 2 centred
WANTREF:        .res 1          ; the game says the screen has changed: refresh at the next vsync, whatever the throttle
VSYNCFLAG:      .res 1          ; set by every vsync, consumed by HAL_TICK_REFRESH
LASTREF:        .res 1          ; vsync tick of the last refresh
LASTARROW:      .res 1          ; vsync tick of the last direct arrow-key scan
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
        lda #0
        sta G_V
        jsr HAL_SETPAL          ; palette
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
        lda #0
        sta VIEW_PENDING
        sta WANTREF
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
        jsr APPLY_VIEW
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
        beq :+
        jmp @spr
:       ; which window tiles have a sprite over them (so the tile fast path leaves them to the cell scan)
        ldx #WIN_W*WIN_H-1
        lda #0
:       sta SPRTILE,x
        dex
        bpl :-
        lda SPR_EN
        beq @rts
        lda #7
        sta S_N
@mark:  ldx S_N
        lda BITS,x
        and SPR_EN
        beq @mnext
        lda SP_C0,x             ; tile columns DIV3[c0] .. DIV3[min(c1,32)], tile rows DIV3[r0] .. DIV3[min(r1,26)]
        cmp #33
        bcs @mnext              ; entirely in the side panel
        tay
        lda DIV3,y
        sta S_T1                ; first tile column
        lda SP_C1,x
        cmp #33
        bcc :+
        lda #32
:       tay
        lda DIV3,y
        sta S_T2                ; last tile column
        ldy SP_R0,x
        lda DIV3,y
        sta G_V                 ; row counter
        ldy SP_R1,x
        cpy #27
        bcc :+
        ldy #26
:       lda DIV3,y
        sta G_M                 ; last tile row
@mrow:  lda G_V                 ; pos = row*11 + first column
        asl a
        asl a
        asl a
        clc
        adc G_V
        clc
        adc G_V
        clc
        adc G_V
        clc
        adc S_T1
        tay
        lda S_T1
        sta G_TMP
@mcol:  lda #1
        sta SPRTILE,y
        iny
        inc G_TMP
        lda G_TMP
        cmp S_T2
        bcc @mcol
        beq @mcol
        inc G_V
        lda G_V
        cmp G_M
        bcc @mrow
        beq @mrow
@mnext: dec S_N
        bpl @mark
@rts:   rts

DIV3:   .repeat 40, i
        .byte i / 3
        .endrepeat

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

; A = C64 colour, Y = q (1..3): fill sprite S_N's multicolour lookups at index q*8+sprite
MCSET:  and #$0F
        tax
        lda CMAP,x
        tax
        lda V1TAB,x
        sta G_V
        lda V2TAB,x
        sta G_M
        tya
        asl a
        asl a
        asl a
        clc
        adc S_N
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



; ---- sound effects (SN76489) ------------------------------------------------------------------------
; PLAY_SOUND (A = the C64 version's sound id 0-18) starts an effect unless a more important one is playing; SOUND_TICK, called
; from the vsync event every frame (interrupts off, so the chip is not shared with the OS's own keyboard scanning of port A),
; steps it.  The engine is the Plus4 version's, converted by tools/make_sound.py (note format described there).
.include "sound.inc"

HAL_PLAY_SOUND:
        tax
        lda SND_ID
        cmp #$FF
        beq @go
        lda SND_PRIO,x          ; larger = more important
        cmp SND_PRIO_CUR
        bcc @no                 ; less important than the one playing
@go:    php
        sei
        lda SND_PRIO,x
        sta SND_PRIO_CUR
        stx SND_ID
        lda SND_FX_L,x
        sta SND_PTR
        lda SND_FX_H,x
        sta SND_PTR+1
        lda #0
        sta SND_TIMER
        sta SND_NSTEP
        sta SND_FADE
        plp
@no:    rts

SOUND_INIT:
        php
        sei
        lda #$FF
        sta SND_ID
        jsr SN_BEGIN
        jsr SN_SILENCE
        jsr SN_END
        plp
        rts

SOUND_TICK:
        lda SND_ID
        cmp #$FF
        bne :+
        rts
:       jsr SN_BEGIN
        jsr SND_STEP
        jmp SN_END

SND_STEP:
        lda SND_FADE
        beq @nofade
        sec
        sbc #2
        bcc @stop
        beq @stop
        sta SND_FADE
        sta SND_VOL
        jsr SN_VOL
@nofade:
        lda SND_TIMER
        beq @next
        dec SND_TIMER
        rts
@next:  lda SND_NSTEP
        beq @load
        dec SND_NSTEP
        lda SND_TIMER_R
        sta SND_TIMER
        clc                     ; period += step, clamped to 8..1023
        lda SND_N_L
        adc SND_STEP_L
        sta SND_N_L
        lda SND_N_H
        adc SND_STEP_H
        bmi @low
        cmp #4
        bcc @ok
        lda #$FF                ; above 1023
        sta SND_N_L
        lda #3
        bne @ok
@low:   lda #8
        sta SND_N_L
        lda #0
@ok:    sta SND_N_H
        lda SND_N_H
        bne @fin
        lda SND_N_L             ; clamp at 8 (as the reference player and the converter do)
        cmp #8
        bcs @fin
        lda #8
        sta SND_N_L
@fin:   jmp SN_PERIOD
@stop:  lda #$FF
        sta SND_ID
        jmp SN_SILENCE
@load:  ldy #0                  ; next note
        lda (SND_PTR),y
        sta SND_N_L
        iny
        lda (SND_PTR),y
        tax
        and #3
        sta SND_N_H
        txa
        and #$40
        sta SND_NOISE
        iny
        lda (SND_PTR),y
        bpl @play
        lda #$FF                ; end of effect
        sta SND_ID
        jmp SN_SILENCE
@play:  sta SND_VOL
        jsr SN_NOTE
        ldy #3
        lda (SND_PTR),y
        tax
        and #$7F
        sta SND_TIMER
        sta SND_TIMER_R
        lda #0
        sta SND_NSTEP
        sta SND_STEP_L
        sta SND_STEP_H
        ldy #4
        txa
        bpl @len4
        lda (SND_PTR),y         ; step lo
        sta SND_STEP_L
        iny
        lda (SND_PTR),y         ; step hi
        sta SND_STEP_H
        iny
        lda (SND_PTR),y         ; step count
        sta SND_NSTEP
        cmp #$FF
        bne :+
        lda SND_VOL             ; $FF: fade out from here
        sta SND_FADE
:       lda #7
        bne @adv
@len4:  lda #4
@adv:   clc                     ; ptr += record length
        adc SND_PTR
        sta SND_PTR
        bcc :+
        inc SND_PTR+1
:       rts

; --- SN76489 ------------------------------------------------------------------------------------------
; Port A (&FE41) carries the byte, bit 0 of the system VIA's addressable latch (&FE40: write $00 / $08) is the chip's /WE.
; Port A is an input on bit 7 for the keyboard, so DDRA is only made all-output for the duration of an update.
SN_BEGIN:
        lda #$FF
        sta $FE43
        rts
SN_END:
        lda #$7F
        sta $FE43
        rts
SN_OUT:
        sta $FE41
        lda #0
        sta $FE40
        nop                     ; /WE low for at least 8 us (16 cycles of 2 MHz)
        nop
        nop
        nop
        nop
        nop
        lda #8
        sta $FE40
        rts
SN_SILENCE:
        lda #$9F
        jsr SN_OUT
        lda #$BF
        jsr SN_OUT
        lda #$DF
        jsr SN_OUT
        lda #$FF
        jmp SN_OUT

; channel 0 (tone) or channel 2 (drives the noise rate) period from SND_N
SN_PERIOD:
        lda SND_NOISE
        beq @tone
        lda #$C0                ; channel 2
        bne @w
@tone:  lda #$80                ; channel 0
@w:     sta SND_T
        lda SND_N_L
        and #$0F
        ora SND_T
        jsr SN_OUT
        lda SND_N_L
        lsr a
        lsr a
        lsr a
        lsr a
        sta SND_T
        lda SND_N_H
        asl a
        asl a
        asl a
        asl a
        ora SND_T
        jmp SN_OUT

; attenuation of the active channel from SND_VOL (loudness 0-15)
SN_VOL:
        lda #15
        sec
        sbc SND_VOL
        sta SND_T
        lda SND_NOISE
        beq @tone
        lda #$F0                ; noise channel
        bne @w
@tone:  lda #$90                ; channel 0
@w:     ora SND_T
        jmp SN_OUT

; start the current note: tone on channel 0, or white noise clocked by channel 2's period (channel 2 itself silent)
SN_NOTE:
        lda SND_NOISE
        beq @tone
        lda #$9F                ; channel 0 off
        jsr SN_OUT
        lda #$DF                ; channel 2 off (its period still sets the noise rate)
        jsr SN_OUT
        jsr SN_PERIOD
        lda #$E7                ; white noise, rate = channel 2
        jsr SN_OUT
        jmp SN_VOL
@tone:  lda #$FF                ; noise off
        jsr SN_OUT
        jsr SN_PERIOD
        jmp SN_VOL

; ---- overview map (f7) ----------------------------------------------------------------------------
; The picture is the 128x64 map, one pixel per tile (white where the tile can't be walked on), in a block of 16 x 8 cells
; (MAP_COL0, MAP_ROW0 of the map screen).  It is drawn straight into the screen memory over cells that the cell scan
; believes are blank, so the scan never touches them.  Each cell row is first built as 8-byte glyphs in MAPROW and drawn
; with the normal cell code.  The blinking dots are single pixels read-modified-written by HAL_PIXEL_CRIT.
MAPDEST_L: .repeat 8, r
        .byte <(SCRTOP + (MAP_ROW0 + r) * 640 + MAP_COL0 * 16)
        .endrepeat
MAPDEST_H: .repeat 8, r
        .byte >(SCRTOP + (MAP_ROW0 + r) * 640 + MAP_COL0 * 16)
        .endrepeat
PIXMASK: .byte $88,$44,$22,$11

; blank the block in the virtual screen (the decompressed map screen has the C64's redefined-character codes there)
HAL_MAP_BLANK:
        lda #<(VSCR + MAP_ROW0 * 40 + MAP_COL0)
        sta P_CH
        lda #>(VSCR + MAP_ROW0 * 40 + MAP_COL0)
        sta P_CH+1
        lda #<(VCOL + MAP_ROW0 * 40 + MAP_COL0)
        sta P_CO
        lda #>(VCOL + MAP_ROW0 * 40 + MAP_COL0)
        sta P_CO+1
        ldx #8
@r:     ldy #15
:       lda #32
        sta (P_CH),y
        lda #1
        sta (P_CO),y
        dey
        bpl :-
        lda P_CH
        clc
        adc #40
        sta P_CH
        bcc :+
        inc P_CH+1
:       lda P_CO
        clc
        adc #40
        sta P_CO
        bcc :+
        inc P_CO+1
:       dex
        bne @r
        rts

HAL_MAP_RENDER:
        lda #0
        sta T_K                 ; block cell row 0-7
@row:   lda #0
        sta S_T2                ; line 0-7 within the cell row
@line:  lda T_K                 ; map row y = 8*cellrow + line; pointer = MAP + y*128
        asl a
        asl a
        asl a
        clc
        adc S_T2
        sta S_T1
        lsr a
        clc
        adc #>MAP
        sta P_CH+1
        lda S_T1
        lsr a
        lda #0
        ror a
        sta P_CH
        ldy #0
@grp:   lda #0
        sta G_V
@x:     lda (P_CH),y
        tax
        lda TILE_ATTRIB,x
        lsr a                   ; carry = can be walked on
        rol G_V
        iny
        tya
        and #7
        bne @x
        tya                     ; 8 tiles done: glyph byte = 1 where NOT walkable; MAPROW[cell*8 + line]
        lsr a
        lsr a
        lsr a
        sec
        sbc #1
        asl a
        asl a
        asl a
        clc
        adc S_T2
        tax
        lda G_V
        eor #$FF
        sta MAPROW,x
        cpy #128
        bne @grp
        inc S_T2
        lda S_T2
        cmp #8
        bne @line
        ldx T_K                 ; draw the 16 cells of this row
        lda MAPDEST_L,x
        sta P_D0
        lda MAPDEST_H,x
        sta P_D0+1
        lda #<MAPROW
        sta G_GLY
        lda #>MAPROW
        sta G_GLY+1
        lda CMASK+1             ; white
        sta G_MASK
        lda #16
        sta S_T2
@cell:  lda P_D0
        clc
        adc #8
        sta P_D8
        lda P_D0+1
        adc #0
        sta P_D8+1
        jsr HAL_CELL_CRIT
        lda P_D0
        clc
        adc #16
        sta P_D0
        bcc :+
        inc P_D0+1
:       lda G_GLY
        clc
        adc #8
        sta G_GLY
        dec S_T2
        bne @cell
        inc T_K
        lda T_K
        cmp #8
        beq :+
        jmp @row
:       rts

; A = 1 set / 0 clear the map-picture pixel at (MAP_X, MAP_Y)
HAL_MAP_PIXEL:
        sta G_V
        lda MAP_Y
        lsr a
        lsr a
        lsr a
        tax
        lda MAPDEST_L,x
        sta P_D0
        lda MAPDEST_H,x
        sta P_D0+1
        lda MAP_X               ; + 16 bytes per cell column
        lsr a
        lsr a
        lsr a
        asl a
        asl a
        asl a
        asl a
        clc
        adc P_D0
        sta P_D0
        bcc :+
        inc P_D0+1
:       lda MAP_X               ; + 8 for the right-hand byte of the cell, + pixel row
        and #4
        asl a
        sta G_TMP
        lda MAP_Y
        and #7
        ora G_TMP
        clc
        adc P_D0
        sta P_D0
        bcc :+
        inc P_D0+1
:       lda MAP_X
        and #3
        tax
        lda PIXMASK,x
        sta G_M
        jmp HAL_PIXEL_CRIT

; ---- display start (CRTC R12/R13) ----------------------------------------------------------------
; The game screen uses all 32 cell rows.  The full screens inherited from the C64 (intro, end, custom keys) are 25 rows;
; HAL_VIEW_CENTRE clears the 7 spare rows and starts the display at row 29, so rows 29-31 (blank) show above the 25 rows
; of the screen and 4 blank rows below, as the 25-row layout was centred before.  The video hardware wraps the start
; address back to the top of the screen memory.
HAL_VIEW_FULL:
        lda #1
        bne QUEUE_VIEW
HAL_VIEW_CENTRE:
        jsr HAL_CLEAR_TAIL
        lda #2
; The change takes effect when the next refresh has drawn the new screen; until then the display is blanked (all logical
; colours black), so neither the old picture jumping by 3 rows nor the new one drawing in at the wrong place is seen.
QUEUE_VIEW:
        sta VIEW_PENDING
        lda #1
        sta G_V
        jmp HAL_SETPAL

; (end of HAL_REFRESH) apply a queued view change and restore the palette
APPLY_VIEW:
        lda VIEW_PENDING
        beq @done
        ldx #>(SCRTOP / 8)
        ldy #<(SCRTOP / 8)
        cmp #1
        beq :+
        ldx #>((SCRTOP + 29 * 640) / 8)
        ldy #<((SCRTOP + 29 * 640) / 8)
:       jsr SETSTART
        lda #0
        sta VIEW_PENDING
        sta G_V
        jmp HAL_SETPAL
@done:  rts

; Set the four logical colours (G_V = 0: the game palette PHYS, else black) through the OS: VDU 19.  Writing the video ULA's
; palette register directly would set only 4 of the 16 entries a 4-colour mode uses (each logical colour occupies four).
HAL_SETPAL:
        ldy #0
@l:     lda #19
        jsr OSWRCH
        tya
        jsr OSWRCH
        lda G_V
        bne @black
        lda PHYS,y
        jmp @w
@black: lda #0
@w:     jsr OSWRCH
        lda #0
        jsr OSWRCH
        jsr OSWRCH
        jsr OSWRCH
        iny
        cpy #4
        bne @l
        rts

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
; DRAW_MAP_WINDOW records the cache slot of the plain tile it plotted at each of the 11x7 window positions in TILE_NEW
; ($FF where an overlay was plotted on top or the tile is never cached).  A position whose slot changed
; is drawn by copying a cached 24x24 image (144 bytes) instead of drawing 9 cells; SH_* is brought up
; to date so the cell scan finds nothing to do there.  Positions with a sprite over them, overlays and
; uncached tiles are left to the cell scan.  Tile images are rendered on first use from the cells the
; game plotted (VSCR/VCOL) and kept in sideways banks 6/7 (and 5), indexed by slot.
; The slot is TSLOT[id] + the animation phase of the tile's kind: the animated tiles (water, fans...) cycle through 2 or 3 images
; (the game's ANIMATE_WATER rotates their characters/colours; tools/anim_test.py checks that), each with its own slot.
.include "tile_kind.inc"        ; TILEKIND: per tile id, 0 plain, 1 never cached, 2 animated (period 3), 3 animated (period 2)

; X = tile id -> A = its cache slot now, $FF = never cached.  (Y is used.)  The caller must keep interrupts off from here until it
; has plotted the tile, so that the tile data it plots belongs to the phase it keyed.
HAL_TILE_KEY:
        ldy TILEKIND,x
        lda TSLOT,x             ; (255 for the uncached tiles: kind 1 adds 0)
        clc
        adc KPHASE,y
        rts

; one animation step (ANIMATE_WATER, from the vsync handler, just before it rotates the tile data): move the phases on
HAL_ANIM_STEP:
        ldx KPHASE+2
        inx
        cpx #3
        bcc :+
        ldx #0
:       stx KPHASE+2
        lda KPHASE+3
        eor #1
        sta KPHASE+3
        rts

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
        ldx T_POS
        lda SPRTILE,x
        beq @free
        rts                     ; a sprite is over it: the cell scan draws it with the sprite
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

; SH_* := VSCR/VCOL for the 3x3 cells of the tile at T_IDX.  VCOL, SH_CH and SH_CO are whole pages away from VSCR, so
; with X = the low byte of T_IDX one unrolled copy per page of the cell index does it (absolute,X carries into the next
; page by itself).  A window tile's cell index is at most 990 + 82, so pages 0-3.
.macro SYNCPAGE p
.ident(.concat("SYNCP_", .string(p))):
        .repeat 9, k
        lda VSCR + p*256 + (k / 3) * 40 + (k .mod 3), x
        sta SH_CH + p*256 + (k / 3) * 40 + (k .mod 3), x
        lda VCOL + p*256 + (k / 3) * 40 + (k .mod 3), x
        sta SH_CO + p*256 + (k / 3) * 40 + (k .mod 3), x
        .endrepeat
        rts
.endmacro
CELLS_SYNC:
        ldx T_IDX
        lda T_IDX+1
        beq @p0
        cmp #2
        bcc @p1
        beq @p2
        jmp SYNCP_3
@p0:    jmp SYNCP_0
@p1:    jmp SYNCP_1
@p2:    jmp SYNCP_2
        SYNCPAGE 3
        SYNCPAGE 2
        SYNCPAGE 1
        SYNCPAGE 0

; X = cache slot -> P_S = address of its image, BL_BANK = bank: slots 0-112 bank 6, 113-225 bank 7, 226+ bank 5 at CACHEB5
J144LO: .repeat 113, j
        .byte <(j * TILEBYTES)
        .endrepeat
J144HI: .repeat 113, j                  ; with &8000 added
        .byte >(j * TILEBYTES) + $80
        .endrepeat
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
        tax                     ; X = index within the bank
        lda J144LO,x
        sta P_S
        lda J144HI,x
        cpy #5
        bne :+
        clc
        adc #>CACHEB5 - $80
:       sta P_S+1
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

; throttled HAL_REFRESH: started only by the first poll after a vsync, so the redraw begins while the beam is at the top of the
; frame (the game polls far more often than 50 Hz), and then either at once if the game flagged a change (HAL_WANT_REFRESH, from
; DRAW_MAP_WINDOW) or at most every 3rd vsync as a safety net for the places that write the screen without saying so.
; Called from every place the game polls or waits: HAL_GETKEY, BACKGROUND_TASKS.
HAL_WANT_REFRESH:
        lda #1
        sta WANTREF
        rts

HAL_TICK_REFRESH:
        pha
        lda VSYNCFLAG
        beq @no
        lda #0
        sta VSYNCFLAG
        lda WANTREF
        bne @go
        lda TICKS
        sec
        sbc LASTREF
        cmp #3
        bcc @no
@go:    lda #0
        sta WANTREF
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
        .byte 193,$71,133       ; f1  weapons  (*FX225,192 moves the function keys to 192+n: no clash with COPY).  b-em's host F-keys are
        .byte 194,$72,133       ; f2  weapons  ; numbered differently in its physical (host F1 = f0) and logical (host F1 = f1) keyboard
        .byte 195,$73,134       ; f3  items    ; modes, so each function is on two or three neighbouring keys
        .byte 196,$14,134       ; f4  items
        .byte 197,$74,135       ; f5
        .byte 198,$75,136       ; f6  map
        .byte 199,$16,136       ; f7  map
        .byte 200,$76,136       ; f8  map
        .byte 9,$60,223         ; tab = C= + * (cheat)
        .byte 127,$59,20        ; delete
KEYSET_N = 16
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
; keys scanned directly with INKEY when the OS buffer has nothing: cursor keys and function keys (internal key numbers, PETSCII)
ARROWKEY: .byte $39,$29,$19,$79, $71,$72,$73,$14,$74,$75,$16,$76
ARROWPET: .byte $91,$11,$9D,$1D, 133,133,134,134,135,136,136,136
ARROWN = 12

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
        beq :+
        jmp @out
:
        lda #$91                ; OSBYTE 145: get a byte from the keyboard buffer
        ldx #0
        jsr OSBYTE
        bcs @poll               ; empty
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
        jmp @out
; Nothing in the OS buffer: look at the cursor and function keys directly (INKEY), once per vsync, so they work whatever the OS's
; cursor-key mode or key buffer is doing.  Only when no key is being tracked already (a press the buffer did deliver sets HELD).
@poll:  lda HELD
        bne @out
        lda TICKS
        cmp LASTARROW
        beq @out
        sta LASTARROW
        ldx #ARROWN-1
@a:     stx G_TMP
        lda ARROWKEY,x
        eor #$FF
        tax
        ldy #$FF
        lda #$81
        jsr OSBYTE
        cpx #$FF
        beq @af
        ldx G_TMP
        dex
        bpl @a
        jmp @out
@af:    ldx G_TMP
        lda ARROWPET,x
        sta KEYQ
        sta HELDPET
        sta LSTX
        lda ARROWKEY,x
        sta HELD
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
        jsr SOUND_INIT
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
        lda ROMSEL_SH           ; the event can arrive while the MOS has another bank paged (a *SRLOAD into bank 5 is copying):
        pha                     ; the game's per-frame code assumes DATABANK, so page it for the handler and give the MOS its bank back
        lda #DATABANK
        sta ROMSEL_SH
        sta ROMSEL
        inc TICKS
        lda #1
        sta VSYNCFLAG
        jsr SOUND_TICK
        jsr RUNIRQ
        pla
        sta ROMSEL_SH
        sta ROMSEL
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
