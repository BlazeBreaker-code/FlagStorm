local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local player        = Players.LocalPlayer
local character     = nil
local humanoid      = nil
local rootPart      = nil

-- Configuration
local WALK_SPEED            = 16      -- normal walking speed
local SPRINT_SPEED          = 24      -- sprinting speed
local MAX_STAMINA           = 100     -- max stamina
local DRAIN_RATE            = 20      -- points/sec drained while sprinting
local REGEN_RATE            = 15      -- points/sec regained when not sprinting
local MIN_STAMINA_TO_SPRINT = 5       -- minimum to allow sprint

-- References to UI
local playerGui  = player:WaitForChild("PlayerGui")
local staminaGui = playerGui:WaitForChild("StaminaGui")
local barFrame   = staminaGui:WaitForChild("BarFrame")
local fillFrame  = barFrame:WaitForChild("Fill")

-- Capture the “designer” color you set in Studio as the “full” color.
-- (In Studio, make sure Fill.BackgroundColor3 is your preferred light‑cyan.)
local fullColor = fillFrame.BackgroundColor3
local lowColor  = Color3.new(1, 0, 0)  -- red when low

-- Reference to the Stamina NumberValue under the player
local staminaValue = player:WaitForChild("Stamina")

-- State flags
local isSprinting   = false
local sprintKeyDown = false

-- Clamp utility
local function clamp(val)
    if val < 0 then return 0 end
    if val > MAX_STAMINA then return MAX_STAMINA end
    return val
end

-- Update the UI bar based on current stamina
local function updateBar()
    local percent = staminaValue.Value / MAX_STAMINA
    fillFrame.Size = UDim2.new(percent, 0, 1, 0)

    -- Use the original “fullColor” if above 25%, otherwise switch to red
    if percent < 0.25 then
        fillFrame.BackgroundColor3 = lowColor
    else
        fillFrame.BackgroundColor3 = fullColor
    end
end

-- Stop sprinting (reset speed)
local function stopSprint()
    if humanoid then
        humanoid.WalkSpeed = WALK_SPEED
    end
    isSprinting = false
end

-- Input handlers for Shift
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.LeftShift then
        sprintKeyDown = true
    end
end)
UserInputService.InputEnded:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.LeftShift then
        sprintKeyDown = false
        stopSprint()
    end
end)

-- Each frame, handle sprint logic and stamina
RunService.RenderStepped:Connect(function(deltaTime)
    -- Ensure character/humanoid refs exist
    if not character or not humanoid or not rootPart then
        character = player.Character
        if character then
            humanoid = character:FindFirstChildOfClass("Humanoid")
            rootPart = character:FindFirstChild("HumanoidRootPart")
            if humanoid then
                humanoid.WalkSpeed = WALK_SPEED
            end
        end
        return
    end

    local canSprint = sprintKeyDown
                      and humanoid.Health > 0
                      and staminaValue.Value > MIN_STAMINA_TO_SPRINT

    if canSprint then
        if not isSprinting then
            humanoid.WalkSpeed = SPRINT_SPEED
            isSprinting = true
        end

        staminaValue.Value = clamp(staminaValue.Value - DRAIN_RATE * deltaTime)
        if staminaValue.Value <= 0 then
            staminaValue.Value = 0
            stopSprint()
        end
    else
        -- Regenerate stamina when not sprinting
        if staminaValue.Value < MAX_STAMINA then
            staminaValue.Value = clamp(staminaValue.Value + REGEN_RATE * deltaTime)
        end
        if isSprinting then
            stopSprint()
        end
    end

    updateBar()
end)

-- Re‑hook references when character spawns
player.CharacterAdded:Connect(function(char)
    character = char
    humanoid  = nil
    rootPart  = nil

    humanoid = char:WaitForChild("Humanoid")
    rootPart = char:WaitForChild("HumanoidRootPart")
    humanoid.WalkSpeed = WALK_SPEED
end)

-- Initial hook if character already exists
if player.Character then
    humanoid = player.Character:FindFirstChildOfClass("Humanoid")
    rootPart = player.Character:FindFirstChild("HumanoidRootPart")
    if humanoid then
        humanoid.WalkSpeed = WALK_SPEED
    end
end
