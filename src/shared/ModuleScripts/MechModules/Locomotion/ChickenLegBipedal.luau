local ChickenLegBipedal = {}
ChickenLegBipedal.__index = ChickenLegBipedal

local MechAudio = require(game:GetService("ReplicatedStorage").ModuleScripts.MechModules.MechAudio)
local CollectionService = game:GetService("CollectionService")

-- Movement & Step Parameters
local STRIDE_LIMIT = 4
local STEP_DURATION = 0.6
local STEP_HEIGHT = 2.5
local VELOCITY_LEAD = 2
local IDLE_TOLERANCE = 6
local TURN_TOLERANCE = math.rad(60)

local WINDUP_CROUCH_ANGLE_DEG = -25 
local WINDUP_CROUCH_OFFSET = math.rad(WINDUP_CROUCH_ANGLE_DEG)

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

local function getYawDifference(cframeA, cframeB)
	local flatA = Vector3.new(cframeA.LookVector.X, 0, cframeA.LookVector.Z).Unit
	local flatB = Vector3.new(cframeB.LookVector.X, 0, cframeB.LookVector.Z).Unit
	local dotProduct = math.clamp(flatA:Dot(flatB), -1, 1)
	return math.acos(dotProduct)
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

local function getGroundPosition(targetWorldCFrame, mechModel)
	local rayOrigin = targetWorldCFrame.Position + Vector3.new(0, 15, 0)
	local rayDirection = Vector3.new(0, -35, 0)

	-- Check if our current mech model is already in the filter list; if not, add it
	if not table.find(locomotionIgnoreList, mechModel) then
		table.insert(locomotionIgnoreList, mechModel)
		raycastParams.FilterDescendantsInstances = locomotionIgnoreList
	end

	local result = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
	if result then
		return result.Position, result.Material
	end
	return targetWorldCFrame.Position, Enum.Material.Plastic
end
local function solve3SegmentFABRIK2D(target2D, L1, L2a, L2b, maxIterations)
	maxIterations = maxIterations or 5

	local p0 = Vector3.zero
	local p3 = target2D

	local totalReach = L1 + L2a + L2b
	local targetDist = p3.Magnitude

	-- Prevent math breakdown if target is beyond max leg reach
	if targetDist >= totalReach - 0.05 then
		local dir = p3.Unit
		local p1 = p0 + dir * L1
		local p2 = p1 + dir * L2a
		return p0, p1, p2, p0 + dir * totalReach
	end

	---- OPTION A: DEEP MECH CROUCH (Aggressive Z-shape at rest)
	-- Increases Z offsets to force the joints further forward and backward
	--local p1 = Vector3.new(0, -L1 * 0.5, -L1 * 0.5)        -- Knee pushed far forward
	--local p2 = Vector3.new(0, -(L1 + L2a) * 0.5, L2a * 0.4)   -- Calf pushed far backward

	-- OPTION B: UPRIGHT / TALL STANCE (Straighter legs at rest)
	-- Decreases Z offsets so joints stay closer to the central vertical axis
	--local p1 = Vector3.new(0, -L1 * 0.85, -L1 * 0.15)      -- Knee slightly forward
	--local p2 = Vector3.new(0, -(L1 + L2a) * 0.85, L2a * 0.1)  -- Calf slightly backward
	-- Initial 2D digitigrade pose setup (Z-shape)
	local p1 = Vector3.new(0, -L1 * 0.8, -L1 * 0.2)
	local p2 = Vector3.new(0, -(L1 + L2a) * 0.6, L2a * 0.3)

	-- ADJUSTABLE CONSTRAINTS (Change these to alter posture!)
	-- Increase MIN_KNEE_FORWARD (e.g., -1.5 or -2.0) to force a deeper knee crouch
	-- Decrease MIN_KNEE_FORWARD (e.g., -0.1) for a straighter, standing pose
	local MIN_KNEE_FORWARD = -1.2

	-- FABRIK Iteration Loop
	for _ = 1, maxIterations do
		-- 1. Backward Pass (Ankle -> Hip)
		p3 = target2D
		p2 = p3 + (p2 - p3).Unit * L2b
		p1 = p2 + (p1 - p2).Unit * L2a
		p0 = p1 + (p0 - p1).Unit * L1

		-- 2. Forward Pass (Hip -> Ankle)
		p0 = Vector3.zero
		p1 = p0 + (p1 - p0).Unit * L1

		-- Enforce Forward Knee Constraint (-Z)
		if p1.Z > -0.05 then
			p1 = Vector3.new(0, p1.Y, -0.05)
		end

		p2 = p1 + (p2 - p1).Unit * L2a

		-- Enforce Backward Calf Constraint (+Z relative to knee)
		if p2.Z < p1.Z + 0.05 then
			p2 = Vector3.new(0, p2.Y, p1.Z + 0.05)
		end

		p3 = p2 + (p3 - p2).Unit * L2b
	end

	return p0, p1, p2, p3
