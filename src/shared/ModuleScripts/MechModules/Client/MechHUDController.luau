--Location: ReplicatedStorage.ModuleScripts.MechModules.Client.MechHUDController
--Function: Handles PaperDoll creation, status display scaling, tooltip rendering, armor caching, 
--and weapon HUD slot updates.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Config = require(script.Parent:WaitForChild("MechClientConfig"))
local MobileUtil = require(game:GetService("ReplicatedStorage"):WaitForChild("ModuleScripts"):WaitForChild("MobileUtil"))

local MechHUDController = {}

local liveArmorCaches = {}
local armorCacheDirty = {}
local mechOriginalArmorMax = {}
local previousStats = {}
local flashTimers = {}
local localPlayer = Players.LocalPlayer

function MechHUDController.FlagArmorCacheDirty(mechModel)
	if mechModel then armorCacheDirty[mechModel] = true end
end

local function getThreeColorGradient(percent, color100, color50, color0)
	if percent >= 0.5 then
		return color50:Lerp(color100, (percent - 0.5) * 2)
	else
		return color0:Lerp(color50, percent * 2)
	end
end

function MechHUDController.BuildArmorCache(mechModel)
	if liveArmorCaches[mechModel] and not armorCacheDirty[mechModel] then return liveArmorCaches[mechModel] end

	local armorCache = {}
	if not mechOriginalArmorMax[mechModel] then mechOriginalArmorMax[mechModel] = {} end

	local sortedKeys = {}
	for baseName, _ in pairs(Config.UI_TO_PART_MAP) do table.insert(sortedKeys, baseName) end
	table.sort(sortedKeys, function(a, b) return string.len(a) > string.len(b) end)

	for _, part in pairs(mechModel:GetDescendants()) do
		if part:GetAttribute("ComponentType") == "Armor" then
			for _, baseName in pairs(sortedKeys) do
				if string.find(part.Name, baseName) then
					if not armorCache[baseName] then armorCache[baseName] = {Current = 0, Max = 0} end
					armorCache[baseName].Current += (part:GetAttribute("CurrentHealth") or 0)
					armorCache[baseName].Max += (part:GetAttribute("MaxHealth") or 0)

					local currentSavedMax = mechOriginalArmorMax[mechModel][baseName] or 0
					if armorCache[baseName].Max > currentSavedMax then
						mechOriginalArmorMax[mechModel][baseName] = armorCache[baseName].Max
					end
					break
				end
			end
		end
	end

	for baseName, lockedMaxArmor in pairs(mechOriginalArmorMax[mechModel]) do
		if not armorCache[baseName] then
			armorCache[baseName] = {Current = 0, Max = lockedMaxArmor}
		else
			armorCache[baseName].Max = lockedMaxArmor
		end
	end

	liveArmorCaches[mechModel] = armorCache
	armorCacheDirty[mechModel] = false
	return armorCache
end

function MechHUDController.UpdateHUDStrokes()
	local MechHealthHUD = localPlayer.PlayerGui:FindFirstChild("MechHealthHUD")
	if not MechHealthHUD then return end
	local activeStage = MechHealthHUD:FindFirstChild("ActiveUITemplate")
	if not activeStage then return end

	local scaleFactor = workspace.CurrentCamera.ViewportSize.Y / Config.BASE_SCREEN_HEIGHT
	local adjustedThickness = math.round(Config.BASE_STROKE_THICKNESS * scaleFactor)

	for _, uiElement in pairs(activeStage:GetDescendants()) do
		if uiElement:IsA("UIStroke") then uiElement.Thickness = adjustedThickness end
	end
end

