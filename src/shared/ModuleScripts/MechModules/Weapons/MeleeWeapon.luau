-- Location: ReplicatedStorage.ModuleScripts.MechModules.Weapons.MeleeWeapon
-- Function: run melee animation from MeleeProfiles

local MeleeWeapon = {}
MeleeWeapon.__index = MeleeWeapon

local activePunchingMechs = {}

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local isServer = RunService:IsServer()

local CombatGuard = require(ReplicatedStorage.ModuleScripts.MechModules.CombatGuard)
local MechAudio = require(ReplicatedStorage.ModuleScripts.MechModules.MechAudio)
local MeleeProfiles = require(ReplicatedStorage.ModuleScripts.MechModules.Weapons.MeleeProfiles)

local meleeSparkEvent = ReplicatedStorage:WaitForChild("MechMeleeSpark")

local function SecureNetworkFire(self, eventName, target, damage, spillover, explosionID)
	if isServer then
		if eventName == "MechStagger" then
			if not CombatGuard.CanAffect(self.Mech, target) then return end
			ReplicatedStorage.MechStagger:FireAllClients(target, damage, spillover)
		end
	else
		if eventName == "MechDamageEvent" then
			local sourceName = (self.WeaponPart and self.WeaponPart.Name) or (self.Hand and self.Hand.Name) or "Fist"
			ReplicatedStorage.MechDamageEvent:FireServer(target, damage, spillover, explosionID, sourceName)
		end
	end
end

local function PlayImpactVisuals(impactPosition, blastDirection, hitNormal)
	if isServer then return end
	MechAudio.playCombatSound("MechPunchHit", impactPosition)

	local masterSpark = ReplicatedStorage:FindFirstChild("ImpactSpark", true)
	if masterSpark then
		local trashFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("TrashPart") or workspace

		local sparkAnchor = Instance.new("Part")
		sparkAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
		sparkAnchor.Transparency = 1
		sparkAnchor.Anchored = true
		sparkAnchor.CanCollide = false
		sparkAnchor.CanQuery = false

		local safeNormal = hitNormal or -blastDirection
		sparkAnchor.Position = impactPosition + (safeNormal * 0.7)
		sparkAnchor.CFrame = CFrame.lookAt(sparkAnchor.Position, sparkAnchor.Position + blastDirection)
		sparkAnchor.Parent = trashFolder

		local newSpark = masterSpark:Clone()
		newSpark.Parent = sparkAnchor
		newSpark:Emit(15)
		game.Debris:AddItem(sparkAnchor, 2)
	end
end

if not isServer then
	meleeSparkEvent.OnClientEvent:Connect(function(impactPos, blastDir, hitNormal)
		PlayImpactVisuals(impactPos, blastDir, hitNormal)
	end)
end

