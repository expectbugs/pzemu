--
-- PZEMUGame.lua — Multi-console process management, key translation, sessions
--
-- Manages the pzemu-bridge process via PZFB's game process API.
-- Console-specific configuration (resolution, core, buttons/key map) is driven by
-- a CONSOLES table. The bridge binary is fully generic — this file provides the
-- per-console knowledge.
--
-- PZFB compatibility (contract C1/C2/C5): every new PZFB 1.8 function is used
-- behind a feature check, so this file works unchanged with PZFB 1.7.x Lua and
-- with 1.8 Lua on top of 1.7 class files (PZFB.hasSessions() == false).
--
-- Third-party note: "Literally Playable Video Game Consoles" ships its own
-- PZEMUMain.lua / PZEMU_Distributions.lua and hooks PZEMUGame:new(console),
-- PZEMUGame.getConsoles(), PZEMUGame.getConsoleById(), game:stop(), game:update()
-- and reads game.state / game.console / game.fb. That mod is NOT supported
-- (Adam, 2026-10-15): there is no obligation to keep those hooks working, though
-- there is no reason to break them on purpose either. Not depending on
-- PZEMUMain.lua / PZEMU_Distributions.lua from here stays good design regardless.
--

require "PZFB/PZFBApi"
require "PZEMU/PZEMUSettings"
require "PZEMU/PZEMUBindings"

PZEMUGame = {}
PZEMUGame.__index = PZEMUGame

-- ---------- platform helpers ----------

local function isWindows()
    return getFileSeparator() == "\\"
end

local function getUserDir()
    return Core.getMyDocumentFolder() .. getFileSeparator() .. "PZEMU"
end

-- ---------- bridge wire protocol (matches bridge/pzemu-bridge.c, contract C4) ----------
-- Wire bytes are [value, keycode]; PZFB.gameSendInput(keycode, value).

PZEMUGame.META_SAVE_STATE   = 16
PZEMUGame.META_LOAD_STATE   = 17
PZEMUGame.META_PAUSE_TOGGLE = 18   -- legacy toggle (ESC)
PZEMUGame.META_PAUSE_ON     = 19   -- idempotent, value ~= 0
PZEMUGame.META_PAUSE_OFF    = 20   -- idempotent, value ~= 0
PZEMUGame.META_QUIT         = 21   -- flush SRAM + exit cleanly, value ~= 0
PZEMUGame.META_VOLUME       = 68   -- value 0..255 = linear gain, 0 = mute

-- Deferred stop (only used when PZFB class files are pre-1.8 and would SIGKILL
-- the bridge immediately, losing the SRAM flush triggered by QUIT).
PZEMUGame.LEGACY_STOP_DELAY_MS = 1000

-- ---------- shared meta-commands (same for all consoles) ----------

local META_KEYS = {}
META_KEYS[Keyboard.KEY_ESCAPE] = PZEMUGame.META_PAUSE_TOGGLE  -- Freeze/unfreeze emulation
META_KEYS[Keyboard.KEY_F5]     = PZEMUGame.META_SAVE_STATE    -- Save state
META_KEYS[Keyboard.KEY_F7]     = PZEMUGame.META_LOAD_STATE    -- Load state

-- ---------- button definitions ----------
-- Each console lists its buttons in display order:
--   { id = <libretro RETRO_DEVICE_ID_JOYPAD_*>, label = "...", keys = { default LWJGL keys } }
-- The default key map is derived from these; user remaps (PZEMUBindings) override them.

local K = Keyboard

local function B(id, label, k1, k2)
    local keys = {}
    if k1 then table.insert(keys, k1) end
    if k2 then table.insert(keys, k2) end
    return { id = id, label = label, keys = keys }
end

local function concatLists(...)
    local out = {}
    for _, list in ipairs({ ... }) do
        for _, v in ipairs(list) do table.insert(out, v) end
    end
    return out
end

local function dpad(labelPrefix)
    labelPrefix = labelPrefix or "D-pad"
    return {
        B(4, labelPrefix .. " Up",    K.KEY_UP),
        B(5, labelPrefix .. " Down",  K.KEY_DOWN),
        B(6, labelPrefix .. " Left",  K.KEY_LEFT),
        B(7, labelPrefix .. " Right", K.KEY_RIGHT),
    }
end

-- NES / Game Boy: D-pad, B, A, Select, Start
local NES_BUTTON_DEFS = concatLists(dpad(), {
    B(0, "B",      K.KEY_Z, K.KEY_A),   -- A/S alternates avoid ghosting with arrows
    B(8, "A",      K.KEY_X, K.KEY_S),
    B(2, "Select", K.KEY_RSHIFT),
    B(3, "Start",  K.KEY_RETURN),
})

-- SNES: adds Y, X, L, R
local SNES_BUTTON_DEFS = concatLists(dpad(), {
    B(0,  "B",          K.KEY_Z, K.KEY_A),
    B(8,  "A",          K.KEY_X, K.KEY_S),
    B(1,  "Y",          K.KEY_C, K.KEY_D),
    B(9,  "X",          K.KEY_V, K.KEY_F),
    B(10, "L shoulder", K.KEY_Q),
    B(11, "R shoulder", K.KEY_E),
    B(2,  "Select",     K.KEY_RSHIFT),
    B(3,  "Start",      K.KEY_RETURN),
})

