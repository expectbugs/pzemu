CC = gcc
CFLAGS = -Wall -Wextra -O2 $(shell pkg-config --cflags sdl2)
LDFLAGS = $(shell pkg-config --libs sdl2) -ldl -lm

TARGET = pzemu-bridge
SRC = pzemu-bridge.c

$(TARGET): $(SRC) libretro.h
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: clean
