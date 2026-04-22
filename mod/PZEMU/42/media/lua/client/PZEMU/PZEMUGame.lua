--
-- PZEMUGame.lua — Multi-console process management, key translation, ROM scanning
--
-- Manages the pzemu-bridge process via PZFB's game process API.
-- Console-specific configuration (resolution, core, key map) is driven by a
-- CONSOLES table. The bridge binary is fully generic — this file provides
-- the per-console knowledge.
--

require "PZFB/PZFBApi"

PZEMUGame = {}
PZEMUGame.__index = PZEMUGame

-- ---------- platform helpers ----------

local function isWindows()
    return getFileSeparator() == "\\"
end

local function getUserDir()
    return Core.getMyDocumentFolder() .. getFileSeparator() .. "PZEMU"
end

-- ---------- shared meta-commands (same for all consoles) ----------

local META_KEYS = {}
META_KEYS[Keyboard.KEY_ESCAPE] = 18  -- Freeze/unfreeze emulation
META_KEYS[Keyboard.KEY_F5]     = 16  -- Save state
META_KEYS[Keyboard.KEY_F7]     = 17  -- Load state

-- ---------- per-console key map builders ----------

local function buildKeyMap(buttonMap)
    -- Merge console-specific button map with shared meta-commands
    local map = {}
    for k, v in pairs(buttonMap) do map[k] = v end
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

-- NES: 8 buttons — D-pad, B, A, Start, Select
local NES_BUTTONS = {}
NES_BUTTONS[Keyboard.KEY_Z]      = 0   -- B
NES_BUTTONS[Keyboard.KEY_A]      = 0   -- B (alt — avoids ghosting with arrows)
NES_BUTTONS[Keyboard.KEY_X]      = 8   -- A
NES_BUTTONS[Keyboard.KEY_S]      = 8   -- A (alt)
NES_BUTTONS[Keyboard.KEY_RSHIFT] = 2   -- SELECT
NES_BUTTONS[Keyboard.KEY_RETURN] = 3   -- START
NES_BUTTONS[Keyboard.KEY_UP]     = 4
NES_BUTTONS[Keyboard.KEY_DOWN]   = 5
NES_BUTTONS[Keyboard.KEY_LEFT]   = 6
NES_BUTTONS[Keyboard.KEY_RIGHT]  = 7

-- SNES: 12 buttons — adds Y, X, L, R to NES layout
local SNES_BUTTONS = {}
SNES_BUTTONS[Keyboard.KEY_Z]      = 0   -- B
SNES_BUTTONS[Keyboard.KEY_A]      = 0   -- B (alt)
SNES_BUTTONS[Keyboard.KEY_X]      = 8   -- A
SNES_BUTTONS[Keyboard.KEY_S]      = 8   -- A (alt)
SNES_BUTTONS[Keyboard.KEY_C]      = 1   -- Y
SNES_BUTTONS[Keyboard.KEY_D]      = 1   -- Y (alt)
SNES_BUTTONS[Keyboard.KEY_V]      = 9   -- X
SNES_BUTTONS[Keyboard.KEY_F]      = 9   -- X (alt)
SNES_BUTTONS[Keyboard.KEY_Q]      = 10  -- L shoulder
SNES_BUTTONS[Keyboard.KEY_E]      = 11  -- R shoulder
SNES_BUTTONS[Keyboard.KEY_RSHIFT] = 2   -- SELECT
SNES_BUTTONS[Keyboard.KEY_RETURN] = 3   -- START
SNES_BUTTONS[Keyboard.KEY_UP]     = 4
SNES_BUTTONS[Keyboard.KEY_DOWN]   = 5
SNES_BUTTONS[Keyboard.KEY_LEFT]   = 6
SNES_BUTTONS[Keyboard.KEY_RIGHT]  = 7

