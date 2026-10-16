--
-- PZEMUWindow.lua — Emulator UI: game picker, welcome screen, game panel,
--                   volume bar, key-binding editor, first-run notice
--
-- Classes:
--   PZEMUGamePanel     — PZFBInputPanel subclass for emulator display + input
--   PZEMUVolumeBar     — slim bar under the screen: - / + / Mute + current volume
--   PZEMUGamePicker    — cartridge-based game selection list (+ Controls button)
--   PZEMUWelcome       — controls summary (from the live bindings), click to start
--   PZEMUControlsPanel — per-console key binding editor (click a key, press a key)
--   PZEMUNoticePanel   — one-time "bring your own ROMs" notice
--   PZEMUBootPanel     — optional cartridge-blowing flavour (sandbox option)
--   PZEMUWindow        — main ISCollapsableWindow (singleton via PZEMUWindow.instance)
--
-- FYI: "Literally Playable Video Game Consoles" (a separate ZombieBuddy-based mod)
-- constructs and wraps several of these classes and replaces PZEMUMain.lua /
-- PZEMU_Distributions.lua. It is NOT supported (Adam, 2026-10-15): there is no
-- obligation to keep it working. Panels added here start hidden and the
-- window-level layout code only runs for windows created by our own createWindow()
-- (window.pzemuManaged == true).
--

require "PZFB/PZFBInput"
require "PZEMU/PZEMUSettings"
require "PZEMU/PZEMUBindings"
require "PZEMU/PZEMUGame"

-- Helper: user data directory
local function getUserDir()
    return Core.getMyDocumentFolder() .. getFileSeparator() .. "PZEMU"
end

local VOLUME_BAR_HEIGHT = 24
local VOLUME_FLASH_MS   = 1800

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

-- Strip common Latin-1 diacritics. Kahlua strings are Java UTF-16 — each
-- accented char (é, ñ, etc.) is a SINGLE 16-bit code unit, not a UTF-8 byte
-- pair. Keys are the Latin-1 supplement code points (U+00E0..U+00FC, U+00F1,
-- U+00E7). Kahlua's string.char(n) appends (char)n to a StringBuilder, so
-- string.char(0xe9) yields the single UTF-16 char é (verified in
-- se/krka/kahlua/stdlib/StringLib.class stringChar bytecode).
-- Covers accented vowels and ñ/ç common in game titles (Pokémon, Señor, etc.)
local DIACRITIC_MAP = {
    [string.char(0xe1)]="a", [string.char(0xe0)]="a", [string.char(0xe2)]="a",
    [string.char(0xe3)]="a", [string.char(0xe4)]="a", [string.char(0xe5)]="a",
    [string.char(0xe9)]="e", [string.char(0xe8)]="e", [string.char(0xea)]="e",
    [string.char(0xeb)]="e", [string.char(0xed)]="i", [string.char(0xec)]="i",
    [string.char(0xee)]="i", [string.char(0xef)]="i", [string.char(0xf3)]="o",
    [string.char(0xf2)]="o", [string.char(0xf4)]="o", [string.char(0xf5)]="o",
    [string.char(0xf6)]="o", [string.char(0xfa)]="u", [string.char(0xf9)]="u",
    [string.char(0xfb)]="u", [string.char(0xfc)]="u", [string.char(0xf1)]="n",
    [string.char(0xe7)]="c",
}
local function stripDiacritics(s)
    for ch, repl in pairs(DIACRITIC_MAP) do
        s = string.gsub(s, ch, repl)
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
    -- NOTE: single-char string.char values here are UTF-16 code units, not UTF-8 byte
    -- sequences, matching Kahlua's Java-backed string representation.
    name = string.gsub(name, "'",                "")
    name = string.gsub(name, string.char(0x2019),"")
    name = string.gsub(name, ",",                "")
    -- Strip internal periods (like "Bros." -> "Bros")
    name = string.gsub(name, "%.", "")
    -- Normalize separator variants: hyphens -> underscore, em/en-dash, colons
    name = string.gsub(name, "%s*[%-]+%s*",      "_")
    name = string.gsub(name, string.char(0x2013),"_")  -- en-dash U+2013
    name = string.gsub(name, string.char(0x2014),"_")  -- em-dash U+2014
    name = string.gsub(name, "%s*:%s*",          "_")
    -- Collapse runs of underscores/spaces
    name = string.gsub(name, "[_%s]+", "_")
    -- Lowercase for case-insensitive matching
    name = string.lower(name)
    -- Strip common diacritics (after lowercase so only the lowercase Latin-1
    -- supplement code points need to be mapped — U+00E0..U+00FC + U+00F1/U+00E7)
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

-- Release a PZFBInputPanel completely (contract C3 with a 1.7.x fallback).
local function cleanupInputPanel(panel)
    if not panel then return end
    if panel.cleanup then
        panel:cleanup()
    else
        panel:releaseInput()
        if panel._removeEventListeners then
            panel:_removeEventListeners()
        end
    end
end

-- Small styled button factory (ISButton onclick is called (target, button, ...))
local function makeButton(parent, x, y, w, h, label, onclick, tooltip)
    local btn = ISButton:new(x, y, w, h, label, parent, onclick)
    btn:initialise()
    btn:instantiate()
    btn.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 0.7 }
    btn.backgroundColor = { r = 0.12, g = 0.12, b = 0.18, a = 0.9 }
    btn.backgroundColorMouseOver = { r = 0.25, g = 0.25, b = 0.35, a = 0.9 }
    btn.textColor = { r = 0.9, g = 0.9, b = 0.9, a = 1.0 }
    if tooltip then btn:setTooltip(tooltip) end
    parent:addChild(btn)
    return btn
end

local function fontH(font)
    return getTextManager():getFontHeight(font)
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
    o.volumeFlashUntil = 0
    o.volumeFlashText = nil
    return o
end

function PZEMUGamePanel:setGame(game)
    self.game = game
end

