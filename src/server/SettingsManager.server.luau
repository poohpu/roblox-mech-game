local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local settingsStore = DataStoreService:GetDataStore("PlayerSettings_v1")

local getSettingsFunc = ReplicatedStorage:WaitForChild("GetSettings")
local saveSettingEvent = ReplicatedStorage:WaitForChild("SaveSettings")

local sessionData = {}

local DEFAULT_SETTINGS = {
	MobileFireAimSensitivity = 0.5,
}

-- Load on join
Players.PlayerAdded:Connect(function(player)
	local key = "User_" .. player.UserId
	local success, data = pcall(function()
		return settingsStore:GetAsync(key)
	end)

	if success and data then
		sessionData[player] = data
	else
		sessionData[player] = table.clone(DEFAULT_SETTINGS)
	end
end)

-- Save on leave
local function saveData(player)
	if not sessionData[player] then return end
	local key = "User_" .. player.UserId
	pcall(function()
		settingsStore:SetAsync(key, sessionData[player])
	end)
	sessionData[player] = nil
end

Players.PlayerRemoving:Connect(saveData)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		saveData(player)
	end
end)

-- Client requests initial data
getSettingsFunc.OnServerInvoke = function(player)
	return sessionData[player] or DEFAULT_SETTINGS
end

-- Client updates a setting
saveSettingEvent.OnServerEvent:Connect(function(player, settingName, value)
	if sessionData[player] and DEFAULT_SETTINGS[settingName] ~= nil then
		sessionData[player][settingName] = value
	end
end)