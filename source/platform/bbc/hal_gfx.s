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

; multicolour sprite byte b = pixel pairs q3 q2 q1 q0: the left screen byte takes (q3,q2), the right one (q1,q0);
; each table gives q*8, ORed with the sprite number to index SP_MCV1/2 and SP_MCM1/2
        .align 256
MQL1:   .repeat 256, i
        .byte (i >> 6) * 8
        .endrepeat
MQL2:   .repeat 256, i
        .byte ((i >> 4) & 3) * 8
        .endrepeat
MQR1:   .repeat 256, i
        .byte ((i >> 2) & 3) * 8
        .endrepeat
MQR2:   .repeat 256, i
        .byte (i & 3) * 8
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
; The rows and byte columns that overlap the cell are worked out first, and an all-transparent source byte
; (most of them) costs next to nothing.
SPR_IN_CELL:
        ldx S_N
        lda G_CX
        asl a
        sec
        sbc SP_BC0,x
        sta S_K0                ; signed: the cell's first byte column relative to the sprite's
        clc
        adc #1
        cmp #7                  ; -1..5 are the only values with a byte of the sprite in this cell
        bcc :+
        rts
:       ldy #0                  ; h range: K0 = -1 leaves out h = 0, K0 = 5 leaves out h = 1
        lda S_K0
        bpl :+
        iny
:       sty S_H0
        ldy #1
        lda S_K0
        cmp #5
        bne :+
        dey
:       sty S_H1
        lda G_CY
        asl a
        asl a
        asl a
        sec
        sbc SP_SY,x
        sta S_RY                ; sprite row of the cell's first pixel row: -7..20 whenever the row masks say the sprite is here
        lda #20                 ; last pixel row of the cell inside the sprite
        sec
        sbc S_RY
        bpl :+
        rts
:       cmp #8
        bcc :+
        lda #7
:       sta S_YE
        ldy #0                  ; first pixel row inside the sprite
        lda S_RY
        bpl :+
        lda #0
        sec
        sbc S_RY
        tay
:       sty S_Y8
        lda SP_SRCL,x
        sta S_SRC
        lda SP_SRCH,x
        sta S_SRC+1
        lda SP_MODE,x
        sta S_MODE
        lda SP_CM,x
        sta S_CMZ
@y:     lda S_RY
        clc
        adc S_Y8
        sta S_T1
        asl a
        clc
        adc S_T1
        sta S_R3                ; ry*3
        lda S_H0
        sta S_H
@h:     lda S_K0
        clc
        adc S_H
        sta S_K                 ; screen byte column 0..5 of the sprite
        lsr a
        clc
        adc S_R3
        tay
        lda (S_SRC),y
        beq @nh                 ; transparent
        tax
        lda S_MODE
        bne @mc
        lda S_K                 ; hi-res: coverage = both planes of the lit pixels, colour from the mask
        and #1
        bne @hr
        lda LTAB,x
        jmp @hv
@hr:    lda RTAB,x
@hv:    sta G_M
        and S_CMZ
        jmp @put
@mc:    lda S_K                 ; multicolour: pixel pairs -> value and coverage from the tables
        and #1
        bne @mcr
        lda MQL1,x
        ora S_N
        tay
        lda MQL2,x
        jmp @mcgo
@mcr:   lda MQR1,x
        ora S_N
        tay
        lda MQR2,x
@mcgo:  ora S_N
        tax
        lda SP_MCV1,y
        ora SP_MCV2,x
        sta G_V
        lda SP_MCM1,y
        ora SP_MCM2,x
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
@nh:    lda S_H
        cmp S_H1
        beq @ny
        inc S_H
        jmp @h
@ny:    lda S_Y8
        cmp S_YE
        beq @done
        inc S_Y8
        jmp @y
@done:  rts
