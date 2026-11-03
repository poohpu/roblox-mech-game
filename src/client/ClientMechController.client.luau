-- Location: StarterPlayerScripts.ClientMechController
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local rojoShared = ReplicatedStorage:WaitForChild("Shared")
local moduleScripts = rojoShared:WaitForChild("ModuleScripts")
local clientModules = moduleScripts:WaitForChild("MechModules"):WaitForChild("Client")

local Config = require(clientModules:WaitForChild("MechClientConfig"))
local HUD = require(clientModules:WaitForChild("MechHUDController"))
local Input = require(clientModules:WaitForChild("MechInputController"))
local Aim = require(clientModules:WaitForChild("MechAimController"))
local MobileUtil = require(moduleScripts:WaitForChild("MobileUtil"))
local isMobile = MobileUtil.isMobile()

local ghostSyncEvent = ReplicatedStorage:WaitForChild("MechGhostSync")
local MechRamEvent = ReplicatedStorage:WaitForChild("MechRamEvent")
local feetOffsetEvent = ReplicatedStorage:WaitForChild("MechFeetOffset")
local updateAimEvent = ReplicatedStorage:WaitForChild("UpdateMechAim")
local fireWeaponEvent = ReplicatedStorage:WaitForChild("MechFireWeapon")
local staggerEvent = ReplicatedStorage:WaitForChild("MechStagger")
local visualEvent = ReplicatedStorage:WaitForChild("MechVisualEffect")
local stateUpdateEvent = ReplicatedStorage:WaitForChild("MechStateUpdate")

local localPlayer = Players.LocalPlayer
local activeMechs = {}
local mechOriginalParts = {}
local cachedAimIgnoreList = {}
--local cachedBumperIgnoreList = {}
local cachedTerrainIgnoreList = {}
local cachedWeaponIgnoreList = {}

local aimRaycastParams = RaycastParams.new()
aimRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
aimRaycastParams.CollisionGroup = "Players"

local bumperRaycastParams = RaycastParams.new()
bumperRaycastParams.FilterType = Enum.RaycastFilterType.Exclude

local terrainRaycastParams = RaycastParams.new()
terrainRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
terrainRaycastParams.IgnoreWater = true

local tankAirRaycastParams = RaycastParams.new()
tankAirRaycastParams.FilterType = Enum.RaycastFilterType.Exclude

local destructiblesList = {}
local trampleOverlapParams = OverlapParams.new()
trampleOverlapParams.FilterType = Enum.RaycastFilterType.Include
trampleOverlapParams.FilterDescendantsInstances = destructiblesList

for _, obj in pairs(CollectionService:GetTagged("Destructible")) do table.insert(destructiblesList, obj) end

CollectionService:GetInstanceAddedSignal("Destructible"):Connect(function(obj)
	table.insert(destructiblesList, obj)
	trampleOverlapParams.FilterDescendantsInstances = destructiblesList
end)
CollectionService:GetInstanceRemovedSignal("Destructible"):Connect(function(obj)
	local idx = table.find(destructiblesList, obj)
	if idx then table.remove(destructiblesList, idx) trampleOverlapParams.FilterDescendantsInstances = destructiblesList end
end)

local globalRaycastIgnore = {}

local function RefreshIgnoreList()
	table.clear(globalRaycastIgnore)
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then table.insert(globalRaycastIgnore, player.Character) end
	end
	for _, vehicle in ipairs(CollectionService:GetTagged("Vehicle")) do
		table.insert(globalRaycastIgnore, vehicle)
	end
	for _, env in ipairs(CollectionService:GetTagged("EnvironmentIgnore")) do
		table.insert(globalRaycastIgnore, env)
	end
	
	terrainRaycastParams.FilterDescendantsInstances = globalRaycastIgnore
	bumperRaycastParams.FilterDescendantsInstances = globalRaycastIgnore
end

