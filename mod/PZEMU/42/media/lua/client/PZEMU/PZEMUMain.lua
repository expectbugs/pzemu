--
-- PZEMUMain.lua — Context menu hooks for TV, console, and cartridge right-click
--
-- Three entry points:
--   1. Right-click TV: shows "Play <Console>" for each nearby console (requires power)
--   2. Right-click console item: shows "Play <Console>" if TV nearby (or handheld)
--   3. Right-click cartridge item: shows "Play <Game>" — launches directly
--
-- When an option cannot be used it is still shown, greyed out, with a tooltip
-- that says why (no powered TV, no cartridges nearby, dead batteries, PZFB not
-- installed, ...). Item identification uses getFullType() lookups.
-- TV detection uses instanceof(obj, "IsoTelevision") — IsoWaveSignal would also
-- match map radios (both extend IsoWaveSignal in B42).
-- Power check uses haveElectricity() || hasGridPower() (verified from vanilla).
--
-- FYI: the separate mod "Literally Playable Video Game Consoles" ships its own
-- replacement of this file. It is not supported (Adam, 2026-10-15).
--

require "PZEMU/PZEMUWindow"
require "PZEMU/PZEMUGame"

PZEMUMain = {}

-- ============================================================================
-- Type-based item identification tables
-- ============================================================================

local CONSOLE_TYPE_TO_ID = {
    ["PZEMU.NES_Console"]       = "nes",
    ["PZEMU.SNES_Console"]      = "snes",
    ["PZEMU.Genesis_Console"]   = "genesis",
    ["PZEMU.GameBoy_Console"]   = "gb",
    ["PZEMU.Atari2600_Console"] = "atari2600",
    ["PZEMU.GameGear_Console"]  = "gg",
    ["PZEMU.SMS_Console"]       = "sms",
}

local HANDHELD_TYPES = {
    ["PZEMU.GameBoy_Console"]   = true,
    ["PZEMU.GameGear_Console"]  = true,
}

-- Item-name prefix per system ("NES: Super Mario Bros."). Must match the
-- DisplayNames in pzemu_items.txt and the spawn code in PZEMU_Distributions.lua.
local SYSTEM_PREFIX = {
    nes = "NES", snes = "SNES", genesis = "Genesis", gb = "Game Boy",
    atari2600 = "Atari 2600", gg = "Game Gear", sms = "Master System",
}

