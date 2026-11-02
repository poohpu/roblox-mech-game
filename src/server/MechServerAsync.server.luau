	-- Location: `ServerScriptService` 
	-- Function: The multiplayer brain of the mech. It does not calculate physics; 
	-- it acts as a "megaphone" to broadcast what individual players are doing to the rest of the server, and handles who owns the physics engine rights.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local updateAimEvent = ReplicatedStorage:WaitForChild("UpdateMechAim")
local fireWeaponEvent = ReplicatedStorage:WaitForChild("MechFireWeapon")
local staggerEvent = ReplicatedStorage:WaitForChild("MechStagger")
--local visualEvent = ReplicatedStorage:WaitForChild("MechVisualEffect")
local ghostSyncEvent = ReplicatedStorage:WaitForChild("MechGhostSync")
local meleeSparkEvent = ReplicatedStorage:FindFirstChild("MechMeleeSpark")
local ramEvent = ReplicatedStorage:WaitForChild("MechRamEvent")
local feetOffsetEvent = ReplicatedStorage:WaitForChild("MechFeetOffset")
local mechReloadEvent = ReplicatedStorage:WaitForChild("MechReloadEvent")
local ServerStorage = game:GetService("ServerStorage")
local shoulderMotorRefreshEvent = ServerStorage:WaitForChild("ShoulderMotorRefreshEvent")


local activeMechs = {} 
local weaponsFolder = ReplicatedStorage:WaitForChild("ModuleScripts"):WaitForChild("MechModules"):WaitForChild("Weapons")

local function GetMechRoot(mechModel)
	return mechModel:FindFirstChild("Hip", true) or mechModel:FindFirstChild("Chassis", true)
end

local function GetSlotMotors(mechModel, baseMotorName)
	local motors = {}
	for _, desc in ipairs(mechModel:GetDescendants()) do
		if desc:IsA("Motor6D") and string.find(desc.Name, "^" .. baseMotorName) then
			table.insert(motors, {
				Motor = desc,
				BaseC0 = desc.C0
			})
		end
	end
	return motors
end

local function findMotor6D(parent: Instance, jointName: string): Motor6D?
	for _, descendant in ipairs(parent:GetDescendants()) do
		if descendant:IsA("Motor6D") and descendant.Name == jointName then
			return descendant
		end
	end
	return nil
end

local function preventWheelBinding(mechModel)
	local wheelParts = {}
	local chassisParts = {}

	-- 1. Gather ONLY the parts you previously put in the "Assembly" group
	for _, part in ipairs(mechModel:GetDescendants()) do
		if part:IsA("BasePart") and part.CollisionGroup == "Assembly" and part.CanCollide then
			-- Split them into two teams based on their naming convention
			if string.find(part.Name, "Wheel") then
				table.insert(wheelParts, part)
			else
				table.insert(chassisParts, part)
			end

			-- 2. CRITICAL: Put them back into the Default group! 
			-- This allows the wheels and fenders to hit OTHER mechs again.
			part.CollisionGroup = "Default"
		end
	end

	-- 3. Create a constraint ONLY between a wheel and a chassis part
	local constraintsMade = 0
	for _, wheel in ipairs(wheelParts) do
		for _, chassis in ipairs(chassisParts) do
			local noCollide = Instance.new("NoCollisionConstraint")
			noCollide.Part0 = wheel
			noCollide.Part1 = chassis
			noCollide.Name = "WheelClearance"
			noCollide.Parent = wheel -- Hide the constraint neatly inside the wheel
			constraintsMade += 1
		end
	end

	print("Wired up", constraintsMade, "NoCollisionConstraints for ->", mechModel.Name)
end

