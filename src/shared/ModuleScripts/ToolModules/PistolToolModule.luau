local PistolToolModule = {}
PistolToolModule.__index = PistolToolModule

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer

local rojoShared = ReplicatedStorage:WaitForChild("Shared")
local moduleScripts = rojoShared:WaitForChild("ModuleScripts")
local MobileUtil = require(moduleScripts:WaitForChild("MobileUtil"))
local isMobile = MobileUtil.isMobile()

local pistolFireEvent = ReplicatedStorage:WaitForChild("PistolFire")
local pistolFiredEvent = ReplicatedStorage:WaitForChild("PistolFired")
local pilotAimEvent = ReplicatedStorage:WaitForChild("PilotAim")

local RELOAD_ACTION = "PistolReload"
local BASE_SCREEN_HEIGHT = 580
local BASE_CROSSHAIR_SIZE = 40
local MOUSE_ICON = "rbxasset://textures/GunCursor.png"
local RELOADING_ICON = "rbxasset://textures/GunWaitCursor.png"

local COOLDOWN = 0.15
local MAX_RANGE = 300
local BULLET_SPEED = 550
local MAX_AMMO = 12
local RELOAD_TIME = 1.5
local MOVE_ZONE_X = 0.4
local AIM_SYNC_RATE = 0.05

-- Global listener for remote player tracer effects (registered once)
local remoteTracerConnection = nil

local function playRemoteEffects(shooter)
	local char = shooter.Character
	if not char then return end

	local gun = char:FindFirstChildOfClass("Tool")
	if not gun then return end

	local gunBarrel = gun:FindFirstChild("Barrel")
	local muzzle = gunBarrel and gunBarrel:FindFirstChild("MuzzlePistol")
	if not muzzle then return end

	local sound = muzzle:FindFirstChild("FireSound")
	local flash = muzzle:FindFirstChild("MuzzleFlash")

	if sound then sound:Play() end
	if flash then flash:Emit(2) end
end

local function renderTracer(shooter, origin, direction)
	local tracer = Instance.new("Part")
	tracer.Size = Vector3.new(0.15, 0.15, 1.5)
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.Color = Color3.fromRGB(255, 215, 100)
	tracer.Material = Enum.Material.Neon
	tracer.CFrame = CFrame.lookAt(origin, origin + direction)

	local trashFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("TrashPart")
	tracer.Parent = trashFolder or workspace

	local distanceTraveled = 0
	local connection = nil

	connection = RunService.Heartbeat:Connect(function(deltaTime)
		local stepDistance = BULLET_SPEED * deltaTime
		distanceTraveled += stepDistance

		if distanceTraveled >= MAX_RANGE then
			connection:Disconnect()
			tracer:Destroy()
			return
		end

		local stepVector = direction * stepDistance
		local currentPos = tracer.Position

		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.CollisionGroup = "Players"

		local hitResult = workspace:Raycast(currentPos, stepVector, rayParams)
		if hitResult then
			connection:Disconnect()
			tracer:Destroy()
		else
			tracer.CFrame = tracer.CFrame + stepVector
		end
	end)
end

if not remoteTracerConnection then
	remoteTracerConnection = pistolFiredEvent.OnClientEvent:Connect(function(shooter, muzzlePos, launchDirection)
		if shooter == player then return end
		playRemoteEffects(shooter)
		renderTracer(shooter, muzzlePos, launchDirection)
	end)
end

function PistolToolModule.new(toolInstance)
	local self = setmetatable({}, PistolToolModule)
	self.Tool = toolInstance
	self.Character = nil
	self.Humanoid = nil

	self.CurrentAmmo = MAX_AMMO
	self.IsReloading = false
	self.CanFire = true
	self.Equipped = false
	self.LastAimSync = 0

	self.AimTouch = nil
	self.AimScreenPos = nil
	self.TouchConnections = {}

	local barrel = toolInstance:WaitForChild("Barrel", 3)
	self.Barrel = barrel
	self.MuzzleAttachment = barrel and barrel:FindFirstChild("MuzzlePistol")
	self.MuzzleFlash = self.MuzzleAttachment and self.MuzzleAttachment:FindFirstChild("MuzzleFlash")
	self.FireSound = self.MuzzleAttachment and self.MuzzleAttachment:FindFirstChild("FireSound")

	return self
