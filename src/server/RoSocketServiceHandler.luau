-- src/server/RoSocketServiceHandler.luau
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local RoSocket = require(ServerStorage.RoSocket)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local CustomFlightModel = require(ReplicatedStorage.Shared.DronePhysics.CustomFlightModel)

local RoSocketServiceHandler = {}

local socketConnection = nil
local MAX_RETRIES = 5
local currentRetries = 0
local orchestratorWsUrl = Config.ROSOCKET_CONNECTION_URL

local activePlayersByUserId = {}
local pendingClientRequests = {}
local serverFlightModels = {}
local playerLatestInputs = {}
local playerControlState = {}

local function connectToOrchestrator()
	if socketConnection and socketConnection.readyState == "OPEN" then print("RoSocketServiceHandler: Already connected or connecting."); return end
	if not HttpService.HttpEnabled then warn("RoSocketServiceHandler: HttpService is not enabled! RoSocket will not function."); return	end
	print("RoSocketServiceHandler: Attempting to connect to Orchestrator at:", orchestratorWsUrl); currentRetries += 1
	local successConnect, newSocket = pcall(RoSocket.Connect, RoSocket, orchestratorWsUrl)
	if not successConnect or not newSocket or typeof(newSocket) ~= "table" then
		warn("RoSocketServiceHandler: RoSocket:Connect failed or returned invalid object. Error:", tostring(newSocket)); socketConnection = nil
		if currentRetries < MAX_RETRIES then task.wait(5); connectToOrchestrator() else warn("Max retries for RoSocket connect.") end; return
	end
	socketConnection = newSocket; print("RoSocketServiceHandler: RoSocket Connect called. Socket object received.")
	socketConnection.OnMessageReceived:Connect(RoSocketServiceHandler.OnOrchestratorMessage)
	socketConnection.OnDisconnect:Connect(function()
		print("RoSocketServiceHandler: Disconnected from Orchestrator via RoSocket."); socketConnection = nil
		if currentRetries < MAX_RETRIES then warn("RoSocketServiceHandler: Will attempt to reconnect in 5 seconds..."); task.wait(5); connectToOrchestrator()
		else warn("RoSocketServiceHandler: Max retries reached. Not attempting further reconnections automatically.") end
	end)
	socketConnection.OnErrorReceived:Connect(function(err) warn("RoSocketServiceHandler: Error from RoSocket connection:", err) end)
	currentRetries = 0; print("RoSocketServiceHandler: Handlers set. RoSocket should be attempting to connect/poll.")
end

function RoSocketServiceHandler.OnOrchestratorMessage(message)
	local success, decoded = pcall(HttpService.JSONDecode, HttpService, message)
	if not success then warn("RoSocketServiceHandler: Failed to decode JSON message from orchestrator:", message, decoded); return end
	print("RoSocketServiceHandler: Message from Orchestrator:", decoded.type, decoded.payload and decoded.payload.original_request_id or "N/A")
	local clientRequestInfo; local systemRequestId = decoded.payload and (decoded.payload.system_request_id or decoded.payload.burst_id)
	if systemRequestId then clientRequestInfo = pendingClientRequests[systemRequestId] end
	if not clientRequestInfo and decoded.payload and decoded.payload.roblox_client_id then
		local robloxPlayerUserId = tonumber(decoded.payload.roblox_client_id)
		if robloxPlayerUserId and activePlayersByUserId[robloxPlayerUserId] then
			clientRequestInfo = { player = activePlayersByUserId[robloxPlayerUserId], original_client_request_id = decoded.payload.original_request_id }
			if not decoded.payload.original_request_id then warn("RoSocketServiceHandler: Fallback to roblox_client_id found player, but message missing original_request_id."); clientRequestInfo = nil end
		end
	end
	if not clientRequestInfo then warn("RoSocketServiceHandler: Could not map orchestrator message back to a player/request. SysID:", systemRequestId or "N/A", "OrigID:", (decoded.payload and decoded.payload.original_request_id) or "N/A", "RobloxCID:", (decoded.payload and decoded.payload.roblox_client_id) or "N/A"); return end
	local playerToFire = clientRequestInfo.player
	if not playerToFire or not playerToFire.Parent then warn("RoSocketServiceHandler: Player for request no longer valid or left:", playerToFire and playerToFire.Name or "Unknown"); if systemRequestId then pendingClientRequests[systemRequestId] = nil end; return end
	local messageType = decoded.type; local payload = decoded.payload
	if messageType == "TRICK_PENDING" then
		if payload and payload.system_request_id and clientRequestInfo.original_client_request_id then pendingClientRequests[payload.system_request_id] = { player = playerToFire, original_client_request_id = clientRequestInfo.original_client_request_id }; print("RoSocketServiceHandler: Stored pending request mapping: SysID", payload.system_request_id, "-> ClientOrigID", clientRequestInfo.original_client_request_id)
		else warn("RoSocketServiceHandler: TRICK_PENDING message missing system_request_id or original_request_id in existing info.") end
	elseif messageType == "TRICK_DATA_START" then Remotes.TrickDataStarted:FireClient(playerToFire, payload); playerControlState[playerToFire.UserId] = "TrickMode"; print("RoSocketServiceHandler: Player", playerToFire.Name, "entering TrickMode (server state).")
	elseif messageType == "TRICK_DATA_CHUNK" then Remotes.TrickDataChunk:FireClient(playerToFire, payload)
	elseif messageType == "TRICK_DATA_END" then Remotes.TrickDataEnded:FireClient(playerToFire, payload); if systemRequestId then pendingClientRequests[systemRequestId] = nil end; playerControlState[playerToFire.UserId] = "PlayerControl"; print("RoSocketServiceHandler: Player", playerToFire.Name, "exiting TrickMode, back to PlayerControl (server state).")
	elseif messageType == "TRICK_ERROR" then Remotes.TrickError:FireClient(playerToFire, payload); if systemRequestId then pendingClientRequests[systemRequestId] = nil end; playerControlState[playerToFire.UserId] = "PlayerControl"; warn("RoSocketServiceHandler: Player", playerToFire.Name, "exiting TrickMode due to error, back to PlayerControl (server state). Message:", payload and payload.message or "N/A")
	elseif messageType == "CONFIGURE_DRONE_ACK" then Remotes.ConfigureDroneAck:FireClient(playerToFire, payload); if systemRequestId then pendingClientRequests[systemRequestId] = nil end
	else warn("RoSocketServiceHandler: Received unknown message type from orchestrator:", messageType) end
