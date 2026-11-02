-- KineticWeapon ModuleScript 
local KineticWeapon = {}
KineticWeapon.__index = KineticWeapon

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local isServer = RunService:IsServer()

local CombatGuard = require(game:GetService("ReplicatedStorage").ModuleScripts.MechModules.CombatGuard)
local MechAudio = require(game:GetService("ReplicatedStorage").ModuleScripts.MechModules.MechAudio)

-- This function intercepts all network requests. 
-- We added 'self' as the first parameter so the Server knows WHO is shooting!
local function SecureNetworkFire(self, eventName, target, damage, spillover, explosionID)
	if isServer then
		-- It is ONLY allowed to broadcast staggers/visuals. 
		-- It is physically impossible for the Server weapon scripts to deal damage now!
		if eventName == "MechStagger" then
			if not CombatGuard.CanAffect(self.Mech, target) then
				return
			end
			game:GetService("ReplicatedStorage").MechStagger:FireAllClients(target, damage, spillover)
		end
	else
		-- ==========================================
		-- WE ARE THE CLIENT! 
		-- We let the Client send damage reports to the Server's Damage Manager!
		-- ==========================================
		if eventName == "MechDamageEvent" then
			game:GetService("ReplicatedStorage").MechDamageEvent:FireServer(target, damage, spillover, explosionID, self.WeaponPart.Name)
		end
	end
end

local function getClosestPointOnSegment(pointA, pointB, targetPoint)
	local segment = pointB - pointA
	local lengthSq = segment:Dot(segment)
	if lengthSq == 0 then return pointA end

	local t = math.clamp((targetPoint - pointA):Dot(segment) / lengthSq, 0, 1)
	return pointA + (segment * t)
end

-- ==========================================
-- 1. THE CONSTRUCTOR 
-- ==========================================
function KineticWeapon.new(mechModel, weaponPart)
	local self = setmetatable({}, KineticWeapon)

	self.Mech = mechModel
	self.WeaponPart = weaponPart
	-- 1. Scan the entire mech for muzzles on this part AND any redirected sibling parts
	self.Muzzles = {}
	local baseName = weaponPart.Name

	for _, desc in ipairs(mechModel:GetDescendants()) do
		if desc:IsA("BasePart") and (desc == weaponPart or desc:GetAttribute("DamageRedirect") == baseName) then
			for _, child in ipairs(desc:GetChildren()) do
				if child:IsA("Attachment") and string.find(child.Name, "Muzzle") then
					table.insert(self.Muzzles, child)
				end
			end
		end
	end

	-- Fallback if no attachments exist
	if #self.Muzzles == 0 then
		table.insert(self.Muzzles, weaponPart)
	end

	self.CurrentMuzzleIndex = 1
	self.FireMode = weaponPart:GetAttribute("FireMode") or "Alternating"
	
	local projAttr = weaponPart:GetAttribute("ProjectileModel")
	local template = nil

	if typeof(projAttr) == "Instance" then
		template = projAttr
	elseif typeof(projAttr) == "string" then
		-- Searches ReplicatedStorage if an attribute string name was provided
		template = game:GetService("ReplicatedStorage"):FindFirstChild(projAttr, true)
	end

	self.TracerTemplate = template or game:GetService("ReplicatedStorage"):FindFirstChild("TracerBullet") or nil

	-- WEAPON STATS
	self.WeaponName = weaponPart:GetAttribute("WeaponName") or weaponPart.Name
	self.IsAutomatic = (weaponPart:GetAttribute("IsAutomatic") == nil) and true or weaponPart:GetAttribute("IsAutomatic")
	self.Cooldown = weaponPart:GetAttribute("Cooldown") or 0.1
	self.BulletSpeed = weaponPart:GetAttribute("BulletSpeed") or 800 -- Studs per second!
	self.MaxRange = weaponPart:GetAttribute("MaxRange") or 500
	self.StaggerPower = weaponPart:GetAttribute("StaggerPower") or 0
	self.Damage = weaponPart:GetAttribute("Damage") or 5
	self.Spread = weaponPart:GetAttribute("Spread") or 1
	self.PilotMultiplier = weaponPart:GetAttribute("PilotDamageMultiplier") or 10

	-- Penetration = How many targets it can pierce THROUGH (0 = stops on first hit)
	self.Penetration = weaponPart:GetAttribute("Penetration") or 0
	-- PenetrationDecay = Multiplier applied to damage after each pierce (0.75 = loses 25% damage per pierce)
	self.PenetrationDecay = weaponPart:GetAttribute("PenetrationDecay") or 0.75

	self.MaxAmmo = weaponPart:GetAttribute("MaxAmmo") or 30
	self.CurrentAmmo = self.MaxAmmo
	self.ReloadTime = weaponPart:GetAttribute("ReloadTime") or 2.5 -- 2.5 seconds to reload
	self.IsReloading = false

	self.LastFireTime = 0 
	self.FireAccumulator = 0

	return self
