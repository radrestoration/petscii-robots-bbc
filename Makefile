# SPDX-License-Identifier: GPL-3.0-only
# PETSCII Robots - BBC Master port.   make help
-include tools.cfg
ifneq ($(strip $(CC65_HOME)),)
export CC65_HOME
CA65 ?= $(CC65_HOME)/bin/ca65
LD65 ?= $(CC65_HOME)/bin/ld65
endif
CA65 ?= ca65
LD65 ?= ld65
PYTHON ?= python3 -I
ZIPTOOL ?= zip

SRC = source/robots.s source/background_tasks.s $(wildcard source/platform/bbc/*.s)

.PHONY: help upstream data all test clean ssd zip release publish
help:
	@echo "make upstream fetch the C64/PET/VIC-20 sources and assets the build reads (tools/fetch_upstream.sh)"
	@echo "make data    convert the C64 assets (build/data)"
	@echo "make all     assemble + link the BBC images (build/robots-{low,mid,gfx}.bin)"
	@echo "make ssd     build/robots.ssd (boots on a Master: shift-break)"
	@echo "make zip      build/petscii-robots-bbc.zip: the disc, run.sh, README, LICENSE (for a release)"
	@echo "make release build/release/: the zip named with the version, VERSION.txt inside it, SHA256SUMS (committed tree only)"
	@echo "make publish TAG=v0.1.0   tag it, push the tag and make a GitHub release with those files (gh; DRY=1 shows what it would do)"
	@echo "make test   renderer, sprite, whole-screen, loader, overview-map and sound and music tests in the headless 6502 simulator (~8 min)"
	@echo "make clean"

upstream/c64/tileset.gfx upstream/Plus4/SOUND.ASM:
	tools/fetch_upstream.sh
upstream: upstream/c64/tileset.gfx

data: build/data/palette.inc
build/data/palette.inc build/data/scr_text.inc build/data/scr_color.inc build/data/tile_meta.inc build/data/tile_kind.inc: tools/make_data.py tools/c64data.py upstream/c64/tileset.gfx
	$(PYTHON) tools/make_data.py
build/data/music_core.inc build/data/music_tab.inc build/data/music_meta.inc: tools/music_port.py tools/sim6502.py upstream/c64/music.c64
	@mkdir -p build/data
	$(PYTHON) tools/music_port.py
build/data/music_conv.inc: tools/music_conv.py
	@mkdir -p build/data
	$(PYTHON) tools/music_conv.py
build/data/sound.inc: tools/make_sound.py upstream/Plus4/SOUND.ASM
	@mkdir -p build/data
	$(PYTHON) tools/make_sound.py

all: build/robots-mid.bin
build/robots-mid.bin: $(SRC) source/bbc.cfg build/data/palette.inc build/data/scr_text.inc build/data/scr_color.inc build/data/sound.inc build/data/tile_meta.inc build/data/tile_kind.inc build/data/music_core.inc build/data/music_tab.inc build/data/music_meta.inc build/data/music_conv.inc
	@mkdir -p build
	$(CA65) -g -t none -I build/data -I source --bin-include-dir build/data -o build/robots.o source/robots.s
	$(LD65) -C source/bbc.cfg -o build/robots build/robots.o -m build/robots.map --dbgfile build/robots.dbg
	@ls -l build/robots-*.bin

build/loader.bin: source/platform/bbc/loader.s source/loader.cfg
	@mkdir -p build
	$(CA65) -t none -o build/loader.o source/platform/bbc/loader.s
	$(LD65) -C source/loader.cfg -o $@ build/loader.o

build/MUS0: build/robots-mid.bin tools/music_port.py
	$(PYTHON) tools/music_port.py songs build/robots.dbg build

ssd: all build/loader.bin build/MUS0
	@grep -q 'name="START",.*val=0x3000' build/robots.dbg || (echo "START moved: update the loader"; false)
	$(PYTHON) tools/make_disc.py build/robots.ssd

ZIP = build/petscii-robots-bbc.zip

zip: ssd tools/make_zip.py tools/dist_run.sh README.md LICENSE
	$(PYTHON) tools/make_zip.py $(ZIP)

# make release                  the zip, named with the version, plus VERSION.txt inside it
#                               and SHA256SUMS -> build/release/ (committed tree only)
# make publish TAG=v0.1.0-rc1   tag it, push the tag, and a GitHub release with those files
#                               (gh, logged in); a "-" in the tag makes it a pre-release.
#                               The release notes are that tag's "## vX.Y.Z" section of
#                               CHANGELOG.md. DRY=1 prints what it would do.
# The version is `git describe`: the tag itself on a tagged commit, else tag-N-gHASH.

VERSION := $(shell git describe --tags --always 2>/dev/null)

# The release notes are the "## <TAG>" section of CHANGELOG.md (to the next "## "); publish
# refuses a tag with no section. CHANGELOG.md is kept by hand, newest version first.
NOTES = awk -v t='$(TAG)' '$$0 ~ "^\#\# \\[?" t "\\]?( |$$)" {p=1; next} /^\#\# /{p=0} p' CHANGELOG.md

release: ## versioned zip + SHA256SUMS -> build/release/ (refuses uncommitted changes)
	@git diff --quiet HEAD -- || { echo "release: uncommitted changes - commit first"; exit 1; }
	$(MAKE) zip
	@rm -rf build/release && mkdir -p build/release
	@printf '%s\n' "petscii-robots-bbc $(VERSION)" "commit $$(git rev-parse HEAD)" "built $$(date -u +%Y-%m-%dT%H:%MZ)" > build/release/VERSION.txt
	@cp $(ZIP) build/release/petscii-robots-bbc-$(VERSION).zip
	@$(ZIPTOOL) -j -X -q build/release/petscii-robots-bbc-$(VERSION).zip build/release/VERSION.txt
	cd build/release && sha256sum *.zip > SHA256SUMS
	@ls -l build/release

publish: ## tag TAG=vX.Y.Z[-rcN], push it, and attach build/release/ to a GitHub release (gh)
	@test -n "$(TAG)" || { echo "publish: TAG=vX.Y.Z[-rcN] needed"; exit 1; }
	@git diff --quiet HEAD -- || { echo "publish: uncommitted changes - commit first"; exit 1; }
	@git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null && { echo "publish: tag $(TAG) exists"; exit 1; } || true
	@$(NOTES) | grep -q '[^[:space:]]' || { echo "publish: CHANGELOG.md has no '## $(TAG)' section with text in it"; exit 1; }
	$(if $(DRY),@echo "would: git tag $(TAG); make release; git push origin $(TAG); gh release create $(TAG) build/release/*.zip build/release/SHA256SUMS --title $(TAG) --notes-file <the '## $(TAG)' section of CHANGELOG.md> $(if $(findstring -,$(TAG)),--prerelease)"; echo "---- release notes ----"; $(NOTES),\
	  git tag $(TAG) && $(MAKE) release && $(NOTES) > build/release/NOTES.md && git push origin $(TAG) && \
	  gh release create $(TAG) build/release/*.zip build/release/SHA256SUMS --title $(TAG) --notes-file build/release/NOTES.md $(if $(findstring -,$(TAG)),--prerelease))

test: all build/loader.bin
	$(PYTHON) tools/render_test.py
	$(PYTHON) tools/verify_test.py
	$(PYTHON) tools/anim_test.py
	$(PYTHON) tools/loader_test.py
	$(PYTHON) tools/map_test.py
	$(PYTHON) tools/window_test.py
	$(PYTHON) tools/arrow_test.py
	$(PYTHON) tools/sound_test.py
	$(PYTHON) tools/music_conv_test.py 1500
	$(PYTHON) tools/music_test.py 1500

clean:
	rm -f build/robots* build/*.o build/loader.*
