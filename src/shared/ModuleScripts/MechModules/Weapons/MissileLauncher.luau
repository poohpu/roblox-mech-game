-- MissileLauncher ModuleScript
local MissileLauncher = {}
MissileLauncher.__index = MissileLauncher

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local rojoShared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local SplashDamage = require(rojoShared.ModuleScripts.MechModules.SplashDamage)
local isServer = RunService:IsServer()
local CombatGuard = require(rojoShared.ModuleScripts.MechModules.CombatGuard)
local MechAudio = require(rojoShared.ModuleScripts.MechModules.MechAudio)

local function SecureNetworkFire(self, eventName, target, damage, spillover, explosionID)
	if isServer then
		if eventName == "MechStagger" then
			if not CombatGuard.CanAffect(self.Mech, target) then
				return
			end
			game:GetService("ReplicatedStorage").MechStagger:FireAllClients(target, damage, spillover)
		end
	else
		if eventName == "MechDamageEvent" then
			game:GetService("ReplicatedStorage").MechDamageEvent:FireServer(target, damage, spillover, explosionID, self.WeaponPart.Name)
		end
	end
end

function MissileLauncher.new(mechModel, weaponPart)
	local self = setmetatable({}, MissileLauncher)

	self.Mech = mechModel
	self.WeaponPart = weaponPart

	self.Muzzles = {}
	for _, child in pairs(weaponPart:GetChildren()) do
		if string.find(child.Name, "MuzzleMissile") then
			table.insert(self.Muzzles, child)
		end
	end
	if #self.Muzzles == 0 then table.insert(self.Muzzles, weaponPart) end
	self.CurrentMuzzleIndex = 1

	local projAttr = weaponPart:GetAttribute("ProjectileModel")
	local template = nil

	if typeof(projAttr) == "Instance" then
		template = projAttr
	elseif typeof(projAttr) == "string" then
		-- Searches ReplicatedStorage if an attribute string name was provided
		template = game:GetService("ReplicatedStorage"):FindFirstChild(projAttr, true)
	end

	self.MissileTemplate = template or game:GetService("ReplicatedStorage"):WaitForChild("MissileProjectile")

	self.WeaponName = weaponPart:GetAttribute("WeaponName") or "Missile Pod"
	self.Cooldown = weaponPart:GetAttribute("Cooldown") or 0.2
	self.BulletSpeed = weaponPart:GetAttribute("BulletSpeed") or 300 -- NOW ACTS AS STRICT MAX TOP SPEED
	self.MaxRange = weaponPart:GetAttribute("MaxRange") or 1000
	self.Damage = weaponPart:GetAttribute("Damage") or 4
	self.BlastRadius = weaponPart:GetAttribute("BlastRadius") or 6
	self.StaggerPower = weaponPart:GetAttribute("StaggerPower") or 0.2

	-- HOMING & SPREAD ATTRIBUTES
	self.TurnRate = weaponPart:GetAttribute("TurnRate") or 0.05
	self.Wobble = weaponPart:GetAttribute("Wobble") or 10
	self.TargetSpread = weaponPart:GetAttribute("TargetSpread") or 6     -- How wide the swarm hits
	self.EjectSpread = weaponPart:GetAttribute("EjectSpread") or 0.2     -- How much they fan out of the barrel
	self.IgnitionTime = weaponPart:GetAttribute("IgnitionTime") or 0.4   -- How long they float before engines ignite
	self.PilotMultiplier = weaponPart:GetAttribute("PilotDamageMultiplier") or 5

	self.MaxAmmo = weaponPart:GetAttribute("MaxAmmo") or 12
	self.CurrentAmmo = self.MaxAmmo
	self.ReloadTime = weaponPart:GetAttribute("ReloadTime") or 8
	self.IsReloading = false
	self.LastFireTime = 0 
	self.FireAccumulator = 0

	return self
end

function MissileLauncher:Reload()
	if self.IsReloading then return end
	self.IsReloading = true

	task.delay(self.ReloadTime, function()
		self.CurrentAmmo = self.MaxAmmo
		self.IsReloading = false
	end)
