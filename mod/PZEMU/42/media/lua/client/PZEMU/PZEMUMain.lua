--
-- PZEMUMain.lua — Entry point, context menu hook for TV right-click
--
-- Adds "Play Console" option when right-clicking a TV (IsoWaveSignal without RadioItemID).
-- Requires PZFB mod for framebuffer rendering and game process management.
--

require "PZEMU/PZEMUWindow"

PZEMUMain = {}

-- ---------- context menu callback ----------

function PZEMUMain.openEmulator(playerObj)
    PZEMUWindow.open()
end

-- ---------- context menu hook ----------

Events.OnFillWorldObjectContextMenu.Add(function(player, context, worldobjects, test)
    if test and ISWorldObjectContextMenu.Test then return true end

    -- Check PZFB availability
    if not PZFB or not PZFB.isAvailable() then return end

    -- Look for a TV in the clicked objects
    for _, object in ipairs(worldobjects) do
        -- TV = IsoWaveSignal without RadioItemID moddata (verified from ISRadioAndTvMenu.lua)
        if instanceof(object, "IsoWaveSignal") and object:getSprite()
           and not object:getModData().RadioItemID then
            local playerObj = getSpecificPlayer(player)
            context:addOption("Play Console", playerObj, PZEMUMain.openEmulator)
            return
        end
    end
end)

-- ---------- startup diagnostic ----------

Events.OnGameStart.Add(function()
    if PZFB and PZFB.isAvailable() then
        print("[PZEMU] PZFB available, version " .. tostring(PZFB.getVersion()))
    else
        print("[PZEMU] WARNING: PZFB not available — emulation will not work")
    end
end)