function MeleeWeapon.new(mechModel, slotOrWeaponPart)
	local self = setmetatable({}, MeleeWeapon)

	self.Mech = mechModel
	
	if typeof(slotOrWeaponPart) == "Instance" then
		self.WeaponPart = slotOrWeaponPart
		self.SlotName = slotOrWeaponPart.Name
	else
		self.SlotName = tostring(slotOrWeaponPart)
		self.WeaponPart = mechModel:FindFirstChild(self.SlotName, true)
	end
	
	local profileName = (self.WeaponPart and self.WeaponPart:GetAttribute("MeleeProfile")) or "Fist"
	self.Profile = MeleeProfiles[profileName] or MeleeProfiles.Fist
	
	local function getStat(attrName, fallback)
		if self.WeaponPart and self.WeaponPart:GetAttribute(attrName) ~= nil then
			return self.WeaponPart:GetAttribute(attrName)
		elseif self.Hand and self.Hand:GetAttribute(attrName) ~= nil then
			return self.Hand:GetAttribute(attrName)
		end
		return fallback
	end

	self.WeaponName = (self.WeaponPart and self.WeaponPart:GetAttribute("WeaponName")) or self.Profile.WeaponName
	self.Damage = getStat("Damage", self.Profile.Damage or 50)
	self.Cooldown = getStat("Cooldown", self.Profile.Cooldown or 1.25)
	self.StaggerPower = getStat("StaggerPower", self.Profile.StaggerPower or 1.0)
	
	local prefix = string.find(self.SlotName, "Right") and "Right" or "Left"
	self.SideMult = (prefix == "Right") and -1 or 1
	
	self.Hand = mechModel:FindFirstChild(prefix .. "Hand", true)
	self.HitboxOriginPart = (self.WeaponPart and self.WeaponPart:FindFirstChild("WeaponHitbox")) 
		or (self.WeaponPart and self.WeaponPart:FindFirstChild("WeaponTip")) 
		or self.WeaponPart 
		or self.Hand

	self.ShoulderJoint = mechModel:FindFirstChild(prefix .. "Shoulder", true)
	self.WaistJoint = mechModel:FindFirstChild("Waist", true)
	self.NeckJoint = mechModel:FindFirstChild("Neck", true) or mechModel:FindFirstChild("NeckMotor", true)
	self.ElbowJoint = nil

	local lowerArm = mechModel:FindFirstChild(prefix .. "LowerArm", true)
	if lowerArm then
		for _, obj in pairs(mechModel:GetDescendants()) do
			if obj:IsA("Motor6D") and obj.Part1 == lowerArm then
				self.ElbowJoint = obj
				break
			end
		end
	end
	
	self.OrigShoulderC1 = self.ShoulderJoint and self.ShoulderJoint.C1 or CFrame.new()
	self.OrigWaistC1 = self.WaistJoint and self.WaistJoint.C1 or CFrame.new()
	self.OrigNeckC1 = self.NeckJoint and self.NeckJoint.C1 or CFrame.new()
	self.OrigElbowC1 = self.ElbowJoint and self.ElbowJoint.C1 or CFrame.new()
	
	-- get moving weapon parts
	self.WeaponMotors = {}
	
	-- for chainsaw blades part switching
	self.IdleBlades = {}
	self.ActiveBlades = {}
	
	if self.WeaponPart then
		for _, desc in ipairs(self.WeaponPart:GetDescendants()) do
			for _, desc in ipairs(self.WeaponPart:GetDescendants()) do
				if desc:IsA("Motor6D") and desc.Part1 then
					self.WeaponMotors[desc.Part1.Name] = {
						Motor = desc,
						OrigC1 = desc.C1
					}
				elseif desc:IsA("BasePart") then
					if string.find(desc.Name, "IdleBlade") then
						table.insert(self.IdleBlades, desc)
					elseif string.find(desc.Name, "ActiveBlade") then
						table.insert(self.ActiveBlades, desc)
						desc.Transparency = 1
					end
				end
			end
		end
	end
	
	self.IsReloading = false
	self.LastFireTime = 0
	self.VibrationConnection = nil
	
	return self
end

function MeleeWeapon:SetChainsawVisuals(isActive)
	if isServer then return end
	for _, part in ipairs(self.IdleBlades) do
		part.Transparency = isActive and 1 or 0
	end
	for _, part in ipairs(self.ActiveBlades) do
		part.Transparency = isActive and 0.3 or 1
		for _, effect in ipairs(part:GetChildren()) do
			if effect:IsA("ParticleEmitter") or effect:IsA("Beam") or effect:IsA("Trail") then
				effect.Enabled = isActive
			end
		end
	end
end

-- vibarating function
function MeleeWeapon:SetVibration(magnitude, baseShoulderGoalC1)
	if self.VibrationConnection then
		self.VibrationConnection:Disconnect()
		self.VibrationConnection = nil
	end

	if not magnitude or magnitude <= 0 or isServer then return end

	self.VibrationConnection = RunService.Heartbeat:Connect(function()
		if not self.ShoulderJoint or not self.ShoulderJoint.Parent then
			self.VibrationConnection:Disconnect()
			return
		end
		local shakeX = (math.random() - 0.5) * 2 * magnitude
		local shakeY = (math.random() - 0.5) * 2 * magnitude
		local shakeZ = (math.random() - 0.5) * 2 * magnitude
		self.ShoulderJoint.C1 = baseShoulderGoalC1 * CFrame.new(shakeX, shakeY, shakeZ)
	end)
