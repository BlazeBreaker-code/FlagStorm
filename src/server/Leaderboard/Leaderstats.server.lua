local Players = game:GetService("Players")

Players.PlayerAdded:Connect(function(player)
    -- Create leaderstats folder:
    local statsFolder = Instance.new("Folder")
    statsFolder.Name = "leaderstats"
    statsFolder.Parent = player

    -- Create “Score” IntValue:
    local scoreValue = Instance.new("IntValue")
    scoreValue.Name = "Score"
    scoreValue.Value = 0
    scoreValue.Parent = statsFolder

    -- ── NEW: Stamina as a NumberValue ──
    local staminaValue = Instance.new("NumberValue")
    staminaValue.Name = "Stamina"
    staminaValue.Value = 100   -- start at 100%
    staminaValue.Parent = player  -- *not* under leaderstats; up to you
end)
