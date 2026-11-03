local Wheeled = {}
Wheeled.__index = Wheeled 

local RunService = game:GetService("RunService")
local rojoShared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local MobileUtil = require(rojoShared.ModuleScripts.MobileUtil)

-- THE CONSTRUCTOR (Runs once when boarding)

function Wheeled.new(mechModel)
	local self = setmetatable({}, Wheeled) 

	self.Mech = mechModel

	-- 1. Cache the Steering Hinges (Front wheels only)
	self.SteerFL = mechModel:FindFirstChild("SteerHinge_FL", true)
	self.SteerFR = mechModel:FindFirstChild("SteerHinge_FR", true)
	if self.SteerFL then print("SteerFL resolved to:", self.SteerFL:GetFullName()) end
	if self.SteerFR then print("SteerFR resolved to:", self.SteerFR:GetFullName()) end

	-- 2. Cache the Drive Motors (All 4 wheels)
	self.DriveFL = mechModel:FindFirstChild("DriveHinge_FL", true)
	self.DriveFR = mechModel:FindFirstChild("DriveHinge_FR", true)
	self.DriveBL = mechModel:FindFirstChild("DriveHinge_BL", true)
	self.DriveBR = mechModel:FindFirstChild("DriveHinge_BR", true)

	-- Quick diagnostic to ensure we spelled everything right in the model!
	if not self.SteerFL or not self.DriveBL then
		warn("Wheeled Locomotion: Missing some constraints! Check your spelling.")
	else
		print("Wheeled Cartridge plugged in and constraints cached!")
	end
	
	local STEER_TORQUE = 5000000000 -- Adjust this higher if the tank body is incredibly massive
	local STEER_SPEED = 20       -- Controls how snappy the steering feels 

	if self.SteerFL then
		self.SteerFL.ServoMaxTorque = STEER_TORQUE
		self.SteerFL.AngularSpeed = STEER_SPEED
		self.SteerFL.AngularResponsiveness = 200
	end

	if self.SteerFR then
		self.SteerFR.ServoMaxTorque = STEER_TORQUE
		self.SteerFR.AngularSpeed = STEER_SPEED
		self.SteerFR.AngularResponsiveness = 200
	end
	
	-- 3. Configure the Drive Motors (The Engine)
	local DRIVE_TORQUE = 5000000000 -- Massive torque to overcome the chassis weight and tire friction!

	-- Group all 4 wheels into a table so we don't have to write the same code 4 times
	local driveHinges = {self.DriveFL, self.DriveFR, self.DriveBL, self.DriveBR}

	for _, hinge in ipairs(driveHinges) do
		if hinge then
			-- Switch the hinge from passive/servo mode into continuous spinning mode
			hinge.ActuatorType = Enum.ActuatorType.Motor

			-- Apply the raw pushing power
			hinge.MotorMaxTorque = DRIVE_TORQUE

			-- Default it to perfectly still when the mech spawns
			hinge.AngularVelocity = 0
		end
	end
	
	-- Parameters: Density, Friction, Elasticity, FrictionWeight, ElasticityWeight
	local stickyTires = PhysicalProperties.new(0.7, 2.0, 0, 100, 1)

	local visualWheels = {
		self.Mech:FindFirstChild("FrontLeftWheel_Tire", true),
		self.Mech:FindFirstChild("FrontRightWheel_Tire", true),
		self.Mech:FindFirstChild("BackLeftWheel_Tire", true),
		self.Mech:FindFirstChild("BackRightWheel_Tire", true)
	}

	for _, tire in ipairs(visualWheels) do
		if tire then
			tire.CustomPhysicalProperties = stickyTires
		end
	end
	
	local torso = mechModel:FindFirstChild("Torso", true)
	if torso then
		-- A. Create an attachment for the constraint to grab onto
		local centerAttachment = Instance.new("Attachment")
		centerAttachment.Name = "FlipAttachment"
		centerAttachment.Parent = torso

		-- B. Create the smooth guiding constraint
		local aligner = Instance.new("AlignOrientation")
		aligner.Name = "SmoothFlipper"
		aligner.Attachment0 = centerAttachment
		aligner.Mode = Enum.OrientationAlignmentMode.OneAttachment

		-- Give it plenty of muscle, but low responsiveness so it moves smoothly!
		aligner.MaxTorque = 5000000000 
		aligner.Responsiveness = 10  

		aligner.Enabled = false -- Keep it OFF until we are flipped over
		aligner.Parent = torso

		-- Cache it to our self table so Update() can use it
		self.FlipAligner = aligner
	end
	
	self.CheckTimer = os.clock()

	return self
