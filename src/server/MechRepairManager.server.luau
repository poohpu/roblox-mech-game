-- Location: ServerScriptService 
-- Function: Handles the repair system, parts restoring, parts healing, receive event calls from Welder_LocalScript.
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local rojoShared = ReplicatedStorage:WaitForChild("Shared")

local repairEvent = ReplicatedStorage:WaitForChild("MechRepairEvent")
local stateUpdateEvent = ReplicatedStorage:WaitForChild("MechStateUpdate")
local visualEvent = ReplicatedStorage:WaitForChild("WelderVisualEvent")
local MechVault = ServerStorage:WaitForChild("Vehicles")
local VisualCluster = require(rojoShared.ModuleScripts.MechModules.VisualCluster)


local function GetPathID(obj, root)
	local path = obj.Name
	local current = obj.Parent
	while current and current ~= root do
		path = current.Name .. "/" .. path
		current = current.Parent
	end
	return path
end

local function wireRestoredWheelClearance(mechModel, newPart)
	-- We only need to do this if the part we just restored is a Wheel
	if not string.find(newPart.Name, "Wheel") then return end

	-- Force it to the Default collision group so it can interact with the world
	newPart.CollisionGroup = "Default"

	-- Sweep through the live mech and create a constraint with every chassis part
	for _, existingPart in ipairs(mechModel:GetDescendants()) do
		if existingPart:IsA("BasePart") and existingPart ~= newPart then

			-- If it's a structural part and NOT another wheel
			if not string.find(existingPart.Name, "Wheel") then
				local noCollide = Instance.new("NoCollisionConstraint")
				noCollide.Part0 = newPart
				noCollide.Part1 = existingPart
				noCollide.Name = "RestoredWheelClearance"
				noCollide.Parent = newPart
			end

		end
	end
end

local PristineCache = {}

for _, prefab in ipairs(MechVault:GetChildren()) do
	PristineCache[prefab.Name] = { Joints = {}, JointMap = {} }

	local idCounter = 1
	local totalBaseParts = 0 -- Keep track of how many parts make up this mech
	
	for _, obj in ipairs(prefab:GetDescendants()) do
		local ignoreNames = {ProxyLeft = true, ProxyRight = true, TargetLeft = true, TargetRight = true, TempHeadGlue = true}
		
		if obj:IsA("BasePart") and not ignoreNames[obj.Name] then
			obj:SetAttribute("RepairID", idCounter)
			
			obj:SetAttribute("OriginalCanCollide", obj.CanCollide)
			
			idCounter += 1
			totalBaseParts += 1
		elseif obj:IsA("JointInstance") or obj:IsA("WeldConstraint") then
			-- Cache all joints ONCE when the server boots to prevent lag spikes!
			table.insert(PristineCache[prefab.Name].Joints, obj)
			
			-- Map exactly what Part0 and Part1 are connected to!
			local p0 = obj.Part0
			local p1 = obj.Part1

			if p0 and p1 then
				if not PristineCache[prefab.Name].JointMap[p0] then PristineCache[prefab.Name].JointMap[p0] = {} end
				if not PristineCache[prefab.Name].JointMap[p1] then PristineCache[prefab.Name].JointMap[p1] = {} end

				-- Tell p0 it is connected to p1, and tell p1 it is connected to p0
				table.insert(PristineCache[prefab.Name].JointMap[p0], p1)
				table.insert(PristineCache[prefab.Name].JointMap[p1], p0)
			end
		elseif obj:IsA("Constraint") and not obj:IsA("WeldConstraint") and not obj:IsA("NoCollisionConstraint") then
			-- NEW: Map constraints by looking at the parents of their Attachments!
			local att0 = obj.Attachment0
			local att1 = obj.Attachment1

			if att0 and att1 then
				local p0 = att0.Parent
				local p1 = att1.Parent

				if p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart") then
					if not PristineCache[prefab.Name].JointMap[p0] then PristineCache[prefab.Name].JointMap[p0] = {} end
					if not PristineCache[prefab.Name].JointMap[p1] then PristineCache[prefab.Name].JointMap[p1] = {} end

					-- Tell the parts they are neighbors so the Repair tool permits them to spawn!
					table.insert(PristineCache[prefab.Name].JointMap[p0], p1)
					table.insert(PristineCache[prefab.Name].JointMap[p1], p0)
				end
			end
		end
	end
	
	prefab:SetAttribute("TotalBaseParts", totalBaseParts)
end