local CART_TYPE_TO_SYSTEM = {
    ["PZEMU.NES_Cart_Mario"]    = "nes",
    ["PZEMU.NES_Cart_Zelda"]    = "nes",
    ["PZEMU.NES_Cart_Contra"]   = "nes",
    ["PZEMU.NES_Cart_MegaMan"]  = "nes",
    ["PZEMU.NES_Cart_Metroid"]  = "nes",
    ["PZEMU.NES_Cart_Generic"]  = "nes",
    ["PZEMU.SNES_Cart_MarioWorld"] = "snes",
    ["PZEMU.SNES_Cart_Zelda"]     = "snes",
    ["PZEMU.SNES_Cart_SF2"]       = "snes",
    ["PZEMU.SNES_Cart_MK2"]       = "snes",
    ["PZEMU.SNES_Cart_StarFox"]   = "snes",
    ["PZEMU.SNES_Cart_SecretOfMana"] = "snes",
    ["PZEMU.SNES_Cart_NBAJam"]    = "snes",
    ["PZEMU.SNES_Cart_Generic"]   = "snes",
    ["PZEMU.Genesis_Cart_Sonic"]     = "genesis",
    ["PZEMU.Genesis_Cart_GoldenAxe"] = "genesis",
    ["PZEMU.Genesis_Cart_Aladdin"]   = "genesis",
    ["PZEMU.Genesis_Cart_SF2"]       = "genesis",
    ["PZEMU.Genesis_Cart_AlteredBeast"]    = "genesis",
    ["PZEMU.Genesis_Cart_DesertStrike"]    = "genesis",
    ["PZEMU.Genesis_Cart_FatalFury"]       = "genesis",
    ["PZEMU.Genesis_Cart_GoldenAxe2"]      = "genesis",
    ["PZEMU.Genesis_Cart_GhoulsNGhosts"]   = "genesis",
    ["PZEMU.Genesis_Cart_HerzogZwei"]      = "genesis",
    ["PZEMU.Genesis_Cart_LighteningForce"] = "genesis",
    ["PZEMU.Genesis_Cart_Moonwalker"]      = "genesis",
    ["PZEMU.Genesis_Cart_OutRun"]          = "genesis",
    ["PZEMU.Genesis_Cart_PhantasyStar3"]   = "genesis",
    ["PZEMU.Genesis_Cart_QuackShot"]       = "genesis",
    ["PZEMU.Genesis_Cart_RoadRash2"]       = "genesis",
    ["PZEMU.Genesis_Cart_RollingThunder2"] = "genesis",
    ["PZEMU.Genesis_Cart_ShadowDancer"]    = "genesis",
    ["PZEMU.Genesis_Cart_RevengeOfShinobi"] = "genesis",
    ["PZEMU.Genesis_Cart_Sonic2"]          = "genesis",
    ["PZEMU.Genesis_Cart_SpaceHarrier2"]   = "genesis",
    ["PZEMU.Genesis_Cart_Splatterhouse2"]  = "genesis",
    ["PZEMU.Genesis_Cart_StreetsOfRage"]   = "genesis",
    ["PZEMU.Genesis_Cart_StreetsOfRage2"]  = "genesis",
    ["PZEMU.Genesis_Cart_Strider"]         = "genesis",
    ["PZEMU.Genesis_Cart_TMNTHH"]          = "genesis",
    ["PZEMU.Genesis_Cart_Generic"]   = "genesis",
    ["PZEMU.GB_Cart_Tetris"]   = "gb",
    ["PZEMU.GB_Cart_Mario"]    = "gb",
    ["PZEMU.GB_Cart_Zelda"]    = "gb",
    ["PZEMU.GB_Cart_Kirby"]    = "gb",
    ["PZEMU.GB_Cart_FinalFantasyLegend"] = "gb",
    ["PZEMU.GB_Cart_Generic"]  = "gb",
    ["PZEMU.Atari_Cart_Combat"]        = "atari2600",
    ["PZEMU.Atari_Cart_Asteroids"]     = "atari2600",
    ["PZEMU.Atari_Cart_Pitfall"]       = "atari2600",
    ["PZEMU.Atari_Cart_SpaceInvaders"] = "atari2600",
    ["PZEMU.Atari_Cart_MsPacMan"]      = "atari2600",
    ["PZEMU.Atari_Cart_Generic"]       = "atari2600",
    ["PZEMU.GG_Cart_Sonic"]    = "gg",
    ["PZEMU.GG_Cart_Columns"]  = "gg",
    ["PZEMU.GG_Cart_Klax"]     = "gg",
    ["PZEMU.GG_Cart_OutRun"]   = "gg",
    ["PZEMU.GG_Cart_Paperboy"] = "gg",
    ["PZEMU.GG_Cart_Shinobi"]  = "gg",
    ["PZEMU.GG_Cart_Generic"]  = "gg",
    ["PZEMU.SMS_Cart_Generic"] = "sms",
}

