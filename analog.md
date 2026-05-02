# Adding Analog Stick Support to PZEmu

Step-by-step guide to enable analog sticks (PSX, PSP, N64, etc.) in pzemu without modifying the PZFB framework. PZFB already exposes analog axis values to Lua via `onPZFBGamepadAxis`; pzemu currently throws them away by thresholding into D-pad presses. This guide forwards the real values through the existing 2-byte wire protocol to the bridge, where they're decoded and exposed to libretro's `RETRO_DEVICE_ANALOG` polls.

## Overview

Three files change. PZFB stays untouched.

| File | Why |
|---|---|
| `bridge/pzemu-bridge.c` | Decode 4 new axis-event keycodes from stdin; expose analog state to libretro; accept a per-console controller-type argument |
| `mod/PZEMU/42/media/lua/client/PZEMU/PZEMUGame.lua` | New `sendGamepadAxis()` method; pass `portDevice` to bridge; per-console `analog` and `portDevice` flags |
| `mod/PZEMU/42/media/lua/client/PZEMU/PZEMUWindow.lua` | Forward analog values for analog-capable consoles; keep D-pad emulation fallback for digital-only consoles |

## Wire protocol extension

PZFB's `gameSendInput(keycode, pressed)` writes 2 bytes: `[pressed, keycode]`. Both bytes are masked with `& 0xFF` and have no validation, so we can repurpose unused keycode values:

| Keycode | Meaning | `pressed` byte |
|---|---|---|
| 0-15 | libretro digital button (existing) | 0 = release, 1 = press |
| 16-18 | meta-commands (existing: save state, load state, pause) | 1 on press only |
| 64-67 | analog axis update (new): leftX, leftY, rightX, rightY | quantized signed value (0=full negative, 128=center, 255=full positive) |

Keycodes 19-63 and 68-255 remain unused and reserved for future use.

8-bit quantization is exact for PSX/PSP — both consoles use 8-bit analog values natively (DualShock and PSP analog stick), so no precision is lost relative to the original hardware.

---

## Step 1 — Bridge: add analog state and port-device variable

Open `~/pzemu/bridge/pzemu-bridge.c`.

**1a.** Right after the `g_buttons` declaration (around line 80), add:

```c
/* analog stick state — 4 axes (leftX, leftY, rightX, rightY) in libretro int16 range */
static int16_t g_analog[4] = {0};
```

**1b.** Right after the `META_PAUSE` define (around line 131), add axis IDs:

```c
/* analog axis events (wire keycodes 64..67, value packed in `pressed` byte) */
#define AXIS_BASE      64
#define AXIS_LEFT_X     0
#define AXIS_LEFT_Y     1
#define AXIS_RIGHT_X    2
#define AXIS_RIGHT_Y    3
```

**1c.** Near the other globals (e.g. right after `g_save_dir` around line 95), add:

```c
/* libretro controller type for port 0 — set from CLI arg 7, default = digital JOYPAD.
 * Different cores expect different values. See analog.md for the table. */
static unsigned g_port_device = RETRO_DEVICE_JOYPAD;
```

---

## Step 2 — Bridge: decode axis events from stdin

Replace the entire `handle_key_event` function (around line 330) with:

```c
static void handle_key_event(uint8_t pressed, uint8_t keycode) {
    if (keycode < 16) {
        g_buttons[keycode] = pressed ? 1 : 0;
        return;
    }

    /* analog axis update: keycode 64..67, value packed in `pressed` (128 = center) */
    if (keycode >= AXIS_BASE && keycode <= AXIS_BASE + 3) {
        unsigned axis = keycode - AXIS_BASE;
        int s = (int)pressed - 128;          /* -128..+127 */
        g_analog[axis] = (int16_t)(s * 256); /* -32768..+32512 */
        return;
    }

    /* meta-commands — trigger on press only */
    if (pressed) {
        switch (keycode) {
        case META_SAVE_STATE: do_save_state(); break;
        case META_LOAD_STATE: do_load_state(); break;
        case META_PAUSE:
            g_paused = !g_paused;
            if (g_audio_dev)
                SDL_PauseAudioDevice(g_audio_dev, g_paused ? 1 : 0);
            fprintf(stderr, "[pzemu] %s\n", g_paused ? "Paused" : "Resumed");
            break;
        default: break;
        }
    }
}
```