-- Volume keys: - / = / M (reserved, never part of a console key map).
function PZEMUGamePanel:isVolumeKey(key)
    return key == Keyboard.KEY_MINUS or key == Keyboard.KEY_EQUALS or key == Keyboard.KEY_M
end

--- dir: -1 / +1 steps the volume, 0 toggles mute. Persists and pushes to the bridge.
function PZEMUGamePanel:changeVolume(dir)
    if not PZEMUSettings then return end
    local text
    if dir == 0 then
        local muted = PZEMUSettings.toggleMute()
        text = muted and "Muted" or ("Volume " .. tostring(PZEMUSettings.getVolume()) .. "%")
    else
        local v = PZEMUSettings.stepVolume(dir)
        text = "Volume " .. tostring(v) .. "%"
    end
    if self.game and self.game.sendVolume then
        self.game:sendVolume()
    end
    self.volumeFlashText = text
    self.volumeFlashUntil = getTimestampMs() + VOLUME_FLASH_MS
end

function PZEMUGamePanel:onPZFBKeyDown(key)
    if key == Keyboard.KEY_MINUS then
        self:changeVolume(-1)
        return
    elseif key == Keyboard.KEY_EQUALS then
        self:changeVolume(1)
        return
    elseif key == Keyboard.KEY_M then
        self:changeVolume(0)
        return
    end
    if self.game then
        self.game:sendKey(key, 1)
    end
end

function PZEMUGamePanel:onPZFBKeyUp(key)
    if self:isVolumeKey(key) then return end
    if self.game then
        self.game:sendKey(key, 0)
    end
end

function PZEMUGamePanel:onPZFBCaptureToggle(active)
    if not active and self.game then
        -- Releasing the Scroll Lock capture: explicit PAUSE ON (C4 keycode 19),
        -- never the toggle — unlocking an already-frozen game must not unfreeze it.
        self.game:sendPause(true)
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

-- Analog forwarding for analog-capable consoles (console.analog == true);
-- D-pad emulation fallback for digital-only consoles (existing behavior preserved).
local STICK_DEADZONE = 0.5
local AXIS_NAME_TO_ID = { leftX = 0, leftY = 1, rightX = 2, rightY = 3 }
local stickState = { left = 0, right = 0, up = 0, down = 0 }

function PZEMUGamePanel:onPZFBGamepadAxis(slot, name, value)
    if not self.game then return end

    -- Console supports analog (e.g. PSX/PSP/N64 added by user): forward the raw axis value
    if self.game.console and self.game.console.analog then
        local axisId = AXIS_NAME_TO_ID[name]
        if axisId then
            self.game:sendGamepadAxis(axisId, value)
        end
        return
    end

    -- Digital-only consoles: emulate D-pad from left stick (existing behavior, untouched)
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
    elseif game.state == "LOST" then
        self:drawText("Another mod took over the emulator.", 10, 10, 1, 0.6, 0.3, 0.9, UIFont.Medium)
        self:drawText("Close this window and start the game again.", 10, 10 + fontH(UIFont.Medium) + 4,
                      0.8, 0.8, 0.8, 0.8, UIFont.Small)
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

    -- Dead handheld batteries: dim the screen and explain how to continue
    if game.batteryDead then
        self:drawRect(0, 0, self.width, self.height, 0.75, 0, 0, 0)
        local title = "BATTERIES DEAD"
        local tw = getTextManager():MeasureStringX(UIFont.Large, title)
        local cy = math.floor(self.height / 2) - 30
        self:drawText(title, math.floor((self.width - tw) / 2), cy, 1, 0.35, 0.35, 1, UIFont.Large)
        local consoleName = (game.console and game.console.displayName) or "handheld"
        local lines = {
            "Insert a fresh battery into the " .. consoleName .. ":",
            "right-click it in your inventory -> Insert Battery.",
            "The game resumes automatically.",
        }
        local y = cy + fontH(UIFont.Large) + 8
        for _, line in ipairs(lines) do
            local lw = getTextManager():MeasureStringX(UIFont.Small, line)
            self:drawText(line, math.floor((self.width - lw) / 2), y, 0.9, 0.9, 0.9, 0.9, UIFont.Small)
            y = y + fontH(UIFont.Small) + 2
        end
    end

    -- Volume change feedback (brief)
    if self.volumeFlashText and getTimestampMs() < self.volumeFlashUntil then
        local tw = getTextManager():MeasureStringX(UIFont.Medium, self.volumeFlashText)
        local x = self.width - tw - 12
        local h = fontH(UIFont.Medium)
        self:drawRect(x - 6, 6, tw + 12, h + 6, 0.6, 0, 0, 0)
        self:drawText(self.volumeFlashText, x, 9, 1, 1, 1, 0.95, UIFont.Medium)
    end

    -- Input capture hint (+ battery level for handhelds)
    if self:isCapturing() then
        local hint = "[Scroll Lock: lock input] [ESC: freeze] [- / =: volume] [M: mute]"
        if game.batteryItem then
            -- batteryLevel() includes the fractional drain not yet stepped off the
            -- item, so the % moves smoothly instead of once per whole use.
            local ok, level = pcall(function()
                if game.batteryLevel then return game:batteryLevel() end
                return game.batteryItem:getCurrentUsesFloat()
            end)
            if ok and type(level) == "number" then
                hint = hint .. "  Battery " .. tostring(math.floor(level * 100 + 0.5)) .. "%"
            end
        end
        self:drawText(hint, 4, self.height - fontH(UIFont.Small) - 4,
                      0.6, 0.6, 0.6, 0.4, UIFont.Small)
    end
end

-- ============================================================================
-- PZEMUVolumeBar — slim control strip under the emulator screen
-- ============================================================================

PZEMUVolumeBar = ISPanel:derive("PZEMUVolumeBar")

function PZEMUVolumeBar:new(x, y, w, h, window)
    local o = ISPanel.new(self, x, y, w, h)
    o.window = window
    o.backgroundColor = { r = 0.05, g = 0.05, b = 0.08, a = 0.95 }
    o.borderColor = { r = 0.3, g = 0.3, b = 0.3, a = 0.6 }
    return o
