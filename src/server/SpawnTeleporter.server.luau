local Players = game:GetService("Players")
local Teams = game:GetService("Teams")

local teleportersFolder = workspace:WaitForChild("Spawn"):WaitForChild("Teleporters")
local mapFolder = workspace:WaitForChild("Map")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local ServerStorage = game:GetService("ServerStorage")
local toolsFolder = ServerStorage:WaitForChild("Tools")

local notifyPlayerEvent = ReplicatedStorage:WaitForChild("NotifyPlayer")

local requestTeamChangeEvent = ReplicatedStorage:WaitForChild("RequestTeamChange")

local roundStatus = ReplicatedStorage:FindFirstChild("RoundStatus")
if not roundStatus then
	roundStatus = Instance.new("StringValue")
	roundStatus.Name = "RoundStatus"
	roundStatus.Value = "Intermission"
	roundStatus.Parent = ReplicatedStorage
end

local teamABase = ReplicatedStorage:FindFirstChild("TeamABase", true) or workspace:FindFirstChild("TeamABase", true)
local teamBBase = ReplicatedStorage:FindFirstChild("TeamBBase", true) or workspace:FindFirstChild("TeamBBase", true)

local padA = teleportersFolder:WaitForChild("ATeleport")

local padB = teleportersFolder:WaitForChild("BTeleport")

local teleportingPlayers = {} -- A table to track individual players so the pad doesn't lock for everyone

local COMBAT_LOG_TIME = 10
local CHANGE_TEAM_COOLDOWN = 10 
local changeTeamCooldowns = {}

