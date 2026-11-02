local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local footstepEvent = ReplicatedStorage:FindFirstChild("MechFootstepEvent")
if not footstepEvent then
	footstepEvent = Instance.new("UnreliableRemoteEvent")
	footstepEvent.Name = "MechFootstepEvent"
	footstepEvent.Parent = ReplicatedStorage
end

footstepEvent.OnServerEvent:Connect(function(driverPlayer, position, material)
	if typeof(position) ~= "Vector3" or typeof(material) ~= "EnumItem" then return end
	
	-- Broadcast to every player EXCEPT the driver (who already heard it locally)
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= driverPlayer then
			footstepEvent:FireClient(player, position, material)
		end
	end
end)