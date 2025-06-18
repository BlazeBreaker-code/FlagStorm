-- FlagSystem.lua

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

local DESPAWN_TIME  = 6
local PICKUP_DELAY  = 3

type FlagData = {
	model:           Model,
	template:        Model,
	homeCFrame:      CFrame,
	team:            string,
	state:           string,
	timer:           thread?,
	holder:          Model?,
	flagHB:          Part?,
	touchConnection: RBXScriptConnection?,
	carrierHB:       Part?,
	weld:            Weld?
}

local FlagSystem = {}
local flagStates = {} :: { [string]: FlagData }
local recentlyScored = {}

local function getPlayerFromPart(part)
	local model = part:FindFirstAncestorOfClass("Model")
	if not model or not model:FindFirstChildOfClass("Humanoid") then return nil end
	local player = Players:GetPlayerFromCharacter(model)
	if not player then return nil end
	local teamName = player.Team and player.Team.Name or nil
	return player, model, teamName
end

local function getNPCFromPart(part)
	local model = part:FindFirstAncestorOfClass("Model")
	if not model then return nil, nil end
	local teamTag = model:FindFirstChild("Team")
	if not teamTag or not model:FindFirstChildOfClass("Humanoid") then return nil, nil end
	return model, teamTag.Value
end

local function setAllParts(model, anchored, canCollide)
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored = anchored
			p.CanCollide = canCollide
		end
	end
end

local function createCarrierHitbox(charModel)
	local hrp = charModel:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end

	local hb = Instance.new("Part")
	hb.Name = "CarrierHitbox"
	hb.Size = Vector3.new(4, 5, 4)
	hb.Transparency = 1
	hb.CanCollide = false
	hb.CanTouch = true
	hb.Anchored = false
	hb.Parent = charModel
	hb.CFrame = hrp.CFrame

	local weld = Instance.new("WeldConstraint", hb)
	weld.Part0, weld.Part1 = hrp, hb

	return hb
end

local function clearFlagData(data)
	if data.model then data.model:Destroy(); data.model = nil end
	if data.touchConnection then data.touchConnection:Disconnect(); data.touchConnection = nil end
	if data.carrierHB then data.carrierHB:Destroy(); data.carrierHB = nil end
	data.flagHB = nil
	if data.timer and typeof(data.timer) == "thread" then
		pcall(function() task.cancel(data.timer) end)
		data.timer = nil
	end
	data.holder = nil
	data.weld = nil
end

local function setupSpawnHitbox(data, flagName)
	local hb = data.model:FindFirstChild("TouchHitbox", true)
	if not hb then warn("[FlagSystem] No TouchHitbox found for " .. flagName); return end
	data.flagHB = hb
	hb.CanTouch = true

	data.touchConnection = hb.Touched:Connect(function(hitPart)
		local pl, ch, tm = getPlayerFromPart(hitPart)
		if pl and data.state == STATE_SPAWN and tm ~= data.team then
			grabFlag(ch, flagName)
			return
		end

		local npcModel, npcTeam = getNPCFromPart(hitPart)
		if npcModel and data.state == STATE_SPAWN and npcTeam ~= data.team then
			grabFlag(npcModel, flagName)
			return
		end
	end)
end

local function setupDropHitbox(data, flagName)
	local hb = data.flagHB
	if not hb then return end

	hb.CanTouch = false
	if data.touchConnection then data.touchConnection:Disconnect(); data.touchConnection = nil end

	data.touchConnection = hb.Touched:Connect(function(hitPart)
		local pl, ch, tm = getPlayerFromPart(hitPart)
		if pl and data.state == STATE_FREE then
			if tm == data.team then
				FlagSystem.returnFlagToSpawn(flagName)
			else
				grabFlag(ch, flagName)
			end
			return
		end

		local npcModel, npcTeam = getNPCFromPart(hitPart)
		if npcModel and data.state == STATE_FREE then
			if npcTeam == data.team then
				FlagSystem.returnFlagToSpawn(flagName)
			else
				grabFlag(npcModel, flagName)
			end
			return
		end
	end)

	task.delay(PICKUP_DELAY, function()
		if hb and hb.Parent then
			hb.CanTouch = true
		end
	end)
