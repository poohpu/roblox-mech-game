local KnifeToolModule = {}
KnifeToolModule.__index = KnifeToolModule

local TweenService = game:GetService("TweenService")

function KnifeToolModule.new(toolInstance)
	local self = setmetatable({}, KnifeToolModule)
	self.Tool = toolInstance
	self.Cooldown = 0.4
	self.Damage = 35
    self.Range = 6
	self.CanSwing = true
	self.IsStabbing = false
	self.ActiveTweens = {}
	return self
end

function KnifeToolModule:SetupJoints(character, cleanC0s)
	if not character then return end

	local upperTorso = character:FindFirstChild("UpperTorso")
	local head = character:FindFirstChild("Head")

	local rightUpperArm = character:FindFirstChild("RightUpperArm")
	local rightLowerArm = character:FindFirstChild("RightLowerArm")

	local leftUpperArm = character:FindFirstChild("LeftUpperArm")
	local leftLowerArm = character:FindFirstChild("LeftLowerArm")

	self.WaistJoint = upperTorso and upperTorso:FindFirstChild("Waist")
	self.NeckJoint = head and head:FindFirstChild("Neck")
	self.RightShoulder = rightUpperArm and rightUpperArm:FindFirstChild("RightShoulder")
	self.RightElbow = rightLowerArm and rightLowerArm:FindFirstChild("RightElbow")
	self.LeftShoulder = leftUpperArm and leftUpperArm:FindFirstChild("LeftShoulder")
	self.LeftElbow = leftLowerArm and leftLowerArm:FindFirstChild("LeftElbow")

	-- Use clean spawn C0s if provided, preventing mid-animation offset accumulation
	if cleanC0s then
		self.BaseWaistC0 = cleanC0s.Waist
		self.BaseNeckC0 = cleanC0s.Neck
		self.BaseRightShoulderC0 = cleanC0s.RightShoulder
		self.BaseRightElbowC0 = cleanC0s.RightElbow
		self.BaseLeftShoulderC0 = cleanC0s.LeftShoulder
		self.BaseLeftElbowC0 = cleanC0s.LeftElbow
	end
end

function KnifeToolModule:ResetJoints()
	if self.WaistJoint and self.BaseWaistC0 then self.WaistJoint.C0 = self.BaseWaistC0 end
	if self.NeckJoint and self.BaseNeckC0 then self.NeckJoint.C0 = self.BaseNeckC0 end

	if self.RightShoulder and self.BaseRightShoulderC0 then self.RightShoulder.C0 = self.BaseRightShoulderC0 end
	if self.RightElbow and self.BaseRightElbowC0 then self.RightElbow.C0 = self.BaseRightElbowC0 end

	if self.LeftShoulder and self.BaseLeftShoulderC0 then self.LeftShoulder.C0 = self.BaseLeftShoulderC0 end
	if self.LeftElbow and self.BaseLeftElbowC0 then self.LeftElbow.C0 = self.BaseLeftElbowC0 end
end

function KnifeToolModule:CancelTweens()
	for _, tween in ipairs(self.ActiveTweens) do
		tween:Cancel()
	end
	table.clear(self.ActiveTweens)
end

function KnifeToolModule:UpdatePosture(cameraPitch)
	if self.IsStabbing then return end
	if not self.WaistJoint or not self.BaseWaistC0 then return end

	-- 1. Hunch spine slightly forward (-10 deg) and add 25% camera pitch
	local waistHunch = math.rad(-10)
	local waistPitch = cameraPitch * 0.25
	self.WaistJoint.C0 = self.BaseWaistC0 * CFrame.Angles(waistHunch + waistPitch, 0, 0)

	-- 2. Tilt neck up/down to keep eyes on camera target
	local neckPitch = cameraPitch * 0.35
	if self.NeckJoint and self.BaseNeckC0 then
		self.NeckJoint.C0 = self.BaseNeckC0 * CFrame.Angles(neckPitch, 0, 0)
	end

	-- 3. Right arm: raise shoulder into ready stance + bend elbow inward (+45 deg)
	local armPitch = (cameraPitch - math.rad(90)) * 0.50
	if self.RightShoulder and self.BaseRightShoulderC0 then
		self.RightShoulder.C0 = self.BaseRightShoulderC0 * CFrame.Angles(armPitch + math.rad(-20), math.rad(-15), 0)
	end
	if self.RightElbow and self.BaseRightElbowC0 then
		self.RightElbow.C0 = self.BaseRightElbowC0 * CFrame.Angles(math.rad(45), 0, 0)
	end

	-- 4. Left arm: off-hand guard stance + bent elbow (+30 deg)
	if self.LeftShoulder and self.BaseLeftShoulderC0 then
		self.LeftShoulder.C0 = self.BaseLeftShoulderC0 * CFrame.Angles(math.rad(15), math.rad(-20), 0)
	end
	if self.LeftElbow and self.BaseLeftElbowC0 then
		self.LeftElbow.C0 = self.BaseLeftElbowC0 * CFrame.Angles(math.rad(30), 0, 0)
	end
end