---

## Step 3 — Bridge: expose analog to libretro

Replace the entire `input_state_cb` function (around line 400) with:

```c
static int16_t RETRO_CALLCONV input_state_cb(unsigned port, unsigned device,
                                              unsigned index, unsigned id)
{
    if (port != 0) return 0;

    unsigned dev = device & RETRO_DEVICE_MASK;

    /* digital joypad polls — used by both RETRO_DEVICE_JOYPAD and RETRO_DEVICE_ANALOG cores */
    if (dev == RETRO_DEVICE_JOYPAD && index == 0) {
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) {
            int16_t mask = 0;
            for (int i = 0; i < 16; i++)
                if (g_buttons[i]) mask |= (1 << i);
            return mask;
        }
        if (id < 16) return g_buttons[id];
        return 0;
    }

    /* analog axis polls */
    if (dev == RETRO_DEVICE_ANALOG) {
        if (index == RETRO_DEVICE_INDEX_ANALOG_LEFT) {
            if (id == RETRO_DEVICE_ID_ANALOG_X) return g_analog[AXIS_LEFT_X];
            if (id == RETRO_DEVICE_ID_ANALOG_Y) return g_analog[AXIS_LEFT_Y];
        } else if (index == RETRO_DEVICE_INDEX_ANALOG_RIGHT) {
            if (id == RETRO_DEVICE_ID_ANALOG_X) return g_analog[AXIS_RIGHT_X];
            if (id == RETRO_DEVICE_ID_ANALOG_Y) return g_analog[AXIS_RIGHT_Y];
        } else if (index == RETRO_DEVICE_INDEX_ANALOG_BUTTON) {
            /* analog-button pressure poll (e.g. shoulder triggers as analog) —
             * we have no analog source for these, so report digital state scaled */
            if (id < 16 && g_buttons[id]) return 0x7FFF;
            return 0;
        }
    }

    return 0;
}
```

---

## Step 4 — Bridge: read port device from CLI and use it

In `main()` (around line 602):

**4a.** Update the usage string at line 604:

```c
fprintf(stderr, "Usage: pzemu-bridge <core> <rom> <width> <height> [sys_dir] [save_dir] [port_device]\n");
```

**4b.** After the `g_save_dir` assignment (around line 613), add:

```c
if (argc > 7) g_port_device = (unsigned)atoi(argv[7]);
```

**4c.** Replace line 746:

```c
p_retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD);
```

with:

```c
p_retro_set_controller_port_device(0, g_port_device);
fprintf(stderr, "[pzemu] Controller port device: %u\n", g_port_device);
```

The log line surfaces the active value to bridge stderr — useful when a core silently rejects an unsupported value. Watch for `"Unsupported Device"` warnings from the core in the same log stream.

---

## Step 5 — Rebuild the bridge

```bash
cd ~/pzemu/bridge
make clean
make
```

Confirm `pzemu-bridge` exists and is newly built. Windows users running the bridge under wine should rebuild `pzemu-bridge.exe` per their cross-compile setup.

---

## Step 6 — Lua: add `sendGamepadAxis` to PZEMUGame

Open `~/pzemu/mod/PZEMU/42/media/lua/client/PZEMU/PZEMUGame.lua`.

Right after `sendGamepadButton` (around line 494), add:

```lua
-- Forward an analog stick value to the bridge.
-- axisId: 0=leftX, 1=leftY, 2=rightX, 3=rightY.
-- value: float in [-1.0, 1.0]. Quantized to 8 bits (128 = center) and packed into the
-- existing 2-byte protocol with keycode = 64 + axisId.
function PZEMUGame:sendGamepadAxis(axisId, value)
    if self.state ~= "RUNNING" and self.state ~= "STARTING" then return end
    if value < -1.0 then value = -1.0 elseif value > 1.0 then value = 1.0 end
    local q = math.floor((value + 1.0) * 127.5 + 0.5)
    if q < 0 then q = 0 elseif q > 255 then q = 255 end
    PZFB.gameSendInput(64 + axisId, q)
end
```