-- Update list when players join/leave, respawn, or vehicles spawn/despawn
local function SetupPlayerCharacterTracking(player)
	player.CharacterAdded:Connect(function()
		RefreshIgnoreList()
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	SetupPlayerCharacterTracking(player)
end
Players.PlayerAdded:Connect(SetupPlayerCharacterTracking)

Players.PlayerRemoving:Connect(RefreshIgnoreList)
CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(RefreshIgnoreList)
CollectionService:GetInstanceRemovedSignal("Vehicle"):Connect(RefreshIgnoreList)
RefreshIgnoreList()

-- Initialize the Input Listener
Input.Init(function() return activeMechs end)

local cameraConnection = nil

local function GetMechRoot(mechModel) return mechModel:FindFirstChild("Hip", true) or mechModel:FindFirstChild("Chassis", true) end

local function findMotor6D(parent, jointName)
	for _, descendant in ipairs(parent:GetDescendants()) do
		if descendant:IsA("Motor6D") and descendant.Name == jointName then
			return descendant
		end
	end
	return nil
end

local function GetSlotMotors(mechModel, baseMotorName)
	local motors = {}
	for _, desc in ipairs(mechModel:GetDescendants()) do
		if desc:IsA("Motor6D") and string.find(desc.Name, "^" .. baseMotorName) then
			table.insert(motors, { Motor = desc, BaseC0 = desc.C0 })
		end
	end
	return motors
end

local function ShouldBlockMech(hitInstance, surfaceNormal)
	local isDestructible, isForcedCollidable, currentNode = false, false, hitInstance

	while currentNode and currentNode ~= workspace do
		if CollectionService:HasTag(currentNode, "Destructible") then isDestructible = true end
		if currentNode:GetAttribute("IsCollidable") == true then isForcedCollidable = true end
		currentNode = currentNode.Parent
	end

	local isTree = string.find(string.lower(hitInstance.Name), "tree") ~= nil
	local isSolidObstacle = isForcedCollidable or isTree or (not isDestructible)

	-- 1. Solid obstacles (trees, forced collidables) ALWAYS block regardless of edge normals
	if isSolidObstacle then
		return true
	end

	-- 2. Standard terrain check (Y >= 0.5 is walkable floor/ramp)
	if surfaceNormal and surfaceNormal.Y >= 0.5 then 
		return false 
	end

	return true
end

local function HandleLocomotionChange(mechModel, newType)
	local mechData = activeMechs[mechModel]
	if not mechData then return end

	if mechData.Seat then mechData.WalkSpeed = mechData.Seat:GetAttribute("WalkSpeed") or 16 end

	if newType == "Crawler" or newType == "ChickenLegCrawler" then
		mechData.IsCrawling = true
		mechData.TargetStancePitch = math.rad(-75)
		for _, part in pairs(mechModel:GetDescendants()) do
			if part:IsA("BasePart") then
				local pNameLower = string.lower(part.Name)
				if string.find(pNameLower, "leg") or string.find(pNameLower, "calf") or string.find(pNameLower, "thigh") or string.find(pNameLower, "foot") then
					part.CanCollide = false
				end
			end
		end
		local crawlerScript = game:GetService("ReplicatedStorage").ModuleScripts.MechModules.Locomotion:FindFirstChild(newType)
		if crawlerScript then mechData.Locomotion = require(crawlerScript).new(mechModel) end

	elseif newType == "Bipedal" or newType == "ChickenLegBipedal" then
		mechData.IsCrawling = false
		mechData.IsLimping = false
		mechData.TargetStancePitch = 0

		for _, part in pairs(mechModel:GetDescendants()) do
			if part:IsA("BasePart") then
				local pNameLower = string.lower(tostring(part.Name))
				if string.find(pNameLower, "leg") or string.find(pNameLower, "calf") or string.find(pNameLower, "thigh") or string.find(pNameLower, "foot") then
					part.CanCollide = part:GetAttribute("OriginalCanCollide") or false
				end
			end
		end
		local bipedalScript = game:GetService("ReplicatedStorage").ModuleScripts.MechModules.Locomotion:FindFirstChild(newType)
		if bipedalScript then mechData.Locomotion = require(bipedalScript).new(mechModel) end
	end

	for _, ik in ipairs(mechModel:GetDescendants()) do
		if ik:IsA("IKControl") then
			local isLeft = string.find(string.lower(ik.Name), "left") or (ik.Parent and string.find(string.lower(ik.Parent.Name), "left"))
			local isRight = string.find(string.lower(ik.Name), "right") or (ik.Parent and string.find(string.lower(ik.Parent.Name), "right"))
			local isLeg = string.find(string.lower(ik.Parent.Name), "leg") or string.find(string.lower(ik.Parent.Name), "calf") or string.find(string.lower(ik.Parent.Name), "thigh") or string.find(string.lower(ik.Parent.Name), "foot")

			local leftLegDead = mechData.Seat:GetAttribute("LeftLegDead")
			local rightLegDead = mechData.Seat:GetAttribute("RightLegDead")

			if isLeg then
				if isLeft then ik.Enabled = not leftLegDead elseif isRight then ik.Enabled = not rightLegDead end
			end
		end
	end
end

local function setupMech(mechModel)
	mechModel:WaitForChild("Torso", 5)
	task.wait(0.5)

	if not mechOriginalParts[mechModel] then
		mechOriginalParts[mechModel] = {}
		-- If CameraYawBase is the mech's life part (Head carries no health),
		-- the HUD shows the labeled CameraYawBase block instead of the Head block.
		local camYawPart = mechModel:FindFirstChild("CameraYawBase")
		local headPart = mechModel:FindFirstChild("Head")
		local headReplacedByCamYaw = camYawPart and camYawPart:GetAttribute("MaxHealth") ~= nil
			and headPart ~= nil and headPart:GetAttribute("MaxHealth") == nil
		for uiName, partName in pairs(Config.UI_TO_PART_MAP) do
			if partName == "Head" and headReplacedByCamYaw then continue end
			if mechModel:FindFirstChild(partName) then mechOriginalParts[mechModel][partName] = true end
		end
		HUD.BuildArmorCache(mechModel)
	end

	local seat = mechModel:FindFirstChildWhichIsA("VehicleSeat", true)
	while not seat and mechModel.Parent do task.wait(0.2) seat = mechModel:FindFirstChildWhichIsA("VehicleSeat", true) end
	if not seat then return end

	local driveCore = mechModel:FindFirstChild("TargetGround", true)
	while not driveCore and mechModel.Parent do task.wait(0.2) driveCore = mechModel:FindFirstChild("TargetGround", true) end
	if not driveCore then return end

	local locoType = seat:GetAttribute("LocomotionType")
	local locomotionCartridge = nil
	if locoType then
		local locoScript = moduleScripts.MechModules.Locomotion:FindFirstChild(locoType)
		if locoScript then locomotionCartridge = require(locoScript).new(mechModel) end
	end

	local loadedWeapons = {}
	local weaponSlots = { RightWeapon = "RightWeaponType", LeftWeapon = "LeftWeaponType", RightShoulderWeapon = "RightShoulderType", LeftShoulderWeapon = "LeftShoulderType" }
	local weaponsFolder = moduleScripts.MechModules.Weapons

	for slotName, attr in pairs(weaponSlots) do
		local wType = seat:GetAttribute(attr)
		if wType then
			local wScript = weaponsFolder:FindFirstChild(wType)
			local wPart = mechModel:FindFirstChild(slotName, true)
			if wScript and wPart then loadedWeapons[slotName] = require(wScript).new(mechModel, wPart) end
		end
	end

	-- MISSING LINK #1: Rebuilding the Joints Cache
	local waist = mechModel:FindFirstChild("Waist", true)
	local neck = mechModel:FindFirstChild("Neck", true)
	local rShoulder = mechModel:FindFirstChild("RightShoulder", true)
	local lShoulder = mechModel:FindFirstChild("LeftShoulder", true)
	local lThigh = findMotor6D(mechModel, "LeftThigh")
	local rThigh = findMotor6D(mechModel, "RightThigh")
	local lKnee  = findMotor6D(mechModel, "LeftLegConn") or findMotor6D(mechModel, "LeftKnee")
	local rKnee  = findMotor6D(mechModel, "RightLegConn") or findMotor6D(mechModel, "RightKnee")
	local lCalf  = findMotor6D(mechModel, "LeftCalf")
	local rCalf  = findMotor6D(mechModel, "RightCalf")
	local lFoot  = findMotor6D(mechModel, "LeftFoot")
	local rFoot  = findMotor6D(mechModel, "RightFoot")

	local rightShoulderMotors = GetSlotMotors(mechModel, "RightShoulderWeaponMotor")
	local leftShoulderMotors = GetSlotMotors(mechModel, "LeftShoulderWeaponMotor")
	local rElbow, lElbow, camYawMotor = nil, nil, nil

	for _, desc in ipairs(mechModel:GetDescendants()) do
		if desc:IsA("Motor6D") then
			if desc.Name == "RightLowerArm" or desc.Name == "RightElbow" then rElbow = desc
			elseif desc.Name == "LeftLowerArm" or desc.Name == "LeftElbow" then lElbow = desc
			elseif desc.Name == "CameraYawBase" then camYawMotor = desc end
		end
	end

	if not mechModel.Parent then return end 

	activeMechs[mechModel] = {
		Driver = nil, Seat = seat, DriveCore = driveCore, Locomotion = locomotionCartridge, Weapons = loadedWeapons,
		WeaponGroups = {
			RightWeapon = seat:GetAttribute("RightWeaponGroup") or "Primary", LeftWeapon = seat:GetAttribute("LeftWeaponGroup") or "Secondary",
			RightShoulderWeapon = seat:GetAttribute("RightShoulderGroup") or "Tertiary", LeftShoulderWeapon = seat:GetAttribute("LeftShoulderGroup") or "Quaternary"
		},
		Torso = mechModel:FindFirstChild("Torso", true),
		Hitbox = mechModel:FindFirstChild("MechHitbox", true) or mechModel:FindFirstChild("Torso", true),
		WaistJoint = waist, NeckJoint = neck, RightShoulder = rShoulder, LeftShoulder = lShoulder,
		RightShoulderMotors = rightShoulderMotors, LeftShoulderMotors = leftShoulderMotors,
		RightElbow = rElbow, LeftElbow = lElbow, BaseRightElbowC0 = rElbow and rElbow.C0, BaseLeftElbowC0 = lElbow and lElbow.C0,
		CamPitchMotor = mechModel:FindFirstChild("CameraPitchMotor", true), CamYawMotor = camYawMotor,
		BaseCamPitchC0 = mechModel:FindFirstChild("CameraPitchMotor", true) and mechModel:FindFirstChild("CameraPitchMotor", true).C0, BaseCamYawC0 = camYawMotor and camYawMotor.C0,
		BaseWaistC0 = waist and waist.C0, BaseNeckC0 = neck and neck.C0, BaseRightC0 = rShoulder and rShoulder.C0, BaseLeftC0 = lShoulder and lShoulder.C0,
		LeftThigh = lThigh, BaseLeftThighC0 = lThigh and lThigh.C0, RightThigh = rThigh, BaseRightThighC0 = rThigh and rThigh.C0,
		LeftKnee = lKnee, BaseLeftKneeC0 = lKnee and lKnee.C0, RightKnee = rKnee, BaseRightKneeC0 = rKnee and rKnee.C0,
		LeftCalf = lCalf, BaseLeftCalfC0 = lCalf and lCalf.C0, RightCalf = rCalf, BaseRightCalfC0 = rCalf and rCalf.C0,
		LeftFootJoint = lFoot, BaseLeftFootC0 = lFoot and lFoot.C0, RightFootJoint = rFoot, BaseRightFootC0 = rFoot and rFoot.C0,
		BaseDriveCFrame = driveCore.CFrame,
		WalkSpeed = seat:GetAttribute("WalkSpeed") or 15, HoverOffset = seat:GetAttribute("HoverOffset") or 0,
		HipTurnSpeed = seat:GetAttribute("HipTurnSpeed") or 8, TorsoTurnSpeed = seat:GetAttribute("TorsoTurnSpeed") or 12,
		LimbsTurnSpeed = seat:GetAttribute("LimbsTurnSpeed") or 30, AimLagEnabled = seat:GetAttribute("AimLagEnabled") or false,
		AimLagSpeed = seat:GetAttribute("AimLagSpeed") or 12, MaxLimbYaw = math.rad(seat:GetAttribute("MaxLimbYaw") or 85),
		IsCrawling = (locoType == "Crawler" or locoType == "ChickenLegCrawler"), IsLimping = seat:GetAttribute("IsLimping") or false, IsStandingUp = seat:GetAttribute("StandingUp") or false,
		FallSpeed = seat:GetAttribute("FallSpeed") or 3, CurrentStancePitch = (locoType == "Crawler" or locoType == "ChickenLegCrawler") and math.rad(-75) or 0, TargetStancePitch = (locoType == "Crawler" or locoType == "ChickenLegCrawler") and math.rad(-75) or 0,
		CurrentTorsoYaw = 0, CurrentLimbsYaw = 0, CurrentLimbsPitch = 0, StaggerYaw = 0, StaggerPitch = 0, StaggerRoll = 0, StaggerPosition = Vector3.new(0,0,0),
		HasInitializedAim = false, LastNetworkSend = 0,
		
		TerrainNormal = Vector3.new(0, 1, 0),
		SuspensionY = driveCore.CFrame.Position.Y,
		VerticalVelocity = 0,
		CurrentSpeed = 0,
		CurrentHeading = driveCore.CFrame.LookVector,
		SprintStanceAlpha = 0,
		HipLocalOffset = (driveCore and GetMechRoot(mechModel)) and driveCore.CFrame:PointToObjectSpace(GetMechRoot(mechModel).Position) or Vector3.new(0, 3, 0),
	}

	local mechData = activeMechs[mechModel]
	mechData.FadeParts = {}
	local initialHead, initialTorso = mechModel:FindFirstChild("Head", true), mechData.Torso
	mechData.AimHeightOffset = (initialHead and initialTorso) and initialTorso.CFrame:PointToObjectSpace(initialHead.Position) or Vector3.new(0, 5, 0)

	for _, part in ipairs(mechModel:GetDescendants()) do if part:IsA("BasePart") then table.insert(mechData.FadeParts, part) end end

	-- IK ANTI-HIJACK LOCK
	for _, ik in pairs(mechModel:GetDescendants()) do
		if ik:IsA("IKControl") then
			local trueTarget = nil
			if string.find(ik.Name, "Left") or (ik.Target and string.find(ik.Target.Name, "Left")) then trueTarget = mechModel:FindFirstChild("TargetLeft", true)
			elseif string.find(ik.Name, "Right") or (ik.Target and string.find(ik.Target.Name, "Right")) then trueTarget = mechModel:FindFirstChild("TargetRight", true) end

			if trueTarget then
				ik.Target = trueTarget
				ik:GetPropertyChangedSignal("Target"):Connect(function() if ik.Target ~= trueTarget then ik.Target = trueTarget end end)
			end
		end
	end

	seat:GetAttributeChangedSignal("IsLimping"):Connect(function() mechData.IsLimping = seat:GetAttribute("IsLimping") or false end)
	seat:GetAttributeChangedSignal("StandingUp"):Connect(function()
		mechData.IsStandingUp = seat:GetAttribute("StandingUp") or false
		if mechData.IsStandingUp == false then
			mechData.BaseDriveCFrame = mechData.DriveCore.CFrame 
			mechData.SuspensionY = mechData.DriveCore.CFrame.Position.Y 
			mechData.TerrainNormal = Vector3.new(0, 1, 0)
			mechData.VerticalVelocity = 0 
			mechData.CurrentStancePitch = mechData.IsCrawling and math.rad(-75) or 0 
		end
	end)
	seat:GetAttributeChangedSignal("LocomotionType"):Connect(function() HandleLocomotionChange(mechModel, seat:GetAttribute("LocomotionType")) end)

	seat.AttributeChanged:Connect(function(attrName)
		if string.find(attrName, "Group") and activeMechs[mechModel] then
			local groups = activeMechs[mechModel].WeaponGroups
			if attrName == "RightWeaponGroup" then groups.RightWeapon = seat:GetAttribute("RightWeaponGroup") or "Primary"
			elseif attrName == "LeftWeaponGroup" then groups.LeftWeapon = seat:GetAttribute("LeftWeaponGroup") or "Secondary"
			elseif attrName == "RightShoulderGroup" then groups.RightShoulderWeapon = seat:GetAttribute("RightShoulderGroup") or "Tertiary"
			elseif attrName == "LeftShoulderGroup" then groups.LeftShoulderWeapon = seat:GetAttribute("LeftShoulderGroup") or "Quaternary" end
		end
	end)

	-- MISSING LINK #2: Camera Binding & UI Setup
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant
		if occupant then
			local driver = Players:GetPlayerFromCharacter(occupant.Parent)
			mechData.Driver = driver
			if driver then
				local playerTeam = driver.Team and driver.Team.Name
				local teamGroup = (playerTeam == "Blue Team") and "TeamAMembers" or "TeamBMembers"
				
				-- Use the server-replicated DriveCFrame attribute when available.
				-- The local DriveCore.CFrame can be STALE on this client (TargetGround is
				-- anchored, so only the server's writes replicate), which made the hip
				-- snap to an old direction whenever ownership switched (hijack).
				local currentCFrame = mechModel:GetAttribute("DriveCFrame") or mechData.DriveCore.CFrame
				local flatRight = Vector3.new(currentCFrame.RightVector.X, 0, currentCFrame.RightVector.Z)
				flatRight = flatRight.Magnitude > 0.01 and flatRight.Unit or Vector3.new(1,0,0)
				local trueForward = Vector3.new(0, 1, 0):Cross(flatRight).Unit
				-- Sync current stance pitch immediately to target pitch so it doesn't start at 0
				mechData.CurrentStancePitch = mechData.TargetStancePitch or (mechData.IsCrawling and math.rad(-75) or 0)

				-- Bake the stance pitch into the initial CFrame so it stays grounded on frame 1
				mechData.BaseDriveCFrame = CFrame.new(currentCFrame.Position) * CFrame.lookAt(Vector3.zero, trueForward) * CFrame.Angles(mechData.CurrentStancePitch, 0, 0)

				-- Re-sync the movement state captured at setup time. Without this, the
				-- Heartbeat loop lerps the hip back toward the stale heading/height
				-- from before this client ever saw the mech being driven.
				mechData.CurrentHeading = trueForward
				mechData.SuspensionY = currentCFrame.Position.Y

				if driver == localPlayer then
					bumperRaycastParams.CollisionGroup = teamGroup
					
					if driveCore then driveCore.CollisionGroup = teamGroup end
					local hip = GetMechRoot(mechModel)
					if hip then hip.CollisionGroup = teamGroup end
					if mechData.Hitbox then
						mechData.Hitbox.CollisionGroup = teamGroup
					end
					
					local humanoid = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
					local cam = workspace.CurrentCamera
					if cameraConnection then cameraConnection:Disconnect() cameraConnection = nil end

					cameraConnection = RunService.RenderStepped:Connect(function(deltaTime)
						if not humanoid or humanoid.Health <= 0 then return end
						local zoomDistance = (cam.CFrame.Position - cam.Focus.Position).Magnitude
						humanoid.CameraOffset = zoomDistance < 1 and Vector3.zero or (mechData.Seat:GetAttribute("CamOffset") or Vector3.new(0, 5, 0))

						local targetFOV = Input.isSprinting and 85 or 70
						cam.FieldOfView = cam.FieldOfView + (targetFOV - cam.FieldOfView) * math.clamp(4 * deltaTime, 0, 1)
					end)

					local CursorGui = localPlayer.PlayerGui:FindFirstChild("CursorGui")
					if CursorGui then
						local scaleFactor = cam.ViewportSize.Y / Config.BASE_SCREEN_HEIGHT
						local crosshairUI = CursorGui:FindFirstChild("Crosshair")
						if crosshairUI then
							crosshairUI.Size = UDim2.fromOffset(math.round(40 * scaleFactor), math.round(40 * scaleFactor))
							crosshairUI.Visible = (mechModel:FindFirstChild("Head", true) ~= nil)
						end
						local secondaryUI = CursorGui:FindFirstChild("SecondaryReticle")
						if secondaryUI then secondaryUI.Size = UDim2.fromOffset(math.round(30 * scaleFactor), math.round(30 * scaleFactor)) end
					end

					Input.BindPilotControls(mechData)
					HUD.MountMechHUD(mechModel, mechData, mechOriginalParts)
				end
			end
		else
			if mechData.Driver == localPlayer then
				local humanoid = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
				if cameraConnection then cameraConnection:Disconnect() cameraConnection = nil end
				if humanoid then humanoid.CameraOffset = Vector3.zero end
				workspace.CurrentCamera.FieldOfView = 70

				Input.UnbindPilotControls()
				HUD.UnmountMechHUD()

				if mechData.FadeParts then
					for _, part in ipairs(mechData.FadeParts) do part.LocalTransparencyModifier = 0 end
				end
				mechData.IsFinishingExit = true
			end
			mechData.Driver = nil
		end
	end)

	if seat.Occupant then mechData.Driver = Players:GetPlayerFromCharacter(seat.Occupant.Parent) end

	mechModel.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			HUD.FlagArmorCacheDirty(mechModel)
			descendant:GetAttributeChangedSignal("CurrentHealth"):Connect(function() HUD.FlagArmorCacheDirty(mechModel) end)
		end
	end)
	mechModel.DescendantRemoving:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			HUD.FlagArmorCacheDirty(mechModel)
			if descendant.Name == "Head" and activeMechs[mechModel] and activeMechs[mechModel].Driver == localPlayer then
				local CursorGui = localPlayer.PlayerGui:FindFirstChild("CursorGui")
				if CursorGui and CursorGui:FindFirstChild("Crosshair") then CursorGui.Crosshair.Visible = false end
			end
		end
	end)

	for _, descendant in ipairs(mechModel:GetDescendants()) do
		if descendant:IsA("BasePart") then descendant:GetAttributeChangedSignal("CurrentHealth"):Connect(function() HUD.FlagArmorCacheDirty(mechModel) end) end
	end
