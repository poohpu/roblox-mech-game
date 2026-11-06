local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local pistolFireEvent = ReplicatedStorage:WaitForChild("PistolFire")
local pistolFiredEvent = ReplicatedStorage:WaitForChild("PistolFired")

local pilotAimEvent = ReplicatedStorage:WaitForChild("PilotAim")

local DAMAGE = 20
local MAX_RANGE = 300
local COOLDOWN = 0.15

local playerTimeBanks = {}
local playerLastFireTime = {}
local playerTracerCooldowns = {}

local roundStatus = ReplicatedStorage:FindFirstChild("RoundStatus")
if not roundStatus then
	roundStatus = Instance.new("StringValue")
	roundStatus.Name = "RoundStatus"
	roundStatus.Value = "Intermission"
	roundStatus.Parent = ReplicatedStorage
end

pistolFireEvent.OnServerEvent:Connect(function(player, hitPart, hitPosition)

	local now = os.clock()
	local lastTime = playerLastFireTime[player] or now
	playerLastFireTime[player] = now

	-- TOKEN BUCKET: Accumulate time bank to forgive network packet jitter
	local timeSinceLast = now - lastTime
	local bank = math.min((playerTimeBanks[player] or (COOLDOWN * 2)) + timeSinceLast, COOLDOWN * 3)
	local bulletCost = COOLDOWN * 0.75 -- 25% ping buffer

	if bank < bulletCost then
		return -- Rejected due to excessive fire rate
	end

	playerTimeBanks[player] = bank - COOLDOWN

	-- Validate player has the tool equipped
	local character = player.Character
	if not character then return end

	local currentPistol = character:FindFirstChild("Pistol")
	if not currentPistol or not currentPistol:IsA("Tool") then
		return 
	end

	-- Validate distance
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end
	if (hitPosition - rootPart.Position).Magnitude > (MAX_RANGE + 20) then return end

	if hitPart and hitPart.Parent then
		local targetCharacter = hitPart:FindFirstAncestorOfClass("Model")
		if not targetCharacter or targetCharacter == character then return end

		local targetHumanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
		local targetPlayer = Players:GetPlayerFromCharacter(targetCharacter)

		if targetHumanoid and targetHumanoid.Health > 0 and targetPlayer then
			if roundStatus.Value ~= "InRound" then return end
			if player.Team and player.Team.Name == "Lobby" then return end
			if targetPlayer.Team and targetPlayer.Team.Name == "Lobby" then return end
			if player.Team and targetPlayer.Team and player.Team == targetPlayer.Team then return end

			targetCharacter:SetAttribute("LastAttacker", player.UserId)
			targetCharacter:SetAttribute("LastDamageTime", os.clock())

			targetHumanoid:TakeDamage(DAMAGE)
		end
	end
end)

-- Broadcast visual tracer data to all clients
pistolFiredEvent.OnServerEvent:Connect(function(player, muzzlePos, launchDirection)
	-- Sanity check: Ensure valid vector data
	if typeof(muzzlePos) ~= "Vector3" or typeof(launchDirection) ~= "Vector3" then return end

	-- Rate-limit visual broadcasts
	local lastTracer = playerTracerCooldowns[player] or 0
	if os.clock() - lastTracer < (COOLDOWN * 0.7) then return end
	playerTracerCooldowns[player] = os.clock()

	-- Relay to all clients including the shooter identity
	pistolFiredEvent:FireAllClients(player, muzzlePos, launchDirection)
end)

pilotAimEvent.OnServerEvent:Connect(function(player, pitch)
	if typeof(pitch) ~= "number" then return end
	pitch = math.clamp(pitch, -1.5, 1.5) -- Guard against invalid or exploited angles

	pilotAimEvent:FireAllClients(player, pitch)
end)

Players.PlayerRemoving:Connect(function(player)
	playerTimeBanks[player] = nil
	playerLastFireTime[player] = nil
	playerTracerCooldowns[player] = nil
end)