end

function RoSocketServiceHandler:Init()
	coroutine.wrap(connectToOrchestrator)(); print("RoSocketServiceHandler: Initiated orchestrator connection attempt. Server-side physics ENABLED.")
	local function _setupPlayerFlightModel(player)
		local playerDrone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)
		if playerDrone then
			print("RoSocketServiceHandler: PlayerDrone found for player", player.Name)
			local cfmInstance = CustomFlightModel.new(playerDrone)
			if cfmInstance then
				serverFlightModels[player.UserId] = cfmInstance
				playerLatestInputs[player.UserId] = { throttle = 0, roll = 0, pitch = 0, yaw = 0 }
				playerControlState[player.UserId] = "PlayerControl"
				print("RoSocketServiceHandler: Initialized SERVER-SIDE CustomFlightModel for player", player.Name)
			else warn("RoSocketServiceHandler: Failed to initialize SERVER-SIDE CustomFlightModel for player", player.Name) end
		else warn("RoSocketServiceHandler: Drone for player", player.Name, "not found. SERVER CFM not initialized.") end
	end
	Players.PlayerAdded:Connect(function(player) activePlayersByUserId[player.UserId] = player; print("RoSocketServiceHandler: Player added to active list:", player.Name, player.UserId); _setupPlayerFlightModel(player) end)
	for _, player in ipairs(Players:GetPlayers()) do activePlayersByUserId[player.UserId] = player; _setupPlayerFlightModel(player) end
	Remotes.RequestTrick.OnServerInvoke = function(player, clientPayload)
		if socketConnection and socketConnection.Send then
			print("RoSocketServiceHandler: Forwarding REQUEST_TRICK from Player", player.UserId, "OrigReqID:", clientPayload.original_request_id)
			local serverPayload = {type = "REQUEST_TRICK", payload = { roblox_client_id = tostring(player.UserId), original_request_id = clientPayload.original_request_id, drone_name = clientPayload.drone_name, trick_type = clientPayload.trick_type, direction = clientPayload.direction, initial_state = clientPayload.initial_state }}
			local success, err = pcall(socketConnection.Send, socketConnection, HttpService:JSONEncode(serverPayload))
			if success then return { success = true, message = "Request forwarded to orchestrator." }
			else warn("RoSocketServiceHandler: Error sending RequestTrick:", err); return { success = false, error = "Failed to send request to orchestrator: " .. tostring(err) } end
		else warn("RoSocketServiceHandler: Cannot forward RequestTrick, RoSocket not connected. State:", socketConnection and socketConnection.readyState or "nil"); return { success = false, error = "Not connected to orchestration server." } end
	end
	Remotes.ConfigureDrone.OnServerInvoke = function(player, clientPayload)
		if socketConnection and socketConnection.Send then
			print("RoSocketServiceHandler: Forwarding CONFIGURE_DRONE from Player", player.UserId)
			local serverPayload = {type = "CONFIGURE_DRONE", payload = { roblox_client_id = tostring(player.UserId), original_request_id = clientPayload.original_request_id, drone_params = clientPayload.drone_params}}
			local success, err = pcall(socketConnection.Send, socketConnection, HttpService:JSONEncode(serverPayload))
			if success then return { success = true, message = "Configuration request forwarded." }
			else warn("RoSocketServiceHandler: Error sending ConfigureDrone:", err); return { success = false, error = "Failed to send configuration request: " .. tostring(err) } end
		else warn("RoSocketServiceHandler: Cannot forward ConfigureDrone, RoSocket not connected."); return { success = false, error = "Not connected to orchestration server." } end
	end
	print("RoSocketServiceHandler: OnServerInvoke handlers set up.")
	Remotes.ClientDroneInputs.OnServerEvent:Connect(function(player, inputs)
		if serverFlightModels[player.UserId] and inputs then
			playerLatestInputs[player.UserId] = inputs
            -- SERVER DEBUG: Log received inputs from client
            -- print(string.format("SERVER RoSocket: Received inputs from %s: T:%.2f R:%.2f P:%.2f Y:%.2f",
            --    player.Name, inputs.throttle, inputs.roll, inputs.pitch, inputs.yaw))
		end
	end)
	RunService.Heartbeat:Connect(function(deltaTime)
		for userId, cfmInstance in pairs(serverFlightModels) do
			local player = activePlayersByUserId[userId]
			if not player or not cfmInstance.IsInitialized then continue end
			local currentDrone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)
			if not currentDrone or not currentDrone.PrimaryPart then continue end
			if currentDrone.PrimaryPart.Anchored then if RunService:IsStudio() and math.random() < 0.01 then print("RoSocketServiceHandler: Server Heartbeat - Drone", currentDrone.Name, "is ANCHORED. Skipping physics update.") end; continue end
			
			if playerControlState[userId] == "PlayerControl" then
				local inputs = playerLatestInputs[userId]
				if inputs then
                    -- SERVER DEBUG: Log inputs being USED for CFM:Update
                    -- if inputs.roll ~= 0 or inputs.pitch ~= 0 or inputs.yaw ~= 0 then
                    --    print(string.format("SERVER RoSocket: USING inputs for %s: T:%.2f R:%.2f P:%.2f Y:%.2f",
                    --        player.Name, inputs.throttle, inputs.roll, inputs.pitch, inputs.yaw))
                    -- end
					cfmInstance:Update(deltaTime, inputs.throttle, inputs.roll, inputs.pitch, inputs.yaw)
				else
					cfmInstance:Update(deltaTime, 0, 0, 0, 0)
				end
			elseif playerControlState[userId] == "TrickMode" then
                cfmInstance:Update(deltaTime, 0,0,0,0)
			end
		end
	end)
	print("RoSocketServiceHandler: Server-side physics Heartbeat loop started. Player inputs will drive server CFM.")
