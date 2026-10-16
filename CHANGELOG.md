# Changelog

## [0.8.0] - 2026-10-15

Works with PZFB 1.7.0+; **PZFB 1.8.0 recommended** (graceful stop so in-game saves survive closing, session ids so other PZFB mods can't kill your game, the long-session out-of-memory fix, the Proton fix). Everything 1.8-only is feature-detected and degrades to the old behaviour on 1.7.x class files.

### Added
- **Volume control** (promised May 3). A volume bar under the screen (`-` / `+` / `Mute` buttons, 10-segment meter) and keys **`-`** (−10 %), **`=`** (+10 %), **`M`** (mute) while playing; brief on-screen flash. Default **50 %** (sandbox option *Default Emulator Volume*), remembered per player in `~/Zomboid/Lua/PZEMU_settings.ini`. Sent to the bridge as a linear gain (new wire command 68) right after launch, again when the first frame arrives, and on every change.
- **Remappable keys** (promised May 1). "Controls..." button on the game list and the welcome screen opens an editor: primary + alternate key per button, click a row then press a key (ESC cancels, Backspace clears), a key already used elsewhere is moved, reserved keys are rejected with the reason (ESC, F5, F7, Scroll Lock, `-`, `=`, `M`). **WASD preset** per console (D-pad → W/A/S/D; NES/GB/Atari/GG/SMS: B/Fire/Button 1 = J (alt Z), A/Fire 2/Button 2 = K (alt X), Select = RShift, Start/Reset/Pause = Enter; SNES: B=J(Z) A=K(X) Y=U(C) X=I(V) L=Q R=E; Genesis: A=J(Z) B=K(X) C=L(C) X=U Y=I Z=O, Start = Enter) and "Reset defaults". Saved per console in `~/Zomboid/Lua/PZEMU_keys.ini` (delete it to reset everything); invalid, duplicate and reserved entries are dropped on load. Arrows + Z/X/A/S remain the defaults. The welcome screen shows the live bindings.
- **Handheld batteries that actually drain.** Game Boy / Game Gear use their charge in real time while a game runs (not while paused): one full charge = *Handheld Battery Life* sandbox minutes (default 600 real minutes = 10 hours, max 1440; 0 = never drain). Empty → the game freezes with a "BATTERIES DEAD" overlay and all input is blocked; the handheld now carries the vanilla `UsesBattery` tag, so right-click → **Insert Battery** (needs a Battery item; the handheld must be empty, like a flashlight) resumes the game automatically, and **Remove Battery** returns the charge to the Battery. Battery % is shown in the hint line (including the partial step). Partial drain is stored on the handheld (item modData `PZEMU_BatteryDrainAcc`), so it accumulates across sessions, saves and reloads instead of resetting when the emulator closes; a fresh battery clears it. A handheld that is already empty won't start (the menu says why). Advertised since 0.4.0, never implemented until now.
- **Context menu explains itself.** Options that used to be silently missing now appear **greyed out with a tooltip** saying why: PZFB class files not installed (with the install hint), TV not powered, no TV within 8 tiles on this floor, no cartridges of that system nearby, batteries dead (with the Insert Battery hint), no console of the cartridge's system nearby, cartridge without game data. (Haggar's "device menu won't open" was a different mod's menu — PZEMU has no device menu — but this covers the PZEMU side.)
- **`GAMES.md`** — the complete game list (224 games, 7 systems: game, exact ROM file name, dedicated/generic cartridge, spawn weight and share) plus **"How to add your own games and cartridges"** (ROM folders, the exact fuzzy-matching rules, pool entry format, dedicated cartridge item recipe, new-system note). Generated from the loot tables by `tools/gen_games_md.py` (stdlib Python; `--check` mode). Asked for ~5 times.
- **"System: Game" item names** — cartridges are now called e.g. `NES: Contra`, `Game Boy: Tetris` (Pleasance's suggestion). Named cartridges via `DisplayName` (existing saves pick it up), generic ones at spawn time; pre-0.8 generic cartridges in existing saves are renamed when the mod next touches them. The game picker shows bare names.
- **First-run "Bring your own ROMs" notice** (once; folder, matching rules, GAMES.md link).
- **Optional cartridge-blowing flavour** — sandbox *Cartridges Sometimes Need A Blow* (off by default): 12 % of launches stall on a boot screen; each blow has a 65 % chance to work and gives 1–2 points of unhappiness relief. The welcome screen follows unchanged. Timorous asked for it; Adam confirmed the folklore.
- **Sandbox options:** `PZEMU.DefaultVolume` (0–100, 50), `PZEMU.HandheldBatteryMinutes` (0–1440, 600), `PZEMU.CartridgeBlowing` (bool, false). *Cartridge Count Multiplier* tooltip now states that 0 spawns nothing.
- **Bridge protocol (contract C4):** `19` PAUSE ON, `20` PAUSE OFF (both idempotent; `18` toggle unchanged), `21` QUIT (flush SRAM + clean exit), `68` VOLUME (0–255 linear gain, 0 = mute; bridge default 255). stdin EOF / broken pipe, a failed frame write, SIGTERM/SIGINT and a core-requested shutdown all behave like QUIT. Full table in `analog.md` and the header of `bridge/pzemu-bridge.c`.
- **Bridge (Windows): Unicode paths.** argv is re-derived from `CommandLineToArgvW`, all file/library calls use the wide APIs (`_wfopen`, `LoadLibraryW`, `_wmkdir`, `MoveFileExW`), cores receive UTF-8 as libretro requires. Cores, ROMs and save folders outside the system codepage (e.g. a CJK or accented Windows user name) now load — the 0.7 exe failed with `Failed to load core` on such paths (reproduced under Wine). fceumm and Genesis Plus GX (`need_fullpath=1`) open the ROM themselves through libretro-common's UTF-8-aware VFS — verified on a CJK path.
- **Build:** `make windows` builds baseline x86-64 (`-march=x86-64 -mtune=generic`, `-lshell32`); new `make bmi2check` prints the BMI2 instruction count of both binaries (must be 0 / 0).

### Changed
- **Graceful shutdown.** Closing the window sends QUIT first, then a PZFB stop scoped to our own session. With PZFB 1.8 class files PZFB closes the bridge's stdin, closes the frame pipe, sends SIGTERM on Linux and only force-kills after 1.5 s — the bridge exits in ~0.1–0.2 s after writing SRAM (measured; wine 31–64 ms with EOF as the only signal). With **1.7.x class files** PZFB still kills immediately, so PZEMU defers the stop by ~1 s to let QUIT land; a game started in that window hands off cleanly. One residual case on 1.7: starting a second console while the first is being stopped may lose the first game's last SRAM changes.
- **PZFB 1.8 session API.** PZEMU stores the session id its launch returned, uploads frames and stops only through that id, and detects when another PZFB mod (PZVP, PZDOOM, …) takes the slot: the window shows "Another mod took over the emulator." instead of foreign frames, and never stops someone else's process.
- **Scroll Lock unlock now freezes the game** (PAUSE ON) instead of toggling — unlocking while already paused no longer unpauses. Locking again does not auto-resume; ESC still toggles pause.
- **Bridge (Windows): stdin is read on a dedicated thread** with blocking `ReadFile` into a ring buffer that the main loop drains every frame; EOF / `ERROR_BROKEN_PIPE` is latched after the last bytes are delivered and nothing is ever dropped. The 0.7 `PeekNamedPipe` polling loop failed when stdin was not a Win32 pipe (e.g. a Linux test harness driving the `.exe` through Wine — it delivered no input at all and never saw EOF); with a real Win32 parent `PeekNamedPipe` works, so no breakage on real Windows/Proton is implied. The thread design works in every case tested.
- Game picker is a scrolling list (`ISScrollingListBox`); welcome screen lists the live bindings in two columns for SNES/Genesis; all panels are created hidden and shown by view.
- `analog.md` protocol table updated (19/20/21/68); `AVOID.md` #21 (stdin polling).
- Linux bridge/core `.dat` files (`pzemu-bridge.dat`, `*_libretro.dat`) are now in the repository next to the Windows ones (they were untracked, so a fresh clone could not build a working Linux mod).

### Fixed
- **In-game saves were lost when closing the emulator.** Battery saves (SRAM) were written only at process exit, and PZFB ≤ 1.7 killed the bridge outright on close. The bridge now writes SRAM every 10 s while it changed (shadow compare) **and** exactly once on every exit path; SRAM and save-state writes are atomic (`<file>.tmp` → fsync → rename / `MoveFileExW(MOVEFILE_REPLACE_EXISTING)`), so a crash mid-write never damages the previous file. Save states (F5/F7) were always written immediately and were never affected. Verified in a harness with snes9x/gambatte/GPGX/stella; in-game confirmation pending.
- **Windows bridge crashed at startup on CPUs without BMI2** (pre-2013 Intel / pre-2015 AMD, `STATUS_ILLEGAL_INSTRUCTION`): the May build's MinGW runtime (`__mingw_pformat`, gdtoa — hit by every `fprintf("%.2f")`) contained 30 BMI2 instructions. Rebuilt with the baseline toolchain; both binaries verified BMI2-free (same bug class as PZDOOM 0.2.1; predicted by Deniss_).
- **Window close really closes.** B42's `ISCollapsableWindow:close()` only hides; PZEMU now stops the game, tears down both input panels (`cleanup()` on PZFB 1.8, release + listener removal on 1.7), clears the singleton and removes the window. Previously the hidden window kept its keyboard hooks alive (and a second window could be created on top).
- **Only televisions offer "Play …"** — detection uses `IsoTelevision`; `IsoWaveSignal` also matched placed radios.
- **`Cartridge Count Multiplier = 0`** now spawns nothing — the must-have game ignored the multiplier. Any positive multiplier still spawns at least one cartridge per console.
- Analog stick → D-pad no longer sticks after a slow return to center (fix is in PZFB 1.8.0's Lua, which PZEMU benefits from).
- Data: `The G.G. Shinobi` ROM name `Shinobi.gg` → `GG_Shinobi.gg` (matches the name the mod already looked for and the common dump name); `Road Rash II` ROM name made consistent between the pool and the named-cartridge table.

### Third-party mods
- "Literally Playable Video Game Consoles" is a separate, unsupported mod that replaces parts of PZEMU — report its issues on its own page.

### Corrections to earlier statements
- PZEMU never renames your ROM files (an April comment said it would replace spaces with underscores). It only *matches* names — see `GAMES.md` for the exact rules.
- Before 0.8.0 (and without PZFB 1.8.0 class files), in-game saves were not reliable — see Fixed above.

## [0.7.0] - 2026-05-02

### Added
- **Analog stick framework**: new wire-protocol extension (keycodes 64-67) carries left/right analog stick X/Y values to the bridge, decoded into libretro's `RETRO_DEVICE_ANALOG` polls. Console entries opt in via `analog = true` and `portDevice = <N>` (libretro device subclass — e.g., 517 for Beetle PSX DualShock, 261 for Swanstation). Default consoles (NES, SNES, Genesis, GB, Atari 2600, Game Gear, SMS) keep their existing left-stick→D-pad threshold behavior unchanged.
- **`PZEMUGame:sendGamepadAxis(axisId, value)`** — public Lua method for forwarding axis values; quantizes float `[-1.0, 1.0]` to 8 bits and packs into the existing 2-byte protocol.
- **Bridge accepts optional 7th argv `port_device`** passed to `retro_set_controller_port_device(port=0, …)`. Defaults to `RETRO_DEVICE_JOYPAD (1)` when absent.
- **Committed Windows cross-compile recipe** (`make windows` in `bridge/`) — uses sibling pzdoom MinGW SDL2 dev files. Replaces the previous undocumented ad-hoc Windows build.

### Fixed
- **Bridge / core auto-redeploy on mod update**: `deployBinaries()` now redeploys when source `.dat` size differs from deployed binary instead of skipping if destination merely exists. Existing users will pick up the v0.7.0 bridge automatically on next launch.

### For mod customizers (advanced)
- Drop a libretro core in `~/Zomboid/PZEMU/`, add a console entry with `analog = true` and the right `portDevice` to your local copy of `CONSOLES`, and analog forwarding works. PSX requires region BIOS files in the per-console save dir; PPSSPP ignores `portDevice` (its `retro_set_controller_port_device` is a no-op stub — leave it unset). See `analog.md` in the source repo for the full how-to and per-core constants.

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
