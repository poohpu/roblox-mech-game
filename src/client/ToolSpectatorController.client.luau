local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Player = Players.LocalPlayer
local pilotAimEvent = ReplicatedStorage:WaitForChild("PilotAim")
local knifeStabEvent = ReplicatedStorage:FindFirstChild("KnifeStab")

local remoteAimCache = {}
local activeStabTweens = {}


local function cancelRemoteTweens(joints)
	for _, tween in ipairs(joints.ActiveTweens) do
		tween:Cancel()
	end
	table.clear(joints.ActiveTweens)
end

local function resetRemoteJoints(joints)
	joints.IsStabbing = false
	cancelRemoteTweens(joints)

	if joints.Waist and joints.BaseWaistC0 then joints.Waist.C0 = joints.BaseWaistC0 end
	if joints.Neck and joints.BaseNeckC0 then joints.Neck.C0 = joints.BaseNeckC0 end
	if joints.RightShoulder and joints.BaseRightShoulderC0 then joints.RightShoulder.C0 = joints.BaseRightShoulderC0 end
	if joints.RightElbow and joints.BaseRightElbowC0 then joints.RightElbow.C0 = joints.BaseRightElbowC0 end
	if joints.LeftShoulder and joints.BaseLeftShoulderC0 then joints.LeftShoulder.C0 = joints.BaseLeftShoulderC0 end
	if joints.LeftElbow and joints.BaseLeftElbowC0 then joints.LeftElbow.C0 = joints.BaseLeftElbowC0 end
end

local function getRemoteJoints(targetChar)
	if remoteAimCache[targetChar] then
		return remoteAimCache[targetChar]
	end

	local upperTorso = targetChar:FindFirstChild("UpperTorso")
	local head = targetChar:FindFirstChild("Head")
	local rightUpperArm = targetChar:FindFirstChild("RightUpperArm")
	local rightLowerArm = targetChar:FindFirstChild("RightLowerArm")
	local leftUpperArm = targetChar:FindFirstChild("LeftUpperArm")
	local leftLowerArm = targetChar:FindFirstChild("LeftLowerArm")

	if not upperTorso or not head or not rightUpperArm then return nil end

	local waist = upperTorso:FindFirstChild("Waist")
	local neck = head:FindFirstChild("Neck")
	local rightShoulder = rightUpperArm:FindFirstChild("RightShoulder")
	local rightElbow = rightLowerArm and rightLowerArm:FindFirstChild("RightElbow")
	local leftShoulder = leftUpperArm and leftUpperArm:FindFirstChild("LeftShoulder")
	local leftElbow = leftLowerArm and leftLowerArm:FindFirstChild("LeftElbow")

	if not waist or not neck or not rightShoulder then return nil end

	local data = {
		Waist = waist,
		Neck = neck,
		RightShoulder = rightShoulder,
		RightElbow = rightElbow,
		LeftShoulder = leftShoulder,
		LeftElbow = leftElbow,

		BaseWaistC0 = waist.C0,
		BaseNeckC0 = neck.C0,
		BaseRightShoulderC0 = rightShoulder.C0,
		BaseRightElbowC0 = rightElbow and rightElbow.C0,
		BaseLeftShoulderC0 = leftShoulder and leftShoulder.C0,
		BaseLeftElbowC0 = leftElbow and leftElbow.C0,

		IsStabbing = false,
		ActiveTweens = {},
	}

	remoteAimCache[targetChar] = data

	targetChar.Destroying:Connect(function()
		remoteAimCache[targetChar] = nil
		activeStabTweens[targetChar] = nil
	end)

	-- Reset spectator joints immediately when the tool leaves the character model
	targetChar.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then
			resetRemoteJoints(data)
		end
	end)

	return data
end

pilotAimEvent.OnClientEvent:Connect(function(shooter, pitch)
	if shooter == Player then return end

	local char = shooter.Character
	if not char then return end

	local joints = getRemoteJoints(char)
	if not joints or joints.IsStabbing then return end

	local tool = char:FindFirstChildOfClass("Tool")

	-- Reset immediately if tool is gone, unmanaged, or unequip pitch 0 was received
	if not tool or (tool.Name ~= "Knife" and tool.Name ~= "Pistol") or pitch == 0 then
		resetRemoteJoints(joints)
		return
	end

	if joints.IsStabbing then return end

	if tool.Name == "Knife" then
		-- Knife posture
		local waistHunch = math.rad(-10)
		local waistPitch = pitch * 0.25
		joints.Waist.C0 = joints.BaseWaistC0 * CFrame.Angles(waistHunch + waistPitch, 0, 0)

		local neckPitch = pitch * 0.35
		joints.Neck.C0 = joints.BaseNeckC0 * CFrame.Angles(neckPitch, 0, 0)

		local armPitch = (pitch - math.rad(90)) * 0.50
		joints.RightShoulder.C0 = joints.BaseRightShoulderC0 * CFrame.Angles(armPitch + math.rad(-20), math.rad(-15), 0)

		if joints.RightElbow and joints.BaseRightElbowC0 then
			joints.RightElbow.C0 = joints.BaseRightElbowC0 * CFrame.Angles(math.rad(45), 0, 0)
		end
		if joints.LeftShoulder and joints.BaseLeftShoulderC0 then
			joints.LeftShoulder.C0 = joints.BaseLeftShoulderC0 * CFrame.Angles(math.rad(15), math.rad(-20), 0)
		end
		if joints.LeftElbow and joints.BaseLeftElbowC0 then
			joints.LeftElbow.C0 = joints.BaseLeftElbowC0 * CFrame.Angles(math.rad(30), 0, 0)
		end

	elseif tool.Name == "Pistol" then
		-- Pistol posture
		joints.Waist.C0 = joints.BaseWaistC0 * CFrame.Angles(pitch * 0.20, 0, 0)
		joints.Neck.C0 = joints.BaseNeckC0 * CFrame.Angles(pitch * 0.30, 0, 0)
		joints.RightShoulder.C0 = joints.BaseRightShoulderC0 * CFrame.Angles(pitch * 0.50, 0, 0)

		-- Reset non-pistol joints to baseline
		if joints.RightElbow and joints.BaseRightElbowC0 then joints.RightElbow.C0 = joints.BaseRightElbowC0 end
		if joints.LeftShoulder and joints.BaseLeftShoulderC0 then joints.LeftShoulder.C0 = joints.BaseLeftShoulderC0 end
		if joints.LeftElbow and joints.BaseLeftElbowC0 then joints.LeftElbow.C0 = joints.BaseLeftElbowC0 end
	end
end)