function KnifeToolModule:AnimateStab(cameraPitch)
	if not self.RightShoulder or not self.BaseRightShoulderC0 then return end
	if not self.WaistJoint or not self.BaseWaistC0 then return end

	self.IsStabbing = true
	self:CancelTweens()

	local windupInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local thrustInfo = TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local recoverInfo = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	-- 1. Windup: Twist waist to the right (-15 deg Y yaw) and pull arm back
	local waistPitch = cameraPitch * 0.25
	local armPitch = cameraPitch * 0.50

	local windupWaist = self.BaseWaistC0 * CFrame.Angles(math.rad(-10) + waistPitch, math.rad(-20), 0)
	local windupArm = self.BaseRightShoulderC0 * CFrame.Angles(math.rad(-120) + armPitch, math.rad(-30), 0)
	local windupElbow = self.BaseRightElbowC0 * CFrame.Angles(math.rad(70), 0, 0)

	local wWaistTween = TweenService:Create(self.WaistJoint, windupInfo, { C0 = windupWaist })
	local wArmTween = TweenService:Create(self.RightShoulder, windupInfo, { C0 = windupArm })
	table.insert(self.ActiveTweens, wWaistTween)
	table.insert(self.ActiveTweens, wArmTween)

	if self.RightElbow and self.BaseRightElbowC0 then
		TweenService:Create(self.RightElbow, windupInfo, { C0 = windupElbow }):Play()
	end

	wWaistTween:Play()
	wArmTween:Play()
	wArmTween.Completed:Wait()

	if not self.IsStabbing then return end

	-- 2. Thrust: Snap waist forward (+10 deg Y yaw) and extend right arm straight forward
	local thrustWaist = self.BaseWaistC0 * CFrame.Angles(waistPitch, math.rad(10), 0)
	local thrustArm = self.BaseRightShoulderC0 * CFrame.Angles(math.rad(10) + armPitch, math.rad(-10), 0)

	-- Straighten elbow for full reach during thrust
	if self.RightElbow and self.BaseRightElbowC0 then
		local tElbowTween = TweenService:Create(self.RightElbow, thrustInfo, { C0 = self.BaseRightElbowC0 })
		table.insert(self.ActiveTweens, tElbowTween)
		tElbowTween:Play()
	end

	local tWaistTween = TweenService:Create(self.WaistJoint, thrustInfo, { C0 = thrustWaist })
	local tArmTween = TweenService:Create(self.RightShoulder, thrustInfo, { C0 = thrustArm })
	table.insert(self.ActiveTweens, tWaistTween)
	table.insert(self.ActiveTweens, tArmTween)

	tWaistTween:Play()
	tArmTween:Play()
	tArmTween.Completed:Wait()

	if not self.IsStabbing then return end

	-- 3. Recover: Return waist smoothly back to baseline
	local readyArmC0 = self.BaseRightShoulderC0 * CFrame.Angles(math.rad(-65) + armPitch, math.rad(-15), 0)
	local readyElbowC0 = self.BaseRightElbowC0 * CFrame.Angles(math.rad(45), 0, 0)
	local targetWaistC0 = self.BaseWaistC0 * CFrame.Angles(math.rad(-10) + waistPitch, 0, 0)

	local rWaistTween = TweenService:Create(self.WaistJoint, recoverInfo, { C0 = targetWaistC0 })
	local rArmTween = TweenService:Create(self.RightShoulder, recoverInfo, { C0 = readyArmC0 })
	table.insert(self.ActiveTweens, rWaistTween)
	table.insert(self.ActiveTweens, rArmTween)

	if self.RightElbow and self.BaseRightElbowC0 then
		local rElbowTween = TweenService:Create(self.RightElbow, recoverInfo, { C0 = readyElbowC0 })
		table.insert(self.ActiveTweens, rElbowTween)
		rElbowTween:Play()
	end

	rWaistTween:Play()
	rArmTween:Play()
	rArmTween.Completed:Wait()

	self.IsStabbing = false
	self:CancelTweens()
end

function KnifeToolModule:OnActivated(player)
	if not self.CanSwing or self.IsStabbing then return end
	self.CanSwing = false

	local character = player.Character
    if not character or not character:FindFirstChild("HumanoidRootPart") then
        self.CanSwing = true
        return
    end

    local camera = workspace.CurrentCamera
	local lookVector = camera.CFrame.LookVector
	local cameraPitch = math.asin(math.clamp(lookVector.Y, -1, 1))

	task.spawn(function()
		task.wait(0.3)
		local origin = character.HumanoidRootPart.Position
		local attackDirection = camera.CFrame.LookVector

		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = {character, self.Tool}
		rayParams.CollisionGroup = "Players"
		local hitResult = workspace:Raycast(origin, attackDirection * self.Range, rayParams)

		if hitResult then
			local knifeHitEvent = game:GetService("ReplicatedStorage"):FindFirstChild("KnifeHit")
			if knifeHitEvent then
				knifeHitEvent:FireServer(hitResult.Instance, hitResult.Position)
			end
		end

		
	end)

	self:AnimateStab(cameraPitch)

	self.CanSwing = true
end

function KnifeToolModule:OnUnequipped()
	self:CancelTweens()

	self.IsStabbing = false
	self.CanSwing = true

	self:ResetJoints()
end

return KnifeToolModule