end

for _, mech in pairs(CollectionService:GetTagged("Vehicle")) do task.spawn(setupMech, mech) end
CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(function(mechModel) task.spawn(setupMech, mechModel) end)
CollectionService:GetInstanceRemovedSignal("Vehicle"):Connect(function(mechModel) 
	if activeMechs[mechModel] and activeMechs[mechModel].Driver == localPlayer then
		if cameraConnection then cameraConnection:Disconnect() end
		Input.UnbindPilotControls()
		HUD.UnmountMechHUD()
	end
	activeMechs[mechModel] = nil 
end)

-- MISSING LINK #3: THE MASTER RENDER LOOP
RunService.PreRender:Connect(function(deltaTime)
	local currentTime = os.clock()
	local mousePos = UserInputService:GetMouseLocation()

	for mechModel, mechData in pairs(activeMechs) do
		local targetPos = Vector3.new()
		local isAiming = false

		mechData.StaggerPitch = Aim.LerpAngle(mechData.StaggerPitch, 0, 5 * deltaTime)
		mechData.StaggerRoll = Aim.LerpAngle(mechData.StaggerRoll, 0, 5 * deltaTime)
		mechData.StaggerYaw = Aim.LerpAngle(mechData.StaggerYaw, 0, 5 * deltaTime)
		mechData.StaggerPosition = mechData.StaggerPosition:Lerp(Vector3.zero, 5 * deltaTime)

		if mechData.Driver == localPlayer then
			if mechData.WantsManualUnstuck then
				mechData.WantsManualUnstuck = false
				local torso = mechData.Torso
				if torso and torso.AssemblyLinearVelocity.Magnitude < 2 and (currentTime - (mechData.LastManualHopTime or 0) >= 2.5) then
					mechData.LastManualHopTime = currentTime
					local hopTrajectory = Vector3.new(0, 1, 0) + (torso.CFrame.LookVector * -0.5)
					torso:ApplyImpulse(hopTrajectory.Unit * (torso.AssemblyMass * 40))
				end
			end

			local isMoving = (mechData.Seat.Throttle ~= 0 or mechData.Seat.Steer ~= 0)
			local limpShakeX, limpShakeY = 0, 0
			local scaleFactor = workspace.CurrentCamera.ViewportSize.Y / Config.BASE_SCREEN_HEIGHT

			if mechData.IsLimping and isMoving then
				local timeOffset = currentTime * 1.5
				limpShakeX = math.noise(timeOffset, 0, 0) * (55 * scaleFactor) 
				limpShakeY = math.noise(timeOffset + 100, 0, 0) * (25 * scaleFactor) 
			end

			local scaledStaggerPower = 800 * scaleFactor
			local punchDeltaX = (mechData.StaggerYaw * scaledStaggerPower * Config.AIM_PUNCH_MULTIPLIER) + limpShakeX
			local punchDeltaY = (mechData.StaggerPitch * -scaledStaggerPower * Config.AIM_PUNCH_MULTIPLIER) + limpShakeY
			local punchedX = mousePos.X + punchDeltaX
			local punchedY = mousePos.Y + punchDeltaY

			local MechWeaponHUD = localPlayer.PlayerGui:FindFirstChild("MechWeaponHUD")
			local CursorGui = localPlayer.PlayerGui:FindFirstChild("CursorGui")

			if MechWeaponHUD and MechWeaponHUD.Enabled then
				local hudFrame = MechWeaponHUD:FindFirstChild("Frame")
				local isAnyReloading = false
				if hudFrame then
					local w = mechData.Weapons or {}
					local g = mechData.WeaponGroups or {}
					local s = mechData.Seat
					local r = HUD.UpdateWeaponSlotDisplay(hudFrame:FindFirstChild("RWeaponFrame"), "RWeaponLabel", "RWeaponUI", w.RightWeapon, g.RightWeapon or "Primary", s:GetAttribute("RightWeaponType"))
					local l = HUD.UpdateWeaponSlotDisplay(hudFrame:FindFirstChild("LWeaponFrame"), "LWeaponLabel", "LWeaponUI", w.LeftWeapon, g.LeftWeapon or "Secondary", s:GetAttribute("LeftWeaponType"))
					local rs = HUD.UpdateWeaponSlotDisplay(hudFrame:FindFirstChild("RShoulderFrame"), "RShoulderLabel", "RShoulderUI", w.RightShoulderWeapon, g.RightShoulderWeapon or "Tertiary", s:GetAttribute("RightShoulderType"))
					local ls = HUD.UpdateWeaponSlotDisplay(hudFrame:FindFirstChild("LShoulderFrame"), "LShoulderLabel", "LShoulderUI", w.LeftShoulderWeapon, g.LeftShoulderWeapon or "Quaternary", s:GetAttribute("LeftShoulderType"))
					isAnyReloading = r or l or rs or ls
				end

				if CursorGui and CursorGui:FindFirstChild("Crosshair") then
					local crosshair = CursorGui.Crosshair
					crosshair.Position = isMobile and UDim2.new(0.5, 0, 0.5, 0) or UDim2.fromOffset(punchedX, punchedY)
					crosshair.Image = isAnyReloading and Config.RELOADING_ICON or Config.MOUSE_ICON
					UserInputService.MouseIconEnabled = false
				end

				if CursorGui and CursorGui:FindFirstChild("SecondaryReticle") then
					local secondary = CursorGui.SecondaryReticle
					if mechData.IsAiming and mechData.AimLagEnabled and (mechModel:FindFirstChild("Head", true) ~= nil) and mechData.ReticleProjectionPos then
						local screenPos = workspace.CurrentCamera:WorldToViewportPoint(mechData.ReticleProjectionPos)
						if screenPos.Z > 0 then
							secondary.Visible = true
							secondary.Position = UDim2.fromOffset(screenPos.X, screenPos.Y)
						else
							secondary.Visible = false
						end
					else
						secondary.Visible = false
					end
				end
			end

			local MechHealthHUD = localPlayer.PlayerGui:FindFirstChild("MechHealthHUD")
			if MechHealthHUD and MechHealthHUD.Enabled then
				local activeStage = MechHealthHUD:FindFirstChild("ActiveUITemplate")
				if activeStage then HUD.UpdatePaperDollColors(mechModel, activeStage) end
			end

			if localPlayer.Character then
				local equippedTool = localPlayer.Character:FindFirstChildOfClass("Tool")
				if equippedTool and equippedTool.Name == Config.TARGET_TOOL_NAME then isAiming = true end
			end

			local camPos = workspace.CurrentCamera.CFrame.Position
			if mechData.FadeParts then
				for _, part in ipairs(mechData.FadeParts) do
					local dist = (camPos - part.Position).Magnitude
					part.LocalTransparencyModifier = math.clamp((18 - dist) / 8, 0, 0.9)
				end
			end

			if isAiming then
				targetPos = Aim.CalculateAimTarget(mechModel, mechData, isMobile, punchDeltaX, punchDeltaY, punchedX, punchedY, aimRaycastParams, cachedAimIgnoreList, localPlayer, mechData.SmoothedTargetPos, deltaTime)
				mechData.SmoothedTargetPos = targetPos
			end
		else
			local networkTarget = mechModel:GetAttribute("AimTarget")
			if networkTarget and networkTarget ~= Vector3.zero then
				targetPos = networkTarget
				isAiming = true
			end
		end

		if (mechData.Driver == localPlayer or mechData.IsFinishingExit) and isAiming then
			local toTarget = targetPos - mechData.DriveCore.Position
			local flatDistance = Vector2.new(toTarget.X, toTarget.Z).Magnitude

			local targetTorsoYaw = mechData.CurrentTorsoYaw
			local targetLimbsYaw = mechData.CurrentLimbsYaw

			if flatDistance > 5 then
				targetTorsoYaw = math.atan2(-toTarget.X, -toTarget.Z)
				local upperToTarget = targetPos - mechData.Torso.Position
				targetLimbsYaw = math.atan2(-upperToTarget.X, -upperToTarget.Z)
			end

			local headPart = mechModel:FindFirstChild("Head", true)
			local aimOrigin = headPart and headPart.Position or (mechData.Torso and mechData.Torso.CFrame:PointToWorldSpace(mechData.AimHeightOffset) or (mechData.Torso.Position + Vector3.new(0,5,0)))

			local upperToTarget = targetPos - aimOrigin
			local flatDist = math.sqrt(upperToTarget.X^2 + upperToTarget.Z^2)
			local rawPitch = math.atan2(upperToTarget.Y, flatDist)

			if (mechData.Driver == localPlayer) and (upperToTarget.Magnitude < 20) then
				local intensity = (20 - upperToTarget.Magnitude) / 20
				local camPitch = math.asin(math.clamp(workspace.CurrentCamera.CFrame.LookVector.Y, -1, 1))
				rawPitch = rawPitch + (camPitch - rawPitch) * (intensity ^ 0.5) 
				local lookDirection = (CFrame.Angles(0, targetLimbsYaw, 0) * CFrame.Angles(rawPitch, 0, 0)).LookVector
				targetPos = mechData.Torso.Position + (lookDirection * 1000)
			end

			local targetLimbsPitch = math.clamp(rawPitch, math.rad(-89), math.rad(80))

			if not mechData.HasInitializedAim then
				if mechData.AimLagEnabled and mechData.Torso then
					local torsoForward = mechData.Torso.CFrame.LookVector
					local chassisYaw = math.atan2(-torsoForward.X, -torsoForward.Z)
					mechData.CurrentTorsoYaw, mechData.CurrentLimbsYaw, mechData.CurrentLimbsPitch = chassisYaw, chassisYaw, 0
				else
					mechData.CurrentTorsoYaw, mechData.CurrentLimbsYaw, mechData.CurrentLimbsPitch = targetTorsoYaw, targetLimbsYaw, targetLimbsPitch
				end
				mechData.HasInitializedAim = true
			end

			if mechData.AimLagEnabled then
				mechData.CurrentTorsoYaw = Aim.RotateTowardsAngle(mechData.CurrentTorsoYaw, targetTorsoYaw, mechData.TorsoTurnSpeed * deltaTime)
				mechData.CurrentLimbsYaw = Aim.RotateTowardsAngle(mechData.CurrentLimbsYaw, targetLimbsYaw, mechData.AimLagSpeed * deltaTime)
				mechData.CurrentLimbsPitch = Aim.RotateTowardsAngle(mechData.CurrentLimbsPitch, targetLimbsPitch, mechData.AimLagSpeed * deltaTime)
			else
				mechData.CurrentTorsoYaw = Aim.LerpAngle(mechData.CurrentTorsoYaw, targetTorsoYaw, mechData.TorsoTurnSpeed * deltaTime)
				mechData.CurrentLimbsYaw = Aim.LerpAngle(mechData.CurrentLimbsYaw, targetLimbsYaw, mechData.LimbsTurnSpeed * deltaTime)
				mechData.CurrentLimbsPitch = Aim.LerpAngle(mechData.CurrentLimbsPitch, targetLimbsPitch, mechData.LimbsTurnSpeed * deltaTime)
			end

			mechData.SprintStanceAlpha = (mechData.SprintStanceAlpha or 0) + ((Input.isSprinting and 1 or 0) - (mechData.SprintStanceAlpha or 0)) * math.clamp(5 * deltaTime, 0, 1)

			local flatRight = Vector3.new(mechData.BaseDriveCFrame.RightVector.X, 0, mechData.BaseDriveCFrame.RightVector.Z)
			flatRight = flatRight.Magnitude < 0.01 and Vector3.new(1,0,0) or flatRight.Unit
			local trueForward = Vector3.new(0, 1, 0):Cross(flatRight).Unit
			local hipYaw = math.atan2(-trueForward.X, -trueForward.Z)

			local rawTorsoOffset = (mechData.Seat:GetAttribute("LocomotionType") == "Wheeled") and (mechData.CurrentTorsoYaw - hipYaw) or (hipYaw - mechData.CurrentTorsoYaw)
			local torsoYawOffset = math.atan2(math.sin(rawTorsoOffset), math.cos(rawTorsoOffset))

			if mechData.WaistJoint and mechData.BaseWaistC0 then mechData.WaistJoint.C0 = mechData.BaseWaistC0 * CFrame.Angles(0, torsoYawOffset, 0) end

			local rawUpperOffset = mechData.CurrentLimbsYaw - mechData.CurrentTorsoYaw
			local upperYawOffset = math.clamp(math.atan2(math.sin(rawUpperOffset), math.cos(rawUpperOffset)), -mechData.MaxLimbYaw, mechData.MaxLimbYaw)
			mechData.CurrentLimbsYaw = mechData.CurrentTorsoYaw + upperYawOffset

			local actualStancePitch = math.asin(math.clamp(mechData.BaseDriveCFrame.LookVector.Y, -1, 1))
			local dynamicPitchComp = -actualStancePitch * math.cos(torsoYawOffset)

			if mechData.NeckJoint and mechData.BaseNeckC0 then mechData.NeckJoint.C0 = mechData.BaseNeckC0 * CFrame.Angles(mechData.CurrentLimbsPitch + dynamicPitchComp, upperYawOffset, 0) end
			if mechData.CamYawMotor and mechData.BaseCamYawC0 then mechData.CamYawMotor.C0 = mechData.BaseCamYawC0 * CFrame.Angles(0, upperYawOffset, 0) end
			if mechData.CamPitchMotor and mechData.BaseCamPitchC0 then mechData.CamPitchMotor.C0 = mechData.BaseCamPitchC0 * CFrame.Angles(mechData.CurrentLimbsPitch + dynamicPitchComp, 0, 0) end

			local sprintAlpha = mechData.SprintStanceAlpha
			local armRot = CFrame.Angles((mechData.CurrentLimbsPitch + dynamicPitchComp) * (1 - sprintAlpha) + (math.rad(25) * sprintAlpha), upperYawOffset * (1 - sprintAlpha), 0)

			if mechData.RightShoulder and mechData.BaseRightC0 then mechData.RightShoulder.C0 = mechData.BaseRightC0 * armRot end
			if mechData.LeftShoulder and mechData.BaseLeftC0 then mechData.LeftShoulder.C0 = mechData.BaseLeftC0 * armRot end
			if mechData.RightElbow and mechData.BaseRightElbowC0 then mechData.RightElbow.C0 = mechData.BaseRightElbowC0 * CFrame.Angles(math.rad(25) * sprintAlpha, 0, 0) end
			if mechData.LeftElbow and mechData.BaseLeftElbowC0 then mechData.LeftElbow.C0 = mechData.BaseLeftElbowC0 * CFrame.Angles(math.rad(25) * sprintAlpha, 0, 0) end

			if mechData.RightShoulderMotors then for _, item in ipairs(mechData.RightShoulderMotors) do if item.Motor then item.Motor.C0 = item.BaseC0 * armRot end end end
			if mechData.LeftShoulderMotors then for _, item in ipairs(mechData.LeftShoulderMotors) do if item.Motor then item.Motor.C0 = item.BaseC0 * armRot end end end

			if mechData.AimLagEnabled then
				local physicalAimDir = (CFrame.Angles(0, mechData.CurrentLimbsYaw, 0) * CFrame.Angles(mechData.CurrentLimbsPitch, 0, 0)).LookVector
				mechData.ReticleProjectionPos = aimOrigin + (physicalAimDir * (targetPos - aimOrigin).Magnitude)
				local aimHit = workspace:Raycast(aimOrigin, physicalAimDir * 10000, aimRaycastParams)
				mechData.TargetPos = aimHit and aimHit.Position or (aimOrigin + (physicalAimDir * 10000))
			else
				mechData.ReticleProjectionPos = targetPos
				mechData.TargetPos = targetPos
			end
			mechData.IsAiming = true
		else
			mechData.IsAiming = false
			mechData.HasInitializedAim = false
			mechData.ReticleProjectionPos = nil
		end
	end
end)

