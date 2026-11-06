local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TerrainStructures = ReplicatedStorage:WaitForChild("TerrainStructures")

local GrassMap = {
	Name = "GrassMap",

	-- Ground & Terrain Math
	Terrain = {
		GridSize = 150,
		HillHeight = 30,
		HillSmoothness = 120,
		FlatBaseHeight = 5,
		BaseColor = Color3.fromRGB(98, 197, 98),
		ColorVariance = 8,
		Material = Enum.Material.Grass,
		MaterialVariant = "ClassicGrass1",
	},

	-- Procedural Wedge Rock Formations
	ProceduralHills = {
		Enabled = true,
		CountBase = NumberRange.new(6, 14),
		MinDistance = 180,
		RadiusRange = NumberRange.new(150, 250),
		HeightRange = NumberRange.new(50, 80),
		SinkDepthRange = NumberRange.new(10, 35),
	},

	-- Biome Building Palettes
	BuildingThemes = {
		{
			Name = "RedBrick_Industrial",
			Primary = Color3.fromRGB(150, 85, 85),
			Secondaries = {
				Color3.fromRGB(104, 60, 60),
				Color3.fromRGB(99, 95, 98),
			}
		},
		{
			Name = "Military_Concrete",
			Primary = Color3.fromRGB(110, 115, 110),
			Secondaries = {
				Color3.fromRGB(45, 50, 48),
				Color3.fromRGB(160, 101, 86),
			}
		},
		{
			Name = "Ruined_Office",
			Primary = Color3.fromRGB(90, 105, 120),
			Secondaries = {
				Color3.fromRGB(140, 140, 140),
				Color3.fromRGB(50, 55, 65),
			}
		},
		{
			Name = "Yellowed",
			Primary = Color3.fromRGB(211, 190, 150),
			Secondaries = {
				Color3.fromRGB(99, 95, 98),
				Color3.fromRGB(130, 110, 90),
			}
		},
	},

	-- Prop Scatter Rules
	Scatters = {
		-- 1. Ruined Buildings (Placed first so smaller props respect clearance)
		{
			Name = "RuinedBuildings",
			TemplatesFolder = TerrainStructures:WaitForChild("RuinedBuildings"),
			CountRange = NumberRange.new(10, 24),
			MinDistance = 200,          -- Spacing between buildings
			FootprintBuffer = 15,       -- Clearance buffer for trees/boulders
			SafeZoneBuffer = 180,
			MinSlopeY = 0.85,
			ScaleRange = NumberRange.new(0.85, 1.15),
			GroundOffset = Vector3.new(0, -2, 0),
			IsBuilding = true,
			CheckGrassOnly = true,
			AvoidRockHills = true, -- Avoid placing on hills
		},

		-- 2. Clustered Multi-Shape Bushes
		{
			Name = "Bushes",
			Template = TerrainStructures:WaitForChild("BushModel"),
			CountRange = NumberRange.new(12, 20),
			ClusterCount = NumberRange.new(3, 8),
			BonusPerRock = NumberRange.new(1, 2), -- Original: #placedRocks * math.random(1, 2)
			ClusterRadius = 80,
			SafeZoneBuffer = 100,
			UseBushVariations = true,
			IgnoreSpacing = true,      -- Bushes do not collide with trees/props
		},

		-- 3. Pine Trees
		{
			Name = "PineTrees",
			Template = TerrainStructures:WaitForChild("PineTree"),
			CountRange = NumberRange.new(80, 260),
			MinDistance = 15,
			SafeZoneBuffer = 120,
			MinSlopeY = 0.80,
			ScaleRange = NumberRange.new(0.8, 1.3),
			GroundOffset = Vector3.new(0, 4, 0),
			IsDestructible = true,
			CheckGrassOnly = true, -- Won't grow on gray rock, but can grow right beside it
			CollectionTag = "EnvironmentIgnore",
		},

		-- 4. Boulders
		{
			Name = "Boulders",
			Template = TerrainStructures:WaitForChild("BoulderModel"),
			CountRange = NumberRange.new(30, 70),
			MinDistance = 20,
			SafeZoneBuffer = 120,
			ScaleRange = NumberRange.new(0.8, 2.2),
			GroundOffset = Vector3.new(0, -1, 0),
			RandomTilt = true,
			IsDestructible = true,
			CheckGrassOnly = false,    -- Can spawn on stone hills
		},
	}
}

return GrassMap