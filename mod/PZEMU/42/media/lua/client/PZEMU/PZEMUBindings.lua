--
-- PZEMUBindings.lua — Per-console remappable keyboard bindings
--
-- Data model
--   A console definition (see PZEMUGame.lua CONSOLES) carries an ordered
--   `buttons` list: { id = <libretro button 0..15>, label = "B", keys = {k1, k2} }
--   where `keys` are the DEFAULT LWJGL key codes. User overrides are stored as
--     bindings[consoleId][buttonId] = { k1 [, k2] }   -- {} means "unbound"
--   Buttons without an override use their defaults, minus any key an override
--   claimed (user keys always win over defaults).
--
-- Persistence: ~/Zomboid/Lua/PZEMU_keys.ini (getFileWriter allowlist: .ini is OK)
--     [nes]
--     4=17          ; button id = key[,key]
--     0=36,44
--   Unknown sections/buttons, out-of-range keys, reserved keys and duplicate
--   keys are dropped on load (first button in definition order wins).
--
-- Reserved keys can never be bound: ESC (freeze), F5/F7 (save/load state),
-- Scroll Lock (input lock) and the volume keys - / = / M.
--
-- Everything here is pure Lua except load()/save() (pcall-guarded PZ file IO)
-- and keyName() (uses the global getKeyName when present). No dependency on
-- PZEMUMain.lua or PZEMU_Distributions.lua — third-party mods replace those.
--

PZEMUBindings = PZEMUBindings or {}

PZEMUBindings.FILE = "PZEMU_keys.ini"
PZEMUBindings.MAX_KEYS_PER_BUTTON = 2
PZEMUBindings.KEY_MIN = 1
PZEMUBindings.KEY_MAX = 255

-- Verified against org.lwjglx.input.Keyboard in the PZ 42.21 jar (javap -constants):
-- KEY_ESCAPE=1, KEY_MINUS=12, KEY_EQUALS=13, KEY_M=50, KEY_F5=63, KEY_F7=65, KEY_SCROLL=70
PZEMUBindings.RESERVED = {
    [1]  = "Escape (freeze / unfreeze)",
    [63] = "F5 (save state)",
    [65] = "F7 (load state)",
    [70] = "Scroll Lock (lock / unlock input)",
    [12] = "- (volume down)",
    [13] = "= (volume up)",
    [50] = "M (mute)",
}

PZEMUBindings.PRESET_WASD_DESCRIPTION =
    "WASD preset: D-pad on W/A/S/D. Face buttons move to J/K/L (and U/I/O for " ..
    "SNES Y/X and Genesis X/Y/Z), shoulders on Q/E, Start = Enter, Select = Right Shift. " ..
    "Z/X/C stay as alternate face keys."

-- ---------- small pure helpers ----------

local function copyList(t)
    local out = {}
    for i, v in ipairs(t or {}) do out[i] = v end
    return out
end

local function listContains(t, v)
    for _, x in ipairs(t or {}) do
        if x == v then return true end
    end
    return false
end

local function listWithout(t, v)
    local out = {}
    for _, x in ipairs(t or {}) do
        if x ~= v then table.insert(out, x) end
    end
    return out
end

local function findButton(console, btnId)
    for _, b in ipairs(console.buttons or {}) do
        if b.id == btnId then return b end
    end
    return nil
end

function PZEMUBindings.isReserved(key)
    return PZEMUBindings.RESERVED[key] ~= nil
end

--- A key is bindable when it is an integer in [KEY_MIN, KEY_MAX] and not reserved.
--- Returns ok, reason.
function PZEMUBindings.validateKey(key)
    if type(key) ~= "number" or key ~= math.floor(key) then
        return false, "not a key code"
    end
    if key < PZEMUBindings.KEY_MIN or key > PZEMUBindings.KEY_MAX then
        return false, "key code out of range"
    end
    if PZEMUBindings.RESERVED[key] then
        return false, "reserved: " .. PZEMUBindings.RESERVED[key]
    end
    return true
end

