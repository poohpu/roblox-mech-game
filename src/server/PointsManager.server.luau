local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ServerStorage = game:GetService("ServerStorage")

local PointsStore = DataStoreService:GetDataStore("PlayerPoints_v1")
local EXPIRATION_WINDOW = 3600 -- 1 hour in seconds
local DEFAULT_POINTS = 0

local activePointBalances = {}
local loadedPlayers = {}
local syncingValue = {} -- guards against our own writes so external edits sync back

local addPointsEvent = ServerStorage:FindFirstChild("AddPointsEvent")
if not addPointsEvent then
	addPointsEvent = Instance.new("BindableEvent")
	addPointsEvent.Name = "AddPointsEvent"
	addPointsEvent.Parent = ServerStorage
end

local function loadPoints(player)
	if loadedPlayers[player.UserId] then return end
	loadedPlayers[player.UserId] = true
	
	local leaderstats = player:WaitForChild("leaderstats", 5)
	if not leaderstats then 
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end
	
	local points = leaderstats:FindFirstChild("Points")
	if not points then
		points = Instance.new("IntValue")
		points.Name = "Points"
		points.Value = DEFAULT_POINTS
		points.Parent = leaderstats
	end
	
	local key = "Player_" .. player.UserId
	local success, saved = pcall(function()
		return PointsStore:GetAsync(key)
	end)
	
	local loadedPoints =  DEFAULT_POINTS
	
	if success and saved then
		local timePassed = os.time() - (saved.LastSeen or 0)
		if timePassed <= EXPIRATION_WINDOW then
			loadedPoints = saved.Points or DEFAULT_POINTS
			print(string.format("Loaded %d points for %s (away for %d s)", points.Value, player.Name, timePassed))
		else
			print(string.format("Points expired for %s (away for %d s > %d s)", player.Name, timePassed, EXPIRATION_WINDOW))
		end
	elseif not success then
		warn("Failed to load points for " .. player.Name .. ": " .. tostring(saved))
		
	end
	
	-- Initialize exact balance tracking in memory
	activePointBalances[player.UserId] = loadedPoints
	points.Value = math.floor(loadedPoints)

	-- Keep the in-memory float balance in sync when the IntValue is changed
	-- by anything other than this script (command bar, other scripts, etc.).
	-- Without this, external edits look fine until the next point award, which
	-- recomputes from the stale in-memory balance and reverts them.
	points.Changed:Connect(function(newValue)
		if not syncingValue[player.UserId] then
			activePointBalances[player.UserId] = newValue
		end
	end)

end

local function savePoints(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	local pointsValue = leaderstats and leaderstats:FindFirstChild("Points")
	if not pointsValue then return end

	local key = "Player_" .. player.UserId
	local payload = {
		Points = pointsValue.Value,
		LastSeen = os.time()
	}
	
	activePointBalances[player.UserId] = nil
	loadedPlayers[player.UserId] = nil

	local success, err = pcall(function()
		PointsStore:SetAsync(key, payload)
	end)

	if not success then
		warn("Failed to save points for " .. player.Name .. ": " .. tostring(err))
	end
end

Players.PlayerAdded:Connect(loadPoints)
-- player who entered before the scripts loaded
for _, player in ipairs(Players:GetPlayers()) do
	loadPoints(player)
end

Players.PlayerRemoving:Connect(savePoints)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		savePoints(player)
	end
end)

addPointsEvent.Event:Connect(function(target, amount)
	local player = nil
	
	if typeof(target) == "Instance" and target:IsA("Player") then
		player = target
	elseif typeof(target) == "number" then
		player = Players:GetPlayerByUserId(target)
	end
	
	if not player then return end
	
	local leaderstats = player:FindFirstChild("leaderstats")
	local pointsValue = leaderstats and leaderstats:FindFirstChild("Points")
	if not pointsValue then return end
	
	local userId = player.UserId
	local currentBalance = activePointBalances[userId] or pointsValue.Value
	print(currentBalance)
	local newBalance = math.max(0, currentBalance + amount)
	
	activePointBalances[userId] = newBalance
	
	local leaderstats = player:FindFirstChild("leaderstats")
	local pointsValue = leaderstats and leaderstats:FindFirstChild("Points")
	local storedFloat = activePointBalances[userId] or pointsValue.Value
	--print(string.format("POINTS DIAGNOSTIC - Target: %s | Added: %.3f | IntValue: %d | Stored Float: %.3f", 
	--	player.Name,
	--	amount, 
	--	pointsValue.Value, 
	--	storedFloat
	--	))
	if pointsValue then
		syncingValue[userId] = true
		pointsValue.Value = math.floor(newBalance)
		syncingValue[userId] = nil
		print(string.format("%s: %+d points (New Balance: %d)", player.Name, newBalance - currentBalance, newBalance))
	end
	
end)