-- MISSING LINK #4: THE MASTER HEARTBEAT LOOP
RunService.Heartbeat:Connect(function(deltaTime)
	local currentTime = os.clock()
	for mechModel, mechData in pairs(activeMechs) do
		if mechData.Driver == localPlayer or mechData.IsFinishingExit then
			if not mechData.IsStandingUp then
				if not mechData.BaseDriveCFrame then mechData.BaseDriveCFrame = mechData.DriveCore.CFrame end

				if not mechData.SuspensionY then mechData.SuspensionY = mechData.BaseDriveCFrame.Position.Y end

				local throttle, steer = mechData.Seat.Throttle, mechData.Seat.Steer
				local camRight = workspace.CurrentCamera.CFrame.RightVector
				local flatForward = Vector3.new(0, 1, 0):Cross(camRight).Unit
				local flatRight = Vector3.new(camRight.X, 0, camRight.Z).Unit

				local moveDir = (flatForward * throttle) + (flatRight * steer)
				if moveDir.Magnitude > 0 then moveDir = moveDir.Unit mechData.CurrentHeading = moveDir end
				if not mechData.CurrentHeading then mechData.CurrentHeading = mechData.BaseDriveCFrame.LookVector end

				local moveVelocity, isMoving = Vector3.zero, false

				if mechData.IsCrawling then
					local fr = Vector3.new(mechData.BaseDriveCFrame.RightVector.X, 0, mechData.BaseDriveCFrame.RightVector.Z)
					local trueForward = Vector3.new(0, 1, 0):Cross(fr.Magnitude > 0.01 and fr.Unit or Vector3.new(1,0,0)).Unit
					mechData.WalkSpeed = mechData.Seat:GetAttribute("WalkSpeed") or 0
					
					local activeTurnSpeed = (mechData.HipTurnSpeed or 8) * 0.2
					local yawDelta = (mechData.WalkSpeed > 0) and (-steer * activeTurnSpeed * deltaTime) or 0
					local newForward = (CFrame.lookAt(Vector3.zero, trueForward) * CFrame.Angles(0, yawDelta, 0)).LookVector

					mechData.CurrentHeading = newForward
					moveVelocity = trueForward * throttle * mechData.WalkSpeed * deltaTime
					isMoving = (mechData.WalkSpeed > 0) and (throttle ~= 0 or steer ~= 0)
				else
					if Input.isSprinting then
						moveDir = (flatForward + (flatRight * steer * 0.8)).Unit
						mechData.CurrentHeading = moveDir -- Force heading toward camera/sprint direction
					end
					local baseSpeed = mechData.Seat:GetAttribute("WalkSpeed") or 15
					local targetSpeed = Input.isSprinting and (baseSpeed * (mechData.Seat:GetAttribute("SprintMultiplier") or 1.6)) or baseSpeed
					mechData.CurrentSpeed = (mechData.CurrentSpeed or baseSpeed) + (targetSpeed - (mechData.CurrentSpeed or baseSpeed)) * math.clamp(((targetSpeed > (mechData.CurrentSpeed or baseSpeed)) and 2.5 or 4.5) * deltaTime, 0, 1)

					if mechData.IsWindingUp then
						moveVelocity, isMoving = Vector3.zero, false
					elseif mechData.IsJumping and mechData.JumpHorizontalVelocity then
						moveVelocity, isMoving = mechData.JumpHorizontalVelocity * deltaTime, true
					elseif mechData.IsSliding and mechData.SlideInitialVelocity then
						local progress = math.clamp((os.clock() - (mechData.SlideStartTime or os.clock())) / math.max(0.05, mechData.Seat:GetAttribute("SlideDuration") or 0.75), 0, 1)
						local friction = 1 - (progress * progress)
						moveVelocity = ((mechData.SlideInitialVelocity * friction) + (moveDir * mechData.CurrentSpeed * (1 - friction))) * deltaTime
						isMoving = true
						if progress >= 1 then mechData.IsSliding = false end
					else
						moveVelocity, isMoving = moveDir * mechData.CurrentSpeed * deltaTime, (mechData.CurrentSpeed > 0.1 and moveDir.Magnitude > 0)
					end
				end

				if not mechData.BaseSize then mechData.BaseSize = mechModel:GetExtentsSize() end
				local customHeight, customRadius = mechModel:GetAttribute("CustomBumperHeight"), mechModel:GetAttribute("CustomBumperRadius")
				local mechRadius = (type(customRadius) == "number") and customRadius or ((math.max(mechData.BaseSize.X, mechData.BaseSize.Z) / 2) * 1.25)
				local groundY = mechData.SuspensionY or mechData.BaseDriveCFrame.Position.Y
				local myHip = GetMechRoot(mechModel)
				local universalCenter = myHip and myHip.Position or (mechData.BaseDriveCFrame.Position + Vector3.new(0, 3, 0))

				if universalCenter.Y < groundY + mechRadius + 0.5 then universalCenter = Vector3.new(universalCenter.X, groundY + mechRadius + 0.5, universalCenter.Z) end
				local nextPosition = mechData.BaseDriveCFrame.Position + moveVelocity
				local verticalOffset = (myHip and myHip.Position.Y - mechData.BaseDriveCFrame.Position.Y) or 3
				local sensorOrigin = nextPosition + Vector3.new(0, verticalOffset, 0)
				if sensorOrigin.Y < groundY + mechRadius + 0.5 then 
					sensorOrigin = Vector3.new(sensorOrigin.X, groundY + mechRadius + 0.5, sensorOrigin.Z) 
				end

				--table.clear(cachedBumperIgnoreList)
				--table.insert(cachedBumperIgnoreList, mechModel)
				--for _, player in ipairs(Players:GetPlayers()) do if player.Character then table.insert(cachedBumperIgnoreList, player.Character) end end
				-- Prevent Whiskers from treating enemy mechs as map walls
				--for _, v in ipairs(CollectionService:GetTagged("Vehicle")) do 
				--	if v ~= mechModel then
				--		table.insert(cachedBumperIgnoreList, v) 
				--	end
				--end

				--bumperRaycastParams.FilterDescendantsInstances = globalRaycastIgnore

				-- MECH VS MECH COLLISION
				local myRadius = mechData.Hitbox and (mechData.Hitbox.Size.Z / 2) + 0.5 or 5
				for _, enemyMech in ipairs(CollectionService:GetTagged("Vehicle")) do
					if enemyMech ~= mechModel then
						local enemyCFrame = enemyMech:GetAttribute("DriveCFrame")
						if enemyCFrame then
							local enemyData = activeMechs[enemyMech]
							local enemyHitbox = (enemyData and enemyData.Hitbox) or enemyMech:FindFirstChild("MechHitbox", true) or enemyMech:FindFirstChild("Torso", true)
							local eRadius = enemyHitbox and (enemyHitbox.Size.Z / 2) + 0.5 or (mechRadius * 0.5)
							local eHip = GetMechRoot(enemyMech)
							local eCenter = eHip and eHip.Position or (enemyCFrame.Position + Vector3.new(0, 3, 0))

							local toEnemy = Vector3.new(eCenter.X - universalCenter.X, 0, eCenter.Z - universalCenter.Z)
							local dist = toEnemy.Magnitude
							if dist < (myRadius + eRadius) and dist > 0.001 then
								local overlap = (myRadius + eRadius) - dist
								local pushDir = -toEnemy.Unit

								-- ANTI-JITTER: ram requests and the local separation prediction
								-- run on the same 0.1s cadence as the server's ram handler, and
								-- the local push matches half of the server's per-event push.
								-- The old per-frame accumulation over-separated the mechs, which
								-- the server then pulled back, causing oscillation.
								if currentTime - (mechData.LastRamSend or 0) >= 0.1 or mechData.LastRamEnemy ~= enemyMech then
									mechData.LastRamSend = currentTime
									mechData.LastRamEnemy = enemyMech
									MechRamEvent:FireServer(enemyMech, overlap, pushDir)

									if mechData.Seat:GetAttribute("LocomotionType") ~= "Wheeled" then
										local selfPush = math.clamp(overlap, 0.6, 2.0)
										mechData.BaseDriveCFrame = mechData.BaseDriveCFrame + (pushDir * selfPush)
										universalCenter = universalCenter + (pushDir * selfPush)
									end
								end
							end
						end
					end
				end

				sensorOrigin = universalCenter

				-- Only run heavy bumper raycasts and terrain checks if the mech is actually moving
				local isStationary = not isMoving and not mechData.IsFalling and math.abs(mechData.VerticalVelocity or 0) < 0.1

				if not isStationary then
					-- Predict where the sensor will be after moveVelocity
					local predictedSensorOrigin = sensorOrigin + moveVelocity
					
					-- WHISKERS (Anti-Clip)
					for _, deg in ipairs({0, 45, 90, 135, 180, 225, 270, 315}) do
						local dir = Vector3.new(math.cos(math.rad(deg)), 0, math.sin(math.rad(deg)))
						local rayStart = sensorOrigin - (dir * 2)
						local rayDistance = myRadius + 2
						local hit = workspace:Raycast(rayStart, dir * rayDistance, bumperRaycastParams)

						if hit and ShouldBlockMech(hit.Instance, hit.Normal) then
							local penDepth = myRadius - (hit.Position - sensorOrigin).Magnitude
							if penDepth > 0 then
								local flatNorm = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
								local pushNorm = flatNorm.Magnitude > 0.001 and flatNorm.Unit or -dir

								moveVelocity = moveVelocity + (pushNorm * penDepth)
								predictedSensorOrigin = predictedSensorOrigin + (pushNorm * penDepth)
							end
							print("OI! Hit part:", hit.Instance:GetFullName(), "| Parent:", hit.Instance.Parent.Name)
						end
					end

					-- SLIDE BLOCKING (Strictly horizontal to prevent climbing/vertical pushes)
					local flatVelocity = Vector3.new(moveVelocity.X, 0, moveVelocity.Z)
					if flatVelocity.Magnitude > 0.001 then
						local bumperHit = workspace:Spherecast(sensorOrigin, myRadius, flatVelocity.Unit * (flatVelocity.Magnitude + 1.5), bumperRaycastParams)
						if bumperHit and ShouldBlockMech(bumperHit.Instance, bumperHit.Normal) then
							local flatNorm = Vector3.new(bumperHit.Normal.X, 0, bumperHit.Normal.Z)
							if flatNorm.Magnitude > 0.001 then
								local dot = moveVelocity:Dot(flatNorm.Unit)
								if dot < 0 then moveVelocity = moveVelocity - (flatNorm.Unit * dot) end
							else
								-- Edge fallback: If hit normal has no horizontal vector, strip forward velocity directly
								local dot = moveVelocity:Dot(flatVelocity.Unit)
								if dot > 0 then moveVelocity = moveVelocity - (flatVelocity.Unit * dot) end
								print("AY!")	
							end
						end
					end
					
					
					
					
				end
				
				-- Recalculate nextPosition with corrected moveVelocity
				nextPosition = mechData.BaseDriveCFrame.Position + moveVelocity
			
				
				-- Clamp BaseDriveCFrame if physical chassis is held back by physics/barriers
				local physicalRoot = GetMechRoot(mechModel)
				if physicalRoot then
					-- BaseDriveCFrame already contains CurrentStancePitch, so we use it directly
					local expectedHipOffsetWorld = mechData.BaseDriveCFrame:VectorToWorldSpace(mechData.HipLocalOffset)
					local physicalDriveCorePos = physicalRoot.Position - expectedHipOffsetWorld

					-- 2. Flatten for the X/Z distance check
					local flatPhysicalPos = Vector3.new(physicalDriveCorePos.X, mechData.BaseDriveCFrame.Position.Y, physicalDriveCorePos.Z)
					local offset = (nextPosition - flatPhysicalPos)

					-- If script position drifts more than 3 studs ahead of physical body, pull it back
					if offset.Magnitude > 3 then
						nextPosition = flatPhysicalPos + (offset.Unit * 3)
					end
				end
				
				-- TERRAIN RAYCAST

				local rayOrigin = nextPosition + Vector3.new(0, 15, 0)
				local fallVel = math.abs(mechData.VerticalVelocity or 0)
				local rayResult, pierceCount = nil, 0
				while pierceCount < 3 do
					rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -(30 + (fallVel * deltaTime)), 0), terrainRaycastParams)
					-- If it hits a steep wall (Normal.Y < 0.3), temporarily ignore the wall and re-cast
					if rayResult and rayResult.Normal.Y < 0.3 then
						table.clear(cachedTerrainIgnoreList)
						table.insert(cachedTerrainIgnoreList, rayResult.Instance)
						for _, obj in ipairs(globalRaycastIgnore) do 
							table.insert(cachedTerrainIgnoreList, obj) 
						end
						pierceCount += 1
					else 
						break 
					end
				end

				local slideComp = (mechData.IsSliding and mechData.SlideStartTime) and (2.5 * (1 - math.clamp((os.clock() - mechData.SlideStartTime) / math.max(0.05, mechData.Seat:GetAttribute("SlideDuration") or 0.75), 0, 1))) or 0
				local windupComp = (mechData.IsWindingUp and mechData.WindupStartTime) and (2.0 * math.clamp((os.clock() - mechData.WindupStartTime) / math.max(0.01, mechData.WindupDuration or 0.2), 0, 1)) or 0
				local targetY = rayResult and (rayResult.Position.Y + (mechData.IsCrawling and 2 or (mechData.HoverOffset or 7)) - slideComp - windupComp) or -10000

				-- JUMP WINDUP
				if mechData.IsWindingUp and (os.clock() - (mechData.WindupStartTime or os.clock())) >= (mechData.WindupDuration or 0) then
					mechData.IsWindingUp, mechData.IsJumping = false, true
					mechData.JumpHorizontalVelocity, mechData.VerticalVelocity = mechData.PendingJumpDir * mechData.PendingJumpHorizontalSpeed, mechData.PendingJumpVerticalSpeed
					mechData.SuspensionY = (mechData.SuspensionY or mechData.BaseDriveCFrame.Position.Y) + 0.5
				end

				-- GRAVITY
				if mechData.IsJumping or (mechData.SuspensionY > targetY + 3.5) then
					mechData.IsFalling = true
					mechData.VerticalVelocity = (mechData.VerticalVelocity or 0) - (workspace.Gravity * deltaTime)
					mechData.SuspensionY = mechData.SuspensionY + (mechData.VerticalVelocity * deltaTime)
					if mechData.VerticalVelocity <= 0 and mechData.SuspensionY <= targetY then
						mechData.SuspensionY, mechData.VerticalVelocity, mechData.IsFalling = targetY, 0, false
						if mechData.IsJumping then
							mechData.IsSliding, mechData.SlideStartTime, mechData.SlideInitialVelocity = true, os.clock(), mechData.JumpHorizontalVelocity or Vector3.zero
						end
						mechData.IsJumping = false
					end
				else
					mechData.IsFalling, mechData.IsJumping, mechData.VerticalVelocity = false, false, 0
					mechData.SuspensionY = mechData.SuspensionY + (targetY - mechData.SuspensionY) * math.min(9 * deltaTime, 1)
				end

				mechData.TerrainNormal = mechData.TerrainNormal:Lerp(rayResult and (mechData.IsCrawling and rayResult.Normal or Vector3.new(0,1,0)) or Vector3.new(0,1,0), 8 * deltaTime)

				local speedRatio = (mechData.Seat:GetAttribute("WalkSpeed") or 15) / 15
				local bobOffset = isMoving and (math.sin(os.clock() * (mechData.IsLimping and (10 * speedRatio * 0.6) or (10 * speedRatio))) * (mechData.IsLimping and (0.5 * math.sqrt(speedRatio) * 2) or (0.5 * math.sqrt(speedRatio)))) or 0

				mechData.CurrentStancePitch = Aim.LerpAngle(mechData.CurrentStancePitch, mechData.TargetStancePitch, mechData.FallSpeed * deltaTime)
				local safeNormal = mechData.TerrainNormal.Unit
				local flatHeading = Vector3.new(mechData.CurrentHeading.X, 0, mechData.CurrentHeading.Z)
				flatHeading = flatHeading.Magnitude > 0.01 and flatHeading.Unit or Vector3.new(0,0,-1)

				local dynRight = flatHeading:Cross(safeNormal)
				dynRight = dynRight.Magnitude < 0.001 and Vector3.new(1,0,0) or dynRight.Unit
				local dynBack = dynRight:Cross(safeNormal).Unit

				local targetRot = CFrame.fromMatrix(Vector3.zero, dynRight, safeNormal, dynBack) * CFrame.Angles(mechData.CurrentStancePitch, 0, 0)
				mechData.BaseDriveCFrame = CFrame.new(Vector3.new(nextPosition.X, mechData.SuspensionY + bobOffset, nextPosition.Z)) * mechData.BaseDriveCFrame.Rotation:Lerp(targetRot, (mechData.HipTurnSpeed) * deltaTime)

				if mechData.Seat:GetAttribute("LocomotionType") == "Wheeled" then
					mechData.BaseDriveCFrame = mechData.DriveCore.CFrame
					if not workspace:Raycast(mechData.DriveCore.Position, Vector3.new(0, -15, 0), tankAirRaycastParams) then
						local cp = math.deg(math.asin(math.clamp(mechData.DriveCore.CFrame.LookVector.Y, -1, 1)))
						if cp < -5 and myHip then
							myHip:ApplyAngularImpulse(mechData.DriveCore.CFrame.RightVector * ((math.abs(cp) / 90) * myHip.AssemblyMass * 50))
						end
					end
				else
					mechData.DriveCore.CFrame = mechData.BaseDriveCFrame * CFrame.new(mechData.StaggerPosition) * CFrame.Angles(mechData.StaggerPitch * Config.HIP_TILT_MULTIPLIER, mechData.StaggerYaw * Config.HIP_TILT_MULTIPLIER, mechData.StaggerRoll * Config.HIP_TILT_MULTIPLIER)
				end

				if not isStationary then
					-- TRAMPLE LOGIC
					if (currentTime - (mechData.LastTrampleTick or 0) > 0.1) then
						mechData.LastTrampleTick = currentTime
						local trampleDamage = (mechData.Seat and mechData.Seat:GetAttribute("TrampleDamage")) or 75
						local hCFrame = mechData.Hitbox and mechData.Hitbox.CFrame or (mechData.BaseDriveCFrame * CFrame.new(0, 5, 0))
						local hSize = mechData.Hitbox and (mechData.Hitbox.Size + Vector3.new(1, 1, 1)) or Vector3.new(12, 10, 12)
						for _, p in ipairs(workspace:GetPartBoundsInBox(hCFrame, hSize, trampleOverlapParams)) do
							if p:GetAttribute("CurrentHealth") and (trampleDamage >= (p:GetAttribute("Hardness") or 0)) then
								ReplicatedStorage.MechDamageEvent:FireServer(p, trampleDamage, false, nil, "Trample")
								break
							end
						end
					end
				end
			
			end
		else
			local isEmpty = (mechData.Driver == nil)
			local hip = GetMechRoot(mechModel)
			local isParked = hip and hip.Anchored

			-- Interpolate network-driven joints toward their latest ghost sync
			-- targets so 10Hz snapshots render as smooth motion for spectators.
			local netJointTargets = mechData.NetJointTargets
			if netJointTargets then
				local jointAlpha = math.clamp(20 * deltaTime, 0, 1)
				for key, entry in pairs(netJointTargets) do
					local motor = entry.Motor
					if motor and motor.Parent then
						motor[entry.Prop] = motor[entry.Prop]:Lerp(entry.Target, jointAlpha)
					else
						netJointTargets[key] = nil
					end
				end
			end

			if mechData.IsFinishingExit then
				if mechData.BaseDriveCFrame then mechData.DriveCore.CFrame = mechData.BaseDriveCFrame * CFrame.new(mechData.StaggerPosition) * CFrame.Angles(mechData.StaggerPitch * Config.HIP_TILT_MULTIPLIER, mechData.StaggerYaw * Config.HIP_TILT_MULTIPLIER, mechData.StaggerRoll * Config.HIP_TILT_MULTIPLIER) end
			else
				local netCFrame = mechModel:GetAttribute("DriveCFrame")
				if mechData.Seat and mechData.Seat:GetAttribute("LocomotionType") == "Wheeled" then
					mechData.BaseDriveCFrame = mechData.DriveCore.CFrame
				else
					if netCFrame then
						mechData.BaseDriveCFrame = (mechData.BaseDriveCFrame or netCFrame):Lerp(netCFrame, 12 * deltaTime)
					end
					if mechData.BaseDriveCFrame then 
						mechData.DriveCore.CFrame = mechData.BaseDriveCFrame * CFrame.new(mechData.StaggerPosition) * CFrame.Angles(mechData.StaggerPitch * Config.HIP_TILT_MULTIPLIER, mechData.StaggerYaw * Config.HIP_TILT_MULTIPLIER, mechData.StaggerRoll * Config.HIP_TILT_MULTIPLIER) 
					end
				end
			end
		end

		if mechData.Locomotion then
			local cCFrame = mechData.DriveCore.CFrame
			local intentionalMovement = mechData.Driver and (cCFrame.Position - (mechData.LastCleanPos or cCFrame.Position)) or Vector3.zero
			mechData.LastCleanPos = cCFrame.Position

			if mechData.Driver == localPlayer or mechData.IsFinishingExit then
				mechData.Locomotion:Update(deltaTime, intentionalMovement, cCFrame.Rotation, mechData.IsLimping, mechData.StaggerPosition.Magnitude, mechData.IsFalling, mechData.CurrentSpeed or mechData.WalkSpeed or 15, mechData.IsWindingUp)
				
				local function preventFootClipping(legData)
					if legData and legData.isStepping then
						local hipPos = mechData.DriveCore.Position
						-- 1. Start slightly below the hip joint
						local rayStart = hipPos - Vector3.new(0, 1, 0)
						-- 2. Aim just above the target ground position
						local rayEnd = legData.goalPos + Vector3.new(0, 1, 0)

						local toGoal = rayEnd - rayStart
						local dist = toGoal.Magnitude

						if dist > 1 then
							local footRay = workspace:Raycast(rayStart, toGoal, bumperRaycastParams)

							-- 3. Only block if the hit surface faces upward/outward (Normal.Y >= 0)
							if footRay and footRay.Normal.Y >= 0 and ShouldBlockMech(footRay.Instance, footRay.Normal) then
								--print("Slope face blocked by:", footRay.Instance.Name, "| Surface Normal Y:", math.round(footRay.Normal.Y * 100) / 100)
							
								-- Only consider it a wall if the hit occurs at least 1.5 studs above the foot's target ground height
								local isAboveFoot = (footRay.Position.Y >= legData.goalPos.Y + 1.5)

								-- Check if the surface faces head-on against the step direction
								local isHeadOnWall = footRay.Normal:Dot(toGoal.Unit) < -0.4

								if isAboveFoot and isHeadOnWall and ShouldBlockMech(footRay.Instance, footRay.Normal) then
									local safePos = footRay.Position - (toGoal.Unit * 1.5)
									safePos = Vector3.new(safePos.X, legData.goalPos.Y, safePos.Z)
									legData.goalPos = safePos
								end
							end
						end
					end
				end

				-- Apply the clamp to whatever legs this locomotion module has
				if mechData.Locomotion.LeftLeg then preventFootClipping(mechData.Locomotion.LeftLeg) end
				if mechData.Locomotion.RightLeg then preventFootClipping(mechData.Locomotion.RightLeg) end	
			end

			if mechData.IsFinishingExit then
				local hasLegs = (mechData.Locomotion.LeftLeg ~= nil)
				if (not hasLegs or (not mechData.Locomotion.LeftLeg.isStepping and not mechData.Locomotion.RightLeg.isStepping)) and not mechData.IsFalling and math.abs(mechData.CurrentStancePitch - mechData.TargetStancePitch) < 0.05 and not mechData.IsStandingUp then
					mechData.ExitSettleTimer = (mechData.ExitSettleTimer or 0) + deltaTime
					if mechData.ExitSettleTimer >= 0.15 then mechData.IsFinishingExit, mechData.ExitSettleTimer = false, 0 end
				else
					mechData.ExitSettleTimer = 0
				end
			end
		end

		if mechData.IsAiming and mechData.Driver == localPlayer and mechData.Weapons then
			table.clear(cachedWeaponIgnoreList) table.insert(cachedWeaponIgnoreList, mechModel)
			if localPlayer.Character then table.insert(cachedWeaponIgnoreList, localPlayer.Character) end

			for slotName, weapon in pairs(mechData.Weapons) do
				local assignedGroup = (mechData.WeaponGroups and mechData.WeaponGroups[slotName]) or "Primary"
				local isHeldDown = not Input.isSprinting and (isMobile and (MobileUtil.IsFiring and MobileUtil.WeaponToggles[assignedGroup]) or Input.isHoldingTrigger[assignedGroup])

				if isHeldDown then
					local fireResult = weapon:Fire(mechData.TargetPos, cachedWeaponIgnoreList, true, deltaTime)
					local shotsFired = (typeof(fireResult) == "number") and fireResult or (fireResult == true and 1 or 0)
					for _ = 1, shotsFired do ReplicatedStorage.MechFireWeapon:FireServer(mechModel, slotName, mechData.TargetPos) end
				else
					weapon.FireAccumulator = 0
				end
			end
		end

		if (mechData.Driver == localPlayer or mechData.IsFinishingExit) and (currentTime - mechData.LastNetworkSend >= 0.0667) then
			mechData.LastNetworkSend = currentTime
			local uTarget = Vector3.zero
			if mechData.IsAiming then
				local aimDir = mechData.BaseDriveCFrame.LookVector
				if mechData.TargetPos and (mechData.TargetPos - mechData.Torso.Position).Magnitude > 0.1 then aimDir = (mechData.TargetPos - mechData.Torso.Position).Unit end
				uTarget = mechData.Torso.Position + (aimDir * 1000)
			end

			local rC0s, lC0s = {}, {}
			if mechData.RightShoulderMotors then for _, i in ipairs(mechData.RightShoulderMotors) do if i.Motor then table.insert(rC0s, i.Motor.C0) end end end
			if mechData.LeftShoulderMotors then for _, i in ipairs(mechData.LeftShoulderMotors) do if i.Motor then table.insert(lC0s, i.Motor.C0) end end end

			local lt, rt = mechModel:FindFirstChild("TargetLeft", true), mechModel:FindFirstChild("TargetRight", true)

			updateAimEvent:FireServer(mechModel, uTarget, mechData.BaseDriveCFrame, {
				WaistC0 = mechData.WaistJoint and mechData.WaistJoint.C0, NeckC0 = mechData.NeckJoint and mechData.NeckJoint.C0,
				RShoulderC0 = mechData.RightShoulder and mechData.RightShoulder.C0, LShoulderC0 = mechData.LeftShoulder and mechData.LeftShoulder.C0,
				RElbowC0 = mechData.RightElbow and mechData.RightElbow.C0, LElbowC0 = mechData.LeftElbow and mechData.LeftElbow.C0,
				RShoulderWeaponC0 = rC0s, LShoulderWeaponC0 = lC0s,
				LThighC0 = mechData.LeftThigh and mechData.LeftThigh.C0, RThighC0 = mechData.RightThigh and mechData.RightThigh.C0,
				LKneeC0 = mechData.LeftKnee and mechData.LeftKnee.C0, RKneeC0 = mechData.RightKnee and mechData.RightKnee.C0,
				LCalfC0 = mechData.LeftCalf and mechData.LeftCalf.C0, RCalfC0 = mechData.RightCalf and mechData.RightCalf.C0,
				LFootC0 = mechData.LeftFootJoint and mechData.LeftFootJoint.C0, RFootC0 = mechData.RightFootJoint and mechData.RightFootJoint.C0,
				WaistC1 = mechData.WaistJoint and mechData.WaistJoint.C1, NeckC1 = mechData.NeckJoint and mechData.NeckJoint.C1,
				RShoulderC1 = mechData.RightShoulder and mechData.RightShoulder.C1, LShoulderC1 = mechData.LeftShoulder and mechData.LeftShoulder.C1,
				RElbowC1 = mechData.RightElbow and mechData.RightElbow.C1, LElbowC1 = mechData.LeftElbow and mechData.LeftElbow.C1,
				CamYawC0 = mechData.CamYawMotor and mechData.CamYawMotor.C0, CamPitchC0 = mechData.CamPitchMotor and mechData.CamPitchMotor.C0,
				LeftFootCFrame = lt and lt.CFrame or CFrame.new(), RightFootCFrame = rt and rt.CFrame or CFrame.new()
			})
		end
	end
