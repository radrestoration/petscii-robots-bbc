#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Does the translated music player (tools/music_port.py) do exactly what the C64 original does?  Both are run in the simulator,
frame by frame - the original with the whole C64 file, the translation with only the repacked image of that one song; after every frame the 25 SID registers of the original must equal the shadow registers
of the translation.  usage: music_test.py [frames per song (default: all)] [song ...]"""
import os, subprocess, sys, tempfile
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(R, 'tools'))
from sim6502 import CPU
import music_port as MP
C65 = os.path.expanduser('~/retro/emulators/cc65')
D = open(os.path.join(R, 'upstream', 'c64', 'music.c64'), 'rb').read()
N = len(D) - 2
LOOP = {0: 13074, 1: 12592, 2: 11782, 3: 12553, 4: 3145, 5: 386, 6: 13728, 7: 23426}      # frames until the original's state repeats
SRC = '''SIDSH = $0200
MZP = $3E
.import __x
.segment "CODE"
.include "music_core.inc"
.segment "TAB"
TB: .include "music_tab.inc"
'''
MP_D = MP.load(os.path.join(R, 'upstream', 'c64')); SONGS = MP.parse_songs(MP_D); NP = max(len(x[1]) for x in SONGS)
def build():
    t = tempfile.mkdtemp()
    open(t + '/t.s', 'w').write('SIDSH = $0200\nMZP = $3E\nMORDLO = $B100\nMORDHI = MORDLO + 3\nMPATLO = MORDLO + 6\nMPATHI = MPATLO + %d\n'
                                '.segment "CODE"\n.include "music_core.inc"\n.segment "TAB"\n.include "music_tab.inc"\n' % NP)
    open(t + '/t.cfg', 'w').write('MEMORY { C: start=$3000, size=$2000, file="%O-c.bin"; T: start=$6000, size=$1000, file="%O-t.bin"; }\n'
                                  'SEGMENTS { CODE: load=C, type=ro, align=256; TAB: load=T, type=ro; }\n')
    env = dict(os.environ, CC65_HOME=C65)
    subprocess.check_call([C65 + '/bin/ca65', '-t', 'none', '-I', os.path.join(R, 'build', 'data'), '-o', t + '/t.o', t + '/t.s'], env=env)
    subprocess.check_call([C65 + '/bin/ld65', '-C', t + '/t.cfg', '-o', t + '/t', t + '/t.o', '-m', t + '/t.map'], env=env)
    return open(t + '/t-c.bin', 'rb').read(), open(t + '/t-t.bin', 'rb').read()
def call(c, addr, a=None):
    if a is not None: c.a = a
    c.sp = 0xFF; c.push(0xFF); c.push(0xFD); c.pc = addr
    while c.pc != 0xFFFE: c.step()
code, tab = build()
songs = [int(x) for x in sys.argv[2:]] or range(8)
nfr = int(sys.argv[1]) if len(sys.argv) > 1 and int(sys.argv[1]) > 0 else None
bad = 0
for s in songs:
    o = CPU(); o.m[0xA000:0xA000 + N] = D[2:]; o.m[0xFFFE] = 0xEA
    p = CPU()                                                      # the translation gets only the repacked single-song image
    img = MP.pack_song(SONGS[s], NP, 0xB100, 0xC000); p.m[0xB100:0xB100 + len(img)] = img
    p.m[0x3000:0x3000 + len(code)] = code; p.m[0x6000:0x6000 + len(tab)] = tab; p.m[0xFFFE] = 0xEA
    sidr = [0] * 32
    o.write_hooks.append(lambda a, v: sidr.__setitem__(a - 0xD400, v) if 0xD400 <= a <= 0xD41F else None)
    call(o, 0xA000, s); call(p, 0x3000, 0)
    n = nfr or LOOP[s]; cyc = 0
    for f in range(n):
        call(o, 0xA003); c0 = p.cycles; call(p, 0x3003); cyc += p.cycles - c0
        mine = list(p.m[0x200:0x219])
        if mine != sidr[:25]:
            print('song %d frame %d: differs\n  orig %s\n  port %s' % (s, f, sidr[:25], mine)); bad += 1; break
    else:
        print('song %d: %d frames identical (port: %d cycles a frame)' % (s, n, cyc // n))
sys.exit(1 if bad else 0)
