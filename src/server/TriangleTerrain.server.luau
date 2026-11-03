local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local PhysicsService = game:GetService("PhysicsService")
local rojoServerStore = ServerStorage:WaitForChild("ServerStore")

local regenEvent = ReplicatedStorage:WaitForChild("RegenTerrainEvent")
local MapConfigs = rojoServerStore:WaitForChild("MapConfigs")
local currentConfig = require(MapConfigs:WaitForChild("GrassMap"))

local mapFolder = workspace:WaitForChild("Map")
local cornerA = mapFolder:WaitForChild("Corner A")
local cornerB = mapFolder:WaitForChild("Corner B")

local flatBaseHeight = 5
local baseSize = 350

local terrainFolder = workspace.Map:FindFirstChild("GeneratedTerrain")
if not terrainFolder then
	terrainFolder = Instance.new("Folder")
	terrainFolder.Name = "GeneratedTerrain"
	terrainFolder.Parent = workspace.Map
end

-- Raycast parameters excluding map boundaries and spawn points
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
local thingsToIgnore = {}
local mapBorders = workspace.Map:FindFirstChild("MapBorders")
if mapBorders then table.insert(thingsToIgnore, mapBorders) end
local spawn = workspace:FindFirstChild("Spawn")
if spawn then table.insert(thingsToIgnore, spawn) end
raycastParams.FilterDescendantsInstances = thingsToIgnore