end

function PistolToolModule:SetupJoints(character, cleanC0s)
	if not character then return end

	local upperTorso = character:FindFirstChild("UpperTorso")
	local head = character:FindFirstChild("Head")
	local rightUpperArm = character:FindFirstChild("RightUpperArm")

	self.WaistJoint = upperTorso and upperTorso:FindFirstChild("Waist")
	self.NeckJoint = head and head:FindFirstChild("Neck")
	self.RightShoulder = rightUpperArm and rightUpperArm:FindFirstChild("RightShoulder")

	if cleanC0s then
		self.BaseWaistC0 = cleanC0s.Waist
		self.BaseNeckC0 = cleanC0s.Neck
		self.BaseRightShoulderC0 = cleanC0s.RightShoulder
	end
end

function PistolToolModule:ResetJoints()
	if self.WaistJoint and self.BaseWaistC0 then self.WaistJoint.C0 = self.BaseWaistC0 end
	if self.NeckJoint and self.BaseNeckC0 then self.NeckJoint.C0 = self.BaseNeckC0 end
	if self.RightShoulder and self.BaseRightShoulderC0 then self.RightShoulder.C0 = self.BaseRightShoulderC0 end
end

function PistolToolModule:UpdateAmmoDisplay()
	local playerGui = player:FindFirstChild("PlayerGui")
	local handheldHUD = playerGui and playerGui:FindFirstChild("HandHeldWeaponHUD")
	if handheldHUD then
		local ammoHUD = handheldHUD:FindFirstChild("Frame")
			and handheldHUD.Frame:FindFirstChild("WeaponFrame")
			and handheldHUD.Frame.WeaponFrame:FindFirstChild("AmmoHUD")
		if ammoHUD then
			ammoHUD.Text = string.format("%d / %d", self.CurrentAmmo, MAX_AMMO)
		end
	end
end

function PistolToolModule:ResetUI()
	local cursorGui = player.PlayerGui:FindFirstChild("CursorGui")
	if cursorGui then
		local crosshair = cursorGui:FindFirstChild("Crosshair")
		if crosshair then
			crosshair.Visible = false
			crosshair.Image = MOUSE_ICON
		end
	end

	local handheldHUD = player.PlayerGui:FindFirstChild("HandHeldWeaponHUD")
	if handheldHUD then
		handheldHUD.Enabled = false
	end
	UserInputService.MouseIconEnabled = true
end

function PistolToolModule:OnEquipped(character)
	self.Character = character
	self.Humanoid = character:FindFirstChildOfClass("Humanoid")

	if self.Humanoid and self.Humanoid.Sit then
		self.Humanoid:UnequipTools()
		return
	end

	self.Equipped = true

	local cursorGui = player.PlayerGui:FindFirstChild("CursorGui")
	if cursorGui then
		local crosshair = cursorGui:FindFirstChild("Crosshair")
		if crosshair then
			local currentScreenHeight = workspace.CurrentCamera.ViewportSize.Y
			local scaleFactor = currentScreenHeight / BASE_SCREEN_HEIGHT
			local adjustedSize = math.round(BASE_CROSSHAIR_SIZE * scaleFactor)

			cursorGui.IgnoreGuiInset = true
			crosshair.Size = UDim2.fromOffset(adjustedSize, adjustedSize)
			crosshair.Visible = true
			UserInputService.MouseIconEnabled = false
		end
	end

	local handheldHUD = player.PlayerGui:FindFirstChild("HandHeldWeaponHUD")
	if handheldHUD then
		handheldHUD.Enabled = true
		self:UpdateAmmoDisplay()
	end

	ContextActionService:BindAction(RELOAD_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin then
			self:Reload()
		end
	end, true, Enum.KeyCode.R)

	ContextActionService:SetTitle(RELOAD_ACTION, "")
	ContextActionService:SetImage(RELOAD_ACTION, "rbxassetid://121684437247046")

	local reloadBtn = ContextActionService:GetButton(RELOAD_ACTION)
	if reloadBtn then
		reloadBtn.Position = UDim2.new(0.45, 0, -0.2, 0)
		reloadBtn.Size = UDim2.new(0.2, 0, 0.2, 0)

		local ratio = reloadBtn:FindFirstChildOfClass("UIAspectRatioConstraint")
		if not ratio then
			ratio = Instance.new("UIAspectRatioConstraint")
			ratio.AspectRatio = 1
			ratio.Parent = reloadBtn
		end
	end

	if isMobile then
		self:SetupMobileControls()
	end
