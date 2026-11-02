-- Location: ServerScriptService -> Script named "RoundManager"
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Match Configurations
local INTERMISSION_TIME = 10
local ROUND_TIME = 900 -- 15 minutes (in seconds)
local MAP_SIZE = 1600

-- Global State Values for Client UI & Game Logic
local statusValue = ReplicatedStorage:FindFirstChild("RoundStatus")
if not statusValue then
	statusValue = Instance.new("StringValue")
	statusValue.Name = "RoundStatus"
	statusValue.Value = "Intermission"
	statusValue.Parent = ReplicatedStorage
end

local timerValue = ReplicatedStorage:FindFirstChild("RoundTimer")
if not timerValue then
	timerValue = Instance.new("IntValue")
	timerValue.Name = "RoundTimer"
	timerValue.Value = 0
	timerValue.Parent = ReplicatedStorage
end

-- Reference to the terrain generator hook
local genMapFunction = ServerStorage:WaitForChild("GenerateMapFunction")

local CollectionService = game:GetService("CollectionService")
local Teams = game:GetService("Teams")

local function CleanupMatch()

	for _, vehicle in ipairs(CollectionService:GetTagged("Vehicle")) do
		if vehicle:IsDescendantOf(workspace) then
			vehicle:Destroy()
		end
	end
	
	local lobbyTeam = Teams:FindFirstChild("Lobby")

	for _, player in ipairs(Players:GetPlayers()) do
		if lobbyTeam then
			player.Team = lobbyTeam
		end
		task.spawn(function()
			player:LoadCharacterAsync()
		end)
	end
end

local function StartRoundLoop()
	while true do
		-- 1. Intermission Phase
		statusValue.Value = "Intermission"
		for i = INTERMISSION_TIME, 1, -1 do
			timerValue.Value = i
			task.wait(1)
		end

		-- 2. Map Generation & Reset Phase
		statusValue.Value = "Generating"
		timerValue.Value = 0
		genMapFunction:Invoke(MAP_SIZE)

		-- 3. Active Match Phase
		statusValue.Value = "InRound"
		for i = ROUND_TIME, 1, -1 do
			timerValue.Value = i
			task.wait(1)
		end

		-- 4. Match Ended Phase
		statusValue.Value = "Ended"
		timerValue.Value = 0
		CleanupMatch()
		task.wait(5)
	end
end

task.spawn(StartRoundLoop)