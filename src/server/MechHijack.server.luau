local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local function applyTeamHue(originalColor, teamColor)
	local _, _, origLightness = originalColor:ToHSV() 
	local teamH, teamS, _ = teamColor:ToHSV() 
	return Color3.fromHSV(teamH, teamS, origLightness)
end

local function GetMechRoot(mechModel) return mechModel:FindFirstChild("Hip", true) or mechModel:FindFirstChild("Chassis", true) end

--local function ApplyCharacterCollisionGroup(player, character)
	--if not character or not player.Team or player.Team.Name == "Lobby" then return end

	--local teamGroup = (player.Team.Name == "Blue Team") and "TeamAMembers" or "TeamBMembers"

	--for _, part in ipairs(character:GetDescendants()) do
	--	if part:IsA("BasePart") and (part.CollisionGroup == "Default" or part.CollisionGroup == "Players") then
	--		part.CollisionGroup = teamGroup
	--	end
	--end
--end

local function syncMechTeam(mechModel, player)
	if not player or not player.Team or player.Team.Name == "Lobby" then return end

	local playerTeamColor = player.TeamColor.Color
	local TeamAccentColor = game:GetService("Teams")[player.Team.Name]:GetAttribute("AccentColor")
	local mechCurrentColor = mechModel:GetAttribute("CurrentTeamColor")

	mechModel:SetAttribute("OwnerId", player.UserId)
	mechModel:SetAttribute("Team", player.Team.Name)
	
	local teamGroup = (player.Team.Name == "Blue Team") and "TeamAMembers" or "TeamBMembers"
	local teamArmor = (player.Team.Name == "Blue Team") and "TeamA_Armor" or "TeamB_Armor"
	
	-- Assign all physical Default parts on the mech to the team group
	for _, part in ipairs(mechModel:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then
			-- Only update parts sitting on Default so custom groups like MechArmor aren't touched
			if part.CollisionGroup == "MechArmor" or part.CollisionGroup == "TeamA_Armor" or part.CollisionGroup == "TeamB_Armor" then
				part.CollisionGroup = teamArmor
			elseif part.CanCollide and part.CollisionGroup == "Default" then
				part.CollisionGroup = teamGroup
			end
		end
	end
	
	--ApplyCharacterCollisionGroup(player, player.Character)
	
	local driveCore = mechModel:FindFirstChild("TargetGround", true)
	if driveCore then driveCore.CollisionGroup = teamGroup end

	local hip = GetMechRoot(mechModel)
	if hip then hip.CollisionGroup = teamGroup end

	local hitbox = mechModel:FindFirstChild("MechHitbox", true) or mechModel:FindFirstChild("Torso", true)
	if hitbox then hitbox.CollisionGroup = teamGroup end

	-- Check if a repaint is needed
	if playerTeamColor ~= mechCurrentColor then
		print(player.Name .. " claimed/hijacked mech! Repainting to " .. tostring(player.Team))

		mechModel:SetAttribute("CurrentTeamColor", playerTeamColor)
		if TeamAccentColor then
			mechModel:SetAttribute("CurrentAccentColor", TeamAccentColor)
		end

		for _, part in ipairs(mechModel:GetDescendants()) do
			if part:IsA("BasePart") then
				if part:GetAttribute("Colorable") == true then
					-- Use the existing BaseColor (or current Color) to derive the clean team color
					local cleanBase = part:GetAttribute("BaseColor") or part.Color
					local newTeamBase = applyTeamHue(cleanBase, playerTeamColor)
					
					-- update the attribute so repair use the new color
					part:SetAttribute("BaseColor", newTeamBase)
					
					part.Color = applyTeamHue(part.Color, playerTeamColor)
				elseif part:GetAttribute("AccentColorable") == true then
					if TeamAccentColor then
						part.Color = TeamAccentColor
						part:SetAttribute("BaseColor", TeamAccentColor)
					end
				end
			end
		end
	end
end


local function handleMechHijack(mechModel)
	local seat = mechModel:FindFirstChildWhichIsA("VehicleSeat", true)
	if not seat then return end

	-- Store the original paint job the first time the mech is touched
	if not mechModel:GetAttribute("CurrentTeamColor") then
		-- Default to White if it doesn't have a color yet
		mechModel:SetAttribute("CurrentTeamColor", Color3.fromRGB(255, 255, 255))
	end
	
	local pilotTeamConnection = nil

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if pilotTeamConnection then
			pilotTeamConnection:Disconnect()
			pilotTeamConnection = nil
		end
		local occupant = seat.Occupant
		if occupant then
			local player = Players:GetPlayerFromCharacter(occupant.Parent)
			if not player then return end
			syncMechTeam(mechModel, player)
			
			pilotTeamConnection = player:GetPropertyChangedSignal("Team"):Connect(function()
				syncMechTeam(mechModel, player)
			end)
		end
	end)
end

-- Hook up all existing and future mechs
for _, mech in ipairs(CollectionService:GetTagged("Vehicle")) do
	handleMechHijack(mech)
end

CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(handleMechHijack)