---

## Step 7 — Lua: pass `portDevice` to the bridge

In `PZEMUGame.lua`'s `start()` function, locate the `argv` table (around line 528) and append the optional `portDevice` argument:

```lua
local argv = {
    self.corePath,
    romPath,
    tostring(w),
    tostring(h),
    saveDir,
    saveDir,
}
if self.console.portDevice then
    table.insert(argv, tostring(self.console.portDevice))
end
```

The bridge defaults to 1 (`RETRO_DEVICE_JOYPAD`) when no 7th argument is passed, so digital-only consoles need no changes.

---

## Step 8 — Lua: replace the analog handler in PZEMUWindow

Open `~/pzemu/mod/PZEMU/42/media/lua/client/PZEMU/PZEMUWindow.lua`.

Replace the block from line 250 (`-- Analog stick -> D-pad conversion...`) through the end of `onPZFBGamepadAxis` (around line 281) with:

```lua
-- Analog forwarding for analog-capable consoles; D-pad emulation fallback otherwise
local STICK_DEADZONE = 0.5
local AXIS_NAME_TO_ID = { leftX = 0, leftY = 1, rightX = 2, rightY = 3 }
local stickState = { left = 0, right = 0, up = 0, down = 0 }

function PZEMUGamePanel:onPZFBGamepadAxis(slot, name, value)
    if not self.game then return end

    -- Console supports analog (e.g. PSX/PSP): forward the raw axis value
    if self.game.console and self.game.console.analog then
        local axisId = AXIS_NAME_TO_ID[name]
        if axisId then
            self.game:sendGamepadAxis(axisId, value)
        end
        return
    end

    -- Digital-only consoles: emulate D-pad from left stick (existing behavior preserved)
    if name == "leftX" then
        local wasLeft, wasRight = stickState.left, stickState.right
        stickState.left  = (value < -STICK_DEADZONE) and 1 or 0
        stickState.right = (value >  STICK_DEADZONE) and 1 or 0
        if stickState.left ~= wasLeft then
            self.game:sendGamepadButton(Joypad.DPadLeft, stickState.left)
        end
        if stickState.right ~= wasRight then
            self.game:sendGamepadButton(Joypad.DPadRight, stickState.right)
        end
    elseif name == "leftY" then
        local wasUp, wasDown = stickState.up, stickState.down
        stickState.up   = (value < -STICK_DEADZONE) and 1 or 0
        stickState.down = (value >  STICK_DEADZONE) and 1 or 0
        if stickState.up ~= wasUp then
            self.game:sendGamepadButton(Joypad.DPadUp, stickState.up)
        end
        if stickState.down ~= wasDown then
            self.game:sendGamepadButton(Joypad.DPadDown, stickState.down)
        end
    end
end
```

---

## Step 9 — Mark analog-capable consoles in `CONSOLES`

For each console entry in `PZEMUGame.lua` that should use real analog, add two fields:

- `analog = true` — tells PZEMUWindow to forward axis values instead of emulating D-pad.
- `portDevice = <N>` — tells the bridge which libretro controller type to request.

**The right `portDevice` value depends on the core**, because cores define their own controller-type constants. Use this table:

| Core | Console | `portDevice` | What it selects |
|---|---|---|---|
| `mednafen_psx_libretro` (Beetle PSX) | PSX | **517** | DualShock (analog + rumble) — recommended |
| `mednafen_psx_libretro` | PSX | 261 | Analog Controller (analog, no rumble) |
| `swanstation_libretro` | PSX | **261** | DualShock |
| `ppsspp_libretro` | PSP | (omit) | Stub function — value ignored, leave default 1 |
| `mupen64plus_next_libretro` | N64 | 1 | N64 controller is its own thing; default JOYPAD works |
| `parallel_n64_libretro` | N64 | 1 | Same as above |

