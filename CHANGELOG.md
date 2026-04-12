# Changelog

## [0.3.0] - 2026-04-12

### Added
- **Gamepad support** for all consoles via PZFB's PZFBInputPanel gamepad system
  - D-pad and face buttons mapped per-console through `gamepadMap` config
  - Left analog stick converted to D-pad input with 0.5 deadzone threshold
  - SNES: full RetroPad 1:1 mapping (B/A/Y/X/L/R/Start/Back)
  - Genesis: face buttons map to A/B/C, bumpers to X/Y/Z (6-button)
  - NES/Game Boy: B/A/Start/Back
  - Atari 2600: A or B = Fire, Start = Reset, Back = Select
  - Game Gear/Master System: B = Button 1, A = Button 2, Start
- Welcome screen now shows "Gamepad supported" hint

## [0.2.0] - 2026-04-11

### Added
- **Multi-console support** — 6 new consoles alongside NES:
  - SNES via Snes9x (256x224) — Z/A=B, X/S=A, C/D=Y, V/F=X, Q=L, E=R
  - Sega Genesis via Genesis Plus GX (320x224) — Z/A=A, X/S=B, C/D=C, Q=X, W=Y, E=Z (6-button)
  - Game Boy via Gambatte (160x144) — same layout as NES
  - Atari 2600 via Stella (320x228) — Z/A=Fire, Enter=Reset, RShift=Select
  - Game Gear via Genesis Plus GX (160x144) — Z/A=1, X/S=2, Enter=Start
  - Master System via Genesis Plus GX (256x192) — Z/A=1, X/S=2
- Console picker UI — right-click TV now shows "Play Console", select system first, then ROM
- Per-console control hints on welcome screen
- Console configuration system with per-console key maps, core files, ROM extensions, and dimensions
- Dynamic window title shows selected console name
- Bridge frame centering — cores that output smaller frames than configured dimensions are centered with black padding (handles Genesis starting at 256x192 before switching to 320x224)

### Changed
- Context menu changed from "Play NES" to "Play Console"
- PZEMUGame constructor now takes a console config parameter instead of being NES-hardcoded
- ROM scanning is per-console with configurable extensions (.smc/.sfc for SNES, .md/.gen/.bin/.smd for Genesis, .gb for Game Boy, .a26/.bin for Atari 2600, .gg for Game Gear, .sms for Master System)
- Bridge binary no longer overrides CLI dimensions from core geometry — fixed output size matches Java ring buffer
- Deploy function iterates all console cores (deduplicates shared cores like Genesis Plus GX)

### Fixed
- `getUserDir()` in PZEMUWindow.lua was defined after functions that reference it — Lua upvalue would be nil at call time
- Bridge SET_GEOMETRY callback no longer changes output frame size mid-game, preventing ring buffer misalignment with dynamic-resolution cores

## [0.1.0] - 2026-04-11

### Added
- Bridge binary (`pzemu-bridge`) — generic libretro frontend that loads any core via dlopen
  - RGBA frame piping to stdout for PZFB game process protocol
  - Non-blocking stdin input with partial-read buffering
  - Precise `clock_gettime`/`nanosleep` frame timer for smooth playback
  - SRAM save/load persistence with signal handling (SIGTERM/SIGINT)
  - XRGB8888, RGB565, and 0RGB1555 pixel format conversion
  - Pipe buffer optimization (1MB via F_SETPIPE_SZ)
  - Auto-creates save directories on first write
  - Save states via F5/F7 (retro_serialize/unserialize)
  - ESC freezes/unfreezes emulation (stops retro_run, mutes audio)
- Lua mod layer
  - Right-click any TV to play retro games via context menu hook
  - ROM picker UI with scanning of bundled and user ROM directories
  - Welcome screen with control layout
  - Game panel with PZFBInputPanel for input capture (MODE_FOCUS)
  - Aspect-correct scaling with letterboxing
  - Binary and core auto-deployment from .dat files
- NES support via FCEUmm libretro core (256x224, XRGB8888)
- 3 bundled free homebrew ROMs (Chase, LAN Master, Zooming Secretary)
- Meta-command protocol: keycode >= 16 triggers bridge-side actions (pause, save/load state)

### Fixed
- ISPanel constructor calls used colon syntax — panels rendered as black
- Load state changed from F9 to F7 (F9 conflicts with PZ keybinding)
- Added A/S as alternate B/A buttons for keyboard ghosting workaround
- Replaced audio backpressure frame limiter with precise nanosleep timer

### Known Issues
- ROM filenames with spaces break due to PZFB's `gameStart()` splitting extraArgs on whitespace — rename files to use underscores
