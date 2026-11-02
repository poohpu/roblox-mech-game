-- Location: ReplicatedStorage.ModuleScripts.MechModules.Client.MechInputController
-- Function: Manages UserInputService listeners, keybind mappings, ContextActionService bindings for mobile, jump execution, sprint timers, and reload hooks.

local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MechReloadEvent = ReplicatedStorage:WaitForChild("MechReloadEvent")
local Players = game:GetService("Players")

local Config = require(script.Parent:WaitForChild("MechClientConfig"))

local MechInputController = {}

MechInputController.isHoldingTrigger = { Primary = false, Secondary = false, Tertiary = false, Quaternary = false }
MechInputController.isSprinting = false
local mobilityPressStartTime = 0
local sprintHoldTask = nil
local getActiveMechsRef = nil

local keyBinds = {
	[Enum.UserInputType.MouseButton1] = "Primary",
	[Enum.KeyCode.F] = "Secondary",
	[Enum.KeyCode.E] = "Tertiary",
	[Enum.KeyCode.Q] = "Quaternary"
}

-- Format Helper for Mobile UI
local function formatMobileButton(button, parent, sizeScale, pos, sizecons)
	button.Parent = parent
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = pos
	button.Size = UDim2.new(sizeScale, 0, sizeScale, 0)
	local ratio = button:FindFirstChildOfClass("UIAspectRatioConstraint") or Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = button
	local sc = button:FindFirstChildOfClass("UISizeConstraint") or Instance.new("UISizeConstraint")
	sc.Parent = button
	sc.MaxSize = Vector2.new(sizecons, sizecons)
end

function MechInputController.Init(getActiveMechsFunc)
	getActiveMechsRef = getActiveMechsFunc
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		local inputType = input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode or input.UserInputType
		local weaponSlot = keyBinds[inputType]

		if weaponSlot then
			MechInputController.isHoldingTrigger[weaponSlot] = true
		elseif input.KeyCode == Enum.KeyCode.X then
			for _, mechData in pairs(getActiveMechsRef()) do
				if mechData.Driver == Players.LocalPlayer then
					if mechData.Seat:GetAttribute("LocomotionType") == "Wheeled" then
						mechData.WantsManualUnstuck = true
					end
					break
				end
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		local inputType = input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode or input.UserInputType
		local weaponSlot = keyBinds[inputType]
		if weaponSlot then MechInputController.isHoldingTrigger[weaponSlot] = false end
	end)
end

function MechInputController.ExecuteMechJump(mechData)
	if not mechData or not mechData.Seat then return end
	local seat = mechData.Seat
	local currentTime = os.clock()

	local cooldown = seat:GetAttribute("JumpCooldown") or 3.0
	if currentTime - (mechData.LastJumpTime or 0) < cooldown then return end
	if mechData.IsFalling then return end

	local distance = seat:GetAttribute("JumpDistance") or 50
	local airTime = seat:GetAttribute("JumpAirTime") or 1.0
	local horizontalSpeed = distance / math.max(0.1, airTime)
	local verticalLaunchSpeed = workspace.Gravity * (airTime * 0.5)

	local camRight = workspace.CurrentCamera.CFrame.RightVector
	local flatForward = Vector3.new(0, 1, 0):Cross(camRight).Unit
	local flatRight = Vector3.new(camRight.X, 0, camRight.Z).Unit

	local inputDir = (flatForward * seat.Throttle) + (flatRight * seat.Steer)
	local jumpDir
	if inputDir.Magnitude > 0.01 then
		jumpDir = inputDir.Unit
	else
		local flatLook = Vector3.new(mechData.BaseDriveCFrame.LookVector.X, 0, mechData.BaseDriveCFrame.LookVector.Z)
		jumpDir = flatLook.Magnitude > 0.01 and flatLook.Unit or flatForward
	end

	local windupTime = seat:GetAttribute("JumpWindupTime") or 0
	mechData.LastJumpTime = currentTime
	mechData.PendingJumpHorizontalSpeed = horizontalSpeed
	mechData.PendingJumpVerticalSpeed = verticalLaunchSpeed
	mechData.PendingJumpDir = jumpDir

	if windupTime > 0 then
		mechData.IsWindingUp = true
		mechData.WindupStartTime = currentTime
		mechData.WindupDuration = windupTime
	else
		mechData.IsJumping = true
		mechData.JumpHorizontalVelocity = jumpDir * horizontalSpeed
		mechData.VerticalVelocity = verticalLaunchSpeed
		mechData.SuspensionY = (mechData.SuspensionY or mechData.BaseDriveCFrame.Position.Y) + 0.5
	end
