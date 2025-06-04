-- src/server/RoSocketServiceHandler.luau
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local RoSocket = require(ServerStorage.RoSocket)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local RoSocketServiceHandler = {}

local socketConnection = nil
local MAX_RETRIES = 5
local currentRetries = 0
local orchestratorWsUrl = Config.ROSOCKET_CONNECTION_URL -- Using Config value

local activePlayersByUserId = {} -- [userId: number] = Player
local pendingClientRequests = {} -- Key: system_request_id, Value: {player: Player, original_client_request_id: string}

local function connectToOrchestrator()
	if socketConnection and socketConnection.readyState == "OPEN" then
		print("RoSocketServiceHandler: Already connected or connecting.")
		return
	end

	if not HttpService.HttpEnabled then
		warn("RoSocketServiceHandler: HttpService is not enabled! RoSocket will not function.")
		return
	end
	
	print("RoSocketServiceHandler: Attempting to connect to Orchestrator at:", orchestratorWsUrl)
	currentRetries += 1
	
	local successConnect, newSocket = pcall(RoSocket.Connect, RoSocket, orchestratorWsUrl)
	if not successConnect or not newSocket or typeof(newSocket) ~= "table" then
		warn("RoSocketServiceHandler: RoSocket:Connect failed or returned invalid object. Error:", tostring(newSocket))
		socketConnection = nil
		if currentRetries < MAX_RETRIES then task.wait(5); connectToOrchestrator() else warn("Max retries for RoSocket connect.") end
		return
	end
	socketConnection = newSocket
	print("RoSocketServiceHandler: RoSocket Connect called. Socket object received.")

	socketConnection.OnMessageReceived:Connect(RoSocketServiceHandler.OnOrchestratorMessage)
	
	socketConnection.OnDisconnect:Connect(function()
		print("RoSocketServiceHandler: Disconnected from Orchestrator via RoSocket.")
		socketConnection = nil
		if currentRetries < MAX_RETRIES then
			warn("RoSocketServiceHandler: Will attempt to reconnect in 5 seconds...")
			task.wait(5)
			connectToOrchestrator()
		else
			warn("RoSocketServiceHandler: Max retries reached. Not attempting further reconnections automatically.")
		end
	end)

	socketConnection.OnErrorReceived:Connect(function(err)
		warn("RoSocketServiceHandler: Error from RoSocket connection:", err)
		-- RoSocket might disconnect after an error, OnDisconnect will handle retry
	end)
	
	-- Assuming connection is "attempted" if we got a socket object.
	-- RoSocket's internal polling should start trying to get messages.
	-- A true "OPEN" state might only be confirmable by receiving a message or a specific "open" event if RoSocket lib had one.
	currentRetries = 0 -- Reset retries as we have a socket object to work with.
	print("RoSocketServiceHandler: Handlers set. RoSocket should be attempting to connect/poll.")
end

function RoSocketServiceHandler.OnOrchestratorMessage(message)
	local success, decoded = pcall(HttpService.JSONDecode, HttpService, message)
	if not success then
		warn("RoSocketServiceHandler: Failed to decode JSON message from orchestrator:", message, decoded)
		return
	end

	print("RoSocketServiceHandler: Message from Orchestrator:", decoded.type, decoded.payload and decoded.payload.original_request_id or "N/A")

	local clientRequestInfo
	local systemRequestId = decoded.payload and (decoded.payload.system_request_id or decoded.payload.burst_id)
	
	if systemRequestId then
		clientRequestInfo = pendingClientRequests[systemRequestId]
	end
	
	if not clientRequestInfo and decoded.payload and decoded.payload.roblox_client_id then
		local robloxPlayerUserId = tonumber(decoded.payload.roblox_client_id) -- Ensure it's a number
		if robloxPlayerUserId and activePlayersByUserId[robloxPlayerUserId] then
			-- This is a fallback if TRICK_PENDING wasn't caught or systemRequestId changed.
			-- It assumes the original_request_id in the payload is the one we need.
			clientRequestInfo = { 
				player = activePlayersByUserId[robloxPlayerUserId], 
				original_client_request_id = decoded.payload.original_request_id 
			}
			if not decoded.payload.original_request_id then
				warn("RoSocketServiceHandler: Fallback to roblox_client_id found player, but message missing original_request_id. Cannot route accurately for type:", decoded.type)
				clientRequestInfo = nil -- Cannot proceed without original_request_id
			end
		end
	end

	if not clientRequestInfo then
		warn("RoSocketServiceHandler: Could not map orchestrator message back to a player/request. SystemID:", systemRequestId or "N/A", 
			"OriginalID:", (decoded.payload and decoded.payload.original_request_id) or "N/A", 
			"RobloxClientID:", (decoded.payload and decoded.payload.roblox_client_id) or "N/A")
		return
	end

	local playerToFire = clientRequestInfo.player
	if not playerToFire or not playerToFire.Parent then -- Check if player is still valid
		warn("RoSocketServiceHandler: Player for request no longer valid or left:", playerToFire and playerToFire.Name or "Unknown")
		if systemRequestId then pendingClientRequests[systemRequestId] = nil end
		return
	end

	if decoded.type == "TRICK_PENDING" then
		if decoded.payload and decoded.payload.system_request_id and clientRequestInfo.original_client_request_id then
			pendingClientRequests[decoded.payload.system_request_id] = {
				player = playerToFire,
				original_client_request_id = clientRequestInfo.original_client_request_id
			}
			print("RoSocketServiceHandler: Stored pending request mapping: SysID", decoded.payload.system_request_id, "-> ClientOrigID", clientRequestInfo.original_client_request_id)
		else
			warn("RoSocketServiceHandler: TRICK_PENDING message missing system_request_id or original_request_id in existing info. Cannot map.")
		end
	elseif decoded.type == "TRICK_DATA_START" then
		Remotes.TrickDataStarted:FireClient(playerToFire, decoded.payload)
	elseif decoded.type == "TRICK_DATA_CHUNK" then
		Remotes.TrickDataChunk:FireClient(playerToFire, decoded.payload)
	elseif decoded.type == "TRICK_DATA_END" then
		Remotes.TrickDataEnded:FireClient(playerToFire, decoded.payload)
		if systemRequestId then pendingClientRequests[systemRequestId] = nil end
	elseif decoded.type == "TRICK_ERROR" then
		Remotes.TrickError:FireClient(playerToFire, decoded.payload)
		if systemRequestId then pendingClientRequests[systemRequestId] = nil end
	elseif decoded.type == "CONFIGURE_DRONE_ACK" then
		Remotes.ConfigureDroneAck:FireClient(playerToFire, decoded.payload)
		if systemRequestId then pendingClientRequests[systemRequestId] = nil end
	else
		warn("RoSocketServiceHandler: Received unknown message type from orchestrator:", decoded.type)
	end