function MechHUDController.InitializePaperDoll(mechModel, paperDoll, mechOriginalParts)
	table.clear(previousStats)
	table.clear(flashTimers)
	local armorCache = MechHUDController.BuildArmorCache(mechModel)

	for uiName, partName in pairs(Config.UI_TO_PART_MAP) do
		local uiBlock = paperDoll:FindFirstChild(uiName, true)
		if uiBlock then
			if not mechOriginalParts[mechModel] or not mechOriginalParts[mechModel][partName] then
				uiBlock.Visible = false
			else
				uiBlock.Visible = true
				local mechPart = mechModel:FindFirstChild(partName)
				if not mechPart then
					uiBlock.BackgroundColor3 = Config.CORE_DEAD
					local stroke = uiBlock:FindFirstChildWhichIsA("UIStroke")
					if stroke then stroke.Enabled = true stroke.Transparency = 0 stroke.Color = Config.ARMOR_DEAD end
				else
					uiBlock.BackgroundColor3 = Config.CORE_100
					local stroke = uiBlock:FindFirstChildWhichIsA("UIStroke")
					if stroke then
						local armorData = armorCache[partName]
						if armorData and armorData.Max > 0 then
							stroke.Enabled = true stroke.Transparency = 0 stroke.Color = Config.ARMOR_100
						else
							stroke.Enabled = false
						end
					end
				end
			end
		end
	end
end

function MechHUDController.SetupHoverTooltips(mechModel, paperDoll, statusLabel)
	statusLabel.Visible = false
	local hoveredBone, hoveredBaseName, hoveredDisplayName = nil, "", ""

	for uiName, partName in pairs(Config.UI_TO_PART_MAP) do
		local uiBlock = paperDoll:FindFirstChild(uiName, true)
		if uiBlock and uiBlock.Visible then
			uiBlock.MouseEnter:Connect(function()
				local foundBone = nil
				for _, obj in pairs(mechModel:GetDescendants()) do
					if obj.Name == partName then
						local compType = obj:GetAttribute("ComponentType")
						if compType == "Skeleton" or compType == "Core" or compType == "Weapon" then
							foundBone = obj break
						end
					end
				end
				hoveredBone = foundBone or mechModel:FindFirstChild(partName, true)
				hoveredBaseName = partName
				hoveredDisplayName = Config.DISPLAY_NAMES[partName] or string.upper(partName)
				statusLabel.Visible = true
			end)
			uiBlock.MouseLeave:Connect(function()
				hoveredBone, hoveredBaseName = nil, ""
				statusLabel.Visible = false
			end)
		end
	end

	RunService:BindToRenderStep("MechTooltipScan", Enum.RenderPriority.Last.Value, function()
		if statusLabel.Visible then
			local screenHeight = workspace.CurrentCamera.ViewportSize.Y
			local scaleFactor = screenHeight / Config.BASE_SCREEN_HEIGHT
			statusLabel.Size = UDim2.new(0, math.round(Config.BASE_TOOLTIP_WIDTH * scaleFactor), 0, math.round(Config.BASE_TOOLTIP_HEIGHT * scaleFactor))
			statusLabel.TextSize = math.round(Config.BASE_FONT_SIZE * scaleFactor)

			if mechModel and hoveredBone and hoveredBone.Parent then
				local hp = math.round(hoveredBone:GetAttribute("CurrentHealth") or 0)
				local maxHp = math.round(hoveredBone:GetAttribute("MaxHealth") or 0)
				local armorData = MechHUDController.BuildArmorCache(mechModel)[hoveredBaseName] or {Current = 0, Max = 0}

				if armorData.Max > 0 then
					statusLabel.Text = string.format(" %s\n HP: %d/%d\n ARMOR: %d/%d", hoveredDisplayName, hp, maxHp, math.round(armorData.Current), math.round(armorData.Max))
				else
					statusLabel.Text = string.format(" %s\n HP: %d/%d", hoveredDisplayName, hp, maxHp)
				end
				statusLabel.TextColor3 = (hp <= 0) and Color3.new(0.8, 0, 0) or Color3.new(1, 1, 1)
			else
				statusLabel.Text = string.format(" %s\n [ DESTROYED ]", hoveredDisplayName)
				statusLabel.TextColor3 = Color3.new(0.8, 0, 0)
			end

			local mousePos = UserInputService:GetMouseLocation()
			local targetX = mousePos.X + (15 * scaleFactor)
			if targetX + statusLabel.Size.X.Offset > workspace.CurrentCamera.ViewportSize.X then targetX = mousePos.X - (15 * scaleFactor) - statusLabel.Size.X.Offset end
			local targetY = mousePos.Y - (8 * scaleFactor)
			if targetY - statusLabel.Size.Y.Offset < 0 then targetY = mousePos.Y + statusLabel.Size.Y.Offset + (8 * scaleFactor) end
			statusLabel.Position = UDim2.fromOffset(targetX, targetY)
		end
	end)