--- Human-readable key name (LWJGL name via PZ's getKeyName when available).
function PZEMUBindings.keyName(key)
    if key == nil then return "(none)" end
    if getKeyName then
        local ok, name = pcall(getKeyName, key)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    return "key " .. tostring(key)
end

--- "Z / A" style text for a key list.
function PZEMUBindings.keysText(keys)
    if not keys or #keys == 0 then return "(none)" end
    local parts = {}
    for _, k in ipairs(keys) do table.insert(parts, PZEMUBindings.keyName(k)) end
    return table.concat(parts, " / ")
end

-- ---------- parse / validate / serialize ----------

--- Parse ini-style lines into a raw table: raw[section][buttonId] = { numbers }.
--- No semantic validation here (see validate()).
function PZEMUBindings.parseLines(lines)
    local raw = {}
    local section = nil
    for _, line in ipairs(lines or {}) do
        local s = string.gsub(line, "^%s+", "")
        s = string.gsub(s, "%s+$", "")
        -- strip trailing ; comments
        s = string.gsub(s, "%s*;.*$", "")
        local first = string.sub(s, 1, 1)
        if s == "" or first == "#" then
            -- skip
        elseif first == "[" then
            section = string.match(s, "^%[([%w_%-]+)%]$")
            if section then
                raw[section] = raw[section] or {}
            end
        elseif section then
            local idStr, rest = string.match(s, "^(%d+)%s*=%s*(.*)$")
            if idStr then
                local keys = {}
                for tok in string.gmatch(rest, "[^,%s]+") do
                    local n = tonumber(tok)
                    if n then table.insert(keys, n) end
                end
                raw[section][tonumber(idStr)] = keys
            end
        end
    end
    return raw
end

--- Validate raw bindings against console definitions. Returns a clean table.
--- Rules: unknown console sections and unknown button ids are dropped; keys must
--- pass validateKey(); duplicates inside a button are collapsed; a key already
--- used by an earlier button (definition order) is dropped from later buttons;
--- at most MAX_KEYS_PER_BUTTON keys per button.
function PZEMUBindings.validate(raw, consoles)
    local clean = {}
    for _, console in ipairs(consoles or {}) do
        local section = raw and raw[console.id]
        if section and console.buttons then
            local out = {}
            local used = {}
            local any = false
            for _, b in ipairs(console.buttons) do
                local keys = section[b.id]
                if keys then
                    local kept = {}
                    for _, k in ipairs(keys) do
                        local ok = PZEMUBindings.validateKey(k)
                        if ok and not used[k] and not listContains(kept, k)
                           and #kept < PZEMUBindings.MAX_KEYS_PER_BUTTON then
                            table.insert(kept, k)
                            used[k] = true
                        end
                    end
                    out[b.id] = kept
                    any = true
                end
            end
            if any then clean[console.id] = out end
        end
    end
    return clean
end

--- Serialize clean bindings into ini lines (sorted, deterministic).
function PZEMUBindings.serializeLines(clean)
    local lines = {
        "# PZEMU key bindings (generated). Format: [console] then buttonId=key[,key]",
        "# Delete this file to restore the defaults for every console.",
    }
    local ids = {}
    for cid, _ in pairs(clean or {}) do table.insert(ids, cid) end
    table.sort(ids)
    for _, cid in ipairs(ids) do
        table.insert(lines, "[" .. cid .. "]")
        local btnIds = {}
        for bid, _ in pairs(clean[cid]) do table.insert(btnIds, bid) end
        table.sort(btnIds)
        for _, bid in ipairs(btnIds) do
            local parts = {}
            for _, k in ipairs(clean[cid][bid]) do table.insert(parts, tostring(k)) end
            table.insert(lines, tostring(bid) .. "=" .. table.concat(parts, ","))
        end
    end
    return lines
end

-- ---------- effective bindings / key map ----------

--- Effective key list per button: override if present, else defaults minus any
--- key an override claimed. Returns eff[buttonId] = { keys }.
function PZEMUBindings.effectiveKeys(console, consoleBindings)
    consoleBindings = consoleBindings or {}
    local claimed = {}
    for _, keys in pairs(consoleBindings) do
        for _, k in ipairs(keys) do claimed[k] = true end
    end
    local eff = {}
    for _, b in ipairs(console.buttons or {}) do
        if consoleBindings[b.id] then
            eff[b.id] = copyList(consoleBindings[b.id])
        else
            local keys = {}
            for _, k in ipairs(b.keys or {}) do
                if not claimed[k] then table.insert(keys, k) end
            end
            eff[b.id] = keys
        end
    end
    return eff
end

--- Build the LWJGL-key -> libretro-button map actually used at runtime.
--- Starts from console.keyMap (which includes the meta keys and any extra keys a
--- third-party mod may have added), removes the DEFAULT keys of every defined
--- button, then inserts the effective keys. Keys of unmodified buttons stay as
--- they were; third-party extras that are not defaults are preserved.
function PZEMUBindings.buildKeyMap(console, consoleBindings)
    local map = {}
    for k, v in pairs(console.keyMap or {}) do map[k] = v end
    if not console.buttons then return map end
    for _, b in ipairs(console.buttons) do
        for _, k in ipairs(b.keys or {}) do
            if map[k] == b.id then map[k] = nil end
        end
    end
    local eff = PZEMUBindings.effectiveKeys(console, consoleBindings)
    for _, b in ipairs(console.buttons) do
        for _, k in ipairs(eff[b.id] or {}) do
            map[k] = b.id
        end
    end
    return map
end

--- Assign `key` to slot `slot` (1 or 2) of button `btnId`.
--- Any other button currently using that key loses it (stealing). Returns
--- newBindings, stolenFromLabel|nil, errorReason|nil. On error nothing changes.
function PZEMUBindings.assign(console, consoleBindings, btnId, slot, key)
    local ok, reason = PZEMUBindings.validateKey(key)
    if not ok then return consoleBindings, nil, reason end
    local target = findButton(console, btnId)
    if not target then return consoleBindings, nil, "unknown button" end
    if slot ~= 1 and slot ~= 2 then slot = 1 end

    local eff = PZEMUBindings.effectiveKeys(console, consoleBindings)
    local out = {}
    for bid, keys in pairs(consoleBindings or {}) do out[bid] = copyList(keys) end

    local stolen = nil
    for _, b in ipairs(console.buttons) do
        if b.id ~= btnId and listContains(eff[b.id], key) then
            out[b.id] = listWithout(eff[b.id], key)
            stolen = b.label
        end
    end

    local keys = listWithout(eff[btnId], key)  -- drop a duplicate in the other slot
    -- place into the requested slot, keeping the other slot's key
    local newKeys = {}
    if slot == 1 then
        table.insert(newKeys, key)
        if keys[1] then table.insert(newKeys, keys[1]) end
    else
        if keys[1] then table.insert(newKeys, keys[1]) end
        table.insert(newKeys, key)
    end
    while #newKeys > PZEMUBindings.MAX_KEYS_PER_BUTTON do table.remove(newKeys) end
    out[btnId] = newKeys
    return out, stolen, nil
end

--- Remove the key in slot `slot` of button `btnId`. Returns new bindings.
function PZEMUBindings.clearSlot(console, consoleBindings, btnId, slot)
    local eff = PZEMUBindings.effectiveKeys(console, consoleBindings)
    local out = {}
    for bid, keys in pairs(consoleBindings or {}) do out[bid] = copyList(keys) end
    local keys = copyList(eff[btnId] or {})
    if keys[slot] then table.remove(keys, slot) end
    out[btnId] = keys
    return out
end

--- Return a fresh bindings table for a named preset of this console
--- (console.presets[name] = { [buttonId] = {keys} }), or nil if absent.
function PZEMUBindings.applyPreset(console, name)
    local preset = console.presets and console.presets[name]
    if not preset then return nil end
    local out = {}
    for bid, keys in pairs(preset) do out[bid] = copyList(keys) end
    return out
end

--- Lines like "D-pad Up  =  W" for display (welcome screen).
function PZEMUBindings.describe(console, consoleBindings)
    local lines = {}
    if not console.buttons then return lines end
    local eff = PZEMUBindings.effectiveKeys(console, consoleBindings)
    for _, b in ipairs(console.buttons) do
        table.insert(lines, b.label .. "  =  " .. PZEMUBindings.keysText(eff[b.id]))
    end
    return lines
end

-- ---------- persistence ----------

PZEMUBindings._data = nil
PZEMUBindings._loaded = false
PZEMUBindings._consoles = {}

--- Register the console definitions used for validation (PZEMUGame calls this).
function PZEMUBindings.registerConsoles(consoles)
    PZEMUBindings._consoles = consoles or {}
end

local function readAllLines()
    local lines = {}
    local ok = pcall(function()
        if not getFileReader then return end
        local reader = getFileReader(PZEMUBindings.FILE, false)
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

function PZEMUBindings.load()
    if PZEMUBindings._loaded then return end
    PZEMUBindings._loaded = true
    local raw = PZEMUBindings.parseLines(readAllLines())
    PZEMUBindings._data = PZEMUBindings.validate(raw, PZEMUBindings._consoles)
end

function PZEMUBindings.save()
    PZEMUBindings.load()
    local ok, err = pcall(function()
        if not getFileWriter then return end
        local writer = getFileWriter(PZEMUBindings.FILE, true, false)
        if not writer then return end
        for _, line in ipairs(PZEMUBindings.serializeLines(PZEMUBindings._data)) do
            writer:writeln(line)
        end
        writer:close()
    end)
    if not ok then
        print("[PZEMU] key bindings save failed: " .. tostring(err))
    end
end

--- Current override table for a console id (may be nil = all defaults).
function PZEMUBindings.get(consoleId)
    PZEMUBindings.load()
    return PZEMUBindings._data[consoleId]
end

--- Replace the override table for a console id and persist. nil = defaults.
function PZEMUBindings.set(consoleId, consoleBindings)
    PZEMUBindings.load()
    if consoleBindings then
        -- keep the file tidy: an override identical to "no override" is still
        -- stored, since it may intentionally unbind a key
        local any = false
        for _, _ in pairs(consoleBindings) do any = true break end
        if not any then consoleBindings = nil end
    end
    PZEMUBindings._data[consoleId] = consoleBindings
    PZEMUBindings.save()
end

--- Effective runtime key map for a console (defaults + user overrides + meta).
function PZEMUBindings.keyMapFor(console)
    if not console then return {} end
    return PZEMUBindings.buildKeyMap(console, PZEMUBindings.get(console.id))
end
