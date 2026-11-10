; SPDX-License-Identifier: GPL-3.0-only
; BBC Master port - music.  The C64 version's player (a stripped GoatTracker 2 play routine, SID) is translated mechanically by
; tools/music_port.py (build/data/music_core.inc), so the real song data and the real player logic run; its SID register writes
; land in SIDSH, and MUS_CONVERT turns the 25 shadow registers into SN76489 writes every 50 Hz frame (model: tools/music_conv.py).
; Everything lives in sideways bank GFXBANK (bank 5, free space after the renderer and font) except the two entry points at the end
; of this file, which page the bank in.  One song is resident at a time: HAL_MUSIC_START loads its image (MUSn, built by
; tools/music_port.py songs) to MUS_R2 with *SRLOAD when the song changes.
;
; SN76489 channels: tone 0-2 = SID voices 0-2; a voice with the noise waveform drives the noise channel instead.  While a sound
; effect plays it owns channel 0 (tone effect) or channel 2 and the noise channel (noise effect): the music leaves them alone and
; rewrites them when the effect is over.

.segment "GFX"

.include "music_meta.inc"       ; MUS_NP

; the song image (pointer tables, order lists, patterns) is loaded at MUS_R2, the free space above the tile cache; its pointer tables come first
MORDLO = MUS_R2                 ; order list pointers (3 channels)
MORDHI = MUS_R2 + 3
MPATLO = MUS_R2 + 6             ; pattern pointers, renumbered per song
MPATHI = MUS_R2 + 6 + MUS_NP
MZP    = $3E                    ; the player's scratch pointer; the game's own use of $3E/$3F is saved around each call

; ---- the translated player and its tables ---------------------------------------------------------
        .include "music_core.inc"                 ; MUSIC_CORE: (+0 init, A = song 0; +3 play one frame)
        .include "music_tab.inc"                  ; TB1, TB2
        .include "music_conv.inc"                 ; MCQ_*, MCATK_*, MCDR_*, MCTHR

; ---- SID shadow registers and the converter's state (main RAM: bank 5 has no room to spare) --------------------------
.segment "HALVARS"
SIDSH:  .res 25
MUS_LVL_L: .res 3               ; envelope level (16 bit) per voice
MUS_LVL_H: .res 3
MUS_PH:    .res 3               ; 0 attack, 1 decay, 2 sustain, 3 release
MUS_GATE:  .res 3
MUS_LN_L:  .res 3               ; period last written to the SN (high byte $FF = unknown)
MUS_LN_H:  .res 3
MUS_LA:    .res 3               ; attenuation last written ($FF = unknown)
MUS_CF_L:  .res 3               ; SID frequency last converted ...
MUS_CF_H:  .res 3
MUS_N_L:   .res 3               ; ... and its period
MUS_N_H:   .res 3
MUS_LR:    .res 1               ; noise rate last written ($FF unknown)
MUS_LNA:   .res 1               ; noise attenuation last written
MUS_GAIN:  .res 1               ; attenuation steps taken off (level songs are mixed low; set by HAL_MUSIC_START)
MUS_NATT:  .res 1
MUS_RATE:  .res 1
; (the converter's temporaries: HALVARS is full, so they take 22 bytes of the main code's spare room)
.segment "CODE"
MT_CTRL:   .res 1               ; the voice being converted
MT_AD:     .res 1
MT_SR:     .res 1
MT_FL:     .res 1
MT_FH:     .res 1
MT_ATT:    .res 1
MT_TG:     .res 1
MT_S:      .res 1
MT_V:      .res 1
MT_OWN:    .res 1               ; channels a sound effect owns: bit n = tone n, bit 3 = noise
MT_M:      .res 2
MT_Q:      .res 2
MT_P:      .res 2
MT_D:      .res 1
MT_F5:     .res 1
MT_N:      .res 2
.segment "GFX"

MVOFF:  .byte 0, 7, 14
MCH:    .byte $80, $A0, $C0     ; SN latch bytes: tone period
MCA:    .byte $90, $B0, $D0     ;                 attenuation
MBIT:   .byte 1, 2, 4

; reset the converter (new song): all channels unknown, envelopes idle
MUS_RESET:
        ldx #2
        lda #0
:       sta MUS_LVL_L,x
        sta MUS_LVL_H,x
        sta MUS_GATE,x
        sta MUS_CF_L,x
        sta MUS_CF_H,x
        lda #3
        sta MUS_PH,x
        lda #$FF
        sta MUS_LN_H,x
        sta MUS_LA,x
        lda #0
        dex
        bpl :-
        lda #$FF
        sta MUS_LR
        sta MUS_LNA
        rts

; SN period for the SID frequency in MT_FL/MT_FH (non-zero) -> MT_N.  See tools/music_conv.py period().
MC_PERIOD:
        stx MT_V
        lda MT_FL
        sta MT_M
        lda MT_FH
        sta MT_M+1
        ldy #0
