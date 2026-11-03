local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local playerGui = player:WaitForChild("PlayerGui")

local rojoShared = ReplicatedStorage:WaitForChild("Shared")
local moduleScripts = rojoShared:WaitForChild("ModuleScripts")
local MobileUtil = require(moduleScripts:WaitForChild("MobileUtil"))

local mobileContainer = playerGui:WaitForChild("MobileControlsGui")

-- gate away pc players
if not MobileUtil.isMobile() then
	return
end

local CAMERA_SENSITIVITY = 0.005 -- Controls how fast dragging turns the camera
local DEADZONE_RADIUS = 5      -- Pixels of finger travel before camera starts turning
local SENSITIVITY_SCALE = 0.5
local TOTAL_DAMPEN_FRAMES = 8   -- Frames to bleed off mobile flick inertia (~0.4s)

local activeTouchInput = nil
local touchStartPos = nil
local currentTouchPos = nil
local lastCameraRotation = nil
local isPastDeadzone = false

local currentYaw = nil
local currentPitch = nil
local releaseDampenFrames = 0

local WEAPON_GROUPS = { "Primary", "Secondary", "Tertiary", "Quaternary" }
local TOGGLE_PREFIX = "MechToggle_"

local SLOT_DEFINITIONS = {
	{ TypeAttr = "RightWeaponType", GroupAttr = "RightWeaponGroup", Default = "Primary" },
	{ TypeAttr = "LeftWeaponType", GroupAttr = "LeftWeaponGroup", Default = "Secondary" },
	{ TypeAttr = "RightShoulderType", GroupAttr = "RightShoulderGroup", Default = "Tertiary" },
	{ TypeAttr = "LeftShoulderType", GroupAttr = "LeftShoulderGroup", Default = "Quaternary" },
}

local FIRE_ACTION_NAME = "MechFireAction"
local TARGET_TOOL_NAME = "Targeting"

local toggleButtons = {}

local function getActiveCameraController()
	local playerScripts = player:FindFirstChild("PlayerScripts")
	local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
	if not playerModule then return nil end

	local success, module = pcall(require, playerModule)
	if success and module and module.GetCameras then
		local cameras = module:GetCameras()
		return cameras and cameras.GetActiveCameraController and cameras:GetActiveCameraController()
	end
	return nil
end

local function rotateCamera(delta: Vector2)
	local controller = getActiveCameraController()
	if not controller then return end

	local yawDelta = delta.X * CAMERA_SENSITIVITY
	local pitchDelta = delta.Y * CAMERA_SENSITIVITY

	if controller.cameraYaw and controller.cameraPitch then
		controller.cameraYaw = controller.cameraYaw - yawDelta
		controller.cameraPitch = math.clamp(controller.cameraPitch - pitchDelta, math.rad(-80), math.rad(80))
	elseif controller.rotateInput then
		controller.rotateInput = controller.rotateInput + Vector2.new(yawDelta, pitchDelta)
	end
end

local function handleFireAction(actionName, inputState, inputObject)
	if inputState == Enum.UserInputState.Begin then
		MobileUtil.IsFiring = true
		activeTouchInput = inputObject
		touchStartPos = Vector2.new(inputObject.Position.X, inputObject.Position.Y)
		currentTouchPos = touchStartPos
		isPastDeadzone = false
		releaseDampenFrames = 0

		local cam = workspace.CurrentCamera
		if cam then
			local p, y, _ = cam.CFrame:ToEulerAnglesYXZ()
			currentPitch = p
			currentYaw = y
		end

	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		if inputObject == activeTouchInput or inputObject == nil then
			MobileUtil.IsFiring = false
			activeTouchInput = nil
			touchStartPos = nil
			currentTouchPos = nil
			isPastDeadzone = false
			-- Dampen residual mobile pan inertia for 8 frames after lifting finger
			releaseDampenFrames = TOTAL_DAMPEN_FRAMES
		end
	end

	-- Keep Pass and Active = false
	return Enum.ContextActionResult.Pass
end

local function formatMobileButton(button: GuiObject, parent: GuiObject, sizeScale: number, pos: UDim2, sizecons: number)
	button.Parent = parent
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = pos
	button.Size = UDim2.new(sizeScale, 0, sizeScale, 0)

	local ratio = button:FindFirstChildOfClass("UIAspectRatioConstraint") or Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = button
	local sizeconstraint = button:FindFirstChildOfClass("UISizeConstraint") or Instance.new("UISizeConstraint")
	sizeconstraint.MaxSize = Vector2.new(sizecons, sizecons)
	sizeconstraint.Parent = button
end

-- Live-track the finger position across the screen
UserInputService.TouchMoved:Connect(function(input)
	if input == activeTouchInput then
		currentTouchPos = Vector2.new(input.Position.X, input.Position.Y)
	end
end)