end

-- hitbox detection 
function MeleeWeapon:RunHitboxWindow(duration, isLocalShooter)
	if not isLocalShooter then return end
	local originPart = self.HitboxOriginPart
	if not originPart then return end

	local punchIgnore = {self.Mech}
	local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
	if seat and seat.Occupant then
		table.insert(punchIgnore, seat.Occupant.Parent)
	end

	local tripwireParams = RaycastParams.new()
	tripwireParams.FilterDescendantsInstances = punchIgnore
	tripwireParams.FilterType = Enum.RaycastFilterType.Exclude
	tripwireParams.CollisionGroup = "Players"
	
	local radius = self.Profile.HitboxRadius or 3
	local multiHitDelay = self.Profile.MultiHitDelay -- if set, then means can be hit rapidly
	local isAreaDamage = self.Profile.IsVolumeHitbox or false
	local lastHitTime = 0
	local hitConfirmed = false
	local lastPos = originPart.Position
	local startTime = os.clock()
	
	local conn
	conn = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if (now - startTime > duration) or hitConfirmed or not originPart or not originPart.Parent then
			conn:Disconnect()
			return
		end
		
		if (not multiHitDelay) or (now - lastHitTime >= multiHitDelay) then
			lastHitTime = now

			-- Hits all parts inside the blade area
			if isAreaDamage then
				local overlapParams = OverlapParams.new()
				overlapParams.FilterDescendantsInstances = punchIgnore
				overlapParams.FilterType = Enum.RaycastFilterType.Exclude
				overlapParams.CollisionGroup = "Players"

				-- 4x3x5 stud box around the blade
				local bladeHitbox = workspace:GetPartBoundsInBox(originPart.CFrame, Vector3.new(3, 3, 5), overlapParams)
				local hitModels = {}

				for _, part in ipairs(bladeHitbox) do
					local model = part:FindFirstAncestorWhichIsA("Model")
					if model and model ~= self.Mech then
						local expID = "Saw_" .. tostring(now) .. "_" .. tostring(math.random(100, 999))
						SecureNetworkFire(self, "MechDamageEvent", part, self.Damage, true, expID)

						local impactPos = part.Position
						local blastDir = originPart.CFrame.LookVector
						PlayImpactVisuals(impactPos, blastDir, -blastDir)
						if not isServer then
							meleeSparkEvent:FireServer(impactPos, blastDir, -blastDir)
						end

						if not hitModels[model] and CollectionService:HasTag(model, "Vehicle") then
							hitModels[model] = true
							SecureNetworkFire(self, "MechStagger", model, self.StaggerPower, originPart.CFrame.LookVector)
						end
					end
				end

				-- Single-target thrust along aim line
			else
				local tripwireParams = RaycastParams.new()
				tripwireParams.FilterDescendantsInstances = punchIgnore
				tripwireParams.FilterType = Enum.RaycastFilterType.Exclude
				tripwireParams.CollisionGroup = "Players"

				local currentPos = originPart.Position
				local travelVector = currentPos - lastPos
				-- If aiming down at a small mech, cast directly toward targetPos
				local castDirection = originPart.CFrame.LookVector
				if self.CurrentTargetPos then
					local toCrosshair = (self.CurrentTargetPos - currentPos)
					if toCrosshair.Magnitude > 0.1 then
						castDirection = toCrosshair.Unit
					end
				end

				-- Cast 5 studs forward/down toward target with an enlarged 3.5 stud radius
				local castVector = castDirection * 5
				local hitResult = workspace:Spherecast(currentPos, 3.5, castVector, tripwireParams)

				if hitResult then
					hitConfirmed = true
					
					local impactPos = hitResult.Position
					local hitNormal = hitResult.Normal
					local blastDir = castDirection

					PlayImpactVisuals(impactPos, blastDir, hitNormal)

					if not isServer then
						meleeSparkEvent:FireServer(impactPos, blastDir, hitNormal)
					end
					
					local expID = "Melee_" .. tostring(now) .. "_" .. tostring(math.random(100, 999))

					-- Pile Bunker deals high damage with spillover = true to break armor into core
					SecureNetworkFire(self, "MechDamageEvent", hitResult.Instance, self.Damage, true, expID)

					local hitModel = hitResult.Instance:FindFirstAncestorWhichIsA("Model")
					if hitModel and CollectionService:HasTag(hitModel, "Vehicle") then
						SecureNetworkFire(self, "MechStagger", hitModel, self.StaggerPower, castDirection)
					end
				end
			end
		end

		lastPos = originPart.Position
	end)
