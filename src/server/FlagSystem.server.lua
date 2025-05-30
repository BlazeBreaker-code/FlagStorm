--// Constants
local Players     = game:GetService("Players")
local flagsFolder = workspace:WaitForChild("Flags")
local basesFolder = workspace:WaitForChild("Bases")

local STATE_SPAWN   = "Spawn"   -- waiting in base
local STATE_IN_PLAY = "InPlay"  -- being carried
local STATE_FREE    = "Free"    -- dropped on ground
local DESPAWN_TIME  = 3         -- seconds before auto-return in Free

--// State Tracking
type FlagData = {
	model:           Model,
	homeCFrame:      CFrame,
	team:            string,
	state:           string,
	timer:           thread?,
	holder:          Player?,
	template:        Model,
	touchConnection: RBXScriptConnection?,
	hitbox:          Part?,
	weld:            Weld?
}

local flagStates = {}  :: {[string]: FlagData}
local recentlyScored = {}

-- Utility: get player, character & team from a part
local function getPlayerFromPart(part)
	local model = part:FindFirstAncestorOfClass("Model")
	if not model or not model:FindFirstChildOfClass("Humanoid") then
		return nil, nil, nil
	end
	local player = Players:GetPlayerFromCharacter(model)
	return player, model, player and player.Team and player.Team.Name
end

-- Create an invisible hitbox welded to the carrier
local function createFlagHitbox(char)
	local hb = Instance.new("Part")
	hb.Name         = "FlagHitbox"
	hb.Size         = Vector3.new(4, 5, 4)
	hb.Transparency = 1
	hb.CanCollide   = false
	hb.CanTouch     = true
	hb.Anchored     = false
	hb.Parent       = char
	hb.CFrame       = char.HumanoidRootPart.CFrame

	local wc = Instance.new("WeldConstraint", hb)
	wc.Part0, wc.Part1 = char.HumanoidRootPart, hb

	return hb
end

-- Handle stealing when someone touches the carrier’s hitbox
local function onFlagHitboxTouched(hitbox, part)
	local thief, thiefChar, thiefTeam = getPlayerFromPart(part)
	if not thief then return end

	local carrierChar   = hitbox.Parent
	local carrierPlayer = Players:GetPlayerFromCharacter(carrierChar)
	if carrierPlayer == thief then return end

	local tag = carrierChar:FindFirstChild("CarryingFlag")
	if not tag then return end

	local data = flagStates[tag.Value]
	if not data then return end

	-- only the enemy steals
	if thiefTeam == data.team then
		local flagName = tag.Value

		-- clear carrier state
		data.state  = STATE_FREE
		data.holder = nil
		tag:Destroy()

		-- destroy weld so model unanchors
		if data.weld then
			data.weld:Destroy()
			data.weld = nil
		end

		-- drop into world
		data.model.Parent = flagsFolder
		local dropPos = hitbox.Position - Vector3.new(0, 2, 0)
		data.model:SetPrimaryPartCFrame(CFrame.new(dropPos))
		for _, p in ipairs(data.model:GetDescendants()) do
			if p:IsA("BasePart") then
				p.Anchored   = false
				p.CanCollide = true
			end
		end

		-- remove carrier hitbox
		hitbox:Destroy()
		data.hitbox = nil

		-- setup ground pickup/return
		if data.touchConnection then
			data.touchConnection:Disconnect()
			data.touchConnection = nil
		end

		local groundHB = data.model:FindFirstChild("TouchHitbox", true)
		if groundHB then
			groundHB.CanTouch = true
			data.touchConnection = groundHB.Touched:Connect(function(o)
				local pl, ch, tm = getPlayerFromPart(o)
				if not pl or data.state ~= STATE_FREE then return end
				if tm == data.team then
					-- teammate returns flag home
					returnFlagToSpawn(flagName)
				else
					-- enemy picks it up
					grabFlag(pl, ch, flagName)
				end
			end)
		else
			warn("Couldn't find nested TouchHitbox for", flagName)
		end

		-- auto-return timer
		data.timer = task.delay(DESPAWN_TIME, function()
			if data.state == STATE_FREE then
				returnFlagToSpawn(flagName)
			end
		end)
	end