-- Genesis 6-button: libretro maps Genesis A=Y(1), B=B(0), C=A(8), X=L(10), Y=X(9), Z=R(11)
local GENESIS_BUTTON_DEFS = concatLists(dpad(), {
    B(1,  "A",     K.KEY_Z, K.KEY_A),
    B(0,  "B",     K.KEY_X, K.KEY_S),
    B(8,  "C",     K.KEY_C, K.KEY_D),
    B(10, "X",     K.KEY_Q),
    B(9,  "Y",     K.KEY_W),
    B(11, "Z",     K.KEY_E),
    B(3,  "Start", K.KEY_RETURN),
})

-- Atari 2600: joystick, fire, select, reset
local ATARI2600_BUTTON_DEFS = concatLists(dpad("Joystick"), {
    B(0, "Fire",        K.KEY_Z, K.KEY_A),
    B(8, "Fire 2",      K.KEY_X, K.KEY_S),   -- paddle / second button games
    B(2, "Game Select", K.KEY_RSHIFT),
    B(3, "Game Reset",  K.KEY_RETURN),
})

-- Game Gear: 1, 2, Start
local GG_BUTTON_DEFS = concatLists(dpad(), {
    B(0, "Button 1", K.KEY_Z, K.KEY_A),
    B(8, "Button 2", K.KEY_X, K.KEY_S),
    B(3, "Start",    K.KEY_RETURN),
})

-- Master System: 1, 2, Pause
local SMS_BUTTON_DEFS = concatLists(dpad(), {
    B(0, "Button 1", K.KEY_Z, K.KEY_A),
    B(8, "Button 2", K.KEY_X, K.KEY_S),
    B(3, "Pause",    K.KEY_RETURN),
})

-- WASD presets (see PZEMUBindings.PRESET_WASD_DESCRIPTION). Buttons not listed
-- keep their defaults minus any key the preset claims.
local WASD_DPAD = {
    [4] = { K.KEY_W }, [5] = { K.KEY_S }, [6] = { K.KEY_A }, [7] = { K.KEY_D },
}

local function withDpad(extra)
    local out = {}
    for id, keys in pairs(WASD_DPAD) do out[id] = keys end
    for id, keys in pairs(extra) do out[id] = keys end
    return out
end

local PRESETS_NES = { wasd = withDpad({
    [0] = { K.KEY_J, K.KEY_Z }, [8] = { K.KEY_K, K.KEY_X },
    [2] = { K.KEY_RSHIFT }, [3] = { K.KEY_RETURN },
}) }
local PRESETS_SNES = { wasd = withDpad({
    [0] = { K.KEY_J, K.KEY_Z }, [8] = { K.KEY_K, K.KEY_X },
    [1] = { K.KEY_U, K.KEY_C }, [9] = { K.KEY_I, K.KEY_V },
    [10] = { K.KEY_Q }, [11] = { K.KEY_E },
    [2] = { K.KEY_RSHIFT }, [3] = { K.KEY_RETURN },
}) }
local PRESETS_GENESIS = { wasd = withDpad({
    [1] = { K.KEY_J, K.KEY_Z }, [0] = { K.KEY_K, K.KEY_X }, [8] = { K.KEY_L, K.KEY_C },
    [10] = { K.KEY_U }, [9] = { K.KEY_I }, [11] = { K.KEY_O },
    [3] = { K.KEY_RETURN },
}) }
local PRESETS_ATARI = { wasd = withDpad({
    [0] = { K.KEY_J, K.KEY_Z }, [8] = { K.KEY_K, K.KEY_X },
    [2] = { K.KEY_RSHIFT }, [3] = { K.KEY_RETURN },
}) }
local PRESETS_GG = { wasd = withDpad({
    [0] = { K.KEY_J, K.KEY_Z }, [8] = { K.KEY_K, K.KEY_X }, [3] = { K.KEY_RETURN },
}) }

-- Derive the default key map (LWJGL key -> libretro button) + meta keys.
local function buildKeyMap(buttonDefs)
    local map = {}
    for _, b in ipairs(buttonDefs) do
        for _, key in ipairs(b.keys) do map[key] = b.id end
    end
    for k, v in pairs(META_KEYS) do map[k] = v end
    return map
end

-- ---------- gamepad map: Joypad.* constants → libretro button IDs ----------
-- The RetroPad layout matches SNES, so the mapping is nearly 1:1.
-- Per-console maps only include buttons that console actually has.

local GAMEPAD_FULL = {}
GAMEPAD_FULL[Joypad.BButton]   = 0   -- B (south face)
GAMEPAD_FULL[Joypad.YButton]   = 1   -- Y (west face)
GAMEPAD_FULL[Joypad.Back]      = 2   -- SELECT / Back
GAMEPAD_FULL[Joypad.Start]     = 3   -- START
GAMEPAD_FULL[Joypad.DPadUp]    = 4
GAMEPAD_FULL[Joypad.DPadDown]  = 5
GAMEPAD_FULL[Joypad.DPadLeft]  = 6
GAMEPAD_FULL[Joypad.DPadRight] = 7
GAMEPAD_FULL[Joypad.AButton]   = 8   -- A (east face)
GAMEPAD_FULL[Joypad.XButton]   = 9   -- X (north face)
GAMEPAD_FULL[Joypad.LBumper]   = 10  -- L shoulder
GAMEPAD_FULL[Joypad.RBumper]   = 11  -- R shoulder