end

function MeleeWeapon:RunPhase(phaseIndex, isLocalShooter)
	local phase = self.Profile and self.Profile.Phases and self.Profile.Phases[phaseIndex]
	
	if not phase then
		if self.SetVibration then self:SetVibration(0) end
		if self.SetChainsawVisuals then
			self:SetChainsawVisuals(false)
		end
		
		activePunchingMechs[self.Mech] = nil
		self.IsReloading = false
		self.Mech:SetAttribute("IsPunching", nil)
		return
	end

	if not self.ShoulderJoint or not self.ShoulderJoint.Parent then
		if self.SetVibration then self:SetVibration(0) end
		activePunchingMechs[self.Mech] = nil
		self.IsReloading = false
		self.Mech:SetAttribute("IsPunching", nil)
		return
	end
	
	local tInfo = TweenInfo.new(
		phase.Duration,
		phase.EasingStyle or Enum.EasingStyle.Quad,
		phase.EasingDirection or Enum.EasingDirection.Out
	)

	local shoulderGoalC1 = self.OrigShoulderC1
	
	if phase.ResetAll then
		if self.WaistJoint then TweenService:Create(self.WaistJoint, tInfo, {C1 = self.OrigWaistC1}):Play() end
		if self.NeckJoint then TweenService:Create(self.NeckJoint, tInfo, {C1 = self.OrigNeckC1}):Play() end
		if self.ShoulderJoint then TweenService:Create(self.ShoulderJoint, tInfo, {C1 = self.OrigShoulderC1}):Play() end
		if self.ElbowJoint then TweenService:Create(self.ElbowJoint, tInfo, {C1 = self.OrigElbowC1}):Play() end
		for _, motorData in pairs(self.WeaponMotors) do
			TweenService:Create(motorData.Motor, tInfo, {C1 = motorData.OrigC1}):Play()
		end
	elseif phase.JointAngles then
		local angles = phase.JointAngles
		if angles.Waist and self.WaistJoint then
			local rot = CFrame.Angles(math.rad(angles.Waist.X), math.rad(angles.Waist.Y * self.SideMult), math.rad(angles.Waist.Z))
			TweenService:Create(self.WaistJoint, tInfo, {C1 = self.OrigWaistC1 * rot}):Play()
		end
		if angles.Neck and self.NeckJoint then
			local rot = CFrame.Angles(math.rad(angles.Neck.X), math.rad(angles.Neck.Y * self.SideMult), math.rad(angles.Neck.Z))
			TweenService:Create(self.NeckJoint, tInfo, {C1 = self.OrigNeckC1 * rot}):Play()
		end
		
		local aimPitch = 0
		if isLocalShooter and self.Mech then
			local root = self.Mech:FindFirstChild("Torso") or self.Mech.PrimaryPart
			if root and self.CurrentTargetPos then
				local toTarget = self.CurrentTargetPos - (self.ShoulderJoint.Part0.Position)
				local flatDist = Vector2.new(toTarget.X, toTarget.Z).Magnitude
				aimPitch = math.atan2(toTarget.Y, flatDist)
				aimPitch = math.clamp(aimPitch, math.rad(-60), math.rad(45)) -- Allow punching down up to 60 deg
			end
		end
		
		if angles.Shoulder and self.ShoulderJoint then
			local rot = CFrame.Angles(
				math.rad(angles.Shoulder.X), 
				math.rad(angles.Shoulder.Y), 
				math.rad(angles.Shoulder.Z * self.SideMult)
			)
			shoulderGoalC1 = self.OrigShoulderC1 * rot
			TweenService:Create(self.ShoulderJoint, tInfo, {C1 = shoulderGoalC1}):Play()
		end
		if angles.Elbow and self.ElbowJoint then
			local rot = CFrame.Angles(math.rad(angles.Elbow.X), math.rad(angles.Elbow.Y), math.rad(angles.Elbow.Z))
			TweenService:Create(self.ElbowJoint, tInfo, {C1 = self.OrigElbowC1 * rot}):Play()
		end
	end
	
	-- move the moving parts
	if phase.PartOffsets then
		for partName, offsetCFrame in pairs(phase.PartOffsets) do
			local motorData = self.WeaponMotors[partName]
			if motorData and motorData.Motor then
				TweenService:Create(motorData.Motor, tInfo, {C1 = motorData.OrigC1 * offsetCFrame}):Play()
			end
		end
	end
	
	if phase.SwapChainsawBlades ~= nil and self.SetChainsawVisuals then
		self:SetChainsawVisuals(phase.SwapChainsawBlades)
	end
	
	if phase.Sound and not isServer then
		MechAudio.playCombatSound(phase.Sound, self.HitboxOriginPart.Position)
	end
	
	if self.SetVibration then
		self:SetVibration(phase.VibrationMagnitude, shoulderGoalC1)
	end
	
	if phase.HitboxActive then
		self:RunHitboxWindow(phase.Duration, isLocalShooter)
	end
	-- wait until phase to end then move to the next one
	task.delay(phase.Duration, function()
		self:RunPhase(phaseIndex + 1, isLocalShooter)
	end)