end

function PZEMUVolumeBar:createChildren()
    ISPanel.createChildren(self)
    local bh = self.height - 4
    self.btnDown = makeButton(self, 4, 2, 26, bh, "-", PZEMUVolumeBar.onDown, "Volume down (- key)")
    self.btnUp   = makeButton(self, 34, 2, 26, bh, "+", PZEMUVolumeBar.onUp, "Volume up (= key)")
    self.btnMute = makeButton(self, 64, 2, 56, bh, "Mute", PZEMUVolumeBar.onMute, "Mute / unmute (M key)")
end

function PZEMUVolumeBar:gamePanel()
    return self.window and self.window.gamePanel
end

function PZEMUVolumeBar.onDown(self, button)
    local gp = self:gamePanel()
    if gp then gp:changeVolume(-1) end
end

function PZEMUVolumeBar.onUp(self, button)
    local gp = self:gamePanel()
    if gp then gp:changeVolume(1) end
end

function PZEMUVolumeBar.onMute(self, button)
    local gp = self:gamePanel()
    if gp then gp:changeVolume(0) end
end

function PZEMUVolumeBar:render()
    ISPanel.render(self)
    if not PZEMUSettings then return end
    local muted = PZEMUSettings.isMuted()
    local vol = PZEMUSettings.getVolume()
    if self.btnMute then
        self.btnMute:setTitle(muted and "Unmute" or "Mute")
    end
    local text = muted and ("Muted (" .. tostring(vol) .. "%)") or ("Volume " .. tostring(vol) .. "%")
    local y = math.floor((self.height - fontH(UIFont.Small)) / 2)
    self:drawText(text, 130, y, 0.9, 0.9, 0.9, 0.9, UIFont.Small)
    -- 10-segment meter
    local mx = 130 + getTextManager():MeasureStringX(UIFont.Small, "Volume 100%") + 12
    local segW = 8
    local segH = self.height - 10
    for i = 1, 10 do
        local on = (not muted) and (vol >= i * 10)
        local c = on and 0.75 or 0.2
        self:drawRect(mx + (i - 1) * (segW + 2), 5, segW, segH, 1, c, c, c)
    end
    local keys = "keys: -  =  M"
    local kw = getTextManager():MeasureStringX(UIFont.Small, keys)
    self:drawText(keys, self.width - kw - 8, y, 0.5, 0.5, 0.5, 0.8, UIFont.Small)
end

-- ============================================================================
-- PZEMUGamePicker — Cartridge-based game selection panel
-- ============================================================================

PZEMUGamePicker = ISPanel:derive("PZEMUGamePicker")

function PZEMUGamePicker:new(x, y, w, h, onSelect, onControls)
    local o = ISPanel.new(self, x, y, w, h)
    o.onSelect = onSelect
    o.onControls = onControls
    o.buttons = {}          -- kept for compatibility (no longer used for rows)
    o.cartridgeList = {}
    o.console = nil
    o.missingRomName = nil
    return o
end

function PZEMUGamePicker:createChildren()
    ISPanel.createChildren(self)
    local listY = 44
    local footer = 96
    self.listBox = ISScrollingListBox:new(16, listY, self.width - 32, self.height - listY - footer)
    self.listBox.anchorLeft = true
    self.listBox.anchorRight = true
    self.listBox.anchorTop = true
    self.listBox.anchorBottom = true
    self.listBox:initialise()
    self.listBox:instantiate()
    self.listBox:setFont(UIFont.Small, 6)
    self.listBox.drawBorder = true
    self.listBox:setOnMouseDownFunction(self, PZEMUGamePicker.onListClick)
    self:addChild(self.listBox)

    self.controlsButton = makeButton(self, 16, self.height - 34, 110, 26, "Controls...",
        PZEMUGamePicker.onControlsClick, "Remap the keyboard controls for this console")
    self.controlsButton.anchorTop = false
    self.controlsButton.anchorBottom = true
end

function PZEMUGamePicker:refresh(console, cartridgeList)
    self.console = console
    self.cartridgeList = cartridgeList or {}
    self.missingRomName = nil

    if self.listBox then
        self.listBox:clear()
        for i, cart in ipairs(self.cartridgeList) do
            local label = cart.gameName or "Unknown Game"
            self.listBox:addItem(label, { index = i })
        end
    end
end

-- ISScrollingListBox callback: (target, item) where item is what we passed to addItem
function PZEMUGamePicker.onListClick(self, item)
    if not item or not item.index then return end
    -- Keep the historical entry point (third-party mods wrap onGameClick(button)).
    self:onGameClick({ gameIndex = item.index })
end

function PZEMUGamePicker.onControlsClick(self, button)
    if self.onControls then self.onControls() end
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
    self:drawText(title, 16, 12, 1, 1, 1, 0.9, UIFont.Medium)

    if #self.cartridgeList == 0 then
        self:drawText("No cartridges found nearby.", 20, 60, 0.8, 0.6, 0.6, 0.8, UIFont.Small)
    end

    if self.missingRomName then
        local y = self.height - 90
        self:drawText("ROM not found:", 140, y, 1, 0.4, 0.4, 0.9, UIFont.Small)
        self:drawText(self.missingRomName, 140, y + 18, 0.5, 0.7, 0.5, 0.8, UIFont.Small)
        local sep = getFileSeparator()
        local romDir = getUserDir() .. sep .. "roms" .. sep .. (self.console and self.console.romDir or "")
        self:drawText("Place your legally obtained ROM in: " .. romDir, 140, y + 36, 0.5, 0.5, 0.5, 0.7, UIFont.Small)
        self:drawText("Close-enough file names are matched automatically (region tags, dashes, roman numerals).",
                      140, y + 54, 0.5, 0.5, 0.5, 0.7, UIFont.Small)
    end
end

-- ============================================================================
-- PZEMUWelcome — Instructions panel (controls from the live bindings)
-- ============================================================================

