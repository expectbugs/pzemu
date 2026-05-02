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
WIN_SDL_DIR = /home/user/pzdoom/doom/mingw-sdl2/SDL2-2.30.12/x86_64-w64-mingw32
WIN_CC = x86_64-w64-mingw32-gcc

windows: $(SRC) libretro.h
	PKG_CONFIG_PATH=$(WIN_SDL_DIR)/lib/pkgconfig \
	$(WIN_CC) -O2 -Wall -Wextra \
		-I$(WIN_SDL_DIR)/include/SDL2 \
		-o pzemu-bridge.exe $(SRC) \
		-L$(WIN_SDL_DIR)/lib -lmingw32 -lSDL2main -lSDL2

clean:
	rm -f $(TARGET) pzemu-bridge.exe

.PHONY: clean windows