end

function RoSocketServiceHandler:PlayerRemoved(player)
	if player and activePlayersByUserId[player.UserId] then
		activePlayersByUserId[player.UserId] = nil; print("RoSocketServiceHandler: Player removed from active list:", player.Name, player.UserId)
		local requestsToClean = {}; for reqId, data in pairs(pendingClientRequests) do if data.player == player then table.insert(requestsToClean, reqId) end end
		for _, reqId in ipairs(requestsToClean) do pendingClientRequests[reqId] = nil; print("RoSocketServiceHandler: Cleaned pending request", reqId, "for removed player", player.Name) end
		local cfmInstance = serverFlightModels[player.UserId]
		if cfmInstance then
			print("RoSocketServiceHandler: Cleaning up server-side CustomFlightModel for removed player", player.Name)
			if typeof(cfmInstance.Cleanup) == "function" then cfmInstance:Cleanup() else warn("RoSocketServiceHandler: CustomFlightModel instance for", player.Name, "does not have a Cleanup method.") end
			serverFlightModels[player.UserId] = nil
		end
		if playerLatestInputs[player.UserId] then playerLatestInputs[player.UserId] = nil; print("RoSocketServiceHandler: Cleaned up latest inputs for removed player", player.Name) end
		if playerControlState[player.UserId] then playerControlState[player.UserId] = nil; print("RoSocketServiceHandler: Cleaned up control state for removed player", player.Name) end
	end
end

return RoSocketServiceHandler