-- Intercept camera input right before Roblox's Camera script updates (Priority 199)
RunService:BindToRenderStep("MobileFireDeadzone", Enum.RenderPriority.Camera.Value + 1, function()
	local cam = workspace.CurrentCamera
	if not cam then return end

	local camPitch, camYaw, _ = cam.CFrame:ToEulerAnglesYXZ()

	if not currentPitch or not currentYaw then
		currentPitch = camPitch
		currentYaw = camYaw
	end

	-- Calculate rotational delta applied by Roblox this frame
	local deltaYaw = math.atan2(math.sin(camYaw - currentYaw), math.cos(camYaw - currentYaw))
	local deltaPitch = math.atan2(math.sin(camPitch - currentPitch), math.cos(camPitch - currentPitch))

	local sensitivity = MobileUtil.FireAimSensitivity or 0.5

	local isInteracting = (activeTouchInput ~= nil and touchStartPos ~= nil)

	if isInteracting then
		local currentPos = currentTouchPos or touchStartPos
		local distance = (currentPos - touchStartPos).Magnitude

		if distance < DEADZONE_RADIUS then
			-- 1. INSIDE DEADZONE: Absorb all rotation (angles remain frozen)
		else
			if not isPastDeadzone then
				isPastDeadzone = true
				currentPitch = camPitch
				currentYaw = camYaw
			else
				currentYaw = currentYaw + (deltaYaw * sensitivity)
				currentPitch = math.clamp(currentPitch + (deltaPitch * sensitivity), math.rad(-80), math.rad(80))
			end
		end

		local focus = cam.Focus.Position
		local zoom = math.max((cam.CFrame.Position - focus).Magnitude, 0.5)
		cam.CFrame = CFrame.new(focus) * CFrame.fromEulerAnglesYXZ(currentPitch, currentYaw, 0) * CFrame.new(0, 0, zoom)

	elseif releaseDampenFrames > 0 then
		local decayProgress = releaseDampenFrames / TOTAL_DAMPEN_FRAMES
		local activeScale = sensitivity * decayProgress

		releaseDampenFrames = releaseDampenFrames - 1

		currentYaw = currentYaw + (deltaYaw * activeScale)
		currentPitch = math.clamp(currentPitch + (deltaPitch * activeScale), math.rad(-80), math.rad(80))

		local focus = cam.Focus.Position
		local zoom = math.max((cam.CFrame.Position - focus).Magnitude, 0.5)
		cam.CFrame = CFrame.new(focus) * CFrame.fromEulerAnglesYXZ(currentPitch, currentYaw, 0) * CFrame.new(0, 0, zoom)
	else
		-- Idle: Track camera angles so baseline is ready for the next press
		currentPitch = camPitch
		currentYaw = camYaw
	end
end)

local function getActiveWeaponGroups(seat: VehicleSeat)
	local activeGroups = {}
	if not seat then return activeGroups end

	for _, slot in ipairs(SLOT_DEFINITIONS) do
		local weaponType = seat:GetAttribute(slot.TypeAttr)
		-- Check if a weapon is equipped and not an empty string
		if weaponType ~= nil and weaponType ~= "" then
			-- Use the rewired group attribute if set; otherwise use default
			local assignedGroup = seat:GetAttribute(slot.GroupAttr) or slot.Default
			activeGroups[assignedGroup] = true
		end
	end

	return activeGroups
end

local function handleToggleAction(actionName, inputState, inputObject)
	if inputState == Enum.UserInputState.Begin then
		local group = string.gsub(actionName, TOGGLE_PREFIX, "")
		if MobileUtil.WeaponToggles[group] ~= nil then
			-- Flip the active state
			MobileUtil.WeaponToggles[group] = not MobileUtil.WeaponToggles[group]

			-- Dim button when toggled OFF, make solid when ON
			local button = ContextActionService:GetButton(actionName)
			if button then
				button.ImageTransparency = MobileUtil.WeaponToggles[group] and 0 or 0.6
			end
		end
	end
	return Enum.ContextActionResult.Pass

end

ContextActionService:BindAction(
	FIRE_ACTION_NAME,
	handleFireAction,
	true -- Creates an on-screen mobile touch button automatically
)

local fireButton = ContextActionService:GetButton(FIRE_ACTION_NAME)

if fireButton then
	fireButton.Visible = false
	fireButton.Active = false
	--fireButton.Size = UDim2.fromOffset(95, 95)

	-- Position it in the bottom-right corner (offset from screen edges)
	--fireButton.Position = UDim2.new(1, -200, 1, -180)

	-- Label the button
	ContextActionService:SetTitle(FIRE_ACTION_NAME, "")
	ContextActionService:SetImage(FIRE_ACTION_NAME, "rbxassetid://73243540972177")
	formatMobileButton(fireButton, mobileContainer, 0.3, UDim2.new(0.77, 0, 0.65, 0), 200)