If you use a different core or are unsure of the right value, check that core's `retro_set_controller_port_device` implementation in its source. The constants are usually defined near the top of the input file as `RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG, N)`. Pick the one whose log message matches what you want (e.g. `"Controller %u: DualShock"`).

Example console entry for PSX with Beetle:

```lua
{
    id            = "psx",
    displayName   = "PlayStation",
    year          = 1994,
    width         = 320,
    height        = 240,
    coreFile      = "mednafen_psx_libretro",
    coreDat       = "mednafen_psx_libretro.dat",
    romDir        = "psx",
    romExtensions = { ".cue", ".chd", ".pbp", ".m3u" },
    analog        = true,    -- enable analog stick forwarding
    portDevice    = 517,     -- DualShock (Beetle PSX)
    keyMap        = buildKeyMap(PSX_BUTTONS),  -- you must define PSX_BUTTONS
    gamepadMap    = GAMEPAD_PSX,                -- you must define GAMEPAD_PSX
    controlHints  = {
        "Left stick   =  Movement",
        "Right stick  =  Camera",
        "(buttons depend on your gamepad map)",
    },
},
```

Existing entries (NES, SNES, Genesis, etc.) need no changes — without the `analog` and `portDevice` flags, behavior is identical to before.

---

## Step 10 — Add a PSX/PSP console entry (if not already present)

The framework changes above are complete, but PSX/PSP aren't in pzemu's default `CONSOLES` list. To actually test:

1. **Get a core:** drop a libretro core into pzemu's cores directory. Beetle PSX HW (`mednafen_psx_hw_libretro.so`), Swanstation (`swanstation_libretro.so`), or PPSSPP (`ppsspp_libretro.so`) are the common choices.
2. **BIOS files (PSX only):** Beetle PSX and Swanstation require PSX BIOS files (`scph5500.bin`, `scph5501.bin`, `scph5502.bin` — one per region) placed in `~/Zomboid/saves/psx/` (or wherever your `saveDir` resolves to — the bridge passes the same path as `system_dir`). Without them, the core errors at load.
3. **Add a console entry** with the correct `coreFile`, dimensions, ROM extensions, `keyMap`, `gamepadMap`, `analog = true`, and `portDevice`.
4. **Define `PSX_BUTTONS` and `GAMEPAD_PSX`** mapping PSX buttons (Cross, Circle, Square, Triangle, L1, L2, R1, R2, Start, Select, L3, R3) to `RETRO_DEVICE_ID_JOYPAD_*` constants. Reference `input.cpp:266-285` of beetle-psx for the canonical PSX → libretro button mapping.

Full console-entry design is its own task; the framework changes in Steps 1-9 are what enables it.

---

## Step 11 — Test

1. Restart Project Zomboid (Lua mod reload picks up the `.lua` changes; the bridge binary is loaded fresh on each `gameStart`).
2. **Regression check first:** launch a digital-only console (NES). Verify the left stick still moves the character via D-pad emulation. If this breaks, the digital fallback in Step 8 has a bug.
3. **Analog check:** launch an analog-capable console with a controller. Move the sticks slowly and verify proportional response, not just on/off at deadzone thresholds. Check the bridge stderr log for `[pzemu] Controller port device: <N>` showing the value you passed, with no `"Unsupported Device"` warning following it.
4. If the core has a built-in input test menu, use it. Beetle PSX shows analog values in real time when you hold a stick.

---

## Troubleshooting

**Bridge stderr shows `"Unsupported Device"` followed by no input working**
The `portDevice` value isn't recognized by the core. Use 517 for Beetle PSX, 261 for Swanstation. Plain `5` (`RETRO_DEVICE_ANALOG`) does not work for either — both cores require their own subclass constants.

**Beetle PSX analog sticks don't move in-game even with `portDevice = 517`**
Check the core option `beetle_psx_analog_toggle`. It must be at its **default (disabled)**, which the docs describe as "the DualShock input device will be locked in Analog Mode where the analog sticks are on." If a previous user enabled this option, the controller boots in digital mode and requires Start+Select+L1+L2+R1+R2 held for one second to switch — disable the option to remove that requirement.