-- Colorize and anchor buildings using config themes
local function PrepareBuilding(buildingModel, themesList)
	themesList = themesList or currentConfig.BuildingThemes
	local theme = themesList[math.random(1, #themesList)]
	local primaryColor = theme.Primary
	local secondaryColor = theme.Secondaries[math.random(1, #theme.Secondaries)]

	for _, part in ipairs(buildingModel:GetDescendants()) do
		if part:IsA("BasePart") then
			local role = part:GetAttribute("ColorRole")
			if role == "Primary" then
				part.Color = primaryColor
			elseif role == "Secondary" then
				part.Color = secondaryColor
			end

			part:SetAttribute("BaseColor", part.Color)

			if part:GetAttribute("IsFoundation") then
				part.Anchored = true
			else
				part.Anchored = false
			end
		end
	end
end

local function SetupDestructibleHealth(model, scaleMultiplier)
	CollectionService:AddTag(model, "Destructible")
	for _, part in pairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			local baseHealth = part:GetAttribute("MaxHealth") or 50
			local finalHealth = math.round(baseHealth * scaleMultiplier)
			part:SetAttribute("MaxHealth", finalHealth)
			part:SetAttribute("CurrentHealth", finalHealth)
		end
	end
end

local function DrawTriangle(a, b, c, parent, color, material, materialVariant)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab.Magnitude, ac.Magnitude, bc.Magnitude

	if (abd > acd and abd > bcd) then
		c, a = a, c
	elseif (acd > bcd and acd > abd) then
		a, b = b, a
	end

	ab, ac, bc = b - a, c - a, c - b

	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))

	local w1 = Instance.new("WedgePart")
	w1.Size = Vector3.new(0, height, math.abs(ab:Dot(back)))
	w1.CFrame = CFrame.fromMatrix((a + b)/2, right, up, back) 
	w1.Color = color
	w1.Anchored = true
	w1.Material = material
	w1.Parent = parent

	local w2 = Instance.new("WedgePart")
	w2.Size = Vector3.new(0, height, math.abs(ac:Dot(back)))
	w2.CFrame = CFrame.fromMatrix((a + c)/2, -right, up, -back) 
	w2.Color = color
	w2.Anchored = true
	w2.Material = material
	w2.Parent = parent

	if materialVariant then
		w1.MaterialVariant = materialVariant
		w2.MaterialVariant = materialVariant
	end
end

local function GenerateRock(centerX, centerZ, rockRadius, maxRockHeight, baseY)
	local rockGridSize = 80

	local function GetRockHeight(x, z)
		local distanceFromCenter = math.sqrt((x - centerX)^2 + (z - centerZ)^2)
		-- 1. Find the exact grass height beneath this vertex
		local localGrassY = baseY
		local rayResult = workspace:Raycast(Vector3.new(x, 1000, z), Vector3.new(0, -2000, 0), raycastParams)
		if rayResult then
			localGrassY = rayResult.Position.Y
		end

		-- How many studs underground the outer edge should tuck
		local edgeSink = 20 

		-- If outside the rock radius, stop exactly at the buried edge depth
		if distanceFromCenter >= rockRadius then 
			return localGrassY - edgeSink 
		end

		local falloff = 1 - (distanceFromCenter / rockRadius)
		local jaggedNoise = math.noise(x / 15, z / 15) * 15

		-- Multiply noise by falloff so bumpiness fades to zero at the outer edge
		local smoothNoise = jaggedNoise * falloff

		-- Height smoothly curves from center peak down to (localGrassY - edgeSink)
		return localGrassY - edgeSink + (maxRockHeight * falloff) + smoothNoise
	end
	
	local tempRockFolder = Instance.new("Folder")
	tempRockFolder.Name = "RockHill"

	for x = centerX - rockRadius - rockGridSize, centerX + rockRadius, rockGridSize do
		for z = centerZ - rockRadius - rockGridSize, centerZ + rockRadius, rockGridSize do
			local y1 = GetRockHeight(x, z)
			local y2 = GetRockHeight(x + rockGridSize, z)
			local y3 = GetRockHeight(x, z + rockGridSize)
			local y4 = GetRockHeight(x + rockGridSize, z + rockGridSize)

			if y1 > -100 or y2 > -100 or y3 > -100 or y4 > -100 then
				local p1 = Vector3.new(x, y1, z)
				local p2 = Vector3.new(x + rockGridSize, y2, z)
				local p3 = Vector3.new(x, y3, z + rockGridSize)
				local p4 = Vector3.new(x + rockGridSize, y4, z + rockGridSize)

				local colorVar = math.random(-15, 15)
				local rockColor = Color3.fromRGB(80 + colorVar, 80 + colorVar, 80 + colorVar)

				DrawTriangle(p1, p3, p2, tempRockFolder, rockColor, Enum.Material.Rock, "rock")
				DrawTriangle(p2, p3, p4, tempRockFolder, rockColor, Enum.Material.Rock, "rock")
			end
		end
	end
	-- Now that the whole hill is built, put it in the map!
	tempRockFolder.Parent = terrainFolder
end

local function BuildMapInfrastructure(cornerA, cornerB, newBaseSize, mapBaseHeight)
	baseSize = newBaseSize

	local startX = math.min(cornerA.Position.X, cornerB.Position.X)
	local endX = math.max(cornerA.Position.X, cornerB.Position.X)
	local startZ = math.min(cornerA.Position.Z, cornerB.Position.Z)
	local endZ = math.max(cornerA.Position.Z, cornerB.Position.Z)

	local mapWidthX = endX - startX
	local mapDepthZ = endZ - startZ
	local centerX = startX + (mapWidthX / 2)
	local centerZ = startZ + (mapDepthZ / 2)

	local borderFolder = workspace.Map:FindFirstChild("MapBorders")
	if borderFolder then
		borderFolder:ClearAllChildren()
	else
		borderFolder = Instance.new("Folder")
		borderFolder.Name = "MapBorders"
		borderFolder.Parent = workspace.Map
	end

	local function CreateWallSegment(size, position, isVisible)
		local part = Instance.new("Part")
		part.Size = size
		part.Position = position
		part.Anchored = true
		part.CanCollide = true
		part.Parent = borderFolder

		if isVisible then
			part.Transparency = 0
			part.Color = Color3.fromRGB(80, 80, 80)
			part.Material = Enum.Material.Concrete
		else
			part.Transparency = 1
		end
	end

	-- 1. Visible Boundary Walls
	local visHeight = 230
	local visWallYPos = mapBaseHeight + (80 / 2) - (150 / 2)
	local visThickness = 100

	local halfWidthSize = Vector3.new(mapWidthX / 2, visHeight, visThickness)
	local northZ = endZ + (visThickness / 2)
	local southZ = startZ - (visThickness / 2)

	CreateWallSegment(halfWidthSize, Vector3.new(centerX - mapWidthX/4, visWallYPos, northZ), true)
	CreateWallSegment(halfWidthSize, Vector3.new(centerX + mapWidthX/4, visWallYPos, northZ), true)
	CreateWallSegment(halfWidthSize, Vector3.new(centerX - mapWidthX/4, visWallYPos, southZ), true)
	CreateWallSegment(halfWidthSize, Vector3.new(centerX + mapWidthX/4, visWallYPos, southZ), true)

	local eastX = endX + (visThickness / 2)
	local westX = startX - (visThickness / 2)
	local totalVisDepth = mapDepthZ + (visThickness * 2)
	local halfDepthSize = Vector3.new(visThickness, visHeight, totalVisDepth / 2)

	CreateWallSegment(halfDepthSize, Vector3.new(eastX, visWallYPos, centerZ - totalVisDepth/4), true)
	CreateWallSegment(halfDepthSize, Vector3.new(eastX, visWallYPos, centerZ + totalVisDepth/4), true)
	CreateWallSegment(halfDepthSize, Vector3.new(westX, visWallYPos, centerZ - totalVisDepth/4), true)
	CreateWallSegment(halfDepthSize, Vector3.new(westX, visWallYPos, centerZ + totalVisDepth/4), true)

	-- 2. Invisible Skybox Boundaries
	local invHeight = 2000
	local invWallYPos = mapBaseHeight + (invHeight / 2)
	local invThickness = 100

	local invNorthZ = endZ + (invThickness / 2)
	local invSouthZ = startZ - (invThickness / 2)
	local invEastX = endX + (invThickness / 2)
	local invWestX = startX - (invThickness / 2)

	local invHalfWidthSize = Vector3.new(mapWidthX / 2, invHeight, invThickness)
	local invTotalDepth = mapDepthZ + (invThickness * 2)
	local invHalfDepthSize = Vector3.new(invThickness, invHeight, invTotalDepth / 2)

	CreateWallSegment(invHalfWidthSize, Vector3.new(centerX - mapWidthX/4, invWallYPos, invNorthZ), false)
	CreateWallSegment(invHalfWidthSize, Vector3.new(centerX + mapWidthX/4, invWallYPos, invNorthZ), false)
	CreateWallSegment(invHalfWidthSize, Vector3.new(centerX - mapWidthX/4, invWallYPos, invSouthZ), false)
	CreateWallSegment(invHalfWidthSize, Vector3.new(centerX + mapWidthX/4, invWallYPos, invSouthZ), false)

	CreateWallSegment(invHalfDepthSize, Vector3.new(invEastX, invWallYPos, centerZ - invTotalDepth/4), false)
	CreateWallSegment(invHalfDepthSize, Vector3.new(invEastX, invWallYPos, centerZ + invTotalDepth/4), false)
	CreateWallSegment(invHalfDepthSize, Vector3.new(invWestX, invWallYPos, centerZ - invTotalDepth/4), false)
	CreateWallSegment(invHalfDepthSize, Vector3.new(invWestX, invWallYPos, centerZ + invTotalDepth/4), false)

	-- Roof
	local totalRoofWidth = mapWidthX + (invThickness * 2)
	local totalRoofDepth = mapDepthZ + (invThickness * 2)
	local roofPieceSize = Vector3.new(totalRoofWidth / 2, invThickness, totalRoofDepth / 2)
	local roofY = mapBaseHeight + invHeight

	local quadOffsets = {
		Vector3.new(-totalRoofWidth/4, 0, -totalRoofDepth/4),
		Vector3.new(totalRoofWidth/4, 0, -totalRoofDepth/4),
		Vector3.new(-totalRoofWidth/4, 0, totalRoofDepth/4),
		Vector3.new(totalRoofWidth/4, 0, totalRoofDepth/4)
	}
	for _, offset in ipairs(quadOffsets) do
		local roofPart = Instance.new("Part")
		roofPart.Size = roofPieceSize
		roofPart.Position = Vector3.new(centerX, roofY, centerZ) + offset
		roofPart.Anchored = true
		roofPart.CanCollide = true
		roofPart.Transparency = 1
		roofPart.Parent = borderFolder
	end

	-- 3. Base Positioning
	local teamABase = workspace:FindFirstChild("TeamABase", true) or ReplicatedStorage:FindFirstChild("TeamABase", true)
	local teamBBase = workspace:FindFirstChild("TeamBBase", true) or ReplicatedStorage:FindFirstChild("TeamBBase", true)
	if teamABase and teamBBase then
		if not teamABase.PrimaryPart then teamABase.PrimaryPart = teamABase:FindFirstChild("BaseFloorA", true) end
		if not teamBBase.PrimaryPart then teamBBase.PrimaryPart = teamBBase:FindFirstChild("BaseFloorB", true) end

		local baseExtentsA = teamABase.PrimaryPart.Size
		local baseExtentsB = teamBBase.PrimaryPart.Size

		local offsetAX = (baseExtentsA.X / 2)
		local offsetAZ = (baseExtentsA.Z / 2)
		local offsetBX = (baseExtentsB.X / 2)
		local offsetBZ = (baseExtentsB.Z / 2)

		teamABase:PivotTo(CFrame.new(Vector3.new(startX + offsetAX, -4, startZ + offsetAZ)))
		teamBBase:PivotTo(CFrame.new(Vector3.new(endX - offsetBX, -4, endZ - offsetBZ)) * CFrame.Angles(0, math.rad(180), 0))
		teamABase.Parent = workspace.Map
		teamBBase.Parent = workspace.Map
	end
end


local function BuildTeamBarriers(cornerA, cornerB, baseSize, padding)
	padding = padding or 60
	local barrierHeight = 2005
	local mapBaseHeight = 5
	local thickness = 5

	local startX = math.min(cornerA.Position.X, cornerB.Position.X)
	local endX = math.max(cornerA.Position.X, cornerB.Position.X)
	local startZ = math.min(cornerA.Position.Z, cornerB.Position.Z)
	local endZ = math.max(cornerA.Position.Z, cornerB.Position.Z)

	local borderFolder = workspace.Map:FindFirstChild("MapBorders") or workspace.Map

	-- Clean up previous barriers
	for _, child in ipairs(borderFolder:GetChildren()) do
		if child.Name == "TeamABarrier" or child.Name == "TeamBBarrier" then
			child:Destroy()
		end
	end

	local barrierDist = baseSize + padding
	local wallYPos = mapBaseHeight + (barrierHeight / 2)

	local function CreateBarrierPart(name, size, position, color, group)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.Position = position
		part.Material = Enum.Material.ForceField
		part.Color = color
		part.Transparency = 0.3
		part.Anchored = true
		part.CanCollide = true
		part.CanQuery = true
		part.CollisionGroup = group
		part.Parent = borderFolder
		return part
	end

	-- 1. Team A Box (Corner A: Min X, Min Z)
	-- Wall parallel to X-axis
	CreateBarrierPart(
		"TeamABarrier",
		Vector3.new(barrierDist, barrierHeight, thickness),
		Vector3.new(startX + barrierDist / 2, wallYPos - 4, startZ + barrierDist),
		Color3.fromRGB(0, 150, 255),
		"TeamABarrier"
	)
	-- Wall parallel to Z-axis
	CreateBarrierPart(
		"TeamABarrier",
		Vector3.new(thickness, barrierHeight, barrierDist),
		Vector3.new(startX + barrierDist, wallYPos - 4, startZ + barrierDist / 2),
		Color3.fromRGB(0, 150, 255),
		"TeamABarrier"
	)

	-- 2. Team B Box (Corner B: Max X, Max Z)
	-- Wall parallel to X-axis
	CreateBarrierPart(
		"TeamBBarrier",
		Vector3.new(barrierDist, barrierHeight, thickness),
		Vector3.new(endX - barrierDist / 2, wallYPos - 4, endZ - barrierDist),
		Color3.fromRGB(255, 50, 50),
		"TeamBBarrier"
	)
	-- Wall parallel to Z-axis
	CreateBarrierPart(
		"TeamBBarrier",
		Vector3.new(thickness, barrierHeight, barrierDist),
		Vector3.new(endX - barrierDist, wallYPos - 4, endZ - barrierDist / 2),
		Color3.fromRGB(255, 50, 50),
		"TeamBBarrier"
	)
end

local function GetTargetCount(rangeOrNumber : NumberRange | number, sizeMultiplier, fallbackMin, fallbackMax)
	local rawCount
	if typeof(rangeOrNumber) == "NumberRange" then
		rawCount = math.random(rangeOrNumber.Min, rangeOrNumber.Max)
	elseif typeof(rangeOrNumber) == "number" then
		rawCount = rangeOrNumber
	else
		rawCount = math.random(fallbackMin or 1, fallbackMax or 1)
	end
	return math.max(1, math.round(rawCount * sizeMultiplier))
end

-- Data-Driven Scatter Pass
local function RunScatterPass(rule, sizeMultiplier, placedObstacles, placedRockHills, safeZoneCheckFn, bounds)
	local targetCount = GetTargetCount(rule.CountRange or rule.BaseCount, sizeMultiplier, 1, 1)
	if rule.BonusPerRock and #placedRockHills > 0 then
		local bonusPer = math.random(rule.BonusPerRock.Min, rule.BonusPerRock.Max)
		targetCount = targetCount + (#placedRockHills * bonusPer)
	end
	local spawnedCount = 0
	local attempts = 0
	local maxAttempts = targetCount * 20

	local folder = Instance.new("Folder")
	folder.Name = rule.Name .. "Folder"
	folder.Parent = terrainFolder

	if rule.CollectionTag then
		CollectionService:AddTag(folder, rule.CollectionTag)
	end

	local function CreateBushVariant(template, rayResult, isRockTerrain, isSloped)
		local clone = template:Clone()
		local bushShape = math.random(1, 10)

		if (isRockTerrain or isSloped) and (bushShape >= 4 and bushShape <= 6) then
			bushShape = (math.random(1, 2) == 1) and math.random(1, 3) or math.random(7, 10)
		end

		local newSize
		if bushShape <= 3 then
			newSize = Vector3.new(math.random(100, 125), math.random(35, 60), math.random(100, 125))
		elseif bushShape <= 6 then
			newSize = Vector3.new(math.random(120, 240), math.random(10, 20), math.random(120, 240))
		else
			local s = math.random(80, 125)
			newSize = Vector3.new(s, s + math.random(-5, 35), s)
		end

		clone.Size = newSize
		local randomRot = CFrame.Angles(0, math.rad(math.random(0, 360)), 0)
		local sinkOffset = CFrame.new(0, -(newSize.Y * 0.25), 0)

		clone.CFrame = CFrame.new(rayResult.Position) * randomRot * sinkOffset
		clone.Parent = folder
	end

	while spawnedCount < targetCount and attempts < maxAttempts do
		attempts += 1

		local rx = math.random(bounds.startX + 150, bounds.endX - 150)
		local rz = math.random(bounds.startZ + 150, bounds.endZ - 150)

		if safeZoneCheckFn(rx, rz, rule.SafeZoneBuffer or 100) then continue end

		if rule.AvoidRockHills then
			local insideRock = false
			for _, rock in ipairs(placedRockHills) do
				local dist = math.sqrt((rx - rock.X)^2 + (rz - rock.Z)^2)
				if dist < rock.Radius then
					insideRock = true
					break
				end
			end
			if insideRock then continue end
		end

		-- spacing check against existing objects
		if not rule.IgnoreSpacing then
			local tooClose = false
			for _, obs in ipairs(placedObstacles) do
				local dist = math.sqrt((rx - obs.X)^2 + (rz - obs.Z)^2)
				local requiredDist = math.max(rule.MinDistance or 10, obs.Radius or 0)
				if dist < requiredDist then
					tooClose = true
					break
				end
			end
			if tooClose then continue end
		end

		local template = rule.Template
		if rule.TemplatesFolder then
			local children = rule.TemplatesFolder:GetChildren()
			if #children > 0 then
				template = children[math.random(1, #children)]
			end
		end
		if not template then continue end

		if rule.UseBushVariations then
			local clusterTotal = math.random(rule.ClusterCount.Min, rule.ClusterCount.Max)
			for _ = 1, clusterTotal do
				local cx = rx + math.random(-rule.ClusterRadius, rule.ClusterRadius)
				local cz = rz + math.random(-rule.ClusterRadius, rule.ClusterRadius)

				if safeZoneCheckFn(cx, cz, 50) then continue end

				local rayResult = workspace:Raycast(Vector3.new(cx, 1000, cz), Vector3.new(0, -2000, 0), raycastParams)
				if rayResult then
					local isRockTerrain = rayResult.Instance.Color.G < 0.5
					local isSloped = rayResult.Normal.Y < 0.88

					if isRockTerrain and math.random(1, 100) <= 75 then continue end
					CreateBushVariant(template, rayResult, isRockTerrain, isSloped)
				end
			end
			spawnedCount += 1
		else
			local rayResult = workspace:Raycast(Vector3.new(rx, 1000, rz), Vector3.new(0, -2000, 0), raycastParams)
			if rayResult then
				if rule.MinSlopeY and rayResult.Normal.Y < rule.MinSlopeY then continue end
				if rule.CheckGrassOnly and rayResult.Instance.Color.G <= 0.5 then continue end

				local scale = math.random(rule.ScaleRange.Min * 100, rule.ScaleRange.Max * 100) / 100
				local instance = template:Clone()
				instance:ScaleTo(scale)

				local rotY = math.rad(math.random(0, 360))
				local rotCFrame = CFrame.Angles(0, rotY, 0)
				if rule.RandomTilt then
					rotCFrame = CFrame.Angles(
						math.rad(math.random(-45, 45)),
						rotY,
						math.rad(math.random(-45, 45))
					)
				end

				local pos = rayResult.Position + (rule.GroundOffset or Vector3.zero) * scale
				instance:PivotTo(CFrame.new(pos) * rotCFrame)

				if rule.IsBuilding then
					PrepareBuilding(instance, currentConfig.BuildingThemes)
				end
				if rule.IsDestructible then
					SetupDestructibleHealth(instance, scale)
				end

				instance.Parent = folder

				local extents = instance:GetExtentsSize()
				local baseRadius = math.max(extents.X, extents.Z) / 2
				local clearanceRadius = baseRadius + (rule.FootprintBuffer or rule.MinDistance or 10)

				table.insert(placedObstacles, {
					X = rx,
					Z = rz,
					Radius = clearanceRadius,
				})

				spawnedCount += 1
			end
		end

		if attempts % 5 == 0 then task.wait() end
	end
end

local function generateTerrain(config)
	config = config or currentConfig
	
	local ignoreList = {}
	local mapBorders = workspace.Map:FindFirstChild("MapBorders")
	if mapBorders then 
		table.insert(ignoreList, mapBorders) 
	end
	local spawn = workspace:FindFirstChild("Spawn")
	if spawn then 
		table.insert(ignoreList, spawn) 
	end
	
	-- Ignore Team Bases so rock skirts don't hit base floors/structures
	local teamABase = workspace:FindFirstChild("TeamABase", true)
	if teamABase then
		table.insert(ignoreList, teamABase)
	end

	local teamBBase = workspace:FindFirstChild("TeamBBase", true)
	if teamBBase then
		table.insert(ignoreList, teamBBase)
	end
	
	raycastParams.FilterDescendantsInstances = ignoreList

	-- Async cleanup of old terrain
	local oldTerrain = terrainFolder
	oldTerrain.Name = "TrashTerrain"
	oldTerrain.Parent = nil 

	terrainFolder = Instance.new("Folder")
	terrainFolder.Name = "GeneratedTerrain"
	terrainFolder.Parent = workspace.Map

	task.spawn(function()
		for i, item in ipairs(oldTerrain:GetChildren()) do
			item:Destroy()
			if i % 100 == 0 then task.wait() end
		end
		oldTerrain:Destroy()
		print("Old map data purged")
	end)

	local bounds = {
		startX = math.min(cornerA.Position.X, cornerB.Position.X),
		endX = math.max(cornerA.Position.X, cornerB.Position.X),
		startZ = math.min(cornerA.Position.Z, cornerB.Position.Z),
		endZ = math.max(cornerA.Position.Z, cornerB.Position.Z),
	}

	local offsetX = math.random(-100000, 100000)
	local offsetZ = math.random(-100000, 100000)

	local function IsInSafeZone(x, z, padding)
		padding = padding or 0
		if x <= bounds.startX + baseSize + padding and z <= bounds.startZ + baseSize + padding then
			return true
		end
		if x >= bounds.endX - baseSize - padding and z >= bounds.endZ - baseSize - padding then
			return true
		end
		return false
	end

	local tSettings = config.Terrain
	local gridSize = tSettings.GridSize or 100
	local hillHeight = tSettings.HillHeight or 30
	local hillSmoothness = tSettings.HillSmoothness or 120

	local function GetGrassHeight(x, z)
		if IsInSafeZone(x, z, 50) then
			return tSettings.FlatBaseHeight or flatBaseHeight
		end
		local noiseValue = math.noise((x + offsetX) / hillSmoothness, (z + offsetZ) / hillSmoothness)
		return noiseValue * hillHeight
	end

	-- 1. Draw Ground Triangle Mesh
	--print("🌱 Drawing terrain triangles...")
	for x = bounds.startX, bounds.endX - gridSize, gridSize do
		for z = bounds.startZ, bounds.endZ - gridSize, gridSize do
			local y1 = GetGrassHeight(x, z)
			local y2 = GetGrassHeight(x + gridSize, z)
			local y3 = GetGrassHeight(x, z + gridSize)
			local y4 = GetGrassHeight(x + gridSize, z + gridSize)

			local p1 = Vector3.new(x, y1, z)
			local p2 = Vector3.new(x + gridSize, y2, z)
			local p3 = Vector3.new(x, y3, z + gridSize)
			local p4 = Vector3.new(x + gridSize, y4, z + gridSize)

			local colorVar = math.random(-tSettings.ColorVariance, tSettings.ColorVariance)
			local triColor = Color3.fromRGB(
				math.clamp(tSettings.BaseColor.R * 255 + colorVar, 0, 255),
				math.clamp(tSettings.BaseColor.G * 255 + colorVar, 0, 255),
				math.clamp(tSettings.BaseColor.B * 255 + colorVar, 0, 255)
			)

			DrawTriangle(p1, p3, p2, terrainFolder, triColor, tSettings.Material, tSettings.MaterialVariant)
			DrawTriangle(p2, p3, p4, terrainFolder, triColor, tSettings.Material, tSettings.MaterialVariant)
		end
		task.wait()
	end

	local placedObstacles = {}
	local placedRockHills = {}
	local mapArea = (bounds.endX - bounds.startX) * (bounds.endZ - bounds.startZ)
	local sizeMultiplier = mapArea / 4000000

	-- 2. Procedural Rock Hills (Wedges)
	if config.ProceduralHills and config.ProceduralHills.Enabled then
		--print("⛰️ Scattering procedural rock hills...")
		local HillCfg = config.ProceduralHills
		local amountOfRocksToTry = GetTargetCount(HillCfg.CountRange or HillCfg.BaseCount, sizeMultiplier, 6, 14)
		local minDistance = HillCfg.MinDistance or 180

		local radiusRange = HillCfg.RadiusRange or NumberRange.new(150, 250)
		local heightRange = HillCfg.HeightRange or NumberRange.new(50, 80)
		local sinkRange = HillCfg.SinkDepthRange or NumberRange.new(10, 35)

		for _ = 1, amountOfRocksToTry do
			local rx, rz, radius, height
			local isTooClose = true
			local attempts = 0

			while isTooClose and attempts < 10 do
				attempts += 1
				radius = math.random(radiusRange.Min, radiusRange.Max)
				height = math.random(heightRange.Min, heightRange.Max)

				rx = math.random(bounds.startX + radius + 20, bounds.endX - radius - 20)
				rz = math.random(bounds.startZ + radius + 20, bounds.endZ - radius - 20)

				if IsInSafeZone(rx, rz, radius + 20) then continue end

				isTooClose = false
				for _, oldObs in ipairs(placedObstacles) do
					local dist = math.sqrt((rx - oldObs.X)^2 + (rz - oldObs.Z)^2)
					if dist < minDistance then
						isTooClose = true
						break
					end
				end
			end

			if not isTooClose then
				local rayResult = workspace:Raycast(Vector3.new(rx, 1000, rz), Vector3.new(0, -2000, 0), raycastParams)
				if rayResult then
					local sinkDepth = math.random(sinkRange.Min, sinkRange.Max)
					local calculatedBaseY = rayResult.Position.Y - sinkDepth
					GenerateRock(rx, rz, radius, height, calculatedBaseY)
					table.insert(placedObstacles, { X = rx, Z = rz, Radius = radius })
				end
			end
			task.wait()
		end
	end

	-- 3. Data-Driven Scatters (Buildings, Bushes, Trees, Boulders)
	for _, scatterRule in ipairs(config.Scatters) do
		print("Scattering: " .. scatterRule.Name)
		RunScatterPass(scatterRule, sizeMultiplier, placedObstacles, placedRockHills, IsInSafeZone, bounds)
	end

	print("Map Generation Complete!")
end

-- BindableFunction for RoundManager
local genMapFunction = ServerStorage:FindFirstChild("GenerateMapFunction")
if not genMapFunction then
	genMapFunction = Instance.new("BindableFunction")
	genMapFunction.Name = "GenerateMapFunction"
	genMapFunction.Parent = ServerStorage
end

local function RunGeneration(newSize, configModule)
	newSize = newSize or 2000
	currentConfig = configModule or currentConfig
	print("Generating map: " .. currentConfig.Name .. " (" .. newSize .. "x" .. newSize .. ")")

	local calculatedBaseSize = math.clamp(newSize * 0.15, 350, 600)

	cornerB.Position = Vector3.new(
		cornerA.Position.X + newSize, 
		cornerB.Position.Y, 
		cornerA.Position.Z + newSize
	)

	BuildMapInfrastructure(cornerA, cornerB, calculatedBaseSize, currentConfig.Terrain.FlatBaseHeight or 5)

	BuildTeamBarriers(cornerA, cornerB, calculatedBaseSize, 60)

	generateTerrain(currentConfig)

	print("✅ SYSTEM: Map generation complete!")
	return true
end

genMapFunction.OnInvoke = RunGeneration

local adminGenEvent = ServerStorage:FindFirstChild("AdminGenMapEvent")
if not adminGenEvent then
	adminGenEvent = Instance.new("BindableEvent")
	adminGenEvent.Name = "AdminGenMapEvent"
	adminGenEvent.Parent = ServerStorage
end

adminGenEvent.Event:Connect(function(newSize)
	RunGeneration(newSize, currentConfig)
end)

regenEvent.OnServerEvent:Connect(function()
	RunGeneration(cornerB.Position.X - cornerA.Position.X, currentConfig)
end)