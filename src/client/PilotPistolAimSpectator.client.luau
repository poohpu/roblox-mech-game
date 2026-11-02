local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Player = Players.LocalPlayer
local pilotAimEvent = ReplicatedStorage:WaitForChild("PilotAim")

local remoteAimCache = {}

local function getRemoteJoints(targetChar)
	if remoteAimCache[targetChar] then
		return remoteAimCache[targetChar]
	end

	local upperTorso = targetChar:FindFirstChild("UpperTorso")
	local rightUpperArm = targetChar:FindFirstChild("RightUpperArm")
	local head = targetChar:FindFirstChild("Head")

	if not upperTorso or not rightUpperArm or not head then return nil end

	local waist = upperTorso:FindFirstChild("Waist")
	local shoulder = rightUpperArm:FindFirstChild("RightShoulder")
	local neck = head:FindFirstChild("Neck")

	if not waist or not shoulder or not neck then return nil end

	local data = {
		Waist = waist,
		Shoulder = shoulder,
		Neck = neck,
		BaseWaistC0 = waist.C0,
		BaseShoulderC0 = shoulder.C0,
		BaseNeckC0 = neck.C0,
	}

	remoteAimCache[targetChar] = data

	-- Clean up cache entry when character respawns or despawns
	targetChar.Destroying:Connect(function()
		remoteAimCache[targetChar] = nil
	end)

	return data
end

pilotAimEvent.OnClientEvent:Connect(function(shooter, pitch)
	-- Ignore our own character (handled locally with zero latency in PreRender)
	if shooter == Player then return end

	local char = shooter.Character
	if not char then return end

	local joints = getRemoteJoints(char)
	if not joints then return end

	-- Distribute rotation using the exact same ratios as local aiming
	local waistPitch = pitch * 0.20
	local neckPitch = pitch * 0.30
	local armPitch = pitch * 0.50

	joints.Waist.C0 = joints.BaseWaistC0 * CFrame.Angles(waistPitch, 0, 0)
	joints.Neck.C0 = joints.BaseNeckC0 * CFrame.Angles(neckPitch, 0, 0)
	joints.Shoulder.C0 = joints.BaseShoulderC0 * CFrame.Angles(armPitch, 0, 0)
end)