:       lda MT_M+1              ; shift F up until bit 15 is set; Y = number of shifts
        bmi @n
        asl MT_M
        rol MT_M+1
        iny
        bne :-
@n:     sty MT_S
        lda MT_M+1
        and #$7F
        tax                     ; index into the reciprocal table
        lda MT_M
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a
        sta MT_F5               ; interpolation fraction, 0-7
        sec
        lda MCQ_LO,x
        sbc MCQ_LO+1,x
        sta MT_D
        lda #0
        sta MT_P
        sta MT_P+1
        ldy MT_F5
        beq @pd
@pl:    clc
        lda MT_P
        adc MT_D
        sta MT_P
        bcc :+
        inc MT_P+1
:       dey
        bne @pl
@pd:    lsr MT_P+1              ; (d * fraction) >> 3
        ror MT_P
        lsr MT_P+1
        ror MT_P
        lsr MT_P+1
        ror MT_P
        lda MCQ_LO,x
        sec
        sbc MT_P
        sta MT_Q
        lda MCQ_HI,x
        sbc MT_P+1
        sta MT_Q+1
        lda #8                  ; r = max(4, 8 - s): shifts down to a period of at most 10 bits (lower notes fold up octaves)
        sec
        sbc MT_S
        bcc @r4
        cmp #4
        bcs @rok
@r4:    lda #4
@rok:   tay
        dey                     ; q >> (r - 1) ...
:       lsr MT_Q+1
        ror MT_Q
        dey
        bne :-
        jsr @half               ; ... + 1, >> 1  =  rounded q >> r
        lda MT_N+1
        cmp #4
        bcc @ok
        lsr MT_Q+1              ; over 1023: one more octave up
        ror MT_Q
        jsr @half
@ok:    ldx MT_V
        rts
@half:  lda MT_Q
        clc
        adc #1
        sta MT_N
        lda MT_Q+1
        adc #0
        lsr a
        sta MT_N+1
        ror MT_N
        rts

; envelope step of voice X (MT_AD, MT_SR set up)
MC_ENV:
        lda MT_SR               ; sustain level target (high byte; the low byte is 0)
        lsr a
        lsr a
        lsr a
        lsr a
        sta MT_S
        asl a
        asl a
        asl a
        asl a
        ora MT_S
        sta MT_TG
        lda MUS_PH,x
        bne @p1
        lda MT_AD               ; attack
        lsr a
        lsr a
        lsr a
        lsr a
        tay
        lda MUS_LVL_L,x
        clc
        adc MCATK_LO,y
        sta MUS_LVL_L,x
        lda MUS_LVL_H,x
        adc MCATK_HI,y
        sta MUS_LVL_H,x
        bcc @x1
        lda #$FF
        sta MUS_LVL_L,x
        sta MUS_LVL_H,x
        lda #1
        sta MUS_PH,x
@x1:    rts
@p1:    cmp #1
        bne @p2
        lda MT_AD               ; decay
        and #15
        tay
        lda MUS_LVL_L,x
        sec
        sbc MCDR_LO,y
        sta MUS_LVL_L,x
        lda MUS_LVL_H,x
        sbc MCDR_HI,y
        sta MUS_LVL_H,x
        bcc @settg
        cmp MT_TG
        bcc @settg
        bne @x2
        lda MUS_LVL_L,x
        bne @x2
@settg: lda MT_TG
        sta MUS_LVL_H,x
        lda #0
        sta MUS_LVL_L,x
        lda #2
        sta MUS_PH,x
@x2:    rts
@p2:    cmp #2
        bne @p3
        lda MUS_LVL_H,x         ; sustain: follow the level down if SR was lowered
        cmp MT_TG
        bcc @x3
        bne @clip
        lda MUS_LVL_L,x
        beq @x3
@clip:  lda MT_TG
        sta MUS_LVL_H,x
        lda #0
        sta MUS_LVL_L,x
@x3:    rts
@p3:    lda MT_SR               ; release
        and #15
        tay
        lda MUS_LVL_L,x
        sec
        sbc MCDR_LO,y
        sta MUS_LVL_L,x
        lda MUS_LVL_H,x
        sbc MCDR_HI,y
        sta MUS_LVL_H,x
        bcs @x4
        lda #0
        sta MUS_LVL_L,x
        sta MUS_LVL_H,x
@x4:    rts

; one frame of conversion: SIDSH -> SN writes
MUS_CONVERT:
        jsr SN_BEGIN
        lda #0
        sta MT_OWN
        lda SND_ID              ; a sound effect owns channel 0, or channel 2 and the noise channel
        cmp #$FF
        beq @free
        lda SND_NOISE
        beq @own0
        lda #%1100
        bne @own