-- NES/GB gamepad: B, A, Select, Start, D-pad (no Y/X/L/R)
local GAMEPAD_NES = {}
GAMEPAD_NES[Joypad.BButton]   = 0   -- B
GAMEPAD_NES[Joypad.AButton]   = 8   -- A
GAMEPAD_NES[Joypad.Back]      = 2   -- SELECT
GAMEPAD_NES[Joypad.Start]     = 3   -- START
GAMEPAD_NES[Joypad.DPadUp]    = 4
GAMEPAD_NES[Joypad.DPadDown]  = 5
GAMEPAD_NES[Joypad.DPadLeft]  = 6
GAMEPAD_NES[Joypad.DPadRight] = 7

-- SNES gamepad: full RetroPad (same as GAMEPAD_FULL)
local GAMEPAD_SNES = GAMEPAD_FULL

-- Genesis gamepad: A/B/C + X/Y/Z (6-button) mapped through libretro's SNES layout
-- Genesis A=Y(1), B=B(0), C=A(8), X=L(10), Y=X(9), Z=R(11)
local GAMEPAD_GENESIS = {}
GAMEPAD_GENESIS[Joypad.YButton]   = 1   -- Genesis A (libretro Y / west face)
GAMEPAD_GENESIS[Joypad.BButton]   = 0   -- Genesis B (libretro B / south face)
GAMEPAD_GENESIS[Joypad.AButton]   = 8   -- Genesis C (libretro A / east face)
GAMEPAD_GENESIS[Joypad.LBumper]   = 10  -- Genesis X (libretro L)
GAMEPAD_GENESIS[Joypad.XButton]   = 9   -- Genesis Y (libretro X / north face)
GAMEPAD_GENESIS[Joypad.RBumper]   = 11  -- Genesis Z (libretro R)
GAMEPAD_GENESIS[Joypad.Start]     = 3   -- START
GAMEPAD_GENESIS[Joypad.DPadUp]    = 4
GAMEPAD_GENESIS[Joypad.DPadDown]  = 5
GAMEPAD_GENESIS[Joypad.DPadLeft]  = 6
GAMEPAD_GENESIS[Joypad.DPadRight] = 7

-- Atari 2600 gamepad: fire + D-pad + select/reset
local GAMEPAD_ATARI2600 = {}
GAMEPAD_ATARI2600[Joypad.AButton]   = 0   -- Fire
GAMEPAD_ATARI2600[Joypad.BButton]   = 0   -- Fire (alt)
GAMEPAD_ATARI2600[Joypad.Back]      = 2   -- Game Select
GAMEPAD_ATARI2600[Joypad.Start]     = 3   -- Game Reset
GAMEPAD_ATARI2600[Joypad.DPadUp]    = 4
GAMEPAD_ATARI2600[Joypad.DPadDown]  = 5
GAMEPAD_ATARI2600[Joypad.DPadLeft]  = 6
GAMEPAD_ATARI2600[Joypad.DPadRight] = 7

-- Game Gear / Master System: 1, 2, Start + D-pad
local GAMEPAD_GG = {}
GAMEPAD_GG[Joypad.BButton]   = 0   -- Button 1
GAMEPAD_GG[Joypad.AButton]   = 8   -- Button 2
GAMEPAD_GG[Joypad.Start]     = 3   -- START
GAMEPAD_GG[Joypad.DPadUp]    = 4
GAMEPAD_GG[Joypad.DPadDown]  = 5
GAMEPAD_GG[Joypad.DPadLeft]  = 6
GAMEPAD_GG[Joypad.DPadRight] = 7

local GAMEPAD_SMS = GAMEPAD_GG

-- ---------- console specifications ----------
-- Resolutions verified against actual core output via standalone bridge testing.
-- The bridge outputs at these fixed dimensions; if the core's frame is smaller
-- (e.g. Genesis starts 256x192), the bridge centers and pads with black.
-- `keyMap` is the DEFAULT map (kept for compatibility); the effective map with
-- user remaps is computed per game instance via PZEMUBindings.keyMapFor().
-- `handheld` consoles have their own screen and run on batteries.

