local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

-- 🛑 IMPORTANT: Replace this number with your ACTUAL Roblox User ID!
local AUTHORIZED_DEVELOPER_ID = 113139919 

-- Helper function to find a player by full or partial username
local function findPlayer(query)
	if not query then return nil end
	query = string.lower(query)
	for _, p in ipairs(Players:GetPlayers()) do
		if string.find(string.lower(p.Name), query, 1, true) or string.find(string.lower(p.DisplayName), query, 1, true) then
			return p
		end
	end
	return nil
end

Players.PlayerAdded:Connect(function(player)
	player.Chatted:Connect(function(message)
		if player.UserId ~= AUTHORIZED_DEVELOPER_ID then return end

		local args = string.split(message, " ")
		local cmd = string.lower(args[1] or "")

		-- 1. CLEAR MECHS
		if cmd == "!clearmechs" then
			local allMechs = CollectionService:GetTagged("Vehicle")
			local deletedCount = 0

			for _, mech in ipairs(allMechs) do
				if mech:IsDescendantOf(workspace) then
					local seat = mech:FindFirstChildWhichIsA("VehicleSeat", true)
					if seat and not seat.Occupant then
						mech:Destroy()
						deletedCount += 1
					end
				end
			end
			print("Success! Wiped " .. deletedCount .. " empty mechs from the server.")

			-- 2. TEST DAMAGE
		elseif cmd == "!testdamage" then
			local character = player.Character
			local humanoid = character and character:FindFirstChild("Humanoid")
			local seat = humanoid and humanoid.SeatPart

			if seat then
				local mechModel = seat:FindFirstAncestorWhichIsA("Model")

				if mechModel and CollectionService:HasTag(mechModel, "Vehicle") then
					local partsScuffed = 0

					for _, part in ipairs(mechModel:GetDescendants()) do
						local maxHP = part:GetAttribute("MaxHealth")
						local curHP = part:GetAttribute("CurrentHealth")

						if maxHP and curHP and math.random() > 0.4 then
							local randomScuff = math.random(1, math.floor(maxHP * 0.9))
							part:SetAttribute("CurrentHealth", randomScuff)
							partsScuffed += 1
						end
					end
					print("💥 Damaged " .. partsScuffed .. " parts on " .. mechModel.Name)
				else
					warn("Admin Error: You must be sitting inside a tagged 'Vehicle'.")
				end
			else
				warn("Admin Error: You must be sitting in a VehicleSeat.")
			end

			-- 3. GENERATE MAP
		elseif cmd == "!genmap" then
			local mapSize = tonumber(args[2])
			if mapSize then
				mapSize = math.clamp(mapSize, 500, 5000)
				local adminGenEvent = ServerStorage:FindFirstChild("AdminGenMapEvent")
				if adminGenEvent then
					adminGenEvent:Fire(mapSize)
				else
					warn("System Error: AdminGenMapEvent not found in ServerStorage!")
				end
			else
				warn("Admin Error: Provide a valid size. Example: !genmap 2000")
			end

			-- 4. ADD / SUBTRACT POINTS
		elseif cmd == "!addpoints" or cmd == "!subpoints" or cmd == "!removepoints" then
			local isSubtract = (cmd == "!subpoints" or cmd == "!removepoints")
			local targetPlayer = player
			local amount = 0

			if #args == 2 then
				-- Usage: !addpoints 500 (Targets yourself)
				amount = tonumber(args[2]) or 0
			elseif #args >= 3 then
				-- Usage: !addpoints PlayerName 500 (Targets specified player)
				targetPlayer = findPlayer(args[2])
				amount = tonumber(args[3]) or 0
			end

			if isSubtract then
				amount = -math.abs(amount)
			end

			if targetPlayer and amount ~= 0 then
				local addPointsEvent = ServerStorage:FindFirstChild("AddPointsEvent")
				if addPointsEvent then
					addPointsEvent:Fire(targetPlayer, amount)
					print(string.format("🔧 ADMIN: Adjusted points for %s by %d", targetPlayer.Name, amount))
				else
					warn("Admin Error: AddPointsEvent not found in ServerStorage!")
				end
			else
				warn("Admin Usage: !addpoints [player] <amount> | !subpoints [player] <amount>")
			end
		end
	end)
end)