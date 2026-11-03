-- Function: Calculates procedural walking animations for two-legged mechs. Runs locally so the step is perfectly smooth.
local Bipedal = {}
Bipedal.__index = Bipedal 
local CollectionService = game:GetService("CollectionService")
local rojoShared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local MechAudio = require(rojoShared.ModuleScripts.MechModules.MechAudio)

-- ==========================================
-- 1. TWEAKABLE STEP PARAMETERS 
-- ==========================================
local STRIDE_LIMIT = 4     
local STEP_DURATION = 0.4  
local STEP_HEIGHT = 10       
local STRIDE_OVERSHOOT = 8.5 
local VELOCITY_LEAD = 2
local IDLE_TOLERANCE = 7.5 
local TURN_TOLERANCE = math.rad(60) 

-- ==========================================
-- 2. HELPER FUNCTIONS
-- ==========================================
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
	local rayOrigin = targetWorldCFrame.Position + Vector3.new(0, 10, 0)
	local rayDirection = Vector3.new(0, -20, 0)

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

local function getYawDifference(cframeA, cframeB)
	local flatA = Vector3.new(cframeA.LookVector.X, 0, cframeA.LookVector.Z).Unit
	local flatB = Vector3.new(cframeB.LookVector.X, 0, cframeB.LookVector.Z).Unit
	local dotProduct = math.clamp(flatA:Dot(flatB), -1, 1)
	return math.acos(dotProduct)
end

-- ==========================================
-- 3. THE CONSTRUCTOR (Setup)
-- ==========================================
function Bipedal.new(mechModel)
	local self = setmetatable({}, Bipedal) 

	self.Mech = mechModel
	self.DriveCore = mechModel:WaitForChild("TargetGround", true)

	self.LeftTarget = mechModel:WaitForChild("TargetLeft", true)
	self.RightTarget = mechModel:WaitForChild("TargetRight", true)

	self.LeftHome = self.DriveCore:WaitForChild("LeftHome", true)
	self.RightHome = self.DriveCore:WaitForChild("RightHome", true)
	
	---- Snap the targets perfectly under the hips so they don't start at 0,0,0
	--self.LeftTarget.CFrame = self.LeftHome.WorldCFrame
	--self.RightTarget.CFrame = self.RightHome.WorldCFrame

	-- Initialize the math AT the targets, preventing the origin panic!
	self.LeftLeg = {isStepping = false, alpha = 0, startPos = self.LeftTarget.Position, goalPos = self.LeftTarget.Position} --revert vector3.new(0,0,0) if problem
	self.RightLeg = {isStepping = false, alpha = 0, startPos = self.RightTarget.Position, goalPos = self.RightTarget.Position}

	return self
end