local CONSOLES = {
    {
        id            = "nes",
        displayName   = "NES",
        year          = 1985,
        width         = 256,
        height        = 224,
        coreFile      = "fceumm_libretro",
        coreDat       = "fceumm_libretro.dat",
        romDir        = "nes",
        romExtensions = { ".nes" },
        buttons       = NES_BUTTON_DEFS,
        presets       = PRESETS_NES,
        keyMap        = buildKeyMap(NES_BUTTON_DEFS),
        gamepadMap    = GAMEPAD_NES,
        controlHints  = {
            "Arrows  =  D-pad",
            "Z or A  =  B button",
            "X or S  =  A button",
            "Enter  =  Start",
            "Right Shift  =  Select",
        },
    },
    {
        id            = "snes",
        displayName   = "SNES",
        year          = 1991,
        width         = 256,
        height        = 224,
        coreFile      = "snes9x_libretro",
        coreDat       = "snes9x_libretro.dat",
        romDir        = "snes",
        romExtensions = { ".smc", ".sfc" },
        buttons       = SNES_BUTTON_DEFS,
        presets       = PRESETS_SNES,
        keyMap        = buildKeyMap(SNES_BUTTON_DEFS),
        gamepadMap    = GAMEPAD_SNES,
        controlHints  = {
            "Arrows  =  D-pad",
            "Z or A  =  B       X or S  =  A",
            "C or D  =  Y       V or F  =  X",
            "Q  =  L shoulder   E  =  R shoulder",
            "Enter  =  Start    RShift  =  Select",
        },
    },
    {
        id            = "genesis",
        displayName   = "Sega Genesis",
        year          = 1989,
        width         = 320,
        height        = 224,
        coreFile      = "genesis_plus_gx_libretro",
        coreDat       = "genesis_plus_gx_libretro.dat",
        romDir        = "genesis",
        romExtensions = { ".md", ".gen", ".bin", ".smd" },
        buttons       = GENESIS_BUTTON_DEFS,
        presets       = PRESETS_GENESIS,
        keyMap        = buildKeyMap(GENESIS_BUTTON_DEFS),
        gamepadMap    = GAMEPAD_GENESIS,
        controlHints  = {
            "Arrows  =  D-pad",
            "Z or A  =  A       X or S  =  B       C or D  =  C",
            "Q  =  X   W  =  Y   E  =  Z  (6-button)",
            "Enter  =  Start",
        },
    },
    {
        id            = "gb",
        displayName   = "Game Boy",
        year          = 1989,
        width         = 160,
        height        = 144,
        coreFile      = "gambatte_libretro",
        coreDat       = "gambatte_libretro.dat",
        romDir        = "gb",
        romExtensions = { ".gb" },
        handheld      = true,
        buttons       = NES_BUTTON_DEFS,
        presets       = PRESETS_NES,
        keyMap        = buildKeyMap(NES_BUTTON_DEFS),
        gamepadMap    = GAMEPAD_NES,
        controlHints  = {
            "Arrows  =  D-pad",
            "Z or A  =  B button",
            "X or S  =  A button",
            "Enter  =  Start",
            "Right Shift  =  Select",
        },
    },
    {
        id            = "atari2600",
        displayName   = "Atari 2600",
        year          = 1977,
        width         = 320,
        height        = 228,
        coreFile      = "stella_libretro",
        coreDat       = "stella_libretro.dat",
        romDir        = "atari2600",
        romExtensions = { ".a26", ".bin" },
        buttons       = ATARI2600_BUTTON_DEFS,
        presets       = PRESETS_ATARI,
        keyMap        = buildKeyMap(ATARI2600_BUTTON_DEFS),
        gamepadMap    = GAMEPAD_ATARI2600,
        controlHints  = {
            "Arrows  =  Joystick",
            "Z or A  =  Fire",
            "Enter  =  Game Reset",
            "Right Shift  =  Game Select",
        },
    },
    {
        id            = "gg",
        displayName   = "Game Gear",
        year          = 1991,
        width         = 160,
        height        = 144,
        coreFile      = "genesis_plus_gx_libretro",
        coreDat       = "genesis_plus_gx_libretro.dat",
        romDir        = "gg",
        romExtensions = { ".gg" },
        handheld      = true,
        buttons       = GG_BUTTON_DEFS,
        presets       = PRESETS_GG,
        keyMap        = buildKeyMap(GG_BUTTON_DEFS),
        gamepadMap    = GAMEPAD_GG,
        controlHints  = {
            "Arrows  =  D-pad",
            "Z or A  =  Button 1",
            "X or S  =  Button 2",
            "Enter  =  Start",
        },
    },
    {
        id            = "sms",
        displayName   = "Master System",
        year          = 1986,
        width         = 256,
        height        = 192,
        coreFile      = "genesis_plus_gx_libretro",
        coreDat       = "genesis_plus_gx_libretro.dat",
        romDir        = "sms",
        romExtensions = { ".sms" },
        buttons       = SMS_BUTTON_DEFS,
        presets       = PRESETS_GG,
        keyMap        = buildKeyMap(SMS_BUTTON_DEFS),
        gamepadMap    = GAMEPAD_SMS,
        controlHints  = {
            "Arrows  =  D-pad",
            "Z or A  =  Button 1",
            "X or S  =  Button 2",
            "Enter  =  Pause",
        },
    },
}

-- Let the bindings module validate saved remaps against these definitions.
if PZEMUBindings and PZEMUBindings.registerConsoles then
    PZEMUBindings.registerConsoles(CONSOLES)
end

-- ---------- .dat file path resolution (handles Workshop vs local) ----------

local function findModDat(filename)
    local sep = getFileSeparator()
    local modInfo = getModInfoByID("PZEMU")
    if not modInfo then return nil end

    local dir = modInfo:getDir()
    if dir then
        local p = dir .. sep .. "media" .. sep .. "pzemu" .. sep .. filename
        if PZFB.fileSize(p) > 0 then return p end
        p = dir .. sep .. "42" .. sep .. "media" .. sep .. "pzemu" .. sep .. filename
        if PZFB.fileSize(p) > 0 then return p end
    end

    local ok, vdir = pcall(function() return modInfo:getVersionDir() end)
    if ok and vdir then
        local p = vdir .. sep .. "media" .. sep .. "pzemu" .. sep .. filename
        if PZFB.fileSize(p) > 0 then return p end
    end
    return nil
end

-- ---------- binary deployment (platform-aware, follows PZDOOM pattern) ----------