local NAMED_CART_ROMS = {
    ["PZEMU.NES_Cart_Mario"]     = "Super_Mario_Bros.nes",
    ["PZEMU.NES_Cart_Zelda"]     = "Legend_of_Zelda.nes",
    ["PZEMU.NES_Cart_Contra"]    = "Contra.nes",
    ["PZEMU.NES_Cart_MegaMan"]   = "Mega_Man_2.nes",
    ["PZEMU.NES_Cart_Metroid"]   = "Metroid.nes",
    ["PZEMU.SNES_Cart_MarioWorld"] = "Super_Mario_World.smc",
    ["PZEMU.SNES_Cart_Zelda"]     = "Zelda_A_Link_to_the_Past.smc",
    ["PZEMU.SNES_Cart_SF2"]       = "Street_Fighter_2_Turbo.smc",
    ["PZEMU.SNES_Cart_MK2"]       = "Mortal_Kombat_2.smc",
    ["PZEMU.SNES_Cart_StarFox"]   = "Star_Fox.smc",
    ["PZEMU.SNES_Cart_SecretOfMana"] = "Secret_of_Mana.smc",
    ["PZEMU.SNES_Cart_NBAJam"]    = "NBA_Jam.smc",
    ["PZEMU.Genesis_Cart_Sonic"]     = "Sonic_The_Hedgehog.bin",
    ["PZEMU.Genesis_Cart_GoldenAxe"] = "Golden_Axe.gen",
    ["PZEMU.Genesis_Cart_Aladdin"]   = "Aladdin.bin",
    ["PZEMU.Genesis_Cart_SF2"]       = "Street_Fighter_2.bin",
    ["PZEMU.Genesis_Cart_AlteredBeast"]    = "Altered_Beast.smd",
    ["PZEMU.Genesis_Cart_DesertStrike"]    = "Desert_Strike.smd",
    ["PZEMU.Genesis_Cart_FatalFury"]       = "Fatal_Fury.smd",
    ["PZEMU.Genesis_Cart_GoldenAxe2"]      = "Golden_Axe_2.gen",
    ["PZEMU.Genesis_Cart_GhoulsNGhosts"]   = "Ghouls_N_Ghosts.smd",
    ["PZEMU.Genesis_Cart_HerzogZwei"]      = "Herzog_Zwei.smd",
    ["PZEMU.Genesis_Cart_LighteningForce"] = "Lightening_Force.smd",
    ["PZEMU.Genesis_Cart_Moonwalker"]      = "Moonwalker.smd",
    ["PZEMU.Genesis_Cart_OutRun"]          = "OutRun.smd",
    ["PZEMU.Genesis_Cart_PhantasyStar3"]   = "Phantasy_Star_3.smd",
    ["PZEMU.Genesis_Cart_QuackShot"]       = "QuackShot.smd",
    ["PZEMU.Genesis_Cart_RoadRash2"]       = "Road_Rash_II.smd",
    ["PZEMU.Genesis_Cart_RollingThunder2"] = "Rolling_Thunder_2.smd",
    ["PZEMU.Genesis_Cart_ShadowDancer"]    = "Shadow_Dancer.smd",
    ["PZEMU.Genesis_Cart_RevengeOfShinobi"] = "Revenge_of_Shinobi.smd",
    ["PZEMU.Genesis_Cart_Sonic2"]          = "Sonic_The_Hedgehog_2.smd",
    ["PZEMU.Genesis_Cart_SpaceHarrier2"]   = "Space_Harrier_2.smd",
    ["PZEMU.Genesis_Cart_Splatterhouse2"]  = "Splatterhouse_2.smd",
    ["PZEMU.Genesis_Cart_StreetsOfRage"]   = "Streets_Of_Rage.smd",
    ["PZEMU.Genesis_Cart_StreetsOfRage2"]  = "Streets_Of_Rage_2.smd",
    ["PZEMU.Genesis_Cart_Strider"]         = "Strider.smd",
    ["PZEMU.Genesis_Cart_TMNTHH"]          = "TMNT_Hyperstone_Heist.smd",
    ["PZEMU.GB_Cart_Tetris"]   = "Tetris.gb",
    ["PZEMU.GB_Cart_Mario"]    = "Super_Mario_Land.gb",
    ["PZEMU.GB_Cart_Zelda"]    = "Links_Awakening.gb",
    ["PZEMU.GB_Cart_Kirby"]    = "Kirbys_Dream_Land.gb",
    ["PZEMU.GB_Cart_FinalFantasyLegend"] = "Final_Fantasy_Legend.gb",
    ["PZEMU.Atari_Cart_Combat"]        = "Combat.bin",
    ["PZEMU.Atari_Cart_Asteroids"]     = "Asteroids.bin",
    ["PZEMU.Atari_Cart_Pitfall"]       = "Pitfall.bin",
    ["PZEMU.Atari_Cart_SpaceInvaders"] = "Space_Invaders.bin",
    ["PZEMU.Atari_Cart_MsPacMan"]      = "Ms_Pac_Man.bin",
    ["PZEMU.GG_Cart_Sonic"]    = "Sonic_the_Hedgehog.gg",
    ["PZEMU.GG_Cart_Columns"]  = "Columns.gg",
    ["PZEMU.GG_Cart_Klax"]     = "Klax.gg",
    ["PZEMU.GG_Cart_OutRun"]   = "OutRun_Europa.gg",
    ["PZEMU.GG_Cart_Paperboy"] = "Paperboy.gg",
    ["PZEMU.GG_Cart_Shinobi"]  = "GG_Shinobi.gg",
}

