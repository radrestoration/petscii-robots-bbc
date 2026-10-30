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

SRC = source/robots.s source/background_tasks.s $(wildcard source/platform/bbc/*.s)

.PHONY: help upstream data all test clean ssd
help:
	@echo "make upstream fetch the C64/PET/VIC-20 sources and assets the build reads (tools/fetch_upstream.sh)"
	@echo "make data    convert the C64 assets (build/data)"
	@echo "make all     assemble + link the BBC images (build/robots-{low,mid,gfx}.bin)"
	@echo "make ssd     build/robots.ssd (boots on a Master: shift-break)"
	@echo "make test    renderer, sprite, whole-screen, loader, overview-map and sound tests in the headless 6502 simulator (~6 min)"
	@echo "make clean"

upstream/c64/tileset.gfx upstream/Plus4/SOUND.ASM:
	tools/fetch_upstream.sh
upstream: upstream/c64/tileset.gfx

data: build/data/palette.inc
build/data/palette.inc build/data/scr_text.inc build/data/scr_color.inc: tools/make_data.py tools/c64data.py upstream/c64/tileset.gfx
	$(PYTHON) tools/make_data.py
build/data/sound.inc: tools/make_sound.py upstream/Plus4/SOUND.ASM
	@mkdir -p build/data
	$(PYTHON) tools/make_sound.py

all: build/robots-mid.bin
build/robots-mid.bin: $(SRC) source/bbc.cfg build/data/palette.inc build/data/scr_text.inc build/data/scr_color.inc build/data/sound.inc
	@mkdir -p build
	$(CA65) -g -t none -I build/data -I source --bin-include-dir build/data -o build/robots.o source/robots.s
	$(LD65) -C source/bbc.cfg -o build/robots build/robots.o -m build/robots.map --dbgfile build/robots.dbg
	@ls -l build/robots-*.bin

build/loader.bin: source/platform/bbc/loader.s source/loader.cfg
	@mkdir -p build
	$(CA65) -t none -o build/loader.o source/platform/bbc/loader.s
	$(LD65) -C source/loader.cfg -o $@ build/loader.o

ssd: all build/loader.bin
	@grep -q 'name="START",.*val=0x3000' build/robots.dbg || (echo "START moved: update the loader"; false)
	$(PYTHON) tools/make_disc.py build/robots.ssd

test: all build/loader.bin
	$(PYTHON) tools/render_test.py
	$(PYTHON) tools/verify_test.py
	$(PYTHON) tools/loader_test.py
	$(PYTHON) tools/map_test.py
	$(PYTHON) tools/sound_test.py

clean:
	rm -f build/robots* build/*.o build/loader.*
