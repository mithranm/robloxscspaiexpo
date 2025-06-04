-- src/server/init.server.luau
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

Players.CharacterAutoLoads = false -- Disable default character loading

local Remotes = require(ReplicatedStorage.Shared.Remotes) 
local RoSocketServiceHandler = require(ServerScriptService.Server.RoSocketServiceHandler) 
local WorldBuilderServer = require(ServerScriptService.Server.WorldBuilderServer) -- NEW

-- Initialize world state from Gazebo orchestrator first
WorldBuilderServer:InitializeWorldState()

-- Then initialize RoSocket connection
RoSocketServiceHandler:Init()

print("Server init.server.luau: WorldBuilderServer and RoSocketServiceHandler Initialized.")

local function SetupPlayer(player)
	print("Server: SetupPlayer called for", player.Name)
	-- Try to get the fetched template first, then the default fallback
	local droneTemplate = ServerStorage.DroneModelsStorage:FindFirstChild("GazeboDroneTemplate_Fetched") 
	if not droneTemplate then
		droneTemplate = ServerStorage.DroneModelsStorage:FindFirstChild("GazeboDroneTemplate_Default")
	end
	
	if droneTemplate then
		local playerDrone = droneTemplate:Clone()
		playerDrone.Name = "PlayerDrone_" .. player.Name
		
		-- Set PrimaryPart CFrame for spawning
		local spawnLocations = Workspace:GetChildren(); local chosenSpawn = nil
        for _,c in ipairs(spawnLocations) do if c:IsA("SpawnLocation") and not c.Neutral then chosenSpawn=c; break; end end
        if not chosenSpawn and #spawnLocations > 0 then for _,c in ipairs(spawnLocations) do if c:IsA("SpawnLocation") then chosenSpawn=c; break; end end end
        if chosenSpawn then playerDrone:SetPrimaryPartCFrame(chosenSpawn.CFrame + Vector3.new(0,3,0))
        else playerDrone:SetPrimaryPartCFrame(CFrame.new(math.random(-20,20), 5, math.random(-20,20))) end
        playerDrone.Parent = Workspace
		print("Server: PlayerDrone '"..playerDrone.Name.."' parented to Workspace.")

		-- Assign network ownership to the client for physics control
		if playerDrone.PrimaryPart then
			playerDrone.PrimaryPart:SetNetworkOwner(player)
			for _,cP in ipairs(playerDrone:GetDescendants()) do if cP:IsA("BasePart") then cP:SetNetworkOwner(player) end end
		end
		
		local gzTag = Instance.new("StringValue"); gzTag.Name="GazeboDroneName"; gzTag.Value="drone_p"..player.UserId; gzTag.Parent=playerDrone
		print("Server: Spawned drone", playerDrone.Name, "for", player.Name, "using template:", droneTemplate.Name)
	else
		warn("Server: CRITICAL - No drone template found! Cannot spawn drone for player:", player.Name)
	end
end

Players.PlayerAdded:Connect(SetupPlayer)

Players.PlayerRemoving:Connect(function(player)
	local playerDrone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)
	if playerDrone then
		playerDrone:Destroy()
		print("Server: Cleaned up drone for player", player.Name)
	end
	
	RoSocketServiceHandler:PlayerRemoved(player) -- Inform handler if it needs to clean up player-specific data
end)

-- Handle players already in game when script runs (e.g. after hot-reload)
for _, player in ipairs(Players:GetPlayers()) do
	if not Workspace:FindFirstChild("PlayerDrone_" .. player.Name) then
		print("Server: Setting up existing player:", player.Name)
		SetupPlayer(player)
	end
end