local SCAN_RANGE = 8

-- ============================================================================
-- Power check — verified from ISVehicleMenu.lua:1088 and ISWorldObjectContextMenu.lua:457
-- haveElectricity() = generator power, hasGridPower() = grid/utility power
-- ============================================================================

local function hasPower(square)
    return square:haveElectricity() or square:hasGridPower()
end

-- ============================================================================
-- Item identification helpers
-- ============================================================================

local function stripSystemPrefix(name, systemId)
    local prefix = SYSTEM_PREFIX[systemId]
    if prefix and name then
        local p = prefix .. ": "
        if string.sub(name, 1, string.len(p)) == p then
            return string.sub(name, string.len(p) + 1)
        end
    end
    return name
end

--- Generic cartridges spawned before 0.8.0 carry the bare game name. Give them
--- the same "System: Game" display name new spawns get (client-side; harmless).
local function fixLegacyCartName(item, systemId)
    local ok = pcall(function()
        local md = item:getModData()
        local gameName = md and md.PZEMU_GameName
        local prefix = SYSTEM_PREFIX[systemId]
        if gameName and prefix and item:isCustomName() and item:getName() == gameName then
            item:setName(prefix .. ": " .. gameName)
        end
    end)
    return ok
end

local function getCartridgeData(item)
    local fullType = item:getFullType()
    local systemId = CART_TYPE_TO_SYSTEM[fullType]
    local romFile = NAMED_CART_ROMS[fullType]
    local gameName = stripSystemPrefix(item:getName(), systemId)

    if not romFile then
        local md = item:getModData()
        romFile = md.PZEMU_RomFile
        if md.PZEMU_GameName then
            gameName = md.PZEMU_GameName
        end
    end

    return { gameName = gameName, romFile = romFile, systemId = systemId }
end

local function handheldHasCharge(item)
    local ok, uses = pcall(function() return item:getCurrentUsesFloat() end)
    return ok and type(uses) == "number" and uses > 0
end

-- ============================================================================
-- Proximity scanning (recursive player inventory via getAllEvalRecurse)
-- ============================================================================

local function scanItems(playerObj, range, matchFn)
    local results = {}

    local playerInv = playerObj:getInventory()
    local found = playerInv:getAllEvalRecurse(function(item)
        return matchFn(item)
    end)
    for i = 0, found:size() - 1 do
        table.insert(results, found:get(i))
    end

    local sq = playerObj:getSquare()
    if not sq then return results end
    local cell = sq:getCell()
    local cx, cy, cz = sq:getX(), sq:getY(), sq:getZ()

    for dx = -range, range do
        for dy = -range, range do
            local s = cell:getGridSquare(cx + dx, cy + dy, cz)
            if s then
                local worldObjs = s:getWorldObjects()
                for i = 0, worldObjs:size() - 1 do
                    local wo = worldObjs:get(i)
                    if wo then
                        local item = wo:getItem()
                        if item and matchFn(item) then
                            table.insert(results, item)
                        end
                    end
                end

                local objects = s:getObjects()
                for i = 0, objects:size() - 1 do
                    local obj = objects:get(i)
                    local cc = obj:getContainerCount()
                    if cc and cc > 0 then
                        for ci = 0, cc - 1 do
                            local cont = obj:getContainerByIndex(ci)
                            if cont then
                                local citems = cont:getItems()
                                for j = 0, citems:size() - 1 do
                                    if matchFn(citems:get(j)) then
                                        table.insert(results, citems:get(j))
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return results
end

