-- **Function:** Calculates procedural dragging/crawling animations. Used as a failsafe when a Bipedal mech's leg are destroyed.
local Crawler = {}
Crawler.__index = Crawler 

local MechAudio = require(game:GetService("ReplicatedStorage").ModuleScripts.MechModules.MechAudio)
local CollectionService = game:GetService("CollectionService")

local CRAWL_STRIDE = 3      -- How far the leg stretches behind before resetting
local CRAWL_DURATION = 0.5   -- Slow, struggling heave
local CRAWL_HEIGHT = 3      -- Keeps the knee low to the dirt
local MAX_STRETCH = 12		-- The absolute maximum physical length of the leg!

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
	-- Shoot a ray from 10 studs above the target, aiming 20 studs straight down
	local rayOrigin = targetPosition + Vector3.new(0, 10, 0)
	local rayDirection = Vector3.new(0, -20, 0)

	-- Check if our current mech model is already in the filter list; if not, add it
	if not table.find(locomotionIgnoreList, mechModel) then
		table.insert(locomotionIgnoreList, mechModel)
		raycastParams.FilterDescendantsInstances = locomotionIgnoreList
	end

	local result = workspace:Raycast(rayOrigin, rayDirection, raycastParams)

	if result then
		-- Return BOTH the exact position on the hill, and the angle of the hill (Normal)
		return result.Position, result.Normal, result.Material
	end

	-- Failsafe: If the ray hits nothing (like a cliff edge), just return the original guess
	return targetPosition, Vector3.new(0, 1, 0), Enum.Material.Plastic
end

function Crawler.new(mechModel)
	local self = setmetatable({}, Crawler) 

	self.Mech = mechModel
	self.DriveCore = mechModel:WaitForChild("TargetGround", true)

	self.LeftTarget = mechModel:WaitForChild("TargetLeft", true)
	self.RightTarget = mechModel:WaitForChild("TargetRight", true)

	-- We track the steps just like the Bipedal script!
	self.LeftLeg = { isStepping = false, alpha = 0, startPos = Vector3.new(), goalPos = Vector3.new() }
	self.RightLeg = { isStepping = false, alpha = 0, startPos = Vector3.new(), goalPos = Vector3.new() }

	return self
end