end

function RoSocketServiceHandler:Init()
	connectToOrchestrator()

	Players.PlayerAdded:Connect(function(player)
		activePlayersByUserId[player.UserId] = player
		print("RoSocketServiceHandler: Player added to active list:", player.Name, player.UserId)
	end)
	
	-- PlayerRemoving handled in the :PlayerRemoved method now
	
	for _, player in ipairs(Players:GetPlayers()) do
		activePlayersByUserId[player.UserId] = player
	end

	Remotes.RequestTrick.OnServerInvoke = function(player, clientPayload)
		if socketConnection and socketConnection.Send then -- RoSocket doesn't have a reliable readyState for sending
			print("RoSocketServiceHandler: Forwarding REQUEST_TRICK from Player", player.UserId, "OrigReqID:", clientPayload.original_request_id)
			
			local serverPayload = {
				type = "REQUEST_TRICK",
				payload = {
					roblox_client_id = tostring(player.UserId), -- Ensure string
					original_request_id = clientPayload.original_request_id,
					drone_name = clientPayload.drone_name, 
					trick_type = clientPayload.trick_type,
					direction = clientPayload.direction,
					initial_state = clientPayload.initial_state
				}
			}
			-- We need to map the orchestrator's response (which will use original_request_id AND a new system_request_id/burst_id)
			-- back to this player. TRICK_PENDING from orchestrator should give us system_request_id.
			-- Store the original_request_id with the player now, expecting it back in the payload.
			-- This step is crucial: map the client's original ID to the player so when TRICK_PENDING comes
			-- with that original ID, we can then create the system_request_id -> player mapping.
			-- Or, more simply, the TRICK_PENDING contains roblox_client_id which we set here.
			
			local success, err = pcall(socketConnection.Send, socketConnection, HttpService:JSONEncode(serverPayload))
			if success then
				return { success = true, message = "Request forwarded to orchestrator." }
			else
				warn("RoSocketServiceHandler: Error sending RequestTrick:", err)
				return { success = false, error = "Failed to send request to orchestrator: " .. tostring(err) }
			end
		else
			warn("RoSocketServiceHandler: Cannot forward RequestTrick, RoSocket not connected or send function unavailable. State:", socketConnection and socketConnection.readyState or "nil")
			return { success = false, error = "Not connected to orchestration server or connection not open." }
		end
	end

	Remotes.ConfigureDrone.OnServerInvoke = function(player, clientPayload)
		if socketConnection and socketConnection.Send then
			print("RoSocketServiceHandler: Forwarding CONFIGURE_DRONE from Player", player.UserId)
			local serverPayload = {
				type = "CONFIGURE_DRONE",
				payload = {
					roblox_client_id = tostring(player.UserId),
					original_request_id = clientPayload.original_request_id,
					drone_params = clientPayload.drone_params
				}
			}
			local success, err = pcall(socketConnection.Send, socketConnection, HttpService:JSONEncode(serverPayload))
			if success then
				return { success = true, message = "Configuration request forwarded." }
			else
				warn("RoSocketServiceHandler: Error sending ConfigureDrone:", err)
				return { success = false, error = "Failed to send configuration request: " .. tostring(err) }
			end
		else
			warn("RoSocketServiceHandler: Cannot forward ConfigureDrone, RoSocket not connected or send unavailable.")
			return { success = false, error = "Not connected to orchestration server or connection not open." }
		end
	end
	print("RoSocketServiceHandler: OnServerInvoke handlers set up.")
end

-- NEW Method to handle player removal
function RoSocketServiceHandler:PlayerRemoved(player)
	if player and activePlayersByUserId[player.UserId] then
		activePlayersByUserId[player.UserId] = nil
		print("RoSocketServiceHandler: Player removed from active list:", player.Name, player.UserId)
		
		-- Clean up pending requests associated with this player
		local requestsToClean = {}
		for reqId, data in pairs(pendingClientRequests) do
			if data.player == player then
				table.insert(requestsToClean, reqId)
			end
		end
		for _, reqId in ipairs(requestsToClean) do
			pendingClientRequests[reqId] = nil
			print("RoSocketServiceHandler: Cleaned pending request", reqId, "for removed player", player.Name)
		end
	end
end

return RoSocketServiceHandler