# Changelog

## [0.1.0] - 2026-04-11

### Added
- Bridge binary (`pzemu-bridge`) — generic libretro frontend that loads any core via dlopen
  - RGBA frame piping to stdout for PZFB game process protocol
  - Non-blocking stdin input with partial-read buffering
  - SDL2 audio with queue backpressure as frame rate limiter
  - SRAM save/load persistence with signal handling (SIGTERM/SIGINT)
  - XRGB8888, RGB565, and 0RGB1555 pixel format conversion
  - Pipe buffer optimization (1MB via F_SETPIPE_SZ)
  - Auto-creates save directories on first write
- Lua mod layer
  - Right-click any TV to "Play NES" via context menu hook
  - ROM picker UI with scanning of bundled and user ROM directories
  - Welcome screen with NES control layout
  - Game panel with PZFBInputPanel for input capture (MODE_FOCUS)
  - Aspect-correct scaling with letterboxing
  - Binary and core auto-deployment from .dat files
- NES support via FCEUmm libretro core (256x224, XRGB8888)
- 3 bundled free homebrew ROMs (Chase, LAN Master, Zooming Secretary)
- NES key mapping: Z=B, X=A, Arrows=D-pad, Enter=Start, RShift=Select
- Scroll Lock toggles input lock
- ESC freezes/unfreezes emulation (stops retro_run, mutes audio)
- F5 saves emulator state to .state file, F9 loads it
- Meta-command protocol: keycode >= 16 triggers bridge-side actions (pause, save/load state)

### Fixed
- ISPanel constructor calls used colon syntax (`ISPanel:new()`) instead of dot syntax (`ISPanel.new(self, ...)`), causing ROM picker and welcome panels to render as plain black panels with no content
- Changed load state from F9 to F7 (F9 conflicts with PZ's built-in keybinding)
- Added A/S as alternate B/A buttons to work around keyboard ghosting when holding Z + Arrow + X simultaneously
- Replaced audio backpressure frame limiter with precise `clock_gettime`/`nanosleep` timer — fixes choppy scrolling and audio in fast games like Super Mario Bros. 3

### Known Issues
- ROM filenames with spaces break due to PZFB's `gameStart()` splitting extraArgs on whitespace — rename files to use underscores
