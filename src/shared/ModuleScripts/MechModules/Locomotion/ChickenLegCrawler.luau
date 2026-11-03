local ChickenLegCrawler = {}
ChickenLegCrawler.__index = ChickenLegCrawler

local rojoShared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local MechAudio = require(rojoShared.ModuleScripts.MechModules.MechAudio)
local CollectionService = game:GetService("CollectionService")

-- Crawl Parameters
local CRAWL_STRIDE = 3      
local CRAWL_DURATION = 0.5  
local CRAWL_HEIGHT = 2.5    
local MAX_STRETCH = 12      

-- ==========================================================
-- UTILITY FUNCTIONS
-- ==========================================================
local function findMotor(parent, name)
	for _, desc in ipairs(parent:GetDescendants()) do
		if desc:IsA("Motor6D") and desc.Name == name then
			return desc
		end
	end
	return nil
end

local function getJointWorldPosition(motor: Motor6D): Vector3?
	if motor and motor.Part0 then
		return (motor.Part0.CFrame * motor.C0).Position
	end
	return nil
end

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

local locomotionIgnoreList = {}

local function refreshLocomotionIgnore()
	table.clear(locomotionIgnoreList)
	for _, prop in ipairs(CollectionService:GetTagged("EnvironmentIgnore")) do
		table.insert(locomotionIgnoreList, prop)
	end
	raycastParams.FilterDescendantsInstances = locomotionIgnoreList
end

CollectionService:GetInstanceAddedSignal("EnvironmentIgnore"):Connect(refreshLocomotionIgnore)
CollectionService:GetInstanceRemovedSignal("EnvironmentIgnore"):Connect(refreshLocomotionIgnore)
refreshLocomotionIgnore()

local function getSlantedGround(targetPosition, mechModel)
	local rayOrigin = targetPosition + Vector3.new(0, 15, 0)
	local rayDirection = Vector3.new(0, -30, 0)

	-- Check if our current mech model is already in the filter list; if not, add it
	if not table.find(locomotionIgnoreList, mechModel) then
		table.insert(locomotionIgnoreList, mechModel)
		raycastParams.FilterDescendantsInstances = locomotionIgnoreList
	end
	
	local result = workspace:Raycast(rayOrigin, rayDirection, raycastParams)

	if result then
		return result.Position, result.Normal, result.Material
	end
	return targetPosition, Vector3.new(0, 1, 0), Enum.Material.Plastic
end

local function solve3SegmentFABRIK2D(target2D, L1, L2a, L2b, maxIterations)
	maxIterations = maxIterations or 5
	local p0 = Vector3.zero
	local p3 = target2D
	local totalReach = L1 + L2a + L2b
	local targetDist = p3.Magnitude

	if targetDist >= totalReach - 0.05 then
		local dir = p3.Unit
		local p1 = p0 + dir * L1
		local p2 = p1 + dir * L2a
		return p0, p1, p2, p0 + dir * totalReach
	end

	local p1 = Vector3.new(0, -L1 * 0.4, -L1 * 0.9) 
	local p2 = Vector3.new(0, -L1 * 0.4 - L2a * 0.5, (-L1 * 0.9) + L2a * 0.8)

	for _ = 1, maxIterations do
		-- Backward Pass
		p3 = target2D
		p2 = p3 + (p2 - p3).Unit * L2b
		p1 = p2 + (p1 - p2).Unit * L2a
		p0 = p1 + (p0 - p1).Unit * L1

		-- Forward Pass
		p0 = Vector3.zero
		p1 = p0 + (p1 - p0).Unit * L1
		if p1.Z > -0.05 then p1 = Vector3.new(0, p1.Y, -0.05) end

		p2 = p1 + (p2 - p1).Unit * L2a
		if p2.Z < p1.Z + 0.05 then p2 = Vector3.new(0, p2.Y, p1.Z + 0.05) end

		p3 = p2 + (p3 - p2).Unit * L2b
	end

	return p0, p1, p2, p3
end