end)

-- MISSING LINK #5: ALL THE EVENT RECEIVERS
fireWeaponEvent.OnClientEvent:Connect(function(shooter, mechModel, slotName, targetPos)
	-- shooter can be nil when the server-side AI pilot broadcasts its shots
	if shooter == localPlayer or not activeMechs[mechModel] then return end
	local weapon = activeMechs[mechModel].Weapons and activeMechs[mechModel].Weapons[slotName]
	if weapon then
		local ignore = {mechModel}
		if shooter and shooter.Character then table.insert(ignore, shooter.Character) end
		weapon:Fire(targetPos, ignore, false)
	end
end)

staggerEvent.OnClientEvent:Connect(function(mechModel, intensity, hitDir)
	local mechData = activeMechs[mechModel]
	if mechData and hitDir then
		local frontHit = mechData.DriveCore.CFrame.LookVector:Dot(hitDir)
		local sideHit = mechData.DriveCore.CFrame.RightVector:Dot(hitDir)
		mechData.StaggerPitch = -frontHit * intensity
		mechData.StaggerRoll = sideHit * (intensity * 0.5)
		mechData.StaggerYaw = sideHit * (intensity * 0.3)
		local flatHitDir = Vector3.new(hitDir.X, 0, hitDir.Z)
		if flatHitDir.Magnitude > 0 then mechData.StaggerPosition = flatHitDir.Unit * (intensity * 4) end
	end
end)