-- 1. RECEIVE THE MOUSE TARGET
-- When a pilot sends their mouse position, the server saves it as an Attribute on the mech.
-- This automatically replicates to all other players with ZERO lag!
updateAimEvent.OnServerEvent:Connect(function(player, mechModel, targetPosition, driveCFrame, syncPackage)
	local mechData = activeMechs[mechModel]
	if not mechData then return end

	-- 1. Are they currently driving?
	local isAuthorized = false
	if mechData.Seat and mechData.Seat.Occupant then
		local sittingPlayer = game.Players:GetPlayerFromCharacter(mechData.Seat.Occupant.Parent)
		if sittingPlayer == player then isAuthorized = true end
	end

	-- 2. Did they just eject? Give them 2.5 seconds to broadcast the crash!
	if not isAuthorized and mechData.LastPilot == player and mechData.ExitTime and mechData.ExitTime > 0 then
		if (workspace:GetServerTimeNow() - mechData.ExitTime) < 2.5 then
			isAuthorized = true
		end
	end

	if isAuthorized then

		if targetPosition then
			mechModel:SetAttribute("AimTarget", targetPosition)
		end
		-- 2. Save the chassis position
		if driveCFrame then
			--print("📍 WRITING DriveCFrame:", driveCFrame.Position)
			mechModel:SetAttribute("DriveCFrame", driveCFrame)

			-- If they just ejected (Seat is empty), we pull the root down with their crash broadcast!
			-- This avoids twitching while driving, but allows the Torso to fall properly when empty.
			if mechData.Seat and mechData.Seat.Occupant == nil and mechData.DriveCore then
				mechData.DriveCore.CFrame = driveCFrame
			end
		end

		-- [THE GHOST SYNC CATCHER & SANITIZER ]
		if syncPackage and type(syncPackage) == "table" then
			local mechData = activeMechs[mechModel]
			if not mechData then return end

			-- A. THE TRANSFORM TRICK (For Arms/Spine)
			-- This makes the upper body aim replicate perfectly on the Server view!
			-- HIGH PING FIX: instead of snapping every Motor6D Transform directly at
			-- 10Hz, we queue the target pose and let the Heartbeat interpolator at the
			-- bottom of this script ease toward it every frame. The server's view
			-- (and any raycasts/hitboxes that depend on it) stays continuous between
			-- samples instead of jittering 10 times a second.
			local transformTargets = mechData.TransformTargets
			if not transformTargets then
				transformTargets = {}
				mechData.TransformTargets = transformTargets
			end

			local function queueTransform(motor, baseC0, incomingC0)
				if motor and baseC0 and typeof(incomingC0) == "CFrame" then
					transformTargets[motor] = baseC0:Inverse() * incomingC0
				end
			end

			queueTransform(mechData.Waist, mechData.BaseWaistC0, syncPackage.WaistC0)
			queueTransform(mechData.Neck, mechData.BaseNeckC0, syncPackage.NeckC0)
			queueTransform(mechData.RShoulder, mechData.BaseRShoulderC0, syncPackage.RShoulderC0)
			queueTransform(mechData.LShoulder, mechData.BaseLShoulderC0, syncPackage.LShoulderC0)
			queueTransform(mechData.RElbow, mechData.BaseRElbowC0, syncPackage.RElbowC0)
			queueTransform(mechData.LElbow, mechData.BaseLElbowC0, syncPackage.LElbowC0)

			queueTransform(mechData.LThigh, mechData.BaseLThighC0, syncPackage.LThighC0)
			queueTransform(mechData.RThigh, mechData.BaseRThighC0, syncPackage.RThighC0)
			queueTransform(mechData.LKnee, mechData.BaseLKneeC0, syncPackage.LKneeC0)
			queueTransform(mechData.RKnee, mechData.BaseRKneeC0, syncPackage.RKneeC0)
			queueTransform(mechData.LCalf, mechData.BaseLCalfC0, syncPackage.LCalfC0)
			queueTransform(mechData.RCalf, mechData.BaseRCalfC0, syncPackage.RCalfC0)
			queueTransform(mechData.LFoot, mechData.BaseLFootC0, syncPackage.LFootC0)
			queueTransform(mechData.RFoot, mechData.BaseRFootC0, syncPackage.RFootC0)

			if mechData.RightShoulderMotors and type(syncPackage.RShoulderWeaponC0) == "table" then
				for index, item in ipairs(mechData.RightShoulderMotors) do
					local incomingC0 = syncPackage.RShoulderWeaponC0[index]
					if incomingC0 and item.Motor and item.Motor.Parent then
						queueTransform(item.Motor, item.BaseC0, incomingC0)
					end
				end
			end

			if mechData.LeftShoulderMotors and type(syncPackage.LShoulderWeaponC0) == "table" then
				for index, item in ipairs(mechData.LeftShoulderMotors) do
					local incomingC0 = syncPackage.LShoulderWeaponC0[index]
					if incomingC0 and item.Motor and item.Motor.Parent then
						queueTransform(item.Motor, item.BaseC0, incomingC0)
					end
				end
			end
			
			-- Tank Turret Transform Trick
			queueTransform(mechData.CamYawMotor, mechData.BaseCamYawC0, syncPackage.CamYawC0)
			queueTransform(mechData.CamPitchMotor, mechData.BaseCamPitchC0, syncPackage.CamPitchC0)

			-- B. THE PROXY TARGET TRICK (For Legs)
			local MAX_LEG_STRETCH = 50 
			local corePos = driveCFrame and driveCFrame.Position or Vector3.zero

			local proxyTargets = mechData.ProxyTargets
			if not proxyTargets then
				proxyTargets = {}
				mechData.ProxyTargets = proxyTargets
			end

			if mechData.ProxyLeft and typeof(syncPackage.LeftFootCFrame) == "CFrame" then
				if (syncPackage.LeftFootCFrame.Position - corePos).Magnitude <= MAX_LEG_STRETCH then
					proxyTargets[mechData.ProxyLeft] = syncPackage.LeftFootCFrame
				end
			end

			if mechData.ProxyRight and typeof(syncPackage.RightFootCFrame) == "CFrame" then
				if (syncPackage.RightFootCFrame.Position - corePos).Magnitude <= MAX_LEG_STRETCH then
					proxyTargets[mechData.ProxyRight] = syncPackage.RightFootCFrame
				end
			end

			-- Relay to Spectators!
			ghostSyncEvent:FireAllClients(player, mechModel, syncPackage)

		end
	end
end)
fireWeaponEvent.OnServerEvent:Connect(function(player, mechModel, slotName, targetPos)
	--print("🚨 TRIPWIRE 1: Request received from", player.Name, "| Slot:", tostring(slotName))

	local character = player.Character
	if not character or not character:FindFirstChild("Humanoid") then 
		return 
	end

	local seat = character.Humanoid.SeatPart
	if not seat then 
		return 
	end
	if not seat:IsDescendantOf(mechModel) then 
		return 
	end

	--print("🚨 TRIPWIRE 2: Pilot authorized.")

	local mechData = activeMechs[mechModel]
	if not mechData then 
		return 
	end

	local serverWeapon = mechData.Weapons and mechData.Weapons[slotName]
	
	-- We must check if the Server is currently holding a Fist, but the Client repaired the Gun!
	local weaponSlots = { RightWeapon = "RightWeaponType", LeftWeapon = "LeftWeaponType", RightShoulderWeapon = "RightShoulderType", LeftShoulderWeapon = "LeftShoulderType" }
	local weaponType = mechData.Seat:GetAttribute(weaponSlots[slotName])
	local weaponPart = mechModel:FindFirstChild(slotName, true)
	local torso = mechModel:FindFirstChild("Torso", true)
	
	local isGunWelded = weaponPart and torso and weaponPart.AssemblyRootPart == torso.AssemblyRootPart
	
	if serverWeapon and serverWeapon.WeaponName ~= "Fist" then
		-- Check if the physical gun part is actually still attached to the mech!
		if not isGunWelded then
			-- Check if the arm is actually still there before giving them a fist!
			local prefix = string.find(slotName, "Right") and "Right" or "Left"
			local hasArm = mechModel:FindFirstChild(prefix .. "Shoulder", true)
			local hasHand = mechModel:FindFirstChild(prefix .. "Hand", true)

			if hasArm and hasHand and not string.find(slotName, "Shoulder") then
				local punchScript = weaponsFolder:FindFirstChild("MeleeWeapon")
				if punchScript then
					local PunchCartridge = require(punchScript)
					mechData.Weapons[slotName] = PunchCartridge.new(mechModel, slotName)
					serverWeapon = mechData.Weapons[slotName]
					print("SERVER: Detected missing weapon. Hot-swapping to Fist!")
				end
			else
				-- If the whole arm is gone, wipe the slot completely!
				mechData.Weapons[slotName] = nil
				serverWeapon = nil
			end
		end
	elseif serverWeapon and serverWeapon.WeaponName == "Fist" then
		-- Fist -> Gun Check: The gun was repaired! 
		if weaponPart and weaponType then
			local weaponScript = weaponsFolder:FindFirstChild(weaponType)
			if weaponScript then
				local WeaponTemplate = require(weaponScript)
				mechData.Weapons[slotName] = WeaponTemplate.new(mechModel, weaponPart)
				serverWeapon = mechData.Weapons[slotName]
				print("SERVER: Detected repaired weapon. Hot-swapping to " .. weaponType .. "!")
			end
		end
	end
	
	if not serverWeapon then 
		print("❌ JAM: Slot '" .. tostring(slotName) .. "' is empty in Server Memory!") 
		return 
	end
	if not serverWeapon or (serverWeapon.Profile and serverWeapon.Profile.Phases) then return end

	--print("🚨 TRIPWIRE 3: Weapon found! Server pulling the trigger...")

	local ignoreList = {mechModel, character}
	local didFire = serverWeapon:Fire(targetPos, ignoreList, true)
	--print("🚨 TRIPWIRE 4: Did Server Weapon Fire?", didFire)

		-- 2. ONLY broadcast the visual tracers to other players if the Server allowed the shot!
	if didFire then
		for _, client in pairs(game:GetService("Players"):GetPlayers()) do
			if client ~= player then
				fireWeaponEvent:FireClient(client, player, mechModel, slotName, targetPos)
			end
		end
	end
end)
--staggerEvent.OnServerEvent:Connect(function(shooter, hitModel, intensity, direction)
--	staggerEvent:FireAllClients(hitModel, intensity, direction)
--end)
--visualEvent.OnServerEvent:Connect(function(player, impactPos, blastDir, hitNormal)
--	-- Echo the explosion to everyone EXCEPT the shooter (they already saw it on their screen!)
--	for _, client in pairs(game.Players:GetPlayers()) do
--		if client ~= player then
--			visualEvent:FireClient(client, impactPos, blastDir, hitNormal)
--		end
--	end
--end)