end

-- ==========================================================
-- MODULE INITIALIZATION
-- ==========================================================
function ChickenLegBipedal.new(mechModel)
	local self = setmetatable({}, ChickenLegBipedal)

	self.Mech = mechModel
	self.Seat = mechModel:WaitForChild("VehicleSeat", true)
	self.DriveCore = mechModel:WaitForChild("TargetGround", true)

	self.LeftTarget = mechModel:WaitForChild("TargetLeft", true)
	self.RightTarget = mechModel:WaitForChild("TargetRight", true)

	self.LeftHome = self.DriveCore:WaitForChild("LeftHome", true)
	self.RightHome = self.DriveCore:WaitForChild("RightHome", true)

	-- Motor6D Joint Chain
	self.LeftThigh = findMotor(self.Mech, "LeftThigh")     -- Hip
	self.LeftKnee  = findMotor(self.Mech, "LeftLegConn")   -- Upper Knee
	self.LeftCalf  = findMotor(self.Mech, "LeftCalf")      -- Lower Knee
	self.LeftFoot  = findMotor(self.Mech, "LeftFoot")      -- Ankle

	self.RightThigh = findMotor(self.Mech, "RightThigh")
	self.RightKnee  = findMotor(self.Mech, "RightLegConn")
	self.RightCalf  = findMotor(self.Mech, "RightCalf")
	self.RightFoot  = findMotor(self.Mech, "RightFoot")

	-- Base C0 Positions
	if self.LeftThigh  then self.LeftThighBaseC0  = self.LeftThigh.C0 end
	if self.LeftKnee   then self.LeftKneeBaseC0   = self.LeftKnee.C0 end
	if self.LeftCalf   then self.LeftCalfBaseC0   = self.LeftCalf.C0 end
	if self.LeftFoot   then self.LeftFootBaseC0   = self.LeftFoot.C0 end

	if self.RightThigh then self.RightThighBaseC0 = self.RightThigh.C0 end
	if self.RightKnee  then self.RightKneeBaseC0  = self.RightKnee.C0 end
	if self.RightCalf  then self.RightCalfBaseC0  = self.RightCalf.C0 end
	if self.RightFoot  then self.RightFootBaseC0  = self.RightFoot.C0 end

	self.LeftLeg = {isStepping = false, alpha = 0, startPos = self.LeftTarget.Position, goalPos = self.LeftTarget.Position}
	self.RightLeg = {isStepping = false, alpha = 0, startPos = self.RightTarget.Position, goalPos = self.RightTarget.Position}

	-- Default Limb Segment Lengths
	self.L1  = 3.67  -- Thigh
	self.L2a = 5.83  -- Knee Link
	self.L2b = 5.84  -- Calf Link

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

	-- Ankle to Sole Plant Offset
	if self.LeftFoot and self.LeftFoot.Part1 then
		local footPart = self.LeftFoot.Part1
		local footHalfHeight = footPart.Size.Y / 2
		local jointLocalY = math.abs(self.LeftFoot.C1.Position.Y)
		self.FootPlantOffset = Vector3.new(0, footHalfHeight + jointLocalY, 0)
	else
		self.FootPlantOffset = Vector3.new(0, 1.5, 0)
	end

	return self
end

