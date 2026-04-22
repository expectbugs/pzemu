--
-- PZEMUWindow.lua — Emulator UI with game picker, welcome screen, and game panel
--
-- Four classes:
--   PZEMUGamePanel  — PZFBInputPanel subclass for emulator display + input
--   PZEMUGamePicker — Cartridge-based game selection list
--   PZEMUWelcome    — Instructions/controls screen (console-specific)
--   PZEMUWindow     — Main ISCollapsableWindow (singleton)
--

require "PZFB/PZFBInput"
require "PZEMU/PZEMUGame"

-- Helper: user data directory
local function getUserDir()
    return Core.getMyDocumentFolder() .. getFileSeparator() .. "PZEMU"
end

-- Helper: convert Roman numeral suffixes to Arabic for matching
-- Handles II-X at end of name or before another _
local function romanToArabic(name)
    -- Order matters: longer numerals first to prevent partial matches
    -- (e.g. "viii" must run before "vii" before "vi")
    -- "v" is processed last because any earlier numeral containing "v"
    -- must be consumed before a single "v" could mis-match.
    local romanPairs = {
        {"viii", "8"}, {"vii", "7"}, {"vi", "6"}, {"iv", "4"},
        {"iii", "3"}, {"ii", "2"}, {"ix", "9"}, {"x", "10"}, {"v", "5"},
    }
    for _, p in ipairs(romanPairs) do
        name = string.gsub(name, "_" .. p[1] .. "$",  "_" .. p[2])
        name = string.gsub(name, "_" .. p[1] .. "_",  "_" .. p[2] .. "_")
    end
    return name
end

-- Strip common Latin-1 diacritics by byte-pattern. Kahlua lacks unicodedata,
-- so this is a best-effort explicit mapping. Uses string.char so we don't
-- depend on Kahlua supporting \xNN escapes in source literals.
-- Covers accented vowels and ñ/ç common in game titles (Pokémon, Señor, etc.)
local DIACRITIC_MAP = {
    [string.char(0xc3,0xa1)]="a", [string.char(0xc3,0xa0)]="a", [string.char(0xc3,0xa2)]="a",
    [string.char(0xc3,0xa3)]="a", [string.char(0xc3,0xa4)]="a", [string.char(0xc3,0xa5)]="a",
    [string.char(0xc3,0xa9)]="e", [string.char(0xc3,0xa8)]="e", [string.char(0xc3,0xaa)]="e",
    [string.char(0xc3,0xab)]="e", [string.char(0xc3,0xad)]="i", [string.char(0xc3,0xac)]="i",
    [string.char(0xc3,0xae)]="i", [string.char(0xc3,0xaf)]="i", [string.char(0xc3,0xb3)]="o",
    [string.char(0xc3,0xb2)]="o", [string.char(0xc3,0xb4)]="o", [string.char(0xc3,0xb5)]="o",
    [string.char(0xc3,0xb6)]="o", [string.char(0xc3,0xba)]="u", [string.char(0xc3,0xb9)]="u",
    [string.char(0xc3,0xbb)]="u", [string.char(0xc3,0xbc)]="u", [string.char(0xc3,0xb1)]="n",
    [string.char(0xc3,0xa7)]="c",
}
local function stripDiacritics(s)
    for bytes, repl in pairs(DIACRITIC_MAP) do
        s = string.gsub(s, bytes, repl)
    end
    return s
end

