-- FlagSystem.lua
-- Server‐side script for handling flag spawn, pickup, drop, and capture

local Players        = game:GetService("Players")
local Replicated     = game:GetService("ReplicatedStorage")
local Workspace      = game:GetService("Workspace")

-- Configuration (folder paths)
local flagsFolder    = Workspace:WaitForChild("Flags")
local basesFolder    = Workspace:WaitForChild("Bases")
local TeamScores     = Replicated:WaitForChild("TeamScores")
local BlueScoreValue = TeamScores:WaitForChild("BlueScore")
local RedScoreValue  = TeamScores:WaitForChild("RedScore")

-- Constants
local STATE_SPAWN   = "Spawn"
local STATE_IN_PLAY = "InPlay"
local STATE_FREE    = "Free"

local DESPAWN_TIME  = 6   -- seconds before auto‐return
local PICKUP_DELAY  = 3   -- seconds before a dropped flag can be re‐picked

-- Data container for each flag
type FlagData = {
	model:           Model,
	template:        Model,
	homeCFrame:      CFrame,
	team:            string,
	state:           string,
	timer:           thread?,
	holder:          Model?,        -- can be Player.Character or NPC Model
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

-- Given a BasePart, return (player, characterModel, teamString) if it’s a player's limb
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

-- Given a BasePart, return (npcModel, teamString) if it’s an NPC (StringValue "Team") carrying a flag
local function getNPCFromPart(part)
	local model = part:FindFirstAncestorOfClass("Model")
	if not model then return nil, nil end
	local teamTag = model:FindFirstChild("Team")
	if not teamTag or not model:FindFirstChildOfClass("Humanoid") then
		return nil, nil
	end
	return model, teamTag.Value
end

-- Make every BasePart descendant of a given Model anchored/collidable or not
local function setAllParts(model, anchored, canCollide)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored   = anchored
			p.CanCollide = canCollide
		end
	end
end

-- Weld a tiny invisible hitbox underneath a character or NPC so we can detect “steals”
local function createCarrierHitbox(charModel)
	local hrp = charModel:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	local hb = Instance.new("Part")
	hb.Name         = "CarrierHitbox"
	hb.Size         = Vector3.new(4, 5, 4)
	hb.Transparency = 1
	hb.CanCollide   = false
	hb.CanTouch     = true
	hb.Anchored     = false
	hb.Parent       = charModel
	hb.CFrame       = hrp.CFrame

	local weld = Instance.new("WeldConstraint", hb)
	weld.Part0, weld.Part1 = hrp, hb

	return hb
end

-- Tear down everything for a given FlagData before respawning:
--   • Destroy the old model
--   • Disconnect its .Touched listener
--   • Destroy any existing carrier hitbox
--   • Cancel any active timer
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
-- After cloning a fresh flag, find its invisible TouchHitbox,
-- enable CanTouch, and connect .Touched → grabFlag.
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

local function setupSpawnHitbox(data, flagName)
	local hb = data.model:FindFirstChild("TouchHitbox", true)
	if not hb then
		warn("[FlagSystem] No TouchHitbox found inside model “" .. flagName .. "”")
		return
	end

	data.flagHB = hb
	hb.CanTouch = true

	data.touchConnection = hb.Touched:Connect(function(hitPart)
		-- First check if a player touched
		local pl, ch, tm = getPlayerFromPart(hitPart)
		if pl and data.state == STATE_SPAWN and tm ~= data.team then
			grabFlag(ch, flagName)  -- pass character model and flagName
			return
		end

		-- Else, check if an NPC touched
		local npcModel, npcTeam = getNPCFromPart(hitPart)
		if npcModel and data.state == STATE_SPAWN and npcTeam ~= data.team then
			grabFlag(npcModel, flagName)  -- pass NPC model and flagName
			return
		end
	end)
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- Hitbox setup for “Free” (dropped) state
-- Once a flag is dropped, re‐enable its TouchHitbox after PICKUP_DELAY,
-- so someone can pick it up again.
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

local function setupDropHitbox(data, flagName)
	local hb = data.flagHB
	if not hb then return end

	-- Immediately disable CanTouch and disconnect previous listener
	hb.CanTouch = false
	if data.touchConnection then
		data.touchConnection:Disconnect()
		data.touchConnection = nil
	end

	data.touchConnection = hb.Touched:Connect(function(hitPart)
		-- Player pickup?
		local pl, ch, tm = getPlayerFromPart(hitPart)
		if pl and data.state == STATE_FREE then
			if tm == data.team then
				returnFlagToSpawn(flagName)
			else
				grabFlag(ch, flagName)
			end
			return
		end

		-- NPC pickup?
		local npcModel, npcTeam = getNPCFromPart(hitPart)
		if npcModel and data.state == STATE_FREE then
			if npcTeam == data.team then
				returnFlagToSpawn(flagName)
			else
				grabFlag(npcModel, flagName)
			end
			return
		end
	end)

	-- After PICKUP_DELAY, re‐enable CanTouch so it can be grabbed
	task.delay(PICKUP_DELAY, function()
		if hb and hb.Parent then
			hb.CanTouch = true
		end
	end)
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- Return a flag to its spawn point:
--   1) Clean up old model/listeners
--   2) Clone fresh template
--   3) Anchor + collidable on all parts
--   4) Hook its Spawn hitbox for pickup
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

	-- 4) Hook its TouchHitbox for spawn pickup
	setupSpawnHitbox(data, flagName)
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- When a player OR NPC grabs a flag:
--   1) Cancel any auto‐return timer
--   2) Disconnect spawn hitbox listener
--   3) Disable that TouchHitbox so it can’t fire again now
--   4) Unanchor + disable collisions on the flag model
--   5) Weld the flag to the carrier’s HumanoidRootPart
--   6) Create a “carrierHB” under carrier for steals
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

