-- ServerScriptService/Gameplay/FlagSystem.lua

--// Services
local Players        = game:GetService("Players")
local Replicated     = game:GetService("ReplicatedStorage")
local Workspace      = game:GetService("Workspace")

--// Configuration (folder paths)
local flagsFolder    = Workspace:WaitForChild("Flags")
local basesFolder    = Workspace:WaitForChild("Bases")
local TeamScores     = Replicated:WaitForChild("TeamScores")
local BlueScoreValue = TeamScores:WaitForChild("BlueScore")  -- IntValue
local RedScoreValue  = TeamScores:WaitForChild("RedScore")   -- IntValue

--// Constants
local STATE_SPAWN   = "Spawn"
local STATE_IN_PLAY = "InPlay"
local STATE_FREE    = "Free"

local DESPAWN_TIME  = 6     -- seconds before auto‐return
local PICKUP_DELAY  = 3     -- seconds before a dropped flag can be re‐picked

--// Data containers
type FlagData = {
    model:           Model,
    template:        Model,
    homeCFrame:      CFrame,
    team:            string,
    state:           string,
    timer:           thread?,
    holder:          Player?,
    flagHB:          Part?,
    touchConnection: RBXScriptConnection?,
    carrierHB:       Part?,
    weld:            Weld?
}

local flagStates = {} :: { [string]: FlagData }
local recentlyScored = {}



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- Helper Functions
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

-- Given a BasePart, return (player, character, teamString) if it’s a player’s limb
local function getPlayerFromPart(part)
    local model = part:FindFirstAncestorOfClass("Model")
    if not model or not model:FindFirstChildOfClass("Humanoid") then
        return nil, nil, nil
    end
    local player = Players:GetPlayerFromCharacter(model)
    if not player then return nil, nil, nil end
    local teamName = player.Team and player.Team.Name or nil
    return player, model, teamName
end

-- Make every BasePart descendant of a given Model anchored/collidable or not
local function setAllParts(model, anchored, canCollide)
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then
            p.Anchored = anchored
            p.CanCollide = canCollide
        end
    end
end

-- Weld a tiny invisible hitbox underneath a character so we can detect “steals”
local function createCarrierHitbox(char)
    local hb = Instance.new("Part")
    hb.Name         = "CarrierHitbox"
    hb.Size         = Vector3.new(4, 5, 4)
    hb.Transparency = 1
    hb.CanCollide   = false
    hb.CanTouch     = true
    hb.Anchored     = false
    hb.Parent       = char
    hb.CFrame       = char.HumanoidRootPart.CFrame

    local weld = Instance.new("WeldConstraint", hb)
    weld.Part0, weld.Part1 = char.HumanoidRootPart, hb

    return hb
end

-- Tear down everything for a given FlagData before respawning:
--   • Destroy the old model
--   • Disconnect its .Touched listener
--   • Destroy any existing carrier hitbox
--   • Kill any active timer
--   • Clear cached references
local function clearFlagData(data)
    if data.model then
        data.model:Destroy()
        data.model = nil
    end
    if data.touchConnection then
        data.touchConnection:Disconnect()
        data.touchConnection = nil
    end
    if data.carrierHB then
        data.carrierHB:Destroy()
        data.carrierHB = nil
    end
    data.flagHB = nil
    if data.timer then
        task.cancel(data.timer)
        data.timer = nil
    end
    data.holder = nil
    data.weld = nil
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- Hitbox setup for “Spawn” state
--
-- After we clone a fresh flag, find the invisible “TouchHitbox” 
-- beneath it, make it CanTouch=true, and connect .Touched → grabFlag.
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

local function setupSpawnHitbox(data, flagName)
    local hb = data.model:FindFirstChild("TouchHitbox", true)
    if not hb then
        warn("[FlagSystem] No TouchHitbox found inside model “" .. flagName .. "”")
        return
    end

    data.flagHB = hb
    hb.CanTouch = true

    data.touchConnection = hb.Touched:Connect(function(o)
        local pl, ch, tm = getPlayerFromPart(o)
        if not pl then return end
        -- Only allow pickup if it’s in the “Spawn” state and toucher is on the enemy team
        if data.state == STATE_SPAWN and tm ~= data.team then
            grabFlag(pl, ch, flagName)
        end
    end)
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- Hitbox setup for “Free” (dropped) state
--  
-- Once a flag is dropped, we want to re-enable its TouchHitbox
-- after a short delay (PICKUP_DELAY), so someone can pick it up again.
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