function PZEMUMain.scanNearbyConsoles(playerObj, range)
    return scanItems(playerObj, range, function(item)
        return CONSOLE_TYPE_TO_ID[item:getFullType()] ~= nil
    end)
end

function PZEMUMain.scanNearbyCartridges(playerObj, range, systemId)
    local carts = scanItems(playerObj, range, function(item)
        return CART_TYPE_TO_SYSTEM[item:getFullType()] == systemId
    end)
    for _, item in ipairs(carts) do
        fixLegacyCartName(item, systemId)
    end
    return carts
end

--- Is this world object a television (not a radio)? IsoTelevision extends
--- IsoWaveSignal; so does IsoRadio — hence the explicit class check.
local function isTelevision(obj)
    return instanceof(obj, "IsoTelevision") and obj:getSprite() ~= nil
end

--- Nearest TV on the player's floor within range.
--- Returns tvObject|nil, powered(boolean). Prefers a powered TV.
function PZEMUMain.findNearbyTVStatus(playerObj, range)
    local sq = playerObj:getSquare()
    if not sq then return nil, false end
    local cell = sq:getCell()
    local cx, cy, cz = sq:getX(), sq:getY(), sq:getZ()

    local unpowered = nil
    for dx = -range, range do
        for dy = -range, range do
            local s = cell:getGridSquare(cx + dx, cy + dy, cz)
            if s then
                local objects = s:getObjects()
                for i = 0, objects:size() - 1 do
                    local obj = objects:get(i)
                    if isTelevision(obj) then
                        if hasPower(s) then
                            return obj, true
                        elseif not unpowered then
                            unpowered = obj
                        end
                    end
                end
            end
        end
    end
    return unpowered, false
end

--- Backward-compatible: powered TV within range or nil.
function PZEMUMain.findNearbyTV(playerObj, range)
    local tv, powered = PZEMUMain.findNearbyTVStatus(playerObj, range)
    if tv and powered then return tv end
    return nil
end

-- ============================================================================
-- Build cartridge list for game picker
-- ============================================================================

local function buildCartridgeList(cartridges)
    local list = {}
    local seen = {}
    for _, item in ipairs(cartridges) do
        local data = getCartridgeData(item)
        if data.romFile and not seen[data.romFile] then
            seen[data.romFile] = true
            table.insert(list, data)
        end
    end
    return list
end

-- ============================================================================
-- Context menu helpers: greyed-out options that explain themselves
-- ============================================================================

local MSG_NO_PZFB = "PZFB's class files are not installed. Load into a game once so PZFB can show its setup panel, "
                 .. "run the generated installer, then restart Project Zomboid."
local MSG_RANGE   = " within " .. tostring(SCAN_RANGE) .. " tiles on this floor"

local function newTooltip(isWorld)
    local tip = nil
    if isWorld and ISWorldObjectContextMenu and ISWorldObjectContextMenu.addToolTip then
        tip = ISWorldObjectContextMenu.addToolTip()
    elseif (not isWorld) and ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.addToolTip then
        tip = ISInventoryPaneContextMenu.addToolTip()
    end
    if not tip then
        tip = ISToolTip:new()
        tip:initialise()
    end
    tip:setVisible(false)
    return tip
end

--- Add "label" to the context menu. When `reason` is non-nil the option is shown
--- disabled (option.notAvailable, verified pattern from ISWorldObjectContextMenu)
--- with `reason` as its tooltip; otherwise it is clickable.
local function addPlayOption(context, isWorld, label, reason, target, onSelect, p1, p2, p3)
    local option
    if reason then
        option = context:addOption(label, target, nil)
        option.notAvailable = true
        local tip = newTooltip(isWorld)
        tip:setName(label)
        tip.description = reason
        option.toolTip = tip
    else
        option = context:addOption(label, target, onSelect, p1, p2, p3)
    end
    return option
end

local function pzfbReady()
    return PZFB ~= nil and PZFB.isAvailable ~= nil and PZFB.isAvailable()
end