end

function PistolToolModule:SetupMobileControls()
	local function touchToViewport(input)
		return Vector2.new(input.Position.X, input.Position.Y) + GuiService:GetGuiInset()
	end

	table.insert(self.TouchConnections, UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType ~= Enum.UserInputType.Touch or processed then return end
		local cam = workspace.CurrentCamera
		if input.Position.X < cam.ViewportSize.X * MOVE_ZONE_X then return end

		self.AimTouch = input
		self.AimScreenPos = touchToViewport(input)
	end))

	table.insert(self.TouchConnections, UserInputService.InputChanged:Connect(function(input)
		if input == self.AimTouch then
			self.AimScreenPos = touchToViewport(input)
		end
	end))

	table.insert(self.TouchConnections, UserInputService.InputEnded:Connect(function(input)
		if input == self.AimTouch then
			self.AimTouch = nil
		end
	end))
end

function PistolToolModule:GetTargetPosition()
	if isMobile then
		local screenPos = self.AimScreenPos or (workspace.CurrentCamera.ViewportSize * 0.5)
		local cam = workspace.CurrentCamera
		local unitRay = cam:ViewportPointToRay(screenPos.X, screenPos.Y)

		local aimParams = RaycastParams.new()
		aimParams.FilterType = Enum.RaycastFilterType.Exclude
		aimParams.FilterDescendantsInstances = { self.Character, self.Tool }
		aimParams.CollisionGroup = "Players"

		local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * MAX_RANGE, aimParams)
		return result and result.Position or (unitRay.Origin + unitRay.Direction * MAX_RANGE)
	end
	return player:GetMouse().Hit.Position
end

function PistolToolModule:UpdatePosture(pitch)
	if not self.Equipped or not self.Character then return end

	local now = os.clock()
	if now - self.LastAimSync >= AIM_SYNC_RATE then
		self.LastAimSync = now
		pilotAimEvent:FireServer(pitch)
	end

	local waistPitch = pitch * 0.20
	local neckPitch = pitch * 0.30
	local armPitch = pitch * 0.50

	if self.WaistJoint and self.BaseWaistC0 then
		self.WaistJoint.C0 = self.BaseWaistC0 * CFrame.Angles(waistPitch, 0, 0)
	end
	if self.NeckJoint and self.BaseNeckC0 then
		self.NeckJoint.C0 = self.BaseNeckC0 * CFrame.Angles(neckPitch, 0, 0)
	end
	if self.RightShoulder and self.BaseRightShoulderC0 then
		self.RightShoulder.C0 = self.BaseRightShoulderC0 * CFrame.Angles(armPitch, 0, 0)
	end
end

