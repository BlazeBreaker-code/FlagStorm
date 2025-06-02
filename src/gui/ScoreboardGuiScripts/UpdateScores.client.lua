local Players          = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

-- Wait for PlayerGui to mount everything from StarterGui
local playerGui      = player:WaitForChild("PlayerGui")

-- Now explicitly fetch the ScreenGui named "ScoreboardGui"
local scoreboardGui  = playerGui:WaitForChild("ScoreboardGui")
local frame          = scoreboardGui:WaitForChild("ScoreBoardFrame")
local blueLabel      = frame:WaitForChild("ScoreBoardBlue"):WaitForChild("ScoreBlue")
local redLabel       = frame:WaitForChild("ScoreBoardRed"):WaitForChild("ScoreRed")

-- Grab the shared team‐score folder in ReplicatedStorage
local TeamScores     = ReplicatedStorage:WaitForChild("TeamScores")

local function refreshScores()
    blueLabel.Text = tostring(TeamScores.BlueScore.Value)
    redLabel.Text  = tostring(TeamScores.RedScore.Value)
end

-- Populate immediately, then listen
refreshScores()
TeamScores.BlueScore.Changed:Connect(refreshScores)
TeamScores.RedScore.Changed:Connect(refreshScores)