-- ==========================================================
-- MODULE INITIALIZATION
-- ==========================================================
function ChickenLegCrawler.new(mechModel)
	local self = setmetatable({}, ChickenLegCrawler)

	self.Mech = mechModel
	self.DriveCore = mechModel:WaitForChild("TargetGround", true)
	self.LeftTarget = mechModel:WaitForChild("TargetLeft", true)
	self.RightTarget = mechModel:WaitForChild("TargetRight", true)

	self.LeftLeg = { isStepping = false, alpha = 0, startPos = Vector3.new(), goalPos = Vector3.new() }
	self.RightLeg = { isStepping = false, alpha = 0, startPos = Vector3.new(), goalPos = Vector3.new() }

	-- Motor6D Joint Chain
	self.LeftThigh = findMotor(self.Mech, "LeftThigh")      
	self.LeftKnee  = findMotor(self.Mech, "LeftLegConn")    
	self.LeftCalf  = findMotor(self.Mech, "LeftCalf")       
	self.LeftFoot  = findMotor(self.Mech, "LeftFoot")       

	self.RightThigh = findMotor(self.Mech, "RightThigh")
	self.RightKnee  = findMotor(self.Mech, "RightLegConn")
	self.RightCalf  = findMotor(self.Mech, "RightCalf")
	self.RightFoot  = findMotor(self.Mech, "RightFoot")

	if self.LeftThigh  then self.LeftThighBaseC0  = self.LeftThigh.C0 end
	if self.LeftKnee   then self.LeftKneeBaseC0   = self.LeftKnee.C0 end
	if self.LeftCalf   then self.LeftCalfBaseC0   = self.LeftCalf.C0 end
	if self.LeftFoot   then self.LeftFootBaseC0   = self.LeftFoot.C0 end
	if self.RightThigh then self.RightThighBaseC0 = self.RightThigh.C0 end
	if self.RightKnee  then self.RightKneeBaseC0  = self.RightKnee.C0 end
	if self.RightCalf  then self.RightCalfBaseC0  = self.RightCalf.C0 end
	if self.RightFoot  then self.RightFootBaseC0  = self.RightFoot.C0 end

	self.L1  = 3.67  
	self.L2a = 5.83  
	self.L2b = 5.84  

	if self.LeftThigh and self.LeftKnee and self.LeftCalf and self.LeftFoot then
		local hipJointPos  = getJointWorldPosition(self.LeftThigh)
		local kneeJointPos = getJointWorldPosition(self.LeftKnee)
		local calfJointPos = getJointWorldPosition(self.LeftCalf)
		local footJointPos = getJointWorldPosition(self.LeftFoot)

		if hipJointPos and kneeJointPos and calfJointPos and footJointPos then
			self.L1  = (kneeJointPos - hipJointPos).Magnitude
			self.L2a = (calfJointPos - kneeJointPos).Magnitude
			self.L2b = (footJointPos - calfJointPos).Magnitude
		end
	end

	if self.LeftFoot and self.LeftFoot.Part1 then
		local footHalfHeight = self.LeftFoot.Part1.Size.Y / 2
		local jointLocalY = math.abs(self.LeftFoot.C1.Position.Y)
		self.FootPlantOffset = Vector3.new(0, (footHalfHeight + jointLocalY) - 0.2, 0)
	else
		self.FootPlantOffset = Vector3.new(0, 1.5, 0)
	end

	return self
end

