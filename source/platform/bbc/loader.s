; PETSCII Robots - BBC Master boot loader (the disc's !BOOT, boot option 2).  Checks for a Master,
; loads the four images and jumps to the game.  Assembled on its own at &1400, which is free
; while the game images load (LOW is below &1400, game variables start at &1600).
OSBYTE  = $FFF4
OSCLI   = $FFF7
OSASCI  = $FFE3
OSWRCH  = $FFEE
PTR     = $70
START   = $3000                 ; first code of the game image (make checks this against the link)

        lda #0                  ; OSBYTE 0, X=1: operating system version; Master 128 = 3, Master Compact = 5
        ldx #1
        jsr OSBYTE
        cpx #3
        beq ok
        cpx #5
        beq ok
        ldx #0
:       lda nomaster,x
        beq :+
        jsr OSASCI
        inx
        bne :-
:       rts
ok:     lda #22                 ; MODE 135 = shadow Mode 7: the screen is in LYNNE, so loading the game over &7C00-&7FFF
        jsr OSWRCH              ; (the normal Mode 7 screen) doesn't scramble the display
        lda #135
        jsr OSWRCH
        ldx #0
:       lda hello,x
        beq :+
        jsr OSASCI
        inx
        bne :-
:       lda #<cmds
        sta PTR
        lda #>cmds
        sta PTR+1
next:   ldy #0
        lda (PTR),y
        beq done
        ldx PTR
        ldy PTR+1
        jsr OSCLI
        ldy #0                  ; step past this command's CR
:       lda (PTR),y
        iny
        cmp #13
        bne :-
        tya
        clc
        adc PTR
        sta PTR
        bcc next
        inc PTR+1
        bne next
done:   jmp START

hello:  .byte "PETSCII ROBOTS - loading...",13,10,0
nomaster: .byte "This version needs a BBC Master",13,10,0
cmds:   .byte "*LOAD LOW 0E00",13
        .byte "*LOAD MID 3000",13
        .byte "*SRLOAD GFX 8000 5",13
        .byte "*SRLOAD TILES 8000 4",13
        .byte 0
