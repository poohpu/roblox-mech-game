-- Location: ReplicatedStorage.ModuleScripts.MechModules.Weapons.MeleeProfiles
-- Function: store animation sequences for melee weapons

local MeleeProfiles = {}

MeleeProfiles.Fist = {
	WeaponName = "Fist",
	Cooldown = 2,
	Damage = 25,
	StaggerPower = 1.0,
	HitboxRadius = 3.0,
	
	Phases = {
		{
			Name = "Windup",
			Duration = 0.4,
			EasingStyle = Enum.EasingStyle.Sine,
			EasingDirection = Enum.EasingDirection.Out,
			JointAngles = {
				Waist = Vector3.new(0, 75, 0),
				Neck = Vector3.new(0, 75, 0),
				Shoulder = Vector3.new(15, 0, 60),
				Elbow = Vector3.new(-15, 0, 0),
			}
		},
		
		{
			Name = "Strike",
			Duration = 0.25,
			EasingStyle = Enum.EasingStyle.Cubic,
			EasingDirection = Enum.EasingDirection.Out,
			HitboxActive = true, 
			JointAngles = {
				Waist = Vector3.new(0, -80, 0),
				Neck = Vector3.new(0, -80, 0),
				Shoulder = Vector3.new(-160, 0, -30),
				Elbow = Vector3.new(160, 0, 0),
			}
		},
		
		{
			Name = "Recovery",
			Duration = 0.6,
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.Out,
			ResetAll = true
		}
	}
}

MeleeProfiles.PileBunker = {
	WeaponName = "Pile Bunker",
	Cooldown = 3,
	Damage = 140,
	StaggerPower = 2.5,
	HitboxRadius = 3.5,
	
	Phases = {
		
		{
			Name = "ChargeUp",
			Duration = 0.55,
			EasingStyle = Enum.EasingStyle.Back,
			EasingDirection = Enum.EasingDirection.Out,
			Sound = "PileBunker_Charge",
			JointAngles = {
				Waist = Vector3.new(0, 65, 0),
				Neck = Vector3.new(0, 65, 0),
				Shoulder = Vector3.new(25, 0, 45),
				Elbow = Vector3.new(-35, 0, 0),
			},
			-- PartOffsets: connected with Motor6D
			PartOffsets = {
				["PileSpike"] = CFrame.new(0, 0, 2.5) 
			}
		},
	
		{
			Name = "DriveThrust",
			Duration = 0.12, 
			EasingStyle = Enum.EasingStyle.Exponential,
			EasingDirection = Enum.EasingDirection.Out,
			HitboxActive = true,
			Sound = "PileBunker_Fire",
			VibrationMagnitude = 0.25, 
			JointAngles = {
				Waist = Vector3.new(0, -75, 0),
				Neck = Vector3.new(0, -75, 0),
				Shoulder = Vector3.new(-155, 0, -20),
				Elbow = Vector3.new(155, 0, 0),
			},
			PartOffsets = {
				["PileSpike"] = CFrame.new(0, 0, -6.0) 
			}
		},

		{
			Name = "VentSteam",
			Duration = 0.35,
			EasingStyle = Enum.EasingStyle.Linear,
			EasingDirection = Enum.EasingDirection.Out,
			PartOffsets = {
				["PileSpike"] = CFrame.new(0, 0, 0)
			}
		},
		
		{
			Name = "Recovery",
			Duration = 0.65,
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.Out,
			ResetAll = true
		}
	}
}

MeleeProfiles.Chainsaw = {
	WeaponName = "Chainsaw",
	Cooldown = 2,
	Damage = 18, -- damage per hit
	MultiDelay = 0.12, -- hit every 0.12 seconds while in active phase
	StaggerPower = 0.25,
	--HitboxRadius = 3.5,
	IsVolumeHitbox = true, -- Hits multiple parts touching

	Phases = {
		{
			Name = "RevUp",
			Duration = 0.3,
			EasingStyle = Enum.EasingStyle.Sine,
			EasingDirection = Enum.EasingDirection.Out,
			Sound = "Chainsaw_Rev",
			SwapChainsawBlades = true,
			VibrationMagnitude = 0.08,
			JointAngles = {
				Waist = Vector3.new(0, -35, 0),
				Neck = Vector3.new(0, -35, 0),
				Shoulder = Vector3.new(-110, 0, -15),
				Elbow = Vector3.new(110, 0, 0),
			}
		},
		
		{
			Name = "Grind",
			Duration = 1.5,
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.Out,
			HitboxActive = true,
			Sound = "Chainsaw_Fire",
			VibrationMagnitude = 0.22,
			JointAngles = {
				Waist = Vector3.new(0, -60, 0),
				Neck = Vector3.new(0, -60, 0),
				Shoulder = Vector3.new(-145, 0, -25),
				Elbow = Vector3.new(145, 0, 0),
			}
		},
		
		{
			Name = "Recovery",
			Duration = 0.5,
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.Out,
			SwapChainsawBlades = false,
			ResetAll = true
		}
	}
}
	

return MeleeProfiles
