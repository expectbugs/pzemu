# Changelog

## [0.6.0] - 2026-04-22

### Added
- **Sandbox options**: `PZEMU.ConsoleRateMultiplier` (scales console spawn rates from 0.0x to 5.0x) and `PZEMU.CartridgeCountMultiplier` (scales per-console cartridge spawn counts from 0.0x to 5.0x). Accessible under the "PZEMU - Retro Consoles" page in PZ's Sandbox Options UI.
- **Three bundled homebrew NES games** now spawn in loot: `Chase`, `LAN Master`, `Zooming Secretary`. Previously these ROMs shipped with the mod but were never referenced by the distribution pool.
- Extended ROM fuzzy-matcher with Roman numerals V through X, diacritic stripping (Pokémon -> Pokemon, Señor -> Senor), leading-article drop (The/A/An) on both sides, em-dash / en-dash / colon separator normalization, and straight <-> curly apostrophe handling.

### Fixed
- **Windows path handling with spaces, apostrophes, and Unicode** (Error Code 1 / 0x0 resolution). Migrated to `PZFB.gameStartArgs()` (available in PZFB 1.7.0+), which passes arguments as an array instead of whitespace-splitting a single string. Users with Windows usernames containing spaces, OneDrive-redirected Documents folders, or non-ASCII characters in their paths should now be able to launch games without issue.
- Orphaned bridge processes after unexpected PZ exit are now cleaned up automatically via PZFB 1.7.0's JVM shutdown hook (no PZEMU code change required; we just benefit from the new PZFB behavior).

### Documented
- Multiplayer is client-local: each player runs their own emulator instance, frames are not network-synced, and both PZFB and PZEMU must be installed on every client.

### Required
- **PZFB 1.7.0 or newer** for full functionality (the space-in-path fix and shutdown-hook cleanup). Users on older PZFB versions will still have the mod work but may hit the Windows path crash.

## [0.5.0] - 2026-04-12

### Added
- **Full Windows support** — cross-compiled bridge binary (MinGW), Windows libretro core DLLs, SDL2.dll auto-deployment
- **220 games across 7 systems** — NES (58), SNES (72), Genesis (29), GB (39), Atari 2600 (9), Game Gear (10), SMS (4)
- **31 new named cartridge items** with dedicated VGC/SEGA addon icons
  - Genesis: 22 new (Altered Beast, Streets of Rage 1&2, Sonic 2, Strider, TMNT, and more)
  - SNES: Star Fox, Secret of Mana, NBA Jam
  - Game Gear: Klax, OutRun Europa, Paperboy, The G.G. Shinobi
  - Game Boy: Final Fantasy Legend
  - Atari: Ms. Pac-Man
- Workshop preview.png for Steam Workshop publishing
- ROM directory instructions and Retrode recommendation in mod description

### Fixed
- **TV power detection** — uses `hasGridPower()` in addition to `haveElectricity()` to detect both grid and generator power (verified from ISVehicleMenu.lua and ISWorldObjectContextMenu.lua)
- **Player inventory scanning** — uses `getAllEvalRecurse()` to search bags, pockets, and all sub-containers (not just root inventory)
- **Fuzzy ROM matching** — normalizes filenames by stripping region codes, version tags, dump flags, apostrophes, and converting Roman numerals (II→2, III→3, IV→4) for matching against common ROM naming conventions
- **Context menu safety** — inventory handler wrapped in pcall to prevent errors from breaking PZ's context menu system
- Donkey Kong Country and Mega Man X romFile names updated to match common ROM dump naming (_1 suffix)
- Added Final Fantasy: Mystic Quest to SNES game pool

## [0.4.0] - 2026-04-12

### Added
- **Lootable console and cartridge items** — 7 console types and ~30 named cartridges as PZ items
  - NES, SNES, Genesis, Game Boy, Atari 2600, Game Gear, Master System
  - Named cartridges with dedicated VGC-sourced icons (Mario, Zelda, Sonic, Tetris, etc.)
  - Generic cartridges with randomized game names from weighted pools
- **Wealth-based loot distribution** — consoles spawn in contextually appropriate locations
  - NES ubiquitous in kids' bedrooms and living rooms
  - SNES more common in wealthy homes, rare in poor
  - Atari 2600 found in garages and closets (obsolete by 1993)
  - Game Boy in school lockers and kids' rooms
  - Game Gear rare (expensive handheld)
  - Master System rare in US market
- **Cartridge spawning via OnFillContainer** — cartridges appear alongside their consoles
  - 3-7 games per console, 15% chance of 8+ bonus games
  - Must-have game always included (Mario with NES, Sonic with Genesis, Tetris with Game Boy)
  - Weighted rarity: common games (Mario) nearly universal, rare games (Dragon Warrior IV) very scarce
- **Three context menu entry points**
  - Right-click TV: "Play NES", "Play SNES", etc. for each nearby console (requires power)
  - Right-click console item: "Play <Console>" if powered TV nearby (or battery for handhelds)
  - Right-click cartridge: "Play <Game>" launches directly
- **Proximity detection** — 8-tile range scan for consoles, cartridges, and TVs
  - Checks player inventory, world objects on ground, and items in nearby containers
- **Power requirements** — stationary consoles require a powered TV within range
- **Handheld battery drain** — Game Boy and Game Gear use Drainable item type
- **Mood effects** — playing reduces stress, boredom, and unhappiness over time
- **ROM-not-found message** — shows exact filename and directory path when ROM is missing
- Console and cartridge icon textures sourced from VGC Workshop mod (MIT licensed)

### Changed
- Context menu now shows per-console options instead of generic "Play Console"
- Game selection shows nearby cartridges instead of filesystem ROM scan
- Window opens from context menu with console pre-selected
- Mod name updated to "REAL Zomboid Console Emulation"

### Removed
- Console picker UI panel (console selection now via context menu)
- Filesystem ROM scanning (replaced by cartridge-based game selection)

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