function Crawler:Update(deltaTime, movementVector, hipRotation, isLimping, staggerOffset, isFalling, currentSpeed, isWindingUp)
	local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
	local walkSpeed = seat and seat:GetAttribute("WalkSpeed") or 6

	local safeSpeed = math.max(0.1, walkSpeed)
	local speedRatio = safeSpeed / 6
	
	staggerOffset = staggerOffset or 0
	isFalling = isFalling or false -- Catch the new falling variable!
	
	if isFalling then
		self.LeftLeg.isStepping = false
		self.RightLeg.isStepping = false

		-- Crawler legs are usually shorter/broken, so we only let them dangle 3 studs down
		local dangleDrop = Vector3.new(0, -3, 0)
		local hipPos = self.DriveCore.Position

		-- Drag the IK targets straight under the falling core
		self.LeftTarget.CFrame = self.LeftTarget.CFrame:Lerp(CFrame.new(hipPos + dangleDrop) * hipRotation, 10 * deltaTime)
		self.RightTarget.CFrame = self.RightTarget.CFrame:Lerp(CFrame.new(hipPos + dangleDrop) * hipRotation, 10 * deltaTime)

		return -- Stop the crawling math so they don't try to paddle in the air!
	end
	
	local dynamicCrawlStride = CRAWL_STRIDE * speedRatio
	local dynamicCrawlDuration = math.max(0.15, CRAWL_DURATION / speedRatio) -- Don't let it step instantaneously
	local dynamicMaxStretch = MAX_STRETCH * speedRatio
	
	local flatMovement = Vector3.new(movementVector.X, 0, movementVector.Z)

	local isMoving = flatMovement.Magnitude > 0.01
	local moveDir = isMoving and flatMovement.Unit or Vector3.new(0, 0, 0)
	
	-- Extract the perfectly flat direction the mech is facing, completely ignoring the 75-degree face-plant tilt!
	local flatForward = Vector3.new(hipRotation.LookVector.X, 0, hipRotation.LookVector.Z)
	if flatForward.Magnitude > 0.01 then
		flatForward = flatForward.Unit
	else
		flatForward = Vector3.new(0, 0, -1)
	end
	local flatBack = -flatForward

	local flatRight = Vector3.new(hipRotation.RightVector.X, 0, hipRotation.RightVector.Z)
	local rightVector
	if flatRight.Magnitude > 0.01 then
		rightVector = flatRight.Unit
	else
		rightVector = Vector3.new(1, 0, 0) -- Safe fallback
	end

	local hipPart = self.Mech:FindFirstChild("Hip", true)
	local hipPos = hipPart and hipPart.Position or self.DriveCore.Position

	-- 1. Estimate where the feet SHOULD be horizontally...
	local estimatedLeftCenter = self.DriveCore.Position + (flatBack * -6) + (rightVector * -2.5)
	local estimatedRightCenter = self.DriveCore.Position + (flatBack * -6) + (rightVector * 2.5)

	-- 2. ...and shoot our lasers to find exactly where the physical dirt actually is!
	local trueLeftPos, leftNormal = getSlantedGround(estimatedLeftCenter, self.Mech)
	local trueRightPos, rightNormal = getSlantedGround(estimatedRightCenter, self.Mech)

	local leftPushStart = trueLeftPos
	local rightPushStart = trueRightPos

	-- Average the height of both feet to get a reliable hip stretch calculation
	local averageGroundY = (trueLeftPos.Y + trueRightPos.Y) / 2
	local flatHipPos = Vector3.new(hipPos.X, averageGroundY, hipPos.Z)

	-- 3. To make the foot lie flat against the slanted hill, we use cross products.
	-- Crossing the UP vector (Terrain Normal) with the RIGHT vector gives us a perfect FORWARD vector that hugs the hill!
	local leftSlopeForward = leftNormal:Cross(rightVector).Unit
	local rightSlopeForward = rightNormal:Cross(rightVector).Unit

	local leftPlantRotation = CFrame.lookAt(Vector3.zero, leftSlopeForward, leftNormal)
	local rightPlantRotation = CFrame.lookAt(Vector3.zero, rightSlopeForward, rightNormal)

	-- ==========================================
	-- LEG LOGIC FUNCTION
	-- ==========================================
	-- We updated this to accept `plantRotation` so each foot tilts independently!
	local function updateLeg(leg, target, pushStart, plantRotation, staggerOffset)
		staggerOffset = staggerOffset or 0

		if leg.isStepping then
			-- Moving the knee up to the waist for the next push
			leg.alpha = math.min(1, leg.alpha + (deltaTime / dynamicCrawlDuration))

			local linearPos = leg.startPos:Lerp(leg.goalPos, leg.alpha)
			local verticalLift = Vector3.new(0, math.sin(leg.alpha * math.pi) * CRAWL_HEIGHT, 0)

			-- Use the specific slant rotation for this foot!
			target.CFrame = CFrame.new(linearPos + verticalLift) * plantRotation

			if leg.alpha >= 1 then
				local seat = self.Seat or self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
				local targetName = string.lower(target.Name)
				local isDead = false

				if seat then
					if string.find(targetName, "left") and seat:GetAttribute("LeftLegDead") then
						isDead = true
					elseif string.find(targetName, "right") and seat:GetAttribute("RightLegDead") then
						isDead = true
					end
				end

				if not isDead then
					MechAudio.playFootstep(target.Position, leg.goalMaterial)
				end
				
				-- Conclude the step and lock the foot down
				leg.isStepping = false
				target.CFrame = CFrame.new(leg.goalPos) * plantRotation
			end

		else
			-- The foot is planted on the ground!
			-- Measure the distance horizontally so steep hills don't break the stride limit!
			local flatTargetPos = Vector3.new(target.Position.X, 0, target.Position.Z)
			local flatPushStart = Vector3.new(pushStart.X, 0, pushStart.Z)
			local flatHipPos2D = Vector3.new(flatHipPos.X, 0, flatHipPos.Z)

			local distFromStart = (flatTargetPos - flatPushStart).Magnitude
			local trueHipDist = (flatTargetPos - flatHipPos2D).Magnitude

			local activeCrawlStride = dynamicCrawlStride + (staggerOffset * 0.5)
			local activeIdleTolerance = 2.0 + staggerOffset
			local activeMaxStretch = dynamicMaxStretch + staggerOffset

			local needsCrawlStep = isMoving and distFromStart > activeCrawlStride
			local needsIdleRecovery = not isMoving and distFromStart > activeIdleTolerance
			local isOverstretched = trueHipDist > activeMaxStretch 

			if needsCrawlStep or needsIdleRecovery then
				leg.isStepping = true
				leg.alpha = 0
				leg.startPos = target.Position

				-- 1. Calculate where we *want* to step mathematically (which might be floating or underground)
				local rawGoalPos
				if isOverstretched then
					rawGoalPos = pushStart + (moveDir * (6 * speedRatio))
				elseif needsCrawlStep then
					rawGoalPos = pushStart + (moveDir * (4 * speedRatio))
				else
					rawGoalPos = pushStart
				end

				-- 2. THE FIX: Shoot our laser one more time to snap the footprint exactly onto the slanted dirt!
				local finalGoalPos, _, finalMaterial = getSlantedGround(rawGoalPos, self.Mech)
				leg.goalPos = finalGoalPos
				leg.goalMaterial = finalMaterial
			end
		end
	end

	-- Run the math for both legs! 
	-- (The dead leg will mathematically step, but since the IK is disabled, the player will only see the surviving leg working!)

	-- Alternate the steps slightly so it looks like struggling
	if not self.RightLeg.isStepping then
		updateLeg(self.LeftLeg, self.LeftTarget, leftPushStart, leftPlantRotation)
	end
	if not self.LeftLeg.isStepping then
		updateLeg(self.RightLeg, self.RightTarget, rightPushStart, rightPlantRotation)
	end
end

return Crawler