**Beetle PSX old/worn sticks don't reach extremes**
Enable core option `beetle_psx_analog_calibration`. It auto-scales analog coordinates based on observed maximums.

**PPSSPP analog feels too sensitive or has a deadband**
Adjust core options `Analog Deadzone` and `Analog Axis Scale` under the Input section. PPSSPP's `retro_set_controller_port_device` is a no-op stub, so `portDevice` doesn't affect it — leave it unset (defaults to 1).

**PPSSPP only responds to the left stick**
Correct — the PSP only has one analog stick (left). PPSSPP polls `RETRO_DEVICE_INDEX_ANALOG_LEFT` exclusively. The right stick won't do anything in PSP games.

**Digital buttons stop working after the change**
Most likely a typo in `input_state_cb`. The `if (dev == RETRO_DEVICE_JOYPAD && index == 0)` branch must still return `g_buttons[id]` for `id < 16` exactly as before. The only intended change in that branch is replacing the early `return 0` for non-JOYPAD calls with the new analog branches below.

**Wrong stick axis (X swapped with Y, or sticks flipped)**
The wire-keycode → axis mapping must agree on both sides:
- Bridge (Step 1b): `AXIS_LEFT_X=0`, `AXIS_LEFT_Y=1`, `AXIS_RIGHT_X=2`, `AXIS_RIGHT_Y=3`
- Lua (Step 8): `AXIS_NAME_TO_ID = { leftX=0, leftY=1, rightX=2, rightY=3 }`

PZFB's axis names are `leftX/leftY/rightX/rightY` (verified against `PZFBInput.lua:450-453`). If your controller reports inverted Y (some pads do), invert in the Lua side: `value = -value` before calling `sendGamepadAxis`.

**Bridge logs `Unsupported Device (5)` specifically**
You set `portDevice = 5` somewhere. That's the plain `RETRO_DEVICE_ANALOG` value, which most PSX cores reject in favor of their subclass constants. Use the table in Step 9.

---

## Why this works without modifying PZFB

`PZFB.gameSendInput(keycode, pressed)` writes `pressed & 0xFF` then `keycode & 0xFF` to the bridge's stdin with no validation (`Color.java:1900-1912`). Both ends — PZFB's Java method and the bridge's `handle_key_event(uint8_t pressed, uint8_t keycode)` — are byte-transparent. Only the *interpretation* of certain byte combinations changes, and that interpretation lives entirely in pzemu's own bridge C and Lua code, both of which the user controls.

The wire is also forward-compatible: future protocol extensions (analog triggers, pressure-sensitive buttons, etc.) can claim more unused keycodes without touching PZFB.

---

## Verified facts

This guide was checked against:

- `~/pzemu/bridge/pzemu-bridge.c` — current line numbers and code structure
- `~/pzemu/bridge/libretro.h` — all constants used
- `~/pzemu/mod/PZEMU/42/media/lua/client/PZEMU/PZEMUGame.lua` — current state of `argv`, `start()`, `sendGamepadButton`
- `~/pzemu/mod/PZEMU/42/media/lua/client/PZEMU/PZEMUWindow.lua` — current `onPZFBGamepadAxis` block
- `~/pzfb/java/zombie/core/Color.java` — `fbGameSendInput` byte-transparency
- `~/pzfb/mod/PZFB/42/media/lua/client/PZFB/PZFBInput.lua` — axis names and PZFB callback contract
- libretro/beetle-psx-libretro `input.cpp` — verified subclass constants (PS_DUALSHOCK=517, PS_ANALOG=261) and the `default:` case behavior that rejects unrecognized device values
- PPSSPP `libretro.cpp` — verified `retro_set_controller_port_device` is a no-op stub
- libretro forum thread on Swanstation — verified `261` is the correct DualShock value for that core
- Beetle PSX core options docs — verified `analog_toggle` default behavior and `analog_calibration` purpose
- PPSSPP core options docs — verified `Analog Deadzone` and `Analog Axis Scale` options exist