function PistolToolModule:Reload()
	if self.IsReloading or not self.Equipped or self.CurrentAmmo >= MAX_AMMO then return end
	self.IsReloading = true

	local cursorGui = player.PlayerGui:FindFirstChild("CursorGui")
	local crosshair = cursorGui and cursorGui:FindFirstChild("Crosshair")
	if crosshair then
		crosshair.Image = RELOADING_ICON
	end

	local handheldHUD = player.PlayerGui:FindFirstChild("HandHeldWeaponHUD")
	local ammoHUD = handheldHUD and handheldHUD.Frame.WeaponFrame:FindFirstChild("AmmoHUD")
	if ammoHUD then
		ammoHUD.Text = "Reloading..."
	end

	task.wait(RELOAD_TIME)

	if self.Equipped then
		self.CurrentAmmo = MAX_AMMO
		self:UpdateAmmoDisplay()
		if crosshair then
			crosshair.Image = MOUSE_ICON
		end
	end

	self.IsReloading = false
end

function PistolToolModule:FireProjectile(origin, direction)
	local tracer = Instance.new("Part")
	tracer.Size = Vector3.new(0.15, 0.15, 1.5)
	tracer.Anchored = true
	tracer.CanCollide = false
	tracer.CanQuery = false
	tracer.Color = Color3.fromRGB(255, 215, 100)
	tracer.Material = Enum.Material.Neon
	tracer.CFrame = CFrame.lookAt(origin, origin + direction)

	local trashFolder = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("TrashPart")
	tracer.Parent = trashFolder or workspace

	local bulletIgnoreList = { self.Character, self.Tool }
	local distanceTraveled = 0
	local connection = nil

	connection = RunService.Heartbeat:Connect(function(deltaTime)
		local stepDistance = BULLET_SPEED * deltaTime
		distanceTraveled += stepDistance

		if distanceTraveled >= MAX_RANGE then
			connection:Disconnect()
			tracer:Destroy()
			return
		end

		local stepVector = direction * stepDistance
		local currentPos = tracer.Position

		local rayParams = RaycastParams.new()
		rayParams.FilterDescendantsInstances = bulletIgnoreList
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.CollisionGroup = "Players"

		local hitResult = workspace:Raycast(currentPos, stepVector, rayParams)
		if hitResult then
			connection:Disconnect()
			tracer:Destroy()
			pistolFireEvent:FireServer(hitResult.Instance, hitResult.Position)
		else
			tracer.CFrame = tracer.CFrame + stepVector
		end
	end)
end

function PistolToolModule:OnActivated()
	if not self.Equipped or not self.CanFire or self.IsReloading then return end
	if self.Humanoid and self.Humanoid.Sit then return end

	if self.CurrentAmmo <= 0 then
		task.spawn(function() self:Reload() end)
		return
	end

	self.CanFire = false
	self.CurrentAmmo -= 1
	self:UpdateAmmoDisplay()

	if self.FireSound then self.FireSound:Play() end
	if self.MuzzleFlash then self.MuzzleFlash:Emit(2) end

	local targetPos = self:GetTargetPosition()
	local muzzlePos = self.MuzzleAttachment and self.MuzzleAttachment.WorldPosition or self.Barrel.Position
	local launchDirection = (targetPos - muzzlePos).Unit

	self:FireProjectile(muzzlePos, launchDirection)
	pistolFiredEvent:FireServer(muzzlePos, launchDirection)

	if self.CurrentAmmo <= 0 then
		task.spawn(function() self:Reload() end)
	end

	task.wait(COOLDOWN)
	self.CanFire = true
end

function PistolToolModule:OnUnequipped()
	self.Equipped = false
	pilotAimEvent:FireServer(0)

	for _, conn in ipairs(self.TouchConnections) do
		conn:Disconnect()
	end
	table.clear(self.TouchConnections)

	self.AimTouch = nil
	self.AimScreenPos = nil

	self:ResetUI()
	ContextActionService:UnbindAction(RELOAD_ACTION)

	if self.Humanoid then
		self.Humanoid.AutoRotate = true
	end

	self:ResetJoints()
end

return PistolToolModule