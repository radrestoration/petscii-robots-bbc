; BBC Master port - Mode 1 renderer and software sprites.  Runs from the sideways bank GFXBANK
; at &8000, only ever entered by the trampolines in hal_low.s with interrupts off, ROMSEL =
; GFXBANK and ACCCON.X = 1 (so &3000-&7FFF is the screen).  See defs.s.
;
; The game still "writes screen RAM": it writes the virtual VSCR/VCOL (low RAM) exactly as the C64
; code writes $E000/$D800.  HAL_REFRESH compares them with SH_CH/SH_CO (what is drawn) and draws
; only the cells that differ.  Mode 1 cell (col,row) = 16 bytes at SCRTOP + (row*40+col)*16:
; 8 bytes for the left 4 pixels (one per pixel row) then 8 for the right 4.
; A glyph row byte b (8 hi-res pixels, bit 7 left) becomes two screen bytes: LTAB[b] and RTAB[b]
; have both bit planes set for each lit pixel; ANDed with the colour's mask ($0F/$F0/$FF) that
; selects logical colour 1/2/3.

.segment "GFX"

; ---- constant tables -------------------------------------------------------------------------
        .align 256
LTAB:   .repeat 256, i
        .byte ((i >> 4) * 17)
        .endrepeat
RTAB:   .repeat 256, i
        .byte ((i & 15) * 17)
        .endrepeat

        .align 256
FONT:   .incbin "font.bin"      ; 256 glyphs x 8 bytes
SPRITES: .incbin "sprites.bin"  ; 43 C64 sprites x 64 bytes

; ---- GFX_CELL: draw one 8x8 cell ---------------------------------------------------------------
; in: G_GLY -> glyph (8 bytes), G_MASK = colour mask, P_D0 -> left byte column, P_D8 = P_D0+8
GFX_CELL:
        ldy #7
@row:   lda (G_GLY),y
        tax
        lda LTAB,x
        and G_MASK
        sta (P_D0),y
        lda RTAB,x
        and G_MASK
        sta (P_D8),y
        dey
        bpl @row
        rts

; ---- GFX_CELLSPR: draw one cell with the hardware sprites over it ------------------------------
; The cell is composed in CBUF and copied to the screen in one go, so a sprite never disappears
; while the cells under it are redrawn.  in: as GFX_CELL, plus G_CX/G_CY (cell) and G_SM (sprites
; whose rows cover this cell row).  Sprite n: SP_* records built by SPR_UPDATE.
GFX_CELLSPR:
        ldy #7
@row:   lda (G_GLY),y
        tax
        lda LTAB,x
        and G_MASK
        sta CBUF,y
        lda RTAB,x
        and G_MASK
        sta CBUF+8,y
        dey
        bpl @row
        lda #7
        sta S_N
@spr:   ldx S_N
        lda BITS,x
        and G_SM
        beq @next
        jsr SPR_IN_CELL
@next:  dec S_N
        bpl @spr
        ldy #15
@cp:    lda CBUF,y
        sta (P_D0),y
        dey
        bpl @cp
        rts

; composite sprite S_N into CBUF for cell (G_CX, G_CY).  Sprite bytes: screen byte column k = 2*cx+h-bc0
; (0..5) of sprite row ry = 8*cy+y-sy (0..20); each source byte is 8 pixels = screen bytes 2j, 2j+1.
SPR_IN_CELL:
        ldx S_N
        lda SP_SRCL,x
        sta S_SRC
        lda SP_SRCH,x
        sta S_SRC+1
        lda G_CX
        asl a
        sec
        sbc SP_BC0,x
        sta S_K0
        lda G_CY
        asl a
        asl a
        asl a
        sec
        sbc SP_SY,x
        sta S_RY                ; -7..20 whenever the row masks say the sprite is here
        lda #0
        sta S_Y8
@y:     lda S_RY
        clc
        adc S_Y8
        bmi @nyj
        cmp #21
        bcc :+
@nyj:   jmp @ny
:
        sta S_T1
        asl a
        clc
        adc S_T1
        sta S_R3                ; ry*3
        lda #0
        sta S_H
@h:     lda S_K0
        clc
        adc S_H
        bmi @nhj
        cmp #6
        bcc :+
@nhj:   jmp @nh
:
        sta S_K
        lsr a
        clc
        adc S_R3
        tay
        lda (S_SRC),y
        sta S_B
        ldx S_N
        lda SP_MODE,x
        bne @mc
        ldx S_B                 ; hi-res: coverage = both planes of the lit pixels, colour from SP_CM
        lda S_K
        and #1
        bne @hr
        lda LTAB,x
        jmp @hv
@hr:    lda RTAB,x
@hv:    sta G_M
        ldx S_N
        and SP_CM,x
        jmp @put
@mc:    lda S_N                 ; multicolour: pixel pairs qa,qb -> value and coverage from the tables
        asl a
        asl a
        sta S_T2
        lda S_K
        and #1
        bne @mcr
        lda S_B                 ; left screen byte: q3,q2
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a
        sta S_T1
        lda S_B
        lsr a
        lsr a
        lsr a
        lsr a
        and #3
        jmp @mcgo
@mcr:   lda S_B                 ; right screen byte: q1,q0
        lsr a
        lsr a
        and #3
        sta S_T1
        lda S_B
        and #3
@mcgo:  sta G_TMP
        lda S_T2
        clc
        adc S_T1
        tax
        lda SP_MCV1,x
        sta G_V
        lda SP_MCM1,x
        sta G_M
        lda S_T2
        clc
        adc G_TMP
        tax
        lda SP_MCV2,x
        ora G_V
        sta G_V
        lda SP_MCM2,x
        ora G_M
        sta G_M
        lda G_V
@put:   sta G_V                 ; A = value, G_M = coverage -> CBUF[h*8+y]
        lda S_H
        asl a
        asl a
        asl a
        clc
        adc S_Y8
        tay
        lda G_M
        eor #$FF
        and CBUF,y
        ora G_V
        sta CBUF,y
@nh:    inc S_H
        lda S_H
        cmp #2
        beq @ny
        jmp @h
@ny:    inc S_Y8
        lda S_Y8
        cmp #8
        beq @done
        jmp @y
@done:  rts