local function setupDropHitbox(data, flagName)
    local hb = data.flagHB
    if not hb then return end

    -- Immediately disconnect previous listener (if any) and disable CanTouch
    hb.CanTouch = false
    if data.touchConnection then
        data.touchConnection:Disconnect()
        data.touchConnection = nil
    end

    data.touchConnection = hb.Touched:Connect(function(o)
        local pl, ch, tm = getPlayerFromPart(o)
        if not pl or data.state ~= STATE_FREE then return end

        -- Touching with your own team → return to spawn
        if tm == data.team then
            returnFlagToSpawn(flagName)
        else
            grabFlag(pl, ch, flagName)
        end
    end)

    -- After PICKUP_DELAY seconds, re-enable CanTouch so it can be grabbed again
    task.delay(PICKUP_DELAY, function()
        if hb and hb.Parent then
            hb.CanTouch = true
        end
    end)
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- Return a flag to its spawn point:
--   1) Tear down old model/listeners
--   2) Clone a fresh template
--   3) Anchor + collidable on all parts
--   4) Hook up its “Spawn” .Touched listener
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

function returnFlagToSpawn(flagName)
    local data = flagStates[flagName]
    if not data then return end

    -- 1) Clean up
    clearFlagData(data)

    -- 2) Clone new template
    local f = data.template:Clone()
    f.Parent = flagsFolder
    f:SetPrimaryPartCFrame(data.homeCFrame)

    -- 3) Anchor + collide on all BaseParts
    setAllParts(f, true, true)

    data.model = f
    data.state = STATE_SPAWN

    -- 4) Hook its TouchHitbox for spawn‐pickup
    setupSpawnHitbox(data, flagName)
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- What happens when a player actually grabs a flag:
--   1) Cancel any free‐state auto‐return timer
--   2) Disconnect the spawn hitbox listener
--   3) Disable that TouchHitbox (so it can’t be triggered mid‐carry)
--   4) Unanchor + disable collisions on the entire flag model
--   5) Weld the flag’s PrimaryPart to the carrier’s HumanoidRootPart
--   6) Create a tiny “carrierHB” under the player for “steal detection”
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

function grabFlag(player, char, flagName)
    local data = flagStates[flagName]
    if not data then return end

    -- 1) Cancel any existing timer
    if data.timer then
        task.cancel(data.timer)
        data.timer = nil
    end

    -- 2) Disconnect the spawn hitbox listener
    if data.touchConnection then
        data.touchConnection:Disconnect()
        data.touchConnection = nil
    end

    -- 3) Disable the TouchHitbox so it won’t fire while carried
    if data.flagHB then
        data.flagHB.CanTouch = false
    end

    -- 4) Unanchor + disable collisions on every BasePart
    setAllParts(data.model, false, false)

    -- 5) Position & weld
    data.model:SetPrimaryPartCFrame(char.HumanoidRootPart.CFrame * CFrame.new(0, 5, 0))
    local w = Instance.new("Weld", char.HumanoidRootPart)
    w.Part0, w.Part1 = char.HumanoidRootPart, data.model.PrimaryPart
    w.C0 = CFrame.new(0, 5, 0)

    data.model.Parent = char
    data.weld = w
    data.state = STATE_IN_PLAY
    data.holder = player

    -- Tag the character so we know who’s carrying it
    local tag = Instance.new("StringValue", char)
    tag.Name  = "CarryingFlag"
    tag.Value = flagName

    -- 6) Create a small invisible “steal detection” hitbox
    local carrierHB = createCarrierHitbox(char)
    data.carrierHB = carrierHB

    carrierHB.Touched:Connect(function(p)
        onFlagHitboxTouched(carrierHB, p)
    end)
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- If someone touches the “carrier hitbox” (which is anchored to the carrier):
--   1) Check if toucher is an enemy
--   2) If yes, drop the flag where it was carried
--   3) Re‐enable its TouchHitbox for “free‐state” pickup after delay
--   4) Start an auto‐return timer if it sits on the ground too long
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