@own0:  lda #%0001
@own:   sta MT_OWN
@free:  lda #15
        sta MUS_NATT
        ldx #0
@voice: ldy MVOFF,x
        lda SIDSH,y
        sta MT_FL
        lda SIDSH+1,y
        sta MT_FH
        lda SIDSH+4,y
        sta MT_CTRL
        lda SIDSH+5,y
        sta MT_AD
        lda SIDSH+6,y
        sta MT_SR
        lda MT_CTRL             ; gate edges restart the envelope
        and #1
        cmp MUS_GATE,x
        beq @ng
        sta MUS_GATE,x
        lda MUS_GATE,x
        beq @rel
        lda #0
        beq @ph
@rel:   lda #3
@ph:    sta MUS_PH,x
@ng:    jsr MC_ENV
        lda MT_CTRL             ; attenuation from the level; silent without a waveform or a frequency
        and #$F0
        beq @off
        lda MT_FL
        ora MT_FH
        beq @off
        ldy #0
:       lda MUS_LVL_H,x
        cmp MCTHR,y
        bcs @got
        iny
        cpy #15
        bne :-
@got:   sty MT_ATT
        bcs @gt                 ; (always: the carry is set here)
@off:   lda #15
        sta MT_ATT
@gt:    lda MT_ATT              ; louder by the song's gain (a silent voice stays silent)
        cmp #15
        beq @gd
        sec
        sbc MUS_GAIN
        bcs :+
        lda #0
:       sta MT_ATT
@gd:    lda MT_CTRL
        bpl @tone
        ldy #0                  ; Y = 1: this noise voice goes through the low-pass filter (a low thump on the C64, not hiss)
        lda SIDSH+23
        and MBIT,x
        beq :+
        lda SIDSH+24
        and #$10
        beq :+
        iny
:       lda MT_ATT              ; noise waveform: the noise channel takes it, the louder voice wins
        cpy #0
        beq @nf
        cmp #15
        beq @nf
        clc
        adc #MC_FILT_ATT
        cmp #15
        bcc @nf
        lda #14
@nf:    cmp MUS_NATT
        bcs @nn
        sta MUS_NATT
        cpy #0
        bne @r2
        lda MT_FH
        bmi @r0
        cmp #$40
        bcs @r1
@r2:    lda #2
        bne @rs
@r1:    lda #1
        bne @rs
@r0:    lda #0
@rs:    sta MUS_RATE
@nn:    lda #15
        sta MT_ATT
@tone:  lda MBIT,x              ; this tone channel belongs to a sound effect: leave it, forget what we wrote
        and MT_OWN
        beq @mine
        lda #$FF
        sta MUS_LA,x
        sta MUS_LN_H,x
        bne @next
@mine:  lda MT_ATT
        cmp #15
        beq @att
        lda MT_FL               ; period, converted again only when the frequency changed
        cmp MUS_CF_L,x
        bne @conv
        lda MT_FH
        cmp MUS_CF_H,x
        beq @have
@conv:  jsr MC_PERIOD
        lda MT_FL
        sta MUS_CF_L,x
        lda MT_FH
        sta MUS_CF_H,x
        lda MT_N
        sta MUS_N_L,x
        lda MT_N+1
        sta MUS_N_H,x
@have:  lda MUS_N_L,x
        cmp MUS_LN_L,x
        bne @wn
        lda MUS_N_H,x
        cmp MUS_LN_H,x
        beq @att
@wn:    lda MUS_N_L,x
        sta MUS_LN_L,x
        and #15
        ora MCH,x
        jsr SN_OUT
        lda MUS_N_L,x
        lsr a
        lsr a
        lsr a
        lsr a
        sta MT_S
        lda MUS_N_H,x
        sta MUS_LN_H,x
        asl a
        asl a
        asl a
        asl a
        ora MT_S
        jsr SN_OUT
@att:   lda MT_ATT
        cmp MUS_LA,x
        beq @next
        sta MUS_LA,x
        ora MCA,x
        jsr SN_OUT
@next:  inx
        cpx #3
        beq :+
        jmp @voice
:       lda MT_OWN              ; the noise channel
        and #8
        bne @ninv
        lda MUS_NATT
        cmp #15
        beq @na
        lda MUS_RATE
        cmp MUS_LR
        beq @na
        sta MUS_LR
        ora #$E4                ; white noise, shift rate 0-2
        jsr SN_OUT
@na:    lda MUS_NATT
        cmp MUS_LNA
        beq @end
        sta MUS_LNA
        ora #$F0
        jsr SN_OUT
        jmp @end
@ninv:  lda #$FF
        sta MUS_LNA
        sta MUS_LR
@end:   jmp SN_END

MUSIC_END:
.assert MUSIC_END <= CACHEB5, error, "the music code runs into the tile cache"