end

function MissileLauncher:Fire(targetPosition, ignoreList, isLocalShooter, deltaTime)
	local currentTime = os.clock()
	if self.IsReloading then return 0 end
	
	local shotsToFire = 0

	-- (Keeping the Visuals and Explosion functions identical to previous step to save space!)
	local function PlayBlastVisuals(impactPosition, blastDirection, hitNormal)
		if isServer then return end
		local explosion = Instance.new("Explosion")
		explosion.Position = impactPosition
		explosion.BlastRadius = self.BlastRadius
		explosion.DestroyJointRadiusPercent = 0
		explosion.BlastPressure = 0
		explosion.Parent = workspace.Map.TrashPart
		
		MechAudio.playCombatSound("Explosion", impactPosition)

		local masterSpark = game:GetService("ReplicatedStorage"):FindFirstChild("ImpactSpark", true)
		if masterSpark then
			local sparkAnchor = Instance.new("Part")
			sparkAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
			sparkAnchor.Transparency = 1
			sparkAnchor.Anchored = true
			sparkAnchor.CanCollide = false
			sparkAnchor.CanQuery = false

			local safeNormal = hitNormal or -blastDirection
			sparkAnchor.Position = impactPosition + (safeNormal * 0.7)
			sparkAnchor.CFrame = CFrame.lookAt(sparkAnchor.Position, sparkAnchor.Position + blastDirection) 
			sparkAnchor.Parent = workspace.Map.TrashPart

			local newSpark = masterSpark:Clone()
			newSpark.Parent = sparkAnchor
			newSpark:Emit(8)
			game.Debris:AddItem(sparkAnchor, 2)
		end
	end

	local function TriggerExplosion(impactPosition, hitPart, blastDirection, hitNormal)
		if not isLocalShooter then return end
		local explosionID = "Blast_" .. tostring(os.clock()) .. "_" .. tostring(math.random(1000, 9999))
		local hitModel = hitPart:FindFirstAncestorWhichIsA("Model")
		local hitVictims = {} 
		local modelHitCounts = {}

		if hitModel then
			local isDestructible = false
			local currentNode = hitPart
			while currentNode and currentNode ~= workspace do
				if CollectionService:HasTag(currentNode, "Destructible") then isDestructible = true break end
				currentNode = currentNode.Parent
			end

			local actualDirectTarget = hitPart
			local redirectName = hitPart:GetAttribute("DamageRedirect")
			if redirectName and CollectionService:HasTag(hitModel, "Vehicle") then
				local masterPart = hitModel:FindFirstChild(redirectName, true)
				if masterPart then
					-- NEW VARIATION: redirect part with its own health + toggle ON takes
					-- the damage itself (the server duplicates it to the master).
					if hitPart:GetAttribute("CurrentHealth") and hitPart:GetAttribute("RedirectAlsoTakesDamage") then
						-- The master receives the duplicated damage, so the splash must skip it
						hitVictims[masterPart] = true
					else
						actualDirectTarget = masterPart
					end
				end
			end

			hitVictims[actualDirectTarget] = true 
			modelHitCounts[hitModel] = 1 

			if CollectionService:HasTag(hitModel, "Vehicle") then
				SecureNetworkFire(self, "MechStagger", hitModel, self.StaggerPower, blastDirection)
				SecureNetworkFire(self, "MechDamageEvent", actualDirectTarget, self.Damage, true, nil)
			elseif isDestructible then
				SecureNetworkFire(self, "MechDamageEvent", actualDirectTarget, self.Damage, true, nil)
			elseif hitModel:FindFirstChild("Humanoid") then
				local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
				local myPilot = seat and seat.Occupant and seat.Occupant.Parent
				if hitModel ~= myPilot then
					local rootPart = hitModel:FindFirstChild("HumanoidRootPart") or hitPart
					SecureNetworkFire(self, "MechDamageEvent", rootPart, self.Damage * self.PilotMultiplier, true, nil)
				end
			end
		end

		-- SPLASH DAMAGE
		SplashDamage.Apply({
			Origin = impactPosition,
			Radius = self.BlastRadius,
			BaseDamage = self.Damage * 0.5, -- Ensure this matches what you want for Missiles!
			SourceMech = self.Mech,
			ExplosionID = explosionID,
			PilotMultiplier = self.PilotMultiplier or 1,
			DirectHitPart = hitPart,
			HitNormal = hitNormal,
			BlastDirection = blastDirection,
			SecureFireFn = function(eventName, target, damage, spill, expID)
				SecureNetworkFire(self, eventName, target, damage, spill, expID)
			end
		})
	end

	if isLocalShooter then
		-- Only force-refill if we were ACTUALLY reloading and that reload should be done by now.
		-- This stops "I paused too long between shots" from being mistaken for "I reloaded."
		if self.IsReloading and (currentTime - self.LastFireTime > self.ReloadTime) then
			self.CurrentAmmo = self.MaxAmmo
			self.IsReloading = false
		end

		if isServer then
			-- SERVER VALIDATION: Token Bucket for Packet Bunching
			local timeSinceLast = currentTime - self.LastFireTime
			self.LastFireTime = currentTime

			self.ServerTimeBank = math.min((self.ServerTimeBank or (self.Cooldown * 2)) + timeSinceLast, self.Cooldown * 3)
			local bulletCost = self.Cooldown * 0.75

			if self.ServerTimeBank < bulletCost or self.CurrentAmmo <= 0 then
				if self.CurrentAmmo <= 0 then task.spawn(function() self:Reload() end) end
				return 0
			end

			self.ServerTimeBank -= self.Cooldown
			self.CurrentAmmo -= 1
			shotsToFire = 1
		else
			-- CLIENT TICK MODE
			if (currentTime - self.LastFireTime) >= self.Cooldown then
				if (self.FireAccumulator :: number) < self.Cooldown then
					self.FireAccumulator = self.Cooldown
				end
			end

			self.FireAccumulator = (self.FireAccumulator or 0) + (deltaTime or 0)

			if self.FireAccumulator < self.Cooldown or self.CurrentAmmo <= 0 then
				return 0
			end

			shotsToFire = 0
			while self.FireAccumulator >= self.Cooldown and shotsToFire < 2 and self.CurrentAmmo > 0 do
				self.FireAccumulator -= self.Cooldown    
				self.CurrentAmmo -= 1
				shotsToFire += 1
			end

			if self.FireAccumulator > self.Cooldown then
				self.FireAccumulator = self.Cooldown
			end

			self.LastFireTime = currentTime
		end

		if self.CurrentAmmo <= 0 then task.spawn(function() self:Reload() end) end

		if shotsToFire == 0 then return 0 end
	else
		-- Spectators never have to calculate ammo or cooldowns
		shotsToFire = 1
	end
	

	-- 1. CYCLE THE MUZZLE
	for i = 1, shotsToFire do
		local activeMuzzle = self.Muzzles[self.CurrentMuzzleIndex]
		self.CurrentMuzzleIndex += 1
		if self.CurrentMuzzleIndex > #self.Muzzles then self.CurrentMuzzleIndex = 1 end

		local origin = activeMuzzle.WorldPosition
		local fireSound = activeMuzzle:FindFirstChild("FireSound")
		if fireSound and not isServer then fireSound:Play() end

		-- NEW: GRAB PILOT'S TEAM COLOR
		local teamColor = Color3.new(1, 1, 1) -- Default to White
		local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
		local myPilotChar = seat and seat.Occupant and seat.Occupant.Parent
		if myPilotChar then
			local pilotPlayer = game:GetService("Players"):GetPlayerFromCharacter(myPilotChar)
			if pilotPlayer and pilotPlayer.Team then
				-- Read the AccentColor Attribute you made
				local accent = pilotPlayer.Team:GetAttribute("AccentColor")

				if accent then
					teamColor = accent
				else
					-- Fallback just in case a team is missing the attribute
					teamColor = pilotPlayer.Team.TeamColor.Color
				end
			end
		end

		local initialDirection = (targetPosition - origin).Unit
		local startOffsetCFrame = CFrame.lookAt(origin, origin + initialDirection)

		-- 2. SPAWN THE MISSILE
		local missile = self.MissileTemplate:Clone()

		if missile:IsA("BasePart") then 
			missile.Anchored = true 
			missile.CanQuery = false 
			missile.Color = teamColor
		end
		--for _, child in pairs(missile:GetDescendants()) do
		--	if child:IsA("BasePart") then child.Anchored = true child.CanQuery = false end

		--	-- APPLY TEAM COLOR TO VISUALS (Assumes they are White/Grayscale by default)
		--	if child:IsA("Trail") or child:IsA("Beam") or child:IsA("ParticleEmitter") then
		--		child.Color = ColorSequence.new(teamColor)
		--	elseif child:IsA("PointLight") then
		--		child.Color = teamColor
		--	end
		--end

		missile.CFrame = startOffsetCFrame
		missile.Parent = workspace.Map.TrashPart
		if isServer then missile.Transparency = 1 end

		local missileIgnoreList = {self.Mech, missile}
		if myPilotChar then table.insert(missileIgnoreList, myPilotChar) end

		local rayParams = RaycastParams.new()
		rayParams.FilterDescendantsInstances = missileIgnoreList
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.CollisionGroup = "Players"

		-- ==========================================
		-- EJECTION & HOMING VARIABLES
		-- ==========================================
		local rightVec = startOffsetCFrame.RightVector
		local upVec = startOffsetCFrame.UpVector
		local fwdVec = startOffsetCFrame.LookVector

		-- EjectSpread attribute determines how far they blast out sideways
		local ejectSpreadX = (math.random() - 0.5) * self.EjectSpread 
		local ejectSpreadY = (math.random() - 0.5) * self.EjectSpread 

		local currentLook = (fwdVec + (rightVec * ejectSpreadX) + (upVec * ejectSpreadY)).Unit
		local currentSpeed = 60 
		local distanceTraveled = 0
		local flightTime = 0
		local uniqueNoiseSeed = math.random(0, 1000)
		local hasIgnited = false

		-- TargetSpread attribute determines the size of the swarm hit-box
		local personalizedTarget = targetPosition + Vector3.new(
			(math.random() - 0.5) * self.TargetSpread,
			(math.random() - 0.5) * self.TargetSpread,
			(math.random() - 0.5) * self.TargetSpread
		)

		local connection = nil

		-- 3. START FLIGHT LOOP
		connection = RunService.Heartbeat:Connect(function(deltaTime)
			if not missile or not missile.Parent then
				connection:Disconnect()
				return
			end

			flightTime += deltaTime
			local currentPos = missile.Position
			local toTarget = personalizedTarget - currentPos
			local distanceToTarget = toTarget.Magnitude

			-- STAGE 1: EJECTION & FLOAT
			if flightTime < self.IgnitionTime then
				currentSpeed = math.max(10, currentSpeed - (100 * deltaTime)) 

				-- STAGE 2: IGNITION & HOMING
			else
				if not hasIgnited then
					hasIgnited = true
					-- TURN ON THE ROCKET BOOST VISUALS!
					if not isServer then
						for _, child in pairs(missile:GetDescendants()) do
							if child:IsA("Trail") or child:IsA("ParticleEmitter") or child:IsA("Beam") then
								child.Enabled = true
							elseif child:IsA("Sound") and child.Name == "Missile_Fly" then
								child:Play()
							end
						end
					end
				end

				if distanceToTarget > 10 then
					local perfectDirection = toTarget.Unit
					local noiseX = math.noise(flightTime * 8, uniqueNoiseSeed, 0)
					local noiseY = math.noise(0, flightTime * 8, uniqueNoiseSeed)

					local accuracyMultiplier = math.clamp(distanceToTarget / 50, 0, 1)
					local wobbleVector = Vector3.new(noiseX, noiseY, 0) * (self.Wobble * accuracyMultiplier)

					local desiredDirection = (perfectDirection + (wobbleVector / 50)).Unit
					currentLook = currentLook:Lerp(desiredDirection, self.TurnRate * (deltaTime * 75))

					-- Accelerate up to the strict max BulletSpeed
					currentSpeed = math.min(self.BulletSpeed, currentSpeed + (800 * deltaTime))
				end
			end

			local currentVelocity = currentLook * currentSpeed
			local stepVector = currentVelocity * deltaTime
			distanceTraveled += stepVector.Magnitude

			if distanceTraveled >= self.MaxRange then
				-- 1. Turn off engines
				for _, child in pairs(missile:GetDescendants()) do
					if child:IsA("Trail") or child:IsA("ParticleEmitter") or child:IsA("Beam") or child:IsA("PointLight") then
						child.Enabled = false
					end
					-- 2. Turn into a dead physical object
					if child:IsA("BasePart") then
						child.Anchored = false
						child.CanCollide = true
						child.Material = Enum.Material.Plastic
						child.Color = Color3.new(0.3, 0.3, 0.3) -- Dark grey
					end
				end

				if missile:IsA("BasePart") then
					missile.Anchored = false
					missile.CanCollide = true
					missile.Material = Enum.Material.Plastic
					missile.Color = Color3.new(0.3, 0.3, 0.3)
					-- 3. Pass the script's velocity over to the Roblox physics engine!
					missile.AssemblyLinearVelocity = currentVelocity 
				end

				game.Debris:AddItem(missile, 3)
				connection:Disconnect()
				return
			end

			local function DetonateAndFade(impactPos, impactNormal, hitInstance)
				-- Explode!
				PlayBlastVisuals(impactPos, currentLook, impactNormal)
				TriggerExplosion(impactPos, hitInstance, currentLook, impactNormal)

				-- Make the physical shell invisible, but keep the trail alive to fade out
				if missile:IsA("BasePart") then missile.Transparency = 1 end
				for _, child in pairs(missile:GetDescendants()) do
					if child:IsA("BasePart") then child.Transparency = 1 end
					-- Turn off the spigot, letting the existing trail naturally dissipate
					if child:IsA("Trail") or child:IsA("ParticleEmitter") or child:IsA("Beam") or child:IsA("PointLight") then
						child.Enabled = false
					elseif child:IsA("Sound") and child.Name == "Missile_Fly" then
						child:Stop()
					end
				end

				-- Safely delete it 2 seconds later once the trail is gone
				game.Debris:AddItem(missile, 2)
				connection:Disconnect()
			end

			-- PROXIMITY DETONATION (Fixes the infinite orbiting)
			-- If we are within 5 studs of the target point, explode in mid-air!
			if distanceToTarget <= 2 then
				-- Look a short distance ahead for a real surface to detonate against
				local snapDistance = 6
				local snapHit = workspace:Spherecast(currentPos, 1, currentLook * snapDistance, rayParams)

				local impactPos = currentPos
				local impactPart = workspace.Terrain
				local impactNormal = -currentLook

				if snapHit then
					impactPos = snapHit.Position
					impactPart = snapHit.Instance
					impactNormal = snapHit.Normal
				end

				DetonateAndFade(impactPos, impactNormal, impactPart)
				return
			end

			local hitResult = workspace:Raycast(currentPos, stepVector, rayParams)

			if hitResult then
				missile.CFrame = CFrame.lookAt(hitResult.Position, hitResult.Position + currentLook)

				DetonateAndFade(hitResult.Position, hitResult.Normal, hitResult.Instance)
			else
				missile.CFrame = CFrame.lookAt(currentPos + stepVector, currentPos + stepVector + currentLook)
			end
		end)

		return shotsToFire
	end
	
end

return MissileLauncher