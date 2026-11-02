--[[
	CombatBalanceData
	Compiled reference of all combat-related stats for review and comparison.
	Everything here is a snapshot of current values in the game (as of this session).
	Feel free to edit the numbers here to run what-if comparisons — nothing in this
	module affects the actual game; it is purely for balance review.

	Derived metrics (sustained DPS, TTK) are computed at the bottom of this file
	and will automatically update when you change any value above.
]]

-- this script is only for compiling data to be read.

local CombatBalanceData = {}

----------------------------------------------------------------
-- 1. MAP
----------------------------------------------------------------
CombatBalanceData.Map = {
	MapSize = 1600,             -- studs (square: 1600 x 1600)
	MapDiagonal = 2263,         -- studs, corner to corner
	BaseSizePerTeam = 350,      -- studs (clamped 350-600, = MAP_SIZE * 0.15)
	BaseDistance = 2263,       -- studs between team bases (opposite corners)

	-- Terrain generation
	GridSize = 100,             -- studs per terrain tile
	HillHeight = 30,            -- max elevation (studs)
	HillSmoothness = 120,
	FlatBaseHeight = 5,          -- studs near bases

	-- Prop scatter counts (min spacing in studs)
	RuinedBuildings = {Min = 10, Max = 24, MinSpacing = 200},
	Bushes = {Min = 12, Max = 20, PerCluster = {3, 8}},
	PineTrees = {Min = 80, Max = 260, MinSpacing = 15},
	Boulders = {Min = 30, Max = 70, MinSpacing = 20},
	RockHills = {Min = 6, Max = 14, Radius = {150, 250}, Height = {50, 80}},

	-- Boundaries
	BoundaryWallHeight = 230,
	BoundaryWallThickness = 100,
	SkyWallHeight = 2000,
	RoofHeight = 2005,
}

----------------------------------------------------------------
-- 2. WEAPONS  (per mech template)
-- SustainedDPS accounts for magazine size + reload time (computed below)
----------------------------------------------------------------
CombatBalanceData.Weapons = {
	BasicMech = {
		MachineGun_Right = {Damage = 2.5, Cooldown = 0.1, BulletSpeed = 800, MaxRange = 500, MaxAmmo = 30, ReloadTime = 3},
		Cannon_Left = {Damage = 30, Cooldown = 1.5, BulletSpeed = 500, MaxRange = 750, MaxAmmo = 5, ReloadTime = 4, SplashRadius = 10},
		MissileLauncher_RightShoulder = {Damage = 15, Cooldown = 0.2, BulletSpeed = 200, MaxRange = 1000, MaxAmmo = 12, ReloadTime = 8, SplashRadius = 8},
	},
	HeavyMech = {
		MachineGun_Right = {Damage = 3, Cooldown = 0.12, BulletSpeed = 800, MaxRange = 700, MaxAmmo = 80, ReloadTime = 8},
		Cannon_LeftShoulder = {Damage = 40, Cooldown = 3, BulletSpeed = 400, MaxRange = 1000, MaxAmmo = 2, ReloadTime = 12, SplashRadius = 16, FireMode = "Simultaneous"},
		MachineGun_Left = {Damage = 3, Cooldown = 0.12, BulletSpeed = 800, MaxRange = 700, MaxAmmo = 80, ReloadTime = 8},
		Cannon_RightShoulder = {Damage = 40, Cooldown = 3, BulletSpeed = 400, MaxRange = 1000, MaxAmmo = 2, ReloadTime = 12, SplashRadius = 16, FireMode = "Simultaneous"},
	},
	LightSniperMech = {
		AntiMaterielRifle_Left = {Damage = 80, Cooldown = 3, BulletSpeed = 800, MaxRange = 1000, MaxAmmo = 3, ReloadTime = 10, Penetration = 3, PenetrationDecay = 0.8},
		MachinePistol_Right = {Damage = 4, Cooldown = 0.12, BulletSpeed = 650, MaxRange = 250, MaxAmmo = 24, ReloadTime = 1.6, Penetration = 1, PenetrationDecay = 0.8, StaggerPower = 0.02},
	},
	WheeledMech = {
		MachineGun_Right = {Damage = 2.5, Cooldown = 0.1, BulletSpeed = 800, MaxRange = 500, MaxAmmo = 30, ReloadTime = 3},
		Cannon_Left = {Damage = 40, Cooldown = 0, BulletSpeed = 500, MaxRange = 750, MaxAmmo = 1, ReloadTime = 3, SplashRadius = 8}, -- auto-fire
		MachineGun_Left = {Damage = 2, Cooldown = 0.1, BulletSpeed = 800, MaxRange = 500, MaxAmmo = 100, ReloadTime = 5},
		MachineGun_LeftShoulder = {Damage = 2.5, Cooldown = 0.1, BulletSpeed = 800, MaxRange = 500, MaxAmmo = 30, ReloadTime = 3},
		MachineGun_RightShoulder = {Damage = 2.5, Cooldown = 0.1, BulletSpeed = 800, MaxRange = 500, MaxAmmo = 30, ReloadTime = 3},
	},
}