function onFlagHitboxTouched(hitbox, part)
    local thief, thiefChar, thiefTeam = getPlayerFromPart(part)
    if not thief then return end

    local carrierChar   = hitbox.Parent
    local carrierPlayer = Players:GetPlayerFromCharacter(carrierChar)
    if carrierPlayer == thief then return end

    local tag = carrierChar:FindFirstChild("CarryingFlag")
    if not tag then return end

    local data = flagStates[tag.Value]
    if not data then return end

    -- Only allow an enemy to steal
    if thiefTeam == data.team then
        local flagName = tag.Value

        -- 1) Clear carry state
        data.state  = STATE_FREE
        data.holder = nil
        tag:Destroy()

        if data.weld then
            data.weld:Destroy()
            data.weld = nil
        end

        -- 2) Detach the model & drop
        data.model.Parent = flagsFolder
        local dropPos = hitbox.Position - Vector3.new(0, 2, 0)
        data.model:SetPrimaryPartCFrame(CFrame.new(dropPos))
        setAllParts(data.model, false, true)  -- unanchor + enable collisions

        -- Remove the carrier’s hitbox
        hitbox:Destroy()
        data.carrierHB = nil

        -- 3) Re‐enable its TouchHitbox after a short delay
        if data.flagHB then
            setupDropHitbox(data, flagName)
        end

        -- 4) Auto‐return timer (if still dropped after DESPAWN_TIME)
        data.timer = task.delay(DESPAWN_TIME, function()
            if data.state == STATE_FREE then
                returnFlagToSpawn(flagName)
            end
        end)
    end
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- “Initialization” (runs once when the server script starts)
--
-- 1) Iterate through every child of Workspace.Flags
--    and build a FlagData entry (with .template & .homeCFrame).
-- 2) Immediately call returnFlagToSpawn(name) to ensure each flag 
--    is sitting at its spawn point in the world.
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

-- 1) Build the “flagStates” table
for _, f in ipairs(flagsFolder:GetChildren()) do
    if f:IsA("Model") then
        local nm = f.Name
        flagStates[nm] = {
            model           = f,
            template        = f:Clone(),
            homeCFrame      = f:GetPrimaryPartCFrame(),
            team            = nm:gsub("Flag", ""),  -- “BlueFlag” → “Blue”
            state           = STATE_SPAWN,
            timer           = nil,
            holder          = nil,
            flagHB          = nil,
            touchConnection = nil,
            carrierHB       = nil,
            weld            = nil
        }
    end
end

-- 2) Spawn (or respawn) each flag at startup
for nm in pairs(flagStates) do
    returnFlagToSpawn(nm)
end

--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- Base‐capture logic: when a “carrying” player touches their own base:
--   • Award 1 point to their personal leaderstats.Score 
--   • Bump the team score in ReplicatedStorage.TeamScores
--   • Remove the flag from their character 
--   • Return it to spawn
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

for _, base in ipairs(basesFolder:GetChildren()) do
    if base:IsA("BasePart") then
        base.Touched:Connect(function(part)
            local pl, ch, tm = getPlayerFromPart(part)
            if not pl then return end

            -- Debounce: prevent multiple touches in rapid succession
            if recentlyScored[pl.UserId] then return end
            recentlyScored[pl.UserId] = true
            task.delay(0.5, function()
                recentlyScored[pl.UserId] = nil
            end)

            -- Only allow capture if they’re touching the RIGHT base
            if base.Name ~= tm .. "Base" then return end

            local tag = ch:FindFirstChild("CarryingFlag")
            if not tag then return end

            local fd = flagStates[tag.Value]
            if not fd or fd.team == tm then return end

            -- Award 1 point to the player’s personal leaderstats.Score
            local ls = pl:FindFirstChild("leaderstats")
            if ls and ls:FindFirstChild("Score") then
                ls.Score.Value += 1
            end

            -- ── Bump the team‐score in ReplicatedStorage.TeamScores ──
            if tm == "Blue" then
                -- Note: if your Luau version is old, replace “+= 1” with “= … + 1”
                BlueScoreValue.Value = BlueScoreValue.Value + 1
            elseif tm == "Red" then
                RedScoreValue.Value = RedScoreValue.Value + 1
            end

            -- Remove the flag instance & tag, then respawn
            local carriedModel = ch:FindFirstChild(tag.Value)
            if carriedModel then
                carriedModel:Destroy()
            end
            tag:Destroy()
            returnFlagToSpawn(tag.Value)
        end)
    end
end
