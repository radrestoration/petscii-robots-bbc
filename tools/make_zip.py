#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""The distribution zip: the disc image, a b-em run script, the README with its screenshots and the licence.   make_zip.py OUT.zip"""
import os
import sys
import zipfile

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main(out):
    top = os.path.splitext(os.path.basename(out))[0]
    files = [("build/robots.ssd", "robots.ssd", 0o644), ("tools/dist_run.sh", "run.sh", 0o755), ("README.md", "README.md", 0o644),
             ("LICENSE", "LICENSE", 0o644), ("screenshots/title.png", "screenshots/title.png", 0o644),
             ("screenshots/play1.png", "screenshots/play1.png", 0o644)]
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for src, name, mode in files:
            info = zipfile.ZipInfo("%s/%s" % (top, name), date_time=(2026, 10, 31, 0, 0, 0))
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, open(os.path.join(R, src), "rb").read())
    print("wrote %s (%d bytes)" % (out, os.path.getsize(out)))


if __name__ == "__main__":
    main(sys.argv[1])