----------------------------------------------------------------
-- 3. MELEE
----------------------------------------------------------------
CombatBalanceData.Melee = {
	Fist = {Damage = 25, Cooldown = 2, StaggerPower = 1.0, HitboxRadius = 3.0},
	PileBunker = {Damage = 140, Cooldown = 3, StaggerPower = 2.5, HitboxRadius = 3.5},
	Chainsaw = {Damage = 18, Cooldown = 2, StaggerPower = 0.25, RepeatInterval = 0.12}, -- volume hitbox
}

----------------------------------------------------------------
-- 4. MECH STATS
----------------------------------------------------------------
CombatBalanceData.Mechs = {
	BasicMech = {
		TotalHealth = 8832, CoreHealth = 300, SkeletonHealth = 1350, ArmorHealth = 6442,
		WalkSpeed = 15, CrawlSpeedOneLeg = 6, CrawlSpeedNoLegs = 0,
		FallSpeed = 3, FallDuration = 1,
		RepairMultiplier = 1.2, Locomotion = "Bipedal",
		Bounty = 400, SpawnCost = 0,
	},
	HeavyMech = {
		TotalHealth = 22852, CoreHealth = 1000, SkeletonHealth = 2540, ArmorHealth = 18202,
		WalkSpeed = 10, CrawlSpeedOneLeg = 6, CrawlSpeedNoLegs = 0,
		FallSpeed = 2, FallDuration = 0.6,
		RepairMultiplier = 2, Locomotion = "Bipedal",
		Bounty = 700, SpawnCost = 800,
	},
	LightSniperMech = {
		TotalHealth = 10881, CoreHealth = 280, SkeletonHealth = 1320, ArmorHealth = 8931,
		WalkSpeed = 17, CrawlSpeedOneLeg = 7, CrawlSpeedNoLegs = 0,
		FallSpeed = 3, FallDuration = 1,
		RepairMultiplier = 1.4, Locomotion = "ChickenLegBipedal",
		Bounty = 600, SpawnCost = 450,
	},
	WheeledMech = {
		TotalHealth = 8714, CoreHealth = 250, SkeletonHealth = 360, ArmorHealth = 7724,
		WalkSpeed = 20, -- scales with wheels: speed = base * (wheelsRemaining / 4)
		FallSpeed = 3,
		RepairMultiplier = 1.5, Locomotion = "Wheeled",
		Bounty = 200, SpawnCost = 0,
	},
}

-- Health distribution formula (how part health is derived)
CombatBalanceData.HealthDistribution = {
	BoneDensity = 8,        -- per volume unit
	ArmorDensity = 10,      -- per volume unit
	RegionMultipliers_Bones = {Torso = 1.0, Arms = 2.0, Legs = 2.0},
	ArmorMultipliers = {Torso = 2.0, Arms = 1.7, Legs = 3.0},
}