local function deployBinaries()
    local sep = getFileSeparator()
    local destDir = getUserDir()

    -- Deploy bridge binary + SDL2 (Windows needs SDL2.dll)
    local files
    if isWindows() then
        files = {
            { dat = "pzemu-bridge_win.dat", dest = "pzemu-bridge.exe" },
            { dat = "SDL2.dat",             dest = "SDL2.dll" },
        }
    else
        files = {
            { dat = "pzemu-bridge.dat", dest = "pzemu-bridge" },
        }
    end

    -- Redeploy when destination is missing OR size differs from the source .dat.
    -- The size mismatch covers mod updates: when a new bridge or core ships, its .dat
    -- file size differs from the previously-deployed binary, triggering replacement.
    for _, f in ipairs(files) do
        local destPath = destDir .. sep .. f.dest
        local src = findModDat(f.dat)
        if src then
            local destSize = PZFB.fileSize(destPath)
            local srcSize  = PZFB.fileSize(src)
            if destSize <= 0 or destSize ~= srcSize then
                print("[PZEMU] Deploying " .. f.dat .. " -> " .. destPath
                      .. " (was " .. tostring(destSize) .. ", now " .. tostring(srcSize) .. ")")
                PZFB.copyFile(src, destPath)
            end
        end
    end

    -- Deploy all cores (skip duplicates — genesis_plus_gx is shared).
    -- Windows uses _win.dat files containing .dll cores.
    local deployed = {}
    for _, console in ipairs(CONSOLES) do
        if not deployed[console.coreFile] then
            deployed[console.coreFile] = true
            local ext = isWindows() and ".dll" or ".so"
            local coreDest = destDir .. sep .. console.coreFile .. ext
            local datName
            if isWindows() then
                datName = string.gsub(console.coreDat, "%.dat$", "_win.dat")
            else
                datName = console.coreDat
            end
            local src = findModDat(datName)
            if src then
                local destSize = PZFB.fileSize(coreDest)
                local srcSize  = PZFB.fileSize(src)
                if destSize <= 0 or destSize ~= srcSize then
                    print("[PZEMU] Deploying " .. datName .. " -> " .. coreDest)
                    PZFB.copyFile(src, coreDest)
                end
            end
        end
    end
end

-- ---------- public: get consoles list ----------

function PZEMUGame.getConsoles()
    return CONSOLES
end

function PZEMUGame.getConsoleById(id)
    for _, console in ipairs(CONSOLES) do
        if console.id == id then
            return console
        end
    end
    return nil
end

-- ---------- PZFB capability helpers ----------

--- true iff the deployed PZFB class files support session ids (PZFB 1.8+).
function PZEMUGame.hasSessions()
    if not PZFB or not PZFB.hasSessions then return false end
    local ok, v = pcall(PZFB.hasSessions)
    return ok and v == true
end

--- true iff `id` (or nil) still owns PZFB's shared game slot.
function PZEMUGame.ownsSession(id)
    if not PZFB or not PZFB.ownsSession then return true end
    local ok, v = pcall(PZFB.ownsSession, id)
    if not ok then return true end
    return v ~= false
end

--- Real-time minutes a full handheld battery lasts while playing (sandbox).
--- 0 disables draining. Default 600 (10 real hours); clamped to the sandbox
--- range 0..1440 (sandbox-options.txt).
function PZEMUGame.batteryMinutes()
    local ok, v = pcall(function()
        if SandboxVars and SandboxVars.PZEMU then
            return SandboxVars.PZEMU.HandheldBatteryMinutes
        end
        return nil
    end)
    if ok and type(v) == "number" then
        if v < 0 then return 0 end
        if v > 1440 then return 1440 end
        return v
    end
    return 600
end

-- ---------- legacy deferred stop (PZFB class files < 1.8) ----------
-- Old class files SIGKILL the child immediately in fbGameStop(). We send QUIT
-- first and give the bridge ~1 s to flush SRAM before the unscoped stop. The
-- handler runs from a module-level OnTick, so it keeps working after the window
-- has been removed. It never kills a game that somebody else started in the
-- meantime: a new fbGameStart resets PZFB's ring-buffer counters and goes back
-- to status 1 (STARTING), both of which we watch for.

PZEMUGame._pendingStop = nil

function PZEMUGame._cancelDeferredStop()
    PZEMUGame._pendingStop = nil
end

local function scheduleLegacyStop(bufStartAtStop)
    PZEMUGame._pendingStop = {
        at = getTimestampMs() + PZEMUGame.LEGACY_STOP_DELAY_MS,
        bufStart = bufStartAtStop or 0,
    }
end

local function legacyStopTick()
    local pending = PZEMUGame._pendingStop
    if not pending then return end
    if not PZFB or not PZFB.isAvailable or not PZFB.isAvailable() then
        PZEMUGame._pendingStop = nil
        return
    end
    local status = PZFB.gameStatus()
    if status == 0 then
        -- somebody already stopped the slot (or nothing was running)
        PZEMUGame._pendingStop = nil
        return
    end
    if status == 1 then
        -- a NEW game is starting (ours could not go back to STARTING) — hands off
        PZEMUGame._pendingStop = nil
        return
    end
    if status >= 3 then
        -- the bridge honoured QUIT and exited: release PZFB's resources now
        PZEMUGame._pendingStop = nil
        PZFB.gameStop()
        return
    end
    -- status 2: still running
    if PZFB.streamBufferStart and PZFB.streamBufferStart() < pending.bufStart then
        -- ring buffer counters were reset: a new game replaced ours — hands off
        PZEMUGame._pendingStop = nil
        return
    end
    if getTimestampMs() >= pending.at then
        PZEMUGame._pendingStop = nil
        PZFB.gameStop()
    end
end

Events.OnTick.Add(legacyStopTick)

-- ---------- constructor ----------

