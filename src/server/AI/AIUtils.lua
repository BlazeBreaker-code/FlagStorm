local PathfindingService = game:GetService("PathfindingService")
local Workspace          = game:GetService("Workspace")
local Teams              = game:GetService("Teams")
local Players            = game:GetService("Players")

local AIUtils = {}

-- Returns a path (array of CFrames) from origin to destination, or nil if no path
function AIUtils:ComputePath(origin, destination)
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 4,
	})
	path:ComputeAsync(origin, destination)
	if path.Status == Enum.PathStatus.Success then
		return path:GetWaypoints()
	else
		return nil
	end
end

-- Pick a random point on the map to patrol (loosely within Flags & Bases)
function AIUtils:GetRandomPatrolPoint()
	local minX, maxX = -100, 100   -- adjust based on your map’s bounds
	local minZ, maxZ = -100, 100
	local y = 1                     -- assume ground is at Y=1; adjust if needed
	local x = math.random(minX, maxX)
	local z = math.random(minZ, maxZ)
	return Vector3.new(x, y, z)
end

-- Returns the Character Model of the nearest enemy player to `originPosition`.
-- If none found, returns nil.
-- This guards against nil.Team and nil.Character.
function AIUtils:GetNearestEnemyPlayer(myTeam, originPosition)
	local nearestChar = nil
	local shortestDist = math.huge

	for _, player in ipairs(Players:GetPlayers()) do
		-- Skip players with no Team or players on the same team
		if player.Team and player.Team.Name ~= myTeam then
			local char = player.Character
			if char then
				local hrp = char:FindFirstChild("HumanoidRootPart")
				if hrp then
					local dist = (hrp.Position - originPosition).Magnitude
					if dist < shortestDist then
						shortestDist = dist
						nearestChar = char
					end
				end
			end
		end
	end

	return nearestChar
end

-- Return the enemy flag Model (or its HumanoidRootPart) based on NPC’s team
function AIUtils:GetEnemyFlag(npcTeam)
	local flagsFolder = Workspace:WaitForChild("Flags")
	if npcTeam == "Blue" then
		return flagsFolder:FindFirstChild("RedFlag")
	else
		return flagsFolder:FindFirstChild("BlueFlag")
	end
end

-- Return the NPC’s own base (“BlueBase” or “RedBase”) as a BasePart
function AIUtils:GetOwnBase(npcTeam)
	local baseName = npcTeam .. "Base"
	return Workspace:WaitForChild("Bases"):FindFirstChild(baseName)
end

-- Return the enemy base (for stealing back their own flag)
function AIUtils:GetEnemyBase(npcTeam)
	local enemyTeam = (npcTeam == "Blue") and "Red" or "Blue"
	local baseName = enemyTeam .. "Base"
	return Workspace:WaitForChild("Bases"):FindFirstChild(baseName)
end

return AIUtils