----------------------------------------------------------------
-- 5. DAMAGE MODEL
----------------------------------------------------------------
CombatBalanceData.DamageModel = {
	SplashDamagePercent = 0.5,       -- of direct hit damage (cannons & missiles)
	SplashDecayFormula = "baseDamage * decayFactor * (1 - distance/radius)",
	MaxPartsHitPerMech = 5,           -- scales with part count at 2%
	PropHitLimit = 45,               -- decay 0.9 per hit
	CoreMeltdownThreshold = 0.10,    -- core at 10% HP
	CoreMeltdownDrain = 5,            -- HP/sec until death
	CoreExplosionRadius = 50,        -- studs
	LimbSeverBonusPoints = 35,
	PointsPerDamage = 0.1,           -- 1 point per 10 damage

	-- Stagger power per weapon type
	StaggerPower = {
		Fist = 1.0, PileBunker = 2.5, Chainsaw = 0.25,
		Cannon = 0.6, HeavyCannon = 1.2, SniperRifle = 1.5, Missile = 0.2, MachinePistol = 0.02,
	},

	-- Damage multipliers vs pilots (out of mech) — per weapon attribute on each mech template
	PilotDamageMultipliers = {
		MachineGun_BasicMech = 7, MachineGun_WheeledShoulders = 4, MachineGun_WheeledLeft = 4, MachineGun_HeavyMech = 8,
		Cannons = 5, Missiles = 5, SniperRifle = 10, MachinePistol = 4,
	},

	-- Trample: direct TrampleDamage attribute per mech template
	Trample = {
		HeavyMech = 125,
		BasicMech = 75,
		LightSniperMech = 75,
		WheeledMech = 75,
		MaxRange = 30,     -- studs
	},

	-- Armor destroyed -> remaining damage spills to skeleton/core, armor ejected
	ArmorSpillover = true,
}

----------------------------------------------------------------
-- 6. REPAIR
----------------------------------------------------------------
CombatBalanceData.Repair = {
	BaseRepairInterval = 0.125,   -- seconds (8 ticks/sec)
	HealPerTick = 10,
	-- Effective tick interval = BaseRepairInterval / RepairMultiplier (per mech)
	MaxDistance = 35,             -- studs from mech torso
	RequiresPilotExit = true,      -- mech must be unoccupied
	SameTeamOnly = true,
	RepairerCooldown = 0.5,        -- seconds between different repairers
	LatencyBuffer = 0.20,          -- 20% on repair timing
	RestoresMissingParts = true,   -- one at a time from blueprint
}

-- Repair time to repair damage of !testdamage command (usually deals about total of 20 percent damage to overall mech, decreasing health on random parts but never killing it )
-- BasicMech (Medium Mech): 1:21 seconds
-- Wheeled: 0:55 seconds
-- Heavy: 2:55 seconds
-- Sniper: 2:10 seconds

----------------------------------------------------------------
-- 7. ROUND SETTINGS
----------------------------------------------------------------
CombatBalanceData.Rounds = {
	IntermissionTime = 10,
	RoundDuration = 900,           -- 15 minutes
	PostRoundCleanup = 5,
	TotalCycle = 1015,             -- seconds per full round cycle
	WinConditions = {"Timer expiry", "All vehicles destroyed"},
	PointsDataStoreExpiryHours = 1,
}

----------------------------------------------------------------
-- 8. DERIVED METRICS (computed — updates automatically if you edit values above)
----------------------------------------------------------------

local function weaponSustainedDPS(w)
	-- damage dealt per full magazine + reload, spread over the whole cycle
	if not w.MaxAmmo or w.MaxAmmo <= 0 then return 0 end
	local fireTime = (w.Cooldown > 0) and (w.MaxAmmo * w.Cooldown) or w.MaxAmmo * 0.1
	local cycle = fireTime + w.ReloadTime
	return (w.Damage * w.MaxAmmo) / cycle
end