end

function MechHUDController.UpdatePaperDollColors(mechModel, paperDoll)
	local currentTime = os.clock()
	local armorCache = MechHUDController.BuildArmorCache(mechModel)

	for uiName, partName in pairs(Config.UI_TO_PART_MAP) do
		local uiBlock = paperDoll:FindFirstChild(uiName, true)
		if uiBlock and uiBlock.Visible then
			local mechPart = mechModel:FindFirstChild(partName)
			if mechPart then
				local maxHealth = mechPart:GetAttribute("MaxHealth") or 100
				local currentHealth = mechPart:GetAttribute("CurrentHealth") or 100
				local hpPercent = maxHealth > 0 and math.clamp(currentHealth / maxHealth, 0, 1) or 0

				local lastHP = previousStats[partName .. "_HP"] or currentHealth
				if currentHealth < lastHP then flashTimers[partName .. "_Core"] = currentTime end
				previousStats[partName .. "_HP"] = currentHealth

				local targetCoreColor = (currentHealth <= 0) and Config.CORE_DEAD or getThreeColorGradient(hpPercent, Config.CORE_100, Config.CORE_50, Config.CORE_0)
				local timeSinceCoreFlash = currentTime - (flashTimers[partName .. "_Core"] or 0)
				if timeSinceCoreFlash < Config.FLASH_DURATION then
					targetCoreColor = targetCoreColor:Lerp(Config.FLASH_COLOR, 1 - (timeSinceCoreFlash / Config.FLASH_DURATION))
				end
				uiBlock.BackgroundColor3 = targetCoreColor

				local stroke = uiBlock:FindFirstChildWhichIsA("UIStroke")
				if stroke and stroke.Enabled then
					local armorData = armorCache[partName] or {Current = 0, Max = 0}
					local armorPercent = armorData.Max > 0 and math.clamp(armorData.Current / armorData.Max, 0, 1) or 0

					local lastArmor = previousStats[partName .. "_Armor"] or armorData.Current
					if armorData.Current < lastArmor then flashTimers[partName .. "_Armor"] = currentTime end
					previousStats[partName .. "_Armor"] = armorData.Current

					local targetArmorColor = (armorData.Current <= 0) and Config.ARMOR_DEAD or getThreeColorGradient(armorPercent, Config.ARMOR_100, Config.ARMOR_50, Config.ARMOR_0)
					local timeSinceArmorFlash = currentTime - (flashTimers[partName .. "_Armor"] or 0)
					if timeSinceArmorFlash < Config.FLASH_DURATION then
						targetArmorColor = targetArmorColor:Lerp(Config.FLASH_COLOR, 1 - (timeSinceArmorFlash / Config.FLASH_DURATION))
					end
					stroke.Color = targetArmorColor
				end
			else
				uiBlock.BackgroundColor3 = Config.CORE_DEAD
				local stroke = uiBlock:FindFirstChildWhichIsA("UIStroke")
				if stroke and stroke.Enabled then stroke.Color = Config.ARMOR_DEAD end
			end
		end
	end
end

