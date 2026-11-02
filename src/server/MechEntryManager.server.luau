-- Services
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

-- Constants
local HATCH_TWEEN_INFO = TweenInfo.new(0.8, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut)

-- This function runs once for every mech that spawns
local function SetupMech(mechModel)
	if not mechModel:IsDescendantOf(workspace) then return end
	print("Wiring up new mech ->", mechModel.Name)

	-- 1. Find the essential parts anywhere inside the mech
	local seat = mechModel:FindFirstChildWhichIsA("VehicleSeat", true)
	local prompt = mechModel:FindFirstChildWhichIsA("ProximityPrompt", true)

	-- If it doesn't have a seat or prompt, it might be a different kind of vehicle, so we ignore it.
	if not seat or not prompt then
		warn("Missing seat or prompt in", mechModel.Name, "- Skipping setup.")
		return
	end
	
	local function GetCurrentHeadData()
		local currentHead = mechModel:FindFirstChild("Head", true)

		local currentNeck = nil
		local baseC0 = nil

		if currentHead then
			for _, obj in ipairs(mechModel:GetDescendants()) do
				-- Find the live neck, even if it's currently unplugged (Part1 = nil)
				if obj:IsA("JointInstance") and (obj.Name == "Neck" or obj.Name == "NeckMotor") then
					currentNeck = obj
					baseC0 = obj.C0
					break
				end
			end
		end

		-- Hand these to whatever requested them.
		return currentHead, currentNeck, baseC0
	end
	
	local function EvaluateLocomotionState()
		-- Grab the pristine blueprint to know what type of mech we are sitting in
		local pristineMech = game:GetService("ServerStorage"):WaitForChild("Vehicles"):FindFirstChild(mechModel.Name)
		local pristineSeat = pristineMech and pristineMech:FindFirstChildWhichIsA("VehicleSeat", true)

		local defaultLoco = pristineSeat and pristineSeat:GetAttribute("LocomotionType") or "Bipedal"
		local defaultSpeed = pristineSeat and pristineSeat:GetAttribute("WalkSpeed") or 15
		
		if defaultLoco == "Wheeled" then
			-- how many wheels
			local maxWheels = seat:GetAttribute("WheelAmount") or 4
			local wheelsLeft = seat:GetAttribute("WheelsRemaining")

			-- If WheelsRemaining is nil, it means it's a pristine mech that hasn't taken damage yet!
			if wheelsLeft == nil then wheelsLeft = maxWheels end

			-- Lock in the Base Speed so we have a clean number to multiply against
			local baseSpeed = seat:GetAttribute("BaseWalkSpeed")
			if not baseSpeed then 
				baseSpeed = defaultSpeed
				seat:SetAttribute("BaseWalkSpeed", baseSpeed) 
			end

			-- Calculate the crippled speed!
			local newSpeed = 0
			if wheelsLeft > 0 then
				local scaleSpeed = seat:GetAttribute("ScaleSpeedWithWheels")
				if scaleSpeed == nil then scaleSpeed = true end 

				if scaleSpeed then
					newSpeed = baseSpeed * (wheelsLeft / maxWheels)
				else
					newSpeed = baseSpeed 
				end
			end

			-- Apply the state and the speed
			seat:SetAttribute("LocomotionType", "Wheeled")
			seat:SetAttribute("WalkSpeed", newSpeed)

		else
			-- [BIPEDAL & CRAWLER LOGIC]
			local maxLegs = seat:GetAttribute("LegAmount") or 2
			local currentLegs = seat:GetAttribute("LegsRemaining") or 2

			if currentLegs < maxLegs then
				-- Determine crawler type based on default locomotion
				local targetCrawlerMode = (defaultLoco == "ChickenLegBipedal") and "ChickenLegCrawler" or "Crawler"
				seat:SetAttribute("LocomotionType", targetCrawlerMode)

				-- If 0 legs remain, speed is 0. Otherwise, crawl at custom CrawlSpeed or default to 40% speed
				local crawlSpeed = (currentLegs == 0) and 0 or (seat:GetAttribute("CrawlSpeed") or (defaultSpeed * 0.4))
				seat:SetAttribute("WalkSpeed", crawlSpeed)
			else
				-- THE MECH IS HEALTHY! ALLOW BIPEDAL BOOT-UP!

				-- if the mech is somehow a default crawler skip the standing tween
				if string.find(defaultLoco, "Crawler") then
					mechModel:SetAttribute("AwaitingStandUp", nil)
					seat:SetAttribute("LocomotionType", defaultLoco)
					seat:SetAttribute("WalkSpeed", defaultSpeed)
					
				elseif mechModel:GetAttribute("AwaitingStandUp") then
					mechModel:SetAttribute("AwaitingStandUp", nil) -- Consume the flag

					task.spawn(function()
						seat:SetAttribute("StandingUp", true)

						-- 1. Calculate the upright position
						local driveCore = mechModel:FindFirstChild("TargetGround", true)
						if driveCore then
							local _, currentY, _ = driveCore.CFrame:ToOrientation()
							local uprightCFrame = CFrame.new(driveCore.Position + Vector3.new(0, 3, 0)) * CFrame.Angles(0, currentY, 0)

							-- 2. Heave the mech out of the dirt
							local standTween = TweenService:Create(
								driveCore,
								TweenInfo.new(1.0, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
								{CFrame = uprightCFrame}
							)
							
							local cancelConnection
							cancelConnection = seat:GetAttributeChangedSignal("LocomotionType"):Connect(function()
								local currentLoco = seat:GetAttribute("LocomotionType")
								if currentLoco == "Crawler" or currentLoco == "ChickenLegCrawler" then
									print(string.format("⚡ INTERRUPT FIRED: [%.4f] Calling standTween:Cancel()", os.clock()))
									standTween:Cancel()
								end
							end)
							
							print(string.format("▶️ TWEEN STARTED: [%.4f]", os.clock()))
							standTween:Play()
							
							--task.delay(0.3, function()
							--	local legPart = mechModel:FindFirstChild("LeftThigh", true) or mechModel:FindFirstChild("LeftCalf", true)
							--	local damageRequest = game:GetService("ServerStorage"):FindFirstChild("ServerDamageRequest")
							--	if damageRequest and legPart then
							--		print("💥 TEST SABOTAGE: Detonating leg at t=0.3s!")
							--		damageRequest:Fire(legPart, 9999, false)
							--	end
							--end)
							
							standTween.Completed:Wait() 
							print(string.format("⏹️ TWEEN UNBLOCKED: [%.4f] PlaybackState: %s", os.clock(), tostring(standTween.PlaybackState)))

							if cancelConnection then
								cancelConnection:Disconnect()
							end
							
							-- Verify chassis integrity before applying Bipedal state
							local currentLegs = seat:GetAttribute("LegsRemaining") or 0
							if currentLegs < maxLegs then
								seat:SetAttribute("StandingUp", false)
								print("🛑 STAND-UP ABORTED: Chassis compromised mid-tween. Retaining Crawler state.")
								return
							end
							

							mechModel:SetAttribute("DriveCFrame", uprightCFrame)
							seat:SetAttribute("StandingUp", false)
						end

						-- 3. Restore original leg collisions
						for _, part in pairs(mechModel:GetDescendants()) do
							if part:IsA("BasePart") then
								local pNameLower = string.lower(part.Name)
								if string.find(pNameLower, "leg") or string.find(pNameLower, "calf") or string.find(pNameLower, "thigh") or string.find(pNameLower, "foot") then
									local origCollide = part:GetAttribute("OriginalCanCollide")
									if origCollide ~= nil then
										part.CanCollide = origCollide
									end
								end
							end
						end

						-- 4. Give full Bipedal stats after standing up
						seat:SetAttribute("LocomotionType", defaultLoco)
						seat:SetAttribute("WalkSpeed", defaultSpeed)

					end)
				else
					-- It's a fresh or already standing mech! Instantly apply Bipedal stats
					seat:SetAttribute("LocomotionType", defaultLoco)
					seat:SetAttribute("WalkSpeed", defaultSpeed)

				end
			end
		end
	end
	
	prompt.Triggered:Connect(function(player)
		local character = player.Character
		local humanoid = character and character:FindFirstChild("Humanoid")

		-- If the player has a valid character and the seat still exists, sit them down!
		if humanoid and seat then
			seat:Sit(humanoid)
		end
	end)
	
	local isHatchMoving = false
	
	-- 2. Multi-Hatch Scanner
	local hatches = {} -- Create an empty list to hold our doors

	for _, obj in ipairs(mechModel:GetDescendants()) do
		-- Find ANY joint where the part it holds is named "HatchPivot"
		if obj:IsA("JointInstance") and obj.Part1 and obj.Part1.Name == "HatchPivot" then
			local pivot = obj.Part1
			local closedC0 = obj.C0
			local openAngles = pivot:GetAttribute("OpenAngles") or Vector3.new(0, 0, 0)
			local openC0 = closedC0 * CFrame.Angles(math.rad(openAngles.X), math.rad(openAngles.Y), math.rad(openAngles.Z))
			local isHeadHatch = pivot:GetAttribute("IsHeadHatch") or false

			-- Bundle all this specific door's data into a package, and shove it in our list
			table.insert(hatches, {
				Hinge = obj,
				Pivot = pivot,
				ClosedC0 = closedC0,
				OpenC0 = openC0,
				IsHeadHatch = isHeadHatch
			})
		end
	end

	-- If the loop finishes and our list is still empty, this mech has no hatches. Abort!
	if #hatches == 0 then return end

	-- Since the mech just spawned and is currently empty, snap all hatches open immediately!
	if not seat.Occupant then

		-- Grab the freshest, currently alive head parts!
		local currentHead, currentNeck, baseC0 = GetCurrentHeadData()

		-- Loop through every single door we found on this mech
		for _, hatchData in ipairs(hatches) do

			-- If THIS specific door is designed to take the head with it, glue it!
			if hatchData.IsHeadHatch and currentHead and currentNeck then
				currentNeck.C0 = baseC0
				currentNeck.Part1 = nil -- Unplug the neck

				local newTempWeld = Instance.new("WeldConstraint")
				newTempWeld.Name = "TempHeadGlue"
				newTempWeld.Part0 = currentHead
				newTempWeld.Part1 = hatchData.Pivot
				newTempWeld.Parent = hatchData.Pivot
			end

			-- Snap this door open!
			hatchData.Hinge.C0 = hatchData.OpenC0
		end
	end

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()

		-- Find the hatch parts dynamically for THIS specific mech
		local currentHatchPivot = mechModel:FindFirstChild("HatchPivot", true)
		local currentHatchHinge = mechModel:FindFirstChild("HatchHinge", true)

		if seat.Occupant ~= nil then
			-- [SOMEONE GOT IN]
			print(seat.Occupant.Parent.Name .. " entered " .. mechModel.Name)

			-- Hide prompt so others can't hijack it!
			prompt.Enabled = false 

			-- 1. Loop through all doors and tween them closed
			local lastCloseTween = nil
			for _, hatchData in ipairs(hatches) do
				local tweenInfo = TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
				local closeTween = TweenService:Create(hatchData.Hinge, tweenInfo, {C0 = hatchData.ClosedC0})
				closeTween:Play()

				-- Remember the last tween we created so we can wait for it below
				lastCloseTween = closeTween 
			end

			-- 2. Wait for the doors to physically shut before handing control back to the player
			if lastCloseTween then
				lastCloseTween.Completed:Wait()
			end
			
			if seat.Occupant == nil then return end

			-- 3. Grab the freshest anatomy right AFTER the doors close
			local currentHead, currentNeck = GetCurrentHeadData()

			-- 4. Head Re-wiring (Entering) - Loop through the doors again to clean up the glue!
			if currentHead and currentNeck then
				for _, hatchData in ipairs(hatches) do
					-- Check if this specific door has glue on it, and destroy it
					for _, child in ipairs(hatchData.Pivot:GetChildren()) do
						if child.Name == "TempHeadGlue" then
							child:Destroy()
						end
					end

					-- If this door is the Head Hatch, plug the neck back in!
					if hatchData.IsHeadHatch then
						currentNeck.Part1 = currentHead
					end
				end
			end
			
			-- Evaluate speed and stance now that the player is safely inside!
			EvaluateLocomotionState()

		else
			-- [SOMEONE GOT OUT]
			print("Player exited " .. mechModel.Name)
			
			-- Grab the freshest, currently alive head parts right as they exit!
			local currentHead, currentNeck, baseC0 = GetCurrentHeadData()
			-- Loop through every single door on the mech
			for _, hatchData in ipairs(hatches) do

				-- Only do this if THIS specific door is the Head Hatch!
				if hatchData.IsHeadHatch and currentHead and currentNeck then
					currentNeck.C0 = baseC0
					currentNeck.Part1 = nil -- Unplug the normal neck

					-- Create a temporary weld to glue the head to THIS hatch
					if not hatchData.Pivot:FindFirstChild("TempHeadGlue") then
						local newTempWeld = Instance.new("WeldConstraint")
						newTempWeld.Name = "TempHeadGlue"
						newTempWeld.Part0 = currentHead
						newTempWeld.Part1 = hatchData.Pivot
						newTempWeld.Parent = hatchData.Pivot
					end
				end

				-- The Hatch Tween (Animate this specific door open)
				local tweenInfo = TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
				local openTween = TweenService:Create(hatchData.Hinge, tweenInfo, {C0 = hatchData.OpenC0})
				openTween:Play()
			end

			-- Turn prompt back on so it can be entered again
			prompt.Enabled = true 
		end

		isHatchMoving = false
	end)
end

-- Hook up any mechs that are ALREADY in the Workspace when the game starts
for _, mech in ipairs(CollectionService:GetTagged("Vehicle")) do
	SetupMech(mech)
end

-- Listen for any brand NEW mechs being spawned/cloned into the game later
CollectionService:GetInstanceAddedSignal("Vehicle"):Connect(SetupMech)