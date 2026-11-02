local MechAudio = {}

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local footstepEvent = ReplicatedStorage:WaitForChild("MechFootstepEvent")

MechAudio.BASE_STEP_ID = "rbxassetid://117557461299376"

MechAudio.MATERIAL_LAYERS = {
	[Enum.Material.Grass] = {
		"rbxassetid://93258972585027", 
		Volume = 0.06,       -- Softer so it doesn't overpower the mech
		MinPitch = 0.65,    -- Deeper playback speed makes it sound heavier
		MaxPitch = 0.80,},  
	[Enum.Material.Ground] = "rbxassetid://98375658066754",  
	[Enum.Material.Mud] = "rbxassetid://98375658066754",    
	[Enum.Material.Sand] = "rbxassetid://91970375419592",   
	[Enum.Material.Rock] = "rbxassetid://91970375419592",
	[Enum.Material.Snow] = "rbxassetid://81253534133158",    
	[Enum.Material.Fabric] = "rbxassetid://9114515257",  

	[Enum.Material.Plastic] = nil,
	[Enum.Material.SmoothPlastic] = nil,
	[Enum.Material.Metal] = nil,
	[Enum.Material.CorrodedMetal] = nil,
}

local function spawnSound(position, soundId, volume, speed)
	if not soundId or soundId == "" or soundId == "rbxassetid://0" then return end

	local attach = Instance.new("Attachment")
	attach.WorldPosition = position
	attach.Parent = workspace.Terrain

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.PlaybackSpeed = speed
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 15
	sound.RollOffMaxDistance = 250
	sound.Parent = attach
	sound:Play()

	Debris:AddItem(attach, 3)
end

function MechAudio.playFootstep(position, material, isReplication)
	if not isReplication and footstepEvent then
		footstepEvent:FireServer(position, material)
	end

	local basePitch = math.random(78, 98) / 100
	spawnSound(position, MechAudio.BASE_STEP_ID, 0.4, basePitch)

	local surfaceData = MechAudio.MATERIAL_LAYERS[material]
	if surfaceData then
		local chosenId = nil
		local volume = 0.1
		local minPitch = 0.90
		local maxPitch = 1.05

		if type(surfaceData) == "table" then
			-- Read custom overrides if defined on the table
			volume = surfaceData.Volume or volume
			minPitch = surfaceData.MinPitch or minPitch
			maxPitch = surfaceData.MaxPitch or maxPitch

			-- Handle either an explicit .Sounds subtable or direct array entries
			local pool = surfaceData.Sounds or surfaceData
			if #pool > 0 then
				chosenId = pool[math.random(1, #pool)]
			end
		else
			-- Simple string ID
			chosenId = surfaceData
		end

		if chosenId then
			local minInt = math.round((minPitch :: number) * 100)
			local maxInt = math.round((maxPitch :: number) * 100)
			local debrisPitch = math.random(minInt, maxInt) / 100
			spawnSound(position, chosenId, volume, debrisPitch)
		end
	end
end

if RunService:IsClient() and footstepEvent then
	footstepEvent.OnClientEvent:Connect(function(replicatedPos, replicatedMat)
		MechAudio.playFootstep(replicatedPos, replicatedMat, true)
	end)
end

MechAudio.COMBAT_SOUNDS = {
	BulletWhiz = {
		Sounds = {
			"rbxassetid://107896098783996",
			"rbxassetid://98869219249636",
			"rbxassetid://92387458125824",
			"rbxassetid://102419286509601"
		},
		Volume = 0.5,
		RollOffMin = 10,
		RollOffMax = 50,
	},
	ShellWhiz = {
		"rbxassetid://18328857935",
		Volume = 0.5,
		RollOffMin = 10,
		RollOffMax = 100,
	},
	HeavyShellWhiz = {					-- unused (for bigger projectile in the future)
		"rbxassetid://18328857241",
		Volume = 0.4,
		RollOffMin = 10,
		RollOffMax = 200,
	},
	BulletImpactGround = {
		"rbxassetid://6962154328",
		Volume = 0.3,
		RollOffMin = 10,
		RollOffMax = 100,
		MinPitch = 1,
		MaxPitch = 1.3,
	},
	BulletImpactMech = {
		Sounds = {
			"rbxassetid://7842407284",
			"rbxassetid://7842407959",
			"rbxassetid://7842411929",
			"rbxassetid://7842412427",
			"rbxassetid://7842412909",
			"rbxassetid://98609496290942"
		},
		Volume = 0.5,
		RollOffMin = 10,
		RollOffMax = 300,
	},
	Explosion = {
		"rbxassetid://70690086887976",
		Volume = 0.5,
		RollOffMin = 10,
		RollOffMax = 400,
		MinPitch = 0.8,
		MaxPitch = 1.2,
	},
	MechPunchHit = {
		Sounds = {
			"rbxassetid://90390915247200",
			"rbxassetid://74928369482414",
			"rbxassetid://87911326370728",
			"rbxassetid://123559569929123",
			"rbxassetid://93947116603157",
			"rbxassetid://84831255267476"
		},
		Volume = 0.5,
		RollOffMin = 10,
		RollOffMax = 200,
		MinPitch = 0.9,
		MaxPitch = 1.1,
	}
}

function MechAudio.play3dSound(position, soundId, volume, pitch, minDistance, maxDistance)
	if not soundId or soundId == "" or soundId == "rbxassetid://0" then return end
	
	local attach = Instance.new("Attachment")
	attach.WorldPosition = position
	attach.Parent = workspace.Terrain

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 1.0
	sound.PlaybackSpeed = pitch or 1.0
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = minDistance or 10
	sound.RollOffMaxDistance = maxDistance or 200
	sound.Parent = attach
	sound:Play()

	Debris:AddItem(attach, 4)
end

function MechAudio.playCombatSound(soundKey, position)
	local soundData = MechAudio.COMBAT_SOUNDS[soundKey]
	if not soundData then return end

	local chosenId = nil
	local volume = 1.0
	local rollOffMin = 10
	local rollOffMax = 200
	local pitch = 1.0

	if type(soundData) == "table" then
		volume = soundData.Volume or volume
		rollOffMin = soundData.RollOffMin or rollOffMin
		rollOffMax = soundData.RollOffMax or rollOffMax

		-- Calculate randomized pitch if bounds are provided
		if soundData.MinPitch and soundData.MaxPitch then
			local minInt = math.round((soundData.MinPitch :: number) * 100)
			local maxInt = math.round((soundData.MaxPitch :: number) * 100)
			pitch = math.random(minInt, maxInt) / 100
		end

		-- Pick a sound ID from either a .Sounds array or a direct indexed table
		local pool = soundData.Sounds or soundData
		if #pool > 0 then
			chosenId = pool[math.random(1, #pool)]
		end
	elseif type(soundData) == "string" then
		chosenId = soundData
	end

	if chosenId then
		MechAudio.play3dSound(position, chosenId, volume, pitch, rollOffMin, rollOffMax)
	end
end

return MechAudio