function PZEMUGame:new(console)
    local o = setmetatable({}, PZEMUGame)
    o.console = console
    o.state = "IDLE"        -- IDLE | STARTING | RUNNING | STOPPED | ERROR | LOST
    o.errorMsg = nil
    o.fb = nil
    o.currentFrame = -1
    o.romPath = nil
    o.sessionId = nil       -- PZFB 1.8 session id (nil on 1.7.x class files)
    o.paused = false        -- best-effort mirror of the bridge pause state
    o.batteryItem = nil     -- handheld InventoryItem this session drains
    o.batteryDead = false
    o._drainAcc = 0         -- fraction of a charge drained but not yet stepped off the item
    o._drainLastMs = nil
    o._drainLastUses = nil  -- last uses value seen (battery-swap detection)
    o.gamepadMap = console.gamepadMap

    -- Effective key map = console defaults + user remaps (+ meta keys).
    -- Consoles without `buttons` (third-party) simply keep their keyMap.
    if PZEMUBindings and PZEMUBindings.keyMapFor then
        local ok, map = pcall(PZEMUBindings.keyMapFor, console)
        o.keyMap = (ok and map) or console.keyMap
    else
        o.keyMap = console.keyMap
    end

    -- Deploy binaries if needed (first-time only, fast no-op after)
    deployBinaries()

    -- Locate bridge binary
    local sep = getFileSeparator()
    local binaryName = isWindows() and "pzemu-bridge.exe" or "pzemu-bridge"
    local userPath = getUserDir() .. sep .. binaryName
    if PZFB.fileSize(userPath) > 0 then
        o.binaryPath = userPath
    else
        o.binaryPath = nil
    end

    -- Locate core for this console
    local ext = isWindows() and ".dll" or ".so"
    local corePath = getUserDir() .. sep .. console.coreFile .. ext
    if PZFB.fileSize(corePath) > 0 then
        o.corePath = corePath
    else
        o.corePath = nil
    end

    return o
end

--- Re-read the user's key bindings (after the Controls panel saved them).
function PZEMUGame:reloadKeyMap()
    if PZEMUBindings and PZEMUBindings.keyMapFor then
        local ok, map = pcall(PZEMUBindings.keyMapFor, self.console)
        if ok and map then self.keyMap = map end
    end
end

-- ---------- input ----------

--- Can we write to the bridge right now (process alive and still ours)?
function PZEMUGame:_canSend()
    if self.state ~= "RUNNING" and self.state ~= "STARTING" then return false end
    if not PZEMUGame.ownsSession(self.sessionId) then return false end
    return true
end

function PZEMUGame:sendKey(lwjglKey, pressed)
    if not self:_canSend() then return end
    if self.batteryDead then return end   -- dead handheld: nothing gets through
    local retroBtn = self.keyMap[lwjglKey]
    if retroBtn then
        if retroBtn == PZEMUGame.META_PAUSE_TOGGLE then
            if pressed == 1 then self.paused = not self.paused end
        end
        PZFB.gameSendInput(retroBtn, pressed)
    end
end

function PZEMUGame:sendGamepadButton(joypadBtn, pressed)
    if not self:_canSend() then return end
    if self.batteryDead then return end
    if not self.gamepadMap then return end
    local retroBtn = self.gamepadMap[joypadBtn]
    if retroBtn then
        PZFB.gameSendInput(retroBtn, pressed)
    end
end

-- Forward an analog stick value to the bridge.
-- axisId: 0=leftX, 1=leftY, 2=rightX, 3=rightY.
-- value: float in [-1.0, 1.0]. Quantized to 8 bits (128 = center) and packed into the
-- existing 2-byte protocol with keycode = 64 + axisId.
function PZEMUGame:sendGamepadAxis(axisId, value)
    if not self:_canSend() then return end
    if self.batteryDead then return end
    if value < -1.0 then value = -1.0 elseif value > 1.0 then value = 1.0 end
    local q = math.floor((value + 1.0) * 127.5 + 0.5)
    if q < 0 then q = 0 elseif q > 255 then q = 255 end
    PZFB.gameSendInput(64 + axisId, q)
end

--- Explicit pause (C4 keycodes 19/20). Idempotent on the bridge side.
function PZEMUGame:sendPause(on)
    if not self:_canSend() then return end
    PZFB.gameSendInput(on and PZEMUGame.META_PAUSE_ON or PZEMUGame.META_PAUSE_OFF, 1)
    self.paused = on and true or false
end

--- Legacy pause toggle (C4 keycode 18) — what ESC does.
function PZEMUGame:togglePause()
    if not self:_canSend() then return end
    if self.batteryDead then return end
    PZFB.gameSendInput(PZEMUGame.META_PAUSE_TOGGLE, 1)
    PZFB.gameSendInput(PZEMUGame.META_PAUSE_TOGGLE, 0)
    self.paused = not self.paused
end

--- Push the current volume setting to the bridge (C4 keycode 68).
function PZEMUGame:sendVolume()
    if not self:_canSend() then return end
    local byte = 255
    if PZEMUSettings and PZEMUSettings.volumeByte then
        local ok, v = pcall(PZEMUSettings.volumeByte)
        if ok and type(v) == "number" then byte = v end
    end
    PZFB.gameSendInput(PZEMUGame.META_VOLUME, byte)
end

--- Ask the bridge to flush SRAM and exit (C4 keycode 21).
function PZEMUGame:sendQuit()
    if not self:_canSend() then return end
    PZFB.gameSendInput(PZEMUGame.META_QUIT, 1)
end

-- ---------- handheld batteries ----------

