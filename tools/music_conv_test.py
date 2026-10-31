#!/usr/bin/env python3
"""Does the 6502 SID -> SN76489 converter (platform/bbc/music.s) do exactly what the reference model (tools/music_conv.py) does?
The SID registers come from the original C64 player running in the simulator; after each frame they are put in the shadow
registers and MUS_CONVERT is run; its SN writes must equal the model's, byte for byte.   usage: music_conv_test.py [frames [songs]]"""
import os, subprocess, sys, tempfile
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(R, 'tools'))
from sim6502 import CPU
import music_conv
C65 = os.path.expanduser('~/retro/emulators/cc65')
D = open(os.path.join(R, 'upstream', 'c64', 'music.c64'), 'rb').read(); N = len(D) - 2
HARNESS = '''GFXBANK = 5
DATABANK = 4
ROMSEL = $FE30
ROMSEL_SH = $F4
ZP0 = $70
ZP1 = $71
CACHEB5 = $A800
MUS_R2 = $B100
MUS_R2_END = $C000
.segment "CODE"
LOGPTR: .word 0
SND_ID: .byte $FF
SND_NOISE: .byte 0
SN_BEGIN: rts
SN_END: rts
SN_SILENCE: rts
HAL_OSCLI: rts
SN_OUT: ldy LOGPTR
        sta $0400,y
        inc LOGPTR
        rts
.include "music.s"
'''
def build():
    t = tempfile.mkdtemp()
    open(t + '/h.s', 'w').write(HARNESS)
    open(t + '/h.cfg', 'w').write('MEMORY { C: start=$3000, size=$2000, file="%O-c.bin"; G: start=$8000, size=$4000, file="%O-g.bin"; }\n'
                                  'SEGMENTS { CODE: load=C, type=rw; GFX: load=G, type=rw, align=256; }\n')
    env = dict(os.environ, CC65_HOME=C65)
    I = ['-I', os.path.join(R, 'build', 'data'), '-I', os.path.join(R, 'source', 'platform', 'bbc')]
    subprocess.check_call([C65 + '/bin/ca65', '-g', '-t', 'none'] + I + ['-o', t + '/h.o', t + '/h.s'], env=env)
    subprocess.check_call([C65 + '/bin/ld65', '-C', t + '/h.cfg', '-o', t + '/h', t + '/h.o', '--dbgfile', t + '/h.dbg'], env=env)
    sym = {}
    for l in open(t + '/h.dbg'):
        if l.startswith('sym') and 'name="' in l and 'val=0x' in l:
            sym[l.split('name="')[1].split('"')[0]] = int(l.split('val=0x')[1].split(',')[0], 16)
    return open(t + '/h-c.bin', 'rb').read(), open(t + '/h-g.bin', 'rb').read(), sym
code, gfx, sym = build()
nfr = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
songs = [int(x) for x in sys.argv[2:]] or range(8)
def call(c, addr, a=None):
    if a is not None: c.a = a
    c.sp = 0xFF; c.push(0xFF); c.push(0xFD); c.pc = addr
    while c.pc != 0xFFFE: c.step()
bad = 0
for s in songs:
    o = CPU(); o.m[0xA000:0xA000 + N] = D[2:]; o.m[0xFFFE] = 0xEA
    sidr = [0] * 32
    o.write_hooks.append(lambda a, v: sidr.__setitem__(a - 0xD400, v) if 0xD400 <= a <= 0xD41F else None)
    p = CPU(); p.m[0x3000:0x3000 + len(code)] = code; p.m[0x8000:0x8000 + len(gfx)] = gfx; p.m[0xFFFE] = 0xEA
    call(o, 0xA000, s); call(p, sym['MUS_RESET']); ref = music_conv.Conv()
    cyc = 0; tot = 0
    for f in range(nfr):
        call(o, 0xA003)
        for i in range(25): p.m[sym['SIDSH'] + i] = sidr[i]
        p.m[sym['LOGPTR']] = 0; c0 = p.cycles
        call(p, sym['MUS_CONVERT']); cyc += p.cycles - c0
        got = list(p.m[0x400:0x400 + p.m[sym['LOGPTR']]]); want = ref.frame(sidr[:25]); tot += len(want)
        if got != want:
            print('song %d frame %d: SN writes differ\n  regs %s\n  model %s\n  6502  %s' % (s, f, sidr[:25], want, got)); bad += 1; break
    else:
        print('song %d: %d frames identical (converter: %d cycles a frame, %.1f SN bytes a frame)' % (s, nfr, cyc // nfr, tot / nfr))
sys.exit(1 if bad else 0)
