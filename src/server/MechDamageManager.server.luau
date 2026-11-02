-- Location: `ServerScriptService`
-- Function: The master judge for all destruction. It receives damage requests from weapons or collisions, calculates if the part actually breaks, and triggers all the physical and visual consequences.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local addPointsEvent = ServerStorage:WaitForChild("AddPointsEvent") 

local DAMAGE_POINTS_RATIO = 0.1 -- 1 point per 10 damage dealt (e.g., 50 damage = 5 points)
local LIMB_SEVER_POINTS = 35

local damageEvent = ReplicatedStorage:WaitForChild("MechDamageEvent")
local ApplyDamage
local ApplyEnvironmentDamage

local CombatGuard = require(game:GetService("ReplicatedStorage").ModuleScripts.MechModules.CombatGuard)

local VisualCluster = require(game:GetService("ReplicatedStorage").ModuleScripts.MechModules.VisualCluster)

local MeleeProfiles = require(game:GetService("ReplicatedStorage").ModuleScripts.MechModules.Weapons.MeleeProfiles)

local function FindBasePart(container, partName)
	for _, desc in ipairs(container:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Name == partName then
			return desc
		end
	end
	return nil
end

local IGNORE_DEBRIS_NAMES = {
	["MechHitbox"] = true,
	["TargetGround"] = true,
	["TargetLeft"] = true,
	["TargetRight"] = true,
	["HumanoidRootPart"] = true,
}

local function DetonateCore(mechModel, corePart)
	-- 1. Prevent double-explosions
	if mechModel:GetAttribute("IsDead") then return end
	mechModel:SetAttribute("IsDead", true)

	-- Kill Event Attribution
	local killEvent = game:GetService("ServerStorage"):FindFirstChild("MechKillEvent")
	local attackerUserId = mechModel:GetAttribute("LastAttacker")
	local ownerId = mechModel:GetAttribute("OwnerId")
	if killEvent and attackerUserId and attackerUserId ~= ownerId then
		killEvent:Fire(mechModel, attackerUserId)
	end

	-- Eliminate Pilot
	local seat = mechModel:FindFirstChildWhichIsA("VehicleSeat", true)
	local ownPilot = seat and seat.Occupant and seat.Occupant.Parent
	if ownPilot then
		local pilotHumanoid = ownPilot:FindFirstChild("Humanoid")
		if pilotHumanoid and pilotHumanoid.Health > 0 then
			pilotHumanoid.Sit = false
			ownPilot:SetAttribute("LastAttacker", nil)
			pilotHumanoid.Health = 0
		end
	end

	local centerPos = corePart.Position
	local blastRadius = 50

	-- 2. Visual Explosion (Supernova)
	local supernova = Instance.new("Part")
	supernova.Shape = Enum.PartType.Ball
	supernova.Material = Enum.Material.Neon
	supernova.CastShadow = false
	supernova.Color = Color3.new(1, 1, 1)
	supernova.Anchored = true
	supernova.CanCollide = false
	supernova.CanQuery = false
	supernova.Size = Vector3.new(2, 2, 2)
	supernova.CFrame = corePart.CFrame
	supernova.Parent = workspace
	
	local mechExplosionSound = ReplicatedStorage.Assets.Sounds:FindFirstChild("Mech_Explosion")
	if mechExplosionSound then
		local soundClone = mechExplosionSound:Clone()
		soundClone.Parent = supernova
		soundClone:Play()
	end

	local expandTween = TweenService:Create(supernova, TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(blastRadius * 2, blastRadius * 2, blastRadius * 2),
		Transparency = 1
	})
	expandTween:Play()
	game.Debris:AddItem(supernova, 5)

	-- 3. CHUNK DISASSEMBLY
	-- Sever ONLY motor joints and IK controllers (leaving WeldConstraints intact)
	for _, item in ipairs(mechModel:GetDescendants()) do
		if item:IsA("Motor6D") or item:IsA("IKControl") or item:IsA("Attachment") then
			item:Destroy()
		end
	end
	
	for _, item in ipairs(mechModel:GetDescendants()) do
		if item:IsA("BasePart") then
			-- Destroy utility parts or fully invisible collision blocks
			if IGNORE_DEBRIS_NAMES[item.Name] then
				item:Destroy()
			end
		end
	end

	-- Track root parts of each chunk so we don't apply impulse multiple times to the same chunk
	local processedChunks = {}

	for _, part in ipairs(mechModel:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "TargetGround" then
			part.Anchored = false
			part.CanCollide = true
			part.CanQuery = false

			-- Get the primary assembly root part for this welded chunk
			local chunkRoot = part.AssemblyRootPart
			if chunkRoot and not processedChunks[chunkRoot] then
				processedChunks[chunkRoot] = true

				-- Calculate throw direction from core
				local throwDir = (chunkRoot.Position - centerPos).Unit
				if throwDir.Magnitude == 0 or throwDir ~= throwDir then 
					throwDir = Vector3.new(0, 1, 0) 
				end

				-- Apply physics impulse to the chunk assembly
				chunkRoot:ApplyImpulse(throwDir * (chunkRoot.AssemblyMass * 120) + Vector3.new(0, chunkRoot.AssemblyMass * 40, 0))
				chunkRoot:ApplyAngularImpulse(Vector3.new(
					math.random(-15, 15), 
					math.random(-15, 15), 
					math.random(-15, 15)
					) * (chunkRoot.AssemblyMass * 10))
			end

			-- Optional scorched material for skeleton/core components
			if part:GetAttribute("ComponentType") == "Skeleton" or part:GetAttribute("ComponentType") == "Core" then
				part.Color = Color3.new(0.1, 0.1, 0.1)
				part.Material = Enum.Material.CorrodedMetal
			end
		end
	end

	-- 4. Final Cleanup
	game.Debris:AddItem(mechModel, 12)
end

ApplyEnvironmentDamage = function(part, damageAmount)
	local currentHealth = part:GetAttribute("CurrentHealth")
	local maxHealth = part:GetAttribute("MaxHealth")
	local hardness = part:GetAttribute("Hardness") or 0 -- Trees default to 0!
	if not currentHealth or currentHealth <= 0 then return end

	if damageAmount < hardness then	
		if hardness > 0 then
			local newHardness = math.max(0, hardness - (damageAmount))
			--print("Object took damage! Old Hardness:", hardness, " | New Hardness:", newHardness)
			part:SetAttribute("Hardness", newHardness)
		end
		return
	end
	
	local newHealth = currentHealth - damageAmount
	--print("Object took damage! Old HP:", currentHealth, " | New HP:", newHealth)

	local h, s, v = part.Color:ToHSV()
	if newHealth > 0 then
		part:SetAttribute("CurrentHealth", newHealth)
		local hpPercent = newHealth / maxHealth
		local isTrunk = string.find(string.lower(part.Name), "trunk")
		
		if not part:GetAttribute("BaseColor") then
			part:SetAttribute("BaseColor", part.Color)
		end

		if hpPercent <= 0.25 then
			-- CRITICAL DAMAGE (< 25%)
			part.Color = Color3.fromHSV(h, s, v * 0.4)
			
			if isTrunk then
				part.Material = Enum.Material.Slate -- Makes it look jagged and ruined!
			end

		elseif hpPercent <= 0.50 then
			-- HEAVY DAMAGE (< 50%)
			
			part.Color = Color3.fromHSV(h, s, v * 0.7)
			if isTrunk then
				part.Material = Enum.Material.Wood -- Expose the rough grain
			end
		end
		
		return
	end

	-- THE PART IS DESTROYED!
	part:SetAttribute("CurrentHealth", 0)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false

	for _, joint in pairs(part:GetJoints()) do
		if joint:IsA("WeldConstraint") then
			joint:Destroy()
		end
	end

	-- 2. Visuals (Turn the wood dark to look blasted)
	part.Color = Color3.fromHSV(h, s, v * 0.2)

	-- 3. The Push (Make the tree tip over naturally from the bullet impact)
	part:ApplyImpulse(Vector3.new(math.random(-5, 5), 5, math.random(-5, 5)) * (part.Mass * 5))
	part:ApplyAngularImpulse(Vector3.new(math.random(-5, 5), math.random(-5, 5), math.random(-5, 5)) * (part.Mass * 5))

	-- 4. Cleanup (Delete the fallen log after 10 seconds to reduce lag)
	game.Debris:AddItem(part, 3)
end

-- Grab your custom spark emitter!
local masterSpark = ReplicatedStorage:FindFirstChild("ImpactSpark", true)
local burstSpark = ReplicatedStorage:FindFirstChild("BurstSpark", true)

local function CascadeSever(targetPart, mechModel)
	print("⚡ [CASCADE] Running CascadeSever on:", targetPart.Name)
	targetPart:SetAttribute("CurrentHealth", 0)

	local downstreamParts = {}

	-- Check all joints in model
	for _, joint in pairs(mechModel:GetDescendants()) do
		if joint:IsA("Motor6D") then
			if joint.Part0 == targetPart then
				print("⚡ [CASCADE] Found downstream Motor6D:", joint.Name, "-> Part1:", joint.Part1 and joint.Part1.Name or "nil")
				if joint.Part1 then table.insert(downstreamParts, joint.Part1) end
			elseif joint.Part1 == targetPart then
				print("⚠️ [CASCADE] Found REVERSED Motor6D (Part1 is target):", joint.Name, "-> Part0:", joint.Part0 and joint.Part0.Name or "nil")
			end
		elseif joint:IsA("WeldConstraint") or joint:IsA("Weld") then
			if joint.Part0 == targetPart or joint.Part1 == targetPart then
				print("⚠️ [CASCADE] Found non-Motor6D joint attached to target:", joint.ClassName, joint.Name)
			end
		end
	end

	print(string.format("⚡ [CASCADE] %s found %d downstream parts.", targetPart.Name, #downstreamParts))

	for _, child in pairs(downstreamParts) do
		local childHP = child:GetAttribute("CurrentHealth") or 0
		print(string.format("⚡ [CASCADE] Checking child %s | Current HP: %d", child.Name, childHP))
		if childHP > 0 then
			CascadeSever(child, mechModel)
		end
	end
end


local function TraceEntireLimb(startPart, mechModel, stumpPart)
	local allDebris = {}
	local visited = {}
	
	-- Treat the stump as already visited so the crawler NEVER crosses the amputation seam into the body
	if stumpPart then
		visited[stumpPart] = true
	end

	-- Cache all joints first so we don't lag the server checking descendants
	local jointMap = {}
	for _, obj in pairs(mechModel:GetDescendants()) do
		if obj:IsA("Motor6D") or obj:IsA("WeldConstraint") or obj:IsA("Weld") or obj:IsA("ManualWeld") then
			if obj.Part0 and obj.Part1 then
				if not jointMap[obj.Part0] then jointMap[obj.Part0] = {} end
				if not jointMap[obj.Part1] then jointMap[obj.Part1] = {} end
				table.insert(jointMap[obj.Part0], obj.Part1)
				table.insert(jointMap[obj.Part1], obj.Part0)
			end
		end
	end

	local function Traverse(currentPart)
		if not currentPart or visited[currentPart] then return end
		visited[currentPart] = true

		if currentPart:IsDescendantOf(mechModel) then
			table.insert(allDebris, currentPart)
		end

		-- 1. Standard Physics Trace (Baseline)
		for _, connected in ipairs(currentPart:GetConnectedParts()) do
			if not visited[connected] and connected:IsDescendantOf(mechModel) then
				Traverse(connected)
			end
		end

		-- 2. Cached Logical Trace (Hunts down nested armor and downstream bones)
		if jointMap[currentPart] then
			for _, connectedPart in ipairs(jointMap[currentPart]) do
				if not visited[connectedPart] and connectedPart:IsDescendantOf(mechModel) then
					Traverse(connectedPart)
				end
			end
		end
	end

	Traverse(startPart)
	
	-- Forces the system to catch visual meshes (like Tires) that bypass rigid physics!
	local baseName = startPart.Name
	for _, obj in pairs(mechModel:GetDescendants()) do
		if obj:IsA("BasePart") and not visited[obj] then
			-- If the part shares the prefix (e.g. FrontLeftWheel_Tire contains FrontLeftWheel)
			if string.find(obj.Name, baseName) then
				table.insert(allDebris, obj)
				visited[obj] = true
			end
		end
	end
	
	return allDebris
end

local function UpdateVisualDamage(visualPart, hpPercent)
	-- Don't waste performance painting invisible hitboxes!
	if visualPart.Transparency >= 1 then return end 

	-- Save the factory paint and material the very first time!
	if not visualPart:GetAttribute("BaseColor") then
		visualPart:SetAttribute("BaseColor", visualPart.Color)
		visualPart:SetAttribute("BaseMaterial", visualPart.Material)
	end

	local baseColor = visualPart:GetAttribute("BaseColor")
	local baseMaterial = visualPart:GetAttribute("BaseMaterial")
	local h, s, v = baseColor:ToHSV()

	-- NEON LOGIC: Dim the glowing lights!
	if baseMaterial == Enum.Material.Neon then
		local dimmedBrightness = math.max(0, v * (0.5 + (hpPercent * 0.5)))
		visualPart.Color = Color3.fromHSV(h, s, dimmedBrightness)

		-- PLASTIC LOGIC: Scuff and melt the armor!
	else
		--local damageDarkness = math.max(0.3, v * (0.3 + (0.7 * hpPercent)))
		--visualPart.Color = Color3.fromHSV(h, s, damageDarkness)
		
		local targetMaterial = baseMaterial
		if hpPercent <= 0.25 then
			-- CRITICAL: Melted, scorched, and slagged plastic
			visualPart.Color = Color3.fromHSV(h, s, v * 0.6) 
			targetMaterial = Enum.Material.Concrete 
		elseif hpPercent <= 0.50 then
			-- HEAVY: Scuffed, pitted, and blast-marked
			
			visualPart.Color = Color3.fromHSV(h, s, v * 0.8) 
		end
			if not targetMaterial then return end
			-- If they get healed, restore the original material!
			if visualPart.Material ~= targetMaterial then
				visualPart.Material = targetMaterial
			end
		
	end
end

ApplyDamage = function(part, damageAmount, allowSpillover, explosionID, blastMemory, ignorePoints)
	local mechModel = part:FindFirstAncestorWhichIsA("Model")
	if not mechModel then return damageAmount end

	-- Tag mech for Welder Combat Cooldown
	mechModel:SetAttribute("LastDamagedTime", workspace:GetServerTimeNow())
	
	-- Preserves existing server-side kill/assist tracking
	mechModel:SetAttribute("LastDamageTime", os.clock())

	local resolvedPart = part

	-- NEW VARIATION: if set, this hit lands on the part itself AND the full damage
	-- is duplicated to this master part (RedirectAlsoTakesDamage toggle).
	local duplicateTarget = nil

	-- Climb the family tree until we find something that can actually take damage!
	while resolvedPart and resolvedPart ~= mechModel do
		-- A. Does it have a redirect address?
		local redirectName = resolvedPart:GetAttribute("DamageRedirect")
		if redirectName then
			local masterPart = FindBasePart(mechModel, redirectName)
			if masterPart then
				-- NEW VARIATION: a redirect part with its own health pool and the
				-- RedirectAlsoTakesDamage toggle ON takes the damage itself; the
				-- damage is duplicated to the master below. Toggle OFF (or no health)
				-- keeps the classic pass-through redirect behavior.
				if resolvedPart:GetAttribute("CurrentHealth") and resolvedPart:GetAttribute("RedirectAlsoTakesDamage") then
					duplicateTarget = masterPart
					break
				end
				resolvedPart = masterPart
				break
			end
		end
		-- B. Does it have health?
		if resolvedPart:GetAttribute("CurrentHealth") then
			break 
		end

		-- Move up to the parent and check again
		resolvedPart = resolvedPart.Parent
	end

	-- If we climbed all the way to the top and found absolutely no health/redirects, abort.
	if not resolvedPart or resolvedPart == mechModel then 
		-- warn("⚠️ BOUNCE: Hit a part with no health logic -> " .. part.Name)
		return damageAmount 
	end

	-- Assign the resolved part so the rest of the script targets the TRUE hitbox!
	part = resolvedPart
	
	-- THE DAMAGE TOKEN CHECK!
	if explosionID and blastMemory then
		if blastMemory[part] then 
			-- We already damaged this part (or the Torso it redirected to) with this explosion!
			return 0 
		end
		-- Mark this part as hit by this specific explosion
		blastMemory[part] = true
	end

	-- NEW VARIATION: duplicate the full damage to the redirect master. Forwarded
	-- after the token check so an already-hit part doesn't re-forward, and with the
	-- same blastMemory so the master gets its own per-explosion token (no repeat hits).
	if duplicateTarget and duplicateTarget ~= part then
		ApplyDamage(duplicateTarget, damageAmount, allowSpillover, explosionID, blastMemory, ignorePoints)
	end
	
	local currentHealth = part:GetAttribute("CurrentHealth")
	if not currentHealth then return damageAmount end

	if currentHealth <= 0 then 
		return damageAmount 
	end

	local componentType = part:GetAttribute("ComponentType")
	local newHealth = currentHealth - damageAmount
	print(string.format(" %s hit! Health: %d -> %d", part.Name, currentHealth, newHealth))
	-- Award combat points for health absorbed by this part
	local seat = mechModel:FindFirstChildWhichIsA("VehicleSeat", true)
	local isPiloted = seat and seat.Occupant ~= nil
	
	local absorbedDamage = math.min(currentHealth, damageAmount)
	local attackerUserId = mechModel:GetAttribute("LastAttacker")
	local ownerId = mechModel:GetAttribute("OwnerId")

	if not ignorePoints and isPiloted and attackerUserId and attackerUserId ~= ownerId and absorbedDamage > 0 and addPointsEvent then
		addPointsEvent:Fire(attackerUserId, absorbedDamage * DAMAGE_POINTS_RATIO)
	end
	if componentType == "Core" then
		local maxHealth = part:GetAttribute("MaxHealth") or 100

		-- If it's still alive, but dropping below 10% health...
		if newHealth > 0 and newHealth <= (maxHealth * 0.10) then
			if not mechModel:GetAttribute("IsMeltingDown") then
				mechModel:SetAttribute("IsMeltingDown", true)
				print("⚠️ SYSTEM: CORE INSTABILITY DETECTED. MELTDOWN IMMINENT.")

				part.Color = Color3.new(1, 0.5, 0) -- Turning orange!
				part.Material = Enum.Material.Neon

				local warningSmoke = Instance.new("Smoke")
				warningSmoke.Color = Color3.new(0.239216, 0.231373, 0.211765)
				warningSmoke.Size = 3
				warningSmoke.RiseVelocity = 5
				warningSmoke.Parent = part

				-- Start the death tick loop
				task.spawn(function()
					while part and part.Parent and part:GetAttribute("CurrentHealth") > 0 do
						task.wait(1)
						-- Drain 5 health every second directly
						ApplyDamage(part, 1, false, true, nil, nil, true) 
					end
				end)
			end
		end
	end
	
	if newHealth > 0 then
		part:SetAttribute("CurrentHealth", newHealth)
		
		local maxHealth = part:GetAttribute("MaxHealth") or 100
		local hpPercent = newHealth / maxHealth
		UpdateVisualDamage(part, hpPercent)
		
		-- 2. Grab the entire hybrid cluster (Welds + Redirects) and paint it!
		local cluster = VisualCluster.Get(part, mechModel)
		for _, visualPart in pairs(cluster) do
			-- Skip redirect parts that manage their own health pool (toggle ON):
			-- they get painted by their own damage events instead.
			if not (visualPart:GetAttribute("DamageRedirect") and visualPart:GetAttribute("CurrentHealth") and visualPart:GetAttribute("RedirectAlsoTakesDamage")) then
				UpdateVisualDamage(visualPart, hpPercent)
			end
		end
		
		return 0 
	end

	part:SetAttribute("CurrentHealth", 0)
	local spilloverDamage = math.abs(newHealth)

	if componentType == "Armor" then
		-- 1. Find what it was protecting before we break the weld
		local underlyingBone = nil
		for _, connectedPart in pairs(part:GetConnectedParts()) do
			local connectedType = connectedPart:GetAttribute("ComponentType")
			if connectedType == "Skeleton" or connectedType == "Core" then
				underlyingBone = connectedPart
				break
			end
		end

		-- 2. Break all joints (Safely deletes the WeldConstraint)
		part:BreakJoints()
		
		part.Parent = workspace
		CollectionService:AddTag(part, "EnvironmentIgnore")
		print("🗑️ DEBUG: Ejected ARMOR into workspace -> {" .. part.Name .. "}")
		
		part.Anchored = false
		part.CanCollide = false
		part.CanQuery = false

		-- 3. Wait one physics tick, then aggressively kick the armor off!
		task.spawn(function()
			task.wait() 
			-- Multiply by part.Mass so heavy plates fly just as well as small ones
			local kickForce = Vector3.new(math.random(-5, 5), math.random(5, 10), math.random(-5, 5)) * (part.Mass * 10)
			local spinForce = Vector3.new(math.random(-10, 10), math.random(-10, 10), math.random(-10, 10)) * (part.Mass * 5)
			part:ApplyImpulse(kickForce)
			part:ApplyAngularImpulse(spinForce)
		end)

		game.Debris:AddItem(part, 3)

		-- 4. Apply the Spillover!
		if allowSpillover and underlyingBone and spilloverDamage > 0 then
			print("⏬ SPILLOVER: " .. spilloverDamage .. " damage bleeding into " .. underlyingBone.Name)
			ApplyDamage(underlyingBone, spilloverDamage, allowSpillover, explosionID, blastMemory, ignorePoints)
		end

	elseif componentType == "Skeleton" or componentType == "Weapon" then
		local lowerName = string.lower(part.Name)
		
		local stumpPart = nil
		local stumpSurfacePos = nil
		local limbSurfacePos = nil
		if string.find(lowerName, "foot") then
			part.Color = Color3.new(0.1, 0.1, 0.1)
			part.Material = Enum.Material.CorrodedMetal
			local seat = mechModel:FindFirstChildWhichIsA("VehicleSeat", true)
			if seat then
				seat:SetAttribute("IsLimping", true)
			end
			print("⚠️ SYSTEM: " .. part.Name .. " disabled! Mech is limping.")

		elseif string.find(lowerName, "head") then
			local tempGlue = mechModel:FindFirstChild("TempHeadGlue", true)
			local neckMotor = mechModel:FindFirstChild("Neck", true) or mechModel:FindFirstChild("NeckMotor", true)

			if neckMotor then
				stumpPart = neckMotor.Part0
				if stumpPart then
					stumpSurfacePos = (stumpPart.CFrame * neckMotor.C0).Position
				end
			end
			limbSurfacePos = part.Position

			if tempGlue then
				tempGlue:Destroy()
			end

			if neckMotor then
				neckMotor:Destroy()
			end

		else
			-- Generic Limb Logic (Arms, Legs, Weapons)
			if mechModel then
				for _, obj in pairs(mechModel:GetDescendants()) do
					local foundStump = nil
					
					-- 1. Check for Motor6Ds and Welds
					if obj:IsA("Motor6D") or obj:IsA("WeldConstraint") or obj:IsA("Weld") then
						if obj.Part1 == part then 
							foundStump = obj.Part0
						--elseif obj.Part0 == part then -- caused to destroy early than cascade
							--obj:Destroy() -- Reversed motor: destroy but don't record as stump
						end

						-- 2. Check for physics constraints (like HingeConstraints for wheels)
					elseif obj:IsA("Constraint") and not obj:IsA("NoCollisionConstraint") then
						if obj.Attachment0 and obj.Attachment1 then
							if obj.Attachment1.Parent == part then 
								foundStump = obj.Attachment0.Parent
							end
							--elseif obj.Attachment0.Parent == part then foundStump = obj.Attachment1.Parent end
						end
					end

					-- 3. If we found what is holding the limb on, calculate the sparks and sever it!
					if foundStump then
						local redirectTarget = foundStump:GetAttribute("DamageRedirect")

						-- If the part redirects damage back to the dying limb, OR its name contains the limb's name (like "FrontLeftWheel_Tire"), it's fake!
						local isFakeStump = (redirectTarget == part.Name) or string.find(foundStump.Name, part.Name)

						if isFakeStump then
							-- It's a decorative joint, but it still connects TO the dying part. Destroy it!
							obj:Destroy()
							foundStump = nil
						else
							-- WE FOUND THE TRUE STRUCTURAL STUMP!
							-- Only record spark positions from the FIRST real joint found
							if not stumpPart then
								stumpPart = foundStump

								local stumpCenter = stumpPart.Position
								local limbCenter = part.Position
								local directionToStump = stumpCenter - limbCenter

								local rayParams = RaycastParams.new()
								rayParams.FilterType = Enum.RaycastFilterType.Include

								rayParams.FilterDescendantsInstances = {stumpPart}
								local stumpRay = workspace:Raycast(limbCenter, directionToStump, rayParams)
								stumpSurfacePos = stumpRay and stumpRay.Position or (obj:IsA("Motor6D") and (stumpPart.CFrame * obj.C0).Position or stumpCenter)

								rayParams.FilterDescendantsInstances = {part}
								local limbRay = workspace:Raycast(stumpCenter, -directionToStump, rayParams)
								limbSurfacePos = limbRay and limbRay.Position or (obj:IsA("Motor6D") and (part.CFrame * obj.C1).Position or limbCenter)
							end

							--print("🔍 SEVER TARGET:", obj.ClassName, "named:", obj.Name, "inside:", obj.Parent:GetFullName())
							obj:Destroy()
						end
					end
				end

				if stumpPart then
					for _, obj in pairs(mechModel:GetDescendants()) do
						if obj:IsA("Constraint") then
							local att0 = obj.Attachment0
							local att1 = obj.Attachment1

							if att0 and att1 then
								if (att0.Parent == part and att1.Parent == stumpPart) or 
									(att1.Parent == part and att0.Parent == stumpPart) then
									print("🔗 SYSTEM: Severed a " .. obj.ClassName .. " holding " .. part.Name .. "!")
									obj:Destroy()
								end
							end
						end
					end
				end
			
			end
		end
		if not string.find(lowerName, "foot") then
			-- 1. TRACE FIRST (While the welds are still intact!)
			local debrisTable = TraceEntireLimb(part, mechModel, stumpPart)

			-- 1.5 DamageRedirect associates (e.g. RightShoulderWeapon_2): separate parts that
			-- redirect damage to the main weapon but have their own Motor6D to the Torso.
			-- Sever their structural motors and add barrel children to the debris table.
			-- Do NOT call TraceEntireLimb — the _2 part is already in the debris table via
			-- the name-based prefix match, and re-tracing can spread through the entire mech.
			local debrisSet = {}
			for _, d in ipairs(debrisTable) do debrisSet[d] = true end

			for _, obj in pairs(mechModel:GetDescendants()) do
				if obj:IsA("BasePart") and obj:GetAttribute("DamageRedirect") == part.Name then
					-- Destroy structural Motor6D(s) connecting this associate to the mech body
					for _, joint in pairs(mechModel:GetDescendants()) do
						if joint:IsA("Motor6D") and joint.Part1 == obj then
							joint:Destroy()
						end
					end
					---- commented out only destroying the motor6d sparing the associate parts
					
					---- Zero its health so repair and UI systems know it's dead
					--obj:SetAttribute("CurrentHealth", 0)
					---- Ensure the associate is in the debris table
					--if not debrisSet[obj] then
					--	table.insert(debrisTable, obj)
					--	debrisSet[obj] = true
					--end
					---- Add barrel children (Motor6D where Part0 == associate) to the debris table
					--for _, joint in pairs(obj:GetDescendants()) do
					--	if joint:IsA("Motor6D") and joint.Part0 == obj and joint.Part1 then
					--		local barrel = joint.Part1
					--		if not debrisSet[barrel] then
					--			table.insert(debrisTable, barrel)
					--			debrisSet[barrel] = true
					--		end
					--	end
					--end
				end
			end

			-- 2. SEVER SECOND (Now that we have the list, we can shatter the arm)
			-- ⚠️ Ensure this is the ONLY CascadeSever in this entire block!
			CascadeSever(part, mechModel)
			
			-- 2.5 INSTANT IK DESTRUCTION (BEFORE EVICTION)
			-- Fixes the NaN Physics Crash that rips the Foot and Calf apart!
			if string.find(lowerName, "calf") or string.find(lowerName, "thigh") or string.find(lowerName, "leg") then
				local isLeft = string.find(lowerName, "left")
				local isRight = string.find(lowerName, "right")
				for _, ik in pairs(mechModel:GetDescendants()) do
					if ik:IsA("IKControl") and ik.EndEffector then
						local effName = string.lower(ik.EndEffector.Name)
						if (isLeft and string.find(effName, "left")) or (isRight and string.find(effName, "right")) then
							ik.Enabled = false
							--print("?? IK AMPUTATED: Destroyed " .. effName .. " before eviction!")
						end
					end
				end
			end

			-- 3. MASS EVICTION THIRD (Kick every single piece into the workspace)
			local ejectedNames = {}
			for _, debrisPart in ipairs(debrisTable) do
				if debrisPart:IsA("BasePart") then
					debrisPart.Parent = workspace
					CollectionService:AddTag(debrisPart, "EnvironmentIgnore")
					game.Debris:AddItem(debrisPart, 10) 

					-- Add the name to our debug table!
					table.insert(ejectedNames, debrisPart.Name)
				end
			end

			print("=========================================")
			print("🗑️ DEBUG: Ejected " .. #ejectedNames .. " parts from " .. part.Name .. ":")
			print(ejectedNames) -- Studio will print this as a dropdown table!
			print("=========================================")
			
			part.Anchored = false
			task.delay(0.1, function()
				if part and part.Parent then 
					part.CanCollide = true 
				end
			end)
			-- B. Explosive Impulse
			task.spawn(function()
				task.wait()
				part:ApplyImpulse(Vector3.new(math.random(-10, 10), math.random(10, 20), math.random(-10, 10)) * (part.Mass * 5))
				part:ApplyAngularImpulse(Vector3.new(math.random(-10, 10), math.random(-10, 10), math.random(-10, 10)) * (part.Mass * 5))
			end)

			-- C. Burst Sparks & Socket Sparks
			if burstSpark then
				local limbAttachment = Instance.new("Attachment")
				limbAttachment.Name = "SeveredLimbSpark"
				limbAttachment.Parent = part
				if limbSurfacePos and stumpSurfacePos then
					limbAttachment.WorldCFrame = CFrame.lookAt(limbSurfacePos, stumpSurfacePos)
				end

				local fallingSpark = burstSpark:Clone()
				fallingSpark.EmissionDirection = Enum.NormalId.Front
				fallingSpark.Parent = part
				fallingSpark:Emit(25)

				if stumpPart and stumpSurfacePos then
					local socketAttachment = Instance.new("Attachment")
					socketAttachment.Name = "SeveredSocket"
					socketAttachment.Parent = stumpPart
					socketAttachment.WorldCFrame = CFrame.lookAt(stumpSurfacePos, limbSurfacePos or part.Position)

					local stumpSpark = burstSpark:Clone()
					stumpSpark.Rate = 0
					stumpSpark.EmissionDirection = Enum.NormalId.Front 
					stumpSpark.Parent = socketAttachment

					task.spawn(function()
						local endTime = os.clock() + 15 
						while os.clock() < endTime and stumpSpark.Parent do
							stumpSpark:Emit(math.random(4, 8))
							task.wait(math.random(10, 30) / 10)
						end
					end)

					game.Debris:AddItem(socketAttachment, 15)
					
				end
			end
		end



		if string.find(lowerName, "calf") or string.find(lowerName, "thigh") or string.find(lowerName, "leg") then

			local seat = mechModel:FindFirstChildWhichIsA("VehicleSeat", true)
			if seat then
				-- 1. Identify WHICH leg took the hit
				local isLeft = string.find(lowerName, "left")
				local isRight = string.find(lowerName, "right")

				local alreadyLeftDead = seat:GetAttribute("LeftLegDead")
				local alreadyRightDead = seat:GetAttribute("RightLegDead")

				local newlyDestroyed = false

				-- 2. Prevent Double-Counting! (Only trigger if the leg was healthy a second ago)
				if isLeft and not alreadyLeftDead then
					seat:SetAttribute("LeftLegDead", true)
					newlyDestroyed = true
				end

				if isRight and not alreadyRightDead then
					seat:SetAttribute("RightLegDead", true)
					newlyDestroyed = true
				end
				
				if newlyDestroyed then
					local legsLeft = seat:GetAttribute("LegsRemaining") or 2
					legsLeft = math.max(0, legsLeft - 1)
					seat:SetAttribute("LegsRemaining", legsLeft)

					local pristineMech = game:GetService("ServerStorage"):FindFirstChild("Vehicles") and game:GetService("ServerStorage").Vehicles:FindFirstChild(mechModel.Name)
					local pristineSeat = pristineMech and pristineMech:FindFirstChildWhichIsA("VehicleSeat", true)
					local baseLoco = pristineSeat and pristineSeat:GetAttribute("LocomotionType") or "Bipedal"
					local targetCrawlerMode = (baseLoco == "ChickenLegBipedal") and "ChickenLegCrawler" or "Crawler"

					-- Officially change the vehicle's DNA to a Crawler!
					seat:SetAttribute("LocomotionType", targetCrawlerMode)

					if legsLeft <= 0 then
						seat:SetAttribute("WalkSpeed", 0)
						print("🛑 SYSTEM: Both legs destroyed. Mobility offline. Turret Mode engaged.")
					else
						local crawlerSpeed = seat:GetAttribute("CrawlSpeed") or 6
						seat:SetAttribute("WalkSpeed", crawlerSpeed)
					end
					
					-- If nobody is driving, the Server must physically tip it over!
					if seat.Occupant == nil then
						local driveCore = mechModel:FindFirstChild("TargetGround", true)
						if driveCore then
							local fallSpeed = seat:GetAttribute("FallSpeed") or 3
							-- Convert the speed into a time duration (e.g., speed 3 = ~1 second fall)
							local fallDuration = 3.0 / fallSpeed

							-- We extract a perfectly flat forward direction...
							local flatForward = Vector3.new(driveCore.CFrame.LookVector.X, 0, driveCore.CFrame.LookVector.Z)
							if flatForward.Magnitude < 0.01 then 
								flatForward = Vector3.new(0, 0, -1) 
							else 
								flatForward = flatForward.Unit 
							end

							-- ...and force the pitch to EXACTLY -75 degrees in world space.
							local flatCFrame = CFrame.lookAt(driveCore.Position, driveCore.Position + flatForward)
							local newCFrame = flatCFrame * CFrame.Angles(math.rad(-75), 0, 0)

							-- Create a temporary virtual value to hold the CFrame during the fall
							local cframeValue = Instance.new("CFrameValue")
							cframeValue.Value = driveCore.CFrame

							-- Every single frame the Tween updates this value, pipe it to the Network Attribute!
							cframeValue.Changed:Connect(function(latestCFrame)
								driveCore.CFrame = latestCFrame
								mechModel:SetAttribute("DriveCFrame", latestCFrame)
							end)


							local fallTween = TweenService:Create(
								cframeValue, 
								TweenInfo.new(fallDuration, Enum.EasingStyle.Sine, Enum.EasingDirection.In), 
								{Value = newCFrame}
							)

							fallTween:Play()

							-- Clean up our virtual value once the mech hits the dirt so it doesn't leak memory
							fallTween.Completed:Connect(function()
								cframeValue:Destroy()
							end)
						end
					end
				end
			end

			-- RELEASE THE PARKING BRAKE! (Allows empty mechs to fall)
			local hip = mechModel:FindFirstChild("Hip", true)
			if hip then
				hip.Anchored = false
			end

			for _, part in pairs(mechModel:GetDescendants()) do
				if part:IsA("BasePart") then
					local pNameLower = string.lower(part.Name)
					if string.find(pNameLower, "leg") or string.find(pNameLower, "calf") or string.find(pNameLower, "thigh") or string.find(pNameLower, "foot") then
						part.CanCollide = false
					end
				end
			end

			game:GetService("ReplicatedStorage").MechStateUpdate:FireAllClients(mechModel, "Collapse", part.Name)
		elseif string.find(lowerName, "wheel") then
			-- [WHEELED MECH LOGIC]
			local seat = mechModel:FindFirstChildWhichIsA("VehicleSeat", true)
			if seat then
				-- 1. Track this specific wheel so we don't double-count it if the script fires twice!
				local deadAttributeName = part.Name .. "_Dead"

				if not seat:GetAttribute(deadAttributeName) then
					seat:SetAttribute(deadAttributeName, true)

					-- 2. Initialize or get the remaining wheels (Defaults to 4)
					local wheelsLeft = seat:GetAttribute("WheelsRemaining")
					if wheelsLeft == nil then wheelsLeft = seat:GetAttribute("WheelAmount") or 4 end

					-- Subtract 1 wheel
					wheelsLeft = math.max(0, wheelsLeft - 1)
					seat:SetAttribute("WheelsRemaining", wheelsLeft)

					-- 3. Apply the Speed Penalties
					if wheelsLeft <= 0 then
						-- ALL WHEELS GONE: Kill the engine!
						seat:SetAttribute("WalkSpeed", 0)
						print("🛑 SYSTEM: All wheels destroyed. Engine killed.")
					else
						-- SOME WHEELS LEFT: Reduce speed proportionally
						local baseSpeed = seat:GetAttribute("BaseWalkSpeed") 
						-- If we haven't locked in a BaseSpeed yet, fetch it directly from the Vault blueprint!
						if not baseSpeed then 
							local pristineMech = game:GetService("ServerStorage").Vehicles:FindFirstChild(mechModel.Name)
							local pristineSeat = pristineMech and pristineMech:FindFirstChildWhichIsA("VehicleSeat", true)

							-- Fallback to 15 only if the blueprint is missing entirely
							baseSpeed = pristineSeat and pristineSeat:GetAttribute("WalkSpeed") or 15 

							-- Save it to the seat so we never have to look it up again
							seat:SetAttribute("BaseWalkSpeed", baseSpeed) 
						end

						local maxWheels = seat:GetAttribute("WheelAmount") or 4
						local newSpeed = baseSpeed * (wheelsLeft / maxWheels)
						print(string.format("🏎️ WHEEL MATH: Base(%s) * [Left(%s) / Max(%s)] = NewSpeed(%s)", tostring(baseSpeed), tostring(wheelsLeft), tostring(maxWheels), tostring(newSpeed)))
						seat:SetAttribute("WalkSpeed", newSpeed)

						print("💾 VERIFY SAVED SPEED: " .. tostring(seat:GetAttribute("WalkSpeed")))
					end
				end
			end

			-- Tell the client to drop the wheel
			game:GetService("ReplicatedStorage").MechStateUpdate:FireAllClients(mechModel, "Severed", part.Name)

		else
			-- Standard arm/hand severing
			game:GetService("ReplicatedStorage").MechStateUpdate:FireAllClients(mechModel, "Severed", part.Name)
		end
		
		if not string.find(lowerName, "foot") then
			game:GetService("ReplicatedStorage").MechStateUpdate:FireAllClients(mechModel, "Severed", part.Name)
			print("🦴 SEVERED: " .. part.Name .. " has detached from the mech!")
			-- Award milestone bonus for severing a limb, weapon, or wheel
			local attackerUserId = mechModel:GetAttribute("LastAttacker")
			local ownerId = mechModel:GetAttribute("OwnerId")

			if isPiloted and attackerUserId and attackerUserId ~= ownerId and addPointsEvent then
				addPointsEvent:Fire(attackerUserId, LIMB_SEVER_POINTS)
			end
		end
		
	elseif componentType == "Core" then
		print("☢️ CORE CRITICAL: " .. part.Name)
			part.Color = Color3.new(1, 0, 0)
			part.Material = Enum.Material.Neon
			DetonateCore(mechModel, part)
	end

	return spilloverDamage
end

local activeExplosions = {} -- The Memory Bank

damageEvent.OnServerEvent:Connect(function(player, hitPart, requestedDamage, allowSpillover, explosionID, damageSource)

	if type(requestedDamage) ~= "number" then 
		warn("❌ SERVER ABORTED: requestedDamage is not a number! It is a " .. type(requestedDamage))
		return 
	end
	if not hitPart or not hitPart.Parent or not hitPart:IsA("BasePart") then return end
	
	
	local actualDamage = 0
	local playerMech = nil

	-- Find the mech this player is driving
	local hitModel = hitPart:FindFirstAncestorWhichIsA("Model")
	local isHumanoid = hitModel and hitModel:FindFirstChild("Humanoid") and not CollectionService:HasTag(hitModel, "Vehicle")
	local hitPlayer = isHumanoid and game:GetService("Players"):GetPlayerFromCharacter(hitModel)
	
	local isMech = hitModel and CollectionService:HasTag(hitModel, "Vehicle") and not isHumanoid
	local mechTeam = hitModel:GetAttribute("Team")

	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if seat then
		playerMech = seat:FindFirstAncestorWhichIsA("Model")
	end

	if damageSource == "Trample" then
		if not playerMech or not seat then return end
		
		-- SECURITY: Trample is only ever valid against Destructible environment.
		-- Reject anything else (mech parts, players) sent through the Trample channel.
		local isTrampleTargetDestructible = false
		local trampleNode = hitPart
		while trampleNode and trampleNode ~= workspace do
			if CollectionService:HasTag(trampleNode, "Destructible") then
				isTrampleTargetDestructible = true
				break
			end
			trampleNode = trampleNode.Parent
		end
		if not isTrampleTargetDestructible then return end

		-- HIGH PING FIX: The pilot's client detects the trample overlap locally, but by
		-- the time this request reaches the server, the server's view of the mech lags
		-- behind the client by the replication delay. Use the freshest position we have
		-- (the client-replicated DriveCFrame attribute OR the physical seat) and add a
		-- lag buffer for how far the mech can travel during the pilot's round-trip ping.
		local mechPositions = {seat.Position}
		local driveCFrame = playerMech:GetAttribute("DriveCFrame")
		if driveCFrame then table.insert(mechPositions, driveCFrame.Position) end

		local distance = math.huge
		for _, pos in ipairs(mechPositions) do
			local d = (pos - hitPart.Position).Magnitude
			if d < distance then distance = d end
		end

		local walkSpeed = seat:GetAttribute("WalkSpeed") or 16
		local pingSeconds = math.clamp(player:GetNetworkPing(), 0, 1)
		local lagBuffer = walkSpeed * pingSeconds * 2
		local maxTrampleReach = 30 + lagBuffer
		
		if distance > maxTrampleReach then
			print(string.format("Attempted to trample out of range (%.1f > %.1f studs) by %s", distance, maxTrampleReach, player.Name))
			return
		end
		
		actualDamage = seat:GetAttribute("TrampleDamage") or 75
	elseif playerMech and damageSource then
		-- Client claims they shot a weapon (e.g., "RightWeapon"). Verify they actually have it!
		local weaponPart = playerMech:FindFirstChild(tostring(damageSource), true)
		
		if not weaponPart and (tostring(damageSource) == "Fist" or string.find(tostring(damageSource), "Hand")) then
			local prefix = string.find(tostring(damageSource), "Left") and "Left" or "Right"
			weaponPart = playerMech:FindFirstChild(prefix .. "Hand", true)
		end
		
		if weaponPart then
			local baseDamage = weaponPart:GetAttribute("Damage") or 0
			local pilotMult = weaponPart:GetAttribute("PilotDamageMultiplier") or 1
			local maxRange = weaponPart:GetAttribute("MaxRange") or 500
			
			local isMeleeSlot = false
			local meleeProfileName = weaponPart:GetAttribute("MeleeProfile")

			-- Check VehicleSeat attributes (e.g., RightWeaponType == "MeleeWeapon" or "Punch")
			if seat then
				local slotTypeAttr = seat:GetAttribute(weaponPart.Name .. "Type")
				if slotTypeAttr == "MeleeWeapon" or slotTypeAttr == "Punch" then
					isMeleeSlot = true
				end
			end
			
			if meleeProfileName or isMeleeSlot or tostring(damageSource) == "Fist" or string.find(string.lower(weaponPart.Name), "hand") then
				local profile = MeleeProfiles and (MeleeProfiles[meleeProfileName] or MeleeProfiles.Fist)
				local profileDamage = profile and profile.Damage or 50
				local handDamage = weaponPart:GetAttribute("Damage") or 0

				-- Allow whichever is highest so custom hand attributes aren't clamped
				baseDamage = math.max(baseDamage, profileDamage, handDamage)
				maxRange = 35 -- Safe close-quarters anti-cheat leash
			end

			-- 1. DYNAMIC DISTANCE CHECK
			if character and character.PrimaryPart then
				local distance = (character.PrimaryPart.Position - hitPart.Position).Magnitude
				-- Base 50 stud buffer plus a ping-scaled allowance: at high ping the
				-- shooter's view of the target lags several studs behind the server,
				-- and the target keeps moving during the shot's round trip.
				-- (40 studs/s approximates a sprinting mech.)
				local ping = math.clamp(player:GetNetworkPing(), 0, 1)
				local lagBuffer = 50 + (40 * ping * 2)
				if distance > (maxRange + lagBuffer) then 
					warn("🚨 ANTI-CHEAT: " .. player.Name .. " hit a part out of range! (" .. math.floor(distance) .. " > " .. maxRange .. ")")
					return 
				end
			end

			-- 2. THE ABSOLUTE CEILING
			-- If hitting a mech, max damage is BaseDamage. If hitting a squishy pilot, it gets the multiplier!
			local absoluteCeiling = baseDamage
			if isHumanoid then
				absoluteCeiling = baseDamage * pilotMult
			end

			-- 3. THE VERIFICATION
			if requestedDamage <= (absoluteCeiling + 1) then -- +1 buffer for floating point decimals
				actualDamage = requestedDamage
			else
				warn("🚨 ANTI-CHEAT: " .. player.Name .. " spoofed damage (" .. requestedDamage .. "). Clamping to " .. absoluteCeiling)
				actualDamage = absoluteCeiling
			end
		else
			warn("⚠️ ANTI-CHEAT: Player tried to fire a weapon slot they don't have: " .. tostring(damageSource))
		end
	end

	-- If no valid damage was found, abort!
	if actualDamage <= 0 then return end
	-- Check friendly fire, lobby, and abandonment rules
	local attacker = playerMech or player
	if not CombatGuard.CanAffect(attacker, hitPart) then
		return
	end

	-- Stamp the attacker on the target model so KillCount can credit the kill on death
	if hitModel and hitModel ~= workspace then
		hitModel:SetAttribute("LastAttacker", player.UserId)
		hitModel:SetAttribute("LastDamageTime", os.clock())
		
		-- If the vehicle is actively piloted, tag the driver character too
		local seat = hitModel:FindFirstChildWhichIsA("VehicleSeat", true)
		local pilot = seat and seat.Occupant and seat.Occupant.Parent
		if pilot then
			pilot:SetAttribute("LastAttacker", player.UserId)
			pilot:SetAttribute("LastDamageTime", os.clock())
		end
	end

	-- 1. Route to Humanoids
	if isHumanoid then
		local targetHum = hitModel:FindFirstChildOfClass("Humanoid")
		local targetSeat = targetHum and targetHum.SeatPart
		local targetMech = targetSeat and targetSeat:FindFirstAncestorWhichIsA("Model")
		
		-- If the pilot is seated in an enemy mech, verify there is an exposed opening
		if targetSeat and targetMech and targetMech ~= playerMech then
			local originPos = (character and character.PrimaryPart and character.PrimaryPart.Position) or (playerMech and playerMech.PrimaryPart and playerMech.PrimaryPart.Position)
			if originPos then
				local losParams = RaycastParams.new()
				losParams.FilterType = Enum.RaycastFilterType.Exclude
				-- Exclude the shooter, their mech, and the target pilot character, but NOT the target mech
				local excludeList = {hitModel}
				if character then table.insert(excludeList, character) end
				if playerMech then table.insert(excludeList, playerMech) end
				losParams.FilterDescendantsInstances = excludeList

				local checkDir = hitPart.Position - originPos
				local losHit = workspace:Raycast(originPos, checkDir, losParams)

				-- If a solid mech part is still blocking the shot, reject damage to the seated pilot!
				if losHit and losHit.Instance:IsDescendantOf(targetMech) then
					warn(string.format("🛡️ COCKPIT BLOCKED: %s tried to hit seated pilot %s, but %s is shielding them!", player.Name, hitModel.Name, losHit.Instance.Name))
					return
				end
			end
		end

		if targetHum then
			targetHum:TakeDamage(actualDamage)
		end
		
		hitModel.Humanoid:TakeDamage(actualDamage)
		return
	end

	-- 2. Route to Destructible Environment
	local isDestructible = false
	local currentNode = hitPart
	while currentNode and currentNode ~= workspace do
		if CollectionService:HasTag(currentNode, "Destructible") then
			isDestructible = true
			break
		end
		currentNode = currentNode.Parent
	end

	if isDestructible then
		ApplyEnvironmentDamage(hitPart, actualDamage)
		return
	end

	-- Route to Mechs (Implemented explosion memory to prevent double-hitting armor plates)
	local blastMemory = nil
	if explosionID then
		if not activeExplosions[explosionID] then
			activeExplosions[explosionID] = {}
			task.delay(1, function() activeExplosions[explosionID] = nil end) 
		end
		blastMemory = activeExplosions[explosionID]
	end
	
	
	-- 3. Route to Mechs
	ApplyDamage(hitPart, actualDamage, allowSpillover, explosionID, blastMemory)
	
end)

local serverDamageBindable = Instance.new("BindableEvent")
serverDamageBindable.Name = "ServerDamageRequest"
serverDamageBindable.Parent = game:GetService("ServerStorage") -- Locked safely away from clients!

serverDamageBindable.Event:Connect(function(hitPart, rawDamage, allowSpillover, explosionID)
	if not hitPart or not hitPart.Parent then return end
	local hitModel = hitPart:FindFirstAncestorWhichIsA("Model")

	-- 1. HUMANOID CHECK (Are we shooting a player/dummy?)
	if hitModel and hitModel:FindFirstChild("Humanoid") and not CollectionService:HasTag(hitModel, "Vehicle") then
		hitModel.Humanoid:TakeDamage(rawDamage)
		return -- Stop here! Don't run mech math on humans!
	end

	-- 2. ENVIRONMENT CHECK (Are we shooting a tree/wall?)
	local isDestructible = false
	local currentNode = hitPart
	while currentNode and currentNode ~= workspace do
		if CollectionService:HasTag(currentNode, "Destructible") then
			isDestructible = true
			break
		end
		currentNode = currentNode.Parent
	end

	if isDestructible then
		-- Assuming ApplyEnvironmentDamage is a function defined higher up in your script!
		if ApplyEnvironmentDamage then ApplyEnvironmentDamage(hitPart, rawDamage) end
		return -- Stop here!
	end

	-- 3. MECH CHECK (We hit armor!)
	local blastMemory = nil
	if explosionID then
		if not activeExplosions[explosionID] then
			activeExplosions[explosionID] = {}
			task.delay(1, function() activeExplosions[explosionID] = nil end) 
		end
		blastMemory = activeExplosions[explosionID]
	end

	-- Route it straight into your master damage math!
	ApplyDamage(hitPart, rawDamage, allowSpillover, explosionID, blastMemory)
end)