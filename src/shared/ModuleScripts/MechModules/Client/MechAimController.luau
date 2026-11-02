--Location: ReplicatedStorage.ModuleScripts.MechModules.Client.MechAimController
--Function: Handles camera raycasting, target smoothing, angle lerping, limb yaw/pitch solver, 
--and reticle positioning.

local MechAimController = {}

function MechAimController.LerpAngle(current, target, step)
	local diff = (target - current)
	diff = (diff + math.pi) % (math.pi * 2) - math.pi 
	return current + (diff * math.clamp(step, 0, 1))
end

function MechAimController.RotateTowardsAngle(current, target, maxStep)
	local diff = (target - current)
	diff = (diff + math.pi) % (math.pi * 2) - math.pi
	if math.abs(diff) <= maxStep then return target end
	return current + (math.sign(diff) * maxStep)
end

function MechAimController.CalculateAimTarget(mechModel, mechData, isMobile, punchDeltaX, punchDeltaY, punchedX, punchedY, aimRaycastParams, cachedAimIgnoreList, localPlayer, smoothedTargetPos, deltaTime)
	local cam = workspace.CurrentCamera
	local rayScreenX, rayScreenY

	if isMobile then
		local center = cam.ViewportSize * 0.5
		rayScreenX = center.X + punchDeltaX
		rayScreenY = center.Y + punchDeltaY
	else
		rayScreenX = punchedX
		rayScreenY = punchedY
	end

	local aimRay = cam:ViewportPointToRay(rayScreenX, rayScreenY)
	table.clear(cachedAimIgnoreList)
	table.insert(cachedAimIgnoreList, mechModel)
	if localPlayer.Character then table.insert(cachedAimIgnoreList, localPlayer.Character) end

	aimRaycastParams.FilterDescendantsInstances = cachedAimIgnoreList
	local raycastResult = workspace:Raycast(aimRay.Origin, aimRay.Direction * 10000, aimRaycastParams)
	local targetPos = raycastResult and raycastResult.Position or (aimRay.Origin + aimRay.Direction * 10000)

	local camPos = cam.CFrame.Position
	local torsoPos = mechData.Torso.Position
	local distCamToTarget = (targetPos - camPos).Magnitude
	local distCamToMech = (torsoPos - camPos).Magnitude
	local distMechToTarget = (targetPos - torsoPos).Magnitude

	if distCamToTarget < distCamToMech or distMechToTarget < 8 then
		targetPos = camPos + (aimRay.Direction * 10000)
	end

	if not smoothedTargetPos then smoothedTargetPos = targetPos end
	smoothedTargetPos = smoothedTargetPos:Lerp(targetPos, math.clamp(deltaTime * 15, 0, 1))
	return smoothedTargetPos
end

return MechAimController