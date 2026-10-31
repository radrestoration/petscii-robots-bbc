#!/bin/bash -e
# SPDX-License-Identifier: GPL-3.0-only
# Runs the original C64 shareware disc in VICE, for comparing against the BBC port.  The disc is part of the upstream download
# (upstream/, not in this repo).  Extra arguments go to VICE (e.g. -ntsc).  Tool path: VICE in tools.cfg, or the environment.
#
# +drive8truedrive -virtualdev8: VICE's ROM-less virtual drive, which loads straight from the image (no 1541 drive ROM needed);
# the same options as the Undead port's run-c64.sh.
cd "$(dirname "$0")"
[ -f tools.cfg ] && . ./tools.cfg
VICE=${VICE:-x64sc}
DISC="upstream/C64 Robots Shareware 06-04-2022/c64robots-shareware.d64"
[ -f "$DISC" ] || { echo "missing $DISC (run make ssd or tools/fetch_upstream.sh first, or copy the shareware disc there)" >&2; exit 1; }
exec $VICE -VICIIfilter 0 +drive8truedrive -virtualdev8 "$@" -autostart "$PWD/$DISC"