end


for index, groupName in ipairs(WEAPON_GROUPS) do
	local actionName = TOGGLE_PREFIX .. groupName
	ContextActionService:BindAction(actionName, handleToggleAction, true)

	local button = ContextActionService:GetButton(actionName)
	if button then
		button.Visible = false
		button.Size = UDim2.fromOffset(30, 30)

		-- 3-letter label: PRI, SEC, TER, QUA
		local shortName = string.upper(string.sub(groupName, 1, 3))
		ContextActionService:SetTitle(actionName, shortName)

		-- Match initial transparency to default toggle state in MobileUtil
		button.ImageTransparency = MobileUtil.WeaponToggles[groupName] and 0 or 0.6

		toggleButtons[groupName] = button
	end
end


local function updateFireButtonVisibility()
	local character = player.Character
	if not character or not fireButton then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	local isSeated = seat and seat:IsA("VehicleSeat")
	local tool = character:FindFirstChildOfClass("Tool")
	local hasTargetingTool = tool and tool.Name == TARGET_TOOL_NAME
	--print("VISIBILITY EVENT FIRED | Seat:", humanoid and humanoid.SeatPart, "| Tool:", tool and tool.Name)

	local shouldShow = (isSeated and hasTargetingTool) == true

	fireButton.Visible = shouldShow
	for _, button in pairs(toggleButtons) do
		button.Visible = false
	end

	-- If active, pack only the equipped weapon groups into a 2x2 formation
	if shouldShow and seat then
		local activeGroups = getActiveWeaponGroups(seat)
		local visibleIndex = 0

		--local SPACING = 35
		--local BASE_X = -90
		--local BASE_Y = -180
		
		local GRID_BASE_X = 0.9
		local GRID_BASE_Y = 0.5
		local SPACING_X = 0.035
		local SPACING_Y = 0.08

		for _, groupName in ipairs(WEAPON_GROUPS) do
			local button = toggleButtons[groupName]
			if button and activeGroups[groupName] then
				visibleIndex += 1

				local col = (visibleIndex - 1) % 2
				local row = math.floor((visibleIndex - 1) / 2)

				--button.Position = UDim2.new(1, BASE_X + (col * SPACING), 1, BASE_Y + (row * SPACING))
				formatMobileButton(
					button,
					mobileContainer,
					0.065,
					UDim2.new(GRID_BASE_X + (col * SPACING_X), 0, GRID_BASE_Y + (row * SPACING_Y), 0),
					40
				)
				button.Visible = true
			end
		end
	end

	if not shouldShow and activeTouchInput then
		handleFireAction(FIRE_ACTION_NAME, Enum.UserInputState.End, nil)
	end
end

local function repositionMobileHUD()
	local mechHealthHUD = playerGui:WaitForChild("MechHealthHUD")
	local healthStage = mechHealthHUD:WaitForChild("ActiveUITemplate")
	healthStage.AnchorPoint = Vector2.new(1, 0)
	healthStage.Position = UDim2.new(0.99, 0, 0.02, 0)
end

local function setupCharacterListeners(character)
	repositionMobileHUD()
	
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			updateFireButtonVisibility()
		end
	end)

	character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then
			updateFireButtonVisibility()
		end
	end)

	local humanoid = character:WaitForChild("Humanoid")
	humanoid.Seated:Connect(function(active)
		updateFireButtonVisibility()
	end)

	-- Initial check in case the character spawned with the tool already equipped
	updateFireButtonVisibility()
end


-- Bind to current character and any future respawns
if player.Character then
	setupCharacterListeners(player.Character)
end

player.CharacterAdded:Connect(setupCharacterListeners)

--task.spawn(function()
	-- A. Move Weapon HUD to the Top-Left (under Roblox menu icons)
	--local mechWeaponHUD = playerGui:WaitForChild("MechWeaponHUD")
	--local weaponMainFrame = mechWeaponHUD:WaitForChild("Frame")
	--weaponMainFrame.AnchorPoint = Vector2.new(0, 0)
	--weaponMainFrame.Position = UDim2.new(0.005, 0, 0.16, 0)

	-- Move Health Paperdoll flush to the top-right corner
	--local mechHealthHUD = playerGui:WaitForChild("MechHealthHUD")
	--local healthStage = mechHealthHUD:WaitForChild("ActiveUITemplate")
	--healthStage.AnchorPoint = Vector2.new(1, 0)
	--healthStage.Position = UDim2.new(0.99, 0, 0.02, 0)
--end) 