function grabFlag(carrierModel, flagName)
	local data = flagStates[flagName]
	if not data then return end

	-- 1) Cancel any existing timer
	if data.timer then
		task.cancel(data.timer)
		data.timer = nil
	end

	-- 2) Disconnect spawn hitbox listener
	if data.touchConnection then
		data.touchConnection:Disconnect()
		data.touchConnection = nil
	end

	-- 3) Disable the TouchHitbox so it won’t fire during carry
	if data.flagHB then
		data.flagHB.CanTouch = false
	end

	-- 4) Unanchor + disable collisions on every BasePart of the flag
	setAllParts(data.model, false, false)

	-- 5) Position & weld under carrier’s HumanoidRootPart
	local hrp = carrierModel:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	data.model:SetPrimaryPartCFrame(hrp.CFrame * CFrame.new(0, 5, 0))
	local w = Instance.new("Weld", hrp)
	w.Part0, w.Part1 = hrp, data.model.PrimaryPart
	w.C0 = CFrame.new(0, 5, 0)

	data.model.Parent = carrierModel
	data.weld = w
	data.state = STATE_IN_PLAY
	data.holder = carrierModel

	-- Tag the carrier (player or NPC) so we know who’s carrying
	local tag = Instance.new("StringValue", carrierModel)
	tag.Name  = "CarryingFlag"
	tag.Value = flagName

	-- 6) Create a small invisible “steal detection” hitbox under carrier
	local carrierHB = createCarrierHitbox(carrierModel)
	if carrierHB then
		data.carrierHB = carrierHB
		carrierHB.Touched:Connect(function(hitPart)
			onFlagHitboxTouched(carrierHB, hitPart)
		end)
	end
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- When someone touches a carrier’s hitbox:
--   1) Verify toucher is an enemy (player or NPC)
--   2) Drop the flag at that position
--   3) Re‐enable its TouchHitbox for Free pickup after delay
--   4) Start auto‐return timer if it remains dropped too long
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

function onFlagHitboxTouched(hitbox, part)
	-- Identify who touched: player or NPC?
	local thief, thiefChar, thiefTeam = getPlayerFromPart(part)
	if not thief then
		thiefChar, thiefTeam = getNPCFromPart(part)
	end
	if not thiefChar then return end

	local carrierChar = hitbox.Parent
	-- If same carrier touches own hitbox, ignore
	if thiefChar == carrierChar then return end

	local tag = carrierChar:FindFirstChild("CarryingFlag")
	if not tag then return end

	local data = flagStates[tag.Value]
	if not data then return end

	-- Only allow enemy to steal
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

		-- 2) Drop the model into the world
		data.model.Parent = flagsFolder
		local dropPos = hitbox.Position - Vector3.new(0, 2, 0)
		data.model:SetPrimaryPartCFrame(CFrame.new(dropPos))
		setAllParts(data.model, false, true)  -- unanchor + enable collisions

		-- Remove the carrier’s hitbox
		hitbox:Destroy()
		data.carrierHB = nil

		-- 3) Re‐enable the TouchHitbox after PICKUP_DELAY
		if data.flagHB then
			setupDropHitbox(data, flagName)
		end

		-- 4) Auto‐return if still dropped after DESPAWN_TIME
		data.timer = task.delay(DESPAWN_TIME, function()
			if data.state == STATE_FREE then
				returnFlagToSpawn(flagName)
			end
		end)
	end
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- Initialization: run once when server script starts
-- 1) Build flagStates table
-- 2) Immediately return each flag to its spawn
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

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

for nm in pairs(flagStates) do
	returnFlagToSpawn(nm)
end



--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
-- Base‐capture logic: when a “carrying” player touches their own base:
--   • Award 1 point to their personal leaderstats.Score 
--   • Bump the team‐score in ReplicatedStorage.TeamScores
--   • Remove the flag instance from their model
--   • Return it to spawn
--––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––

for _, base in ipairs(basesFolder:GetChildren()) do
	if base:IsA("BasePart") then
		base.Touched:Connect(function(part)
			local pl, ch, tm = getPlayerFromPart(part)
			if not pl then return end

			-- Debounce so only one touch registers
			if recentlyScored[pl.UserId] then return end
			recentlyScored[pl.UserId] = true
			task.delay(0.5, function()
				recentlyScored[pl.UserId] = nil
			end)

			-- Only allow capture if base matches player’s team
			if base.Name ~= tm .. "Base" then return end

			local tag = ch:FindFirstChild("CarryingFlag")
			if not tag then return end

			local fd = flagStates[tag.Value]
			if not fd or fd.team == tm then return end

			-- Award 1 point to the player’s leaderstats.Score
			local ls = pl:FindFirstChild("leaderstats")
			if ls and ls:FindFirstChild("Score") then
				ls.Score.Value += 1
			end

			-- Bump the team‐score
			if tm == "Blue" then
				BlueScoreValue.Value = BlueScoreValue.Value + 1
			elseif tm == "Red" then
				RedScoreValue.Value = RedScoreValue.Value + 1
			end

			-- Remove the flag model and tag, then respawn
			local carriedModel = ch:FindFirstChild(tag.Value)
			if carriedModel then
				carriedModel:Destroy()
			end
			tag:Destroy()
			returnFlagToSpawn(tag.Value)
		end)
	end
end
