local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Create the RemoteEvent automatically if it doesn't exist yet
local knifeHitEvent = ReplicatedStorage:FindFirstChild("KnifeHit")
if not knifeHitEvent then
	knifeHitEvent = Instance.new("RemoteEvent")
	knifeHitEvent.Name = "KnifeHit"
	knifeHitEvent.Parent = ReplicatedStorage
end

local knifeStabEvent = ReplicatedStorage:FindFirstChild("KnifeStab")
if not knifeStabEvent then
	knifeStabEvent = Instance.new("RemoteEvent")
	knifeStabEvent.Name = "KnifeStab"
	knifeStabEvent.Parent = ReplicatedStorage
end



local DAMAGE = 35
local BASE_KNIFE_RANGE = 6
local RUNNING_SPEED = 24 -- Estimated max infantry speed (studs/sec)

local roundStatus = ReplicatedStorage:FindFirstChild("RoundStatus")
if not roundStatus then
	roundStatus = Instance.new("StringValue")
	roundStatus.Name = "RoundStatus"
	roundStatus.Value = "Intermission"
	roundStatus.Parent = ReplicatedStorage
end

knifeStabEvent.OnServerEvent:Connect(function(player, pitch)
	if typeof(pitch) ~= "number" then return end
	pitch = math.clamp(pitch, -1.5, 1.5)

	-- Broadcast stab animation trigger to all other clients
	knifeStabEvent:FireAllClients(player, pitch)
end)

knifeHitEvent.OnServerEvent:Connect(function(player, hitPart, hitPosition)
	if not hitPart or not hitPart.Parent then return end

	local character = player.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then return end

	-- holding knife check
	local knifeTool = character:FindFirstChild("Knife")
	if not knifeTool or not knifeTool:IsA("Tool") then
		return 
	end

	-- Get round-trip ping in seconds (clamped to prevent extreme exploitation)
	local pingSeconds = math.clamp(player:GetNetworkPing(), 0, 1)
	
	-- Calculate dynamic lag buffer based on ping * 2 (Round Trip Time)
	local lagBuffer = RUNNING_SPEED * (pingSeconds * 2)
	local maxAllowedDistance = BASE_KNIFE_RANGE + 4 + lagBuffer

	-- Validate actual server distance
	local distance = (hitPosition - character.HumanoidRootPart.Position).Magnitude
	if distance > maxAllowedDistance then
		return -- Hit rejected due to exceeding ping-adjusted range
	end

	-- Identify target character and humanoid
	local targetModel = hitPart:FindFirstAncestorOfClass("Model")
	if not targetModel or targetModel == character then return end

	local targetHumanoid = targetModel:FindFirstChildOfClass("Humanoid")
	local targetPlayer = Players:GetPlayerFromCharacter(targetModel)

	-- Apply damage and set kill-attribution tags
	if targetHumanoid and targetHumanoid.Health > 0 and targetPlayer then
		if roundStatus.Value ~= "InRound" then return end
		if player.Team and player.Team.Name == "Lobby" then return end
		if targetPlayer.Team and targetPlayer.Team.Name == "Lobby" then return end
		if player.Team and targetPlayer.Team and player.Team == targetPlayer.Team then return end

		targetModel:SetAttribute("LastAttacker", player.UserId)
		targetModel:SetAttribute("LastDamageTime", os.clock())

		targetHumanoid:TakeDamage(DAMAGE)
		print(player.Name .. " stabbed " .. targetModel.Name .. " for " .. DAMAGE .. " damage!")
	end
end)