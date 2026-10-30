#!/bin/sh
# Fetch the third-party sources this port reads, at the commits it was built from, into upstream/ (not part of this repo).
#   c64   - assets (tileset, font, sprites, 14 levels) and the C64 source `make data` takes the game screen layout from
#   pet   - the game-logic source (BACKGROUND_TASKS.ASM) that source/background_tasks.s was translated from
#   vic20 - only for the Mode 2 preview tools (tools/mode2_*.py)
# Each repo has its own README and terms; see them before redistributing anything derived from them.
set -e
cd "$(dirname "$0")/.."
mkdir -p upstream
fetch() {   # name url commit
    if [ -d "upstream/$1/.git" ]; then echo "upstream/$1 already there"; return; fi
    git clone -q "$2" "upstream/$1"
    git -C "upstream/$1" checkout -q "$3"
    echo "upstream/$1 at $3"
}
fetch c64   https://github.com/zeropolis79/PETSCIIRobots-C64  63b4d6cb0b5f0b44fb570cf499524a4d5d5e8818
fetch pet   https://github.com/zeropolis79/PETSCIIRobots-Pet  83058d15d8f004e707c7838eb3e1d8e123ce34dd
fetch vic20 https://github.com/zeropolis79/PETSCIIRobots-Vic20 f0b349f622ecde4c1374cd1b10467cc7884090c5
