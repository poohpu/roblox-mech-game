local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local moduleScripts = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ModuleScripts")
local toolModules = moduleScripts:WaitForChild("ToolModules")
local KnifeToolModule = require(toolModules:WaitForChild("KnifeToolModule"))

local activeKnifeInstance = nil
local activeToolConnection = nil
local aimConnection = nil

local characterBaseC0s = {}

local function onCharacterAdded(character)
	local rootPart = character:WaitForChild("HumanoidRootPart")
	local humanoid = character:WaitForChild("Humanoid")

	-- Store true default C0s ONCE before any tool modifies them
	characterBaseC0s[character] = {
		Waist = character:WaitForChild("UpperTorso"):WaitForChild("Waist").C0,
		Neck = character:WaitForChild("Head"):WaitForChild("Neck").C0,
		RightShoulder = character:WaitForChild("RightUpperArm"):WaitForChild("RightShoulder").C0,
		RightElbow = character:WaitForChild("RightLowerArm"):WaitForChild("RightElbow").C0,
		LeftShoulder = character:WaitForChild("LeftUpperArm"):WaitForChild("LeftShoulder").C0,
		LeftElbow = character:WaitForChild("LeftLowerArm"):WaitForChild("LeftElbow").C0,
	}

	-- Clean up memory when character despawns/dies
	humanoid.Died:Connect(function()
		characterBaseC0s[character] = nil
	end)

	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and child.Name == "Knife" then
	local cleanC0s = characterBaseC0s[character]

			activeKnifeInstance = KnifeToolModule.new(child)
			activeKnifeInstance:SetupJoints(character, cleanC0s)

			-- Disable default character rotation so body turns with camera ray/mouse
			humanoid.AutoRotate = false

			-- 1. Attack activation
			activeToolConnection = child.Activated:Connect(function()
				if activeKnifeInstance then
					activeKnifeInstance:OnActivated(player)
				end
			end)

			-- 2. Frame-by-frame camera facing & torso pitch aiming
			aimConnection = RunService.PreRender:Connect(function()
				local camera = workspace.CurrentCamera
				if not character or not rootPart then return end

				local lookVector = camera.CFrame.LookVector

				-- Rotate whole body horizontally (Yaw) towards camera look direction
				local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z).Unit
				if flatLook.Magnitude > 0.1 then
					rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + flatLook)
				end

				-- Calculate pitch angle (-1 to 1 rad) for spine tilt
				local pitch = math.asin(math.clamp(lookVector.Y, -1, 1))

				if activeKnifeInstance then
					activeKnifeInstance:UpdatePosture(pitch)
				end
			end)
		end
	end)

	character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") and child.Name == "Knife" then
			if activeToolConnection then
				activeToolConnection:Disconnect()
				activeToolConnection = nil
			end
			if aimConnection then
				aimConnection:Disconnect()
				aimConnection = nil
			end

			if activeKnifeInstance then
				activeKnifeInstance:OnUnequipped() 
				activeKnifeInstance = nil
			end

			humanoid.AutoRotate = true
		end
	end)
end

if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)