-- ==========================================
-- 4. THE UPDATE LOOP (Your exact math!)
-- ==========================================
function Bipedal:Update(deltaTime, movementVector, hipRotation, isLimping, staggerOffset, isFalling, currentSpeed, isWindingUp)
	-- Grab the dynamic WalkSpeed attribute from the mech's seat or fallback to 15
	local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
	local walkSpeed = currentSpeed or (seat and seat:GetAttribute("WalkSpeed")) or 15
	
	staggerOffset = staggerOffset or 0
	isFalling = isFalling or false -- Failsafe in case it's missing
	
	local speedRatio = walkSpeed / 15
	local dynamicStepDuration = math.max(0.15, STEP_DURATION / speedRatio) -- Clamp at 0.15s so it doesn't teleport
	
	local distanceScale = math.sqrt(walkSpeed / 15)
	
	local dynamicStrideLimit = STRIDE_LIMIT * distanceScale 
	local dynamicVelocityLead = VELOCITY_LEAD * distanceScale
	
	-- Instead of blindly multiplying Overshoot, we calculate exactly how far to throw the foot 
	-- based on the mech's actual speed so it never accidentally breaks its own StrideLimit!
	local distanceTraveledDuringStep = walkSpeed * dynamicStepDuration
	local dynamicOvershoot = dynamicStrideLimit + (distanceTraveledDuringStep * 0.8)
	
	-- Are we currently driving?
	local flatMovement = Vector3.new(movementVector.X, 0, movementVector.Z)
	
	local isMoving = flatMovement.Magnitude > 0.01
	local moveDirection = isMoving and flatMovement.Unit or Vector3.new(0, 0, 0)

	local activeIdleTolerance = IDLE_TOLERANCE + staggerOffset
	local activeTurnTolerance = TURN_TOLERANCE + (staggerOffset * 0.05) -- Tiny slack for rotation

	local activeStrideLimit = dynamicStrideLimit
	if isLimping then activeStrideLimit = activeStrideLimit * 1.8 end
	activeStrideLimit = activeStrideLimit + (staggerOffset * 0.5)
	
	local activeStepDuration = isLimping and (dynamicStepDuration * 2.0) or dynamicStepDuration
	local activeOvershoot = isLimping and (dynamicOvershoot * 1.5) or dynamicOvershoot

	local baseLeftHome = self.LeftHome.WorldPosition
	local baseRightHome = self.RightHome.WorldPosition

	if isFalling then
		-- Cancel any steps that were mid-animation
		self.LeftLeg.isStepping = false
		self.RightLeg.isStepping = false

		-- Target a spot roughly 7 studs straight down from the hips
		local dangleDrop = Vector3.new(0, -7, 0)

		-- Smoothly drag the feet through the air into the dangling pose
		self.LeftTarget.CFrame = self.LeftTarget.CFrame:Lerp(CFrame.new(baseLeftHome + dangleDrop) * hipRotation, 10 * deltaTime)
		self.RightTarget.CFrame = self.RightTarget.CFrame:Lerp(CFrame.new(baseRightHome + dangleDrop) * hipRotation, 10 * deltaTime)

		-- RETURN EARLY! Stop the script here so it doesn't run the normal walking math.
		return 
	end

	-- Get current real-time positions of our resting targets
	local currentLeftHome = self.LeftHome.WorldPosition + (moveDirection * dynamicVelocityLead)
	local currentRightHome = self.RightHome.WorldPosition + (moveDirection * dynamicVelocityLead)

	-------------------------------------------------------
	-- LEFT LEG LOGIC
	-------------------------------------------------------
	if self.LeftLeg.isStepping then
		self.LeftLeg.alpha = math.min(1, self.LeftLeg.alpha + (deltaTime / activeStepDuration))

		local linearPos = self.LeftLeg.startPos:Lerp(self.LeftLeg.goalPos, self.LeftLeg.alpha)
		local verticalLift = Vector3.new(0, math.sin(self.LeftLeg.alpha * math.pi) * STEP_HEIGHT, 0)

		self.LeftTarget.CFrame = CFrame.new(linearPos + verticalLift) * hipRotation

		if self.LeftLeg.alpha >= 1 then
			self.LeftLeg.isStepping = false
			local seat = self.Seat or self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
			if not (seat and seat:GetAttribute("LeftLegDead")) then
				MechAudio.playFootstep(self.LeftTarget.Position, self.LeftLeg.goalMaterial)
			end
		end

	elseif not self.RightLeg.isStepping and not isWindingUp then
		local leftFootTwist = getYawDifference(hipRotation, self.LeftTarget.CFrame)

		local needsWalkingStep = isMoving and ((self.LeftTarget.Position - currentLeftHome).Magnitude > activeStrideLimit or leftFootTwist > TURN_TOLERANCE)
		local needsIdleRecovery = not isMoving and ((self.LeftTarget.Position - baseLeftHome).Magnitude > IDLE_TOLERANCE or leftFootTwist > TURN_TOLERANCE)

		if needsWalkingStep or needsIdleRecovery then
			self.LeftLeg.isStepping = true
			self.LeftLeg.alpha = 0
			self.LeftLeg.startPos = self.LeftTarget.Position

			-- Add this right after LeftLeg startPos is set:
			local leftStrideDist = (self.LeftLeg.goalPos - self.LeftLeg.startPos).Magnitude
			if leftStrideDist > 8 then
				print(string.format("⚠️ [LEFT LEG GIANT STEP] Stride Distance: %.2f studs! (Start Z: %.2f -> Goal Z: %.2f)", 
					leftStrideDist, 
					self.LeftHome.CFrame:PointToObjectSpace(self.LeftLeg.startPos).Z,
					self.LeftHome.CFrame:PointToObjectSpace(self.LeftLeg.goalPos).Z
					))
			end

			if needsWalkingStep then
				local velocityOffset = moveDirection * activeOvershoot
				-- Add the Vector3 to the CFrame safely
				self.LeftLeg.goalPos, self.LeftLeg.goalMaterial = getGroundPosition(self.LeftHome.WorldCFrame + velocityOffset, self.Mech)
			else
				self.LeftLeg.goalPos, self.LeftLeg.goalMaterial = getGroundPosition(self.LeftHome.WorldCFrame, self.Mech)
			end
		end
	end

	-------------------------------------------------------
	-- RIGHT LEG LOGIC
	-------------------------------------------------------
	if self.RightLeg.isStepping then
		self.RightLeg.alpha = math.min(1, self.RightLeg.alpha + (deltaTime / activeStepDuration))

		local linearPos = self.RightLeg.startPos:Lerp(self.RightLeg.goalPos, self.RightLeg.alpha)
		local verticalLift = Vector3.new(0, math.sin(self.RightLeg.alpha * math.pi) * STEP_HEIGHT, 0)

		self.RightTarget.CFrame = CFrame.new(linearPos + verticalLift) * hipRotation

		if self.RightLeg.alpha >= 1 then 
			self.RightLeg.isStepping = false 
			local seat = self.Seat or self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
			if not (seat and seat:GetAttribute("RightLegDead")) then
				MechAudio.playFootstep(self.RightTarget.Position, self.RightLeg.goalMaterial)
			end
		end

	elseif not self.LeftLeg.isStepping and not isWindingUp then
		local rightFootTwist = getYawDifference(hipRotation, self.RightTarget.CFrame)

		local needsWalkingStep = isMoving and ((self.RightTarget.Position - currentRightHome).Magnitude > activeStrideLimit or rightFootTwist > TURN_TOLERANCE)
		local needsIdleRecovery = not isMoving and ((self.RightTarget.Position - baseRightHome).Magnitude > IDLE_TOLERANCE or rightFootTwist > TURN_TOLERANCE)

		if needsWalkingStep or needsIdleRecovery then
			self.RightLeg.isStepping = true
			self.RightLeg.alpha = 0
			self.RightLeg.startPos = self.RightTarget.Position


			-- Add this right after RightLeg startPos is set:
			local rightStrideDist = (self.RightLeg.goalPos - self.RightLeg.startPos).Magnitude
			if rightStrideDist > 8 then
				print(string.format("⚠️ [RIGHT LEG GIANT STEP] Stride Distance: %.2f studs! (Start Z: %.2f -> Goal Z: %.2f)", 
					rightStrideDist, 
					self.RightHome.CFrame:PointToObjectSpace(self.RightLeg.startPos).Z,
					self.RightHome.CFrame:PointToObjectSpace(self.RightLeg.goalPos).Z
					))
			end

			if needsWalkingStep then
				local velocityOffset = moveDirection * activeOvershoot
				self.RightLeg.goalPos, self.RightLeg.goalMaterial = getGroundPosition(self.RightHome.WorldCFrame + velocityOffset, self.Mech)
			else
				self.RightLeg.goalPos, self.RightLeg.goalMaterial = getGroundPosition(self.RightHome.WorldCFrame, self.Mech)
			end
		end
	end
	
	
	
end

return Bipedal