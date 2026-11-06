local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local moduleScripts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ModuleScripts")
local toolModules = moduleScripts:WaitForChild("ToolModules")

local MobileUtil = require(moduleScripts:WaitForChild("MobileUtil"))
local isMobile = MobileUtil.isMobile()

local KnifeToolModule = require(toolModules:WaitForChild("KnifeToolModule"))
local PistolToolModule = require(toolModules:WaitForChild("PistolToolModule"))

local activeToolInstance = nil
local activeToolConnection = nil
local aimConnection = nil

local characterBaseC0s = {}

local function onCharacterAdded(character)
	local rootPart = character:WaitForChild("HumanoidRootPart")
	local humanoid = character:WaitForChild("Humanoid")

	-- Store default baseline C0s ONCE per character life
	characterBaseC0s[character] = {
		Waist = character:WaitForChild("UpperTorso"):WaitForChild("Waist").C0,
		Neck = character:WaitForChild("Head"):WaitForChild("Neck").C0,
		RightShoulder = character:WaitForChild("RightUpperArm"):WaitForChild("RightShoulder").C0,
		RightElbow = character:WaitForChild("RightLowerArm"):WaitForChild("RightElbow").C0,
		LeftShoulder = character:WaitForChild("LeftUpperArm"):WaitForChild("LeftShoulder").C0,
		LeftElbow = character:WaitForChild("LeftLowerArm"):WaitForChild("LeftElbow").C0,
	}

	humanoid.Died:Connect(function()
		characterBaseC0s[character] = nil
	end)

	character.ChildAdded:Connect(function(child)
		if not child:IsA("Tool") then return end

		local cleanC0s = characterBaseC0s[character]
		local isKnife = (child.Name == "Knife")
		local isPistol = (child.Name == "Pistol")

		if not isKnife and not isPistol then return end

		if isKnife then
			activeToolInstance = KnifeToolModule.new(child)
			activeToolInstance:SetupJoints(character, cleanC0s)
			activeToolInstance:OnEquipped(character)
		elseif isPistol then
			activeToolInstance = PistolToolModule.new(child)
			activeToolInstance:SetupJoints(character, cleanC0s)
			activeToolInstance:OnEquipped(character)
		end

		humanoid.AutoRotate = false

		-- 1. Attack / Fire input connection
		activeToolConnection = child.Activated:Connect(function()
			if activeToolInstance then
				activeToolInstance:OnActivated(player)
			end
		end)

		-- 2. Aim & Spine posture tracking loop
		aimConnection = RunService.PreRender:Connect(function()
			if not character or not rootPart or not activeToolInstance then return end

			local camera = workspace.CurrentCamera
			local lookVector = camera.CFrame.LookVector
			local rootPos = rootPart.Position

			-- Horizontal Body Yaw Rotation
			if isMobile then
				-- Mobile: Lock character body to face camera look direction
				local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z).Unit
				if flatLook.Magnitude > 0.1 then
					rootPart.CFrame = CFrame.lookAt(rootPos, rootPos + flatLook)
				end
			else
				-- PC: Face mouse target position
				local mousePos = player:GetMouse().Hit.Position
				local flatTarget = Vector3.new(mousePos.X, rootPos.Y, mousePos.Z)
				if (flatTarget - rootPos).Magnitude > 0.1 then
					rootPart.CFrame = CFrame.lookAt(rootPos, flatTarget)
				end
			end

			-- Vertical Pitch Angle
			local pitch = math.asin(math.clamp(lookVector.Y, -1, 1))

			-- Crosshair overlay positioning
			local cursorGui = player.PlayerGui:FindFirstChild("CursorGui")
			if cursorGui then
				local crosshair = cursorGui:FindFirstChild("Crosshair")
				if crosshair and crosshair.Visible then
					if isMobile then
						-- Lock crosshair precisely to the center of the screen
						local viewport = camera.ViewportSize
						crosshair.Position = UDim2.fromOffset(viewport.X * 0.5, viewport.Y * 0.5)
					else
						-- Follow mouse location on PC
						local screenPos = UserInputService:GetMouseLocation()
						crosshair.Position = UDim2.fromOffset(screenPos.X, screenPos.Y)
					end
				end
			end

			activeToolInstance:UpdatePosture(pitch)
		end)
	end)

	character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") and (child.Name == "Knife" or child.Name == "Pistol") then
			if activeToolConnection then
				activeToolConnection:Disconnect()
				activeToolConnection = nil
			end
			if aimConnection then
				aimConnection:Disconnect()
				aimConnection = nil
			end

			if activeToolInstance then
				activeToolInstance:OnUnequipped()
				activeToolInstance = nil
			end

			humanoid.AutoRotate = true
		end
	end)
end

if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)