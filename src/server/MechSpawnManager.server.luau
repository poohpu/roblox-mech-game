-- Location: ServerScriptService 
-- Function: The traffic controller and janitor for the server. It handles spawning new mechs, transferring ownership when someone steals a mech, and deleting abandoned vehicles to prevent server lag.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local Teams = game:GetService("Teams")

local spawnEvent = ReplicatedStorage:WaitForChild("VehicleSpawnEvent")
local vehicleFolder = ServerStorage:WaitForChild("Vehicles")

local addPointsEvent = ServerStorage:WaitForChild("AddPointsEvent") 

local roundStatus = ReplicatedStorage:FindFirstChild("RoundStatus")
if not roundStatus then
	roundStatus = Instance.new("StringValue")
	roundStatus.Name = "RoundStatus"
	roundStatus.Value = "Intermission"
	roundStatus.Parent = ReplicatedStorage
end

local SPAWN_COOLDOWN = 5 -- Wait 10 seconds between spawns
local MAX_VEHICLES = 3 -- Max abandoned mechs per player
local PAD_CLEARANCE_SIZE = Vector3.new(30, 50, 30) -- How big the clearance check box is

-- Memory tables to track player data
local playerCooldowns = {}
local playerVehicles = {}

local function applyTeamHue(originalColor, teamColor)
	-- 1. Get the Lightness (Value) of the mech's original armor part
	local _, _, origLightness = originalColor:ToHSV()

	-- 2. Get the Hue and Saturation of the Spawner's team color
	local teamH, teamS, _ = teamColor:ToHSV() 

	-- 3. Combine them! This makes dark parts dark blue, and light parts light blue.
	return Color3.fromHSV(teamH, teamS, origLightness)
end

local function ShowScannerHologram(cframe, isBlocked)
	local box = Instance.new("Part")
	box.Size = PAD_CLEARANCE_SIZE
	box.CFrame = cframe
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CastShadow = false
	box.Material = Enum.Material.ForceField
	box.Color = isBlocked and Color3.new(1, 0, 0) or Color3.new(0, 1, 0)
	box.Transparency = 0.5
	box.Parent = workspace

	game.Debris:AddItem(box, 1.5)
end

-- Safely deletes a player's oldest EMPTY mech to keep the server clean
local function EnforceVehicleLimit(userId)
	local myVehicles = playerVehicles[userId]
	if not myVehicles then return end

	-- Clean out dead/blown up mechs from the list
	for i = #myVehicles, 1, -1 do
		if not myVehicles[i] or not myVehicles[i].Parent then
			table.remove(myVehicles, i)
		end
	end

	-- If they are over the limit, find the oldest EMPTY one and scrap it
	while #myVehicles > MAX_VEHICLES do
		local deletedOne = false
		for i, mech in ipairs(myVehicles) do
			local seat = mech:FindFirstChildWhichIsA("VehicleSeat", true)
			if seat and not seat.Occupant then
				mech:Destroy()
				table.remove(myVehicles, i)
				deletedOne = true
				break
			end
		end

		-- If ALL their mechs are somehow occupied, just delete the oldest one period to save the server
		if not deletedOne then
			local oldMech = table.remove(myVehicles, 1)
			if oldMech then oldMech:Destroy() end
		end
	end
end

-- Transfers ownership of a mech to whoever sits in it
local function TransferOwnership(mech, newPlayer)
	local currentOwnerId = mech:GetAttribute("OwnerId")
	if currentOwnerId == newPlayer.UserId then return end -- They already own it!

	-- 1. Remove it from the OLD owner's list
	if currentOwnerId and playerVehicles[currentOwnerId] then
		local oldList = playerVehicles[currentOwnerId]
		local index = table.find(oldList, mech)
		if index then table.remove(oldList, index) end
	end

	-- 2. Give it to the NEW owner
	mech:SetAttribute("OwnerId", newPlayer.UserId)
	if not playerVehicles[newPlayer.UserId] then playerVehicles[newPlayer.UserId] = {} end
	table.insert(playerVehicles[newPlayer.UserId], mech)

	-- 3. Destroy any "Owner Left" billboard if it was counting down!
	local abandonUI = mech:FindFirstChild("AbandonUI", true)
	if abandonUI then abandonUI:Destroy() end

	-- 4. Check if the new owner has too many mechs now
	EnforceVehicleLimit(newPlayer.UserId)
end

