--
-- PZEMU_Distributions.lua — Server-side loot table patching + cartridge spawning
--
-- Injects console items into ProceduralDistributions tables.
-- OnFillContainer spawns cartridges alongside consoles with weighted game pools.
--

require "Items/ProceduralDistributions"

-- ============================================================================
-- Console distribution — inject into existing loot tables
-- ============================================================================

-- Safe sandbox-var accessor: returns default when SandboxVars.PZEMU isn't populated yet
-- (first run after install, saves from before this option existed, etc.)
local function pzemuSandboxDouble(name, defaultValue)
    if SandboxVars and SandboxVars.PZEMU and SandboxVars.PZEMU[name] ~= nil then
        return SandboxVars.PZEMU[name]
    end
    return defaultValue
end

local function addToDistribution(tableName, itemName, weight)
    local data = ProceduralDistributions.list[tableName]
    if not data then return end
    local mult = pzemuSandboxDouble("ConsoleRateMultiplier", 1.0)
    local scaledWeight = weight * mult
    -- Skip entirely if multiplier is 0 — avoids weight-0 entries in loot tables
    if scaledWeight <= 0 then return end
    table.insert(data.items, itemName)
    table.insert(data.items, scaledWeight)
end

local consoleDistributionsApplied = false

local function applyConsoleDistributions()
    -- Guard against double-registration: if the mod is on a player-hosted MP
    -- instance, both OnGameStart (client-side IngameState) and OnServerStarted
    -- (host's GameServer) will fire. We only want to add items once.
    if consoleDistributionsApplied then return end
    consoleDistributionsApplied = true

-- NES — ubiquitous in 1993, nearly every household with kids
addToDistribution("LivingRoomShelf",              "PZEMU.NES_Console", 8)
addToDistribution("BedroomDresserChild",           "PZEMU.NES_Console", 6)
addToDistribution("LivingRoomShelfClassy",         "PZEMU.NES_Console", 6)
addToDistribution("LivingRoomShelfRedneck",        "PZEMU.NES_Console", 3)
addToDistribution("ElectronicStoreMisc",           "PZEMU.NES_Console", 15)
addToDistribution("GigamartHouseElectronics",      "PZEMU.NES_Console", 12)

-- SNES — hot new console (1991), more common in wealthier homes
addToDistribution("LivingRoomShelf",              "PZEMU.SNES_Console", 4)
addToDistribution("BedroomDresserChild",           "PZEMU.SNES_Console", 3)
addToDistribution("LivingRoomShelfClassy",         "PZEMU.SNES_Console", 8)
addToDistribution("LivingRoomShelfRedneck",        "PZEMU.SNES_Console", 1)
addToDistribution("ElectronicStoreMisc",           "PZEMU.SNES_Console", 12)
addToDistribution("GigamartHouseElectronics",      "PZEMU.SNES_Console", 10)

-- Genesis — SNES competitor, slightly less popular in US
addToDistribution("LivingRoomShelf",              "PZEMU.Genesis_Console", 4)
addToDistribution("BedroomDresserChild",           "PZEMU.Genesis_Console", 3)
addToDistribution("LivingRoomShelfClassy",         "PZEMU.Genesis_Console", 6)
addToDistribution("LivingRoomShelfRedneck",        "PZEMU.Genesis_Console", 2)
addToDistribution("ElectronicStoreMisc",           "PZEMU.Genesis_Console", 12)
addToDistribution("GigamartHouseElectronics",      "PZEMU.Genesis_Console", 10)

-- Game Boy — portable, very common, found everywhere kids go
addToDistribution("BedroomDresserChild",           "PZEMU.GameBoy_Console", 8)
addToDistribution("SchoolLockers",                 "PZEMU.GameBoy_Console", 3)
addToDistribution("WardrobeChild",                 "PZEMU.GameBoy_Console", 4)
addToDistribution("BedroomDresserClassy",          "PZEMU.GameBoy_Console", 6)
addToDistribution("BedroomDresserRedneck",         "PZEMU.GameBoy_Console", 3)
addToDistribution("ElectronicStoreMisc",           "PZEMU.GameBoy_Console", 15)
addToDistribution("GigamartHouseElectronics",      "PZEMU.GameBoy_Console", 12)

-- Atari 2600 — obsolete by 1993, found in storage/garages
addToDistribution("ClosetShelfGeneric",            "PZEMU.Atari2600_Console", 4)
addToDistribution("GarageTools",                   "PZEMU.Atari2600_Console", 3)
addToDistribution("BedroomDresserChild",           "PZEMU.Atari2600_Console", 1)
addToDistribution("LivingRoomShelfClassy",         "PZEMU.Atari2600_Console", 1)
addToDistribution("LivingRoomShelfRedneck",        "PZEMU.Atari2600_Console", 5)
addToDistribution("ElectronicStoreMisc",           "PZEMU.Atari2600_Console", 2)

-- Game Gear — expensive portable ($150), rarer than Game Boy
addToDistribution("BedroomDresserChild",           "PZEMU.GameGear_Console", 1.5)
addToDistribution("SchoolLockers",                 "PZEMU.GameGear_Console", 1)
addToDistribution("WardrobeChild",                 "PZEMU.GameGear_Console", 1)
addToDistribution("BedroomDresserClassy",          "PZEMU.GameGear_Console", 3)
addToDistribution("ElectronicStoreMisc",           "PZEMU.GameGear_Console", 6)
addToDistribution("GigamartHouseElectronics",      "PZEMU.GameGear_Console", 5)

-- Master System — rare in US by 1993
addToDistribution("ElectronicStoreMisc",           "PZEMU.SMS_Console", 3)
addToDistribution("LivingRoomShelf",              "PZEMU.SMS_Console", 0.5)
addToDistribution("LivingRoomShelfClassy",         "PZEMU.SMS_Console", 1)
addToDistribution("LivingRoomShelfRedneck",        "PZEMU.SMS_Console", 0.5)

    -- After modifying ProceduralDistributions.list, re-parse so the Java-side
    -- loot tables pick up the new entries. Pattern verified against
    -- VFE/VFE_Distributions.lua:1635 which uses the same Parse() call.
    -- Required because we run AFTER the initial IsoWorld.init() ItemPickerJava.Parse()
    -- at IsoWorld:2117 bytecode. Running earlier (OnPreDistributionMerge at
    -- IsoWorld:2024) would not have SandboxVars populated — SandboxOptions.load()
    -- -> toLua() runs at IsoWorld:2096, AFTER OnPreDistributionMerge. For loaded
    -- saves this means the user's per-save sandbox value isn't visible in time.
    ItemPickerJava.Parse()
end  -- applyConsoleDistributions

-- Register on BOTH events so loot distribution works in every mode:
--   Single-player: IngameState fires OnGameStart (GameServer doesn't run).
--   Dedicated server: GameServer fires OnServerStarted (no IngameState).
--   Player-hosted MP: both fire; the applied-guard prevents double-add.
-- Verified OnServerStarted trigger at zombie/network/GameServer.class bytecode 230.
Events.OnGameStart.Add(applyConsoleDistributions)
Events.OnServerStarted.Add(applyConsoleDistributions)

-- ============================================================================
-- Game pools — weighted lists for cartridge spawning
-- ============================================================================

-- Each entry: { name, romFile, namedItem (or nil for generic), weight }
-- namedItem = specific item ID with dedicated icon, nil = use generic cartridge

local NES_GAME_POOL = {
    { name = "Super Mario Bros.",        romFile = "Super_Mario_Bros.nes",         namedItem = "PZEMU.NES_Cart_Mario",   weight = 50 },
    { name = "Super Mario Bros. 3",      romFile = "Super_Mario_Bros_3.nes",       namedItem = nil,                      weight = 35 },
    { name = "The Legend of Zelda",       romFile = "Legend_of_Zelda.nes",          namedItem = "PZEMU.NES_Cart_Zelda",   weight = 30 },
    { name = "Contra",                   romFile = "Contra.nes",                   namedItem = "PZEMU.NES_Cart_Contra",  weight = 25 },
    { name = "Mega Man 2",               romFile = "Mega_Man_2.nes",              namedItem = "PZEMU.NES_Cart_MegaMan", weight = 20 },
    { name = "Metroid",                  romFile = "Metroid.nes",                  namedItem = "PZEMU.NES_Cart_Metroid", weight = 15 },
    { name = "Castlevania",              romFile = "Castlevania.nes",              namedItem = nil,                      weight = 15 },
    { name = "Mike Tyson's Punch-Out!!", romFile = "Mike_Tysons_Punch_Out.nes",   namedItem = nil,                      weight = 15 },
    { name = "Marble Madness",           romFile = "Marble_Madness.nes",           namedItem = nil,                      weight = 10 },
    { name = "Dragon Warrior",           romFile = "Dragon_Warrior.nes",           namedItem = nil,                      weight = 5 },
    { name = "Dragon Warrior II",        romFile = "Dragon_Warrior_II.nes",        namedItem = nil,                      weight = 2 },
    { name = "Dragon Warrior III",       romFile = "Dragon_Warrior_III.nes",       namedItem = nil,                      weight = 1 },
    { name = "Dragon Warrior IV",        romFile = "Dragon_Warrior_IV.nes",        namedItem = nil,                      weight = 1 },
    { name = "Adventure Island",         romFile = "Adventure_Island.nes",         namedItem = nil,                      weight = 8 },
    { name = "Adventure Island II",      romFile = "Adventure_Island_II.nes",      namedItem = nil,                      weight = 5 },
    { name = "Baseball Stars",           romFile = "Baseball_Stars.nes",           namedItem = nil,                      weight = 5 },
    { name = "Batman: The Video Game",   romFile = "Batman_The_Video_Game.nes",    namedItem = nil,                      weight = 10 },
    { name = "Battletoads",              romFile = "Battletoads.nes",              namedItem = nil,                      weight = 12 },
    { name = "Bionic Commando",          romFile = "Bionic_Commando.nes",          namedItem = nil,                      weight = 8 },
    { name = "Blades of Steel",          romFile = "Blades_of_Steel.nes",          namedItem = nil,                      weight = 8 },
    { name = "Blaster Master",           romFile = "Blaster_Master.nes",           namedItem = nil,                      weight = 10 },
    { name = "Bomberman",                romFile = "Bomberman.nes",                namedItem = nil,                      weight = 8 },
    { name = "Bubble Bobble",            romFile = "Bubble_Bobble.nes",            namedItem = nil,                      weight = 10 },
    { name = "Castlevania II: Simon's Quest", romFile = "Castlevania_II_Simons_Quest.nes", namedItem = nil,              weight = 10 },
    { name = "Castlevania III: Dracula's Curse", romFile = "Castlevania_III_Draculas_Curse.nes", namedItem = nil,        weight = 8 },
    { name = "Crystalis",                romFile = "Crystalis.nes",                namedItem = nil,                      weight = 5 },
    { name = "Double Dragon",            romFile = "Double_Dragon.nes",            namedItem = nil,                      weight = 12 },
    { name = "Double Dragon II",         romFile = "Double_Dragon_II.nes",         namedItem = nil,                      weight = 8 },
    { name = "Dr. Mario",                romFile = "Dr_Mario.nes",                 namedItem = nil,                      weight = 15 },
    { name = "DuckTales",                romFile = "DuckTales.nes",                namedItem = nil,                      weight = 12 },
    { name = "Excitebike",               romFile = "Excitebike.nes",               namedItem = nil,                      weight = 15 },
    { name = "Faxanadu",                 romFile = "Faxanadu.nes",                 namedItem = nil,                      weight = 5 },
    { name = "Final Fantasy",            romFile = "Final_Fantasy.nes",            namedItem = nil,                      weight = 8 },
    { name = "Ghosts 'n Goblins",        romFile = "Ghosts_n_Goblins.nes",         namedItem = nil,                      weight = 8 },
    { name = "Gradius",                  romFile = "Gradius.nes",                  namedItem = nil,                      weight = 10 },
    { name = "Ice Climber",              romFile = "Ice_Climber.nes",              namedItem = nil,                      weight = 10 },
    { name = "Jackal",                   romFile = "Jackal.nes",                   namedItem = nil,                      weight = 5 },
    { name = "Kid Icarus",               romFile = "Kid_Icarus.nes",               namedItem = nil,                      weight = 8 },
    { name = "Kung Fu",                  romFile = "Kung_Fu.nes",                  namedItem = nil,                      weight = 10 },
    { name = "Life Force",               romFile = "Life_Force.nes",               namedItem = nil,                      weight = 8 },
    { name = "Mega Man 3",               romFile = "Mega_Man_3.nes",               namedItem = nil,                      weight = 12 },
    { name = "Metal Gear",               romFile = "Metal_Gear.nes",               namedItem = nil,                      weight = 8 },
    { name = "Ninja Gaiden",             romFile = "Ninja_Gaiden.nes",             namedItem = nil,                      weight = 12 },
    { name = "Ninja Gaiden II",          romFile = "Ninja_Gaiden_II.nes",          namedItem = nil,                      weight = 8 },
    { name = "R.C. Pro-Am",              romFile = "RC_Pro_Am.nes",                namedItem = nil,                      weight = 10 },
    { name = "River City Ransom",        romFile = "River_City_Ransom.nes",        namedItem = nil,                      weight = 8 },
    { name = "StarTropics",              romFile = "StarTropics.nes",              namedItem = nil,                      weight = 5 },
    { name = "Super Mario Bros. 2",      romFile = "Super_Mario_Bros_2.nes",       namedItem = nil,                      weight = 30 },
    { name = "Tecmo Bowl",               romFile = "Tecmo_Bowl.nes",               namedItem = nil,                      weight = 10 },
    { name = "Tecmo Super Bowl",         romFile = "Tecmo_Super_Bowl.nes",         namedItem = nil,                      weight = 8 },
    { name = "Tetris",                   romFile = "Tetris.nes",                   namedItem = nil,                      weight = 40 },
    { name = "TMNT",                     romFile = "TMNT.nes",                     namedItem = nil,                      weight = 12 },
    { name = "TMNT II: The Arcade Game", romFile = "TMNT_II_The_Arcade_Game.nes",  namedItem = nil,                      weight = 10 },
    { name = "TMNT III: The Manhattan Project", romFile = "TMNT_III_The_Manhattan_Project.nes", namedItem = nil,          weight = 5 },
    { name = "Zelda II: The Adventure of Link", romFile = "Zelda_II_The_Adventure_of_Link.nes", namedItem = nil,          weight = 15 },
    { name = "Kirby's Adventure",        romFile = "Kirbys_Adventure.nes",         namedItem = nil,                      weight = 12 },
    { name = "Lode Runner",              romFile = "Lode_Runner.nes",              namedItem = nil,                      weight = 5 },
    { name = "Maniac Mansion",           romFile = "Maniac_Mansion.nes",           namedItem = nil,                      weight = 5 },
    -- Bundled homebrew (shipped with mod, always findable — hence reliable low weight)
    { name = "Chase",                    romFile = "Chase.nes",                    namedItem = nil,                      weight = 3 },
    { name = "LAN Master",               romFile = "Lan_Master.nes",               namedItem = nil,                      weight = 3 },
    { name = "Zooming Secretary",        romFile = "Zooming_Secretary.nes",        namedItem = nil,                      weight = 3 },
}

local SNES_GAME_POOL = {
    { name = "Super Mario World",        romFile = "Super_Mario_World.smc",        namedItem = "PZEMU.SNES_Cart_MarioWorld", weight = 50 },
    { name = "Zelda: A Link to the Past",romFile = "Zelda_A_Link_to_the_Past.smc", namedItem = "PZEMU.SNES_Cart_Zelda",     weight = 30 },
    { name = "Street Fighter II Turbo",  romFile = "Street_Fighter_2_Turbo.smc",   namedItem = "PZEMU.SNES_Cart_SF2",       weight = 25 },
    { name = "Super Metroid",            romFile = "Super_Metroid.smc",            namedItem = nil,                          weight = 20 },
    { name = "Donkey Kong Country",      romFile = "Donkey_Kong_Country_1.smc",    namedItem = nil,                          weight = 20 },
    { name = "Mega Man X",               romFile = "Mega_Man_X_1.smc",            namedItem = nil,                          weight = 15 },
    { name = "Mortal Kombat II",         romFile = "Mortal_Kombat_2.smc",          namedItem = "PZEMU.SNES_Cart_MK2",       weight = 15 },
    { name = "Chrono Trigger",           romFile = "Chrono_Trigger.smc",           namedItem = nil,                          weight = 5 },
    { name = "Castlevania: Dracula X",   romFile = "Castlevania_Dracula_X.smc",    namedItem = nil,                          weight = 5 },
    { name = "ActRaiser",                romFile = "ActRaiser.smc",                namedItem = nil,                          weight = 8 },
    { name = "Alien 3",                  romFile = "Alien_3.smc",                  namedItem = nil,                          weight = 5 },
    { name = "Axelay",                   romFile = "Axelay.smc",                   namedItem = nil,                          weight = 5 },
    { name = "Battletoads in Battlemaniacs", romFile = "Battletoads_in_Battlemaniacs.smc", namedItem = nil,                   weight = 8 },
    { name = "Contra III",               romFile = "Contra_III.smc",               namedItem = nil,                          weight = 12 },
    { name = "Cybernator",               romFile = "Cybernator.smc",               namedItem = nil,                          weight = 5 },
    { name = "Darius Twin",              romFile = "Darius_Twin.smc",              namedItem = nil,                          weight = 3 },
    { name = "E.V.O.: Search For Eden",  romFile = "EVO_Search_For_Eden.smc",      namedItem = nil,                          weight = 3 },
    { name = "F-Zero",                   romFile = "F-Zero.smc",                   namedItem = nil,                          weight = 20 },
    { name = "Final Fantasy II",         romFile = "Final_Fantasy_II.smc",         namedItem = nil,                          weight = 10 },
    { name = "Final Fight",              romFile = "Final_Fight.smc",              namedItem = nil,                          weight = 12 },
    { name = "Goof Troop",               romFile = "Goof_Troop.smc",               namedItem = nil,                          weight = 5 },
    { name = "Gradius III",              romFile = "Gradius_III.smc",              namedItem = nil,                          weight = 8 },
    { name = "Legend of the Mystical Ninja", romFile = "Legend_of_the_Mystical_Ninja.smc", namedItem = nil,                   weight = 5 },
    { name = "Lost Vikings",             romFile = "Lost_Vikings.smc",             namedItem = nil,                          weight = 5 },
    { name = "Mario Kart",               romFile = "Super_Mario_Kart.smc",         namedItem = nil,                          weight = 25 },
    { name = "Pilotwings",               romFile = "Pilotwings.smc",               namedItem = nil,                          weight = 8 },
    { name = "Prince of Persia",         romFile = "Prince_of_Persia.smc",         namedItem = nil,                          weight = 5 },
    { name = "Rock N Roll Racing",       romFile = "Rock_N_Roll_Racing.smc",       namedItem = nil,                          weight = 8 },
    { name = "Soul Blazer",              romFile = "Soul_Blazer.smc",              namedItem = nil,                          weight = 5 },
    { name = "Space Megaforce",          romFile = "Space_Megaforce.smc",          namedItem = nil,                          weight = 3 },
    { name = "Sunset Riders",            romFile = "Sunset_Riders.smc",            namedItem = nil,                          weight = 8 },
    { name = "Super Castlevania IV",     romFile = "Super_Castlevania_IV.smc",     namedItem = nil,                          weight = 10 },
    { name = "Super Double Dragon",      romFile = "Super_Double_Dragon.smc",      namedItem = nil,                          weight = 5 },
    { name = "Super Ghouls n Ghosts",    romFile = "Super_Ghouls_n_Ghosts.smc",    namedItem = nil,                          weight = 8 },
    { name = "Super R-Type",             romFile = "Super_R-Type.smc",             namedItem = nil,                          weight = 5 },
    { name = "Super Star Wars",          romFile = "Super_Star_Wars.smc",          namedItem = nil,                          weight = 8 },
    { name = "Super Tennis",             romFile = "Super_Tennis.smc",             namedItem = nil,                          weight = 5 },
    { name = "Super Turrican",           romFile = "Super_Turrican.smc",           namedItem = nil,                          weight = 3 },
    { name = "TMNT IV: Turtles in Time", romFile = "TMNT_IV_Turtles_in_Time.smc",  namedItem = nil,                          weight = 12 },
    { name = "Top Gear",                 romFile = "Top_Gear.smc",                 namedItem = nil,                          weight = 8 },
    { name = "UN Squadron",              romFile = "UN_Squadron.smc",              namedItem = nil,                          weight = 5 },
    { name = "Star Fox",                 romFile = "Star_Fox.smc",                 namedItem = "PZEMU.SNES_Cart_StarFox",    weight = 15 },
    { name = "Secret of Mana",           romFile = "Secret_of_Mana.smc",           namedItem = "PZEMU.SNES_Cart_SecretOfMana", weight = 10 },
    { name = "NBA Jam",                  romFile = "NBA_Jam.smc",                  namedItem = "PZEMU.SNES_Cart_NBAJam",     weight = 15 },
    { name = "Battletoads & Double Dragon", romFile = "Battletoads_Double_Dragon.smc", namedItem = nil,                       weight = 5 },
    { name = "Breath of Fire",           romFile = "Breath_of_Fire.smc",           namedItem = nil,                          weight = 5 },
    { name = "Breath of Fire II",        romFile = "Breath_of_Fire_II.smc",        namedItem = nil,                          weight = 3 },
    { name = "Bust-A-Move",              romFile = "Bust-A-Move.smc",              namedItem = nil,                          weight = 8 },
    { name = "Demon's Crest",            romFile = "Demons_Crest.smc",             namedItem = nil,                          weight = 3 },
    { name = "Donkey Kong Country 2",    romFile = "Donkey_Kong_Country_2.smc",    namedItem = nil,                          weight = 15 },
    { name = "Dragon Ball Z: Super Butouden", romFile = "Dragon_Ball_Z_Super_Butouden.smc", namedItem = nil,                 weight = 5 },
    { name = "EarthBound",               romFile = "EarthBound.smc",               namedItem = nil,                          weight = 5 },
    { name = "Final Fantasy III",        romFile = "Final_Fantasy_III.smc",        namedItem = nil,                          weight = 8 },
    { name = "Fire Emblem: Mystery of the Emblem", romFile = "Fire_Emblem_Mystery_of_the_Emblem.smc", namedItem = nil,       weight = 3 },
    { name = "Harvest Moon",             romFile = "Harvest_Moon.smc",             namedItem = nil,                          weight = 5 },
    { name = "Illusion of Gaia",         romFile = "Illusion_of_Gaia.smc",         namedItem = nil,                          weight = 5 },
    { name = "International Superstar Soccer Deluxe", romFile = "International_Superstar_Soccer_Deluxe.smc", namedItem = nil, weight = 5 },
    { name = "Kirby's Dream Course",     romFile = "Kirbys_Dream_Course.smc",      namedItem = nil,                          weight = 5 },
    { name = "Kirby's Dream Land 3",     romFile = "Kirbys_Dream_Land_3.smc",      namedItem = nil,                          weight = 5 },
    { name = "Knights of the Round",     romFile = "Knights_of_the_Round.smc",     namedItem = nil,                          weight = 5 },
    { name = "Lufia",                    romFile = "Lufia.smc",                    namedItem = nil,                          weight = 5 },
    { name = "Lufia II",                 romFile = "Lufia_II.smc",                 namedItem = nil,                          weight = 3 },
    { name = "Mighty Morphin Power Rangers", romFile = "Mighty_Morphin_Power_Rangers.smc", namedItem = nil,                  weight = 8 },
    { name = "Saturday Night Slam Masters", romFile = "Saturday_Night_Slam_Masters.smc", namedItem = nil,                    weight = 5 },
    { name = "Secret of Evermore",        romFile = "Secret_of_Evermore.smc",       namedItem = nil,                          weight = 3 },
    { name = "Spider-Man and Venom: Maximum Carnage", romFile = "Spider-Man_Maximum_Carnage.smc", namedItem = nil,           weight = 5 },
    { name = "Super Bomberman 2",        romFile = "Super_Bomberman_2.smc",        namedItem = nil,                          weight = 8 },
    { name = "Super Mario RPG",          romFile = "Super_Mario_RPG.smc",          namedItem = nil,                          weight = 10 },
    { name = "Super Mario World 2: Yoshi's Island", romFile = "Super_Mario_World_2_Yoshis_Island.smc", namedItem = nil,      weight = 15 },
    { name = "Super Street Fighter II",  romFile = "Super_Street_Fighter_II.smc",  namedItem = nil,                          weight = 10 },
    { name = "Terranigma",               romFile = "Terranigma.smc",               namedItem = nil,                          weight = 2 },
    { name = "Final Fantasy: Mystic Quest", romFile = "Final_Fantasy_Mystic_Quest.smc", namedItem = nil,                     weight = 5 },
}

local GENESIS_GAME_POOL = {
    { name = "Sonic the Hedgehog",       romFile = "Sonic_The_Hedgehog.bin",       namedItem = "PZEMU.Genesis_Cart_Sonic",     weight = 50 },
    { name = "Sonic the Hedgehog 2",     romFile = "Sonic_The_Hedgehog_2.smd",     namedItem = "PZEMU.Genesis_Cart_Sonic2",       weight = 35 },
    { name = "Streets of Rage 2",        romFile = "Streets_Of_Rage_2.smd",        namedItem = "PZEMU.Genesis_Cart_StreetsOfRage2", weight = 20 },
    { name = "Streets of Rage",          romFile = "Streets_Of_Rage.smd",          namedItem = "PZEMU.Genesis_Cart_StreetsOfRage",  weight = 15 },
    { name = "Golden Axe",               romFile = "Golden_Axe.gen",               namedItem = "PZEMU.Genesis_Cart_GoldenAxe", weight = 15 },
    { name = "Aladdin",                  romFile = "Aladdin.bin",                  namedItem = "PZEMU.Genesis_Cart_Aladdin",   weight = 20 },
    { name = "Altered Beast",            romFile = "Altered_Beast.smd",            namedItem = "PZEMU.Genesis_Cart_AlteredBeast", weight = 12 },
    { name = "Street Fighter II",        romFile = "Street_Fighter_2.bin",         namedItem = "PZEMU.Genesis_Cart_SF2",      weight = 15 },
    { name = "Mortal Kombat",            romFile = "Mortal_Kombat.smd",            namedItem = nil,                           weight = 15 },
    { name = "Ghouls 'N Ghosts",         romFile = "Ghouls_N_Ghosts.smd",         namedItem = "PZEMU.Genesis_Cart_GhoulsNGhosts", weight = 8 },
    { name = "Gunstar Heroes",           romFile = "Gunstar_Heroes.smd",           namedItem = nil,                           weight = 10 },
    { name = "Road Rash II",             romFile = "Road_Rash_II.smd",             namedItem = "PZEMU.Genesis_Cart_RoadRash2",    weight = 10 },
    { name = "Golden Axe 2",             romFile = "Golden_Axe_2.gen",             namedItem = "PZEMU.Genesis_Cart_GoldenAxe2",   weight = 8 },
    { name = "Phantasy Star IV",         romFile = "Phantasy_Star_4.smd",          namedItem = nil,                           weight = 3 },
    { name = "Desert Strike",            romFile = "Desert_Strike.smd",            namedItem = "PZEMU.Genesis_Cart_DesertStrike",    weight = 8 },
    { name = "Fatal Fury",               romFile = "Fatal_Fury.smd",               namedItem = "PZEMU.Genesis_Cart_FatalFury",      weight = 5 },
    { name = "Herzog Zwei",              romFile = "Herzog_Zwei.smd",              namedItem = "PZEMU.Genesis_Cart_HerzogZwei",     weight = 3 },
    { name = "Lightening Force",         romFile = "Lightening_Force.smd",         namedItem = "PZEMU.Genesis_Cart_LighteningForce", weight = 5 },
    { name = "Moonwalker",               romFile = "Moonwalker.smd",               namedItem = "PZEMU.Genesis_Cart_Moonwalker",     weight = 8 },
    { name = "OutRun",                   romFile = "OutRun.smd",                   namedItem = "PZEMU.Genesis_Cart_OutRun",         weight = 8 },
    { name = "Phantasy Star III",        romFile = "Phantasy_Star_3.smd",          namedItem = "PZEMU.Genesis_Cart_PhantasyStar3",  weight = 5 },
    { name = "QuackShot",                romFile = "QuackShot.smd",                namedItem = "PZEMU.Genesis_Cart_QuackShot",      weight = 8 },
    { name = "Rolling Thunder 2",        romFile = "Rolling_Thunder_2.smd",        namedItem = "PZEMU.Genesis_Cart_RollingThunder2", weight = 5 },
    { name = "Shadow Dancer",            romFile = "Shadow_Dancer.smd",            namedItem = "PZEMU.Genesis_Cart_ShadowDancer",   weight = 5 },
    { name = "Revenge of Shinobi",       romFile = "Revenge_of_Shinobi.smd",       namedItem = "PZEMU.Genesis_Cart_RevengeOfShinobi", weight = 8 },
    { name = "Space Harrier 2",          romFile = "Space_Harrier_2.smd",          namedItem = "PZEMU.Genesis_Cart_SpaceHarrier2",  weight = 5 },
    { name = "Splatterhouse 2",          romFile = "Splatterhouse_2.smd",          namedItem = "PZEMU.Genesis_Cart_Splatterhouse2", weight = 5 },
    { name = "Strider",                  romFile = "Strider.smd",                  namedItem = "PZEMU.Genesis_Cart_Strider",        weight = 8 },
    { name = "TMNT: Hyperstone Heist",   romFile = "TMNT_Hyperstone_Heist.smd",    namedItem = "PZEMU.Genesis_Cart_TMNTHH",        weight = 8 },
}

local GB_GAME_POOL = {
    { name = "Tetris",                   romFile = "Tetris.gb",                    namedItem = "PZEMU.GB_Cart_Tetris",  weight = 50 },
    { name = "Super Mario Land",         romFile = "Super_Mario_Land.gb",          namedItem = "PZEMU.GB_Cart_Mario",   weight = 40 },
    { name = "Super Mario Land 2",       romFile = "Super_Mario_Land_2.gb",        namedItem = nil,                     weight = 25 },
    { name = "Zelda: Link's Awakening",  romFile = "Links_Awakening.gb",           namedItem = "PZEMU.GB_Cart_Zelda",   weight = 25 },
    { name = "Kirby's Dream Land",       romFile = "Kirbys_Dream_Land.gb",         namedItem = "PZEMU.GB_Cart_Kirby",   weight = 20 },
    { name = "Pokemon Red",              romFile = "Pokemon_Red.gb",               namedItem = nil,                     weight = 15 },
    { name = "Dr. Mario",                romFile = "Dr_Mario.gb",                  namedItem = nil,                     weight = 15 },
    { name = "Castlevania Adventure",    romFile = "Castlevania_Adventure.gb",     namedItem = nil,                     weight = 5 },
    { name = "Alleyway",                 romFile = "Alleyway.gb",                  namedItem = nil,                     weight = 5 },
    { name = "Avenging Spirit",          romFile = "Avenging_Spirit.gb",           namedItem = nil,                     weight = 3 },
    { name = "Balloon Kid",              romFile = "Balloon_Kid.gb",               namedItem = nil,                     weight = 5 },
    { name = "Baseball",                 romFile = "Baseball.gb",                  namedItem = nil,                     weight = 3 },
    { name = "Batman: The Video Game",   romFile = "Batman_The_Video_Game.gb",     namedItem = nil,                     weight = 5 },
    { name = "Battletoads",              romFile = "Battletoads.gb",               namedItem = nil,                     weight = 5 },
    { name = "Bionic Commando",          romFile = "Bionic_Commando.gb",           namedItem = nil,                     weight = 3 },
    { name = "Bubble Bobble",            romFile = "Bubble_Bobble.gb",             namedItem = nil,                     weight = 5 },
    { name = "Castlevania II: Belmont's Revenge", romFile = "Castlevania_II_Belmonts_Revenge.gb", namedItem = nil,      weight = 5 },
    { name = "Double Dragon",            romFile = "Double_Dragon.gb",             namedItem = nil,                     weight = 5 },
    { name = "Double Dragon II",         romFile = "Double_Dragon_II.gb",          namedItem = nil,                     weight = 3 },
    { name = "DuckTales",                romFile = "DuckTales.gb",                 namedItem = nil,                     weight = 5 },
    { name = "Final Fantasy Legend",     romFile = "Final_Fantasy_Legend.gb",       namedItem = "PZEMU.GB_Cart_FinalFantasyLegend", weight = 5 },
    { name = "Final Fantasy Legend II",  romFile = "Final_Fantasy_Legend_II.gb",    namedItem = nil,                     weight = 3 },
    { name = "Gargoyle's Quest",         romFile = "Gargoyles_Quest.gb",            namedItem = nil,                     weight = 5 },
    { name = "Kid Dracula",              romFile = "Kid_Dracula.gb",               namedItem = nil,                     weight = 3 },
    { name = "Kid Icarus: Of Myths and Monsters", romFile = "Kid_Icarus_Of_Myths_and_Monsters.gb", namedItem = nil,     weight = 3 },
    { name = "Mega Man: Dr. Wily's Revenge", romFile = "Mega_Man_Dr_Wilys_Revenge.gb", namedItem = nil,                 weight = 5 },
    { name = "Mega Man II",              romFile = "Mega_Man_II.gb",               namedItem = nil,                     weight = 3 },
    { name = "Mega Man III",             romFile = "Mega_Man_III.gb",              namedItem = nil,                     weight = 3 },
    { name = "Metroid II: Return of Samus", romFile = "Metroid_II_Return_of_Samus.gb", namedItem = nil,                 weight = 8 },
    { name = "Nemesis",                  romFile = "Nemesis.gb",                   namedItem = nil,                     weight = 3 },
    { name = "Ninja Gaiden Shadow",      romFile = "Ninja_Gaiden_Shadow.gb",       namedItem = nil,                     weight = 3 },
    { name = "Operation C",              romFile = "Operation_C.gb",               namedItem = nil,                     weight = 3 },
    { name = "R-Type",                   romFile = "R-Type.gb",                    namedItem = nil,                     weight = 5 },
    { name = "SolarStriker",             romFile = "SolarStriker.gb",              namedItem = nil,                     weight = 3 },
    { name = "TMNT: Fall of the Foot Clan", romFile = "TMNT_Fall_of_the_Foot_Clan.gb", namedItem = nil,                 weight = 5 },
    { name = "TMNT II: Back from the Sewers", romFile = "TMNT_II_Back_from_the_Sewers.gb", namedItem = nil,             weight = 3 },
    { name = "Wave Race",                romFile = "Wave_Race.gb",                 namedItem = nil,                     weight = 3 },
    { name = "Yoshi",                    romFile = "Yoshi.gb",                     namedItem = nil,                     weight = 5 },
    { name = "Yoshi's Cookie",           romFile = "Yoshis_Cookie.gb",             namedItem = nil,                     weight = 3 },
}

local ATARI2600_GAME_POOL = {
    { name = "Combat",                   romFile = "Combat.bin",                   namedItem = "PZEMU.Atari_Cart_Combat",        weight = 50 },
    { name = "Space Invaders",           romFile = "Space_Invaders.bin",           namedItem = "PZEMU.Atari_Cart_SpaceInvaders", weight = 40 },
    { name = "Asteroids",                romFile = "Asteroids.bin",                namedItem = "PZEMU.Atari_Cart_Asteroids",     weight = 30 },
    { name = "Pitfall!",                 romFile = "Pitfall.bin",                  namedItem = "PZEMU.Atari_Cart_Pitfall",       weight = 25 },
    { name = "Pac-Man",                  romFile = "Pac_Man.bin",                  namedItem = nil,                              weight = 20 },
    { name = "Frogger",                  romFile = "Frogger.bin",                  namedItem = nil,                              weight = 15 },
    { name = "Breakout",                 romFile = "Breakout.bin",                 namedItem = nil,                              weight = 15 },
    { name = "Adventure",                romFile = "Adventure.bin",                namedItem = nil,                              weight = 10 },
    { name = "Ms. Pac-Man",              romFile = "Ms_Pac_Man.bin",               namedItem = "PZEMU.Atari_Cart_MsPacMan",      weight = 20 },
}

local GG_GAME_POOL = {
    { name = "Sonic the Hedgehog",       romFile = "Sonic_the_Hedgehog.gg",        namedItem = "PZEMU.GG_Cart_Sonic",   weight = 50 },
    { name = "Columns",                  romFile = "Columns.gg",                   namedItem = "PZEMU.GG_Cart_Columns", weight = 30 },
    { name = "Sonic the Hedgehog 2",     romFile = "Sonic_the_Hedgehog_2.gg",      namedItem = nil,                     weight = 25 },
    { name = "Sonic Chaos",              romFile = "Sonic_Chaos.gg",               namedItem = nil,                     weight = 15 },
    { name = "The G.G. Shinobi",         romFile = "Shinobi.gg",                   namedItem = "PZEMU.GG_Cart_Shinobi", weight = 10 },
    { name = "Streets of Rage 2",        romFile = "Streets_of_Rage_2.gg",         namedItem = nil,                     weight = 10 },
    { name = "Mortal Kombat",            romFile = "Mortal_Kombat.gg",             namedItem = nil,                     weight = 10 },
    { name = "Klax",                     romFile = "Klax.gg",                      namedItem = "PZEMU.GG_Cart_Klax",    weight = 8 },
    { name = "OutRun Europa",            romFile = "OutRun_Europa.gg",             namedItem = "PZEMU.GG_Cart_OutRun",  weight = 8 },
    { name = "Paperboy",                 romFile = "Paperboy.gg",                  namedItem = "PZEMU.GG_Cart_Paperboy", weight = 8 },
}

local SMS_GAME_POOL = {
    { name = "Alex Kidd in Miracle World", romFile = "Alex_Kidd_in_Miracle_World.sms", namedItem = nil, weight = 40 },
    { name = "Sonic the Hedgehog",         romFile = "Sonic_the_Hedgehog.sms",         namedItem = nil, weight = 30 },
    { name = "Fantasy Zone",               romFile = "Fantasy_Zone.sms",               namedItem = nil, weight = 15 },
    { name = "Wonder Boy",                 romFile = "Wonder_Boy.sms",                 namedItem = nil, weight = 15 },
}

-- Map console system tags to their game pool and generic cartridge item
local SYSTEM_CONFIG = {
    PZEMU_NES       = { pool = NES_GAME_POOL,       genericItem = "PZEMU.NES_Cart_Generic",     mustHaveIndex = 1 },
    PZEMU_SNES      = { pool = SNES_GAME_POOL,      genericItem = "PZEMU.SNES_Cart_Generic",    mustHaveIndex = 1 },
    PZEMU_Genesis   = { pool = GENESIS_GAME_POOL,    genericItem = "PZEMU.Genesis_Cart_Generic", mustHaveIndex = 1 },
    PZEMU_GB        = { pool = GB_GAME_POOL,         genericItem = "PZEMU.GB_Cart_Generic",      mustHaveIndex = 1 },
    PZEMU_Atari2600 = { pool = ATARI2600_GAME_POOL,  genericItem = "PZEMU.Atari_Cart_Generic",   mustHaveIndex = 1 },
    PZEMU_GG        = { pool = GG_GAME_POOL,         genericItem = "PZEMU.GG_Cart_Generic",      mustHaveIndex = 1 },
    PZEMU_SMS       = { pool = SMS_GAME_POOL,         genericItem = "PZEMU.SMS_Cart_Generic",     mustHaveIndex = 1 },
}

-- Console fullType → system key (for type-based identification, no hasTag)
local CONSOLE_TYPE_TO_SYSKEY = {
    ["PZEMU.NES_Console"]       = "PZEMU_NES",
    ["PZEMU.SNES_Console"]      = "PZEMU_SNES",
    ["PZEMU.Genesis_Console"]   = "PZEMU_Genesis",
    ["PZEMU.GameBoy_Console"]   = "PZEMU_GB",
    ["PZEMU.Atari2600_Console"] = "PZEMU_Atari2600",
    ["PZEMU.GameGear_Console"]  = "PZEMU_GG",
    ["PZEMU.SMS_Console"]       = "PZEMU_SMS",
}

-- ============================================================================
-- Weighted random selection
-- ============================================================================

local function weightedRandom(pool)
    local totalWeight = 0
    for _, entry in ipairs(pool) do
        totalWeight = totalWeight + entry.weight
    end
    local roll = ZombRand(math.floor(totalWeight)) + 1
    local cumulative = 0
    for _, entry in ipairs(pool) do
        cumulative = cumulative + entry.weight
        if roll <= cumulative then
            return entry
        end
    end
    return pool[#pool]
end

-- ============================================================================
-- Spawn a single cartridge into a container
-- ============================================================================

local function spawnCartridge(container, game, config)
    local item
    if game.namedItem then
        item = container:AddItem(game.namedItem)
    else
        item = container:AddItem(config.genericItem)
    end
    if item then
        if not game.namedItem then
            item:setName(game.name)
            item:setCustomName(true)
            item:getModData().PZEMU_GameName = game.name
            item:getModData().PZEMU_RomFile = game.romFile
        end
    end
    return item
end

-- ============================================================================
-- OnFillContainer — spawn cartridges alongside consoles
-- ============================================================================

local function onFillContainer(_roomName, _containerType, container)
    if isClient() then return end
    if not instanceof(container, "ItemContainer") then return end

    -- Find which console systems exist in this container (type-based, no hasTag)
    local foundSystems = {}
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local sysKey = CONSOLE_TYPE_TO_SYSKEY[item:getFullType()]
        if sysKey and not foundSystems[sysKey] then
            foundSystems[sysKey] = true
        end
    end

    -- For each console system found, spawn cartridges
    for sysTag, _ in pairs(foundSystems) do
        local config = SYSTEM_CONFIG[sysTag]
        if config then
            local pool = config.pool
            local countMult = pzemuSandboxDouble("CartridgeCountMultiplier", 1.0)
            local count = math.floor((3 + ZombRand(5)) * countMult + 0.5)  -- 3-7 base, scaled
            if ZombRand(100) < 15 then     -- 15% bonus
                count = count + math.floor(ZombRand(8) * countMult + 0.5)
            end
            if count < 0 then count = 0 end

            -- Track spawned games to avoid duplicates
            local spawned = {}

            -- Always include the "must-have" game first
            local mustHave = pool[config.mustHaveIndex]
            if mustHave then
                spawnCartridge(container, mustHave, config)
                spawned[mustHave.romFile] = true
                count = count - 1
            end

            -- Fill remaining slots from weighted pool
            local attempts = 0
            while count > 0 and attempts < 50 do
                local game = weightedRandom(pool)
                if not spawned[game.romFile] then
                    spawnCartridge(container, game, config)
                    spawned[game.romFile] = true
                    count = count - 1
                end
                attempts = attempts + 1
            end
        end
    end
end

Events.OnFillContainer.Add(onFillContainer)

print("[PZEMU] Distribution tables loaded")
