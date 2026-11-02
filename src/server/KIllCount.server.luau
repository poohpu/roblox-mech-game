local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local PILOT_KILL_POINTS = 100

local COMBAT_LOG_TIME = 10
local activeCharacters = {}

local addPointsEvent = ServerStorage:WaitForChild("AddPointsEvent")

-- Create the MechKillEvent BindableEvent so MechDamageManager can notify us when a mech dies
local mechKillEvent = ServerStorage:FindFirstChild("MechKillEvent")
if not mechKillEvent then
	mechKillEvent = Instance.new("BindableEvent")
	mechKillEvent.Name = "MechKillEvent"
	mechKillEvent.Parent = ServerStorage
end

-- Set up leaderstats for a player
local function setupLeaderstats(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then return end -- Already set up

	leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local playerKills = Instance.new("IntValue")
	playerKills.Name = "Pilot Kills"
	playerKills.Value = 0
	playerKills.Parent = leaderstats

	local mechKills = Instance.new("IntValue")
	mechKills.Name = "Mech Kills"
	mechKills.Value = 0
	mechKills.Parent = leaderstats
end

-- Credit a player kill to the attacker
local function creditPlayerKill(victimCharacter)
	if not victimCharacter then return end

	local attackerUserId = victimCharacter:GetAttribute("LastAttacker")
	victimCharacter:SetAttribute("LastAttacker", nil)

	if not attackerUserId then return end

	local victimPlayer = Players:GetPlayerFromCharacter(victimCharacter)
	if victimPlayer and victimPlayer.UserId == attackerUserId then return end -- Self-kill, skip

	local attacker = Players:GetPlayerByUserId(attackerUserId)
	if not attacker then return end -- Attacker left the game

	local leaderstats = attacker:FindFirstChild("leaderstats")
	if not leaderstats then return end

	local playerKills = leaderstats:FindFirstChild("Pilot Kills")
	if playerKills then
		playerKills.Value += 1
	end
	
	addPointsEvent:Fire(attackerUserId, PILOT_KILL_POINTS)
end

-- Credit a mech kill to the attacker
local function creditMechKill(mechModel, attackerUserId)
	if not attackerUserId then return end

	local attacker = Players:GetPlayerByUserId(attackerUserId)
	if not attacker then return end -- Attacker left the game

	local leaderstats = attacker:FindFirstChild("leaderstats")
	if not leaderstats then return end

	local mechKills = leaderstats:FindFirstChild("Mech Kills")
	if mechKills then
		mechKills.Value += 1
	end
	
	-- award 50 percent
	local totalBounty = (mechModel and mechModel:GetAttribute("Bounty")) or 200
	local coreKillReward = math.floor(totalBounty * 0.5)

	addPointsEvent:Fire(attackerUserId, coreKillReward)
end

-- Handle a player's character spawning
local function onCharacterAdded(player, character)
	activeCharacters[player] = character
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	humanoid.Died:Connect(function()
		creditPlayerKill(character)
	end)
end

-- Handle a player joining
local function onPlayerAdded(player)
	setupLeaderstats(player)

	if player.Character then
		onCharacterAdded(player, player.Character)
	end

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
end

-- Listen for new players
Players.PlayerAdded:Connect(onPlayerAdded)

-- Handle players already in the game
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

-- Listen for mech kills from MechDamageManager
mechKillEvent.Event:Connect(function(mechModel, attackerUserId)
	creditMechKill(mechModel, attackerUserId)
end)

local function onPlayerRemoving(player)
	local character = activeCharacters[player]
	activeCharacters[player] = nil -- Clean up memory
	
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	-- Only penalize if they were alive when they quit
	if not humanoid or humanoid.Health <= 0 then return end

	local lastDamageTime = character:GetAttribute("LastDamageTime")
	local lastAttacker = character:GetAttribute("LastAttacker")

	if lastAttacker and lastDamageTime and (os.clock() - lastDamageTime) <= COMBAT_LOG_TIME then
		print(string.format("%s disconnected during combat! Crediting attacker.", player.Name))
		creditPlayerKill(character)
	end
end

Players.PlayerRemoving:Connect(onPlayerRemoving)
