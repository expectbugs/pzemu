--
-- PZEMUWindow.lua — UI window with game panel, ROM picker, and welcome screen
--
-- Four classes:
--   PZEMUGamePanel  — PZFBInputPanel subclass for emulator display + input
--   PZEMURomPicker  — ROM file selection list
--   PZEMUWelcome    — Instructions/controls screen
--   PZEMUWindow     — Main ISCollapsableWindow (singleton)
--

require "PZFB/PZFBInput"
require "PZEMU/PZEMUGame"

-- ============================================================================
-- PZEMUGamePanel — Extends PZFBInputPanel for emulator display
-- ============================================================================

PZEMUGamePanel = PZFBInputPanel:derive("PZEMUGamePanel")

function PZEMUGamePanel:new(x, y, w, h, game)
    local o = PZFBInputPanel.new(self, x, y, w, h, {
        mode                  = PZFBInput.MODE_FOCUS,
        captureToggleKey      = Keyboard.KEY_SCROLL,
        escapeCloses          = false,
        escapeReleasesCapture = true,
        forceCursorVisible    = true,
        autoGrab              = false,
    })
    o.game = game
    return o
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
        -- Send Start press/release to pause the game (NES Start = pause)
        PZFB.gameSendInput(3, 1)
        PZFB.gameSendInput(3, 0)
    end
end

function PZEMUGamePanel:render()
    PZFBInputPanel.render(self)
    local game = self.game
    if not game then return end

    game:update()

    -- Status text for non-running states
    if game.state == "STARTING" then
        self:drawText("Starting NES emulator...", 10, 10, 1, 1, 1, 0.8, UIFont.Medium)
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
        local scaleX = self.width / PZEMUGame.NES_WIDTH
        local scaleY = self.height / PZEMUGame.NES_HEIGHT
        local scale = math.min(scaleX, scaleY)
        local drawW = math.floor(PZEMUGame.NES_WIDTH * scale)
        local drawH = math.floor(PZEMUGame.NES_HEIGHT * scale)
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
        local hint = "[Scroll Lock: lock input] [ESC: unlock]"
        self:drawText(hint, 4, self.height - getTextManager():getFontHeight(UIFont.Small) - 4,
                      0.6, 0.6, 0.6, 0.4, UIFont.Small)
    end
end

-- ============================================================================
-- PZEMURomPicker — ROM selection panel
-- ============================================================================

PZEMURomPicker = ISPanel:derive("PZEMURomPicker")

function PZEMURomPicker:new(x, y, w, h, onSelect)
    local o = ISPanel.new(self, x, y, w, h)
    o.onSelect = onSelect
    o.buttons = {}
    o.roms = {}
    return o
end

function PZEMURomPicker:createChildren()
    ISPanel.createChildren(self)
    self:refresh()
end

function PZEMURomPicker:refresh()
    -- Remove old buttons
    for _, btn in ipairs(self.buttons) do
        self:removeChild(btn)
    end
    self.buttons = {}

    self.roms = PZEMUGame.findRoms()

    local yOff = 50
    for i, rom in ipairs(self.roms) do
        -- Strip .nes extension for display
        local displayName = rom.name
        if string.sub(string.lower(displayName), -4) == ".nes" then
            displayName = string.sub(displayName, 1, -5)
        end

        local btn = ISButton:new(20, yOff, self.width - 40, 28, displayName, self, PZEMURomPicker.onRomClick)
        btn:initialise()
        btn:instantiate()
        btn.internal = "ROM_" .. tostring(i)
        btn.romIndex = i
        btn.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 0.6 }
        btn.backgroundColor = { r = 0.1, g = 0.1, b = 0.15, a = 0.8 }
        btn.textColor = { r = 0.9, g = 0.9, b = 0.9, a = 1.0 }
        self:addChild(btn)
        table.insert(self.buttons, btn)
        yOff = yOff + 32
    end
end

function PZEMURomPicker:onRomClick(button)
    local rom = self.roms[button.romIndex]
    if rom and self.onSelect then
        self.onSelect(rom)
    end
end

function PZEMURomPicker:prerender()
    ISPanel.prerender(self)
    self:drawRect(0, 0, self.width, self.height, 0.95, 0.05, 0.05, 0.08)
end

