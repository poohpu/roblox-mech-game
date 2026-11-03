-- Cannon ModuleScript –
local Cannon = {}
Cannon.__index = Cannon

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local rojoShared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local SplashDamage = require(rojoShared.ModuleScripts.MechModules.SplashDamage)
local isServer = RunService:IsServer()
local CombatGuard = require(rojoShared.ModuleScripts.MechModules.CombatGuard)
local MechAudio = require(rojoShared.ModuleScripts.MechModules.MechAudio)
local isServer = game:GetService("RunService"):IsServer()

-- This function intercepts all network requests. 
-- We added 'self' as the first parameter so the Server knows WHO is shooting!
local function SecureNetworkFire(self, eventName, target, damage, spillover, explosionID)
	if isServer then
		-- It is ONLY allowed to broadcast staggers/visuals. 
		-- It is physically impossible for the Server weapon scripts to deal damage now!
		if eventName == "MechStagger" then
			-- verify if the target can be affected
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
function Cannon.new(mechModel, weaponPart)
	local self = setmetatable({}, Cannon)

	self.Mech = mechModel
	self.WeaponPart = weaponPart
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

	-- Fallback if no muzzle attachments exist
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

	-- Grab the master shell we just built!
	self.ShellTemplate = template or game:GetService("ReplicatedStorage"):WaitForChild("CannonShell")

	self.WeaponName = weaponPart:GetAttribute("WeaponName") or weaponPart.Name
	self.Cooldown = weaponPart:GetAttribute("Cooldown") or 1.5 -- Cannons fire slower
	self.BulletSpeed = weaponPart:GetAttribute("BulletSpeed") or 300 -- Slower than hitscan
	self.MaxRange = weaponPart:GetAttribute("MaxRange") or 750 
	self.GravityDrop = weaponPart:GetAttribute("GravityDrop") or 0.2
	self.StaggerPower = weaponPart:GetAttribute("StaggerPower") or 0.6
	self.Damage = weaponPart:GetAttribute("Damage") or 25           
	self.BlastRadius = weaponPart:GetAttribute("BlastRadius") or 15 
	self.PilotMultiplier = weaponPart:GetAttribute("PilotDamageMultiplier") or 5

	-- AMMO STATS
	self.MaxAmmo = weaponPart:GetAttribute("MaxAmmo") or 5
	self.CurrentAmmo = self.MaxAmmo
	self.ReloadTime = weaponPart:GetAttribute("ReloadTime") or 4.0
	self.IsReloading = false

	self.LastFireTime = 0 
	self.FireAccumulator = 0

	return self
end

-- ==========================================
-- 1.5 THE RELOAD SEQUENCE
-- ==========================================
function Cannon:Reload()
	if self.IsReloading then return end
	self.IsReloading = true
	
	print("?? SYSTEM:", self.WeaponName, "is reloading...")

	-- 0.2s Server Buffer to prevent latency post-reload rejection
	local actualReloadTime = isServer and math.max(0.1, self.ReloadTime - 0.2) or self.ReloadTime

	task.delay(self.ReloadTime, function()
		self.CurrentAmmo = self.MaxAmmo
		self.IsReloading = false
		print("? SYSTEM:", self.WeaponName, "reloaded! Ammo:", self.CurrentAmmo)
	end)
end

