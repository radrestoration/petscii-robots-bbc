#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""One-off mechanical pass over the translated C64 sources (run once on source/robots.s and
source/background_tasks.s; kept for the record - the sources are hand-maintained afterwards).
 $FB-$FE zero-page pointers -> ZP0-ZP3 (BBC user zero page), variable page $06xx/$07xx -> $16xx/$17xx,
 level/unit/map $5Dxx-$7Fxx -> +$3800 (sideways bank 4), virtual screen/colour/VIC/sprite pointers,
 KERNAL keyboard poking -> HAL names.   usage: bbc_mechanical.py file.s ..."""
import re, sys

def conv(code):
    # virtual hardware
    def vscr(m):
        a = int(m.group(1), 16)
        if 0xE3F8 <= a <= 0xE3FF: return 'VSPTR+%d' % (a - 0xE3F8)
        if 0xE000 <= a <= 0xE3E7: return 'VSCR+$%03X' % (a - 0xE000)
        return m.group(0)
    code = re.sub(r'\$(E[0-3][0-9A-F]{2})\b', vscr, code)
    code = re.sub(r'\$(D[89AB][0-9A-F]{2})\b', lambda m: 'VCOL+$%03X' % (int(m.group(1), 16) - 0xD800) if int(m.group(1), 16) <= 0xDBE7 else m.group(0), code)
    code = re.sub(r'\$D0([0-2][0-9A-F])\b', lambda m: 'VIC+$%s' % m.group(1), code)
    # keyboard stand-ins
    code = re.sub(r'\$00C6\b', 'KBDCOUNT', code)
    code = re.sub(r'\$0289\b', 'KBDENABLE', code)
    code = re.sub(r'\$028C\b', 'KREPEAT', code)
    code = re.sub(r'(?<![#$A-Za-z0-9_])\$C5\b', 'LSTX', code)
    code = re.sub(r'\bJSR(\s+)\$(F142|FFE4)\b', r'JSR\1HAL_GETKEY', code)
    # zero-page pointers (not immediates)
    code = re.sub(r'(?<![#$0-9A-Za-z_])\$(FB|FC|FD|FE)\b', lambda m: 'ZP%d' % (int(m.group(1), 16) - 0xFB), code)
    return code

def main(path):
    out = []
    for line in open(path).read().split('\n'):
        m = re.match(r'^([^;]*)(;.*)?$', line)
        code, com = m.group(1), m.group(2) or ''
        if '.byte' not in code and not code.lstrip().startswith('.'):
            em = re.match(r'^(\w+)\s*=\s*\$(0[67][0-9A-Fa-f]{2})\b(.*)$', code)
            if em:      # variable page equates
                code = '%s =$%s%s' % (em.group(1), '1' + em.group(2)[1:], em.group(3))
            em = re.match(r'^(\w+)\s*=\s*\$((?:5[D-F]|6[0-9A-F]|7[0-9A-F])[0-9A-Fa-f]{2})\b(.*)$', code)
            if em:      # level data
                code = '%s =$%04X%s' % (em.group(1), int(em.group(2), 16) + 0x3800, em.group(3))
            code = conv(code)
        out.append(code + com)
    open(path, 'w').write('\n'.join(out))

for p in sys.argv[1:]: main(p)
