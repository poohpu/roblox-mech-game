local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local CombatGuard = {}

-- Decide whether it's player, character or mech model
function CombatGuard.GetPilot(entity)
	if not entity then return nil end
	if entity:IsA("Player") then return entity end

	-- Check if it's a character
	local fromChar = Players:GetPlayerFromCharacter(entity)
	if fromChar then return fromChar end

	-- Check if it's a mech with an occupant
	if CollectionService:HasTag(entity, "Vehicle") then
		local seat = entity:FindFirstChildWhichIsA("VehicleSeat", true)
		if seat and seat.Occupant then
			return Players:GetPlayerFromCharacter(seat.Occupant.Parent)
		end
	end

	return nil
end

-- Evaluates whether an attacker is allowed to damage or stagger a target
function CombatGuard.CanAffect(attackerEntity, targetInstance)
	if not attackerEntity or not targetInstance or not targetInstance.Parent then 
		return false 
	end

	local attackerPlayer = CombatGuard.GetPilot(attackerEntity)
	local targetModel = targetInstance:IsA("Model") and targetInstance or targetInstance:FindFirstAncestorWhichIsA("Model")
	if not targetModel or targetModel == workspace then 
		return true -- Hit loose environment or unparented part
	end

	-- 1. Identify Target Type
	local isMech = CollectionService:HasTag(targetModel, "Vehicle")
	local isHumanoid = targetModel:FindFirstChild("Humanoid") ~= nil and not isMech
	local targetPlayer = isHumanoid and Players:GetPlayerFromCharacter(targetModel)

	-- 2. Lobby Guard (Blocks all combat if either party is in "Lobby")
	if (attackerPlayer and attackerPlayer.Team and attackerPlayer.Team.Name == "Lobby")
		or (targetPlayer and targetPlayer.Team and targetPlayer.Team.Name == "Lobby") then
		return false
	end

	-- 3. Pilot-to-Pilot Friendly Fire Guard
	if isHumanoid and attackerPlayer and targetPlayer then
		if attackerPlayer.Team ~= nil and attackerPlayer.Team == targetPlayer.Team then
			return false
		end
		return true
	end

	-- 4. Vehicle Combat & Abandonment Guard
	if isMech then
		local mechTeam = targetModel:GetAttribute("Team")
		if mechTeam == "Lobby" then return false end

		-- Check if attacker and target mech belong to the same team
		local isTeammate = attackerPlayer and attackerPlayer.Team and (attackerPlayer.Team.Name == mechTeam)

		if isTeammate then
			local seat = targetModel:FindFirstChildWhichIsA("VehicleSeat", true)

			-- Rule A: Occupied friendly mechs have absolute immunity
			if seat and seat.Occupant ~= nil then
				return false
			end

			-- Rule B: Dismounted repair protection
			local ownerId = targetModel:GetAttribute("OwnerId")
			local ownerPlayer = ownerId and Players:GetPlayerByUserId(ownerId)

			if ownerPlayer and ownerPlayer.Character then
				local ownerHumanoid = ownerPlayer.Character:FindFirstChild("Humanoid")
				if ownerHumanoid and ownerHumanoid.Health > 0 then
					-- Check if the owner is seated inside a DIFFERENT vehicle
					local currentSeat = ownerHumanoid.SeatPart
					local isPilotingOtherVehicle = currentSeat 
						and currentSeat:IsA("VehicleSeat") 
						and not currentSeat:IsDescendantOf(targetModel)

					-- If they are driving another mech, proximity protection is revoked
					if not isPilotingOtherVehicle then
						local seatPos = seat and seat.Position or targetInstance.Position
						local dist = ownerPlayer:DistanceFromCharacter(seatPos)
						if dist > 0 and dist <= 50 then
							return false -- Pilot is nearby on foot repairing
						end
					end
				end
			end

			-- Rule C: Abandoned hull (allies can destroy to clear the lane)
			return true
		end
	end

	return true
end

return CombatGuard