-- ==========================================
-- 2. THE FIRE ACTION 
-- ==========================================
function Cannon:Fire(targetPosition, ignoreList, isLocalShooter, deltaTime)
	--if isServer then
	--	print("🚨 SERVER CANNON: Trigger pulled! Ammo:", self.CurrentAmmo, "| Reloading:", self.IsReloading)
	--end
	if self.IsReloading then return 0 end
	local function PlayBlastVisuals(impactPosition, blastDirection, hitNormal)
		if isServer then return end
		local explosion = Instance.new("Explosion")
		explosion.Position = impactPosition
		explosion.BlastRadius = 20
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
			newSpark:Emit(15) 
			game.Debris:AddItem(sparkAnchor, 2)
		end
	end

	local currentTime = os.clock()
	local shotsToFire = 0

	if isLocalShooter then
		-- 1. Auto-Sync Ammo: If the client paused shooting long enough to reload, top off the Server!
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
			if (currentTime - self.LastFireTime) < self.Cooldown or self.CurrentAmmo <= 0 then
				return 0
			end

			self.CurrentAmmo -= 1
			shotsToFire = 1
			self.LastFireTime = currentTime
		end

		if self.CurrentAmmo <= 0 then
			task.spawn(function() self:Reload() end)
		end

		if shotsToFire == 0 then return 0 end
	else
		shotsToFire = 1
	end

	-- 1. Determine which muzzles fire during this trigger pull
	local muzzlesToFire = {}

	if self.FireMode == "Simultaneous" then
		muzzlesToFire = self.Muzzles
	else
		-- Alternating mode: pick the current muzzle, then advance the counter
		local activeMuzzle = self.Muzzles[self.CurrentMuzzleIndex] or self.WeaponPart
		table.insert(muzzlesToFire, activeMuzzle)

		self.CurrentMuzzleIndex = (self.CurrentMuzzleIndex % #self.Muzzles) + 1
	end

	-- 2. Fire each selected muzzle
	for _, muzzle in ipairs(muzzlesToFire) do
		-- Visuals & Audio per muzzle
		local flashEmitter = muzzle:FindFirstChild("MuzzleFlash")
		if flashEmitter and not isServer then flashEmitter:Emit(3) end

		local fireSound = muzzle:FindFirstChild("FireSound") or self.FireSound
		if fireSound and not isServer then fireSound:Play() end

		-- Physics & Shell Origin
		local gunBasePos = (muzzle:IsA("Attachment") and muzzle.Parent and muzzle.Parent.Position) or self.WeaponPart.Position
		local muzzlePos = (muzzle:IsA("Attachment") and muzzle.WorldPosition) or muzzle.Position

		local trueAimDirection = (targetPosition - gunBasePos).Unit
		local barrelLength = (muzzlePos - gunBasePos).Magnitude
		local barrelVector = trueAimDirection * barrelLength
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

		local shellRadius = 1.5 
		local clearanceHit = workspace:Raycast(gunBasePos, barrelVector, clearanceParams)



		local function TriggerExplosion(impactPosition, hitPart, blastDirection, hitNormal)

			if isLocalShooter then
				-- Generate a completely unique ID for this specific explosion
				local explosionID = "Blast_" .. tostring(os.clock()) .. "_" .. tostring(math.random(1000, 9999))
				local hitModel = hitPart:FindFirstAncestorWhichIsA("Model")

				-- Define the ledgers up here so BOTH Direct and Splash can share them!
				local hitVictims = {} 
				local modelHitCounts = {}

				-- ==========================================
				-- 1. DIRECT HIT LOGIC
				-- ==========================================
				if hitModel then
					local isDestructible = false
					local currentNode = hitPart
					while currentNode and currentNode ~= workspace do
						if CollectionService:HasTag(currentNode, "Destructible") then
							isDestructible = true
							break
						end
						currentNode = currentNode.Parent
					end

					-- Route the Direct Hit target
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

					-- Log the direct hit so the splash ignores it, and start the decay counter at 1!
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
				SplashDamage.Apply({
					Origin = impactPosition,
					Radius = self.BlastRadius,
					BaseDamage = self.Damage * 0.5, -- Splash base is 50% of direct hit
					SourceMech = self.Mech,
					ExplosionID = explosionID,
					PilotMultiplier = self.PilotMultiplier,
					DirectHitPart = hitPart,
					HitNormal = hitNormal,
					BlastDirection = blastDirection,
					SecureFireFn = function(eventName, target, damage, spill, expID)
						SecureNetworkFire(self, eventName, target, damage, spill, expID)
					end
				})
			end
		end

		if clearanceHit then
			if game:GetService("RunService"):IsServer() then
				print("🚨 SERVER CANNON: Barrel blocked instantly by " .. clearanceHit.Instance.Name)
			end
			local safeDir = barrelVector.Magnitude > 0.001 and barrelVector.Unit or self.Muzzle.CFrame.LookVector

			if isLocalShooter then
				-- Draw the explosion on our screen
				PlayBlastVisuals(clearanceHit.Position, safeDir, clearanceHit.Normal)

			end

			-- 3. Deal the actual damage
			TriggerExplosion(clearanceHit.Position, clearanceHit.Instance, safeDir, clearanceHit.Normal)
		else
			-- PATH IS CLEAR!
			if game:GetService("RunService"):IsServer() then
				print("✅ SERVER CANNON: Shell spawned and flying!")
			end
			-- Spawn the physical shell at the muzzle and let it fly!
			local origin = muzzlePos
			local direction = (targetPosition - origin).Unit

			local shell = self.ShellTemplate:Clone()
			shell.CFrame = CFrame.lookAt(origin, origin + direction)
			shell.Parent = workspace

			if isServer then
				shell.Transparency = 1
				for _, child in pairs(shell:GetDescendants()) do
					if child:IsA("BasePart") then child.Transparency = 1 end
					if child:IsA("ParticleEmitter") or child:IsA("Trail") then child.Enabled = false end
				end
			end
			shell.AssemblyLinearVelocity = direction * self.BulletSpeed
			shell.CanCollide = false
			shell.CanQuery = false
			if game:GetService("RunService"):IsServer() then
				shell:SetNetworkOwner(nil)
			end

			-- If GravityDrop is 0, the upward force perfectly cancels gravity, shooting perfectly straight!
			local attachment = Instance.new("Attachment")
			attachment.Parent = shell

			local antiGrav = Instance.new("VectorForce")
			antiGrav.Attachment0 = attachment
			-- Formula: Upward Force = Mass * Gravity * (1 - How much we want it to drop)
			local counterForce = shell:GetMass() * workspace.Gravity * (1 - self.GravityDrop)
			antiGrav.Force = Vector3.new(0, counterForce, 0)
			antiGrav.RelativeTo = Enum.ActuatorRelativeTo.World
			antiGrav.Parent = shell

			-- We need a fresh ignore list for the flying shell so it doesn't blow up in our face
			local bulletIgnoreList = {self.Mech, shell}
			local seat = self.Mech:FindFirstChildWhichIsA("VehicleSeat", true)
			local myPilot = seat and seat.Occupant and seat.Occupant.Parent
			if myPilot then table.insert(bulletIgnoreList, myPilot) end

			local tripwireParams = RaycastParams.new()
			tripwireParams.FilterDescendantsInstances = bulletIgnoreList
			tripwireParams.FilterType = Enum.RaycastFilterType.Exclude
			tripwireParams.CollisionGroup = "Players"

			-- Track exactly where the shell was in the previous frame
			local lastPos = shell.Position
			local tripwireConnection
			local hasWhizzed = false

			tripwireConnection = game:GetService("RunService").Heartbeat:Connect(function()
				-- Failsafe: Stop the loop if the shell was destroyed
				if not shell or not shell.Parent then
					tripwireConnection:Disconnect()
					return
				end

				local currentPos = shell.Position
				local travelVector = currentPos - lastPos
				local travelDistance = travelVector.Magnitude

				if not isServer and not isLocalShooter and not hasWhizzed and workspace.CurrentCamera then
					local camPos = workspace.CurrentCamera.CFrame.Position
					local closestPoint = getClosestPointOnSegment(lastPos, currentPos, camPos)

					if (closestPoint - camPos).Magnitude <= 35 then
						hasWhizzed = true
						MechAudio.playCombatSound("ShellWhiz", closestPoint)
					end
				end

				-- Only calculate if the shell actually moved
				if travelDistance > 0.001 then
					local staggerBuffer = travelVector.Unit * 20
					local safeStartPos = lastPos - staggerBuffer
					local safeTravelVector = travelVector + staggerBuffer
					-- Shoot a laser from where it WAS, to where it IS NOW
					local tripwireThickness = 0.2
					if isServer then tripwireThickness = 4.0 end -- Server gets a massive hitbox to forgive Ping differences!
					local hitResult = workspace:Spherecast(safeStartPos, tripwireThickness, safeTravelVector, tripwireParams)

					if hitResult then
						-- hitResult.Distance is exactly how far the shell traveled before touching the armor.
						-- By moving the start position forward by that exact distance, we get the TRUE center of the shell!
						local impactCenter = safeStartPos + (safeTravelVector.Unit * hitResult.Distance)
						if game:GetService("RunService"):IsServer() then
							print("💥 SERVER CANNON STRUCK: " .. hitResult.Instance.Name)
						else
							print("?? CLIENT CANNON STRUCK: " .. hitResult.Instance.Name)
						end
						-- Check if we hit a living, moving target
						local hitAncestor = hitResult.Instance:FindFirstAncestorWhichIsA("Model")
						local CollectionService = game:GetService("CollectionService")
						local isCombatHit = hitAncestor and (CollectionService:HasTag(hitAncestor, "Vehicle") or hitAncestor:FindFirstChild("Humanoid"))

						if isLocalShooter then
							-- ?? THE SHOOTER: Always explode, deal damage, and tell the network!
							PlayBlastVisuals(impactCenter, travelVector.Unit, hitResult.Normal)
							TriggerExplosion(impactCenter, hitResult.Instance, travelVector.Unit, hitResult.Normal)

						else
							-- ?? THE SPECTATOR: Always explode visually to hide lag!
							PlayBlastVisuals(impactCenter, travelVector.Unit, hitResult.Normal)

							-- We STILL do not send damage here. We just make it look good instantly!
						end

						shell:Destroy()
						tripwireConnection:Disconnect()
						return
					end
				end

				-- Update the position for the next frame's check
				lastPos = currentPos
			end)

			--local connection
			--connection = shell.Touched:Connect(function(hit)
			--	if hit:IsDescendantOf(self.Mech) then return end
			--	if connection then connection:Disconnect() end

			--	-- The shell hit something mid-air! Trigger the exact same explosion!
			--	TriggerExplosion(shell.Position, hit, direction)
			--	shell:Destroy()
			--end)
			local timeToLive = self.MaxRange / self.BulletSpeed

			task.delay(timeToLive, function()
				-- If the shell hasn't exploded on anything yet...
				if shell and shell.Parent then

					-- 1. Disconnect the impact trigger so it doesn't explode when it hits the floor
					if tripwireConnection then tripwireConnection:Disconnect() end

					-- 2. Destroy the VectorForce so the shell is immediately crushed by Roblox gravity
					if antiGrav then antiGrav:Destroy() end

					-- 3. Turn it into a dead casing
					shell.CanCollide = true
					shell.Material = Enum.Material.Plastic
					shell.BrickColor = BrickColor.new("Dark stone grey")

					-- 4. Tell the server to clean up the trash 3 seconds later
					game.Debris:AddItem(shell, 3)
				end
			end)
		end
	end

	return true
end

return Cannon
-- Cannon End –