local function SyncPrePlacedMech(liveMech)
	local ServerStorage = game:GetService("ServerStorage")
	if liveMech:IsDescendantOf(ServerStorage) then return end
	
	if liveMech:GetAttribute("IDsSynced") then return end
	liveMech:SetAttribute("IDsSynced", true)

	-- Pull true total part count from Pristine Vault prefab if available
	local pristineMech = MechVault:FindFirstChild(liveMech.Name)
	if pristineMech and pristineMech:GetAttribute("TotalBaseParts") then
		liveMech:SetAttribute("TotalBaseParts", pristineMech:GetAttribute("TotalBaseParts"))
	end

	local nameCounts = {}
	local validLiveParts = 0
	
	for _, obj in ipairs(liveMech:GetDescendants()) do
		if obj:IsA("BasePart") then
			if not obj:GetAttribute("RepairID") then
				local basePath = GetPathID(obj, liveMech)
				nameCounts[basePath] = (nameCounts[basePath] or 0) + 1
				local uniqueID = basePath .. "_" .. nameCounts[basePath]

				obj:SetAttribute("RepairID", uniqueID)
			end
			
			if obj:GetAttribute("OriginalCanCollide") == nil then
				obj:SetAttribute("OriginalCanCollide", obj.CanCollide)
			end

			validLiveParts += 1
		end
	end
	
	-- Fallback only if no matching prefab was found in MechVault
	if not liveMech:GetAttribute("TotalBaseParts") then
		liveMech:SetAttribute("TotalBaseParts", validLiveParts)
	end
end

for _, mech in ipairs(CollectionService:GetTagged("Vehicle")) do SyncPrePlacedMech(mech) end
CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(SyncPrePlacedMech)

local function applyTeamHue(originalColor, teamColor)
	local _, _, origLightness = originalColor:ToHSV() 
	local teamH, teamS, _ = teamColor:ToHSV() 
	return Color3.fromHSV(teamH, teamS, origLightness)
end



local function WashVisualCluster(liveMasterPart, liveMech, pristineMech)
	local cluster = VisualCluster.Get(liveMasterPart, liveMech)
	
	table.insert(cluster, liveMasterPart)
	
	local seat = liveMech:FindFirstChildWhichIsA("VehicleSeat", true)
	if not seat then return end
	for _, liveArmorPart in ipairs(cluster) do
		local id = liveArmorPart:GetAttribute("RepairID")
		if id then
			-- Find the exact matching clean plate in the vault
			for _, pristinePart in ipairs(pristineMech:GetDescendants()) do
				if pristinePart:GetAttribute("RepairID") == id then
					liveArmorPart.Color = pristinePart.Color
					liveArmorPart.Material = pristinePart.Material

					-- Re-apply team paint if necessary!
					local teamColor = liveMech:GetAttribute("CurrentTeamColor")
					local accentColor = liveMech:GetAttribute("CurrentAccentColor")
					if teamColor and liveArmorPart:GetAttribute("Colorable") then
						liveArmorPart.Color = applyTeamHue(liveArmorPart.Color, teamColor)
						liveArmorPart:SetAttribute("BaseColor", liveArmorPart.Color)
					elseif teamColor and liveArmorPart:GetAttribute("AccentColorable") then
						liveArmorPart.Color = accentColor
						liveArmorPart:SetAttribute("BaseColor", accentColor)
					else
						liveArmorPart:SetAttribute("BaseColor", liveArmorPart.Color)
					end
					break
				end
			end
		end
	end
end