-- Clean up memory when a player leaves the game
Players.PlayerRemoving:Connect(function(player)
	playerCooldowns[player.UserId] = nil

	-- Optional: Automatically destroy all their mechs when they leave
	if playerVehicles[player.UserId] then
		local abandonedMechs = playerVehicles[player.UserId]
		playerVehicles[player.UserId] = nil -- Free up server memory immediately
		
		for _, mech in ipairs(abandonedMechs) do
			if mech and mech.Parent then
				-- Run this in a separate thread so it doesn't pause the server!
				task.spawn(function()
					local anchor = mech.PrimaryPart or mech:FindFirstChild("VehicleSeat", true)
					if not anchor then mech:Destroy(); return end

					-- 1. Create the UI
					local billboard = Instance.new("BillboardGui")
					billboard.Name = "AbandonUI"
					billboard.Size = UDim2.new(0, 200, 0, 50)
					billboard.StudsOffset = Vector3.new(0, 10, 0) -- Float 10 studs above the mech
					billboard.AlwaysOnTop = true
					billboard.MaxDistance = 100

					local textLabel = Instance.new("TextLabel")
					textLabel.Size = UDim2.new(1, 0, 1, 0)
					textLabel.BackgroundTransparency = 1
					textLabel.TextColor3 = Color3.new(1, 0.2, 0.2) -- Red text
					textLabel.TextStrokeTransparency = 0
					textLabel.TextScaled = true
					textLabel.Font = Enum.Font.Jura
					textLabel.Parent = billboard
					billboard.Parent = anchor

					-- 2. The Countdown Loop
					for i = 30, 1, -1 do
						-- If the mech was destroyed during the countdown, stop counting!
						if not mech or not mech.Parent then return end
						if mech:GetAttribute("OwnerId") ~= player.UserId then return end

						textLabel.Text = "Owner Left\nDeleting in: " .. i
						task.wait(1)
					end

					-- 3. Cleanup
					if mech and mech.Parent and mech:GetAttribute("OwnerId") == player.UserId then
						mech:Destroy()
					end
				end)
			end
		end
	end
end)

