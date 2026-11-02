--Location: ReplicatedStorage.ModuleScripts.MechModules.Client.MechClientConfig
--Function: Centralized repository for all constants, UI color definitions, 
--screen scale baselines, and UI-to-part mappings.

local MechClientConfig = {}

MechClientConfig.TARGET_TOOL_NAME = "Targeting"
MechClientConfig.AIM_PUNCH_MULTIPLIER = 0.2
MechClientConfig.HIP_TILT_MULTIPLIER = 0.6
MechClientConfig.MOUSE_ICON = "rbxasset://textures/GunCursor.png"
MechClientConfig.RELOADING_ICON = "rbxasset://textures/GunWaitCursor.png"

MechClientConfig.MECH_RELOAD_ACTION = "MechReload"
MechClientConfig.MECH_MOBILITY_ACTION = "MechMobility"
MechClientConfig.MOBILITY_TAP_THRESHOLD = 0.25

MechClientConfig.MOBILITY_ENABLED_LOCOMOTIONS = {
	["Bipedal"] = true,
	["ChickenLegBipedal"] = true
}

-- UI Baseline Measurements
MechClientConfig.BASE_SCREEN_HEIGHT = 580
MechClientConfig.BASE_STROKE_THICKNESS = 3
MechClientConfig.BASE_TOOLTIP_WIDTH = 136
MechClientConfig.BASE_TOOLTIP_HEIGHT = 46
MechClientConfig.BASE_FONT_SIZE = 14

-- Color Palettes
MechClientConfig.CORE_100 = Color3.fromRGB(65, 213, 65)
MechClientConfig.CORE_50 = Color3.fromRGB(235, 219, 52)
MechClientConfig.CORE_0 = Color3.fromRGB(219, 53, 53)
MechClientConfig.CORE_DEAD = Color3.fromRGB(80, 80, 80)

MechClientConfig.ARMOR_100 = Color3.fromRGB(0, 170, 255)
MechClientConfig.ARMOR_50 = Color3.fromRGB(225, 110, 10)
MechClientConfig.ARMOR_0 = Color3.fromRGB(189, 4, 4)
MechClientConfig.ARMOR_DEAD = Color3.fromRGB(47, 47, 47)

MechClientConfig.FLASH_COLOR = Color3.new(1, 1, 1)
MechClientConfig.FLASH_DURATION = 0.15

MechClientConfig.UI_TO_PART_MAP = {
	["Head"] = "Head", ["CameraYawBase"] = "CameraYawBase", ["Torso"] = "Torso", ["Hip"] = "Torso",
	["LeftUpperArm"] = "LeftUpperArm", ["LeftLowerArm"] = "LeftLowerArm",
	["RightUpperArm"] = "RightUpperArm", ["RightLowerArm"] = "RightLowerArm",
	["LeftThigh"] = "LeftThigh", ["RightThigh"] = "RightThigh",
	["LeftCalf"] = "LeftCalf", ["RightCalf"] = "RightCalf",
	["LeftLegConn"] = "LeftLegConn", ["RightLegConn"] = "RightLegConn",
	["LeftFoot"] = "LeftFoot", ["RightFoot"] = "RightFoot",
	["LeftHand"] = "LeftHand", ["RightHand"] = "RightHand",
	["LeftWeapon"] = "LeftWeapon", ["RightWeapon"] = "RightWeapon",
	["LeftShoulderWeapon"] = "LeftShoulderWeapon", ["RightShoulderWeapon"] = "RightShoulderWeapon",
	["FrontLeftWheel"] = "FrontLeftWheel", ["FrontRightWheel"] = "FrontRightWheel",
	["BackLeftWheel"] = "BackLeftWheel", ["BackRightWheel"] = "BackRightWheel"
}

MechClientConfig.DISPLAY_NAMES = {
	["Head"] = "HEAD", ["CameraYawBase"] = "HEAD", ["Torso"] = "TORSO", ["Hip"] = "HIP",
	["LeftUpperArm"] = "LEFT UPPER ARM", ["LeftLowerArm"] = "LEFT LOWER ARM",
	["RightUpperArm"] = "RIGHT UPPER ARM", ["RightLowerArm"] = "RIGHT LOWER ARM",
	["LeftThigh"] = "LEFT THIGH", ["RightThigh"] = "RIGHT THIGH",
	["LeftCalf"] = "LEFT CALF", ["RightCalf"] = "RIGHT CALF",
	["LeftLegConn"] = "LEFT KNEE", ["RightLegConn"] = "RIGHT KNEE",
	["LeftFoot"] = "LEFT FOOT", ["RightFoot"] = "RIGHT FOOT",
	["LeftHand"] = "LEFT HAND", ["RightHand"] = "RIGHT HAND",
	["LeftWeapon"] = "LEFT ARM WEAPON", ["RightWeapon"] = "RIGHT ARM WEAPON",
	["LeftShoulderWeapon"] = "LEFT SHOULDER WEAPON", ["RightShoulderWeapon"] = "RIGHT SHOULDER WEAPON",
	["FrontLeftWheel"] = "FRONT LEFT WHEEL", ["FrontRightWheel"] = "FRONT RIGHT WHEEL",
	["BackLeftWheel"] = "BACK LEFT WHEEL", ["BackRightWheel"] = "BACK RIGHT WHEEL"
}

return MechClientConfig