-- ==========================================
-- HELPER: UNIVERSAL RESTORER (Phantom Killer)
-- ==========================================
local function UniversalRestore(liveMech, pristineMech, missingPristinePart, livePartsCache)
	local restoredPart = missingPristinePart:Clone()

	for _, child in ipairs(restoredPart:GetChildren()) do
		if child:IsA("JointInstance") or child:IsA("WeldConstraint") then
			child.Part0 = nil
			child.Part1 = nil
			child:Destroy()
		end
	end

	local maxHP = restoredPart:GetAttribute("MaxHealth")
	if maxHP then restoredPart:SetAttribute("CurrentHealth", maxHP) end
	
	local teamColor = liveMech:GetAttribute("CurrentTeamColor")
	local accentColor = liveMech:GetAttribute("CurrentAccentColor")

	if teamColor and restoredPart:GetAttribute("Colorable") then
		restoredPart.Color = applyTeamHue(restoredPart.Color, teamColor)
		restoredPart:SetAttribute("BaseColor", restoredPart.Color)

	elseif accentColor and restoredPart:GetAttribute("AccentColorable") then
		restoredPart.Color = accentColor
		restoredPart:SetAttribute("BaseColor", accentColor)
	else
		restoredPart:SetAttribute("BaseColor", restoredPart.Color)
	end

	local pNameLower = string.lower(restoredPart.Name)
	local isLegBone = string.find(pNameLower, "leg") or string.find(pNameLower, "calf") or string.find(pNameLower, "thigh") or string.find(pNameLower, "foot")

	if isLegBone then
		-- RULE 1: IK Legs MUST be false forever, even if true in Studio!
		restoredPart.CanCollide = false
	else
		-- RULE 2: Everything else copies the blueprint's original setting!
		restoredPart.CanCollide = missingPristinePart.CanCollide
	end

	local wasAnchored = restoredPart.Anchored
	restoredPart.Anchored = true
	
	local torso = liveMech:FindFirstChild("Torso", true) or liveMech.PrimaryPart
	if torso then
		restoredPart.CFrame = torso.CFrame
	end

	local targetParentName = missingPristinePart.Parent.Name
	restoredPart.Parent = (targetParentName == pristineMech.Name) and liveMech or liveMech:FindFirstChild(targetParentName, true) or liveMech
	
	-- Instantly add to our live cache using its unique ID
	local myID = restoredPart:GetAttribute("RepairID")
	if myID then livePartsCache[myID] = restoredPart end

	local attachedSomething = false
	for _, pristineJoint in ipairs(PristineCache[pristineMech.Name].Joints) do
		local p0 = pristineJoint.Part0
		local p1 = pristineJoint.Part1

		if p0 == missingPristinePart or p1 == missingPristinePart then
			local liveP0 = livePartsCache[p0 and p0:GetAttribute("RepairID")]
			local liveP1 = livePartsCache[p1 and p1:GetAttribute("RepairID")]

			if liveP0 and liveP1 then
				--print("🔧 WELDER DEBUG: Linking " .. liveP0.Name .. " to " .. liveP1.Name .. " via " .. pristineJoint.Name)
				-- If the stump is currently sparking, delete the spark attachment instantly!
				local oldSocket = liveP0:FindFirstChild("SeveredSocket")
				if oldSocket then oldSocket:Destroy() end

				local oldSocket2 = liveP1:FindFirstChild("SeveredSocket")
				if oldSocket2 then oldSocket2:Destroy() end
				
				for _, child in ipairs(liveP0:GetChildren()) do
					if (child:IsA("JointInstance") or child:IsA("WeldConstraint")) and child.Name == pristineJoint.Name then
						local childP0Alive = child.Part0 and livePartsCache[child.Part0:GetAttribute("RepairID")]
						local childP1Alive = child.Part1 and livePartsCache[child.Part1:GetAttribute("RepairID")]

						-- If the old joint is holding onto thin air or severed debris, destroy it!
						if not (childP0Alive and childP1Alive) then
							child:Destroy()
						end
					end
				end

				if pristineJoint:IsA("WeldConstraint") or pristineJoint:IsA("Weld") or pristineJoint:IsA("Motor6D") then
					local isP0Clone = (p0 == missingPristinePart)
					local pristineOffset = p0.CFrame:ToObjectSpace(p1.CFrame)
					if isP0Clone then
						liveP0.CFrame = liveP1.CFrame * pristineOffset:Inverse()
					else
						liveP1.CFrame = liveP0.CFrame * pristineOffset
					end
				end

				local newJoint = Instance.new(pristineJoint.ClassName)
				newJoint.Name = pristineJoint.Name
				newJoint.Part0 = liveP0
				newJoint.Part1 = liveP1
				if pristineJoint:IsA("JointInstance") then
					newJoint.C0 = pristineJoint.C0
					newJoint.C1 = pristineJoint.C1
				end
				newJoint.Parent = liveP0
				attachedSomething = true
				
				-- THE STATE INTERCEPT: Swap the Neck for TempGlue if parked!
				-- no camerayaw check, only do this for head hatch set up
			
				
				if pristineJoint.Name == "Neck" or pristineJoint.Name == "NeckMotor" then
					local seat = liveMech:FindFirstChildWhichIsA("VehicleSeat", true)
					if seat and seat.Occupant == nil then
						-- 1. Unplug the newly built neck!
						newJoint.Part1 = nil 

						-- 2. Build the Glue
						local liveHatch = liveMech:FindFirstChild("HatchPivot", true)
						local pristineHatch = pristineMech:FindFirstChild("HatchPivot", true)
						local cloneHead = (p0 == missingPristinePart) and liveP0 or liveP1

						if liveHatch and pristineHatch and cloneHead and pristineHatch:GetAttribute("IsHeadHatch") == true then
							local pristineHead = pristineMech:FindFirstChild("Head", true)
							local offset = pristineHatch.CFrame:ToObjectSpace(pristineHead.CFrame)
							cloneHead.CFrame = liveHatch.CFrame * offset

							local tempGlue = Instance.new("WeldConstraint")
							tempGlue.Name = "TempHeadGlue"
							tempGlue.Part0 = cloneHead
							tempGlue.Part1 = liveHatch
							tempGlue.Parent = liveHatch
							
						--	print("🚨 REPAIR DIAGNOSTIC: MechRepairManager is about to build TempHeadGlue on ->", liveMech.Name)
							--print("   - Joint name that triggered this:", pristineJoint.Name)
						--	print("   - Does this mech even have a HatchPivot?", liveHatch ~= nil)
						else
							-- repair the neck normally 
							newJoint.Part1 = (p0 == missingPristinePart) and liveP0 or liveP1
						end
					end
				end
			end
		end
	end
	restoredPart.Anchored = wasAnchored
	
	-- Apply the invisible clearance so the new wheel doesn't grind against the chassis!
	wireRestoredWheelClearance(liveMech, restoredPart)

	return attachedSomething, restoredPart
