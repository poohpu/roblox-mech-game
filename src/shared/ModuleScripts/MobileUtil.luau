local UserInputService = game:GetService("UserInputService")

local MobileUtil = {}

-- Gating behind 'not KeyboardEnabled' prevents false positives on touchscreen laptops.
local cachedIsMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

function MobileUtil.isMobile(): boolean
	return cachedIsMobile
end

-- Track which weapon channels are active and whether the mobile fire button is pressed.
MobileUtil.WeaponToggles = {
	Primary = true,    -- Default to Primary active
	Secondary = true,
	Tertiary = true,
	Quaternary = true,
}

MobileUtil.IsFiring = false

MobileUtil.FireAimSensitivity = 0.5

return MobileUtil