local function burstDPS(w)
	-- DPS while the magazine is actually firing (no reload counted)
	if not w.MaxAmmo or w.MaxAmmo <= 0 then return 0 end
	local cd = (w.Cooldown > 0) and w.Cooldown or 0.1
	return w.Damage / cd
end

local derived = { SustainedDPS = {}, BurstDPS = {}, TimeToKill = {} }

for mechName, weapons in pairs(CombatBalanceData.Weapons) do
	derived.SustainedDPS[mechName] = {}
	derived.BurstDPS[mechName] = {}
	for weaponName, w in pairs(weapons) do
		derived.SustainedDPS[mechName][weaponName] = {
			DPS = math.floor(weaponSustainedDPS(w) * 10 + 0.5) / 10,
			BurstDPS = math.floor(burstDPS(w) * 10 + 0.5) / 10,
			MagazineDamage = w.Damage * w.MaxAmmo,
			RangeVsMapDiagonal = math.floor((w.MaxRange / CombatBalanceData.Map.MapDiagonal) * 100) .. "%",
		}
	end
end

-- Repair HP/sec per mech (for comparing vs weapon DPS)
derived.RepairHPS = {}
for mechName, stats in pairs(CombatBalanceData.Mechs) do
	local ticksPerSec = 1 / (CombatBalanceData.Repair.BaseRepairInterval / stats.RepairMultiplier)
	derived.RepairHPS[mechName] = math.floor(ticksPerSec * CombatBalanceData.Repair.HealPerTick * 10 + 0.5) / 10
end

-- Time-to-kill: each mech's total loadout sustained DPS vs each target's total health
for attackerName, weapons in pairs(CombatBalanceData.Weapons) do
	local totalDPS = 0
	for _, w in pairs(weapons) do
		totalDPS += weaponSustainedDPS(w)
	end
	derived.TimeToKill[attackerName] = {
		LoadoutSustainedDPS = math.floor(totalDPS * 10 + 0.5) / 10,
		vs = {},
	}
	for targetName, stats in pairs(CombatBalanceData.Mechs) do
		derived.TimeToKill[attackerName].vs[targetName] = math.floor(stats.TotalHealth / totalDPS) -- seconds
	end
end

CombatBalanceData.Derived = derived

----------------------------------------------------------------
-- 9. PRINT HELPER
-- Call CombatBalanceData.PrintSummary() from any script,
-- or run this in the command bar:
--   require(game.ReplicatedStorage.CombatBalanceData).PrintSummary()
----------------------------------------------------------------

function CombatBalanceData.PrintSummary()
	local d = CombatBalanceData.Derived
	local mechOrder = {"BasicMech", "HeavyMech", "LightSniperMech", "WheeledMech"}

	print("==================== WEAPON DPS ====================")
	for _, mechName in mechOrder do
		local weapons = CombatBalanceData.Weapons[mechName]
		if weapons then
			print("\n[" .. mechName .. "]")
			for weaponName, stats in pairs(d.SustainedDPS[mechName]) do
				print(string.format("  %-28s Burst %6.1f DPS | Sustained %6.1f DPS | Mag %5d dmg | Range %s of map",
					weaponName, stats.BurstDPS, stats.DPS, stats.MagazineDamage, stats.RangeVsMapDiagonal))
			end
		end
	end

	print("\n==================== REPAIR HPS ====================")
	for _, mechName in mechOrder do
		print(string.format("  %-16s %5.1f HP/sec", mechName, d.RepairHPS[mechName] or 0))
	end

	print("\n==================== TIME TO KILL (full loadout sustained DPS vs total health) ====================")
	for _, attacker in mechOrder do
		local ttk = d.TimeToKill[attacker]
		if ttk then
			local line = string.format("  %-16s (%5.1f DPS) ->", attacker, ttk.LoadoutSustainedDPS)
			for _, target in mechOrder do
				local secs = ttk.vs[target]
				if secs then
					line ..= string.format("  %s: %ds", target, secs)
				end
			end
			print(line)
		end
	end
	print("====================================================")
end

return CombatBalanceData