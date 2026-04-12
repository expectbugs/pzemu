--
-- PZEMUWindow.lua — Multi-console UI with console picker, ROM picker, and game panel
--
-- Five classes:
--   PZEMUGamePanel     — PZFBInputPanel subclass for emulator display + input
--   PZEMUConsolePicker — Console selection list
--   PZEMURomPicker     — ROM file selection list
--   PZEMUWelcome       — Instructions/controls screen (console-specific)
--   PZEMUWindow        — Main ISCollapsableWindow (singleton)
--

require "PZFB/PZFBInput"
require "PZEMU/PZEMUGame"

-- Helper used by ROM picker for "No ROMs found" path
local function getUserDir()
    return Core.getMyDocumentFolder() .. getFileSeparator() .. "PZEMU"
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
-- PZEMUConsolePicker — Console selection panel
-- ============================================================================

PZEMUConsolePicker = ISPanel:derive("PZEMUConsolePicker")

function PZEMUConsolePicker:new(x, y, w, h, onSelect)
    local o = ISPanel.new(self, x, y, w, h)
    o.onSelect = onSelect
    o.buttons = {}
    o.consoles = {}
    return o
end

function PZEMUConsolePicker:createChildren()
    ISPanel.createChildren(self)
    self.consoles = PZEMUGame.getConsoles()

    local y = 50
    for i, console in ipairs(self.consoles) do
        local label = console.displayName .. "  (" .. tostring(console.year) .. ")"
        local btnW = math.min(300, self.width - 40)
        local btnX = math.floor((self.width - btnW) / 2)
        local btn = ISButton:new(btnX, y, btnW, 30, label, self, PZEMUConsolePicker.onBtnClick)
        btn:initialise()
        btn:instantiate()
        btn.internal = "CON_" .. tostring(i)
        btn.consoleIndex = i
        btn.borderColor = { r = 0.3, g = 0.5, b = 0.3, a = 0.6 }
        btn.backgroundColor = { r = 0.08, g = 0.12, b = 0.08, a = 0.8 }
        btn.textColor = { r = 0.9, g = 1.0, b = 0.9, a = 1.0 }
        self:addChild(btn)
        table.insert(self.buttons, btn)
        y = y + 34
    end
end

function PZEMUConsolePicker:onBtnClick(button)
    local console = self.consoles[button.consoleIndex]
    if console and self.onSelect then
        self.onSelect(console)
    end
end

function PZEMUConsolePicker:prerender()
    ISPanel.prerender(self)
    self:drawRect(0, 0, self.width, self.height, 0.95, 0.05, 0.05, 0.08)
end

function PZEMUConsolePicker:render()
    ISPanel.render(self)
    local title = "Select a Console"
    local titleW = getTextManager():MeasureStringX(UIFont.Large, title)
    self:drawText(title, math.floor((self.width - titleW) / 2), 12, 1, 1, 1, 0.9, UIFont.Large)
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
    o.console = nil
    return o
end

function PZEMURomPicker:createChildren()
    ISPanel.createChildren(self)
end

function PZEMURomPicker:refresh(console)
    self.console = console

    -- Remove old buttons
    for _, btn in ipairs(self.buttons) do
        self:removeChild(btn)
    end
    self.buttons = {}

    self.roms = PZEMUGame.findRoms(console)

    local yOff = 50
    for i, rom in ipairs(self.roms) do
        -- Strip extension for display
        local displayName = rom.name
        for _, ext in ipairs(console.romExtensions) do
            local extLen = #ext
            if string.sub(string.lower(displayName), -extLen) == ext then
                displayName = string.sub(displayName, 1, -extLen - 1)
                break
            end
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

    local consoleName = self.console and self.console.displayName or "?"
    local title = consoleName .. " — Select a ROM"
    self:drawText(title, 20, 12, 1, 1, 1, 0.9, UIFont.Medium)

    if #self.roms == 0 then
        local sep = getFileSeparator()
        local romDir = getUserDir() .. sep .. "roms" .. sep .. (self.console and self.console.romDir or "")
        self:drawText("No ROMs found.", 20, 60, 0.8, 0.6, 0.6, 0.8, UIFont.Small)
        self:drawText("Place ROM files in:", 20, 80, 0.6, 0.6, 0.6, 0.7, UIFont.Small)
        self:drawText(romDir, 20, 100, 0.5, 0.7, 0.5, 0.7, UIFont.Small)
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
    self.selectedRom = nil

    -- Console picker (visible initially)
    self.consolePicker = PZEMUConsolePicker:new(0, th, panelW, panelH, function(console)
        self:onConsoleSelected(console)
    end)
    self.consolePicker.anchorLeft = true
    self.consolePicker.anchorRight = true
    self.consolePicker.anchorTop = true
    self.consolePicker.anchorBottom = true
    self.consolePicker:initialise()
    self.consolePicker:instantiate()
    self:addChild(self.consolePicker)

    -- ROM picker (hidden)
    self.romPicker = PZEMURomPicker:new(0, th, panelW, panelH, function(rom)
        self:onRomSelected(rom)
    end)
    self.romPicker.anchorLeft = true
    self.romPicker.anchorRight = true
    self.romPicker.anchorTop = true
    self.romPicker.anchorBottom = true
    self.romPicker:initialise()
    self.romPicker:instantiate()
    self.romPicker:setVisible(false)
    self:addChild(self.romPicker)

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

function PZEMUWindow:onConsoleSelected(console)
    self.selectedConsole = console
    self.consolePicker:setVisible(false)

    -- Create game object for selected console
    self.game = PZEMUGame:new(console)
    self.gamePanel:setGame(self.game)

    -- Refresh ROM picker for this console
    self.romPicker:refresh(console)
    self.romPicker:setVisible(true)

    self:setTitle(console.displayName .. " Emulator")
end

function PZEMUWindow:onRomSelected(rom)
    self.selectedRom = rom
    self.romPicker:setVisible(false)
    self.welcomePanel:setConsole(self.selectedConsole)
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
    local h = 540
    local x = math.floor((screenW - w) / 2)
    local y = math.floor((screenH - h) / 2)

    local window = PZEMUWindow:new(x, y, w, h)
    window.minimumWidth = 340
    window.minimumHeight = 280
    window:initialise()
    window:instantiate()
    window:setTitle("Retro Console Emulator")
    window:setResizable(true)
    window:addToUIManager()

    PZEMUWindow.instance = window
end