-- Replicate knife stab animation on remote characters
knifeStabEvent.OnClientEvent:Connect(function(shooter, pitch)
	if shooter == Player then return end

	local char = shooter.Character
	if not char then return end

	local joints = getRemoteJoints(char)
	if not joints then return end

	cancelRemoteTweens(joints)
	joints.IsStabbing = true

	task.spawn(function()
		local windupInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local thrustInfo = TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local recoverInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

		local waistPitch = pitch * 0.25
		local armPitch = pitch * 0.50

		-- 1. Windup
		local windupWaist = joints.BaseWaistC0 * CFrame.Angles(math.rad(-10) + waistPitch, math.rad(-20), 0)
		local windupArm = joints.BaseRightShoulderC0 * CFrame.Angles(math.rad(-120) + armPitch, math.rad(-30), 0)

		local wWaist = TweenService:Create(joints.Waist, windupInfo, { C0 = windupWaist })
		local wArm = TweenService:Create(joints.RightShoulder, windupInfo, { C0 = windupArm })
		table.insert(joints.ActiveTweens, wWaist)
		table.insert(joints.ActiveTweens, wArm)

		if joints.RightElbow and joints.BaseRightElbowC0 then
			local wElbow = TweenService:Create(joints.RightElbow, windupInfo, { C0 = joints.BaseRightElbowC0 * CFrame.Angles(math.rad(70), 0, 0) })
			table.insert(joints.ActiveTweens, wElbow)
			wElbow:Play()
		end

		wWaist:Play()
		wArm:Play()
		wArm.Completed:Wait()

		if not joints.IsStabbing then return end

		-- 2. Thrust
		local thrustWaist = joints.BaseWaistC0 * CFrame.Angles(waistPitch, math.rad(10), 0)
		local thrustArm = joints.BaseRightShoulderC0 * CFrame.Angles(math.rad(10) + armPitch, math.rad(-10), 0)

		local tWaist = TweenService:Create(joints.Waist, thrustInfo, { C0 = thrustWaist })
		local tArm = TweenService:Create(joints.RightShoulder, thrustInfo, { C0 = thrustArm })
		table.insert(joints.ActiveTweens, tWaist)
		table.insert(joints.ActiveTweens, tArm)

		if joints.RightElbow and joints.BaseRightElbowC0 then
			local tElbow = TweenService:Create(joints.RightElbow, thrustInfo, { C0 = joints.BaseRightElbowC0 })
			table.insert(joints.ActiveTweens, tElbow)
			tElbow:Play()
		end

		tWaist:Play()
		tArm:Play()
		tArm.Completed:Wait()

		if not joints.IsStabbing then return end

		-- 3. Recover
		local readyArmC0 = joints.BaseRightShoulderC0 * CFrame.Angles(math.rad(-65) + armPitch, math.rad(-15), 0)
		local targetWaistC0 = joints.BaseWaistC0 * CFrame.Angles(math.rad(-10) + waistPitch, 0, 0)

		local rWaist = TweenService:Create(joints.Waist, recoverInfo, { C0 = targetWaistC0 })
		local rArm = TweenService:Create(joints.RightShoulder, recoverInfo, { C0 = readyArmC0 })
		table.insert(joints.ActiveTweens, rWaist)
		table.insert(joints.ActiveTweens, rArm)

		if joints.RightElbow and joints.BaseRightElbowC0 then
			local rElbow = TweenService:Create(joints.RightElbow, recoverInfo, { C0 = joints.BaseRightElbowC0 * CFrame.Angles(math.rad(45), 0, 0) })
			table.insert(joints.ActiveTweens, rElbow)
			rElbow:Play()
		end

		rWaist:Play()
		rArm:Play()
		rArm.Completed:Wait()

		joints.IsStabbing = false
		cancelRemoteTweens(joints)
	end)
end)