end

function FlagSystem.returnFlagToSpawn(flagName)
	local data = flagStates[flagName]
	if not data then return end

	clearFlagData(data)

	local f = data.template:Clone()
	f.Parent = flagsFolder
	f:SetPrimaryPartCFrame(data.homeCFrame)
	setAllParts(f, true, true)

	data.model = f
	data.state = STATE_SPAWN
	setupSpawnHitbox(data, flagName)
end

function grabFlag(carrierModel, flagName)
	local data = flagStates[flagName]
	if not data then return end

	if data.timer and typeof(data.timer) == "thread" then
		pcall(function() task.cancel(data.timer) end)
		data.timer = nil
	end

	if data.touchConnection then data.touchConnection:Disconnect(); data.touchConnection = nil end
	if data.flagHB then data.flagHB.CanTouch = false end
	setAllParts(data.model, false, false)

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

	local tag = Instance.new("StringValue", carrierModel)
	tag.Name = "CarryingFlag"
	tag.Value = flagName

	local carrierHB = createCarrierHitbox(carrierModel)
	if carrierHB then
		data.carrierHB = carrierHB
		carrierHB.Touched:Connect(function(hitPart)
			onFlagHitboxTouched(carrierHB, hitPart)
		end)
	end
end

function onFlagHitboxTouched(hitbox, part)
	local thief, thiefChar, thiefTeam = getPlayerFromPart(part)
	if not thief then
		thiefChar, thiefTeam = getNPCFromPart(part)
	end
	if not thiefChar then return end

	local carrierChar = hitbox.Parent
	if not carrierChar then return end
	if thiefChar == carrierChar then return end

	local tag = carrierChar:FindFirstChild("CarryingFlag")
	if not tag then return end

	local data = flagStates[tag.Value]
	if not data then return end

	if thiefTeam == data.team then
		local flagName = tag.Value

		data.state = STATE_FREE
		data.holder = nil
		tag:Destroy()

		if data.weld then data.weld:Destroy(); data.weld = nil end

		data.model.Parent = flagsFolder
		local dropPos = hitbox.Position - Vector3.new(0, 2, 0)
		data.model:SetPrimaryPartCFrame(CFrame.new(dropPos))
		setAllParts(data.model, false, true)

		hitbox:Destroy()
		data.carrierHB = nil

		if data.flagHB then
			setupDropHitbox(data, flagName)
		end

		data.timer = task.delay(DESPAWN_TIME, function()
			if data.state == STATE_FREE then
				FlagSystem.returnFlagToSpawn(flagName)
			end
		end)
	end
end

for _, f in ipairs(flagsFolder:GetChildren()) do
	if f:IsA("Model") then
		local nm = f.Name
		flagStates[nm] = {
			model           = f,
			template        = f:Clone(),
			homeCFrame      = f:GetPrimaryPartCFrame(),
			team            = nm:gsub("Flag", ""),
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
	FlagSystem.returnFlagToSpawn(nm)
end

for _, base in ipairs(basesFolder:GetChildren()) do
	if base:IsA("BasePart") then
		base.Touched:Connect(function(part)
			local pl, ch, tm = getPlayerFromPart(part)
			if not pl then return end

			if recentlyScored[pl.UserId] then return end
			recentlyScored[pl.UserId] = true
			task.delay(0.5, function() recentlyScored[pl.UserId] = nil end)

			if base.Name ~= tm .. "Base" then return end

			local tag = ch:FindFirstChild("CarryingFlag")
			if not tag then return end

			local fd = flagStates[tag.Value]
			if not fd or fd.team == tm then return end

			local ls = pl:FindFirstChild("leaderstats")
			if ls and ls:FindFirstChild("Score") then
				ls.Score.Value += 1
			end

			if tm == "Blue" then
				BlueScoreValue.Value += 1
			elseif tm == "Red" then
				RedScoreValue.Value += 1
			end

			local carriedModel = ch:FindFirstChild(tag.Value)
			if carriedModel then carriedModel:Destroy() end
			tag:Destroy()
			FlagSystem.returnFlagToSpawn(tag.Value)
		end)
	end
end

return FlagSystem