-- Genesis 6-button: libretro maps Genesis A=Y(1), B=B(0), C=A(8)
-- 6-button adds: X=L(10), Y=X(9), Z=R(11)
local GENESIS_BUTTONS = {}
GENESIS_BUTTONS[Keyboard.KEY_Z]      = 1   -- Genesis A (libretro Y)
GENESIS_BUTTONS[Keyboard.KEY_A]      = 1   -- Genesis A (alt)
GENESIS_BUTTONS[Keyboard.KEY_X]      = 0   -- Genesis B (libretro B)
GENESIS_BUTTONS[Keyboard.KEY_S]      = 0   -- Genesis B (alt)
GENESIS_BUTTONS[Keyboard.KEY_C]      = 8   -- Genesis C (libretro A)
GENESIS_BUTTONS[Keyboard.KEY_D]      = 8   -- Genesis C (alt)
GENESIS_BUTTONS[Keyboard.KEY_Q]      = 10  -- Genesis X (libretro L) — 6-button
GENESIS_BUTTONS[Keyboard.KEY_W]      = 9   -- Genesis Y (libretro X) — 6-button
GENESIS_BUTTONS[Keyboard.KEY_E]      = 11  -- Genesis Z (libretro R) — 6-button
GENESIS_BUTTONS[Keyboard.KEY_RETURN] = 3   -- START
GENESIS_BUTTONS[Keyboard.KEY_UP]     = 4
GENESIS_BUTTONS[Keyboard.KEY_DOWN]   = 5
GENESIS_BUTTONS[Keyboard.KEY_LEFT]   = 6
GENESIS_BUTTONS[Keyboard.KEY_RIGHT]  = 7

-- Game Boy: same as NES (D-pad, B, A, Start, Select)
local GB_BUTTONS = NES_BUTTONS

-- Atari 2600: minimal — fire, select, reset + D-pad
local ATARI2600_BUTTONS = {}
ATARI2600_BUTTONS[Keyboard.KEY_Z]      = 0   -- Fire
ATARI2600_BUTTONS[Keyboard.KEY_A]      = 0   -- Fire (alt)
ATARI2600_BUTTONS[Keyboard.KEY_X]      = 8   -- Fire 2 (paddle games)
ATARI2600_BUTTONS[Keyboard.KEY_S]      = 8   -- Fire 2 (alt)
ATARI2600_BUTTONS[Keyboard.KEY_RSHIFT] = 2   -- Game Select
ATARI2600_BUTTONS[Keyboard.KEY_RETURN] = 3   -- Game Reset
ATARI2600_BUTTONS[Keyboard.KEY_UP]     = 4
ATARI2600_BUTTONS[Keyboard.KEY_DOWN]   = 5
ATARI2600_BUTTONS[Keyboard.KEY_LEFT]   = 6
ATARI2600_BUTTONS[Keyboard.KEY_RIGHT]  = 7

-- Game Gear: D-pad, Button 1, Button 2, Start
local GG_BUTTONS = {}
GG_BUTTONS[Keyboard.KEY_Z]      = 0   -- Button 1
GG_BUTTONS[Keyboard.KEY_A]      = 0   -- Button 1 (alt)
GG_BUTTONS[Keyboard.KEY_X]      = 8   -- Button 2
GG_BUTTONS[Keyboard.KEY_S]      = 8   -- Button 2 (alt)
GG_BUTTONS[Keyboard.KEY_RETURN] = 3   -- START
GG_BUTTONS[Keyboard.KEY_UP]     = 4
GG_BUTTONS[Keyboard.KEY_DOWN]   = 5
GG_BUTTONS[Keyboard.KEY_LEFT]   = 6
GG_BUTTONS[Keyboard.KEY_RIGHT]  = 7

-- Master System: D-pad, Button 1, Button 2
local SMS_BUTTONS = {}
SMS_BUTTONS[Keyboard.KEY_Z]      = 0   -- Button 1
SMS_BUTTONS[Keyboard.KEY_A]      = 0   -- Button 1 (alt)
SMS_BUTTONS[Keyboard.KEY_X]      = 8   -- Button 2
SMS_BUTTONS[Keyboard.KEY_S]      = 8   -- Button 2 (alt)
SMS_BUTTONS[Keyboard.KEY_RETURN] = 3   -- Pause
SMS_BUTTONS[Keyboard.KEY_UP]     = 4
SMS_BUTTONS[Keyboard.KEY_DOWN]   = 5
SMS_BUTTONS[Keyboard.KEY_LEFT]   = 6
SMS_BUTTONS[Keyboard.KEY_RIGHT]  = 7

