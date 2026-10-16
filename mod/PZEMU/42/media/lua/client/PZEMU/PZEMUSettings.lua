--
-- PZEMUSettings.lua — Client-side persistent settings (volume, first-run notice)
--
-- Stored in ~/Zomboid/Lua/PZEMU_settings.ini via getFileWriter/getFileReader.
-- PZ 42.20+ only allows ini/cfg/txt/log/json extensions for getFileWriter
-- (anything else returns nil silently), so the name MUST stay ".ini".
--
-- The parse/serialize/quantize helpers are pure Lua so they can be unit-tested
-- outside the game (see tests in the pzemu repo). Everything that touches PZ
-- globals is pcall-guarded, so a missing/blocked file never raises.
--
-- This file deliberately has no dependency on PZEMUMain.lua or
-- PZEMU_Distributions.lua (third-party mods ship replacements of those).
--

PZEMUSettings = PZEMUSettings or {}

PZEMUSettings.FILE = "PZEMU_settings.ini"

-- Volume is stored as a percentage 0..100. Keys change it in STEP increments.
PZEMUSettings.VOLUME_STEP    = 10
PZEMUSettings.VOLUME_DEFAULT = 50   -- fallback when no sandbox default is available

-- ---------- pure helpers ----------

--- Clamp and round a volume percentage to an integer in [0, 100].
function PZEMUSettings.clampVolume(pct)
    pct = tonumber(pct)
    if not pct then return PZEMUSettings.VOLUME_DEFAULT end
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    return math.floor(pct + 0.5)
end

--- Convert a percentage (0..100) and a mute flag into the wire byte expected by
--- the bridge (C4 keycode 68): 0..255 linear gain, 0 = mute.
function PZEMUSettings.volumeToByte(pct, muted)
    if muted then return 0 end
    pct = PZEMUSettings.clampVolume(pct)
    local b = math.floor(pct * 255 / 100 + 0.5)
    if b < 0 then b = 0 end
    if b > 255 then b = 255 end
    return b
end

--- Parse "key=value" lines into a table of strings. Blank lines and lines
--- starting with '#' or ';' are ignored. Whitespace around key/value is trimmed.
function PZEMUSettings.parseLines(lines)
    local out = {}
    for _, line in ipairs(lines or {}) do
        local s = string.gsub(line, "^%s+", "")
        s = string.gsub(s, "%s+$", "")
        local first = string.sub(s, 1, 1)
        if s ~= "" and first ~= "#" and first ~= ";" and first ~= "[" then
            local k, v = string.match(s, "^([%w_%.]+)%s*=%s*(.*)$")
            if k then
                out[k] = v
            end
        end
    end
    return out
end

--- Serialize a flat table into sorted "key=value" lines.
function PZEMUSettings.serializeLines(tbl)
    local keys = {}
    for k, _ in pairs(tbl) do table.insert(keys, k) end
    table.sort(keys)
    local lines = { "# PZEMU client settings (generated — edit while PZ is closed)" }
    for _, k in ipairs(keys) do
        local v = tbl[k]
        if type(v) == "boolean" then v = v and "1" or "0" end
        table.insert(lines, k .. "=" .. tostring(v))
    end
    return lines
end

-- ---------- state ----------

PZEMUSettings._data = nil      -- parsed string table, lazily loaded
PZEMUSettings._loaded = false

local function sandboxDefaultVolume()
    local ok, v = pcall(function()
        if SandboxVars and SandboxVars.PZEMU and SandboxVars.PZEMU.DefaultVolume ~= nil then
            return SandboxVars.PZEMU.DefaultVolume
        end
        return nil
    end)
    if ok and type(v) == "number" then return PZEMUSettings.clampVolume(v) end
    return PZEMUSettings.VOLUME_DEFAULT
end

local function readAllLines()
    local lines = {}
    local ok = pcall(function()
        if not getFileReader then return end
        local reader = getFileReader(PZEMUSettings.FILE, false)
        if not reader then return end
        local line = reader:readLine()
        while line do
            table.insert(lines, line)
            line = reader:readLine()
        end
        reader:close()
    end)
    if not ok then return {} end
    return lines
end

function PZEMUSettings.load()
    if PZEMUSettings._loaded then return end
    PZEMUSettings._loaded = true
    PZEMUSettings._data = PZEMUSettings.parseLines(readAllLines())
end

function PZEMUSettings.save()
    PZEMUSettings.load()
    local ok, err = pcall(function()
        if not getFileWriter then return end
        local writer = getFileWriter(PZEMUSettings.FILE, true, false)
        if not writer then return end  -- allowlist/IO failure: silent nil in 42.20+
        for _, line in ipairs(PZEMUSettings.serializeLines(PZEMUSettings._data)) do
            writer:writeln(line)
        end
        writer:close()
    end)
    if not ok then
        print("[PZEMU] settings save failed: " .. tostring(err))
    end
end

function PZEMUSettings.getRaw(key)
    PZEMUSettings.load()
    return PZEMUSettings._data[key]
end

function PZEMUSettings.setRaw(key, value)
    PZEMUSettings.load()
    if type(value) == "boolean" then value = value and "1" or "0" end
    PZEMUSettings._data[key] = tostring(value)
end

-- ---------- typed accessors ----------

--- Current volume percentage (0..100). Falls back to the sandbox default, then 50.
function PZEMUSettings.getVolume()
    local raw = tonumber(PZEMUSettings.getRaw("volume"))
    if raw == nil then return sandboxDefaultVolume() end
    return PZEMUSettings.clampVolume(raw)
end

function PZEMUSettings.setVolume(pct)
    PZEMUSettings.setRaw("volume", PZEMUSettings.clampVolume(pct))
    PZEMUSettings.save()
end

function PZEMUSettings.isMuted()
    return PZEMUSettings.getRaw("muted") == "1"
end

function PZEMUSettings.setMuted(muted)
    PZEMUSettings.setRaw("muted", muted and true or false)
    PZEMUSettings.save()
end

--- Wire byte for the current settings (see volumeToByte).
function PZEMUSettings.volumeByte()
    return PZEMUSettings.volumeToByte(PZEMUSettings.getVolume(), PZEMUSettings.isMuted())
end

--- Step the volume by +/- VOLUME_STEP. Unmutes. Returns the new percentage.
function PZEMUSettings.stepVolume(dir)
    local v = PZEMUSettings.getVolume()
    if dir > 0 then v = v + PZEMUSettings.VOLUME_STEP else v = v - PZEMUSettings.VOLUME_STEP end
    v = PZEMUSettings.clampVolume(v)
    PZEMUSettings.setRaw("volume", v)
    PZEMUSettings.setRaw("muted", false)
    PZEMUSettings.save()
    return v
end

--- Toggle mute. Returns the new mute state.
function PZEMUSettings.toggleMute()
    local m = not PZEMUSettings.isMuted()
    PZEMUSettings.setMuted(m)
    return m
end

--- First-run "bring your own ROMs" notice acknowledgement.
function PZEMUSettings.isRomNoticeAcknowledged()
    return PZEMUSettings.getRaw("romNoticeAck") == "1"
end

function PZEMUSettings.acknowledgeRomNotice()
    PZEMUSettings.setRaw("romNoticeAck", true)
    PZEMUSettings.save()
end