end

function KineticWeapon:Reload()
	if self.IsReloading then return end
	self.IsReloading = true

	print("?? SYSTEM:", self.WeaponName, "is reloading...")

	-- (Optional: You could play a Reload Sound here!)

	--- Subtract a 0.2s ping buffer on the server so it finishes reloading
	-- slightly BEFORE the client's first post-reload network packet arrives.
	local actualReloadTime = isServer and math.max(0.1, self.ReloadTime - 0.2) or self.ReloadTime

	task.delay(actualReloadTime, function()
		self.CurrentAmmo = self.MaxAmmo
		self.IsReloading = false
	end)
end

-- ==========================================
-- 2. THE FIRE ACTION (Projectile Stepping)
-- ==========================================
function KineticWeapon:Fire(targetPosition, ignoreList, isLocalShooter, deltaTime)
	local currentTime = os.clock()
	local side = isServer and "[SERVER]" or "[CLIENT]"
	if self.IsReloading then return false end

	local shotsToFire = 0

	-- 1. Check Fire Rate Cooldown
	if isLocalShooter then
		-- 1. Auto-Sync Ammo: If the player paused shooting long enough to reload, top off the Server!
		-- Only force-refill if we were ACTUALLY reloading and that reload should be done by now.
		-- This stops "I paused too long between shots" from being mistaken for "I reloaded."
		if self.IsReloading and (currentTime - self.LastFireTime > self.ReloadTime) then
			self.CurrentAmmo = self.MaxAmmo
			self.IsReloading = false
			--print(string.format("🔄 %s %s auto-synced reload completed.", side, self.WeaponName))
		end

		-- 2. Ping Grace Period: Give the Server a 20% forgiveness buffer on cooldowns to absorb network lag!
		if isServer then 
			-- SERVER VALIDATION: Token Bucket for Packet Bunching
			local timeSinceLast = currentTime - self.LastFireTime
			self.LastFireTime = currentTime

			-- Accumulate a bank of time (cap it at 3 shots worth to prevent delayed burst hacking)
			self.ServerTimeBank = math.min((self.ServerTimeBank or (self.Cooldown * 2)) + timeSinceLast, self.Cooldown * 5)

			-- The cost of one bullet (with 25% ping/jitter forgiveness)
			local bulletCost = self.Cooldown * 0.75

			if (self.ServerTimeBank :: number) < bulletCost or self.CurrentAmmo <= 0 then
				if self.CurrentAmmo <= 0 then
					print(string.format("⛔ [SERVER] Rejected shot for %s (Out of Ammo: %d/%d)", self.WeaponName, self.CurrentAmmo, self.MaxAmmo))
					task.spawn(function() self:Reload() end)
				else
					print(string.format("⛔ [SERVER] Rejected shot for %s (Jitter limit - Bank: %.3fs < Cost: %.3fs)", self.WeaponName, self.ServerTimeBank, bulletCost))
				end
				return 0
			end
			
			-- Deduct the TRUE cooldown from the bank to maintain the strict long-term fire rate
			self.ServerTimeBank -= self.Cooldown 
			self.CurrentAmmo -= 1
			shotsToFire = 1

			--print(string.format("🔫 [SERVER] %s Fired | Ammo: %d/%d", self.WeaponName, self.CurrentAmmo, self.MaxAmmo))
		else
			-- Client, Frame-dependent, so we use the accumulator loop
			-- Single-fire weapons only fire 1 shot per trigger call, while automatic uses accumulator
			if not self.IsAutomatic then
				if (currentTime - self.LastFireTime) < self.Cooldown or self.CurrentAmmo <= 0 then
					return 0
				end
				self.CurrentAmmo -= 1
				shotsToFire = 1
				self.LastFireTime = currentTime
				--print(string.format("🔫 [CLIENT] %s Fired (Semi) | Ammo: %d/%d", self.WeaponName, self.CurrentAmmo, self.MaxAmmo))
			else
				if (currentTime - self.LastFireTime) >= self.Cooldown then
					if (self.FireAccumulator :: number) < self.Cooldown then
						self.FireAccumulator = self.Cooldown
					end
				end

				self.FireAccumulator += (deltaTime or 0)

				if self.FireAccumulator < self.Cooldown then
					return 0
				end

				while self.FireAccumulator >= self.Cooldown and shotsToFire < 2 and self.CurrentAmmo > 0 do
					self.FireAccumulator -= self.Cooldown -- Always subtract the true cost!
					self.CurrentAmmo -= 1
					shotsToFire += 1
				end

				if self.FireAccumulator > self.Cooldown then
					self.FireAccumulator = self.Cooldown
				end

				self.LastFireTime = currentTime
			--	print(string.format("🔫 [CLIENT] %s Fired (%d shots) | Ammo: %d/%d", self.WeaponName, shotsToFire, self.CurrentAmmo, self.MaxAmmo))
			end
			
		end
		
		
		-- If we are out of bullets, trigger the reload and cancel the shot
		if self.CurrentAmmo <= 0 then
		--	print(string.format("⚠️ %s %s emptied magazine! Triggering reload...", side, self.WeaponName))
			task.spawn(function() self:Reload() end)
		end

		if shotsToFire == 0 then
			return 0
		end

	end

	-- 1. Determine which muzzles fire on this trigger pull
	local muzzlesToFire = {}

	if self.FireMode == "Simultaneous" then
		muzzlesToFire = self.Muzzles
	else
		-- Alternating mode: pick current muzzle, advance index with modulo
		local activeMuzzle = self.Muzzles[self.CurrentMuzzleIndex] or self.WeaponPart
		table.insert(muzzlesToFire, activeMuzzle)

		self.CurrentMuzzleIndex = (self.CurrentMuzzleIndex % #self.Muzzles) + 1
	end

	-- 2. Fire each selected muzzle
	for _, muzzle in ipairs(muzzlesToFire) do
		local flashEmitter = muzzle:FindFirstChild("MuzzleFlash")
		if flashEmitter and not isServer then
			flashEmitter:Emit(1)
		end

		local fireSound = muzzle:FindFirstChild("FireSound") or self.FireSound
		if fireSound and not isServer then fireSound:Play() end

		-- Calculate origin per muzzle attachment
		local gunBasePos = (muzzle:IsA("Attachment") and muzzle.Parent and muzzle.Parent.Position) or self.WeaponPart.Position
		local muzzlePos = (muzzle:IsA("Attachment") and muzzle.WorldPosition) or muzzle.Position
		local barrelVector = muzzlePos - gunBasePos
		if barrelVector.Magnitude > 50 then
			barrelVector = barrelVector.Unit * 50
		end

		local ignoreList = {self.Mech}
		for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
			if player.Character then
				-- The engine will automatically ignore all body parts and hats instantly.
				table.insert(ignoreList, player.Character)
			end
		end

		local clearanceParams = RaycastParams.new()
		clearanceParams.FilterDescendantsInstances = ignoreList -- Ignore our own mech!
		clearanceParams.FilterType = Enum.RaycastFilterType.Exclude
		clearanceParams.CollisionGroup = "Players"

		local tracerRadius = 0.5 
		if barrelVector.Magnitude > 1000 then
			print(string.format("⚠️ [SHAPECAST DIAGNOSTIC] Oversized barrelVector! Magnitude: %.2f | GunBase: %s | MuzzlePos: %s", 
				barrelVector.Magnitude, 
				tostring(gunBasePos), 
				tostring(muzzlePos)
				))
		end
		local clearanceHit = workspace:Spherecast(gunBasePos, tracerRadius, barrelVector, clearanceParams)

		local shotID = (self.Penetration > 0) and ("Pierce_" .. tostring(os.clock()) .. "_" .. tostring(math.random(1000, 9999))) or nil

		local function TriggerMGHit(hitPosition, hitInstance, hitNormal, currentBulletDamage)
			-- Play 3D impact audio for both shooter and nearby spectators
			if not isServer then
				local hitModel = hitInstance:FindFirstAncestorWhichIsA("Model")
				if hitModel and CollectionService:HasTag(hitModel, "Vehicle") then
					MechAudio.playCombatSound("BulletImpactMech", hitPosition)
				else
					MechAudio.playCombatSound("BulletImpactGround", hitPosition)
				end
			end

			local masterSpark = game:GetService("ReplicatedStorage"):FindFirstChild("ImpactSpark", true)
			if masterSpark then
				local sparkAnchor = Instance.new("Part")
				sparkAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
				sparkAnchor.Transparency = 1
				sparkAnchor.Anchored = true
				sparkAnchor.CanCollide = false
				sparkAnchor.CanQuery = false
				sparkAnchor.CFrame = CFrame.lookAt(hitPosition, hitPosition + hitNormal)
				sparkAnchor.Parent = workspace.Map.TrashPart -- Or just workspace

				local newSpark = masterSpark:Clone()
				newSpark.Parent = sparkAnchor
				newSpark:Emit(5)
				game.Debris:AddItem(sparkAnchor, 2)
			end

			-- Damage Logic!
			if isLocalShooter and not isServer then
				local hitModel = hitInstance:FindFirstAncestorWhichIsA("Model")
				if hitModel then

					-- Deep search for destructible
					local isDestructible = false
					local currentNode = hitInstance
					while currentNode and currentNode ~= workspace do
						if CollectionService:HasTag(currentNode, "Destructible") then
							isDestructible = true
							break
						end
						currentNode = currentNode.Parent
					end
					
					-- Allow spillover into internal parts if the weapon has Penetration > 0
					local allowSpillover = (self.Penetration > 0)

					-- Damage Routing
					if CollectionService:HasTag(hitModel, "Vehicle") then
						SecureNetworkFire(self, "MechStagger", hitModel, self.StaggerPower, -hitNormal)
						SecureNetworkFire(self, "MechDamageEvent", hitInstance, currentBulletDamage, allowSpillover, shotID)
					elseif isDestructible then
						SecureNetworkFire(self, "MechDamageEvent", hitInstance, currentBulletDamage, allowSpillover, shotID)
					elseif hitModel:FindFirstChild("Humanoid") then
						local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
						local myPilot = seat and seat.Occupant and seat.Occupant.Parent

						if hitModel ~= myPilot then
							local targetHum = hitModel:FindFirstChildOfClass("Humanoid")
							local targetSeat = targetHum and targetHum.SeatPart
							local targetMech = targetSeat and targetSeat:FindFirstAncestorWhichIsA("Model")

							if hitModel ~= myPilot then
								SecureNetworkFire(self, "MechDamageEvent", hitInstance, currentBulletDamage * self.PilotMultiplier, allowSpillover, shotID)
							end
						end
					end
				end
			end
		end

		if clearanceHit then
			-- Pull back 0.2 studs
			TriggerMGHit(clearanceHit.Position, clearanceHit.Instance, clearanceHit.Normal, self.Damage)
		else
			local origin = muzzlePos
			local perfectDirection = (targetPosition - origin).Unit

			-- 1. Create a matrix pointing perfectly at the target
			local baseAimCFrame = CFrame.lookAt(Vector3.zero, perfectDirection)

			-- 2. Generate random angles (in Radians) based on your Spread attribute
			-- (math.random() - 0.5) * 2 gives a random number between -1.0 and 1.0
			local randomPitch = math.rad((math.random() - 0.5) * 2 * self.Spread)
			local randomYaw = math.rad((math.random() - 0.5) * 2 * self.Spread)

			-- 3. Apply the random shake to the perfect aim to get our final bullet path!
			local spreadCFrame = baseAimCFrame * CFrame.Angles(randomPitch, randomYaw, 0)
			local finalDirection = spreadCFrame.LookVector

			-- 3. Create the Visual Bullet
			local tracer
			if self.TracerTemplate then
				tracer = self.TracerTemplate:Clone()
			else
				-- Fallback default part if no custom model/part exists
				tracer = Instance.new("Part")
				tracer.Size = Vector3.new(0.2, 0.2, 3)
				tracer.Color = Color3.new(1, 0.77, 0.25)
				tracer.Material = Enum.Material.Neon
			end

			local spawnCFrame = CFrame.lookAt(origin, origin + finalDirection)
			if tracer:IsA("Model") then
				tracer:PivotTo(spawnCFrame)
				for _, desc in ipairs(tracer:GetDescendants()) do
					if desc:IsA("BasePart") then
						desc.Anchored = true
						desc.CanCollide = false
						desc.CanQuery = false
						if isServer then desc.Transparency = 1 end
					end
				end
			else
				tracer.CFrame = spawnCFrame
				tracer.Anchored = true
				tracer.CanCollide = false
				tracer.CanQuery = false
				if isServer then tracer.Transparency = 1 end
			end

			tracer.Parent = workspace.Map.TrashPart

			local bulletIgnoreList = {self.Mech}
			local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
			local myPilot = seat and seat.Occupant and seat.Occupant.Parent
			if myPilot then table.insert(bulletIgnoreList, myPilot) end

			-- 4. The Bullet Loop (Runs every single frame)
			local distanceTraveled = 0
			local connection = nil
			local hasWhizzed = false
			
			-- Track remaining penetrations and current damage for this bullet
			local remainingPen = self.Penetration
			local currentBulletDamage = self.Damage
			local hitMasterParts = {}

			connection = RunService.Heartbeat:Connect(function(deltaTime)
				local stepDistance = self.BulletSpeed * deltaTime
				distanceTraveled += stepDistance
				if distanceTraveled >= self.MaxRange then
					-- Stop calculating the raycast
					connection:Disconnect()

					local parts = tracer:IsA("Model") and tracer:GetDescendants() or {tracer}
					for _, p in ipairs(parts) do
						if p:IsA("BasePart") then
							p.Anchored = false
							p.CanCollide = true
							p.AssemblyLinearVelocity = finalDirection * self.BulletSpeed
							p.Material = Enum.Material.Plastic
							p.BrickColor = BrickColor.new("Dark stone grey")
						end
					end

					-- Tell the server to clean up the dead casing 3 seconds from now
					game.Debris:AddItem(tracer, 2)

					return
				end
				local stepVector = finalDirection * stepDistance
				local currentCFrame = tracer:IsA("Model") and tracer:GetPivot() or tracer.CFrame
				local currentPos = currentCFrame.Position

				-- Check for near-miss flyby sound past the local player's camera
				if not isServer and not isLocalShooter and not hasWhizzed and workspace.CurrentCamera then
					local camPos = workspace.CurrentCamera.CFrame.Position
					local closestPoint = getClosestPointOnSegment(currentPos, currentPos + stepVector, camPos)

					-- 20 studs represents close near-miss range
					if (closestPoint - camPos).Magnitude <= 20 then
						hasWhizzed = true
						MechAudio.playCombatSound("BulletWhiz", closestPoint)
					end
				end

				local remainingStepDist = stepDistance
				local rayOrigin = currentPos
				
				while remainingStepDist > 0.01 do
					local rayParams = RaycastParams.new()
					rayParams.FilterDescendantsInstances = bulletIgnoreList
					rayParams.FilterType = Enum.RaycastFilterType.Exclude
					rayParams.CollisionGroup = "Players"

					local hitResult = workspace:Raycast(rayOrigin, finalDirection * remainingStepDist, rayParams)

					if hitResult then
						local hitPart = hitResult.Instance
						local hitPoint = hitResult.Position
						local hitModel = hitPart:FindFirstAncestorWhichIsA("Model")
						
						local resolvedTarget = hitPart
						local redirectName = hitPart:GetAttribute("DamageRedirect")
						if redirectName and hitModel and CollectionService:HasTag(hitModel, "Vehicle") then
							local master = hitModel:FindFirstChild(redirectName, true)
							if master then
								-- NEW VARIATION: redirect part with its own health + toggle ON takes
								-- the damage itself (the server duplicates it to the master).
								if hitPart:GetAttribute("CurrentHealth") and hitPart:GetAttribute("RedirectAlsoTakesDamage") then
									if hitMasterParts[master] then
										-- Pair already damaged by this bullet: route to the marked master
										-- so the ledger check below skips it (no damage, no extra charge)
										resolvedTarget = master
									else
										-- Pre-mark the master so a later direct hit on it doesn't
										-- double-damage the pair within the same bullet
										hitMasterParts[master] = true
									end
								else
									resolvedTarget = master
								end
							end
						end
						
						table.insert(bulletIgnoreList, hitPart)

						-- 3.5 Check if the hit object is penetrable (Mech, Humanoid, or Destructible)
						local isPenetrable = false
						if hitModel and (CollectionService:HasTag(hitModel, "Vehicle") or hitModel:FindFirstChild("Humanoid")) then
							isPenetrable = true
						else
							-- Climb the hierarchy to check if it's a Destructible prop (like a tree)
							local currentNode = hitPart
							while currentNode and currentNode ~= workspace do
								if CollectionService:HasTag(currentNode, "Destructible") then
									isPenetrable = true
									break
								end
								currentNode = currentNode.Parent
							end
						end

						-- [If we hit a solid wall/terrain, trigger impact visuals and stop the bullet immediately!
						if not isPenetrable then
							TriggerMGHit(hitPoint, hitPart, hitResult.Normal, currentBulletDamage)
							tracer.CFrame = CFrame.lookAt(hitPoint, hitPoint + finalDirection)
							tracer:Destroy()
							connection:Disconnect()
							return
						end
						-- 4. If the target is a character, resolve the target to the MODEL so they can only be hit once!
						local isCharacter = hitModel and hitModel:FindFirstChildOfClass("Humanoid")
						if isCharacter then
							resolvedTarget = hitModel -- Treat the entire character as one entity!

							local hum = hitModel:FindFirstChildOfClass("Humanoid")
							local targetSeat = hum and hum.SeatPart
							local targetVehicle = targetSeat and targetSeat:FindFirstAncestorWhichIsA("Model")

							-- Seated Pilot Protection: Did we already penetrate their mech's hull?
							if targetVehicle and targetVehicle ~= self.Mech then
								for hitObj, _ in pairs(hitMasterParts) do
									if typeof(hitObj) == "Instance" and hitObj:IsDescendantOf(targetVehicle) then
										-- The hull shields the pilot; bullet absorbed by the mech!
										tracer.CFrame = CFrame.lookAt(hitPoint, hitPoint + finalDirection)
										tracer:Destroy()
										connection:Disconnect()
										return
									end
								end
							end
						end

						-- 5. Only trigger damage and consume a penetration charge if it's a NEW master part/model
						if not hitMasterParts[resolvedTarget] then
							hitMasterParts[resolvedTarget] = true
							TriggerMGHit(hitPoint, hitPart, hitResult.Normal, currentBulletDamage)

							-- Once a bullet strikes a human pilot, stop the bullet immediately!
							if isCharacter then
								tracer.CFrame = CFrame.lookAt(hitPoint, hitPoint + finalDirection)
								tracer:Destroy()
								connection:Disconnect()
								return
							end

							if remainingPen > 0 then
								remainingPen -= 1
								currentBulletDamage = currentBulletDamage * self.PenetrationDecay
							else
								-- Out of penetration! Snap tracer to final hit point and destroy
								tracer.CFrame = CFrame.lookAt(hitPoint, hitPoint + finalDirection)
								tracer:Destroy()
								connection:Disconnect()
								return
							end
						end

						-- 6. Advance rayOrigin to the impact point and continue the loop for parts behind it
						local traveled = (hitPoint - rayOrigin).Magnitude
						remainingStepDist -= traveled
						rayOrigin = hitPoint
					else
						-- Path is clear for the rest of this frame's step; move the visual bullet
						local nextCFrame = CFrame.lookAt(currentPos + stepVector, currentPos + stepVector + finalDirection)
						if tracer:IsA("Model") then
							tracer:PivotTo(nextCFrame)
						else
							tracer.CFrame = nextCFrame
						end
						break
					end
				end
			end)
		end
	end
	return shotsToFire or 1
		
	end

return KineticWeapon
-- KineticWeapon End – 
