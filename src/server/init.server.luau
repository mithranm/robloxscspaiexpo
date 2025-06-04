-- src/server/init.server.luau
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

Workspace.Gravity = 0
print("Server: Workspace.Gravity set to 0.")
Players.CharacterAutoLoads = false

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local RoSocketServiceHandler = require(ServerScriptService.Server.RoSocketServiceHandler)
local WorldBuilderServer = require(ServerScriptService.Server.WorldBuilderServer)

local function SetupPlayer(player)
	print("Server: SetupPlayer for", player.Name)
	player.DevComputerMovementMode = Enum.DevComputerMovementMode.Scriptable
	player.DevTouchMovementMode = Enum.DevTouchMovementMode.Scriptable

	local droneTemplateToUse = ServerStorage.DroneModelsStorage:FindFirstChild("GazeboDroneTemplate_Fetched")
		or ServerStorage.DroneModelsStorage:FindFirstChild("GazeboDroneTemplate_Default")

	if droneTemplateToUse then
		print("Server: Using template", droneTemplateToUse.Name, "for player", player.Name)
		local playerDrone = droneTemplateToUse:Clone()
		playerDrone.Name = "PlayerDrone_" .. player.Name

		local bodyPart = playerDrone:FindFirstChild("Body") or playerDrone.PrimaryPart
		if bodyPart then bodyPart.CanCollide = true end

		local spawnCFrame
		local chosenSpawn = Workspace:FindFirstChildOfClass("SpawnLocation") -- Simplified spawn selection
		if chosenSpawn then
			spawnCFrame = chosenSpawn.CFrame + Vector3.new(0, 5, 0)
		else
			spawnCFrame = CFrame.new(math.random(-50,50), 10, math.random(-50,50))
		end
		playerDrone:SetPrimaryPartCFrame(spawnCFrame)
		playerDrone.Parent = Workspace

		-- CORRECTED Network Ownership: Iterate through BaseParts
		for _, part in ipairs(playerDrone:GetDescendants()) do
			if part:IsA("BasePart") then
				part:SetNetworkOwner(nil) -- Server owns all parts
			end
		end
		print("Server: Network ownership of all parts in", playerDrone.Name, "set to SERVER.")

		local gzTag = Instance.new("StringValue"); gzTag.Name="GazeboDroneName"; gzTag.Value="drone_p"..player.UserId; gzTag.Parent=playerDrone
		print("Server: Spawned drone", playerDrone.Name)
	else
		warn("Server: CRITICAL - No drone template found for player:", player.Name)
	end
end

WorldBuilderServer:InitializeWorldState()
RoSocketServiceHandler:Init()
print("Server: Init complete.")

Players.PlayerAdded:Connect(SetupPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	if not Workspace:FindFirstChild("PlayerDrone_" .. player.Name) then
		SetupPlayer(player)
	else
        local existingDrone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)
        if existingDrone then
            local changedOwnership = false
            for _, part in ipairs(existingDrone:GetDescendants()) do
                if part:IsA("BasePart") and part:GetNetworkOwner() ~= nil then
                    part:SetNetworkOwner(nil)
                    changedOwnership = true
                end
            end
            if changedOwnership then print("Server: Corrected network ownership for existing drone of", player.Name) end
        end
	end
end

Players.PlayerRemoving:Connect(function(player)
	local playerDrone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)
	if playerDrone then playerDrone:Destroy() end
	RoSocketServiceHandler:PlayerRemoved(player)
	print("Server: Cleaned up for player", player.Name)
end)