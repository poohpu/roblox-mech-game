local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Create the RemoteEvent automatically if it doesn't exist yet
local knifeHitEvent = ReplicatedStorage:FindFirstChild("KnifeHit")
if not knifeHitEvent then
	knifeHitEvent = Instance.new("RemoteEvent")
	knifeHitEvent.Name = "KnifeHit"
	knifeHitEvent.Parent = ReplicatedStorage
end

local DAMAGE = 35
local BASE_KNIFE_RANGE = 6
local RUNNING_SPEED = 24 -- Estimated max infantry speed (studs/sec)

knifeHitEvent.OnServerEvent:Connect(function(player, hitPart, hitPosition)
	if not hitPart or not hitPart.Parent then return end

	local character = player.Character
	if not character or not character:FindFirstChild("HumanoidRootPart") then return end

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
	if targetHumanoid and targetHumanoid.Health > 0 then
		-- Prevent friendly fire between teammates
		if player.Team and targetPlayer and targetPlayer.Team and player.Team == targetPlayer.Team then
			return
		end

		targetModel:SetAttribute("LastAttacker", player.UserId)
		targetModel:SetAttribute("LastDamageTime", os.clock())

		targetHumanoid:TakeDamage(DAMAGE)
		print(player.Name .. " stabbed " .. targetModel.Name .. " for " .. DAMAGE .. " damage!")
	end
end)