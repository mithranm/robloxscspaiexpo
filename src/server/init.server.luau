-- src/server/init.server.luau
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

Workspace.Gravity = 0 -- Set workspace gravity to 0 for custom gravity implementation
print("Server: Workspace.Gravity set to 0 for custom gravity implementation.")

Players.CharacterAutoLoads = false -- Disable default character loading

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local RoSocketServiceHandler = require(ServerScriptService.Server.RoSocketServiceHandler)
local WorldBuilderServer = require(ServerScriptService.Server.WorldBuilderServer)

local function SetupPlayer(player)
	print("Server: SetupPlayer called for", player.Name)

	player.DevComputerMovementMode = Enum.DevComputerMovementMode.Scriptable
	player.DevTouchMovementMode = Enum.DevTouchMovementMode.Scriptable
	print("Server: Set DevComputerMovementMode and DevTouchMovementMode to Scriptable for", player.Name)

	local droneTemplateToUse = ServerStorage.DroneModelsStorage:FindFirstChild("GazeboDroneTemplate_Fetched")
	if not droneTemplateToUse then
		droneTemplateToUse = ServerStorage.DroneModelsStorage:FindFirstChild("GazeboDroneTemplate_Default")
		if droneTemplateToUse then
			print("Server: Using GazeboDroneTemplate_Default for player", player.Name)
		end
	else
		print("Server: Using GazeboDroneTemplate_Fetched for player", player.Name)
	end

	if droneTemplateToUse then
		local playerDrone = droneTemplateToUse:Clone()
		playerDrone.Name = "PlayerDrone_" .. player.Name

		-- Ensure the drone body can collide (important for server physics + ground)
		local bodyPart = playerDrone:FindFirstChild("Body") or playerDrone.PrimaryPart
		if bodyPart then
			bodyPart.CanCollide = true
			print("Server: Ensured CanCollide is true for drone body:", bodyPart.Name)
		else
			warn("Server: Could not find body part for drone", playerDrone.Name, "to set CanCollide.")
		end


		local spawnLocations = Workspace:GetChildren()
		local chosenSpawn = nil
		for _,c in ipairs(spawnLocations) do
			if c:IsA("SpawnLocation") and not c.Neutral and c.Enabled then chosenSpawn=c; break; end
		end
		if not chosenSpawn then
			for _,c in ipairs(spawnLocations) do
				if c:IsA("SpawnLocation") and c.Enabled then chosenSpawn=c; break; end
			end
		end

		local spawnCFrame
		if chosenSpawn then
			spawnCFrame = chosenSpawn.CFrame + Vector3.new(0, 20, 0)
			print("Server: Spawning drone for", player.Name, "at SpawnLocation:", chosenSpawn.Name, "at CFrame:", spawnCFrame)
		else
			local randomX = math.random(-50,50)
			local randomZ = math.random(-50,50)
			spawnCFrame = CFrame.new(randomX, 25, randomZ)
			print("Server: No SpawnLocation found. Spawning drone for", player.Name, "at random CFrame:", spawnCFrame)
		end

		playerDrone:SetPrimaryPartCFrame(spawnCFrame)

		print("Server (PRE-PARENT): Clone '" .. playerDrone.Name .. "' PrimaryPart:", playerDrone.PrimaryPart, "Body child:", playerDrone:FindFirstChild("Body"), "CFRAME:", playerDrone:GetPrimaryPartCFrame())
		playerDrone.Parent = Workspace
		print("Server (POST-PARENT): Clone '" .. playerDrone.Name .. "' PrimaryPart:", playerDrone.PrimaryPart, "Body child:", playerDrone:FindFirstChild("Body"), "CFRAME:", playerDrone:GetPrimaryPartCFrame())
		print("Server: PlayerDrone '"..playerDrone.Name.."' parented to Workspace.")

		-- For server-side physics, the server should own the parts.
		-- Setting network owner to the player can lead to conflicts if the server is also trying to control physics.
		-- However, for responsiveness, player network ownership is often preferred even with server-calculated forces.
		-- For now, let's explicitly set to server (nil) to be strict with "server-side physics".
		-- If responsiveness suffers, this can be changed back to player.
		if playerDrone.PrimaryPart then
			playerDrone.PrimaryPart:SetNetworkOwner(nil) -- Server (nil) takes ownership
			for _, cP in ipairs(playerDrone:GetDescendants()) do
				if cP:IsA("BasePart") then cP:SetNetworkOwner(nil) end -- Server (nil) takes ownership
			end
			print("Server: Network ownership of", playerDrone.Name, "set to SERVER (nil).")
		else
			warn("Server: PlayerDrone", playerDrone.Name, "has no PrimaryPart. Cannot set network owner.")
		end

		local gzTag = Instance.new("StringValue"); gzTag.Name="GazeboDroneName"; gzTag.Value="drone_p"..player.UserId; gzTag.Parent=playerDrone
		print("Server: Spawned drone", playerDrone.Name, "for", player.Name, "using template:", droneTemplateToUse.Name)
	else
		warn("Server: CRITICAL - No drone template found (neither Fetched nor Default)! Cannot spawn drone for player:", player.Name)
	end
end

print("Server init.server.luau: Initializing WorldBuilderServer and RoSocketServiceHandler...")
WorldBuilderServer:InitializeWorldState()
RoSocketServiceHandler:Init()
print("Server init.server.luau: WorldBuilderServer and RoSocketServiceHandler Initialization complete.")

Players.PlayerAdded:Connect(SetupPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	if not Workspace:FindFirstChild("PlayerDrone_" .. player.Name) then
		print("Server: Setting up existing player:", player.Name)
		SetupPlayer(player)
	else 
		if player.DevComputerMovementMode ~= Enum.DevComputerMovementMode.Scriptable then
			player.DevComputerMovementMode = Enum.DevComputerMovementMode.Scriptable
			print("Server: Corrected DevComputerMovementMode for existing player", player.Name)
		end
		if player.DevTouchMovementMode ~= Enum.DevTouchMovementMode.Scriptable then
			player.DevTouchMovementMode = Enum.DevTouchMovementMode.Scriptable
			print("Server: Corrected DevTouchMovementMode for existing player", player.Name)
		end
        -- Also ensure network ownership is server for existing drones if we want pure server physics
        local existingDrone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)
        if existingDrone and existingDrone.PrimaryPart and existingDrone.PrimaryPart:GetNetworkOwner() ~= nil then
            existingDrone.PrimaryPart:SetNetworkOwner(nil)
            for _, cP in ipairs(existingDrone:GetDescendants()) do
				if cP:IsA("BasePart") then cP:SetNetworkOwner(nil) end
			end
            print("Server: Corrected Network Ownership to SERVER for existing drone of player", player.Name)
        end
	end
end

print("Server init.server.luau: Player setup connections established and existing players processed.")

Players.PlayerRemoving:Connect(function(player)
	local playerDrone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)
	if playerDrone then
		playerDrone:Destroy()
		print("Server: Cleaned up drone for player", player.Name)
	end

	RoSocketServiceHandler:PlayerRemoved(player)
end)