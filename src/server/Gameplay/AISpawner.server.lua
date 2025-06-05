local Workspace         = game:GetService("Workspace")
local Teams             = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")

-- Configuration
local NUM_BLUE_GUARDS = 1
local NUM_RED_GUARDS  = 1

-- Templates
local NPCFolder         = Workspace:WaitForChild("NPCs")
local BlueTemplate      = NPCFolder:WaitForChild("BlueGuardTemplate")
local RedTemplate       = NPCFolder:WaitForChild("RedGuardTemplate")
local spawnPointsFolder = Workspace:WaitForChild("NPCsSpawnPoints")

-- Helper: pick a random spawn point for a given team
local function getRandomSpawn(teamName)
    local points = {}
    for _, part in ipairs(spawnPointsFolder:GetChildren()) do
        if part.Name:match(teamName .. "Spawn") then
            table.insert(points, part.Position)
        end
    end
    if #points == 0 then return Vector3.new(0, 5, 0) end
    return points[math.random(1, #points)]
end

-- Spawn n NPCs for a given team
local function spawnNpcs(teamName, template, count)
    for i = 1, count do
        local npcClone = template:Clone()
        npcClone.Parent = Workspace
        npcClone.Name = teamName .. "Guard_" .. i

        -- Set the Team tag (in case the template didn’t have it)
        local tag = npcClone:FindFirstChild("Team")
        if not tag then
            tag = Instance.new("StringValue", npcClone)
            tag.Name = "Team"
        end
        tag.Value = teamName

        -- Move NPC to spawn point
        local pos = getRandomSpawn(teamName)
        npcClone:SetPrimaryPartCFrame(CFrame.new(pos + Vector3.new(0, 3, 0)))  -- slight Y offset so it doesn’t spawn stuck

        -- Ensure NPC has a Humanoid + PrimaryPart for AIController to work
        local humanoid = npcClone:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid.WalkSpeed = 0  -- AIController will set actual speed
        end

        -- Kick off the AIController coroutine inside the cloned NPC
        local controllerScript = npcClone:FindFirstChild("AIController")
        if controllerScript then
            controllerScript.Disabled = false
        end
    end
end

-- Once the map is loaded, spawn guards for each team
spawn(function()
    wait(2)  -- let the world settle
    spawnNpcs("Blue", BlueTemplate, NUM_BLUE_GUARDS)
    spawnNpcs("Red", RedTemplate, NUM_RED_GUARDS)
end)