-- ==========================================================
-- UPDATE LOOP
-- ==========================================================
function ChickenLegCrawler:Update(deltaTime, movementVector, hipRotation, isLimping, staggerOffset, isFalling, currentSpeed, isWindingUp)
	if not self.DriveCore then return end

	if self.Mech:GetAttribute("AwaitingStandUp") then return end
	
	local function getLiveMotor(currentMotor, motorName)
		if currentMotor and currentMotor.Parent and currentMotor.Part0 and currentMotor.Part1 then
			return currentMotor
		end
		for _, desc in ipairs(self.Mech:GetDescendants()) do
			if desc:IsA("Motor6D") and desc.Name == motorName then
				if desc.Part0 and desc.Part1 and desc.Part0:GetAttribute("RepairID") and desc.Part1:GetAttribute("RepairID") then
					return desc
				end
			end
		end
		return currentMotor
	end

	self.LeftThigh = getLiveMotor(self.LeftThigh, "LeftThigh")
	self.LeftKnee  = getLiveMotor(self.LeftKnee, "LeftLegConn")
	self.LeftCalf  = getLiveMotor(self.LeftCalf, "LeftCalf")
	self.LeftFoot  = getLiveMotor(self.LeftFoot, "LeftFoot")

	self.RightThigh = getLiveMotor(self.RightThigh, "RightThigh")
	self.RightKnee  = getLiveMotor(self.RightKnee, "RightLegConn")
	self.RightCalf  = getLiveMotor(self.RightCalf, "RightCalf")
	self.RightFoot  = getLiveMotor(self.RightFoot, "RightFoot")
	
	local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
	local walkSpeed = seat and seat:GetAttribute("WalkSpeed") or 6
	local safeSpeed = math.max(0.1, walkSpeed)
	local speedRatio = safeSpeed / 6

	local leftLegDead = seat and seat:GetAttribute("LeftLegDead") or false
	local rightLegDead = seat and seat:GetAttribute("RightLegDead") or false

	staggerOffset = staggerOffset or 0
	isFalling = isFalling or false 

	if isFalling then
		self.LeftLeg.isStepping = false
		self.RightLeg.isStepping = false
		local dangleDrop = Vector3.new(0, -3, 0)
		local hipPos = self.DriveCore.Position
		self.LeftTarget.CFrame = self.LeftTarget.CFrame:Lerp(CFrame.new(hipPos + dangleDrop) * hipRotation, 10 * deltaTime)
		self.RightTarget.CFrame = self.RightTarget.CFrame:Lerp(CFrame.new(hipPos + dangleDrop) * hipRotation, 10 * deltaTime)
		-- We DO NOT return early here because we still need the FABRIK math below to calculate the joint angles!
	else
		local dynamicCrawlStride = CRAWL_STRIDE * speedRatio
		local dynamicCrawlDuration = math.max(0.15, CRAWL_DURATION / speedRatio)
		local dynamicMaxStretch = MAX_STRETCH * speedRatio

		local flatMovement = Vector3.new(movementVector.X, 0, movementVector.Z)
		local isMoving = flatMovement.Magnitude > 0.01
		local moveDir = isMoving and flatMovement.Unit or Vector3.new(0, 0, 0)

		local flatForward = Vector3.new(hipRotation.LookVector.X, 0, hipRotation.LookVector.Z)
		flatForward = flatForward.Magnitude > 0.01 and flatForward.Unit or Vector3.new(0, 0, -1)
		local flatBack = -flatForward

		local flatRight = Vector3.new(hipRotation.RightVector.X, 0, hipRotation.RightVector.Z)
		local rightVector = flatRight.Magnitude > 0.01 and flatRight.Unit or Vector3.new(1, 0, 0)

		local hipPart = self.Mech:FindFirstChild("Hip", true)
		local hipPos = hipPart and hipPart.Position or self.DriveCore.Position

		-- 1. Estimate positions & raycast to ground
		local estimatedLeftCenter = self.DriveCore.Position + (flatBack * -6) + (rightVector * -2.5)
		local estimatedRightCenter = self.DriveCore.Position + (flatBack * -6) + (rightVector * 2.5)

		local trueLeftPos, leftNormal = getSlantedGround(estimatedLeftCenter, self.Mech)
		local trueRightPos, rightNormal = getSlantedGround(estimatedRightCenter, self.Mech)

		local averageGroundY = (trueLeftPos.Y + trueRightPos.Y) / 2
		local flatHipPos = Vector3.new(hipPos.X, averageGroundY, hipPos.Z)

		-- 2. Surface rotation conforming
		local leftSlopeForward = leftNormal:Cross(rightVector).Unit
		local rightSlopeForward = rightNormal:Cross(rightVector).Unit
		local leftPlantRotation = CFrame.lookAt(Vector3.zero, leftSlopeForward, leftNormal)
		local rightPlantRotation = CFrame.lookAt(Vector3.zero, rightSlopeForward, rightNormal)

		local function updateLeg(leg, target, pushStart, plantRotation)
			if leg.isStepping then
				leg.alpha = math.min(1, leg.alpha + (deltaTime / dynamicCrawlDuration))
				local linearPos = leg.startPos:Lerp(leg.goalPos, leg.alpha)
				local verticalLift = Vector3.new(0, math.sin(leg.alpha * math.pi) * CRAWL_HEIGHT, 0)

				target.CFrame = CFrame.new(linearPos + verticalLift) * plantRotation

				if leg.alpha >= 1 then
					local targetName = string.lower(target.Name)
					local isDead = (seat and ((string.find(targetName, "left") and seat:GetAttribute("LeftLegDead")) or (string.find(targetName, "right") and seat:GetAttribute("RightLegDead")))) or false
					if not isDead then
						MechAudio.playFootstep(target.Position, leg.goalMaterial)
					end
					leg.isStepping = false
					target.CFrame = CFrame.new(leg.goalPos) * plantRotation
				end
			else
				local flatTargetPos = Vector3.new(target.Position.X, 0, target.Position.Z)
				local flatPushStart = Vector3.new(pushStart.X, 0, pushStart.Z)
				local flatHipPos2D = Vector3.new(flatHipPos.X, 0, flatHipPos.Z)

				local distFromStart = (flatTargetPos - flatPushStart).Magnitude
				local trueHipDist = (flatTargetPos - flatHipPos2D).Magnitude

				local needsCrawlStep = isMoving and distFromStart > (dynamicCrawlStride + staggerOffset * 0.5)
				local needsIdleRecovery = not isMoving and distFromStart > (2.0 + staggerOffset)

				if needsCrawlStep or needsIdleRecovery then
					local rawGoalPos = (trueHipDist > (dynamicMaxStretch + staggerOffset)) and (pushStart + (moveDir * (6 * speedRatio)))
						or needsCrawlStep and (pushStart + (moveDir * (4 * speedRatio)))
						or pushStart

					local finalGoalPos, _, finalMaterial = getSlantedGround(rawGoalPos, self.Mech)
					if (target.Position - finalGoalPos).Magnitude > 15 then
						target.CFrame = CFrame.new(finalGoalPos) * plantRotation
						leg.goalPos = finalGoalPos
						leg.goalMaterial = finalMaterial
						leg.isStepping = false
					else
						leg.isStepping = true
						leg.alpha = 0
						leg.startPos = target.Position
						leg.goalPos = finalGoalPos
						leg.goalMaterial = finalMaterial
					end
				end
			end
		end

		if not leftLegDead and not self.RightLeg.isStepping then 
			updateLeg(self.LeftLeg, self.LeftTarget, trueLeftPos, leftPlantRotation) 
		end
		if not rightLegDead and not self.LeftLeg.isStepping then 
			updateLeg(self.RightLeg, self.RightTarget, trueRightPos, rightPlantRotation) 
		end
	end

	local flatForward = Vector3.new(hipRotation.LookVector.X, 0, hipRotation.LookVector.Z)
	flatForward = flatForward.Magnitude > 0.01 and flatForward.Unit or Vector3.new(0, 0, -1)
	local flatRight = Vector3.new(hipRotation.RightVector.X, 0, hipRotation.RightVector.Z)
	local rightVector = flatRight.Magnitude > 0.01 and flatRight.Unit or Vector3.new(1, 0, 0)
	local flatUp = rightVector:Cross(flatForward).Unit
	local stableHipRotation = CFrame.lookAt(Vector3.zero, flatForward, flatUp)

	-- ==========================================================
	-- 3. APPLY 2D FABRIK TO FOLLOW TARGETS (NEW FOR CHICKENLEG CRAWLER)
	-- ==========================================================
	if not leftLegDead and self.LeftThigh and self.LeftTarget and self.LeftThighBaseC0 then
		local jointWorldPos = (self.LeftThigh.Part0.CFrame * CFrame.new(self.LeftThighBaseC0.Position)).Position
		local stableHipCFrame = CFrame.new(jointWorldPos) * stableHipRotation

		local adjustedTargetPos = self.LeftTarget.Position + self.FootPlantOffset
		local localTarget = stableHipCFrame:PointToObjectSpace(adjustedTargetPos)

		local target2D = Vector3.new(0, localTarget.Y, localTarget.Z)
		local p0, p1, p2, p3 = solve3SegmentFABRIK2D(target2D, self.L1, self.L2a, self.L2b, 5)

		local thighPitch = math.atan2(-(p1 - p0).Z, -(p1 - p0).Y)
		local kneePitch  = math.atan2(-(p2 - p1).Z, -(p2 - p1).Y) - thighPitch
		local calfPitch  = math.atan2(-(p3 - p2).Z, -(p3 - p2).Y) - (thighPitch + kneePitch)
		local hipRoll    = math.atan2(localTarget.X, -localTarget.Y)

		-- Calculate World CFrames for each segment to isolate them from the Torso's physical tilt
		local thighWorldRot = stableHipCFrame.Rotation * CFrame.Angles(0, 0, hipRoll) * CFrame.Angles(thighPitch, 0, 0)
		local c0Rot = self.LeftThigh.Part0.CFrame.Rotation:Inverse() * thighWorldRot * self.LeftThigh.C1.Rotation
		self.LeftThigh.C0 = CFrame.new(self.LeftThighBaseC0.Position) * c0Rot

		if self.LeftKnee and self.LeftKneeBaseC0 then
			local kneeWorldRot = thighWorldRot * CFrame.Angles(kneePitch, 0, 0)
			local kneeC0Rot = self.LeftKnee.Part0.CFrame.Rotation:Inverse() * kneeWorldRot * self.LeftKnee.C1.Rotation
			self.LeftKnee.C0 = CFrame.new(self.LeftKneeBaseC0.Position) * kneeC0Rot

			if self.LeftCalf and self.LeftCalfBaseC0 then
				local calfWorldRot = kneeWorldRot * CFrame.Angles(calfPitch, 0, 0)
				local calfC0Rot = self.LeftCalf.Part0.CFrame.Rotation:Inverse() * calfWorldRot * self.LeftCalf.C1.Rotation
				self.LeftCalf.C0 = CFrame.new(self.LeftCalfBaseC0.Position) * calfC0Rot
			end
		end

		if self.LeftFoot and self.LeftFootBaseC0 then
			local footTargetRot = self.LeftTarget.CFrame.Rotation
			local footC0Rot = self.LeftFoot.Part0.CFrame.Rotation:Inverse() * footTargetRot * self.LeftFoot.C1.Rotation
			self.LeftFoot.C0 = CFrame.new(self.LeftFootBaseC0.Position) * footC0Rot
		end
	end

	if not rightLegDead and self.RightThigh and self.RightTarget and self.RightThighBaseC0 then
		local jointWorldPos = (self.RightThigh.Part0.CFrame * CFrame.new(self.RightThighBaseC0.Position)).Position
		local stableHipCFrame = CFrame.new(jointWorldPos) * stableHipRotation

		local adjustedTargetPos = self.RightTarget.Position + self.FootPlantOffset
		local localTarget = stableHipCFrame:PointToObjectSpace(adjustedTargetPos)

		local target2D = Vector3.new(0, localTarget.Y, localTarget.Z)
		local p0, p1, p2, p3 = solve3SegmentFABRIK2D(target2D, self.L1, self.L2a, self.L2b, 5)

		local thighPitch = math.atan2(-(p1 - p0).Z, -(p1 - p0).Y)
		local kneePitch  = math.atan2(-(p2 - p1).Z, -(p2 - p1).Y) - thighPitch
		local calfPitch  = math.atan2(-(p3 - p2).Z, -(p3 - p2).Y) - (thighPitch + kneePitch)
		local hipRoll    = math.atan2(localTarget.X, -localTarget.Y)

		local thighWorldRot = stableHipCFrame.Rotation * CFrame.Angles(0, 0, hipRoll) * CFrame.Angles(thighPitch, 0, 0)
		local c0Rot = self.RightThigh.Part0.CFrame.Rotation:Inverse() * thighWorldRot * self.RightThigh.C1.Rotation
		self.RightThigh.C0 = CFrame.new(self.RightThighBaseC0.Position) * c0Rot

		if self.RightKnee and self.RightKneeBaseC0 then
			local kneeWorldRot = thighWorldRot * CFrame.Angles(kneePitch, 0, 0)
			local kneeC0Rot = self.RightKnee.Part0.CFrame.Rotation:Inverse() * kneeWorldRot * self.RightKnee.C1.Rotation
			self.RightKnee.C0 = CFrame.new(self.RightKneeBaseC0.Position) * kneeC0Rot

			if self.RightCalf and self.RightCalfBaseC0 then
				local calfWorldRot = kneeWorldRot * CFrame.Angles(calfPitch, 0, 0)
				local calfC0Rot = self.RightCalf.Part0.CFrame.Rotation:Inverse() * calfWorldRot * self.RightCalf.C1.Rotation
				self.RightCalf.C0 = CFrame.new(self.RightCalfBaseC0.Position) * calfC0Rot
			end
		end

		if self.RightFoot and self.RightFootBaseC0 then
			local footTargetRot = self.RightTarget.CFrame.Rotation
			local footC0Rot = self.RightFoot.Part0.CFrame.Rotation:Inverse() * footTargetRot * self.RightFoot.C1.Rotation
			self.RightFoot.C0 = CFrame.new(self.RightFootBaseC0.Position) * footC0Rot
		end
	end
end

return ChickenLegCrawler