visualEvent.OnClientEvent:Connect(function(impactPos, blastDir, hitNormal)
	local explosion = Instance.new("Explosion")
	explosion.Position, explosion.BlastRadius, explosion.DestroyJointRadiusPercent, explosion.BlastPressure = impactPos, 20, 0, 0
	explosion.Parent = workspace
	local masterSpark = ReplicatedStorage:FindFirstChild("ImpactSpark", true)
	if masterSpark then
		local sparkAnchor = Instance.new("Part")
		sparkAnchor.Size, sparkAnchor.Transparency, sparkAnchor.Anchored, sparkAnchor.CanCollide, sparkAnchor.CanQuery = Vector3.new(0.1,0.1,0.1), 1, true, false, false
		sparkAnchor.Position = impactPos + ((hitNormal or -blastDir) * 0.7)
		sparkAnchor.CFrame = CFrame.lookAt(sparkAnchor.Position, sparkAnchor.Position + blastDir)
		sparkAnchor.Parent = workspace
		local newSpark = masterSpark:Clone()
		newSpark.Parent = sparkAnchor
		newSpark:Emit(15)
		game.Debris:AddItem(sparkAnchor, 2)
	end
end)

stateUpdateEvent.OnClientEvent:Connect(function(mechModel, action, partName)
	local mechData = activeMechs[mechModel]
	if not mechData then return end
	local pName = string.lower(partName)

	if action == "Severed" then
		local slotToUpdate, isArmDestroyed = nil, false
		if string.find(pName, "right") then
			if string.find(pName, "shoulderweapon") then slotToUpdate, isArmDestroyed = "RightShoulderWeapon", false
			elseif string.find(pName, "weapon") then slotToUpdate, isArmDestroyed = "RightWeapon", false
			elseif string.find(pName, "arm") or string.find(pName, "hand") then slotToUpdate, isArmDestroyed = "RightWeapon", true end
		elseif string.find(pName, "left") then
			if string.find(pName, "shoulderweapon") then slotToUpdate, isArmDestroyed = "LeftShoulderWeapon", false
			elseif string.find(pName, "weapon") then slotToUpdate, isArmDestroyed = "LeftWeapon", false
			elseif string.find(pName, "arm") or string.find(pName, "hand") then slotToUpdate, isArmDestroyed = "LeftWeapon", true end
		elseif string.find(pName, "head") or string.find(pName, "neck") then
			if mechData.Driver == localPlayer then local c = localPlayer.PlayerGui:FindFirstChild("CursorGui") if c and c:FindFirstChild("Crosshair") then c.Crosshair.Visible = false end end
		end

		if slotToUpdate then
			if isArmDestroyed then
				if mechData.Weapons[slotToUpdate] then mechData.Weapons[slotToUpdate] = nil end
			else
				local prefix = string.find(slotToUpdate, "Right") and "Right" or "Left"
				if not string.find(slotToUpdate, "Shoulder") and mechModel:FindFirstChild(prefix .. "Hand", true) then
					local punchScript = moduleScripts.MechModules.Weapons:FindFirstChild("MeleeWeapon")
					if punchScript then mechData.Weapons[slotToUpdate] = require(punchScript).new(mechModel, slotToUpdate) end
				else
					if mechData.Weapons[slotToUpdate] then mechData.Weapons[slotToUpdate] = nil end
				end
			end
		end

	elseif action == "Restored" then
		if string.find(pName, "head") or string.find(pName, "neck") then
			if mechData.Driver == localPlayer then local c = localPlayer.PlayerGui:FindFirstChild("CursorGui") if c and c:FindFirstChild("Crosshair") then c.Crosshair.Visible = true end end
		end
		local weaponSlots = { RightWeapon = "RightWeaponType", LeftWeapon = "LeftWeaponType", RightShoulderWeapon = "RightShoulderType", LeftShoulderWeapon = "LeftShoulderType" }
		for sName, attr in pairs(weaponSlots) do
			local wType = mechData.Seat:GetAttribute(attr)
			local wPart = mechModel:FindFirstChild(sName, true)
			local torso = mechModel:FindFirstChild("Torso", true)
			local prefix = string.find(sName, "Right") and "Right" or "Left"

			if wPart and torso and wPart.AssemblyRootPart == torso.AssemblyRootPart then
				if not mechData.Weapons[sName] or mechData.Weapons[sName].WeaponName == "Fist" then
					local wScript = moduleScripts.MechModules.Weapons:FindFirstChild(wType)
					if wScript then mechData.Weapons[sName] = require(wScript).new(mechModel, wPart) end
				end
			elseif mechModel:FindFirstChild(prefix .. "Shoulder", true) and mechModel:FindFirstChild(prefix .. "Hand", true) and not string.find(sName, "Shoulder") then
				if not mechData.Weapons[sName] or mechData.Weapons[sName].WeaponName ~= "Fist" then
					local punchScript = moduleScripts.MechModules.Weapons:FindFirstChild("MeleeWeapon")
					if punchScript then mechData.Weapons[sName] = require(punchScript).new(mechModel, sName) end
				end
			else
				mechData.Weapons[sName] = nil
			end
		end

		if mechData.Driver == localPlayer then HUD.MountMechHUD(mechModel, mechData, mechOriginalParts) end
		if mechModel:FindFirstChild("RightShoulder", true) then mechData.RightShoulder = mechModel:FindFirstChild("RightShoulder", true) end
		if mechModel:FindFirstChild("LeftShoulder", true) then mechData.LeftShoulder = mechModel:FindFirstChild("LeftShoulder", true) end
		if mechModel:FindFirstChild("Head", true) then mechData.Head = mechModel:FindFirstChild("Head", true) end
		if mechModel:FindFirstChild("Neck", true) or mechModel:FindFirstChild("NeckMotor", true) then mechData.NeckJoint = mechModel:FindFirstChild("Neck", true) or mechModel:FindFirstChild("NeckMotor", true) end
		if mechModel:FindFirstChild("CameraPitchMotor", true) then mechData.CamPitchMotor = mechModel:FindFirstChild("CameraPitchMotor", true) end

		for _, desc in ipairs(mechModel:GetDescendants()) do if desc:IsA("Motor6D") and desc.Name == "CameraYawBase" then mechData.CamYawMotor = desc break end end
		mechData.RightShoulderMotors = GetSlotMotors(mechModel, "RightShoulderWeaponMotor")
		mechData.LeftShoulderMotors = GetSlotMotors(mechModel, "LeftShoulderWeaponMotor")
	end
end)