local ramCooldowns = {}
local RAM_COOLDOWN = 0.1

ramEvent.OnServerEvent:Connect(function(player, enemyMech, overlap, pushDir)
    local enemyData = activeMechs[enemyMech]
	if not enemyData then return end
	
	print("RAM")

    -- 1. Pilot Validation: Ensure the caller is actively driving a mech
    local senderChar = player.Character
    local senderHumanoid = senderChar and senderChar:FindFirstChildOfClass("Humanoid")
    local senderSeat = senderHumanoid and senderHumanoid.SeatPart
	if not senderSeat or not senderSeat:IsA("VehicleSeat") then return end
	local senderMech = senderSeat:FindFirstAncestorWhichIsA("Model")

    -- 2. Anti-Spam & Clamping
    local now = os.clock()
    local lastRamTime = ramCooldowns[enemyMech] or 0
    if now - lastRamTime < RAM_COOLDOWN then return end
    ramCooldowns[enemyMech] = now

    local clampedOverlap = math.clamp(overlap or 0, 0, 3)
    local flatPushDir = Vector3.new(pushDir.X, 0, pushDir.Z)
    if flatPushDir.Magnitude < 0.001 then return end
    flatPushDir = flatPushDir.Unit

    local enemyLocoType = enemyData.Seat and enemyData.Seat:GetAttribute("LocomotionType")
    local hip = GetMechRoot(enemyMech)

    if enemyLocoType == "Wheeled" then
        if hip then
            hip.Anchored = false

			-- Calculate desired top push speed based on overlap (capped between 8 and 22 studs/s)
			local desiredSpeed = math.clamp(clampedOverlap * 14, 12, 28)
			local pushVector = -flatPushDir

			-- Check how fast the tank is ALREADY sliding in the push direction
			local currentSpeedInPushDir = hip.AssemblyLinearVelocity:Dot(pushVector)

			-- Only add the speed needed to hit the target (prevents stacking into a rocket)
			local speedDelta = math.clamp(desiredSpeed - currentSpeedInPushDir, 0, desiredSpeed)

			-- Only add a tiny upward pop if the tank is completely stopped (< 2 studs/s)
			local isStopped = hip.AssemblyLinearVelocity.Magnitude < 2
			local liftPower = isStopped and 1.2 or 0
			local frictionBreakLift = Vector3.new(0, hip.AssemblyMass * liftPower, 0)

			local horizontalForce = pushVector * (hip.AssemblyMass * speedDelta)
			local totalShoveForce = horizontalForce + frictionBreakLift

			-- Only fire if there is actual force needed
			if totalShoveForce.Magnitude > 50 then
				local networkOwner = hip:GetNetworkOwner()
				if networkOwner then
					ramEvent:FireClient(networkOwner, enemyMech, totalShoveForce)
				else
					-- Directly set linear velocity to break physics sleep before applying impulse
					hip.AssemblyLinearVelocity = pushVector * (desiredSpeed * 0.5)
					hip:ApplyImpulse(totalShoveForce)
				end
			end
        end
    else
        -- BIPEDAL / CRAWLER: Shift CFrame and notify spectators
        local currentCFrame = enemyMech:GetAttribute("DriveCFrame")
        if currentCFrame and enemyData.DriveCore then
			-- ANTI-JITTER: a driven victim's client also predicts its own half of
			-- the separation locally, so the server pushes at half strength for
			-- driven mechs. Unmanned mechs (AI / parked) get the full push since
			-- the server is their only authority.
			local victimDriven = enemyData.Driver ~= nil
			local pushDistance = victimDriven
				and math.clamp(clampedOverlap * 1.0, 0.6, 2.0)
				or math.clamp(clampedOverlap * 2.0, 1.2, 4.0)
			local pushOffset = -flatPushDir * pushDistance

            -- Wall penetration check
            local rayParams = RaycastParams.new()
            rayParams.FilterType = Enum.RaycastFilterType.Exclude
            rayParams.FilterDescendantsInstances = {enemyMech, senderChar, senderMech }

            local hipPos = enemyData.DriveCore.Position
            local hit = workspace:Raycast(hipPos, pushOffset, rayParams)
            if hit then
                pushOffset = pushOffset.Unit * math.max(hit.Distance - 1, 0)
            end

			-- HIGH PING FIX: log the ram displacement so the rubberband anti-cheat
			-- doesn't false-positive on the victim. The push happens instantly (up to
			-- ~4 studs, and rams can chain), which looks like a teleport to the
			-- 1-second distance monitor below.
			enemyData.RamDisplacements = enemyData.RamDisplacements or {}
			table.insert(enemyData.RamDisplacements, {time = os.clock(), distance = pushOffset.Magnitude})

			if pushOffset.Magnitude > 0.01 then
				-- ANTI-JITTER: never teleport a driven mech directly. The pilot's
				-- client owns that mech's DriveCFrame simulation, so a server
				-- teleport fights it and caused the ram jitter. Driven victims
				-- reconcile through the feet offset event (their client adds the
				-- offset to BaseDriveCFrame); unmanned mechs teleport directly.
				if not victimDriven then
					local newCFrame = currentCFrame + pushOffset
					enemyData.DriveCore.CFrame = newCFrame
					enemyMech:SetAttribute("DriveCFrame", newCFrame)

					if hip then
						hip.AssemblyLinearVelocity = pushOffset.Unit * 2
					end
				end

				feetOffsetEvent:FireAllClients(enemyMech, pushOffset)
			end
        end
    end