; ---- main RAM: entry points ------------------------------------------------------------------------
.segment "CODE"

MUS_PLAY:       .byte 0         ; non-zero: a song is playing
MUS_LOADED:     .byte $FF       ; song whose image is in bank 5
MUS_SONG:       .byte 0
MUS_ERR:        .byte 0         ; non-zero: the last song image could not be loaded (the game prints a message; see MUS_CHECK_GET)
MUS_TRIES:      .byte 0

; The first order list of every song image starts right after the pointer tables, so MORDLO/MORDHI [0] are the same for all songs;
; a load that did not happen leaves the byte HAL_MUSIC_START cleared before it.
MUS_OL = MUS_R2 + 6 + 2 * MUS_NP

; page bank 5 and clear the high byte of the first order-list pointer (the check byte, MUS_CHECK_CLEAR), or read the pointer into X/A (MUS_CHECK_GET)
MUS_CHECK_CLEAR:
        php
        sei
        ldx #GFXBANK
        stx ROMSEL_SH
        stx ROMSEL
        lda #0
        sta MORDHI
        bpl MUS_CHECK_END
MUS_CHECK_GET:
        php
        sei
        ldx #GFXBANK
        stx ROMSEL_SH
        stx ROMSEL
        lda MORDHI
        ldx MORDLO
MUS_CHECK_END:
        pha
        lda #DATABANK
        sta ROMSEL_SH
        sta ROMSEL
        pla
        plp
        rts

; HAL_MUSIC_START: A = the C64 version's song number (0-7; 5 = silence).  Loads the song image if another one is resident.
; The image is checked after the load (the first order-list pointer is what the file says) and the load retried up to three times:
; MUS_ERR is set if it never arrives (MUS_CHECK_GET), and then no music is played.
HAL_MUSIC_START:
        sta MUS_SONG
        php
        sei
        lda #0
        sta MUS_PLAY            ; (the vsync handler must not run the player while the image is replaced)
        plp
        lda MUS_SONG
        cmp #5
        bne :+
        php                     ; the blank song: silence
        sei
        jsr SN_BEGIN
        jsr SN_SILENCE
        jsr SN_END
        plp
        rts
:       cmp MUS_LOADED
        beq @init
        sta MUS_LOADED
        php                     ; the disc read takes seconds and the player is stopped meanwhile: don't leave the old song's tones on
        sei
        jsr SN_BEGIN
        jsr SN_SILENCE
        jsr SN_END
        plp
        lda #3
        sta MUS_TRIES
@load:  jsr MUS_CHECK_CLEAR
        ldy MUS_SONG
        ldx MUS_CMDL,y
        lda MUS_CMDH,y
        tay
        jsr HAL_OSCLI
        jsr MUS_CHECK_GET
        cmp #>MUS_OL
        bne @bad
        cpx #<MUS_OL
        beq @ok
@bad:   dec MUS_TRIES
        bne @load
        lda #$FF                ; no image: nothing to play
        sta MUS_LOADED
        sta MUS_ERR
        rts
@ok:    lda #0
        sta MUS_ERR
@init:  php
        sei
        lda $3E
        pha
        lda $3F
        pha
        lda #GFXBANK
        sta ROMSEL_SH
        sta ROMSEL
        lda MUS_SONG            ; the level songs (0-3) are played louder
        cmp #4
        lda #MC_LEVEL_GAIN
        bcc :+
        lda #0
:       sta MUS_GAIN
        jsr MUS_RESET
        lda #0
        jsr MUSIC_CORE
        lda #DATABANK
        sta ROMSEL_SH
        sta ROMSEL
        pla
        sta $3F
        pla
        sta $3E
        lda #1
        sta MUS_PLAY
        plp
        rts

; HAL_MUSIC_TICK: one frame of the music; called from the vsync handler (interrupts off) while the game's MUSIC_STATE is on
HAL_MUSIC_TICK:
        lda MUS_PLAY
        beq @no
        lda $3E
        pha
        lda $3F
        pha
        lda #GFXBANK
        sta ROMSEL_SH
        sta ROMSEL
        jsr MUSIC_CORE+3
        jsr MUS_CONVERT
        lda #DATABANK
        sta ROMSEL_SH
        sta ROMSEL
        pla
        sta $3F
        pla
        sta $3E
@no:    rts

MUS_CMDS:                       ; *SRLOAD MUSn xxxx 5, 20 bytes each (the song images are built by tools/music_port.py songs)
.repeat 8, n
        .byte .sprintf("*SRLOAD MUS%d %04X 5", n, MUS_R2), 13
.endrepeat
MUS_CMDL:
.repeat 8, i
        .byte <(MUS_CMDS + i * 20)
.endrepeat
MUS_CMDH:
.repeat 8, i
        .byte >(MUS_CMDS + i * 20)
.endrepeat
