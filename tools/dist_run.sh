#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Runs robots.ssd in b-em as a Master 128 (autoboot).  BEM=/path/to/b-em if it is not on your PATH.
# On a real Master: put robots.ssd on a disc, hold Shift and tap Break.
cd "$(dirname "$0")" || exit 1
exec ${BEM:-b-em} -m10 -disc "$PWD/robots.ssd" -autoboot