function PZEMURomPicker:render()
    ISPanel.render(self)
    self:drawText("Select a ROM", 20, 12, 1, 1, 1, 0.9, UIFont.Medium)

    if #self.roms == 0 then
        local sep = getFileSeparator()
        local romDir = Core.getMyDocumentFolder() .. sep .. "PZEMU" .. sep .. "roms" .. sep .. "nes"
        self:drawText("No ROMs found.", 20, 60, 0.8, 0.6, 0.6, 0.8, UIFont.Small)
        self:drawText("Place .nes files in:", 20, 80, 0.6, 0.6, 0.6, 0.7, UIFont.Small)
        self:drawText(romDir, 20, 100, 0.5, 0.7, 0.5, 0.7, UIFont.Small)
    end
end

-- ============================================================================
-- PZEMUWelcome — Instructions panel
-- ============================================================================

PZEMUWelcome = ISPanel:derive("PZEMUWelcome")

function PZEMUWelcome:new(x, y, w, h, onDismiss)
    local o = ISPanel.new(self, x, y, w, h)
    o.onDismiss = onDismiss
    o.tickCount = 0
    return o
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
    local title = "NES Emulator"
    local titleW = getTextManager():MeasureStringX(UIFont.Large, title)
    self:drawText(title, cx - titleW / 2, y, 1, 1, 1, 0.95, UIFont.Large)
    y = y + 40

    -- Controls
    local controls = {
        "Arrows  =  D-pad",
        "Z  =  B button",
        "X  =  A button",
        "Enter  =  Start",
        "Right Shift  =  Select",
        "",
        "Scroll Lock  =  Lock/unlock input",
        "ESC  =  Release input + pause",
    }

    for _, line in ipairs(controls) do
        if line == "" then
            y = y + 10
        else
            local lineW = getTextManager():MeasureStringX(UIFont.Small, line)
            self:drawText(line, cx - lineW / 2, y, 0.8, 0.8, 0.8, 0.8, UIFont.Small)
            y = y + 20
        end
    end

    -- Pulsing "Click to play" prompt
    y = y + 30
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

    -- Create game object
    self.game = PZEMUGame:new()

    -- Game panel (hidden initially)
    self.gamePanel = PZEMUGamePanel:new(0, th, panelW, panelH - rh, self.game)
    self.gamePanel.anchorLeft = true
    self.gamePanel.anchorRight = true
    self.gamePanel.anchorTop = true
    self.gamePanel.anchorBottom = true
    self.gamePanel:initialise()
    self.gamePanel:instantiate()
    self.gamePanel:setVisible(false)
    self:addChild(self.gamePanel)

    -- ROM picker (initially visible)
    self.romPicker = PZEMURomPicker:new(0, th, panelW, panelH, function(rom)
        self:onRomSelected(rom)
    end)
    self.romPicker.anchorLeft = true
    self.romPicker.anchorRight = true
    self.romPicker.anchorTop = true
    self.romPicker.anchorBottom = true
    self.romPicker:initialise()
    self.romPicker:instantiate()
    self:addChild(self.romPicker)

    -- Welcome panel (hidden until ROM selected)
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

    -- CRITICAL: bring resize widgets to top after all addChild calls (AVOID.md #11)
    if self.resizeWidget then self.resizeWidget:bringToTop() end
    if self.resizeWidget2 then self.resizeWidget2:bringToTop() end
end

function PZEMUWindow:onRomSelected(rom)
    self.romPicker:setVisible(false)
    self.selectedRom = rom
    self.welcomePanel:setVisible(true)
end

function PZEMUWindow:onWelcomeDismissed()
    self.welcomePanel:setVisible(false)
    self.gamePanel:setVisible(true)
    self.game:start(self.selectedRom.path)
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

function PZEMUWindow.open()
    if PZEMUWindow.instance then
        PZEMUWindow.instance:bringToTop()
        return
    end

    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    local w = 660
    local h = 500
    local x = math.floor((screenW - w) / 2)
    local y = math.floor((screenH - h) / 2)

    local window = PZEMUWindow:new(x, y, w, h)
    window.minimumWidth = 340
    window.minimumHeight = 230
    window:initialise()
    window:instantiate()
    window:setTitle("NES Emulator")
    window:setResizable(true)
    window:addToUIManager()

    PZEMUWindow.instance = window
end
