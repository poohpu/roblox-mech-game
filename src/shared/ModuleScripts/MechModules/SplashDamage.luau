local SplashDamage = {}
local CollectionService = game:GetService("CollectionService")

function SplashDamage.Apply(params)
	local origin = params.Origin
	local radius = params.Radius
	local rawSplashDamage = params.BaseDamage
	local sourceMech = params.SourceMech
	local fireFunc = params.SecureFireFn
	local explosionID = params.ExplosionID
	local pilotMultiplier = params.PilotMultiplier or 1
	local directHitPart = params.DirectHitPart
	local hitNormal = params.HitNormal or Vector3.new(0, 1, 0)
	local blastDirection = params.BlastDirection or Vector3.new(0, -1, 0)

	-- ==========================================
	-- 1. GATHER & LINE OF SIGHT
	-- ==========================================
	local overlapParams = OverlapParams.new()
	overlapParams.CollisionGroup = "Players"
	local partsInBlast = workspace:GetPartBoundsInRadius(origin, radius, overlapParams)

	local hitData = {}
	local hitVictims = {}
	if directHitPart then hitVictims[directHitPart] = true end

	-- NEW VARIATION: redirect parts with their own health + the RedirectAlsoTakesDamage
	-- toggle ON keep the damage themselves while the server duplicates it to their master.
	-- Pre-scan for those pairs so masters already receiving duplicated damage are skipped
	-- and each redirect pair is damaged exactly once per explosion.
	local pairedMasters = {}
	for _, scannedPart in pairs(partsInBlast) do
		if scannedPart:IsA("BasePart")
			and scannedPart:GetAttribute("DamageRedirect")
			and scannedPart:GetAttribute("CurrentHealth")
			and scannedPart:GetAttribute("RedirectAlsoTakesDamage") then
			local scannedModel = scannedPart:FindFirstAncestorWhichIsA("Model")
			if scannedModel then
				local masterPart = scannedModel:FindFirstChild(scannedPart:GetAttribute("DamageRedirect"), true)
				if masterPart then pairedMasters[masterPart] = true end
			end
		end
	end

	for _, blastedPart in pairs(partsInBlast) do
		if blastedPart == directHitPart then continue end 
		if pairedMasters[blastedPart] then continue end

		local blastModel = blastedPart:FindFirstAncestorWhichIsA("Model")
		if blastModel == workspace then blastModel = nil end

		local isDestructibleSplash = false
		local currentNode = blastedPart
		while currentNode and currentNode ~= workspace do
			if CollectionService:HasTag(currentNode, "Destructible") then
				isDestructibleSplash = true
				break
			end
			currentNode = currentNode.Parent
		end

		local toExplosion = origin - blastedPart.Position
		local distanceToExplosion = toExplosion.Magnitude
		local rayDir = Vector3.zero
		if distanceToExplosion > 0.001 then
			rayDir = toExplosion.Unit * (distanceToExplosion + 2)
		end

		local rayParams = RaycastParams.new()
		local thingsToIgnore = {sourceMech}

		if blastModel and not CollectionService:HasTag(blastModel, "Vehicle") then 
			table.insert(thingsToIgnore, blastModel) 
		end
		if isDestructibleSplash and blastModel and not table.find(thingsToIgnore, blastModel) then 
			table.insert(thingsToIgnore, blastModel) 
		end

		rayParams.FilterDescendantsInstances = thingsToIgnore
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.CollisionGroup = "Players"

		local hitResult = nil
		if distanceToExplosion > 0.001 then
			hitResult = workspace:Raycast(blastedPart.Position, rayDir, rayParams)
		end

		local isHittingTarget = false
		if not hitResult then
			isHittingTarget = true
		else
			if hitResult.Distance >= (distanceToExplosion - 0.1) then
				isHittingTarget = true
			end
		end

		if not isHittingTarget then continue end

		local actualTarget = blastedPart
		local redirectName = blastedPart:GetAttribute("DamageRedirect")
		if redirectName and blastModel then
			local masterPart = blastModel:FindFirstChild(redirectName, true)
			if masterPart then
				-- NEW VARIATION: toggle ON keeps the part itself as the target;
				-- the server duplicates the damage to the master.
				if not (blastedPart:GetAttribute("CurrentHealth") and blastedPart:GetAttribute("RedirectAlsoTakesDamage")) then
					actualTarget = masterPart
				end
			end
		end

		table.insert(hitData, {
			Target = actualTarget,
			Distance = distanceToExplosion,
			Model = blastModel,
			IsProp = isDestructibleSplash 
		})
	end

	-- ==========================================
	-- 2. SORT & DECAY SPREAD
	-- ==========================================
	table.sort(hitData, function(a, b) return a.Distance < b.Distance end)

	local dynamicLimits = {}
	local modelHitCounts = {}
	local SPREAD_PERCENTAGE = 0.02 

	for _, data in ipairs(hitData) do
		local currentHitCount = 0
		if data.Model then currentHitCount = modelHitCounts[data.Model] or 0 end

		local currentLimit = 5
		local decayFactor = 0.5 ^ currentHitCount 

		if data.IsProp then 
			currentLimit = 45 
			decayFactor = 0.9 ^ currentHitCount 
		elseif data.Model then
			if CollectionService:HasTag(data.Model, "Vehicle") then
				if not dynamicLimits[data.Model] then
					local partCount = 0
					for _, item in pairs(data.Model:GetDescendants()) do
						if item:IsA("BasePart") then partCount += 1 end
					end
					dynamicLimits[data.Model] = math.max(5, math.floor(partCount * SPREAD_PERCENTAGE))
				end
				currentLimit = dynamicLimits[data.Model]
			else
				currentLimit = 1
			end
		end

		if currentHitCount >= currentLimit then continue end

		if not hitVictims[data.Target] then
			local distanceFalloff = math.clamp(1 - (data.Distance / radius), 0, 1)
			local finalSplashDamage = rawSplashDamage * decayFactor * distanceFalloff
			if data.Model then modelHitCounts[data.Model] = currentHitCount + 1 end
			hitVictims[data.Target] = true

			if data.IsProp then
				fireFunc("MechDamageEvent", data.Target, finalSplashDamage, false, explosionID)
			elseif data.Model and CollectionService:HasTag(data.Model, "Vehicle") then
				if data.Model == sourceMech then finalSplashDamage = finalSplashDamage / 2 end 
				fireFunc("MechDamageEvent", data.Target, finalSplashDamage, false, explosionID)
			elseif data.Model and data.Model:FindFirstChild("Humanoid") then
				local seat = sourceMech:FindFirstChildWhichIsA("VehicleSeat", true)
				local myPilot = seat and seat.Occupant and seat.Occupant.Parent
				if data.Model ~= myPilot then
					local rootPart = data.Model:FindFirstChild("HumanoidRootPart") or data.Target
					fireFunc("MechDamageEvent", rootPart, finalSplashDamage * pilotMultiplier, false, explosionID)
				end
			end
		end
	end
end

return SplashDamage