local function itemUsesFloat(item)
    local ok, v = pcall(function() return item:getCurrentUsesFloat() end)
    if ok and type(v) == "number" then return v end
    return nil
end

-- The fractional drain that has not yet been stepped off the item (same unit as
-- _drainAcc: fraction of a full charge) lives in the handheld's modData, so it
-- survives stop/start, saving and reloading. At the default 600 min one UseDelta
-- step is 60 real minutes; without this, sessions under an hour would never drain
-- and longer ones would lose their partial progress.
local DRAIN_ACC_KEY = "PZEMU_BatteryDrainAcc"

local function itemModData(item)
    local ok, md = pcall(function() return item:getModData() end)
    if ok and md ~= nil then return md end
    return nil
end

local function loadDrainAcc(item)
    local md = itemModData(item)
    if not md then return 0 end
    local ok, v = pcall(function() return md[DRAIN_ACC_KEY] end)
    if ok and type(v) == "number" and v > 0 then
        if v > 1 then return 1 end
        return v
    end
    return 0
end

local function saveDrainAcc(item, acc)
    local md = itemModData(item)
    if not md then return end
    pcall(function()
        if acc and acc > 0 then md[DRAIN_ACC_KEY] = acc else md[DRAIN_ACC_KEY] = nil end
    end)
end

--- (Re)load the per-session drain state from the current handheld: fractional
--- drain from its modData, last seen uses (battery-swap detection), fresh clock.
--- Called from setBatteryItem() and start().
function PZEMUGame:_loadBatteryState()
    local item = self.batteryItem
    self.batteryDead = false
    self._drainLastMs = nil
    if item then
        self._drainAcc = loadDrainAcc(item)
        self._drainLastUses = itemUsesFloat(item)
    else
        self._drainAcc = 0
        self._drainLastUses = nil
    end
end

--- Track the handheld item (Drainable) this session runs on.
function PZEMUGame:setBatteryItem(item)
    self.batteryItem = item
    self:_loadBatteryState()
end

--- Effective charge 0..1 for display: whole uses left on the item minus the
--- fractional drain not yet stepped off it, so the % moves smoothly instead of
--- once per whole use. nil without a handheld or when the item can't be read.
function PZEMUGame:batteryLevel()
    local item = self.batteryItem
    if not item then return nil end
    local uses = itemUsesFloat(item)
    if not uses then return nil end
    local level = uses - (self._drainAcc or 0)
    if level < 0 then level = 0 end
    if level > 1 then level = 1 end
    return level
end

--- A fresh battery went in: forget the partial drain of the old one (memory + item).
function PZEMUGame:_resetDrain(item, now)
    self._drainAcc = 0
    self._drainLastMs = now
    saveDrainAcc(item, 0)
end

--- Drain the handheld while RUNNING and not paused; freeze when empty; auto-resume
--- once a battery has been inserted. Rate: one full charge per
--- SandboxVars.PZEMU.HandheldBatteryMinutes real minutes of play (default 600 =
--- 10 real hours, so each UseDelta 0.1 step is 60 real minutes). Partial progress
--- is persisted on the item (DRAIN_ACC_KEY) and carries across sessions.
function PZEMUGame:_updateBattery()
    local item = self.batteryItem
    if not item then return end
    local now = getTimestampMs()

    if self.batteryDead then
        local uses = itemUsesFloat(item)
        if uses and uses > 0 then
            self.batteryDead = false
            self:_resetDrain(item, now)
            self._drainLastUses = uses
            self:sendPause(false)
        end
        return
    end

    local minutes = PZEMUGame.batteryMinutes()
    if self.paused or minutes <= 0 then
        self._drainLastMs = now
        return
    end
    if not self._drainLastMs then
        self._drainLastMs = now
        return
    end
    local dt = now - self._drainLastMs
    self._drainLastMs = now
    if dt <= 0 or dt > 5000 then return end  -- clock jump / long hitch guard

    local uses = itemUsesFloat(item)
    if not uses then return end

    -- Uses only ever go down through us; a rise means a fresh battery went in.
    -- (Vanilla InsertBattery keeps the handheld item, so its modData survives.)
    if self._drainLastUses and uses > self._drainLastUses + 0.0001 then
        self._drainAcc = 0
        saveDrainAcc(item, 0)
    end

    -- Drainable items only store whole "uses" (UseDelta each); accumulate until
    -- one use is spent, then step the item down.
    local step = 0.1
    local ok, ud = pcall(function() return item:getUseDelta() end)
    if ok and type(ud) == "number" and ud > 0 then step = ud end

    self._drainAcc = (self._drainAcc or 0) + dt / (minutes * 60000)
    if self._drainAcc >= step then
        local n = math.floor(self._drainAcc / step)
        self._drainAcc = self._drainAcc - n * step
        local newUses = uses - n * step
        if newUses < 0 then newUses = 0 end
        pcall(function() item:setCurrentUsesFloat(newUses) end)
        uses = itemUsesFloat(item) or newUses
    end
    self._drainLastUses = uses
    saveDrainAcc(item, self._drainAcc)

    if uses <= 0.0001 then
        self.batteryDead = true
        self:sendPause(true)
    end
end

-- ---------- lifecycle ----------