-- ==========================================================
-- UPDATE LOOP
-- ==========================================================
function ChickenLegBipedal:Update(deltaTime, movementVector, hipRotation, isLimping, staggerOffset, isFalling, currentSpeed, isWindingUp)
	if not self.DriveCore then return end

	if self.Mech:GetAttribute("AwaitingStandUp") then return end
	
	local function getLiveMotor(currentMotor, motorName)
		-- FAST CHECK: If the joint is healthy, short-circuit instantly (Zero performance cost)
		if currentMotor and currentMotor.Parent and currentMotor.Part0 and currentMotor.Part1 then
			return currentMotor
		end

		-- RECOVERY: Only runs ONCE when the joint is actively broken
		for _, desc in ipairs(self.Mech:GetDescendants()) do
			if desc:IsA("Motor6D") and desc.Name == motorName then
				-- CRITICAL: Ignore dead joints inside severed limbs! 
				-- We only adopt this motor if BOTH connected parts have active RepairIDs
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
	
	
	if not self.LeftThigh or not self.RightThigh then return end
	
	local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
	local walkSpeed = currentSpeed or (seat and seat:GetAttribute("WalkSpeed")) or 15
	local speedRatio = walkSpeed / 15
	local dynamicStepDuration = math.max(0.15, STEP_DURATION / speedRatio)
	local distanceScale = math.sqrt(walkSpeed / 15)
	local dynamicStrideLimit = STRIDE_LIMIT * distanceScale
	local dynamicVelocityLead = VELOCITY_LEAD * distanceScale
	local distanceTraveledDuringStep = walkSpeed * dynamicStepDuration
	local dynamicOvershoot = dynamicStrideLimit + (distanceTraveledDuringStep * 0.8)

	local flatMovement = Vector3.new(movementVector.X, 0, movementVector.Z)
	local isMoving = flatMovement.Magnitude > 0.01
	local moveDirection = isMoving and flatMovement.Unit or Vector3.new(0, 0, 0)

	if isFalling then
		self.LeftLeg.isStepping = false
		self.RightLeg.isStepping = false
		local dangleDrop = Vector3.new(0, -3, 0)
		self.LeftTarget.CFrame = self.LeftTarget.CFrame:Lerp(CFrame.new(self.LeftHome.WorldPosition + dangleDrop) * hipRotation, 10 * deltaTime)
		self.RightTarget.CFrame = self.RightTarget.CFrame:Lerp(CFrame.new(self.RightHome.WorldPosition + dangleDrop) * hipRotation, 10 * deltaTime)
	end

	local activeStrideLimit = dynamicStrideLimit + (staggerOffset or 0) * 0.5
	local activeStepDuration = isLimping and (dynamicStepDuration * 2.0) or dynamicStepDuration
	local activeOvershoot = isLimping and (dynamicOvershoot * 1.5) or dynamicOvershoot

	if isWindingUp then
		self.windupCompression = math.min(2.0, (self.windupCompression or 0) + (12 * deltaTime))
	else
		self.windupCompression = math.max(0, (self.windupCompression or 0) - (12 * deltaTime))
	end

	local windupAlpha = (self.windupCompression or 0) / 2.0
	local windupPitch = WINDUP_CROUCH_OFFSET * windupAlpha
	local crouchOffset = Vector3.new(0, self.windupCompression, 0)

	local currentLeftHome = self.LeftHome.WorldPosition + (moveDirection * dynamicVelocityLead) + crouchOffset
	local currentRightHome = self.RightHome.WorldPosition + (moveDirection * dynamicVelocityLead) + crouchOffset

	-- LEFT LEG STEP ARC
	if self.LeftLeg.isStepping then
		self.LeftLeg.alpha = math.min(1, self.LeftLeg.alpha + (deltaTime / activeStepDuration))
		local linearPos = self.LeftLeg.startPos:Lerp(self.LeftLeg.goalPos, self.LeftLeg.alpha)
		local verticalLift = Vector3.new(0, math.sin(self.LeftLeg.alpha * math.pi) * STEP_HEIGHT, 0)
		self.LeftTarget.CFrame = CFrame.new(linearPos + verticalLift) * hipRotation

		if self.LeftLeg.alpha >= 1 then
			self.LeftLeg.isStepping = false
			local seatRef = self.Seat or self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
			if not (seatRef and seatRef:GetAttribute("LeftLegDead")) then
				MechAudio.playFootstep(self.LeftTarget.Position, self.LeftLeg.goalMaterial)
			end
		end
	elseif not self.RightLeg.isStepping and not isWindingUp then
		local leftFootTwist = getYawDifference(hipRotation, self.LeftTarget.CFrame)
		local needsWalkingStep = isMoving and ((self.LeftTarget.Position - currentLeftHome).Magnitude > activeStrideLimit or leftFootTwist > TURN_TOLERANCE)
		local needsIdleRecovery = not isMoving and ((self.LeftTarget.Position - self.LeftHome.WorldPosition).Magnitude > IDLE_TOLERANCE or leftFootTwist > TURN_TOLERANCE)

		if needsWalkingStep or needsIdleRecovery then
			self.LeftLeg.isStepping = true
			self.LeftLeg.alpha = 0
			self.LeftLeg.startPos = self.LeftTarget.Position
			local velocityOffset = needsWalkingStep and (moveDirection * activeOvershoot) or Vector3.zero
			self.LeftLeg.goalPos, self.LeftLeg.goalMaterial = getGroundPosition(self.LeftHome.WorldCFrame + velocityOffset, self.Mech)
		end
	end

	-- RIGHT LEG STEP ARC
	if self.RightLeg.isStepping then
		self.RightLeg.alpha = math.min(1, self.RightLeg.alpha + (deltaTime / activeStepDuration))
		local linearPos = self.RightLeg.startPos:Lerp(self.RightLeg.goalPos, self.RightLeg.alpha)
		local verticalLift = Vector3.new(0, math.sin(self.RightLeg.alpha * math.pi) * STEP_HEIGHT, 0)
		self.RightTarget.CFrame = CFrame.new(linearPos + verticalLift) * hipRotation

		if self.RightLeg.alpha >= 1 then 
			self.RightLeg.isStepping = false 
			local seatRef = self.Seat or self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
			if not (seatRef and seatRef:GetAttribute("RightLegDead")) then
				MechAudio.playFootstep(self.RightTarget.Position, self.RightLeg.goalMaterial)
			end
		end
	elseif not self.LeftLeg.isStepping and not isWindingUp then
		local rightFootTwist = getYawDifference(hipRotation, self.RightTarget.CFrame)
		local needsWalkingStep = isMoving and ((self.RightTarget.Position - currentRightHome).Magnitude > activeStrideLimit or rightFootTwist > TURN_TOLERANCE)
		local needsIdleRecovery = not isMoving and ((self.RightTarget.Position - self.RightHome.WorldPosition).Magnitude > IDLE_TOLERANCE or rightFootTwist > TURN_TOLERANCE)

		if needsWalkingStep or needsIdleRecovery then
			self.RightLeg.isStepping = true
			self.RightLeg.alpha = 0
			self.RightLeg.startPos = self.RightTarget.Position
			local velocityOffset = needsWalkingStep and (moveDirection * activeOvershoot) or Vector3.zero
			self.RightLeg.goalPos, self.RightLeg.goalMaterial = getGroundPosition(self.RightHome.WorldCFrame + velocityOffset, self.Mech)
		end
	end

	-- Piston lift flex during mid-air step swing
	local PISTON_FLEX_ANGLE = math.rad(15)
	local leftPistonFlex = self.LeftLeg.isStepping and (math.sin(self.LeftLeg.alpha * math.pi) * PISTON_FLEX_ANGLE) or 0
	local rightPistonFlex = self.RightLeg.isStepping and (math.sin(self.RightLeg.alpha * math.pi) * PISTON_FLEX_ANGLE) or 0

	local maxLegReach = (self.L1 + self.L2a + self.L2b) - 0.01

	if self.LeftThigh and self.LeftTarget and self.LeftThighBaseC0 then
		local hipCFrame = self.LeftThigh.Part0.CFrame * CFrame.new(self.LeftThighBaseC0.Position)
		local adjustedTargetPos = self.LeftTarget.Position + self.FootPlantOffset
		local localTarget = hipCFrame:PointToObjectSpace(adjustedTargetPos)

		-- 1. Flatten target to 2D Y-Z plane to remove X distortion
		local target2D = Vector3.new(0, localTarget.Y, localTarget.Z)

		if target2D.Magnitude > maxLegReach then
			target2D = target2D.Unit * maxLegReach
		end

		-- 2. Solve 2D joint positions
		local p0, p1, p2, p3 = solve3SegmentFABRIK2D(target2D, self.L1, self.L2a, self.L2b)

		-- 3. Calculate segment direction vectors
		local v1 = (p1 - p0)
		local v2 = (p2 - p1)
		local v3 = (p3 - p2)

		-- 4. Convert vectors to pitch angles
		local theta1 = math.atan2(-v1.Z, -v1.Y)
		local theta2 = math.atan2(-v2.Z, -v2.Y)
		local theta3 = math.atan2(-v3.Z, -v3.Y)

		local thighPitch = theta1
		local kneePitch  = (theta2 - theta1) - leftPistonFlex + windupPitch
		local calfPitch  = (theta3 - theta2) + leftPistonFlex - windupPitch
		local hipRoll    = math.atan2(localTarget.X, -localTarget.Y)

		-- 5. Apply Roll before Pitch
		self.LeftThigh.C0 = CFrame.new(self.LeftThighBaseC0.Position) 
			* CFrame.Angles(0, 0, hipRoll) 
			* CFrame.Angles(thighPitch, 0, 0)

		if self.LeftKnee and self.LeftKneeBaseC0 then
			self.LeftKnee.C0 = CFrame.new(self.LeftKneeBaseC0.Position) * CFrame.Angles(kneePitch, 0, 0)
		end

		if self.LeftCalf and self.LeftCalfBaseC0 then
			self.LeftCalf.C0 = CFrame.new(self.LeftCalfBaseC0.Position) * CFrame.Angles(calfPitch, 0, 0)
		end

		if self.LeftFoot and self.LeftFootBaseC0 then
			local totalLegPitch = thighPitch + kneePitch + calfPitch
			self.LeftFoot.C0 = CFrame.new(self.LeftFootBaseC0.Position) 
				* CFrame.Angles(0, 0, -hipRoll) 
				* CFrame.Angles(-totalLegPitch, 0, 0)
		end
	end

	if self.RightThigh and self.RightTarget and self.RightThighBaseC0 then
		local hipCFrame = self.RightThigh.Part0.CFrame * CFrame.new(self.RightThighBaseC0.Position)
		local adjustedTargetPos = self.RightTarget.Position + self.FootPlantOffset
		local localTarget = hipCFrame:PointToObjectSpace(adjustedTargetPos)

		-- 1. Flatten target to 2D Y-Z plane
		local target2D = Vector3.new(0, localTarget.Y, localTarget.Z)

		if target2D.Magnitude > maxLegReach then
			target2D = target2D.Unit * maxLegReach
		end

		-- 2. Solve 2D joint positions
		local p0, p1, p2, p3 = solve3SegmentFABRIK2D(target2D, self.L1, self.L2a, self.L2b)

		local v1 = (p1 - p0)
		local v2 = (p2 - p1)
		local v3 = (p3 - p2)

		local theta1 = math.atan2(-v1.Z, -v1.Y)
		local theta2 = math.atan2(-v2.Z, -v2.Y)
		local theta3 = math.atan2(-v3.Z, -v3.Y)

		local thighPitch = theta1
		local kneePitch  = (theta2 - theta1) - rightPistonFlex + windupPitch
		local calfPitch  = (theta3 - theta2) + rightPistonFlex - windupPitch
		local hipRoll    = math.atan2(localTarget.X, -localTarget.Y)

		-- 5. Apply Roll before Pitch (Symmetrical with left leg)
		self.RightThigh.C0 = CFrame.new(self.RightThighBaseC0.Position) 
			* CFrame.Angles(0, 0, hipRoll) 
			* CFrame.Angles(thighPitch, 0, 0)

		if self.RightKnee and self.RightKneeBaseC0 then
			self.RightKnee.C0 = CFrame.new(self.RightKneeBaseC0.Position) * CFrame.Angles(kneePitch, 0, 0)
		end

		if self.RightCalf and self.RightCalfBaseC0 then
			self.RightCalf.C0 = CFrame.new(self.RightCalfBaseC0.Position) * CFrame.Angles(calfPitch, 0, 0)
		end

		if self.RightFoot and self.RightFootBaseC0 then
			local totalLegPitch = thighPitch + kneePitch + calfPitch
			self.RightFoot.C0 = CFrame.new(self.RightFootBaseC0.Position) 
				* CFrame.Angles(0, 0, -hipRoll) 
				* CFrame.Angles(-totalLegPitch, 0, 0)
		end
	end
end

return ChickenLegBipedal