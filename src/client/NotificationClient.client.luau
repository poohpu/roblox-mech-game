local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local notifyPlayerEvent = ReplicatedStorage:WaitForChild("NotifyPlayer")

notifyPlayerEvent.OnClientEvent:Connect(function(title, message)
	StarterGui:SetCore("SendNotification", {
		Title = title,
		Text = message,
		Duration = 3,
	})
end)