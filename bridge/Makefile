CC = gcc
CFLAGS = -Wall -Wextra -O2 $(shell pkg-config --cflags sdl2)
LDFLAGS = $(shell pkg-config --libs sdl2) -ldl -lm

TARGET = pzemu-bridge
SRC = pzemu-bridge.c

$(TARGET): $(SRC) libretro.h
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Cross-compile for Windows using MinGW + SDL2 from sibling pzdoom project.
# Requires x86_64-w64-mingw32-gcc and the SDL2 mingw dev tree fetched into
# pzdoom's doom/mingw-sdl2/. The bridge has #ifdef _WIN32 guards for
# LoadLibrary/GetProcAddress so dlopen symbols aren't needed on Windows.
#
# -march=x86-64 -mtune=generic: baseline x86-64 only. The May 2026 build
# picked up BMI2 (shlx/sarx/...) inside the MinGW runtime (__mingw_pformat,
# gdtoa) and crashed with STATUS_ILLEGAL_INSTRUCTION on pre-Haswell Intel /
# pre-Excavator AMD CPUs. Verify with `make bmi2check` after every build.
WIN_SDL_DIR = /home/user/pzdoom/doom/mingw-sdl2/SDL2-2.30.12/x86_64-w64-mingw32
WIN_CC = x86_64-w64-mingw32-gcc
WIN_OBJDUMP = x86_64-w64-mingw32-objdump

windows: $(SRC) libretro.h
	PKG_CONFIG_PATH=$(WIN_SDL_DIR)/lib/pkgconfig \
	$(WIN_CC) -O2 -Wall -Wextra -march=x86-64 -mtune=generic \
		-I$(WIN_SDL_DIR)/include/SDL2 \
		-o pzemu-bridge.exe $(SRC) \
		-L$(WIN_SDL_DIR)/lib -lmingw32 -lSDL2main -lSDL2 -lshell32

# Count BMI2 instructions in both binaries — must print 0 for each.
BMI2_RE = '\s(shlx|shrx|sarx|rorx|bzhi|pdep|pext|mulx)\s'
bmi2check:
	@printf '%-20s ' pzemu-bridge.exe; $(WIN_OBJDUMP) -d --no-show-raw-insn pzemu-bridge.exe | grep -cE $(BMI2_RE) || true
	@printf '%-20s ' $(TARGET); objdump -d --no-show-raw-insn $(TARGET) | grep -cE $(BMI2_RE) || true

clean:
	rm -f $(TARGET) pzemu-bridge.exe

.PHONY: clean windows bmi2check