-- ---------- console specifications ----------
-- Resolutions verified against actual core output via standalone bridge testing.
-- The bridge outputs at these fixed dimensions; if the core's frame is smaller
-- (e.g. Genesis starts 256x192), the bridge centers and pads with black.

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
        keyMap        = buildKeyMap(NES_BUTTONS),
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
        keyMap        = buildKeyMap(SNES_BUTTONS),
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
        keyMap        = buildKeyMap(GENESIS_BUTTONS),
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
        keyMap        = buildKeyMap(GB_BUTTONS),
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
        keyMap        = buildKeyMap(ATARI2600_BUTTONS),
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
        keyMap        = buildKeyMap(GG_BUTTONS),
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
        keyMap        = buildKeyMap(SMS_BUTTONS),
        gamepadMap    = GAMEPAD_SMS,
        controlHints  = {
            "Arrows  =  D-pad",
            "Z or A  =  Button 1",
            "X or S  =  Button 2",
            "Enter  =  Pause",
        },
    },
}

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

    for _, f in ipairs(files) do
        local destPath = destDir .. sep .. f.dest
        if PZFB.fileSize(destPath) <= 0 then
            local src = findModDat(f.dat)
            if src then
                print("[PZEMU] Deploying " .. f.dat .. " -> " .. destPath)
                PZFB.copyFile(src, destPath)
            end
        end
    end

    -- Deploy all cores (skip duplicates — genesis_plus_gx is shared)
    -- Windows uses _win.dat files containing .dll cores
    local deployed = {}
    for _, console in ipairs(CONSOLES) do
        if not deployed[console.coreFile] then
            deployed[console.coreFile] = true
            local ext = isWindows() and ".dll" or ".so"
            local coreDest = destDir .. sep .. console.coreFile .. ext
            if PZFB.fileSize(coreDest) <= 0 then
                local datName
                if isWindows() then
                    datName = string.gsub(console.coreDat, "%.dat$", "_win.dat")
                else
                    datName = console.coreDat
                end
                local src = findModDat(datName)
                if src then
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

-- ---------- constructor ----------

function PZEMUGame:new(console)
    local o = setmetatable({}, PZEMUGame)
    o.console = console
    o.state = "IDLE"
    o.errorMsg = nil
    o.fb = nil
    o.currentFrame = -1
    o.romPath = nil
    o.keyMap = console.keyMap
    o.gamepadMap = console.gamepadMap

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

-- ---------- input ----------

function PZEMUGame:sendKey(lwjglKey, pressed)
    if self.state ~= "RUNNING" and self.state ~= "STARTING" then return end
    local retroBtn = self.keyMap[lwjglKey]
    if retroBtn then
        PZFB.gameSendInput(retroBtn, pressed)
    end
end

function PZEMUGame:sendGamepadButton(joypadBtn, pressed)
    if self.state ~= "RUNNING" and self.state ~= "STARTING" then return end
    if not self.gamepadMap then return end
    local retroBtn = self.gamepadMap[joypadBtn]
    if retroBtn then
        PZFB.gameSendInput(retroBtn, pressed)
    end
end

-- ---------- lifecycle ----------

function PZEMUGame:start(romPath)
    self:stop()

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

    local w = self.console.width
    local h = self.console.height

    -- Create framebuffer (NEAREST filtering for pixel-perfect rendering)
    self.fb = PZFB.create(w, h)

    -- Build extra args as a table: { core_path, rom_path, width, height, sys_dir, save_dir }
    -- Using gameStartArgs (PZFB 1.7.0+) bypasses whitespace-split parsing, so paths
    -- with spaces, apostrophes, or Unicode pass through verbatim.
    -- Falls back to legacy gameStart on older PZFB.
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

    if PZFB.gameStartArgs then
        PZFB.gameStartArgs(self.binaryPath, w, h, argv)
    else
        -- Legacy fallback for users still on PZFB < 1.7.0
        -- (will still break on paths with spaces; user must update PZFB)
        local extraArgs = table.concat(argv, " ")
        PZFB.gameStart(self.binaryPath, w, h, extraArgs)
    end
    self.state = "STARTING"
    self.errorMsg = nil
end

function PZEMUGame:stop()
    if self.state ~= "IDLE" then
        PZFB.gameStop()
    end
    if self.fb then
        PZFB.destroy(self.fb)
        self.fb = nil
    end
    self.state = "IDLE"
    self.currentFrame = -1
end

function PZEMUGame:update()
    if self.state == "IDLE" or self.state == "ERROR" or self.state == "STOPPED" then
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

    -- Consume latest frame from ring buffer
    if not self.fb or not PZFB.isReady(self.fb) then return end

    local bufStart = PZFB.streamBufferStart()
    local bufCount = PZFB.streamBufferCount()
    if bufCount <= 0 then return end

    local latest = bufStart + bufCount - 1
    if latest ~= self.currentFrame then
        if PZFB.streamFrame(self.fb, latest) then
            self.currentFrame = latest
        end
    end
end