end

function Wheeled:GetActiveDriveHinges()
	local mech = self.Mech or self.Model or (self.Seat and self.Seat:FindFirstAncestorWhichIsA("Model"))
	if not mech then return {} end

	local activeHinges = {}
	for _, desc in ipairs(mech:GetDescendants()) do
		if desc:IsA("HingeConstraint") and string.find(desc.Name, "DriveHinge") then
			-- Verify the hinge is actually linked to an active wheel before sending torque
			if desc.Attachment1 and desc.Attachment1.Parent then
				table.insert(activeHinges, desc)
			end
		end
	end

	return activeHinges
end

function Wheeled:Update(deltaTime, movementVector, hipRotation, isLimping, staggerOffset, isFalling, currentSpeed, isWindingUp)
	-- 1. Get the live Seat to read player input
	local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
	if not seat then return end
	
	-- Normalize inputs to prevent circular mobile thumbsticks from starving engine torque
	local rawThrottle = seat.ThrottleFloat
	local steerInput = seat.SteerFloat
	
	local throttleInput = seat.Throttle
	
	if MobileUtil.isMobile() then
		local thumbDeflection = math.sqrt(rawThrottle * rawThrottle + steerInput * steerInput)
		if thumbDeflection > 0.1 then
			throttleInput = (rawThrottle < -0.15) and -1 or 1
		else
			throttleInput = 0
		end
	end


	-- 2. Define how far the wheels can physically turn (e.g., 35 degrees left or right)
	local MAX_STEER_ANGLE = 45 
	
	-- If the player is holding 'S' (Reverse), we cut the max steering angle in half!
	if throttleInput < 0 then
		MAX_STEER_ANGLE = 35 -- (Tune this number! Lower = wider turns in reverse)
	end

	-- 3. Calculate the angle. 
	-- We multiply the seat's Steer (-1 to 1) by our max angle.
	-- Calculate the angle in DEGREES (HingeConstraints do not use Radians!)
	-- Note: We might need to make this negative depending on which way your yellow arrows face.
	-- We check if this specific mech's seat was flagged by the builder to invert the steering.
	local steerMultiplier = seat:GetAttribute("InvertSteering") and -1 or 1
	local targetAngleDegrees = steerInput * steerMultiplier * MAX_STEER_ANGLE
	
	local torso = self.Mech:FindFirstChild("Torso", true)

	-- Check if at least one front wheel is physically mounted and receiving drive power
	local activeMotors = self:GetActiveDriveHinges()
	local hasSteering = false
	for _, hinge in ipairs(activeMotors) do
		if string.find(hinge.Name, "_FL") or string.find(hinge.Name, "_FR") then
			hasSteering = true
			break
		end
	end
	
	-- Only assist if we are driving FORWARD (Throttle > 0) and actually STEERING
	if torso and throttleInput > 0 and math.abs(steerInput) > 0.05 and hasSteering then

		-- We multiply by -1 because Roblox Steer is 1 for Right, but a Right turn is a NEGATIVE rotation in 3D math.
		local steerDirection = steerInput * steerMultiplier

		-- 250 is our baseline assist power. (Tune this! Higher = tighter turns, lower = wider turns)
		local assistPower = 1500

		-- Build the rotational force: 
		-- Spin around the UpVector, scale by Mass, scale by our Power, and scale by deltaTime for smooth framerates!
		local turnForce = torso.CFrame.UpVector * (steerDirection * torso.AssemblyMass * assistPower * deltaTime)

		--if math.random() < 0.1 then -- Throttle output to keep console readable
		--	print(string.format("ASSIST -> SteerInput: %.2f | Direction: %.2f | Force Y: %.0f", steerInput, steerDirection, turnForce.Y))
		--end
		-- Apply the twist!
		torso:ApplyAngularImpulse(turnForce)
	end
	
	-- 4. Apply to the Front Left Wheel (Checking if it hasn't been blown off!)
	if self.SteerFL and self.SteerFL.Parent then
		self.SteerFL.TargetAngle = targetAngleDegrees
	end

	-- 5. Apply to the Front Right Wheel
	if self.SteerFR and self.SteerFR.Parent then
		self.SteerFR.TargetAngle = targetAngleDegrees
	end
	
	-- 6. Calculate the Drive Speed
	-- Throttle is 1 (W), -1 (S), or 0 (Idle).
	local WHEEL_SPEED = seat and seat:GetAttribute("WalkSpeed") or 20 -- How fast the wheels spin (in radians per second)
	local targetVelocity = throttleInput * WHEEL_SPEED

	-- 7. Apply velocity to all currently active drive hinges
	local liveMotors = self:GetActiveDriveHinges()
	for _, hinge in ipairs(liveMotors) do
		hinge.AngularVelocity = targetVelocity
	end

	local torso = self.Mech:FindFirstChild("Torso", true)

	-- Initialize our stuck stopwatch if it doesn't exist yet
	self.StuckTimer = self.StuckTimer or 0
	
	if torso then
		local currentSpeed = torso.AssemblyLinearVelocity.Magnitude

		-- If holding the gas AND moving painfully slow...
		if throttleInput ~= 0 and currentSpeed < 2 then
			-- Add the time that passed this frame to our stopwatch
			self.StuckTimer += deltaTime

			-- If we've been stuck for 1.5 seconds straight...
			if self.StuckTimer > 1.5 then
				print("⚙️ INITIATING EMERGENCY UNSTUCK NUDGE!")
				-- 1. Determine which way the player is trying to drive (1 for Forward, -1 for Reverse)
				local driveDirection = throttleInput

				-- 2. Build the "Hop" trajectory: Straight UP, plus a little bit in their drive direction
				-- .LookVector is the direction the torso is currently facing
				local hopTrajectory = Vector3.new(0, 1, 0) + (torso.CFrame.LookVector * driveDirection)

				-- 3. Calculate how much force we need to lift THIS specific chassis
				-- .Unit ensures our trajectory direction length is exactly 1, so our math stays clean.
				-- We multiply by AssemblyMass so heavy tanks and light buggies both get an equal hop.
				-- (The '800' is our Hop Power multiplier. We will tune this!)
				local nudgeForce = hopTrajectory.Unit * (torso.AssemblyMass * 60)

				-- 4. Smack the chassis with the physics force!
				torso:ApplyImpulse(nudgeForce)

				-- 5. Reset the timer so it doesn't spam infinitely
				self.StuckTimer = 0

				-- (We will put the physics nudge right here in the next step!)
			end
		else
			-- We let go of the gas, OR we are driving fast again. Reset the clock!
			self.StuckTimer = 0
		end
		
		local upY = torso.CFrame.UpVector.Y

		-- Initialize our stopwatch memory if it doesn't exist yet
		self.FlipTimer = self.FlipTimer or 0
		
		-- If the UpVector drops below 0.2, the mech is tipped over!
		if upY < 0.2 then
			-- ONLY run the stopwatch if we aren't already actively flipping
			if not self.IsFlipping then
				-- Add the time that passed this specific frame (deltaTime) to our stopwatch
				self.FlipTimer += deltaTime

				if self.FlipTimer >= 2.0 then
					print("🔄 SENSOR: 2 seconds passed! Activating Smooth Flipper!")

					self.IsFlipping = true

					if self.FlipAligner and torso then
						-- 1. Find our current flat heading so we don't spin wildly when flipping
						local currentLook = torso.CFrame.LookVector
						local flatLook = Vector3.new(currentLook.X, 0, currentLook.Z)

						-- Failsafe: if perfectly nose-down, default to looking North
						if flatLook.Magnitude < 0.001 then
							flatLook = Vector3.new(0, 0, -1)
						else
							flatLook = flatLook.Unit
						end

						-- 2. Create a CFrame that is exactly where we are, but perfectly flat
						local targetCFrame = CFrame.lookAt(torso.Position, torso.Position + flatLook)

						-- 3. Give the target to the hardware and turn it on!
						self.FlipAligner.CFrame = targetCFrame
						self.FlipAligner.Enabled = true

					end
					self.FlipTimer = 0
				end
			end

		else
			-- Reset the stopwatch so we don't trigger again immediately
			self.FlipTimer = 0
			self.IsFlipping = false

			-- Instantly cut the moment we are upright
			if self.FlipAligner and self.FlipAligner.Enabled then
				self.FlipAligner.Enabled = false
				print("✅ SENSOR: Mech is upright. Flipper instantly powered down!")
			end
		end
		
	end
	
end

return Wheeled