local VisualCluster = {}

function VisualCluster.Get(masterPart, mechModel)
	local cluster = {}
	local checked = {[masterPart] = true}
	local partsToCheck = {masterPart}

	-- 1. Grab Attribute-linked parts
	for _, child in pairs(mechModel:GetDescendants()) do
		if child:IsA("BasePart") and child:GetAttribute("DamageRedirect") == masterPart.Name then
			if not checked[child] then
				checked[child] = true
				table.insert(cluster, child)
				table.insert(partsToCheck, child)
			end
		end
	end

	-- 2. Grab Welded parts (Optimized)
	while #partsToCheck > 0 do
		local current = table.remove(partsToCheck, 1)
		-- Only query the physics engine if the part is actually in the Workspace simulation
		local joints = current:IsDescendantOf(workspace) and current:GetJoints() or current:GetChildren()

		for _, joint in pairs(joints) do
			if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
				local otherPart = (joint.Part0 == current) and joint.Part1 or joint.Part0
				if otherPart and otherPart:IsDescendantOf(mechModel) and not checked[otherPart] then
					checked[otherPart] = true
					-- Don't bridge health-bar boundaries (keep armor clusters separate from bones)
					if otherPart:GetAttribute("MaxHealth") == nil then
						table.insert(cluster, otherPart)
						table.insert(partsToCheck, otherPart)
					end
				end
			end
		end
	end
	return cluster
end

return VisualCluster