end)

-- 2. HAND OVER NETWORK OWNERSHIP
-- When someone sits in a mech, let their computer control the physics so it drives smoothly.
local function setupMech(mechModel)
	if mechModel:IsDescendantOf(game:GetService("ServerStorage")) then return end
	
	local seat = mechModel:FindFirstChildWhichIsA("VehicleSeat", true)
	local assemblyCount = 0
	local totalPhysicalCount = 0
	for _, part in ipairs(mechModel:GetDescendants()) do
		if part:IsA("BasePart") then
			if part.CanCollide then totalPhysicalCount += 1 end
			if part.CollisionGroup == "Assembly" then
				assemblyCount += 1
				print("🔍 FOUND ASSEMBLY PART:", part.Name)
			end
		end
	end
	--print("📊 DIAGNOSTIC:", mechModel.Name, "has", totalPhysicalCount, "physical parts, but only", assemblyCount, "in the Assembly group.")
	if not seat then return end

	-- We create a blank attribute ready for the mouse target
	mechModel:SetAttribute("AimTarget", Vector3.new(0,0,0))
	
	local loadedWeapons = {}
	local weaponSlots = {
		RightWeapon = "RightWeaponType",
		LeftWeapon = "LeftWeaponType",
		RightShoulderWeapon = "RightShoulderType",
		LeftShoulderWeapon = "LeftShoulderType"
	}

	for slotName, attributeName in pairs(weaponSlots) do
		local weaponType = seat:GetAttribute(attributeName)
		if weaponType then
			local weaponScript = weaponsFolder:FindFirstChild(weaponType)
			local weaponPart = mechModel:FindFirstChild(slotName, true)

			if weaponScript and weaponPart then
				local WeaponTemplate = require(weaponScript)
				loadedWeapons[slotName] = WeaponTemplate.new(mechModel, weaponPart)
				print("SERVER: Registered " .. weaponType .. " into " .. slotName)
			end
		end
	end

	local targetLeft = mechModel:FindFirstChild("TargetLeft", true)
	local targetRight = mechModel:FindFirstChild("TargetRight", true)

	-- 1. Create Server-Only Targets so the Server's IK doesn't fight the Client's IK!
	local proxyLeft = targetLeft and targetLeft:Clone()

	if proxyLeft then
		proxyLeft.Name = "ServerProxyLeft"
		proxyLeft.Anchored = true
		proxyLeft.Parent = targetLeft.Parent
	end

	local proxyRight = targetRight and targetRight:Clone()

	if proxyRight then
		proxyRight.Name = "ServerProxyRight"
		proxyRight.Anchored = true
		proxyRight.Parent = targetRight.Parent
	end

	-- 2. Redirect the Server's IK to look at our new Proxies
	for _, ik in pairs(mechModel:GetDescendants()) do
		if ik:IsA("IKControl") and ik.Target then
			if ik.Target.Name == "TargetLeft" and proxyLeft then
				ik.Target = proxyLeft
			elseif ik.Target.Name == "TargetRight" and proxyRight then
				ik.Target = proxyRight
			end
		end
	end

	-- 3. Cache the joints exactly ONCE so we never have to use GetDescendants in the network loop again!
	local waist = mechModel:FindFirstChild("Waist", true)
	local neck = mechModel:FindFirstChild("Neck", true) or mechModel:FindFirstChild("NeckMotor", true)
	local rShoulder = mechModel:FindFirstChild("RightShoulder", true)
	local lShoulder = mechModel:FindFirstChild("LeftShoulder", true)
	
	-- FABRIK leg
	local lThigh = findMotor6D(mechModel, "LeftThigh")
	local rThigh = findMotor6D(mechModel, "RightThigh")
	local lKnee  = findMotor6D(mechModel, "LeftLegConn") or findMotor6D(mechModel, "LeftKnee")
	local rKnee  = findMotor6D(mechModel, "RightLegConn") or findMotor6D(mechModel, "RightKnee")
	local lCalf  = findMotor6D(mechModel, "LeftCalf")
	local rCalf  = findMotor6D(mechModel, "RightCalf")
	local lFoot  = findMotor6D(mechModel, "LeftFoot")
	local rFoot  = findMotor6D(mechModel, "RightFoot")
	
	local rElbow, lElbow = nil, nil
	for _, desc in ipairs(mechModel:GetDescendants()) do
		if desc:IsA("Motor6D") then
			if desc.Name == "RightLowerArm" or desc.Name == "RightElbow" then
				rElbow = desc
			elseif desc.Name == "LeftLowerArm" or desc.Name == "LeftElbow" then
				lElbow = desc
			end
		end
	end
	local rightShoulderMotors = GetSlotMotors(mechModel, "RightShoulderWeaponMotor")
	local leftShoulderMotors = GetSlotMotors(mechModel, "LeftShoulderWeaponMotor")

	-- Tank Turret Joints
	local camPitchMotor = mechModel:FindFirstChild("CameraPitchMotor", true)
	local camYawMotor = nil

	for _, desc in ipairs(mechModel:GetDescendants()) do
		if desc:IsA("Motor6D") and desc.Name == "CameraYawBase" then
			camYawMotor = desc
			break
		end
	end

	-- Save the mech's data to the server's memory
	activeMechs[mechModel] = {
		Seat = seat,
		Weapons = loadedWeapons,
		Waist = waist,
		BaseWaistC0 = waist and waist.C0,
		Neck = neck,
		BaseNeckC0 = neck and neck.C0,
		RShoulder = rShoulder,
		BaseRShoulderC0 = rShoulder and rShoulder.C0,
		LShoulder = lShoulder,
		BaseLShoulderC0 = lShoulder and lShoulder.C0,
		RElbow = rElbow,
		BaseRElbowC0 = rElbow and rElbow.C0,
		LElbow = lElbow,
		BaseLElbowC0 = lElbow and lElbow.C0,
		
		LThigh = lThigh, BaseLThighC0 = lThigh and lThigh.C0,
		RThigh = rThigh, BaseRThighC0 = rThigh and rThigh.C0,
		LKnee = lKnee, BaseLKneeC0 = lKnee and lKnee.C0,
		RKnee = rKnee, BaseRKneeC0 = rKnee and rKnee.C0,
		LCalf = lCalf, BaseLCalfC0 = lCalf and lCalf.C0,
		RCalf = rCalf, BaseRCalfC0 = rCalf and rCalf.C0,
		LFoot = lFoot, BaseLFootC0 = lFoot and lFoot.C0,
		RFoot = rFoot, BaseRFootC0 = rFoot and rFoot.C0,
		
		ProxyLeft = proxyLeft,
		ProxyRight = proxyRight,
		RightShoulderMotors = rightShoulderMotors,
		LeftShoulderMotors = leftShoulderMotors,
		CamPitchMotor = camPitchMotor,
		BaseCamPitchC0 = camPitchMotor and camPitchMotor.C0,
		CamYawMotor = camYawMotor,
		BaseCamYawC0 = camYawMotor and camYawMotor.C0,
		DriveCore = mechModel:FindFirstChild("TargetGround", true)
	}
	
	local ignoredPartNames = {
		["TargetGround"] = true,
		["TargetLeft"] = true,
		["TargetRight"] = true,
		["ServerProxyLeft"] = true,
		["ServerProxyRight"] = true
	}

	local function handleOccupantChange()
		local occupant = seat.Occupant
		local driveCore = mechModel:FindFirstChild("TargetGround", true)
		local mechData = activeMechs[mechModel] -- Get our memory table

		if occupant then
			-- Someone sat down! Get the player.
			local player = game.Players:GetPlayerFromCharacter(occupant.Parent)
			if player then
				-- Track the pilot for the Broadcasting License!
				mechData.LastPilot = player
				mechData.ExitTime = 0
				
				-- Grant their computer full control over the mech's physical parts
				for _, part in pairs(mechModel:GetDescendants()) do
					if part:IsA("BasePart") and not ignoredPartNames[part.Name] then
						-- Use pcall because some parts (like welded accessories) can't have ownership set directly
						part.Anchored = false
						local ok, err = pcall(function()
							part:SetNetworkOwner(player)
						end)
						if not ok then warn("Ownership failed on", part.Name, err) end
					end
				end
			end
		else
			-- Pilot ejected! Start the grace period timer.
			local mechData = activeMechs[mechModel]
			if mechData then
				mechData.ExitTime = workspace:GetServerTimeNow()
				
				local lastKnownCFrame = mechModel:GetAttribute("DriveCFrame")
				if mechData.DriveCore and lastKnownCFrame then
					mechData.DriveCore.CFrame = lastKnownCFrame
				end
			end
			
			local isWheeled = mechData and mechData.Seat and mechData.Seat:GetAttribute("LocomotionType") == "Wheeled"

			if isWheeled then
				-- WHEELED: Reclaim ownership immediately so the server controls its physics right away
				for _, part in ipairs(mechModel:GetDescendants()) do
					if part:IsA("BasePart") then
						pcall(function()
							part:SetNetworkOwner(nil)
						end)
					end
				end

				local driveCore = mechModel:FindFirstChild("TargetGround", true)
				if driveCore then
					mechModel:SetAttribute("DriveCFrame", driveCore.CFrame)
				end
			else
				-- BIPEDAL: Needs the 5-second window to let walking/stepping animations finish settling
				task.delay(5, function()
					if seat.Occupant == nil then
						for _, part in ipairs(mechModel:GetDescendants()) do
							if part:IsA("BasePart") then
								pcall(function()
									part:SetNetworkOwner(nil)
								end)
							end
						end

						local hip = GetMechRoot(mechModel)
						local driveCore = mechModel:FindFirstChild("TargetGround", true)
						local finalParkedCFrame = mechModel:GetAttribute("DriveCFrame")

						if hip and driveCore and finalParkedCFrame then
							driveCore.CFrame = finalParkedCFrame
							mechModel:SetAttribute("DriveCFrame", finalParkedCFrame)
						end
					end
				end)
			end
			
			
		end
	end
	-- Connect the event, AND run it instantly to catch anyone already sitting!
	seat:GetPropertyChangedSignal("Occupant"):Connect(handleOccupantChange)
	if seat.Occupant then
		handleOccupantChange()
	end
	-- Untangle the wheel collisions before the physics engine has a chance to freak out
	preventWheelBinding(mechModel)