end

-- ==========================================
-- THE MASTER REPAIR LOOP
-- ==========================================
-- repair ticks usually take 8-11 ms, which is slightly heavy, may come back and rewrite the loop.
repairEvent.OnServerEvent:Connect(function(player, liveMech)
	if not liveMech or not liveMech.Parent then return end

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local torso = liveMech:FindFirstChild("Torso", true) or liveMech.PrimaryPart
	if not root or not torso or (root.Position - torso.Position).Magnitude > 35 then return end

	if (torso:GetAttribute("CurrentHealth") or 0) <= 0 then return end

	local seat = liveMech:FindFirstChildWhichIsA("VehicleSeat", true)
	if not seat then return end

	-- Rule 1: Occupant Check
	if seat.Occupant ~= nil then
		warn("Anti-Cheat: " .. player.Name .. " tried to repair an occupied mech.")
		return
	end

	-- Rule 2: Team & Ownership Check
	local ownerId = liveMech:GetAttribute("OwnerId")
	if player.Team ~= nil then
		local ownerPlayer = game:GetService("Players"):GetPlayerByUserId(ownerId)
		if ownerPlayer and ownerPlayer.Team ~= player.Team then
			warn("Anti-Cheat: " .. player.Name .. " tried to repair an enemy mech.")
			return
		end
	else
		if ownerId ~= player.UserId then
			warn("Anti-Cheat: " .. player.Name .. " tried to repair an unowned mech.")
			return
		end
	end

	-- Rule 2.5: Combat Tag Check (Cannot repair recently damaged mechs)
	local COMBAT_COOLDOWN = 4.0 -- Seconds after taking damage before repair is permitted
	local lastDamagedTime = liveMech:GetAttribute("LastDamagedTime") or 0
	local currentTime = workspace:GetServerTimeNow()

	if (currentTime - lastDamagedTime) < COMBAT_COOLDOWN then
		return -- Silently drop packet if client tried to repair during combat cooldown
	end

	-- Rule 3: No Stacking Repairs (The Server Timestamp)
	local activeRepairPlayer = liveMech:GetAttribute("RepairingPlayer")
	local lastRepairTime = liveMech:GetAttribute("LastRepairedTime") or 0
	local currentTime = workspace:GetServerTimeNow()

	if activeRepairPlayer and activeRepairPlayer ~= player.UserId then
		if (currentTime - lastRepairTime) < 0.5 then
			-- We don't warn here because a tiny bit of network lag could accidentally trigger this.
			-- We just silently drop the request.
			return
		end
	end

	-- If they passed all checks, lock this mech to them for the next 0.5 seconds!
	liveMech:SetAttribute("RepairingPlayer", player.UserId)
	liveMech:SetAttribute("LastRepairedTime", currentTime)
	
	-- Rule 4: Rate Limiting (Enforce Mech RepairMultiplier)
	local multiplier = seat:GetAttribute("RepairMultiplier") or 1
	local expectedInterval = 0.125 / math.max(0.1, multiplier)
	local lastPlayerTick = player:GetAttribute("LastRepairTick") or 0

	-- Allow a 20% latency buffer so ping spikes don't drop legitimate repair pulses
	if (currentTime - lastPlayerTick) < (expectedInterval * 0.8) then
		return
	end
	player:SetAttribute("LastRepairTick", currentTime)

	local pristineMech = MechVault:FindFirstChild(liveMech.Name)
	if not pristineMech then return end
	
	SyncPrePlacedMech(liveMech)
	
	local livePartsCache = {}
	for _, obj in ipairs(liveMech:GetDescendants()) do
		if obj:IsA("BasePart") and not CollectionService:HasTag(obj, "EnvironmentIgnore") then
			-- Only cache parts that are actually alive!
			local currentHP = obj:GetAttribute("CurrentHealth")
			local isAlive = false
			if currentHP == nil then
				isAlive = true -- Accept armor/weapons that don't use health
			elseif type(currentHP) == "number" and currentHP > 0 then
				isAlive = true -- Accept bones only if they have actual health
			end

			if isAlive then
				local id = obj:GetAttribute("RepairID")
				if id then 
					livePartsCache[id] = obj 
				end
			end
		end
	end
	
	local missingTasks = {}
	local healingTasks = {}

	-- PASS 1: HEAL EXISTING PARTS
	for _, livePart in pairs(livePartsCache) do
		local maxHP = livePart:GetAttribute("MaxHealth")
		if maxHP then
			local curHP = livePart:GetAttribute("CurrentHealth")
			if not curHP then
				curHP = maxHP
				livePart:SetAttribute("CurrentHealth", maxHP)
			end

			if curHP > maxHP then
				livePart:SetAttribute("CurrentHealth", maxHP)
			elseif curHP < maxHP then
				table.insert(healingTasks, {Part = livePart, CurHP = curHP, MaxHP = maxHP})
			end
		end
	end

	-- Force the dictionary to forget any parts that were ejected to the workspace!
	-- ==========================================
	for id, cachedPart in pairs(livePartsCache) do
		if not cachedPart:IsDescendantOf(liveMech) then
			--print(cachedPart, livePartsCache[id])
			livePartsCache[id] = nil -- Erase the ghost reference!
		end
	end

	-- PASS 2: FIND MISSING PARTS (The Skeleton Blindspot Fix!)
	for _, pristinePart in ipairs(pristineMech:GetDescendants()) do
		-- We now check ALL BaseParts, even if they don't have MaxHealth!
		if pristinePart:IsA("BasePart") then
			local id = pristinePart:GetAttribute("RepairID")

			if not livePartsCache[id] then
				-- PART IS MISSING: Check structural anchor via IDs
				local canAttach = false
				
				-- Look up its neighbors instantly!
				local neighbors = PristineCache[pristineMech.Name].JointMap[pristinePart]
				if neighbors then
					for _, connectedPristinePart in ipairs(neighbors) do
						-- If any of the parts it connects to are currently alive on the live mech, we can attach to it!
						local neighborID = connectedPristinePart:GetAttribute("RepairID")
						if neighborID and livePartsCache[neighborID] then
							canAttach = true 
							break
						end
					end
				end

				if canAttach then table.insert(missingTasks, pristinePart) 
				else
					-- THE PROBE: Print what is being rejected and why
					if string.find(string.lower(pristinePart.Name), "wheel") then
						print("REPAIR REJECTED: " .. pristinePart.Name .. " is missing, but the JointMap says it has 0 alive neighbors to attach to!")
					end
				end
			end
		end
	end

	-- ==========================================
	-- EXECUTE REPAIR
	-- ==========================================
	if #missingTasks > 0 then
		local pristinePartToRestore = missingTasks[math.random(1, #missingTasks)]
		local success, restoredLimb = UniversalRestore(liveMech, pristineMech, pristinePartToRestore, livePartsCache)

		if success and restoredLimb then
			-- Check the blueprint vault to find all armor meant for this bone, and build it instantly!
			local pristineCluster = VisualCluster.Get(pristinePartToRestore, pristineMech)

			for _, pristineArmor in ipairs(pristineCluster) do
				-- Skip the core bone we just built!
				if pristineArmor ~= pristinePartToRestore then
					local armorID = pristineArmor:GetAttribute("RepairID")

					-- If the live mech is missing this specific piece of armor, clone it!
					if not livePartsCache[armorID] then
						UniversalRestore(liveMech, pristineMech, pristineArmor, livePartsCache)
					end
				end
			end
			
			WashVisualCluster(restoredLimb, liveMech, pristineMech)
			stateUpdateEvent:FireAllClients(liveMech, "Restored", restoredLimb.Name)

			-- Notify MechServerAsync to refresh its shoulder motor caches
			local refreshEvent = ServerStorage:FindFirstChild("ShoulderMotorRefreshEvent")
			if refreshEvent then
				refreshEvent:Fire(liveMech)
			end

			-- We flag the mech so the client knows it was missing parts!
			liveMech:SetAttribute("HasMissingParts", true)
		end

	elseif #healingTasks > 0 then
		local healAmount = 5
		
		while healAmount > 0 and #healingTasks > 0 do
			local randomIndex = math.random(1, #healingTasks)
			local healTask = healingTasks[randomIndex]

			local hpNeeded = healTask.MaxHP - healTask.CurHP
			local hpToApply = math.min(healAmount, hpNeeded)

			local newHP = healTask.CurHP + hpToApply
			healTask.Part:SetAttribute("CurrentHealth", newHP)
			healTask.CurHP = newHP -- Update the table in case it survives the tick

			healAmount -= hpToApply

			if newHP >= healTask.MaxHP then
				WashVisualCluster(healTask.Part, liveMech, pristineMech)

				if string.find(string.lower(healTask.Part.Name), "foot") then
					local seat = liveMech:FindFirstChildWhichIsA("VehicleSeat", true)
					local leftFoot = liveMech:FindFirstChild("LeftFoot", true)
					local rightFoot = liveMech:FindFirstChild("RightFoot", true)
					if seat then
						local rightFootDead = not rightFoot or rightFoot:GetAttribute("CurrentHealth") <= 0
						local leftFootDead = not leftFoot or leftFoot:GetAttribute("CurrentHealth") <= 0
						local stillLimping = (rightFootDead or leftFootDead)

						seat:SetAttribute("IsLimping", stillLimping)
					end
				end
				
				-- Part is fully healed, remove it so the loop targets other damaged parts
				table.remove(healingTasks, randomIndex)
			end

			game:GetService("ReplicatedStorage").MechHealFlashEvent:FireAllClients(healTask.Part)
		end
	
	else
		-- If BOTH lists are totally empty, tell the client it is flawless!
		liveMech:SetAttribute("HasMissingParts", nil)
	end
	
	-- Check what locomotion system this blueprint uses
	local pristineSeat = pristineMech:FindFirstChildWhichIsA("VehicleSeat", true)
	local defaultLoco = pristineSeat and pristineSeat:GetAttribute("LocomotionType") or "Bipedal"
	local defaultSpeed = pristineSeat and pristineSeat:GetAttribute("WalkSpeed") or 15

	local legHealth = { Left = true, Right = true } 

	local function GetStrictComponent(model, name)
		for _, obj in ipairs(model:GetDescendants()) do
			-- Only accept physical bones or attachments!
			if obj.Name == name and (obj:IsA("BasePart") or obj:IsA("Attachment")) then
				return obj
			end
		end
		return nil
	end

	if defaultLoco == "Wheeled" then
		-- ==========================================
		-- PASS 3 (WHEELED): WHEEL RECOVERY LOGIC
		-- ==========================================
		local seat = liveMech:FindFirstChildWhichIsA("VehicleSeat", true)
		if seat then
			local maxWheels = seat:GetAttribute("WheelAmount") or 4
			local aliveWheels = 0

			-- Check all 4 wheel hubs in the blueprint
			for _, pristinePart in ipairs(pristineMech:GetDescendants()) do
				if pristinePart:IsA("BasePart") and string.find(string.lower(pristinePart.Name), "wheel") then
					local id = pristinePart:GetAttribute("RepairID")
					if id and livePartsCache[id] then
						seat:SetAttribute(pristinePart.Name .. "_Dead", nil)
						
						if string.find(pristinePart.Name, "Wheel_Part") then
							aliveWheels += 1
						end
					end
				end
			end

			-- Update the seat's live wheel count
			seat:SetAttribute("WheelsRemaining", aliveWheels)

			-- Scale speed based on surviving wheels (or 0 if all are gone)
			local speedFraction = (maxWheels > 0) and (aliveWheels / maxWheels) or 0
			local calculatedSpeed = math.round(defaultSpeed * speedFraction)
			seat:SetAttribute("WalkSpeed", calculatedSpeed)
			seat:SetAttribute("LocomotionType", "Wheeled")
			
			for _, pristineConstraint in ipairs(pristineMech:GetDescendants()) do
				if pristineConstraint:IsA("HingeConstraint") or (pristineConstraint:IsA("Constraint") and not pristineConstraint:IsA("WeldConstraint") and not pristineConstraint:IsA("NoCollisionConstraint")) then
					local targetParent = (pristineConstraint.Parent == pristineMech) and liveMech or liveMech:FindFirstChild(pristineConstraint.Parent.Name, true)

					if targetParent then
						local liveConstraint = targetParent:FindFirstChild(pristineConstraint.Name)
						if not liveConstraint then
							liveConstraint = pristineConstraint:Clone()
							liveConstraint.Parent = targetParent
						end

						-- Helper: Looks for the attachment inside its EXACT parent part to avoid name collisions
						local function resolveAttachment(pristineAtt)
							if not pristineAtt or not pristineAtt.Parent then return nil end
							local livePart = liveMech:FindFirstChild(pristineAtt.Parent.Name, true)
							return livePart and livePart:FindFirstChild(pristineAtt.Name)
						end

						liveConstraint.Attachment0 = resolveAttachment(pristineConstraint.Attachment0)
						liveConstraint.Attachment1 = resolveAttachment(pristineConstraint.Attachment1)

						if liveConstraint:IsA("HingeConstraint") and pristineConstraint:IsA("HingeConstraint") then
							liveConstraint.ActuatorType = pristineConstraint.ActuatorType
							liveConstraint.MotorMaxTorque = pristineConstraint.MotorMaxTorque
						end
					end
				end
			end
		end
	else
		-- ==========================================
		-- PASS 3: BIPEDAL RECOVERY LOGIC
		-- ==========================================
		legHealth.Left = true
		legHealth.Right = true

		for _, pristinePart in ipairs(pristineMech:GetDescendants()) do
			local pNameLower = string.lower(pristinePart.Name) -- Force lowercase to prevent capitalization traps!

			-- Added "leg" to the search just in case you use UpperLeg/LowerLeg!
			if string.find(pNameLower, "thigh") or string.find(pNameLower, "calf") or string.find(pNameLower, "foot") or string.find(pNameLower, "leg") then

				-- Ignore missing armor, only care about the core bones!
				if pristinePart:GetAttribute("ComponentType") == "Skeleton" then
					local id = pristinePart:GetAttribute("RepairID")

					-- If this specific bone is missing, ONLY fail its specific leg!
					if id and not livePartsCache[id] then

						print("Waiting on missing skeleton bone -> " .. pristinePart.Name)

						if string.find(pNameLower, "left") then legHealth.Left = false end
						if string.find(pNameLower, "right") then legHealth.Right = false end
					end
				end
			end
		end

		local seat = liveMech:FindFirstChildWhichIsA("VehicleSeat", true)
		if seat then
			local maxLegs = seat:GetAttribute("LegAmount") or 2
			local activeLegs = 0

			if legHealth.Left then 
				activeLegs = activeLegs + 1 
				seat:SetAttribute("LeftLegDead", false) -- Wipes the memory clean!
			else
				seat:SetAttribute("LeftLegDead", true)
			end

			if legHealth.Right then 
				activeLegs = activeLegs + 1 
				seat:SetAttribute("RightLegDead", false) -- Wipes the memory clean!
			else
				seat:SetAttribute("RightLegDead", true)
			end

			seat:SetAttribute("LegsRemaining", activeLegs)

			-- Do NOT turn on the IK or Bipedal logic until we have enough legs to stand up!
			local readyToStand = (activeLegs >= maxLegs)

			-- 1. Look at the pristine vault blueprint to remember how this mech normally moves
			local pristineSeat = pristineMech:FindFirstChildWhichIsA("VehicleSeat", true)
			local defaultLoco = pristineSeat and pristineSeat:GetAttribute("LocomotionType") or "Bipedal"
			local defaultSpeed = pristineSeat and pristineSeat:GetAttribute("WalkSpeed") or 15

			local currentLoco = seat:GetAttribute("LocomotionType")
			local wasCrawling = (currentLoco == "Crawler" or currentLoco == "ChickenLegCrawler")
			local targetCrawlerMode = (defaultLoco == "ChickenLegBipedal") and "ChickenLegCrawler" or "Crawler"

			-- ==========================================
			-- 2. SMART LOCOMOTION ROUTING
			-- ==========================================
			if readyToStand then
				-- Don't flip yet if we were Crawler — EnterMech's stand-up tween handles that
				-- Only reset to Bipedal if the legs are FULLY restored!
				if not wasCrawling and seat:GetAttribute("LocomotionType") ~= defaultLoco then
					seat:SetAttribute("LocomotionType", defaultLoco)
					seat:SetAttribute("WalkSpeed", defaultSpeed)
				end
			else
				-- We are still missing leg bones. Force Crawler Mode!
				if activeLegs > 0 then
					local crawlerSpeed = seat:GetAttribute("CrawlSpeed") or 6
					seat:SetAttribute("WalkSpeed", crawlerSpeed)

					-- Force Crawler state just in case it got confused!
					if seat:GetAttribute("LocomotionType") ~= targetCrawlerMode then
						seat:SetAttribute("LocomotionType", targetCrawlerMode)
					end
				else
					seat:SetAttribute("WalkSpeed", 0) -- 0 Legs = Turret Mode
				end
			end

			-- ==========================================
			-- 1. INDEPENDENT IK RESURRECTION 
			-- ==========================================
			for _, pristineIK in ipairs(pristineMech:GetDescendants()) do
				if pristineIK:IsA("IKControl") then

					local nameLower = string.lower(pristineIK.Name)
					local parentNameLower = pristineIK.Parent and string.lower(pristineIK.Parent.Name) or ""

					local isLeft = string.find(nameLower, "left") or string.find(parentNameLower, "left")
					local isRight = string.find(nameLower, "right") or string.find(parentNameLower, "right")

					-- The moment a SINGLE leg is healthy, build its IK!
					if (isLeft and legHealth.Left) or (isRight and legHealth.Right) then
						local liveIK = liveMech:FindFirstChild(pristineIK.Name, true)

						if not liveIK then
							--print("Cloning IKControl -> " .. pristineIK.Name)
							liveIK = pristineIK:Clone()

							local targetParentName = pristineIK.Parent.Name
							local foundParent = (targetParentName == pristineMech.Name) and liveMech or liveMech:FindFirstChild(targetParentName, true)
							if foundParent then liveIK.Parent = foundParent end
						end

						if liveIK then
							-- Check for Server Proxies first so server IK tracks network foot replication
							local proxyName = isLeft and "ServerProxyLeft" or (isRight and "ServerProxyRight" or nil)
							local proxyTarget = proxyName and GetStrictComponent(liveMech, proxyName)

							if proxyTarget then
								liveIK.Target = proxyTarget
							elseif pristineIK.Target then 
								liveIK.Target = GetStrictComponent(liveMech, pristineIK.Target.Name) 
							end

							if pristineIK.EndEffector then liveIK.EndEffector = GetStrictComponent(liveMech, pristineIK.EndEffector.Name) end
							if pristineIK.ChainRoot then liveIK.ChainRoot = GetStrictComponent(liveMech, pristineIK.ChainRoot.Name) end
							if pristineIK.Pole then liveIK.Pole = GetStrictComponent(liveMech, pristineIK.Pole.Name) end

							-- The IK mathematically exists, but we force it to sleep so it doesn't anchor to the floor while crawling!
							liveIK.Enabled = true
						end
					end
				end
			end
			
			-- ==========================================
			-- 3. THE STAND-UP SEQUENCE
			-- ==========================================
			if readyToStand and wasCrawling then
				--print("🚀 SYSTEM: Chassis fully repaired. Initiating Bipedal Boot Sequence.")

				liveMech:SetAttribute("AwaitingStandUp", true)
			end
	end
		-- ==========================================
		-- 2. INDEPENDENT CONSTRAINT RESURRECTION
		-- ==========================================
		for _, pristineConstraint in ipairs(pristineMech:GetDescendants()) do
			if pristineConstraint:IsA("Constraint") and not pristineConstraint:IsA("WeldConstraint") and not pristineConstraint:IsA("NoCollisionConstraint") then

				local nameLower = string.lower(pristineConstraint.Name)
				local parentNameLower = pristineConstraint.Parent and string.lower(pristineConstraint.Parent.Name) or ""

				local isLeft = string.find(nameLower, "left") or string.find(parentNameLower, "left")
				local isRight = string.find(nameLower, "right") or string.find(parentNameLower, "right")

				local isCore = not (isLeft or isRight)

				-- The moment a SINGLE leg is healthy, rebuild its physical limits!
				if isCore or (isLeft and legHealth.Left) or (isRight and legHealth.Right) then
					local targetParentName = pristineConstraint.Parent.Name
					local targetParent = (targetParentName == pristineMech.Name) and liveMech or liveMech:FindFirstChild(targetParentName, true)

					if targetParent then
						local liveConstraint = targetParent:FindFirstChild(pristineConstraint.Name)

						-- If the constraint was destroyed, clone a new one
						if not liveConstraint then
							liveConstraint = pristineConstraint:Clone()
							liveConstraint.Parent = targetParent
						end

						-- ALWAYS re-wire the attachments! (Even if the constraint survived, 
						-- its old attachments might have been blown up with the wheel).
						if liveConstraint then
							pcall(function()
								if pristineConstraint.Attachment0 then 
									liveConstraint.Attachment0 = GetStrictComponent(liveMech, pristineConstraint.Attachment0.Name) 
								end

								if pristineConstraint.Attachment1 then 
									liveConstraint.Attachment1 = GetStrictComponent(liveMech, pristineConstraint.Attachment1.Name) 
								end

								if liveConstraint:IsA("HingeConstraint") and pristineConstraint:IsA("HingeConstraint") then
									liveConstraint.ActuatorType = pristineConstraint.ActuatorType
									liveConstraint.MotorMaxTorque = pristineConstraint.MotorMaxTorque
								end
							end)

						end
					end
				end
			end
		end

		
	end
	
end)

visualEvent.OnServerEvent:Connect(function(player, hitPosition, isHealing)
	-- Loop through all players in the game
	for _, otherPlayer in ipairs(game.Players:GetPlayers()) do
		-- Send the visual data to everyone EXCEPT the person holding the welder!
		if otherPlayer ~= player then
			visualEvent:FireClient(otherPlayer, player, hitPosition, isHealing)
		end
	end
end)
