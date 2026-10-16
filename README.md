# PZEMU — REAL Zomboid Console Emulation

Find retro game consoles and cartridges while looting Knox Country, plug them into a powered TV (or just pick up a Game Boy) and **play the actual games** inside Project Zomboid. Not a timer that lowers boredom — real emulation (libretro cores) rendered through the [Video Framebuffer (PZFB)](https://github.com/expectbugs/pzfb) library, at full speed, with sound and gamepad support.

Steam Workshop: [REAL Zomboid Console Emulation](https://steamcommunity.com/sharedfiles/filedetails/?id=3705757669) · Game list: [GAMES.md](GAMES.md) · Changes: [CHANGELOG.md](CHANGELOG.md)

**7 systems:** NES, SNES, Sega Genesis, Game Boy, Atari 2600, Game Gear, Master System — everything that existed in July 1993 Kentucky. **224 games** in the loot tables with wealth-based distribution (SNES in rich homes, Atari in garages, Game Boys in school lockers…).

## Requirements

- Project Zomboid **Build 42** (tested on 42.21).
- **[Video Framebuffer (PZFB)](https://steamcommunity.com/sharedfiles/filedetails/?id=3698742271)** — subscribe, enable, and do its one-time extra install step (it copies 10 class files into the game folder; a panel on the main menu tells you where the script is). **PZEMU does nothing without it.** PZFB 1.7.0+ works; **1.8.0 recommended**: in-game saves survive closing the window, PZEMU can't be killed by PZVP/PZDOOM windows, and the long-session out-of-memory crash is fixed.
- **Your own ROM files.** PZEMU ships no commercial games. Three free homebrew NES games (Chase, LAN Master, Zooming Secretary) are bundled and work out of the box. For dumping your own cartridges a Retrode (USB cartridge reader) is the easy legal way.
- Linux and Windows. Audio goes straight to your system (SDL2), not through PZ.

## ROM folders

Put ROMs in your Zomboid **user** folder (not the game install):

| System | Folder | Extensions |
|---|---|---|
| NES | `Zomboid/PZEMU/roms/nes/` | `.nes` |
| SNES | `Zomboid/PZEMU/roms/snes/` | `.smc` `.sfc` |
| Genesis | `Zomboid/PZEMU/roms/genesis/` | `.md` `.gen` `.bin` `.smd` |
| Game Boy | `Zomboid/PZEMU/roms/gb/` | `.gb` |
| Atari 2600 | `Zomboid/PZEMU/roms/atari2600/` | `.a26` `.bin` |
| Game Gear | `Zomboid/PZEMU/roms/gg/` | `.gg` |
| Master System | `Zomboid/PZEMU/roms/sms/` | `.sms` |

Linux: `~/Zomboid/PZEMU/roms/…`. Windows: `C:\Users\<you>\Zomboid\PZEMU\roms\…`. The folders are created the first time the emulator runs. Zipped ROMs are not read.

When you pick a game, PZEMU looks for the exact file name listed in [GAMES.md](GAMES.md) (e.g. `Super_Mario_Bros_3.nes`), then falls back to fuzzy matching that ignores region/revision tags, punctuation, articles and roman numerals (`Super Mario Bros. 3 (USA) (PRG1) [!].nes` works). PZEMU **never renames or moves** your files. If a game isn't found, the window shows the file name it expected and the folder.

Saves: `Zomboid/PZEMU/saves/<system>/<rom>.srm` (battery saves) and `<rom>.state` (save states). Emulator binaries and cores are copied to `Zomboid/PZEMU/` on first use.

## How to play

- **Right-click a TV** → "Play NES" etc. for every console within 8 tiles on the same floor (TV must be powered — grid or generator).
- **Right-click a console item** → "Play <console>" if a powered TV is near (handhelds need no TV).
- **Right-click a cartridge** → "Play <game>".
- Options that aren't available are **greyed out with a tooltip saying why** (no power, no TV nearby, no cartridges, dead batteries, PZFB not installed…).
- Pick a game from the list (the console's cartridges within reach), read the controls on the welcome screen, click to start.

Playing reduces stress, boredom and unhappiness. Each player runs the emulator on their own machine — see Multiplayer.

## Controls

Keyboard works while the mouse is over the emulator screen (**FOCUS** mode). Press **Scroll Lock** to lock all keyboard input to the emulator regardless of the mouse; unlocking (Scroll Lock again) **freezes** the game so nothing happens while you're away. **ESC** freezes/unfreezes (and releases the lock).

| Key | Action |
|---|---|
| Arrow keys | D-pad / joystick |
| **Z** (alt **A**) | NES/GB **B** · SNES **B** · Genesis **A** · Atari **Fire** · GG/SMS **Button 1** |
| **X** (alt **S**) | NES/GB **A** · SNES **A** · Genesis **B** · Atari **Fire 2** · GG/SMS **Button 2** |
| **C** (alt **D**) | SNES **Y** · Genesis **C** |
| **V** (alt **F**) | SNES **X** |
| **Q** / **E** | SNES **L** / **R** · Genesis **X** / **Z** |
| **W** | Genesis **Y** |
| **Enter** | Start · Atari Game Reset · SMS Pause |
| **Right Shift** | Select · Atari Game Select |
| **ESC** | Pause / unpause |
| **F5** / **F7** | Save state / load state |
| **Scroll Lock** | Lock / unlock keyboard to the emulator (unlocking freezes) |
| **-** / **=** / **M** | Volume down / up (10 % steps) / mute |

**Volume:** a bar under the screen (`-` `+` `Mute` buttons and a meter) or the keys above. Default 50 % (sandbox option *Default Emulator Volume*), remembered on your machine (`Zomboid/Lua/PZEMU_settings.ini`).

**Remapping:** click **Controls...** on the game list or the welcome screen. Each button has a primary and an alternate key: click a slot, press a key (ESC cancels, Backspace clears). A key used by another button is moved. **WASD preset** puts the D-pad on W/A/S/D and the face buttons on J/K (SNES also U/I, Genesis J/K/L + U/I/O), Start on Enter, Select on Right Shift; Z/X/C stay as alternates. **Reset defaults** restores the table above. Bindings are per console and saved in `Zomboid/Lua/PZEMU_keys.ini` (delete it to reset everything). ESC, F5, F7, Scroll Lock, `-`, `=` and `M` can't be bound.

**Gamepad:** supported for all consoles; plug it in and click the emulator screen. Left stick doubles as D-pad. PlayStation pads get A/B and X/Y swapped automatically so the physical layout matches. Don't bind the controller to a PZ player (the vanilla prompt) — leave PZ on keyboard/mouse and let the emulator window take the pad.

## Handheld batteries

Game Boy and Game Gear drain their batteries in **real time** while a game runs (not while paused): a full charge lasts the sandbox *Handheld Battery Life* in real minutes (default 600 = 10 real hours; 0 = never drain). When they're empty the game freezes with a **BATTERIES DEAD** screen — right-click the handheld in your inventory → **Insert Battery** (you need a Battery item; the handheld must be empty, like a flashlight) and the game resumes. **Remove Battery** gives the remaining charge back to the Battery. The hint line under the screen shows the battery %. Partial drain is stored on the handheld itself, so it accumulates across closing the emulator, saving and reloading — a set lasts about 10 hours of total play however you split it, and the % keeps moving between whole steps.

## Sandbox options ("PZEMU - Retro Consoles")

| Option | Default | Effect |
|---|---|---|
| Console Spawn Rate Multiplier | 1.0 | 0.0–5.0× how often consoles appear in loot (0 = none) |
| Cartridge Count Multiplier | 1.0 | 0.0–5.0× cartridges spawned next to a found console (3–7 base, 15 % chance of a bigger stash; **0 = none at all**, any positive value ≥ 1) |
| Default Emulator Volume | 50 | Starting volume for players who haven't set their own |
| Handheld Battery Life (real minutes) | 600 | Minutes of play per full charge (0–1440; 600 = 10 real hours); 0 = batteries never drain |
| Cartridges Sometimes Need A Blow | off | Flavour: sometimes a game won't boot until you blow on the cartridge |

## Multiplayer

Items, loot and the "Play" options work like any other mod (the server needs PZEMU in its mod list; spawning is server-side). **Emulation is client-local**: each player runs their own emulator process and sees their own frames — two people at the same TV each play their own game. Every client needs PZFB's class files installed. Not tested by the author on a dedicated server; players have reported playing in MP.

## Adding your own games

See **[GAMES.md → How to add your own games and cartridges](GAMES.md#how-to-add-your-own-games-and-cartridges)**: one line in `PZEMU_Distributions.lua` adds a game to a system's loot pool (it spawns as the generic cartridge with the name on it); three edits give it a dedicated cartridge icon. Generic-cartridge games can't be spawned from the debug item list (PZ limitation, same as home VHS tapes) — respawn a bookshelf's loot instead. `GAMES.md` is generated: run `python3 tools/gen_games_md.py` after editing the pools (`--check` tells you if it's stale).

## Building the bridge

`bridge/pzemu-bridge.c` is a single-file libretro frontend: it loads a core, pipes RGBA frames to PZFB over stdout, reads input events from stdin and plays audio through SDL2. The wire protocol is documented in the file header and in [analog.md](analog.md).

```bash
cd bridge
make                 # Linux: gcc + SDL2 dev files (pkg-config sdl2)
make windows         # x86_64-w64-mingw32-gcc + the SDL2 MinGW dev tree (see Makefile for the path)
make bmi2check       # must print 0 for both binaries (older CPUs crash on BMI2)
```

Copy the results over `mod/PZEMU/42/media/pzemu/pzemu-bridge.dat` (Linux) / `pzemu-bridge_win.dat` (Windows). Cores ship as `*_libretro.dat` / `*_libretro_win.dat` (fceumm, snes9x, genesis_plus_gx, gambatte, stella). Workshop blocks executables, hence `.dat`; the Lua copies them to `Zomboid/PZEMU/` and redeploys when the size changes.

## Credits

Console and cartridge textures and 3D models: Spicy_Apples (Video Game Consoles mod, MIT-licensed code; models used with permission), Big Al, eric1894. Emulation by the libretro cores. Everything else by SpaceJesus / expectbugs.

## License

Not yet specified — this repository currently has no license file. Until one is added, the usual default applies (all rights reserved apart from what the Workshop terms grant). Ask before redistributing modified copies.

P.S. Tested on Linux only. I don't have Windows because zombies can get through them. Windows reports are very welcome.