end

-- Grab the flag (from base or free)
function grabFlag(player, char, flagName)
	local data = flagStates[flagName]
	if not data then return end

	-- cancel free-state timer
	if data.timer then
		task.cancel(data.timer)
		data.timer = nil
	end
	-- remove free-state listener
	if data.touchConnection then
		data.touchConnection:Disconnect()
		data.touchConnection = nil
	end

	-- make parts movable and non-collidable
	for _, p in ipairs(data.model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored   = false
			p.CanCollide = false
		end
	end

	-- weld flag to carrier
	data.model:SetPrimaryPartCFrame(char.HumanoidRootPart.CFrame * CFrame.new(0, 5, 0))
	local w = Instance.new("Weld", char.HumanoidRootPart)
	w.Part0, w.Part1 = char.HumanoidRootPart, data.model.PrimaryPart
	w.C0 = CFrame.new(0, 5, 0)
	data.model.Parent = char

	data.weld = w
	local tag  = Instance.new("StringValue", char)
	tag.Name   = "CarryingFlag"
	tag.Value  = flagName

	data.state  = STATE_IN_PLAY
	data.holder = player

	-- create & weld invisible hitbox
	local hb = createFlagHitbox(char)
	data.hitbox = hb
	hb.Touched:Connect(function(p)
		onFlagHitboxTouched(hb, p)
	end)
end

-- Return flag to spawn base
function returnFlagToSpawn(flagName)
	local data = flagStates[flagName]
	if not data then return end

	-- clean up old instances
	if data.model then
		data.model:Destroy()
	end
	if data.touchConnection then
		data.touchConnection:Disconnect()
		data.touchConnection = nil
	end
	if data.hitbox then
		data.hitbox:Destroy()
		data.hitbox = nil
	end

	-- clone fresh flag template
	local f = data.template:Clone()
	f:SetPrimaryPartCFrame(data.homeCFrame)
	f.Parent = flagsFolder
	for _, p in ipairs(f:GetDescendants()) do
		if p:IsA("BasePart") then
			p.Anchored   = true
			p.CanCollide = true
		end
	end

	local hb = f:FindFirstChild("TouchHitbox", true)
	if hb then
		hb.CanTouch = true
		data.touchConnection = hb.Touched:Connect(function(o)
			local pl, ch, tm = getPlayerFromPart(o)
			if not pl then return end
			if data.state == STATE_SPAWN and tm ~= data.team then
				grabFlag(pl, ch, flagName)
			end
		end)
	end

	data.model          = f
	data.state          = STATE_SPAWN
	data.holder         = nil
	data.weld           = nil
	data.timer          = nil
end

-- Setup flags on server start
for _, f in ipairs(flagsFolder:GetChildren()) do
	local nm = f.Name
	flagStates[nm] = {
		model           = f,
		homeCFrame      = f:GetPrimaryPartCFrame(),
		team            = nm:gsub("Flag", ""),
		state           = STATE_SPAWN,
		template        = f:Clone(),
		timer           = nil,
		holder          = nil,
		touchConnection = nil,
		hitbox          = nil,
		weld            = nil
	}
end

-- Spawn all flags
for nm in pairs(flagStates) do
	returnFlagToSpawn(nm)
end

-- Base capture logic
for _, base in ipairs(basesFolder:GetChildren()) do
	base.Touched:Connect(function(part)
		local pl, ch, tm = getPlayerFromPart(part)
		if not pl then return end

		-- debounce scoring
		if recentlyScored[pl.UserId] then return end
		recentlyScored[pl.UserId] = true
		task.delay(0.5, function()
			recentlyScored[pl.UserId] = nil
		end)

		if base.Name ~= tm .. "Base" then return end

		local tag = ch:FindFirstChild("CarryingFlag")
		if not tag then return end

		local fd = flagStates[tag.Value]
		if not fd or fd.team == tm then return end

		local ls = pl:FindFirstChild("leaderstats")
		if ls and ls:FindFirstChild("Score") then
			ls.Score.Value += 1
		end

		ch:FindFirstChild(tag.Value):Destroy()
		tag:Destroy()
		returnFlagToSpawn(tag.Value)
	end)
end