end

function MechInputController.HandleMobilityAction(actionName, inputState, inputObject)
	local currentMechData = nil
	for _, mechData in pairs(getActiveMechsRef()) do
		if mechData.Driver == Players.LocalPlayer then currentMechData = mechData break end
	end
	if not currentMechData or not currentMechData.Seat then return end

	local seat = currentMechData.Seat
	local locoType = seat:GetAttribute("LocomotionType")
	local isMobilityAllowed = (Config.MOBILITY_ENABLED_LOCOMOTIONS[locoType] == true) and (not currentMechData.IsCrawling)
	local canSprint = isMobilityAllowed and (seat:GetAttribute("CanSprint") == true)
	local canJump = isMobilityAllowed and (seat:GetAttribute("CanJump") == true)

	if inputState == Enum.UserInputState.Begin then
		mobilityPressStartTime = os.clock()
		if sprintHoldTask then task.cancel(sprintHoldTask) sprintHoldTask = nil end
		if canSprint then
			sprintHoldTask = task.delay(Config.MOBILITY_TAP_THRESHOLD, function() MechInputController.isSprinting = true end)
		end
	elseif inputState == Enum.UserInputState.End then
		if sprintHoldTask then task.cancel(sprintHoldTask) sprintHoldTask = nil end
		if (os.clock() - mobilityPressStartTime) < Config.MOBILITY_TAP_THRESHOLD then
			if canJump then MechInputController.ExecuteMechJump(currentMechData) end
		else
			MechInputController.isSprinting = false
			if not canSprint and canJump then MechInputController.ExecuteMechJump(currentMechData) end
		end
	elseif inputState == Enum.UserInputState.Cancel then
		if sprintHoldTask then task.cancel(sprintHoldTask) sprintHoldTask = nil end
		MechInputController.isSprinting = false
	end
end

function MechInputController.HandleMechReload(actionName, inputState, inputObject)
	if inputState ~= Enum.UserInputState.Begin then return end
	for mechModel, mechData in pairs(getActiveMechsRef()) do
		if mechData.Driver == Players.LocalPlayer then
			if mechData.Weapons then
				for slotName, weapon in pairs(mechData.Weapons) do
					if weapon and weapon.MaxAmmo and weapon.CurrentAmmo and weapon.CurrentAmmo < weapon.MaxAmmo and not weapon.IsReloading then
						weapon:Reload()
						MechReloadEvent:FireServer(mechModel, slotName)
					end
				end
			end
			break
		end
	end
end

function MechInputController.BindPilotControls(mechData)
	local mobileContainer = Players.LocalPlayer.PlayerGui:WaitForChild("MobileControlsGui")

	ContextActionService:BindAction(Config.MECH_RELOAD_ACTION, MechInputController.HandleMechReload, true, Enum.KeyCode.R)
	ContextActionService:SetTitle(Config.MECH_RELOAD_ACTION, "")
	ContextActionService:SetImage(Config.MECH_RELOAD_ACTION, "rbxassetid://121684437247046")

	local reloadBtn = ContextActionService:GetButton(Config.MECH_RELOAD_ACTION)
	if reloadBtn then formatMobileButton(reloadBtn, mobileContainer, 0.11, UDim2.new(0.84, 0, 0.48, 0), 50) end

	local canJump = mechData.Seat:GetAttribute("CanJump") == true
	local canSprint = mechData.Seat:GetAttribute("CanSprint") == true

	if canJump or canSprint then
		ContextActionService:BindAction(Config.MECH_MOBILITY_ACTION, MechInputController.HandleMobilityAction, true, Enum.KeyCode.LeftShift)
		ContextActionService:SetTitle(Config.MECH_MOBILITY_ACTION, "")
		ContextActionService:SetImage(Config.MECH_MOBILITY_ACTION, "rbxassetid://91491509088047")
		local mobilityBtn = ContextActionService:GetButton(Config.MECH_MOBILITY_ACTION)
		if mobilityBtn then formatMobileButton(mobilityBtn, mobileContainer, 0.11, UDim2.new(0.77, 0, 0.42, 0), 50) end
	end
end

function MechInputController.UnbindPilotControls()
	ContextActionService:UnbindAction(Config.MECH_RELOAD_ACTION)
	ContextActionService:UnbindAction(Config.MECH_MOBILITY_ACTION)
end

return MechInputController