function MechHUDController.UpdateWeaponSlotDisplay(slotFrame, labelName, uiName, weapon, assignedGroup, weaponType)
	if not slotFrame then return false end
	local titleLabel = slotFrame:FindFirstChild(labelName)
	local ammoLabel = slotFrame:FindFirstChild(uiName)
	if not ammoLabel then return false end

	if not weaponType or weaponType == "" then
		ammoLabel.Text = "-"
		ammoLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
		ammoLabel.BackgroundTransparency = 0
		if titleLabel then titleLabel.BackgroundTransparency = 0 end
		return false
	end

	if not weapon then
		ammoLabel.Text = "DESTROYED"
		ammoLabel.TextColor3 = Color3.new(0.77, 0, 0)
		ammoLabel.BackgroundTransparency = 0
		if titleLabel then titleLabel.BackgroundTransparency = 0 end
		return false
	end

	local isToggledOn = true
	if MobileUtil.isMobile() and MobileUtil.WeaponToggles[assignedGroup] ~= nil then
		isToggledOn = MobileUtil.WeaponToggles[assignedGroup]
	end

	if not isToggledOn then
		ammoLabel.Text = "TOGGLED OFF"
		ammoLabel.TextColor3 = Color3.fromRGB(1, 0.2, 0.2)
		ammoLabel.BackgroundTransparency = 0.6
		if titleLabel then titleLabel.BackgroundTransparency = 0.6 end
		return false
	end

	if titleLabel then titleLabel.TextColor3 = Color3.new(0, 0, 0) end

	if weapon.IsReloading then
		ammoLabel.Text = weapon.CurrentAmmo and "RELOADING..." or "COOLDOWN..."
		ammoLabel.TextColor3 = Color3.new(1, 0.2, 0.2)
		ammoLabel.BackgroundTransparency = 0
		if titleLabel then titleLabel.BackgroundTransparency = 0 end
		return true
	end

	if weapon.CurrentAmmo then
		ammoLabel.Text = string.format("%s: %d / %d", tostring(weapon.WeaponName), weapon.CurrentAmmo, weapon.MaxAmmo)
	else
		ammoLabel.Text = tostring(weapon.WeaponName) .. ": READY"
	end
	ammoLabel.TextColor3 = Color3.new(0, 0, 0)
	ammoLabel.BackgroundTransparency = 0
	if titleLabel then titleLabel.BackgroundTransparency = 0 end
	return false
end

-- ==============================================
-- NEW FUNCTIONS: HUD MOUNTING / UNMOUNTING
-- ==============================================

function MechHUDController.MountMechHUD(mechModel, mechData, mechOriginalParts)
	local MechHealthHUD = localPlayer.PlayerGui:FindFirstChild("MechHealthHUD")
	if MechHealthHUD then MechHealthHUD.Enabled = true end

	local MechWeaponHUD = localPlayer.PlayerGui:FindFirstChild("MechWeaponHUD")
	if MechWeaponHUD then MechWeaponHUD.Enabled = true end
	
	local hudTypeName = mechData.Seat:GetAttribute("HUD_Template") or "Bipedal_HUD"
	local activeStage = MechHealthHUD:FindFirstChild("ActiveUITemplate")

	if activeStage then
		for _, oldUI in pairs(activeStage:GetChildren()) do if oldUI:IsA("Frame") then oldUI:Destroy() end end

		local templateFolder = MechHealthHUD:FindFirstChild("Templates")
		if templateFolder then
			local correctBlueprint = templateFolder:FindFirstChild(hudTypeName)
			if correctBlueprint then
				local newUITemplate = correctBlueprint:Clone()
				newUITemplate.Parent = activeStage
				newUITemplate.Visible = true

				MechHUDController.UpdateHUDStrokes()
				MechHUDController.InitializePaperDoll(mechModel, newUITemplate, mechOriginalParts)

				local statusLabel = MechHealthHUD:FindFirstChild("HoverStatusText")
				if statusLabel then MechHUDController.SetupHoverTooltips(mechModel, newUITemplate, statusLabel) end
			end
		end
	end
end

function MechHUDController.UnmountMechHUD()
	local MechHealthHUD = localPlayer.PlayerGui:FindFirstChild("MechHealthHUD")
	if MechHealthHUD then MechHealthHUD.Enabled = false end

	local MechWeaponHUD = localPlayer.PlayerGui:FindFirstChild("MechWeaponHUD")
	if MechWeaponHUD then MechWeaponHUD.Enabled = false end

	local CursorGui = localPlayer.PlayerGui:FindFirstChild("CursorGui")
	if CursorGui then
		local crosshair = CursorGui:FindFirstChild("Crosshair")
		local secondary = CursorGui:FindFirstChild("SecondaryReticle")
		if crosshair then crosshair.Visible = false end
		if secondary then secondary.Visible = false end
	end

	UserInputService.MouseIconEnabled = true
end

return MechHUDController