end

function MeleeWeapon:Fire(targetPosition, ignoreList, isLocalShooter, deltaTime)
	-- Guard against simultaneous attacks from either arm
	if activePunchingMechs[self.Mech] or self.Mech:GetAttribute("IsPunching") then 
		return 0 
	end

	local currentTime = os.clock()

	if isLocalShooter then
		if isServer then
			-- Token Bucket Rate Limit check on server
			local timeSinceLast = currentTime - self.LastFireTime
			self.LastFireTime = currentTime

			self.ServerTimeBank = math.min((self.ServerTimeBank or (self.Cooldown * 2)) + timeSinceLast, self.Cooldown * 3)
			local punchCost = self.Cooldown * 0.75

			if self.ServerTimeBank < punchCost then
				return 0
			end

			self.ServerTimeBank -= self.Cooldown
		else
			if (currentTime - self.LastFireTime) < self.Cooldown or self.IsReloading then 
				return 0 
			end
		end
	end

	if not self.ShoulderJoint or not self.ShoulderJoint.Parent then
		self.IsReloading = false
		return 0
	end

	if not self.Profile or not self.Profile.Phases then
		warn("⚠️ SYSTEM ERROR: MeleeProfile missing on " .. tostring(self.WeaponName))
		return 0
	end

	-- Lock both arms immediately
	activePunchingMechs[self.Mech] = true
	self.LastFireTime = currentTime
	self.IsReloading = true
	self.Mech:SetAttribute("IsPunching", true)

	print("🥊 PUNCH STARTED on slot:", self.SlotName, "| Script:", script.Name)

	-- Emergency unlock timer if a sequence gets interrupted
	local totalDuration = 0
	for _, phase in ipairs(self.Profile.Phases) do
		totalDuration += (phase.Duration or 0.2)
	end
	task.delay(totalDuration + 0.2, function()
		if activePunchingMechs[self.Mech] then
			activePunchingMechs[self.Mech] = nil
			self.IsReloading = false
			self.Mech:SetAttribute("IsPunching", nil)
		end
	end)

	self.CurrentTargetPos = targetPosition
	self:RunPhase(1, isLocalShooter)
	return 1
end

return MeleeWeapon