local function givePistol(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	local character = player.Character

	if not backpack or not character then return end

	-- Check if the player already has a pistol equipped or in their inventory
	local hasPistol = backpack:FindFirstChild("Pistol") or character:FindFirstChild("Pistol")
	if hasPistol then return end

	-- Clone a fresh pistol into their backpack
	local pistolTemplate = toolsFolder:FindFirstChild("Pistol")
	if pistolTemplate then
		local newPistol = pistolTemplate:Clone()
		newPistol.Parent = backpack
	end
end

local function ApplyCharacterCollisionGroup(player, character)
	if not character or not player.Team or player.Team.Name == "Lobby" then return end

	local teamGroup = (player.Team.Name == "Blue Team") and "TeamAMembers" or "TeamBMembers"

	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and (part.CollisionGroup == "Default" or part.CollisionGroup == "Players" or part.CollisionGroup == "TeamAMembers" or part.CollisionGroup == "TeamBMembers") then
			part.CollisionGroup = teamGroup
		end
	end
end

local function canJoinTeam(targetTeamName)
	local blueTeam = Teams:FindFirstChild("Blue Team")
	local redTeam = Teams:FindFirstChild("Red Team")
	
	if not blueTeam or not redTeam then
		return true
	end
	
	local totalPlayers = #Players:GetPlayers()
	-- Each team can hold up to half the server's active players (minimum 1 per team)
	local maxPerTeam = math.max(1, math.ceil(totalPlayers / 2))

	local targetTeam = Teams:FindFirstChild(targetTeamName)
	if not targetTeam then
		return false, "Invalid team"
	end

	local targetCount = #targetTeam:GetPlayers()

	if targetCount >= maxPerTeam then
		return false, "This team is full, join the other team."
	end
	
	return true
end

local function setupTeleporter(startPad, teamName, targetBaseName)
	local isTeleporting = false -- This is our "debounce" (cooldown)

	startPad.Touched:Connect(function(hit)
	
		-- Check if whatever touched the pad is a player/character
		local character = hit.Parent
		local player = Players:GetPlayerFromCharacter(character)
		local rootPart = character:FindFirstChild("HumanoidRootPart")

		if player and rootPart then
			if roundStatus.Value ~= "InRound" then
				return
			end
			
			if teleportingPlayers[player.UserId] then return end
			teleportingPlayers[player.UserId] = true
			
			local canJoin, reason = canJoinTeam(teamName)
			if not canJoin then
				notifyPlayerEvent:FireClient(player, "Team Balance", reason)
				task.wait(2)
				teleportingPlayers[player.UserId] = nil
				return
			end
			
			local targetBase = mapFolder:FindFirstChild(targetBaseName, true)

			if targetBase then
				-- Create an empty list, and fill it with every SpawnLocation we find
				local availableSpawns = {}
				for _, obj in ipairs(targetBase:GetDescendants()) do
					if obj:IsA("SpawnLocation") then
						table.insert(availableSpawns, obj)
					end
				end
				if #availableSpawns > 0 then
					-- Pick a random number between 1 and the total amount of spawns we found
					local randomSpawn = availableSpawns[math.random(1, #availableSpawns)]

					-- Teleport the player slightly above the pad so they don't clip into the floor
					rootPart.CFrame = randomSpawn.CFrame + Vector3.new(0, 3, 0)
					
					givePistol(player)
					
					local targetTeam = Teams:FindFirstChild(teamName)
					if targetTeam then
						player.Team = targetTeam
					end
				else
					warn("Map Error: No SpawnLocations found inside " .. targetBaseName)
				end
				
			else
				warn("Map Error: Could not find " .. targetBaseName .. " in the active Map!")
			end

			-- Wait 1 second before THIS PLAYER can use a pad again
			task.wait(1)
			teleportingPlayers[player.UserId] = nil
		end
	end)
end

setupTeleporter(padA, "Blue Team", "TeamABase")
setupTeleporter(padB, "Red Team", "TeamBBase")

local function onCharacterAdded(character, player)
	-- Brief yield so Roblox finishes initializing the Backpack
	task.wait(0.1)

	-- Only grant the weapon if the round is active and they are not in the lobby
	if roundStatus.Value == "InRound" and player.Team and player.Team.Name ~= "Lobby" then
		givePistol(player)
	end
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("HumanoidRootPart", 5)
		ApplyCharacterCollisionGroup(player, character)
		onCharacterAdded(character, player)
	end)
	
	player:GetPropertyChangedSignal("Team"):Connect(function()
		if player.Character then
			ApplyCharacterCollisionGroup(player, player.Character)
		end
	end)
end

-- Connect existing and incoming players
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end
Players.PlayerAdded:Connect(onPlayerAdded)

requestTeamChangeEvent.OnServerEvent:Connect(function(player)
	if player.Team and player.Team.Name == "Lobby" then return end
	local now = os.clock()
	local lastRequest = changeTeamCooldowns[player.UserId]

	-- Block requests if cooldown is still active
	if lastRequest and (now - lastRequest) < CHANGE_TEAM_COOLDOWN then
		local remaining = math.ceil(CHANGE_TEAM_COOLDOWN - (now - lastRequest))
		notifyPlayerEvent:FireClient(player, "Change Team", "Wait " .. remaining .. "s before changing teams again")
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if character and humanoid and humanoid.Health > 0 then
		local lastDamageTime = character:GetAttribute("LastDamageTime")

		-- Check if they are inside a mech that took recent damage
		local seat = humanoid.SeatPart
		local mechModel = seat and seat:FindFirstAncestorWhichIsA("Model")
		if mechModel and CollectionService:HasTag(mechModel, "Vehicle") then
			local mechDamageTime = mechModel:GetAttribute("LastDamageTime")
			if mechDamageTime and (not lastDamageTime or mechDamageTime > lastDamageTime) then
				lastDamageTime = mechDamageTime
				-- Transfer mech's attacker to character so KillCount credits the pilot kill
				character:SetAttribute("LastAttacker", mechModel:GetAttribute("LastAttacker"))
			end
		end

		-- If attacked recently, kill the humanoid so the attacker gets full credit
		if lastDamageTime and (os.clock() - lastDamageTime) <= COMBAT_LOG_TIME then
			notifyPlayerEvent:FireClient(player, "Combat Logged", "You were defeated for leaving during combat.")
			humanoid.Health = 0
			task.wait(1.5) 
		end
	end

	changeTeamCooldowns[player.UserId] = now

	local lobbyTeam = Teams:FindFirstChild("Lobby")
	if lobbyTeam then
		player.Team = lobbyTeam
	end

	-- Clear any active pad cooldowns for this player
	teleportingPlayers[player.UserId] = nil

	task.spawn(function()
		player:LoadCharacterAsync()
	end)
end)