-- ============================================================================
-- Context menu callbacks
-- ============================================================================

local function onPlayConsole(playerObj, consoleId, handheldItem)
    local console = PZEMUGame.getConsoleById(consoleId)
    if not console then return end

    local carts = PZEMUMain.scanNearbyCartridges(playerObj, SCAN_RANGE, consoleId)
    local cartList = buildCartridgeList(carts)
    local opts = nil
    if handheldItem then opts = { handheldItem = handheldItem } end
    PZEMUWindow.openWithContext(console, cartList, opts)
end

local function onPlayCartridge(playerObj, cartItem, handheldItem)
    local systemId = CART_TYPE_TO_SYSTEM[cartItem:getFullType()]
    if not systemId then return end

    local console = PZEMUGame.getConsoleById(systemId)
    if not console then return end

    local data = getCartridgeData(cartItem)
    if data.romFile then
        local opts = nil
        if handheldItem then opts = { handheldItem = handheldItem } end
        PZEMUWindow.openWithGame(console, data, opts)
    end
end

-- ============================================================================
-- World object context menu (TV right-click)
-- ============================================================================

Events.OnFillWorldObjectContextMenu.Add(function(player, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end

    local tvObject = nil
    for _, object in ipairs(worldobjects) do
        if isTelevision(object) then
            tvObject = object
            break
        end
    end
    if not tvObject then return end

    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    local tvSquare = tvObject:getSquare()
    local powered = tvSquare ~= nil and hasPower(tvSquare)

    local consoles = PZEMUMain.scanNearbyConsoles(playerObj, SCAN_RANGE)

    local systemsFound = {}
    local order = {}
    for _, item in ipairs(consoles) do
        local ft = item:getFullType()
        if not HANDHELD_TYPES[ft] then
            local cid = CONSOLE_TYPE_TO_ID[ft]
            if cid and not systemsFound[cid] then
                systemsFound[cid] = true
                table.insert(order, cid)
            end
        end
    end
    -- A TV with no console anywhere near it gets no PZEMU entries at all.
    if #order == 0 then return end

    for _, consoleId in ipairs(order) do
        local console = PZEMUGame.getConsoleById(consoleId)
        if console then
            local reason = nil
            if not pzfbReady() then
                reason = MSG_NO_PZFB
            elseif not powered then
                reason = "This TV has no power. Restore grid power or run a generator nearby."
            else
                local carts = PZEMUMain.scanNearbyCartridges(playerObj, SCAN_RANGE, consoleId)
                if #carts == 0 then
                    reason = "No " .. console.displayName .. " cartridges" .. MSG_RANGE .. ". Bring a game."
                end
            end
            addPlayOption(context, true, "Play " .. console.displayName, reason, playerObj, onPlayConsole, consoleId)
        end
    end
end)

-- ============================================================================
-- Inventory context menu (console/cartridge right-click)
-- Wrapped in pcall to never break the vanilla context menu system
-- ============================================================================

local function tvReason(playerObj)
    local tv, powered = PZEMUMain.findNearbyTVStatus(playerObj, SCAN_RANGE)
    if not tv then
        return "No TV" .. MSG_RANGE .. ". Stand closer to a television."
    end
    if not powered then
        return "The TV nearby has no power. Restore grid power or run a generator."
    end
    return nil
end

local function inventoryContextMenuHandler(player, context, items)
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end

    for _, v in ipairs(items) do
        local item = v
        if not instanceof(v, "InventoryItem") then
            item = v.items[1]
        end
        if not item then return end

        local fullType = item:getFullType()

        -- Console right-click
        local consoleId = CONSOLE_TYPE_TO_ID[fullType]
        if consoleId then
            local console = PZEMUGame.getConsoleById(consoleId)
            if not console then return end

            local reason = nil
            local handheld = nil
            if not pzfbReady() then
                reason = MSG_NO_PZFB
            elseif HANDHELD_TYPES[fullType] then
                handheld = item
                if not handheldHasCharge(item) then
                    reason = "The batteries are dead. Right-click the " .. console.displayName
                          .. " -> Insert Battery (needs a charged Battery)."
                end
            else
                reason = tvReason(playerObj)
            end
            if not reason then
                local carts = PZEMUMain.scanNearbyCartridges(playerObj, SCAN_RANGE, consoleId)
                if #carts == 0 then
                    reason = "No " .. console.displayName .. " cartridges" .. MSG_RANGE .. "."
                end
            end
            addPlayOption(context, false, "Play " .. console.displayName, reason,
                          playerObj, onPlayConsole, consoleId, handheld)
            return
        end

        -- Cartridge right-click
        local systemId = CART_TYPE_TO_SYSTEM[fullType]
        if systemId then
            local console = PZEMUGame.getConsoleById(systemId)
            if not console then return end
            fixLegacyCartName(item, systemId)
            local data = getCartridgeData(item)
            local label = "Play " .. (data.gameName or item:getName())

            local reason = nil
            local handheld = nil
            if not pzfbReady() then
                reason = MSG_NO_PZFB
            elseif not data.romFile then
                reason = "This cartridge carries no game data (spawned outside the loot system?). It cannot be played."
            else
                local consoles = PZEMUMain.scanNearbyConsoles(playerObj, SCAN_RANGE)
                local stationary = false
                local deadHandheld = nil
                for _, con in ipairs(consoles) do
                    local conType = con:getFullType()
                    if CONSOLE_TYPE_TO_ID[conType] == systemId then
                        if HANDHELD_TYPES[conType] then
                            if handheldHasCharge(con) then
                                if not handheld then handheld = con end
                            else
                                deadHandheld = con
                            end
                        else
                            stationary = true
                        end
                    end
                end
                if handheld then
                    reason = nil
                elseif stationary then
                    reason = tvReason(playerObj)
                elseif deadHandheld then
                    reason = "The " .. console.displayName .. " nearby has dead batteries. Right-click it -> Insert Battery."
                else
                    reason = "No " .. console.displayName .. MSG_RANGE .. "."
                end
            end
            addPlayOption(context, false, label, reason, playerObj, onPlayCartridge, item, handheld)
            return
        end
    end
end

Events.OnFillInventoryObjectContextMenu.Add(function(player, context, items)
    local ok, err = pcall(inventoryContextMenuHandler, player, context, items)
    if not ok then
        print("[PZEMU] Inventory context menu error: " .. tostring(err))
    end
end)

-- ============================================================================
-- Mood effects
-- ============================================================================

local moodTickCounter = 0
local MOOD_INTERVAL = 3000

local function modifyStat(stats, statType, delta, minVal, maxVal)
    local current = stats:get(statType)
    stats:set(statType, math.max(minVal, math.min(maxVal, current + delta)))
end

local function onTick()
    if not PZEMUWindow.instance then
        moodTickCounter = 0
        return
    end

    local game = PZEMUWindow.instance.game
    if not game or game.state ~= "RUNNING" or game.paused or game.batteryDead then
        moodTickCounter = 0
        return
    end

    moodTickCounter = moodTickCounter + 1
    if moodTickCounter < MOOD_INTERVAL then return end
    moodTickCounter = 0

    local playerObj = getPlayer()
    if not playerObj then return end

    local stats = playerObj:getStats()
    modifyStat(stats, CharacterStat.UNHAPPINESS, -ZombRand(10, 26), 0.0, 100.0)
    modifyStat(stats, CharacterStat.BOREDOM, -ZombRand(20, 41), 0.0, 100.0)
    modifyStat(stats, CharacterStat.STRESS, -ZombRand(10, 21) / 100.0, 0.0, 1.0)
end

Events.OnTick.Add(onTick)

-- ============================================================================
-- Startup
-- ============================================================================

Events.OnGameStart.Add(function()
    if pzfbReady() then
        local sessions = (PZEMUGame.hasSessions and PZEMUGame.hasSessions()) and "session API" or "legacy slot"
        print("[PZEMU] PZFB available, version " .. tostring(PZFB.getVersion()) .. " (" .. sessions .. ")")
    else
        print("[PZEMU] WARNING: PZFB not available — emulation will not work")
    end
end)