ghostSyncEvent.OnClientEvent:Connect(function(pilotPlayer, mechModel, syncPackage)
	if pilotPlayer == localPlayer or not activeMechs[mechModel] then return end
	local mechData = activeMechs[mechModel]

	-- Store the latest joint targets instead of snapping them. The Heartbeat
	-- loop interpolates toward these targets every frame, so the 10Hz network
	-- snapshots render as smooth continuous motion for spectators (fixes
	-- choppy IK legs and stop-motion punch animations at high ping).
	local targets = mechData.NetJointTargets
	if not targets then
		targets = {}
		mechData.NetJointTargets = targets
	end

	local function setJoint(motor, prop, value)
		if motor and typeof(value) == "CFrame" then
			targets[tostring(motor) .. prop] = { Motor = motor, Prop = prop, Target = value }
		end
	end

	setJoint(mechData.WaistJoint, "C0", syncPackage.WaistC0)
	setJoint(mechData.NeckJoint, "C0", syncPackage.NeckC0)
	setJoint(mechData.RightShoulder, "C0", syncPackage.RShoulderC0)
	setJoint(mechData.LeftShoulder, "C0", syncPackage.LShoulderC0)
	setJoint(mechData.RightElbow, "C0", syncPackage.RElbowC0)
	setJoint(mechData.LeftElbow, "C0", syncPackage.LElbowC0)

	setJoint(mechData.WaistJoint, "C1", syncPackage.WaistC1)
	setJoint(mechData.RightShoulder, "C1", syncPackage.RShoulderC1)
	setJoint(mechData.LeftShoulder, "C1", syncPackage.LShoulderC1)
	setJoint(mechData.RightElbow, "C1", syncPackage.RElbowC1)
	setJoint(mechData.LeftElbow, "C1", syncPackage.LElbowC1)
	setJoint(mechData.NeckJoint, "C1", syncPackage.NeckC1)

	setJoint(mechData.LeftThigh, "C0", syncPackage.LThighC0)
	setJoint(mechData.RightThigh, "C0", syncPackage.RThighC0)
	setJoint(mechData.LeftKnee, "C0", syncPackage.LKneeC0)
	setJoint(mechData.RightKnee, "C0", syncPackage.RKneeC0)
	setJoint(mechData.LeftCalf, "C0", syncPackage.LCalfC0)
	setJoint(mechData.RightCalf, "C0", syncPackage.RCalfC0)
	setJoint(mechData.LeftFootJoint, "C0", syncPackage.LFootC0)
	setJoint(mechData.RightFootJoint, "C0", syncPackage.RFootC0)

	if mechData.RightShoulderMotors and type(syncPackage.RShoulderWeaponC0) == "table" then
		for i, item in ipairs(mechData.RightShoulderMotors) do
			setJoint(item.Motor, "C0", syncPackage.RShoulderWeaponC0[i])
		end
	end
	if mechData.LeftShoulderMotors and type(syncPackage.LShoulderWeaponC0) == "table" then
		for i, item in ipairs(mechData.LeftShoulderMotors) do
			setJoint(item.Motor, "C0", syncPackage.LShoulderWeaponC0[i])
		end
	end

	setJoint(mechData.CamYawMotor, "C0", syncPackage.CamYawC0)
	setJoint(mechData.CamPitchMotor, "C0", syncPackage.CamPitchC0)

	local leftTarget = mechModel:FindFirstChild("TargetLeft", true)
	setJoint(leftTarget, "CFrame", syncPackage.LeftFootCFrame)
	local rightTarget = mechModel:FindFirstChild("TargetRight", true)
	setJoint(rightTarget, "CFrame", syncPackage.RightFootCFrame)
end)

feetOffsetEvent.OnClientEvent:Connect(function(mechModel, pushOffset)
	local mechData = activeMechs[mechModel]
	if not mechData then return end
	-- push including empty one
	if mechData.BaseDriveCFrame then 
		mechData.BaseDriveCFrame = mechData.BaseDriveCFrame + pushOffset 
	end
	local tl = mechModel:FindFirstChild("TargetLeft", true)
	local tr = mechModel:FindFirstChild("TargetRight", true)
	if tl then tl.CFrame = tl.CFrame + pushOffset end
	if tr then tr.CFrame = tr.CFrame + pushOffset end
	print("Feet offset")
end)

MechRamEvent.OnClientEvent:Connect(function(targetMech, shoveForce)
	local mechData = activeMechs[targetMech]
	if not mechData or mechData.Driver ~= localPlayer then return end
	local hip = GetMechRoot(targetMech)
	if hip then hip:ApplyImpulse(shoveForce) print("Ram Client") end
end)