end

for _, mech in ipairs(CollectionService:GetTagged("Vehicle")) do
	setupMech(mech)
end

CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(setupMech)

-- Prevent memory leaks when mechs are destroyed
CollectionService:GetInstanceRemovedSignal("Vehicle"):Connect(function(mechModel)
	activeMechs[mechModel] = nil
	ramCooldowns[mechModel] = nil
end)

-- Refresh shoulder motor caches after repair (fixes stale Motor6D references)
shoulderMotorRefreshEvent.Event:Connect(function(mechModel)
	local mechData = activeMechs[mechModel]
	if not mechData then return end

	mechData.RightShoulderMotors = GetSlotMotors(mechModel, "RightShoulderWeaponMotor")
	mechData.LeftShoulderMotors = GetSlotMotors(mechModel, "LeftShoulderWeaponMotor")
	print("🔧 SERVER: Refreshed shoulder weapon motor caches for " .. mechModel.Name)
end)

-- Rubberbanding
-- We give a 3x multiplier to WalkSpeed to allow for jumping, dashing, or getting 
-- horizontally pushed by explosions, while still easily catching map-wide teleports.
local SPEED_BUFFER = 3.0 

task.spawn(function()
	while task.wait(1) do -- Check every 1 second
		for mechModel, mechData in pairs(activeMechs) do
			local seat = mechData.Seat
			local pilot = seat and seat.Occupant
			local driveCore = mechModel:FindFirstChild("TargetGround", true)
			local currentCFrame = mechModel:GetAttribute("DriveCFrame")

			-- Only monitor mechs that are actively being driven!
			if pilot and seat then
				local currentLoco = seat:GetAttribute("LocomotionType")
                local hip = GetMechRoot(mechModel)
                local currentCFrame = mechModel:GetAttribute("DriveCFrame")

                -- Wheeled mechs use physical Hip position; Bipeds/Crawlers use replicated DriveCFrame
                local currentPos = (currentLoco == "Wheeled" and hip) and hip.Position or (currentCFrame and currentCFrame.Position)

                if currentPos then
                    local lastPos = mechData.LastSafePosition

					if lastPos then
						-- MATH: We check horizontal distance only. 
						-- (We ignore the Y-axis so falling off a massive cliff doesn't trigger a false positive!)
						local flatCurrent = Vector3.new(currentPos.X, 0, currentPos.Z)
						local flatLast = Vector3.new(lastPos.X, 0, lastPos.Z)
						local horizontalDistance = (flatCurrent - flatLast).Magnitude

						local walkSpeed = seat:GetAttribute("WalkSpeed") or 16
						local currentLoco = seat:GetAttribute("LocomotionType")

						-- Bipedal & Crawler strictly obey math, so they keep the standard 3.0 buffer.
						-- Wheeled mechs use physics momentum and gravity, so we give them a massive 8.0 buffer!
						local dynamicBuffer = (currentLoco == "Wheeled") and 8.0 or SPEED_BUFFER
						local maxAllowedDistance = walkSpeed * dynamicBuffer

						-- HIGH PING FIX: Ram pushes displace a mech instantly, which the
						-- distance monitor can mistake for a teleport. Add the total recent
						-- ram displacement (last 2 seconds) to the allowed distance so ram
						-- victims aren't rubberbanded. Expired entries are pruned here.
						local ramAllowance = 0
						local ramLog = mechData.RamDisplacements
						if ramLog then
							local checkTime = os.clock()
							local keptLog = {}
							for _, entry in ipairs(ramLog) do
								if checkTime - entry.time < 2 then
									keptLog[#keptLog + 1] = entry
									ramAllowance += entry.distance
								end
							end
							mechData.RamDisplacements = keptLog
						end
						maxAllowedDistance += ramAllowance

						if horizontalDistance > maxAllowedDistance then
							print("ANTI-CHEAT TRIGGERED on: " .. mechModel.Name)
							print("   -> LocoType:", seat:GetAttribute("LocomotionType"))
							print("   -> Traveled:", math.floor(horizontalDistance), "studs")
							print("   -> Max Allowed:", math.floor(maxAllowedDistance), "studs")
							print("   -> Rubberbanding now...")

							-- 1. Strip Network Ownership from the exploiter instantly!
							for _, part in pairs(mechModel:GetDescendants()) do
								if part:IsA("BasePart") then
									pcall(function() part:SetNetworkOwner(nil) end)
								end
							end

							-- 2. Snap the mech back to the last known safe location
							local lastKnown = mechModel:GetAttribute("DriveCFrame")
							local safeRotation = (lastKnown and lastKnown.Rotation) or CFrame.identity
							local safeCFrame = CFrame.new(lastPos) * safeRotation
							mechModel:SetAttribute("DriveCFrame", safeCFrame)

							-- 3. Snap the physical Torso so the exploiter gets violently yanked backward on their screen!
							local torso = mechModel:FindFirstChild("Torso")
							if torso then torso.CFrame = safeCFrame end
							if driveCore then driveCore.CFrame = safeCFrame end

							-- 4. Give the steering wheel back after 1 second of punishment
							local player = game.Players:GetPlayerFromCharacter(pilot.Parent)
							if player then
								task.delay(1, function()
									for _, part in pairs(mechModel:GetDescendants()) do
										if part:IsA("BasePart") and part.Name ~= "TargetGround" then
											pcall(function() part:SetNetworkOwner(player) end)
										end
									end
								end)
							end
						else
							-- Movement is legal! Record this as the new Safe Position.
							mechData.LastSafePosition = currentPos
						end
					end
					
				else
					-- First time seeing this mech move, record its starting block
					mechData.LastSafePosition = currentPos
				end
			else
				-- If the pilot hopped out, clear the safe position
				mechData.LastSafePosition = nil
			end
		end
	end
end)

meleeSparkEvent.OnServerEvent:Connect(function(player, impactPos, blastDir, hitNormal)
	-- Bounce the visuals to every spectator (skipping the shooter since they already drew it!)
	for _, otherPlayer in ipairs(game:GetService("Players"):GetPlayers()) do
		if otherPlayer ~= player then
			meleeSparkEvent:FireClient(otherPlayer, impactPos, blastDir, hitNormal)
		end
	end
end)

mechReloadEvent.OnServerEvent:Connect(function(player, mechModel, slotName)
	local mechData = activeMechs[mechModel]
	if not mechData then return end

	-- Verify the player is actually sitting in this mech
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat or not seat:IsDescendantOf(mechModel) then return end

	local serverWeapon = mechData.Weapons and mechData.Weapons[slotName]
	if serverWeapon and not serverWeapon.IsReloading and serverWeapon.CurrentAmmo < serverWeapon.MaxAmmo then
		serverWeapon:Reload()
	end
end)

-- HIGH PING FIX: Server-side pose interpolator.
-- The pilot's client streams joint poses at ~10Hz. Instead of snapping the
-- server's Motor6D Transforms and IK proxy targets to each sample, ease toward
-- the latest queued pose every frame so the server's view stays continuous
-- between samples (matching the client-side ghostSync interpolator).
local SYNC_INTERVAL = 0.1 -- seconds between ghost sync samples

RunService.Heartbeat:Connect(function(dt)
	local alpha = math.clamp(dt / SYNC_INTERVAL, 0, 1)

	for _, mechData in pairs(activeMechs) do
		local transformTargets = mechData.TransformTargets
		if transformTargets then
			for motor, targetTransform in pairs(transformTargets) do
				if motor.Parent then
					motor.Transform = motor.Transform:Lerp(targetTransform, alpha)
				else
					-- Motor was destroyed (limb severed) - stop tracking it
					transformTargets[motor] = nil
				end
			end
		end

		local proxyTargets = mechData.ProxyTargets
		if proxyTargets then
			for proxy, targetCFrame in pairs(proxyTargets) do
				if proxy.Parent then
					proxy.CFrame = proxy.CFrame:Lerp(targetCFrame, alpha)
				else
					proxyTargets[proxy] = nil
				end
			end
		end
	end
end)

