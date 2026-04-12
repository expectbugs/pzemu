--
-- PZEMUGame.lua — Process management, key translation, binary deployment, ROM scanning
--
-- Manages the pzemu-bridge process via PZFB's game process API.
-- Translates LWJGL key codes to libretro button IDs before sending.
--

require "PZFB/PZFBApi"

PZEMUGame = {}
PZEMUGame.__index = PZEMUGame

-- FCEUmm outputs 256x224 (NTSC with standard 8-line top/bottom clipping)
PZEMUGame.NES_WIDTH  = 256
PZEMUGame.NES_HEIGHT = 224

-- ---------- platform helpers ----------

local function isWindows()
    return getFileSeparator() == "\\"
end

local function getUserDir()
    return Core.getMyDocumentFolder() .. getFileSeparator() .. "PZEMU"
end

-- ---------- NES key map: LWJGL key code → RETRO_DEVICE_ID_JOYPAD_* ----------
-- Button IDs 0-15 are standard libretro joypad buttons.
-- IDs 16+ are meta-commands handled by the bridge (not sent to the core).

local NES_KEY_MAP = {}
-- Primary layout (Z/X + Arrows)
NES_KEY_MAP[Keyboard.KEY_Z]      = 0   -- B (south face)
NES_KEY_MAP[Keyboard.KEY_X]      = 8   -- A (east face)
-- Alternative layout (A/S + Arrows) — avoids keyboard ghosting with Z/X + arrows
NES_KEY_MAP[Keyboard.KEY_A]      = 0   -- B (alternate)
NES_KEY_MAP[Keyboard.KEY_S]      = 8   -- A (alternate)
NES_KEY_MAP[Keyboard.KEY_RSHIFT] = 2   -- SELECT
NES_KEY_MAP[Keyboard.KEY_RETURN] = 3   -- START
NES_KEY_MAP[Keyboard.KEY_UP]     = 4   -- D-pad UP
NES_KEY_MAP[Keyboard.KEY_DOWN]   = 5   -- D-pad DOWN
NES_KEY_MAP[Keyboard.KEY_LEFT]   = 6   -- D-pad LEFT
NES_KEY_MAP[Keyboard.KEY_RIGHT]  = 7   -- D-pad RIGHT
NES_KEY_MAP[Keyboard.KEY_ESCAPE] = 18  -- ESC → freeze emulation (meta-command)
NES_KEY_MAP[Keyboard.KEY_F5]     = 16  -- Save state (meta-command)
NES_KEY_MAP[Keyboard.KEY_F7]     = 17  -- Load state (meta-command)

-- ---------- .dat file path resolution (handles Workshop vs local) ----------

local function findModDat(filename)
    local sep = getFileSeparator()
    local modInfo = getModInfoByID("PZEMU")
    if not modInfo then return nil end

    local dir = modInfo:getDir()
    if dir then
        -- Try: dir/media/pzemu/filename
        local p = dir .. sep .. "media" .. sep .. "pzemu" .. sep .. filename
        if PZFB.fileSize(p) > 0 then return p end
        -- Try: dir/42/media/pzemu/filename
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

-- ---------- binary deployment ----------

local function deployBinaries()
    local sep = getFileSeparator()
    local destDir = getUserDir()

    local files
    if isWindows() then
        files = {
            { dat = "pzemu-bridge_win.dat", dest = "pzemu-bridge.exe" },
            { dat = "SDL2.dat",             dest = "SDL2.dll" },
            { dat = "fceumm_libretro.dat",  dest = "fceumm_libretro.dll" },
        }
    else
        files = {
            { dat = "pzemu-bridge.dat",     dest = "pzemu-bridge" },
            { dat = "fceumm_libretro.dat",  dest = "fceumm_libretro.so" },
        }
    end

    for _, f in ipairs(files) do
        local destPath = destDir .. sep .. f.dest
        if PZFB.fileSize(destPath) <= 0 then
            local srcPath = findModDat(f.dat)
            if srcPath then
                print("[PZEMU] Deploying " .. f.dat .. " -> " .. destPath)
                PZFB.copyFile(srcPath, destPath)
            end
        end
    end
end

-- ---------- ROM scanning ----------

local function scanDir(dirPath, results, seen)
    local listing = PZFB.listDir(dirPath)
    if not listing or listing == "" then return end
    local sep = getFileSeparator()
    for line in string.gmatch(listing, "[^\n]+") do
        local lower = string.lower(line)
        if string.sub(lower, -4) == ".nes" and not seen[lower] then
            seen[lower] = true
            table.insert(results, {
                name = line,
                path = dirPath .. sep .. line,
            })
        end
    end
end

function PZEMUGame.findRoms()
    local sep = getFileSeparator()
    local results = {}
    local seen = {}

    -- Bundled ROMs from mod directory
    local modInfo = getModInfoByID("PZEMU")
    if modInfo then
        local dir = modInfo:getDir()
        if dir then
            scanDir(dir .. sep .. "media" .. sep .. "pzemu" .. sep .. "roms" .. sep .. "nes", results, seen)
            scanDir(dir .. sep .. "42" .. sep .. "media" .. sep .. "pzemu" .. sep .. "roms" .. sep .. "nes", results, seen)
        end
        local ok, vdir = pcall(function() return modInfo:getVersionDir() end)
        if ok and vdir then
            scanDir(vdir .. sep .. "media" .. sep .. "pzemu" .. sep .. "roms" .. sep .. "nes", results, seen)
        end
    end

    -- User ROMs from ~/Zomboid/PZEMU/roms/nes/
    scanDir(getUserDir() .. sep .. "roms" .. sep .. "nes", results, seen)

    return results
end

-- ---------- constructor ----------

function PZEMUGame:new()
    local o = setmetatable({}, PZEMUGame)
    o.state = "IDLE"
    o.errorMsg = nil
    o.fb = nil
    o.currentFrame = -1
    o.romPath = nil
    o.keyMap = NES_KEY_MAP

    -- Deploy binaries if needed
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

    -- Locate NES core
    local coreName = isWindows() and "fceumm_libretro.dll" or "fceumm_libretro.so"
    local corePath = getUserDir() .. sep .. coreName
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

-- ---------- lifecycle ----------

function PZEMUGame:start(romPath)
    self:stop()

    if not self.binaryPath then
        self.errorMsg = "Bridge binary not found"
        self.state = "ERROR"
        return
    end
    if not self.corePath then
        self.errorMsg = "NES core not found"
        self.state = "ERROR"
        return
    end

    self.romPath = romPath
    self.currentFrame = -1

    -- Create framebuffer (NEAREST filtering for pixel-perfect rendering)
    self.fb = PZFB.create(PZEMUGame.NES_WIDTH, PZEMUGame.NES_HEIGHT)

    -- Build extra args: core_path rom_path width height save_dir save_dir
    local sep = getFileSeparator()
    local saveDir = getUserDir() .. sep .. "saves" .. sep .. "nes"

    local extraArgs = self.corePath .. " " .. romPath .. " "
        .. tostring(PZEMUGame.NES_WIDTH) .. " " .. tostring(PZEMUGame.NES_HEIGHT)
        .. " " .. saveDir .. " " .. saveDir

    PZFB.gameStart(self.binaryPath, PZEMUGame.NES_WIDTH, PZEMUGame.NES_HEIGHT, extraArgs)
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

    -- Transition: STARTING → RUNNING
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