PZEMUWelcome = ISPanel:derive("PZEMUWelcome")

function PZEMUWelcome:new(x, y, w, h, onDismiss, onControls)
    local o = ISPanel.new(self, x, y, w, h)
    o.onDismiss = onDismiss
    o.onControls = onControls
    o.tickCount = 0
    o.console = nil
    o.controlLines = nil
    return o
end

function PZEMUWelcome:createChildren()
    ISPanel.createChildren(self)
    self.controlsButton = makeButton(self, self.width - 126, 10, 110, 26, "Controls...",
        PZEMUWelcome.onControlsClick, "Remap the keyboard controls for this console")
    self.controlsButton.anchorLeft = false
    self.controlsButton.anchorRight = true
end

function PZEMUWelcome.onControlsClick(self, button)
    if self.onControls then self.onControls() end
end

--- controlLines: optional list of "Button  =  Key" strings; falls back to the
--- console's static controlHints when nil.
function PZEMUWelcome:setConsole(console, controlLines)
    self.console = console
    self.controlLines = controlLines
end

function PZEMUWelcome:onMouseDown(x, y)
    -- Clicks on the Controls button belong to the button, not to "start".
    if self.controlsButton and self.controlsButton:isMouseOver() then
        return true
    end
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
    local lines = self.controlLines
    if (not lines or #lines == 0) and self.console and self.console.controlHints then
        lines = self.console.controlHints
    end
    local lineH = fontH(UIFont.Small) + 2
    if lines then
        -- two columns when there are many buttons (SNES, Genesis)
        local cols = (#lines > 8) and 2 or 1
        local rows = math.ceil(#lines / cols)
        local colW = (self.width - 40) / cols
        for i, line in ipairs(lines) do
            local col = math.floor((i - 1) / rows)
            local row = (i - 1) - col * rows
            local lineW = getTextManager():MeasureStringX(UIFont.Small, line)
            local lx = 20 + col * colW + (colW - lineW) / 2
            self:drawText(line, lx, y + row * lineH, 0.8, 0.8, 0.8, 0.8, UIFont.Small)
        end
        y = y + rows * lineH
    end

    -- Common controls
    y = y + 10
    local common = {
        "Gamepad supported (left stick = D-pad)",
        "",
        "ESC  =  Freeze / unfreeze emulation",
        "F5  =  Save state    F7  =  Load state",
        "Scroll Lock  =  Lock / unlock input (unlocking freezes the game)",
        "-  /  =  =  Volume down / up        M  =  Mute",
    }
    for _, line in ipairs(common) do
        local lineW = getTextManager():MeasureStringX(UIFont.Small, line)
        self:drawText(line, cx - lineW / 2, y, 0.6, 0.7, 0.6, 0.7, UIFont.Small)
        y = y + lineH
    end

    -- Pulsing "Click to play" prompt
    y = y + 16
    local alpha = 0.4 + 0.4 * math.sin(self.tickCount * 0.05)
    local prompt = "Click anywhere to start"
    local promptW = getTextManager():MeasureStringX(UIFont.Medium, prompt)
    self:drawText(prompt, cx - promptW / 2, y, 0.5, 1, 0.5, alpha, UIFont.Medium)
end

-- ============================================================================
-- PZEMUControlsPanel — per-console key binding editor
-- Derives from PZFBInputPanel (EXCLUSIVE) so that, while waiting for a key, the
-- pressed key is consumed instead of moving the player.
-- ============================================================================

PZEMUControlsPanel = PZFBInputPanel:derive("PZEMUControlsPanel")

function PZEMUControlsPanel:new(x, y, w, h, onBack)
    local o = PZFBInputPanel.new(self, x, y, w, h, {
        mode                  = PZFBInput.MODE_EXCLUSIVE,
        captureToggleKey      = nil,
        escapeCloses          = false,
        escapeReleasesCapture = false,
        forceCursorVisible    = true,
        autoGrab              = false,
    })
    o.onBack = onBack
    o.console = nil
    o.bindings = {}
    o.rows = {}
    o.capturing = nil
    o.status = ""
    o.statusColor = { 0.7, 0.9, 0.7 }
    o._lastW, o._lastH = 0, 0
    return o
end

function PZEMUControlsPanel:createChildren()
    PZFBInputPanel.createChildren(self)
    local bw = 120
    local by = self.height - 34
    self.presetButton = makeButton(self, 16, by, bw, 26, "WASD preset", PZEMUControlsPanel.onPreset,
        PZEMUBindings and PZEMUBindings.PRESET_WASD_DESCRIPTION or nil)
    self.resetButton = makeButton(self, 16 + bw + 8, by, bw, 26, "Reset defaults", PZEMUControlsPanel.onReset,
        "Restore the default keys (arrows + Z/X/C...) for this console")
    self.backButton = makeButton(self, self.width - 16 - 90, by, 90, 26, "Back", PZEMUControlsPanel.onBackClick)
    for _, b in ipairs({ self.presetButton, self.resetButton, self.backButton }) do
        b.anchorTop = false
        b.anchorBottom = true
    end
    self.backButton.anchorLeft = false
    self.backButton.anchorRight = true
end

function PZEMUControlsPanel:setConsole(console)
    self.console = console
    self.bindings = {}
    if PZEMUBindings and console then
        local cur = PZEMUBindings.get(console.id)
        if cur then
            for bid, keys in pairs(cur) do
                local copy = {}
                for i, k in ipairs(keys) do copy[i] = k end
                self.bindings[bid] = copy
            end
        end
    end
    self:cancelCapture()
    self.status = "Click a key to change it. Keys you pick are taken from other buttons automatically."
    self.statusColor = { 0.7, 0.7, 0.7 }
    self:rebuildRows()
end

function PZEMUControlsPanel:clearRows()
    for _, row in ipairs(self.rows) do
        if row.btn1 then self:removeChild(row.btn1) end
        if row.btn2 then self:removeChild(row.btn2) end
    end
    self.rows = {}
end

function PZEMUControlsPanel:rowGeometry()
    local n = (self.console and self.console.buttons) and #self.console.buttons or 0
    local top = 44
    local bottom = 44 + 40   -- footer buttons + status line
    local avail = self.height - top - bottom
    local rowH = 26
    if n > 0 and n * rowH > avail then
        rowH = math.max(18, math.floor(avail / n))
    end
    return top, rowH
end

function PZEMUControlsPanel:rebuildRows()
    self:clearRows()
    if not self.console or not self.console.buttons then return end
    local top, rowH = self:rowGeometry()
    local keyX = math.floor(self.width * 0.42)
    local bw = math.min(130, math.floor((self.width - keyX - 24) / 2) - 4)
    local bh = math.max(16, rowH - 4)
    local eff = PZEMUBindings.effectiveKeys(self.console, self.bindings)
    for i, b in ipairs(self.console.buttons) do
        local y = top + (i - 1) * rowH
        local keys = eff[b.id] or {}
        local row = { def = b }
        row.btn1 = makeButton(self, keyX, y, bw, bh, PZEMUBindings.keyName(keys[1]),
            PZEMUControlsPanel.onKeyButton, "Primary key for " .. b.label .. " (click, then press a key)")
        row.btn1.pzBtnId = b.id
        row.btn1.pzSlot = 1
        row.btn2 = makeButton(self, keyX + bw + 8, y, bw, bh, PZEMUBindings.keyName(keys[2]),
            PZEMUControlsPanel.onKeyButton, "Alternate key for " .. b.label .. " (click, then press a key)")
        row.btn2.pzBtnId = b.id
        row.btn2.pzSlot = 2
        table.insert(self.rows, row)
    end
    self._lastW, self._lastH = self.width, self.height
end

function PZEMUControlsPanel:refreshLabels()
    if not self.console or not self.console.buttons then return end
    local eff = PZEMUBindings.effectiveKeys(self.console, self.bindings)
    for _, row in ipairs(self.rows) do
        local keys = eff[row.def.id] or {}
        row.btn1:setTitle(PZEMUBindings.keyName(keys[1]))
        row.btn2:setTitle(PZEMUBindings.keyName(keys[2]))
    end
end

function PZEMUControlsPanel:persist()
    if PZEMUBindings and self.console then
        PZEMUBindings.set(self.console.id, self.bindings)
    end
end

function PZEMUControlsPanel.onKeyButton(self, button)
    if not self.console then return end
    local b = nil
    for _, def in ipairs(self.console.buttons) do
        if def.id == button.pzBtnId then b = def end
    end
    if not b then return end
    self.capturing = { btnId = button.pzBtnId, slot = button.pzSlot, label = b.label }
    self.status = "Press a key for " .. b.label .. "  (ESC cancels, Backspace clears)"
    self.statusColor = { 1.0, 0.9, 0.4 }
    self:grabInput()
end

function PZEMUControlsPanel:cancelCapture()
    self.capturing = nil
    if self._capturing then
        self:releaseInput()
    end
end

function PZEMUControlsPanel:onPZFBKeyDown(key)
    local cap = self.capturing
    if not cap then return end
    if key == Keyboard.KEY_ESCAPE then
        self.status = "Cancelled."
        self.statusColor = { 0.7, 0.7, 0.7 }
        self:cancelCapture()
        return
    end
    if key == Keyboard.KEY_BACK then
        self.bindings = PZEMUBindings.clearSlot(self.console, self.bindings, cap.btnId, cap.slot)
        self:persist()
        self:refreshLabels()
        self.status = "Cleared a key for " .. cap.label .. "."
        self.statusColor = { 0.7, 0.9, 0.7 }
        self:cancelCapture()
        return
    end
    local newBindings, stolen, err = PZEMUBindings.assign(self.console, self.bindings, cap.btnId, cap.slot, key)
    if err then
        self.status = "Cannot use " .. PZEMUBindings.keyName(key) .. ": " .. err
        self.statusColor = { 1.0, 0.5, 0.5 }
        self:cancelCapture()
        return
    end
    self.bindings = newBindings
    self:persist()
    self:refreshLabels()
    self.status = cap.label .. " = " .. PZEMUBindings.keyName(key)
    if stolen then
        self.status = self.status .. "  (taken from " .. stolen .. ")"
    end
    self.statusColor = { 0.7, 0.9, 0.7 }
    self:cancelCapture()
end

function PZEMUControlsPanel:onPZFBKeyUp(key)
end

function PZEMUControlsPanel.onPreset(self, button)
    if not self.console then return end
    local preset = PZEMUBindings.applyPreset(self.console, "wasd")
    if not preset then
        self.status = "No WASD preset for this console."
        self.statusColor = { 1.0, 0.5, 0.5 }
        return
    end
    self.bindings = preset
    self:persist()
    self:refreshLabels()
    self.status = PZEMUBindings.PRESET_WASD_DESCRIPTION
    self.statusColor = { 0.7, 0.9, 0.7 }
end

function PZEMUControlsPanel.onReset(self, button)
    if not self.console then return end
    self.bindings = {}
    self:persist()
    self:refreshLabels()
    self.status = "Defaults restored for " .. self.console.displayName .. "."
    self.statusColor = { 0.7, 0.9, 0.7 }
end

function PZEMUControlsPanel.onBackClick(self, button)
    self:cancelCapture()
    if self.onBack then self.onBack() end
end

function PZEMUControlsPanel:setVisible(visible)
    if not visible then
        self.capturing = nil
    end
    PZFBInputPanel.setVisible(self, visible)
end

function PZEMUControlsPanel:prerender()
    PZFBInputPanel.prerender(self)
    self:drawRect(0, 0, self.width, self.height, 0.95, 0.05, 0.05, 0.08)
    if self.console and (self._lastW ~= self.width or self._lastH ~= self.height) then
        self:rebuildRows()
    end
end

function PZEMUControlsPanel:render()
    PZFBInputPanel.render(self)
    local name = self.console and self.console.displayName or "?"
    self:drawText(name .. " — Controls", 16, 12, 1, 1, 1, 0.9, UIFont.Medium)

    if self.console and self.console.buttons then
        local top, rowH = self:rowGeometry()
        local keyX = math.floor(self.width * 0.42)
        local th = fontH(UIFont.Small)
        self:drawText("Button", 16, top - th - 4, 0.6, 0.6, 0.6, 0.8, UIFont.Small)
        self:drawText("Key / alternate", keyX, top - th - 4, 0.6, 0.6, 0.6, 0.8, UIFont.Small)
        for i, b in ipairs(self.console.buttons) do
            local y = top + (i - 1) * rowH + math.floor((rowH - th) / 2) - 2
            self:drawText(b.label, 16, y, 0.9, 0.9, 0.9, 0.9, UIFont.Small)
        end
    else
        self:drawText("This console has no remappable button list.", 16, 50, 0.8, 0.6, 0.6, 0.9, UIFont.Small)
    end

    -- status + reserved note above the footer buttons
    local th = fontH(UIFont.Small)
    local sy = self.height - 34 - th * 2 - 8
    local c = self.statusColor
    self:drawText(self.status or "", 16, sy, c[1], c[2], c[3], 0.95, UIFont.Small)
    self:drawText("Reserved (cannot be bound): ESC, F5, F7, Scroll Lock, -, =, M.   Arrows remain the default.",
                  16, sy + th + 2, 0.5, 0.5, 0.5, 0.8, UIFont.Small)
end

-- ============================================================================
-- PZEMUNoticePanel — first-run "bring your own ROMs" notice
-- ============================================================================

PZEMUNoticePanel = ISPanel:derive("PZEMUNoticePanel")

function PZEMUNoticePanel:new(x, y, w, h, onAccept)
    local o = ISPanel.new(self, x, y, w, h)
    o.onAccept = onAccept
    return o
end

function PZEMUNoticePanel:createChildren()
    ISPanel.createChildren(self)
    self.okButton = makeButton(self, math.floor((self.width - 160) / 2), self.height - 44, 160, 28,
        "I understand", PZEMUNoticePanel.onOk)
    self.okButton.anchorTop = false
    self.okButton.anchorBottom = true
end

function PZEMUNoticePanel.onOk(self, button)
    if self.onAccept then self.onAccept() end
end

function PZEMUNoticePanel:prerender()
    ISPanel.prerender(self)
    self:drawRect(0, 0, self.width, self.height, 0.97, 0.05, 0.05, 0.08)
end

function PZEMUNoticePanel:render()
    ISPanel.render(self)
    local cx = self.width / 2
    local y = 24
    local title = "Bring your own ROMs"
    local tw = getTextManager():MeasureStringX(UIFont.Large, title)
    self:drawText(title, cx - tw / 2, y, 1, 1, 1, 0.95, UIFont.Large)
    y = y + fontH(UIFont.Large) + 14

    local sep = getFileSeparator()
    local lines = {
        "PZEMU is an emulator. It ships only three free homebrew NES games.",
        "Every other cartridge you find in the world needs a ROM file that YOU supply —",
        "a dump of a cartridge you legally own (we recommend a Retrode for dumping).",
        "",
        "Put ROM files in the system folder under:",
        getUserDir() .. sep .. "roms" .. sep .. "<nes | snes | genesis | gb | atari2600 | gg | sms>",
        "",
        "Selecting a game whose ROM is missing shows the expected file name. Common dump",
        "names are matched automatically (region tags, dashes, roman numerals, articles).",
        "The full list of games, file names and spawn chances is in GAMES.md on GitHub:",
        "https://github.com/expectbugs/pzemu/blob/main/GAMES.md",
    }
    local lh = fontH(UIFont.Small) + 3
    for _, line in ipairs(lines) do
        local lw = getTextManager():MeasureStringX(UIFont.Small, line)
        local x = (lw > self.width - 24) and 12 or (cx - lw / 2)
        self:drawText(line, x, y, 0.85, 0.85, 0.85, 0.9, UIFont.Small)
        y = y + lh
    end
end

-- ============================================================================
-- PZEMUBootPanel — optional cartridge-blowing flavour (SandboxVars.PZEMU.CartridgeBlowing)
-- ============================================================================

PZEMUBootPanel = ISPanel:derive("PZEMUBootPanel")

PZEMUBootPanel.FAIL_CHANCE = 12   -- % of launches that need a blow
PZEMUBootPanel.BLOW_SUCCESS = 65  -- % chance each blow fixes it

function PZEMUBootPanel:new(x, y, w, h, onBooted, onGiveUp)
    local o = ISPanel.new(self, x, y, w, h)
    o.onBooted = onBooted
    o.onGiveUp = onGiveUp
    o.console = nil
    o.attempts = 0
    o.message = ""
    return o
end

function PZEMUBootPanel:createChildren()
    ISPanel.createChildren(self)
    local bw = 190
    self.blowButton = makeButton(self, math.floor(self.width / 2) - bw - 6, self.height - 50, bw, 30,
        "Blow on the cartridge", PZEMUBootPanel.onBlow)
    self.giveUpButton = makeButton(self, math.floor(self.width / 2) + 6, self.height - 50, bw, 30,
        "Try another game", PZEMUBootPanel.onGiveUpClick)
    for _, b in ipairs({ self.blowButton, self.giveUpButton }) do
        b.anchorTop = false
        b.anchorBottom = true
    end
end

function PZEMUBootPanel:setup(console)
    self.console = console
    self.attempts = 0
    self.message = ""
end

--- Sandbox gate + random roll: should this launch stall?
function PZEMUBootPanel.shouldFail()
    local ok, enabled = pcall(function()
        return SandboxVars and SandboxVars.PZEMU and SandboxVars.PZEMU.CartridgeBlowing == true
    end)
    if not ok or not enabled then return false end
    return ZombRand(100) < PZEMUBootPanel.FAIL_CHANCE
end

function PZEMUBootPanel.onBlow(self, button)
    self.attempts = self.attempts + 1
    -- A tiny bit of nostalgic relief: 1-2 points of unhappiness (0-100 scale).
    pcall(function()
        local p = getPlayer()
        if p and CharacterStat then
            local stats = p:getStats()
            local cur = stats:get(CharacterStat.UNHAPPINESS)
            local new = cur - ZombRand(1, 3)
            if new < 0 then new = 0 end
            stats:set(CharacterStat.UNHAPPINESS, new)
        end
    end)
    if ZombRand(100) < PZEMUBootPanel.BLOW_SUCCESS then
        if self.onBooted then self.onBooted() end
    else
        local msgs = {
            "Still a grey screen. Blow harder?",
            "The screen flickers... and dies again.",
            "Nothing. Maybe wiggle it a bit first.",
        }
        self.message = msgs[(self.attempts % #msgs) + 1]
    end
end

function PZEMUBootPanel.onGiveUpClick(self, button)
    if self.onGiveUp then self.onGiveUp() end
end

function PZEMUBootPanel:prerender()
    ISPanel.prerender(self)
    self:drawRect(0, 0, self.width, self.height, 0.97, 0.05, 0.05, 0.08)
end

function PZEMUBootPanel:render()
    ISPanel.render(self)
    local cx = self.width / 2
    local y = 40
    local name = self.console and self.console.displayName or "console"
    local title = "The game won't boot"
    local tw = getTextManager():MeasureStringX(UIFont.Large, title)
    self:drawText(title, cx - tw / 2, y, 1, 0.9, 0.6, 0.95, UIFont.Large)
    y = y + fontH(UIFont.Large) + 16
    local lines = {
        "You push the cartridge into the " .. name .. " and flip the switch...",
        "Nothing but a flickering grey screen.",
        "",
        "Everyone knows what to do.",
    }
    for _, line in ipairs(lines) do
        local lw = getTextManager():MeasureStringX(UIFont.Small, line)
        self:drawText(line, cx - lw / 2, y, 0.85, 0.85, 0.85, 0.9, UIFont.Small)
        y = y + fontH(UIFont.Small) + 3
    end
    if self.message ~= "" then
        y = y + 12
        local lw = getTextManager():MeasureStringX(UIFont.Medium, self.message)
        self:drawText(self.message, cx - lw / 2, y, 1, 0.6, 0.6, 0.95, UIFont.Medium)
    end
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
    self.handheldItem = nil
    self.afterNotice = nil
    self.controlsReturn = nil

    local function fullAnchors(p)
        p.anchorLeft = true
        p.anchorRight = true
        p.anchorTop = true
        p.anchorBottom = true
    end

    -- Game picker (visible initially when opened via openWithContext)
    self.gamePicker = PZEMUGamePicker:new(0, th, panelW, panelH,
        function(romPath) self:onGameSelected(romPath) end,
        function() self:openControls("picker") end)
    fullAnchors(self.gamePicker)
    self.gamePicker:initialise()
    self.gamePicker:instantiate()
    self.gamePicker:setVisible(false)
    self:addChild(self.gamePicker)

    -- Welcome panel (hidden)
    self.welcomePanel = PZEMUWelcome:new(0, th, panelW, panelH,
        function() self:onWelcomeDismissed() end,
        function() self:openControls("welcome") end)
    fullAnchors(self.welcomePanel)
    self.welcomePanel:initialise()
    self.welcomePanel:instantiate()
    self.welcomePanel:setVisible(false)
    self:addChild(self.welcomePanel)

    -- Game panel (hidden)
    self.gamePanel = PZEMUGamePanel:new(0, th, panelW, panelH - rh)
    fullAnchors(self.gamePanel)
    self.gamePanel:initialise()
    self.gamePanel:instantiate()
    self.gamePanel:setVisible(false)
    self:addChild(self.gamePanel)

    -- Volume bar (hidden; shown under the screen while a game runs)
    self.volumeBar = PZEMUVolumeBar:new(0, self.height - rh - VOLUME_BAR_HEIGHT, panelW, VOLUME_BAR_HEIGHT, self)
    self.volumeBar.anchorLeft = true
    self.volumeBar.anchorRight = true
    self.volumeBar.anchorTop = false
    self.volumeBar.anchorBottom = true
    self.volumeBar:initialise()
    self.volumeBar:instantiate()
    self.volumeBar:setVisible(false)
    self:addChild(self.volumeBar)

    -- Key binding editor (hidden)
    self.controlsPanel = PZEMUControlsPanel:new(0, th, panelW, panelH, function() self:closeControls() end)
    fullAnchors(self.controlsPanel)
    self.controlsPanel:initialise()
    self.controlsPanel:instantiate()
    self.controlsPanel:setVisible(false)
    self:addChild(self.controlsPanel)

    -- First-run ROM notice (hidden)
    self.noticePanel = PZEMUNoticePanel:new(0, th, panelW, panelH, function() self:onNoticeAccepted() end)
    fullAnchors(self.noticePanel)
    self.noticePanel:initialise()
    self.noticePanel:instantiate()
    self.noticePanel:setVisible(false)
    self:addChild(self.noticePanel)

    -- Cartridge-blowing flavour (hidden)
    self.bootPanel = PZEMUBootPanel:new(0, th, panelW, panelH,
        function() self:showWelcome() end,
        function() self:showView("picker") end)
    fullAnchors(self.bootPanel)
    self.bootPanel:initialise()
    self.bootPanel:instantiate()
    self.bootPanel:setVisible(false)
    self:addChild(self.bootPanel)

    -- CRITICAL: bring resize widgets to top after all addChild calls (AVOID.md #11)
    if self.resizeWidget then self.resizeWidget:bringToTop() end
    if self.resizeWidget2 then self.resizeWidget2:bringToTop() end
end

--- opts (optional): { handheldItem = <InventoryItem> } — the handheld the
--- session runs on; its batteries drain while playing.
function PZEMUWindow:setupConsole(console, opts)
    self.selectedConsole = console
    self.game = PZEMUGame:new(console)
    if opts and opts.handheldItem and self.game.setBatteryItem then
        self.handheldItem = opts.handheldItem
        self.game:setBatteryItem(opts.handheldItem)
    end
    self.gamePanel:setGame(self.game)
    self:setTitle(console.displayName .. " Emulator")
end

-- ---------- view switching (only for windows created by createWindow) ----------

function PZEMUWindow:showView(name)
    local panels = {
        picker = self.gamePicker, welcome = self.welcomePanel, game = self.gamePanel,
        controls = self.controlsPanel, notice = self.noticePanel, boot = self.bootPanel,
    }
    for key, p in pairs(panels) do
        if p and key ~= name and p:isVisible() then p:setVisible(false) end
    end
    if self.volumeBar then self.volumeBar:setVisible(name == "game") end
    if name == "game" and self.gamePanel then
        -- leave room for the volume bar
        local th = self:titleBarHeight()
        local rh = self:resizeWidgetHeight()
        self.gamePanel:setHeight(self.height - th - rh - VOLUME_BAR_HEIGHT)
        self.volumeBar:setY(self.height - rh - VOLUME_BAR_HEIGHT)
    end
    local target = panels[name]
    if target then target:setVisible(true) end
end

function PZEMUWindow:controlLinesForConsole(console)
    if PZEMUBindings and console and console.buttons then
        local ok, lines = pcall(function()
            return PZEMUBindings.describe(console, PZEMUBindings.get(console.id))
        end)
        if ok and lines and #lines > 0 then return lines end
    end
    return nil
end

function PZEMUWindow:showWelcome()
    self.welcomePanel:setConsole(self.selectedConsole, self:controlLinesForConsole(self.selectedConsole))
    self:showView("welcome")
end

--- Enter the pre-game flow: first-run notice (once), then picker or welcome.
function PZEMUWindow:beginFlow(view)
    if PZEMUSettings and not PZEMUSettings.isRomNoticeAcknowledged() then
        self.afterNotice = view
        self:showView("notice")
        return
    end
    self:enterPreGame(view)
end

function PZEMUWindow:enterPreGame(view)
    if view == "welcome" then
        self:tryBoot()
    else
        self:showView("picker")
    end
end

function PZEMUWindow:onNoticeAccepted()
    if PZEMUSettings then PZEMUSettings.acknowledgeRomNotice() end
    self:enterPreGame(self.afterNotice or "picker")
    self.afterNotice = nil
end

--- A game was chosen (ROM resolved): maybe stall on a dirty cartridge, else welcome.
function PZEMUWindow:tryBoot()
    if PZEMUBootPanel.shouldFail() then
        self.bootPanel:setup(self.selectedConsole)
        self:showView("boot")
    else
        self:showWelcome()
    end
end

function PZEMUWindow:onGameSelected(romPath)
    self.pendingRomPath = romPath
    self:tryBoot()
end

function PZEMUWindow:openControls(returnView)
    self.controlsReturn = returnView or "picker"
    self.controlsPanel:setConsole(self.selectedConsole)
    self:showView("controls")
end

function PZEMUWindow:closeControls()
    if self.game and self.game.reloadKeyMap then self.game:reloadKeyMap() end
    if self.controlsReturn == "welcome" then
        self:showWelcome()
    else
        self:showView("picker")
    end
    self.controlsReturn = nil
end

function PZEMUWindow:onWelcomeDismissed()
    if not self.pendingRomPath or not self.game then return end
    self.welcomePanel:setVisible(false)
    if self.pzemuManaged then
        self:showView("game")
    else
        self.gamePanel:setVisible(true)
    end
    if self.game.reloadKeyMap then self.game:reloadKeyMap() end
    self.game:start(self.pendingRomPath)
    self.gamePanel:grabInput()
end

--- Real teardown: stop the game (graceful), release every input panel, and
--- remove the window. B42's ISCollapsableWindow:close() only hides.
function PZEMUWindow:close()
    if self.game then
        self.game:stop()
    end
    cleanupInputPanel(self.gamePanel)
    cleanupInputPanel(self.controlsPanel)
    if PZEMUWindow.instance == self then
        PZEMUWindow.instance = nil
    end
    self:setVisible(false)
    self:removeFromUIManager()
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
    window.pzemuManaged = true   -- our own flow: view switching + volume bar layout
    window.minimumWidth = 340
    window.minimumHeight = 280
    window:initialise()
    window:instantiate()
    window:setResizable(true)
    window:addToUIManager()

    PZEMUWindow.instance = window
    return window
end

-- Open with game picker showing available cartridges.
-- opts (optional): { handheldItem = <InventoryItem> }
function PZEMUWindow.openWithContext(console, cartridgeList, opts)
    local window = createWindow()
    window:setupConsole(console, opts)
    window.gamePicker:refresh(console, cartridgeList)
    window:beginFlow("picker")
end

-- Open directly to a specific game (from cartridge right-click)
function PZEMUWindow.openWithGame(console, gameData, opts)
    local romPath = resolveRomPath(console, gameData.romFile)
    if not romPath then
        -- Fall back to game picker with just this one game
        PZEMUWindow.openWithContext(console, { gameData }, opts)
        return
    end

    local window = createWindow()
    window:setupConsole(console, opts)
    window.pendingRomPath = romPath
    window.gamePicker:refresh(console, { gameData })
    window:beginFlow("welcome")
end

-- ============================================================================
-- Safety: tear our window down when leaving the world
-- ============================================================================

local function closeManagedInstance()
    local inst = PZEMUWindow.instance
    if inst and inst.pzemuManaged and inst.Type == "PZEMUWindow" then
        inst:close()
    end
end

Events.OnMainMenuEnter.Add(closeManagedInstance)
Events.OnPlayerDeath.Add(function(player)
    closeManagedInstance()
end)