function PZEMUGame:start(romPath)
    self:stop()
    -- A new start supersedes any pending legacy stop (fbGameStart kills the old process itself).
    PZEMUGame._cancelDeferredStop()

    if not self.binaryPath then
        self.errorMsg = "Bridge binary not found"
        self.state = "ERROR"
        return
    end
    if not self.corePath then
        self.errorMsg = self.console.displayName .. " core not found"
        self.state = "ERROR"
        return
    end

    self.romPath = romPath
    self.currentFrame = -1
    self.paused = false
    self:_loadBatteryState()   -- fractional drain comes back from the item's modData
    self._volumeSentRunning = false

    local w = self.console.width
    local h = self.console.height

    -- Create framebuffer (NEAREST filtering for pixel-perfect rendering)
    self.fb = PZFB.create(w, h)

    -- Build extra args as a table: { core_path, rom_path, width, height, sys_dir, save_dir }
    -- Using gameStartArgs (PZFB 1.7.0+) bypasses whitespace-split parsing, so paths
    -- with spaces, apostrophes, or Unicode pass through verbatim.
    local sep = getFileSeparator()
    local saveDir = getUserDir() .. sep .. "saves" .. sep .. self.console.romDir

    local argv = {
        self.corePath,
        romPath,
        tostring(w),
        tostring(h),
        saveDir,
        saveDir,
    }

    -- Optional 7th argv: libretro controller-port-device subclass for analog-capable cores.
    -- Bridge defaults to RETRO_DEVICE_JOYPAD (1) when absent — existing consoles unchanged.
    if self.console.portDevice then
        table.insert(argv, tostring(self.console.portDevice))
    end

    local id = nil
    if PZFB.gameStartArgs then
        id = PZFB.gameStartArgs(self.binaryPath, w, h, argv)
    else
        -- Legacy fallback for users still on PZFB < 1.7.0
        -- (will still break on paths with spaces; user must update PZFB)
        local extraArgs = table.concat(argv, " ")
        id = PZFB.gameStart(self.binaryPath, w, h, extraArgs)
    end
    -- PZFB 1.8 returns the session id (> 0); 1.7.x returns nothing.
    if type(id) == "number" and id > 0 then
        self.sessionId = id
    else
        self.sessionId = nil
    end

    self.state = "STARTING"
    self.errorMsg = nil

    -- Volume right after start (stdin is open as soon as the process exists).
    self:sendVolume()

    -- A handheld that is already empty cannot boot.
    if self.batteryItem then
        local uses = itemUsesFloat(self.batteryItem)
        if uses and uses <= 0 then
            self.batteryDead = true
            self:sendPause(true)
        end
    end
end

function PZEMUGame:stop()
    local wasLive = (self.state == "STARTING" or self.state == "RUNNING")

    if self.state == "LOST" then
        -- Another mod owns the slot: never touch it. Just drop our resources.
    elseif self.state ~= "IDLE" then
        if wasLive then
            -- Ask the bridge to flush SRAM and exit on its own.
            self:sendQuit()
        end
        if PZEMUGame.hasSessions() then
            -- Scoped stop: PZFB 1.8 stops only if our id is current, and the Java
            -- side handles the graceful EOF -> SIGTERM -> kill sequence (C2).
            PZFB.gameStop(self.sessionId)
        else
            -- Legacy class files (immediate SIGKILL). Our process was alive: give
            -- it time to honour QUIT. Our process already exited: only clean up
            -- when nothing else has taken the slot since.
            if wasLive then
                local bufStart = PZFB.streamBufferStart and PZFB.streamBufferStart() or 0
                scheduleLegacyStop(bufStart)
            else
                local status = PZFB.gameStatus()
                if status == 0 or status >= 3 then
                    PZFB.gameStop()
                end
            end
        end
    end

    if self.fb then
        PZFB.destroy(self.fb)
        self.fb = nil
    end
    self.state = "IDLE"
    self.sessionId = nil
    self.currentFrame = -1
    self.paused = false
end

function PZEMUGame:update()
    if self.state == "IDLE" or self.state == "ERROR" or self.state == "STOPPED" or self.state == "LOST" then
        return
    end

    -- Session ownership (PZFB 1.8): another mod may have taken the shared slot.
    if self.sessionId and not PZEMUGame.ownsSession(self.sessionId) then
        self.state = "LOST"
        self.errorMsg = "Another mod took over the emulator"
        if self.fb then
            PZFB.destroy(self.fb)
            self.fb = nil
        end
        return
    end

    local status = PZFB.gameStatus()
    -- 0=idle, 1=starting, 2=running, 3=exited, 4=error

    if status >= 3 then
        if status == 4 then
            self.errorMsg = PZFB.gameError()
            self.state = "ERROR"
        else
            self.state = "STOPPED"
        end
        return
    end

    if self.state == "STARTING" and status >= 2 then
        self.state = "RUNNING"
    end

    if self.state == "RUNNING" and not self._volumeSentRunning then
        -- Re-send once the bridge is definitely up (idempotent).
        self._volumeSentRunning = true
        self:sendVolume()
    end

    if self.state == "RUNNING" then
        self:_updateBattery()
    end

    -- Consume latest frame from ring buffer
    if not self.fb or not PZFB.isReady(self.fb) then return end

    local bufStart = PZFB.streamBufferStart()
    local bufCount = PZFB.streamBufferCount()
    if bufCount <= 0 then return end

    local latest = bufStart + bufCount - 1
    if latest ~= self.currentFrame then
        -- Third argument is the session id (PZFB 1.8 scoped upload); 1.7.x ignores it.
        if PZFB.streamFrame(self.fb, latest, self.sessionId) then
            self.currentFrame = latest
        end
    end
end