spawnEvent.OnServerEvent:Connect(function(player, requestedVehicleName, spawnerButton, vehiclespawnLocation)
	if roundStatus.Value ~= "InRound" then
		warn(player.Name .. " attempted to spawn a vehicle outside of an active round.")
		return
	end
	-- Does this vehicle actually exist in our vault?
	local vehiclePrefab = vehicleFolder:FindFirstChild(requestedVehicleName)
	if not vehiclePrefab then 
		warn(player.Name .. " tried to spawn an invalid vehicle!")
		return 
	end
	
	-- Check if the vehicle has a point cost and if the player can afford it
	local spawnCost = vehiclePrefab:GetAttribute("SpawnCost") or 0
	local leaderstats = player:FindFirstChild("leaderstats")
	local pointsVal = leaderstats and leaderstats:FindFirstChild("Points")
	local currentPoints = pointsVal and pointsVal.Value or 0

	if currentPoints < spawnCost then
		warn(string.format("%s cannot afford %s! (Cost: %d, Has: %d)", player.Name, requestedVehicleName, spawnCost, currentPoints))
		return
	end

	-- Is the player actually standing near the spawner?
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not spawnerButton or not vehiclespawnLocation then return end

	local distance = (rootPart.Position - spawnerButton.Position).Magnitude
	if distance > 20 then 
		warn(player.Name .. " is too far away to use this spawner!")
		return 
	end

	local lastSpawnTime = playerCooldowns[player.UserId] or 0
	if os.clock() - lastSpawnTime < SPAWN_COOLDOWN then
		-- They are clicking too fast!
		warn(player.Name .. " is on vehicle cooldown!")
		return 
	end
	
	local hoverCFrame = vehiclespawnLocation.CFrame * CFrame.new(0, 15, 0)
	local targetCFrame = hoverCFrame -- Default to hovering

	-- Find the floor
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = {spawnerButton, vehiclespawnLocation}
	local hit = workspace:Raycast(hoverCFrame.Position, Vector3.new(0, -50, 0), rayParams)

	if hit then
		-- We subtract 15 to get the base of the pad, then add 1 for safety
		targetCFrame = CFrame.new(hit.Position + Vector3.new(0, 1, 0)) * hoverCFrame.Rotation
	end

	-- Draw an invisible box at the spawn location to see what is inside it
	local overlapParams = OverlapParams.new()
	local partsInBox = workspace:GetPartBoundsInBox(targetCFrame, PAD_CLEARANCE_SIZE, overlapParams)
	local isBlocked = false
	
	for _, part in ipairs(partsInBox) do
		local model = part:FindFirstAncestorWhichIsA("Model")
		-- If we find a part belonging to ANY vehicle, cancel the spawn!
		if model and CollectionService:HasTag(model, "Vehicle") then
			if part.Transparency < 1 or part.CanCollide then
				warn("Pad is blocked by another vehicle! (Tripped by: " .. part.Name .. ")")
				isBlocked = true
				break
			end
		end
	end

	ShowScannerHologram(targetCFrame, isBlocked)
	
	if isBlocked then return end -- Stop the spawn!
	
	local newMech = vehiclePrefab:Clone()
	local padTeamColor = spawnerButton:GetAttribute("TeamColor") or Color3.fromRGB(255, 255, 255)
	local padAccentColor = spawnerButton:GetAttribute("AccentColor") or Color3.fromRGB(255, 255, 255)
	
	for _, part in ipairs(newMech:GetDescendants()) do
		if part:IsA("BasePart") then
			-- Check if this specific part is flagged as paintable
			if part:GetAttribute("Colorable") and part:GetAttribute("Colorable") == true then
				part.Color = applyTeamHue(part.Color, padTeamColor)
			elseif part:GetAttribute("AccentColorable") and part:GetAttribute("AccentColorable") == true then
				part.Color = applyTeamHue(part.Color, padAccentColor)
			end
		end
	end
	
	-- Calculate the exact pivot offset to ground it perfectly
	local targetGround = newMech:FindFirstChild("TargetGround", true)
	if targetGround and hit then
		local pivotOffset = newMech:GetPivot().Y - targetGround.Position.Y
		targetCFrame = CFrame.new(hit.Position + Vector3.new(0, pivotOffset + 1, 0)) * hoverCFrame.Rotation
	end

	newMech:PivotTo(targetCFrame)
	CollectionService:AddTag(newMech, "Vehicle") 
	newMech.Parent = workspace
	
	
	-- Give ownership to the spawner
	if not playerVehicles[player.UserId] then playerVehicles[player.UserId] = {} end
	newMech:SetAttribute("OwnerId", player.UserId)
	table.insert(playerVehicles[player.UserId], newMech)

	playerCooldowns[player.UserId] = os.clock()
	
	-- Deduct points only after the vehicle successfully spawns
	if spawnCost > 0 and addPointsEvent then
		addPointsEvent:Fire(player, -spawnCost)
		print(spawnCost)
	end
	
	EnforceVehicleLimit(player.UserId)
	
	local seat = newMech:FindFirstChildWhichIsA("VehicleSeat", true)
	if seat then
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local occupant = seat.Occupant
			if occupant and occupant.Parent then
				local newDriver = Players:GetPlayerFromCharacter(occupant.Parent)
				if newDriver then
					TransferOwnership(newMech, newDriver)
				end
			end
		end)
	end
		
	task.spawn(function()
		local anchor = newMech:FindFirstChild("VehicleSeat", true) or newMech.PrimaryPart
		if not anchor then return end

		-- 1. Create a warning hologram (invisible at first)
		local warningGui = Instance.new("BillboardGui")
		warningGui.Size = UDim2.new(0, 250, 0, 60)
		warningGui.StudsOffset = Vector3.new(0, 10, 0) -- Float above the mech
		warningGui.AlwaysOnTop = true
		warningGui.Enabled = false
		warningGui.MaxDistance = 200

		local textLabel = Instance.new("TextLabel")
		textLabel.Size = UDim2.new(1, 0, 1, 0)
		textLabel.BackgroundTransparency = 1
		textLabel.TextColor3 = Color3.new(1, 0.5, 0) -- Warning Orange!
		textLabel.TextStrokeTransparency = 0
		textLabel.TextScaled = true
		textLabel.Font = Enum.Font.Jura
		textLabel.Parent = warningGui
		warningGui.Parent = anchor

		-- 2. The Loiter Logic
		local loiterTime = 0
		local MAX_LOITER = 30 -- Total seconds allowed on the pad
		local PAD_RADIUS = 30 -- Studs away they must drive to be "clear"

		while newMech and newMech.Parent do
			local isOnAnyPad = false
			local allSpawnPads = CollectionService:GetTagged("SpawnPad")
			
			for _, pad in ipairs(allSpawnPads) do
				local dist = (anchor.Position - pad.Position).Magnitude
				if dist <= PAD_RADIUS then
					isOnAnyPad = true
					break -- We found one! Stop searching the other pads to save CPU.
				end
			end

			-- If you haven't tagged them yet, just check the original spawn point
			if #allSpawnPads == 0 then
				local dist = (anchor.Position - targetCFrame.Position).Magnitude
				if dist <= PAD_RADIUS then isOnAnyPad = true end
			end
			
			local dist = (anchor.Position - targetCFrame.Position).Magnitude

			if isOnAnyPad then
				loiterTime += 1

				-- If they sit for 10 seconds, flash the warning!
				if loiterTime > 10 then
					warningGui.Enabled = true
					textLabel.Text = "Clear the Spawn Pad!\n" .. (MAX_LOITER - loiterTime)
				end

				-- If time runs out, vaporize the mech!
				if loiterTime >= MAX_LOITER then
					newMech:Destroy()
					break
				end
			else
				-- They successfully drove off the pad.
				-- Reset the timer and hide the warning in case they drive back later!
				loiterTime = 0
				warningGui.Enabled = false
			end

			task.wait(1) -- Check once per second
		end
	end)

	
end)
