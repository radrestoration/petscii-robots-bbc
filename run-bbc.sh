#!/bin/bash -e
# Runs the BBC Master disc in b-em (model 10 = Master 128, autoboots).  Tool paths: tools.cfg
cd "$(dirname "$0")"
[ -f tools.cfg ] && . ./tools.cfg
BEM=${BEM:-b-em}
[ -f build/robots.ssd ] || make ssd
DISC="$PWD/build/robots.ssd"
[ -n "$BEM_DIR" ] && cd "$(eval echo $BEM_DIR)"
exec $BEM -m10 -disc "$DISC" -autoboot