-- Helper: normalize a ROM filename for fuzzy matching
-- Normalization examples (what this function produces for real inputs):
--   "Super Mario Bros. 3 (USA) (PRG1) [!].nes" -> "super_mario_bros_3"
--   "Legend of Zelda, The (USA).nes"           -> "legend_of_zelda"   (trailing ", The" drop)
--   "The Legend of Zelda (USA).nes"            -> "legend_of_zelda"   (leading "The " drop)
--   "Pokemon Red (U) [S][!].gb"                -> "pokemon_red"
--   "Pokémon Red (U).gb"                       -> "pokemon_red"       (diacritic strip)
--   "Kirby's Dream Land.gb"                    -> "kirbys_dream_land"
--   "Zelda II: The Adventure of Link.nes"      -> "zelda_2_the_adventure_of_link"
--   "Final Fantasy - IV.smc" (hyphen w/space)  -> "final_fantasy_4"
--   "Castlevania IV.smc"                       -> "castlevania_4"
-- Note: embedded articles are NOT dropped (only leading ^the_/^a_/^an_ and
-- trailing _the$/_a$/_an$). This keeps game names like "Zelda II: The Adventure
-- of Link" distinct from future entries without such sub-titles.
-- False-positive guard:
--   "Final Fantasy II" and "Final Fantasy III" produce distinct "final_fantasy_2"
--   and "final_fantasy_3" — DO NOT add prefix-matching to fuzzyFindRom or this breaks.
local function normalizeRomName(filename)
    -- Remove file extension
    local name = string.gsub(filename, "%.[^%.]+$", "")
    -- Strip everything from first ( or [ to end of string (region/version/dump tags)
    name = string.gsub(name, "%s*[%(].*$", "")
    name = string.gsub(name, "%s*%[.*$", "")
    -- Strip trailing underscores, whitespace, and periods
    name = string.gsub(name, "[_%s%.]+$", "")
    -- Strip apostrophes (straight and U+2019 curly right single quotation mark) and commas
    name = string.gsub(name, "'",                        "")
    name = string.gsub(name, string.char(0xe2,0x80,0x99),"")
    name = string.gsub(name, ",",                        "")
    -- Strip internal periods (like "Bros." -> "Bros")
    name = string.gsub(name, "%.", "")
    -- Normalize separator variants: hyphens -> underscore, em/en-dash, colons
    name = string.gsub(name, "%s*[%-]+%s*",              "_")
    name = string.gsub(name, string.char(0xe2,0x80,0x93),"_")  -- en-dash
    name = string.gsub(name, string.char(0xe2,0x80,0x94),"_")  -- em-dash
    name = string.gsub(name, "%s*:%s*",                  "_")
    -- Collapse runs of underscores/spaces
    name = string.gsub(name, "[_%s]+", "_")
    -- Lowercase for case-insensitive matching
    name = string.lower(name)
    -- Strip common diacritics (after lowercase so only lowercase UTF-8 bytes matter)
    name = stripDiacritics(name)
    -- Drop leading article: "the_", "a_", "an_"
    name = string.gsub(name, "^the_", "")
    name = string.gsub(name, "^a_",   "")
    name = string.gsub(name, "^an_",  "")
    -- Drop trailing ", The" / ", A" / ", An" (now "_the" / "_a" / "_an" after comma-strip)
    name = string.gsub(name, "_the$", "")
    name = string.gsub(name, "_a$",   "")
    name = string.gsub(name, "_an$",  "")
    -- Convert Roman numerals to Arabic (II->2, III->3, ..., X->10)
    name = romanToArabic(name)
    return name
end

-- Helper: get the file extension from a filename
local function getExtension(filename)
    return string.match(filename, "(%.[^%.]+)$") or ""
end

-- Helper: fuzzy-match a ROM in a directory
-- Scans the directory for files with matching extension whose normalized name
-- matches the normalized expected name.
local function fuzzyFindRom(dirPath, romFile, extensions)
    local listing = PZFB.listDir(dirPath)
    if not listing or listing == "" then return nil end

    local expectedBase = normalizeRomName(romFile)
    local expectedExt = string.lower(getExtension(romFile))
    local sep = getFileSeparator()

    for line in string.gmatch(listing, "[^\n]+") do
        local fileExt = string.lower(getExtension(line))
        -- Check if extension matches (could be .nes, .smc, .bin, etc.)
        local extMatch = false
        if fileExt == expectedExt then
            extMatch = true
        elseif extensions then
            for _, ext in ipairs(extensions) do
                if fileExt == ext then
                    extMatch = true
                    break
                end
            end
        end
        if extMatch then
            local fileBase = normalizeRomName(line)
            if fileBase == expectedBase then
                return dirPath .. sep .. line
            end
        end
    end
    return nil
end

-- Helper: resolve ROM path — exact match first, then fuzzy match
local function resolveRomPath(console, romFile)
    local sep = getFileSeparator()
    local userRomDir = getUserDir() .. sep .. "roms" .. sep .. console.romDir

    -- 1. Exact match in user ROM dir
    local exactPath = userRomDir .. sep .. romFile
    if PZFB.fileSize(exactPath) > 0 then return exactPath end

    -- 2. Fuzzy match in user ROM dir
    local fuzzyPath = fuzzyFindRom(userRomDir, romFile, console.romExtensions)
    if fuzzyPath then return fuzzyPath end

    -- 3. Bundled ROMs from mod directory (exact only — bundled names are controlled)
    local modInfo = getModInfoByID("PZEMU")
    if modInfo then
        local dir = modInfo:getDir()
        if dir then
            local p = dir .. sep .. "media" .. sep .. "pzemu" .. sep .. "roms" .. sep .. console.romDir .. sep .. romFile
            if PZFB.fileSize(p) > 0 then return p end
            p = dir .. sep .. "42" .. sep .. "media" .. sep .. "pzemu" .. sep .. "roms" .. sep .. console.romDir .. sep .. romFile
            if PZFB.fileSize(p) > 0 then return p end
        end
        local ok, vdir = pcall(function() return modInfo:getVersionDir() end)
        if ok and vdir then
            local p = vdir .. sep .. "media" .. sep .. "pzemu" .. sep .. "roms" .. sep .. console.romDir .. sep .. romFile
            if PZFB.fileSize(p) > 0 then return p end
        end
    end

    return nil
end

-- ============================================================================
-- PZEMUGamePanel — Extends PZFBInputPanel for emulator display
-- ============================================================================

PZEMUGamePanel = PZFBInputPanel:derive("PZEMUGamePanel")

function PZEMUGamePanel:new(x, y, w, h)
    local o = PZFBInputPanel.new(self, x, y, w, h, {
        mode                  = PZFBInput.MODE_FOCUS,
        captureToggleKey      = Keyboard.KEY_SCROLL,
        escapeCloses          = false,
        escapeReleasesCapture = true,
        forceCursorVisible    = true,
        autoGrab              = false,
    })
    o.game = nil
    return o
end

function PZEMUGamePanel:setGame(game)
    self.game = game
end

function PZEMUGamePanel:onPZFBKeyDown(key)
    if self.game then
        self.game:sendKey(key, 1)
    end
end

function PZEMUGamePanel:onPZFBKeyUp(key)
    if self.game then
        self.game:sendKey(key, 0)
    end
end

function PZEMUGamePanel:onPZFBCaptureToggle(active)
    if not active and self.game then
        -- Freeze emulation when releasing capture (meta-command 18)
        PZFB.gameSendInput(18, 1)
        PZFB.gameSendInput(18, 0)
    end
end

-- ---------- gamepad support ----------

function PZEMUGamePanel:onPZFBGamepadDown(slot, button)
    if self.game then
        self.game:sendGamepadButton(button, 1)
    end
end

function PZEMUGamePanel:onPZFBGamepadUp(slot, button)
    if self.game then
        self.game:sendGamepadButton(button, 0)
    end
end

-- Analog stick -> D-pad conversion for consoles without analog support
local STICK_DEADZONE = 0.5
local stickState = { left = 0, right = 0, up = 0, down = 0 }

function PZEMUGamePanel:onPZFBGamepadAxis(slot, name, value)
    if not self.game then return end

    -- Only use left stick for D-pad
    if name == "leftX" then
        local wasLeft = stickState.left
        local wasRight = stickState.right
        stickState.left  = (value < -STICK_DEADZONE) and 1 or 0
        stickState.right = (value >  STICK_DEADZONE) and 1 or 0
        if stickState.left ~= wasLeft then
            self.game:sendGamepadButton(Joypad.DPadLeft, stickState.left)
        end
        if stickState.right ~= wasRight then
            self.game:sendGamepadButton(Joypad.DPadRight, stickState.right)
        end
    elseif name == "leftY" then
        local wasUp = stickState.up
        local wasDown = stickState.down
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

function PZEMUGamePanel:render()
    PZFBInputPanel.render(self)
    local game = self.game
    if not game then return end

    game:update()

    if game.state == "STARTING" then
        self:drawText("Starting emulator...", 10, 10, 1, 1, 1, 0.8, UIFont.Medium)
        return
    elseif game.state == "ERROR" then
        self:drawText("Error: " .. (game.errorMsg or "unknown"), 10, 10, 1, 0.3, 0.3, 0.9, UIFont.Small)
        return
    elseif game.state == "STOPPED" then
        self:drawText("Emulator has exited.", 10, 10, 0.7, 0.7, 0.7, 0.8, UIFont.Medium)
        return
    end

    -- Draw framebuffer with aspect-correct scaling + letterboxing
    if game.fb and PZFB.isReady(game.fb) then
        local cw = game.console.width
        local ch = game.console.height
        local scaleX = self.width / cw
        local scaleY = self.height / ch
        local scale = math.min(scaleX, scaleY)
        local drawW = math.floor(cw * scale)
        local drawH = math.floor(ch * scale)
        local drawX = math.floor((self.width - drawW) / 2)
        local drawY = math.floor((self.height - drawH) / 2)

        -- Black letterbox/pillarbox bars
        if drawX > 0 then
            self:drawRect(0, 0, drawX, self.height, 1, 0, 0, 0)
            self:drawRect(drawX + drawW, 0, self.width - drawX - drawW, self.height, 1, 0, 0, 0)
        end
        if drawY > 0 then
            self:drawRect(0, 0, self.width, drawY, 1, 0, 0, 0)
            self:drawRect(0, drawY + drawH, self.width, self.height - drawY - drawH, 1, 0, 0, 0)
        end

        -- drawTextureScaled(tex, x, y, w, h, a, r, g, b) — alpha BEFORE rgb
        self:drawTextureScaled(PZFB.getTexture(game.fb), drawX, drawY, drawW, drawH, 1, 1, 1, 1)
    end

    -- Input capture hint
    if self:isCapturing() then
        local hint = "[Scroll Lock: lock input] [ESC: freeze]"
        self:drawText(hint, 4, self.height - getTextManager():getFontHeight(UIFont.Small) - 4,
                      0.6, 0.6, 0.6, 0.4, UIFont.Small)
    end
end

-- ============================================================================
-- PZEMUGamePicker — Cartridge-based game selection panel
-- ============================================================================

PZEMUGamePicker = ISPanel:derive("PZEMUGamePicker")

function PZEMUGamePicker:new(x, y, w, h, onSelect)
    local o = ISPanel.new(self, x, y, w, h)
    o.onSelect = onSelect
    o.buttons = {}
    o.cartridgeList = {}
    o.console = nil
    o.missingRomName = nil
    return o
end

function PZEMUGamePicker:createChildren()
    ISPanel.createChildren(self)
end

function PZEMUGamePicker:refresh(console, cartridgeList)
    self.console = console
    self.cartridgeList = cartridgeList or {}
    self.missingRomName = nil

    -- Remove old buttons
    for _, btn in ipairs(self.buttons) do
        self:removeChild(btn)
    end
    self.buttons = {}

    local yOff = 50
    for i, cart in ipairs(self.cartridgeList) do
        local label = cart.gameName or "Unknown Game"
        local btn = ISButton:new(20, yOff, self.width - 40, 28, label, self, PZEMUGamePicker.onGameClick)
        btn:initialise()
        btn:instantiate()
        btn.internal = "GAME_" .. tostring(i)
        btn.gameIndex = i
        btn.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 0.6 }
        btn.backgroundColor = { r = 0.1, g = 0.1, b = 0.15, a = 0.8 }
        btn.textColor = { r = 0.9, g = 0.9, b = 0.9, a = 1.0 }
        self:addChild(btn)
        table.insert(self.buttons, btn)
        yOff = yOff + 32
    end
end

function PZEMUGamePicker:onGameClick(button)
    local cart = self.cartridgeList[button.gameIndex]
    if not cart then return end

    -- Resolve ROM path
    local romPath = resolveRomPath(self.console, cart.romFile)
    if romPath then
        self.missingRomName = nil
        if self.onSelect then
            self.onSelect(romPath)
        end
    else
        -- ROM not found — show message
        self.missingRomName = cart.romFile
    end
end

function PZEMUGamePicker:prerender()
    ISPanel.prerender(self)
    self:drawRect(0, 0, self.width, self.height, 0.95, 0.05, 0.05, 0.08)
end

function PZEMUGamePicker:render()
    ISPanel.render(self)

    local consoleName = self.console and self.console.displayName or "?"
    local title = consoleName .. " — Select a Game"
    self:drawText(title, 20, 12, 1, 1, 1, 0.9, UIFont.Medium)

    if #self.cartridgeList == 0 then
        self:drawText("No cartridges found nearby.", 20, 60, 0.8, 0.6, 0.6, 0.8, UIFont.Small)
    end

    if self.missingRomName then
        local y = self.height - 80
        self:drawText("ROM not found:", 20, y, 1, 0.4, 0.4, 0.9, UIFont.Small)
        self:drawText(self.missingRomName, 20, y + 18, 0.5, 0.7, 0.5, 0.8, UIFont.Small)
        local sep = getFileSeparator()
        local romDir = getUserDir() .. sep .. "roms" .. sep .. (self.console and self.console.romDir or "")
        self:drawText("Place ROM in: " .. romDir, 20, y + 36, 0.5, 0.5, 0.5, 0.7, UIFont.Small)
    end
end

-- ============================================================================
-- PZEMUWelcome — Instructions panel (console-specific controls)
-- ============================================================================

PZEMUWelcome = ISPanel:derive("PZEMUWelcome")

function PZEMUWelcome:new(x, y, w, h, onDismiss)
    local o = ISPanel.new(self, x, y, w, h)
    o.onDismiss = onDismiss
    o.tickCount = 0
    o.console = nil
    return o
end

function PZEMUWelcome:setConsole(console)
    self.console = console
end

function PZEMUWelcome:onMouseDown(x, y)
    if self.onDismiss then
        self.onDismiss()
    end
    return true
end

function PZEMUWelcome:prerender()
    ISPanel.prerender(self)
    self:drawRect(0, 0, self.width, self.height, 0.95, 0.05, 0.05, 0.08)
end

function PZEMUWelcome:render()
    ISPanel.render(self)
    self.tickCount = self.tickCount + 1

    local cx = self.width / 2
    local y = 30

    -- Title
    local consoleName = self.console and self.console.displayName or "Emulator"
    local title = consoleName .. " Emulator"
    local titleW = getTextManager():MeasureStringX(UIFont.Large, title)
    self:drawText(title, cx - titleW / 2, y, 1, 1, 1, 0.95, UIFont.Large)
    y = y + 40

    -- Console-specific controls
    if self.console and self.console.controlHints then
        for _, line in ipairs(self.console.controlHints) do
            local lineW = getTextManager():MeasureStringX(UIFont.Small, line)
            self:drawText(line, cx - lineW / 2, y, 0.8, 0.8, 0.8, 0.8, UIFont.Small)
            y = y + 20
        end
    end

    -- Common controls
    y = y + 10
    local common = {
        "Gamepad supported (left stick = D-pad)",
        "",
        "ESC  =  Freeze / unfreeze emulation",
        "F5  =  Save state    F7  =  Load state",
        "Scroll Lock  =  Lock/unlock input",
    }
    for _, line in ipairs(common) do
        local lineW = getTextManager():MeasureStringX(UIFont.Small, line)
        self:drawText(line, cx - lineW / 2, y, 0.6, 0.7, 0.6, 0.7, UIFont.Small)
        y = y + 20
    end

    -- Pulsing "Click to play" prompt
    y = y + 20
    local alpha = 0.4 + 0.4 * math.sin(self.tickCount * 0.05)
    local prompt = "Click anywhere to start"
    local promptW = getTextManager():MeasureStringX(UIFont.Medium, prompt)
    self:drawText(prompt, cx - promptW / 2, y, 0.5, 1, 0.5, alpha, UIFont.Medium)
end

-- ============================================================================
-- PZEMUWindow — Main window (singleton)
-- ============================================================================

PZEMUWindow = ISCollapsableWindow:derive("PZEMUWindow")

PZEMUWindow.instance = nil

function PZEMUWindow:createChildren()
    ISCollapsableWindow.createChildren(self)

    local th = self:titleBarHeight()
    local rh = self:resizeWidgetHeight()
    local panelW = self.width
    local panelH = self.height - th

    self.game = nil
    self.selectedConsole = nil
    self.pendingRomPath = nil

    -- Game picker (visible initially when opened via openWithContext)
    self.gamePicker = PZEMUGamePicker:new(0, th, panelW, panelH, function(romPath)
        self:onGameSelected(romPath)
    end)
    self.gamePicker.anchorLeft = true
    self.gamePicker.anchorRight = true
    self.gamePicker.anchorTop = true
    self.gamePicker.anchorBottom = true
    self.gamePicker:initialise()
    self.gamePicker:instantiate()
    self.gamePicker:setVisible(false)
    self:addChild(self.gamePicker)

    -- Welcome panel (hidden)
    self.welcomePanel = PZEMUWelcome:new(0, th, panelW, panelH, function()
        self:onWelcomeDismissed()
    end)
    self.welcomePanel.anchorLeft = true
    self.welcomePanel.anchorRight = true
    self.welcomePanel.anchorTop = true
    self.welcomePanel.anchorBottom = true
    self.welcomePanel:initialise()
    self.welcomePanel:instantiate()
    self.welcomePanel:setVisible(false)
    self:addChild(self.welcomePanel)

    -- Game panel (hidden)
    self.gamePanel = PZEMUGamePanel:new(0, th, panelW, panelH - rh)
    self.gamePanel.anchorLeft = true
    self.gamePanel.anchorRight = true
    self.gamePanel.anchorTop = true
    self.gamePanel.anchorBottom = true
    self.gamePanel:initialise()
    self.gamePanel:instantiate()
    self.gamePanel:setVisible(false)
    self:addChild(self.gamePanel)

    -- CRITICAL: bring resize widgets to top after all addChild calls (AVOID.md #11)
    if self.resizeWidget then self.resizeWidget:bringToTop() end
    if self.resizeWidget2 then self.resizeWidget2:bringToTop() end
end

function PZEMUWindow:setupConsole(console)
    self.selectedConsole = console
    self.game = PZEMUGame:new(console)
    self.gamePanel:setGame(self.game)
    self:setTitle(console.displayName .. " Emulator")
end

function PZEMUWindow:onGameSelected(romPath)
    self.pendingRomPath = romPath
    self.gamePicker:setVisible(false)
    self.welcomePanel:setConsole(self.selectedConsole)
    self.welcomePanel:setVisible(true)
end

function PZEMUWindow:onWelcomeDismissed()
    self.welcomePanel:setVisible(false)
    self.gamePanel:setVisible(true)
    self.game:start(self.pendingRomPath)
    self.gamePanel:grabInput()
end

function PZEMUWindow:close()
    if self.game then
        self.game:stop()
    end
    if self.gamePanel then
        self.gamePanel:releaseInput()
    end
    PZEMUWindow.instance = nil
    ISCollapsableWindow.close(self)
end

-- ============================================================================
-- Public openers — called from PZEMUMain context menu callbacks
-- ============================================================================

local function createWindow()
    if PZEMUWindow.instance then
        PZEMUWindow.instance:close()
    end

    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local w = 660
    local h = 540
    local x = math.floor((screenW - w) / 2)
    local y = math.floor((screenH - h) / 2)

    local window = PZEMUWindow:new(x, y, w, h)
    window.minimumWidth = 340
    window.minimumHeight = 280
    window:initialise()
    window:instantiate()
    window:setResizable(true)
    window:addToUIManager()

    PZEMUWindow.instance = window
    return window
end

-- Open with game picker showing available cartridges
function PZEMUWindow.openWithContext(console, cartridgeList)
    local window = createWindow()
    window:setupConsole(console)
    window.gamePicker:refresh(console, cartridgeList)
    window.gamePicker:setVisible(true)
end

-- Open directly to a specific game (from cartridge right-click)
function PZEMUWindow.openWithGame(console, gameData)
    local romPath = resolveRomPath(console, gameData.romFile)
    if not romPath then
        -- Fall back to game picker with just this one game
        PZEMUWindow.openWithContext(console, { gameData })
        return
    end

    local window = createWindow()
    window:setupConsole(console)
    window.pendingRomPath = romPath
    window.welcomePanel:setConsole(console)
    window.welcomePanel:setVisible(true)
end
