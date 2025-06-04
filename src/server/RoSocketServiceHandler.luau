-- src/server/RoSocketServiceHandler.luau
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local RoSocket = require(ServerStorage.RoSocket)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local CustomFlightModel = require(ReplicatedStorage.Shared.DronePhysics.CustomFlightModel)
local ServerDroneGuidance = require(ServerScriptService.Server.ServerDroneGuidance)

local RoSocketServiceHandler = {}

local socketConnection = nil
local MAX_RETRIES = 5; local currentRetries = 0
local orchestratorWsUrl = Config.ROSOCKET_CONNECTION_URL

local activePlayersByUserId = {}
local pendingClientRequests = {} 
local serverFlightModels = {}
local serverGuidanceControllers = {}
local playerLatestInputs = {}
local activeTrickTimeouts = {} 
local activeReorientations = {}

local FALLBACK_TIMEOUT_DURATION = Config.TRICK_ACTIVATION_DELAY + 0.5 

local function connectToOrchestrator()
	if socketConnection and socketConnection.readyState == "OPEN" then return end
	if not HttpService.HttpEnabled then warn("RoSocketServiceHandler: HttpService disabled!"); return end
	print("RoSocketServiceHandler: Connecting to Orchestrator:", orchestratorWsUrl); currentRetries += 1
	local successConnect, newSocket = pcall(RoSocket.Connect, RoSocket, orchestratorWsUrl)
	if not successConnect or not newSocket or typeof(newSocket) ~= "table" or newSocket.error then 
		warn("RoSocketServiceHandler: RoSocket:Connect failed:", tostring(newSocket and newSocket.error or newSocket)); socketConnection = nil
		if currentRetries < MAX_RETRIES then task.wait(5); connectToOrchestrator() else warn("Max retries for RoSocket connect.") end; return
	end
	socketConnection = newSocket; print("RoSocketServiceHandler: RoSocket Connect called.")
	socketConnection.OnMessageReceived:Connect(RoSocketServiceHandler.OnOrchestratorMessage)
	socketConnection.OnDisconnect:Connect(function()
		print("RoSocketServiceHandler: RoSocket disconnected."); socketConnection = nil
		if currentRetries < MAX_RETRIES then task.wait(5); connectToOrchestrator() else warn("Max retries for RoSocket.") end
	end)
	socketConnection.OnErrorReceived:Connect(function(err) warn("RoSocketServiceHandler: RoSocket Error:", err) end)
	currentRetries = 0
end

local function initiateServerFallback(player, originalRequestId, reason)
    local requestData = pendingClientRequests[originalRequestId]
    if not requestData then
        warn("RoSocketServiceHandler:initiateServerFallback - No pending request data for ID:", originalRequestId)
        return
    end
    local clientPayload = requestData.clientPayload

    local cfm = serverFlightModels[player.UserId]
    local guidanceCtrl = serverGuidanceControllers[player.UserId]
    local drone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)

    if not (cfm and guidanceCtrl and drone and drone.PrimaryPart) then
        warn("RoSocketServiceHandler:initiateServerFallback - Cannot initiate fallback, components missing for", player.Name, "ReqID:", originalRequestId)
        if cfm then cfm:SetControlMode("Player") end
        Remotes.ServerNotification:FireClient(player, {type="TrickEnded", original_request_id=originalRequestId, success=false, message="Server error during fallback init."})
        if pendingClientRequests[originalRequestId] then pendingClientRequests[originalRequestId] = nil end
        return
    end
    
    warn("RoSocketServiceHandler:", reason, "for OrigID:", originalRequestId, "Player:", player.Name, ". Initiating server fallback.")
    if activeTrickTimeouts[originalRequestId] then task.cancel(activeTrickTimeouts[originalRequestId]); activeTrickTimeouts[originalRequestId] = nil end

    local currentDroneState = cfm:GetCurrentState() 
    local fallbackFrames = ServerDroneGuidance.generatePreProgrammedBarrelRoll(currentDroneState.cframe, clientPayload.direction or "RIGHT", 2.0, 40)
    local fallbackBurstId = "server_fallback_" .. HttpService:GenerateGUID(false)

    cfm:SetControlMode("Guidance") 
    guidanceCtrl:StartGuidance(fallbackBurstId, fallbackFrames, currentDroneState.cframe) -- Pass CFrame for initial yaw
    Remotes.ServerNotification:FireClient(player, {type="TrickStarted", original_request_id=originalRequestId, burst_id=fallbackBurstId, source="ServerFallback"})
    if pendingClientRequests[originalRequestId] then pendingClientRequests[originalRequestId].system_request_id = fallbackBurstId end
end


function RoSocketServiceHandler.OnOrchestratorMessage(message)
    local success, decoded = pcall(HttpService.JSONDecode, HttpService, message)
	if not success then warn("RoSocketServiceHandler: Failed to decode JSON:", message, decoded); return end

	local playerToFire = nil
    local originalRequestId = decoded.payload and decoded.payload.original_request_id
    local systemRequestId = decoded.payload and (decoded.payload.system_request_id or decoded.payload.burst_id)

    if originalRequestId and pendingClientRequests[originalRequestId] then
        playerToFire = pendingClientRequests[originalRequestId].player
        if systemRequestId and not pendingClientRequests[originalRequestId].system_request_id then
             pendingClientRequests[originalRequestId].system_request_id = systemRequestId
        end
    elseif systemRequestId then 
        for reqId, data in pairs(pendingClientRequests) do
            if data.system_request_id == systemRequestId then
                playerToFire = data.player
                originalRequestId = reqId 
                break
            end
        end
    end
    
	if not playerToFire or not playerToFire.Parent then
        warn("RoSocketServiceHandler: Could not map orchestrator message to player. OrigID:", originalRequestId or "N/A", "SysID:", systemRequestId or "N/A")
        return
    end

    if originalRequestId and activeTrickTimeouts[originalRequestId] then
        print("RoSocketServiceHandler: Gazebo responded for request", originalRequestId, ". Cancelling fallback timeout.")
        task.cancel(activeTrickTimeouts[originalRequestId]); activeTrickTimeouts[originalRequestId] = nil
    end

	local messageType = decoded.type; local payload = decoded.payload
    local cfm = serverFlightModels[playerToFire.UserId]
    local guidanceCtrl = serverGuidanceControllers[playerToFire.UserId]

    if not payload.original_request_id and originalRequestId then payload.original_request_id = originalRequestId end

	if messageType == "TRICK_PENDING" then
		print("RoSocketServiceHandler: TRICK_PENDING for player", playerToFire.Name, "SysID:", systemRequestId or "N/A")
        if originalRequestId and pendingClientRequests[originalRequestId] and systemRequestId then
            pendingClientRequests[originalRequestId].system_request_id = systemRequestId 
        end
	elseif messageType == "TRICK_DATA_START" then
		if cfm and guidanceCtrl then
            local drone = Workspace:FindFirstChild("PlayerDrone_" .. playerToFire.Name)
            cfm:SetControlMode("Guidance")
            guidanceCtrl:StartGuidance(payload.burst_id, {}, drone and drone.PrimaryPart and drone.PrimaryPart.CFrame or CFrame.new())
			Remotes.ServerNotification:FireClient(playerToFire, {type="TrickStarted", original_request_id=originalRequestId, burst_id=payload.burst_id, source="Gazebo"})
            print("RoSocketServiceHandler: Player", playerToFire.Name, "starting Gazebo-guided trick:", payload.burst_id)
        end
	elseif messageType == "TRICK_DATA_CHUNK" then
		if guidanceCtrl and guidanceCtrl:IsActive() and guidanceCtrl.burstId == payload.burst_id then
            guidanceCtrl.trajectoryFrames = payload.frames 
        end
	elseif messageType == "TRICK_DATA_END" then
		if guidanceCtrl and guidanceCtrl:IsActive() and guidanceCtrl.burstId == payload.burst_id then
            guidanceCtrl:EndGuidance(false)
        end
        if cfm then cfm:SetControlMode("Player") end
		Remotes.ServerNotification:FireClient(playerToFire, {type="TrickEnded", original_request_id=originalRequestId, burst_id=payload.burst_id, success=true})
        if originalRequestId then pendingClientRequests[originalRequestId] = nil end
        print("RoSocketServiceHandler: Player", playerToFire.Name, "Gazebo trick ended:", payload.burst_id)
	elseif messageType == "TRICK_ERROR" then
		if guidanceCtrl and guidanceCtrl:IsActive() then guidanceCtrl:EndGuidance(true) end
        if cfm then cfm:SetControlMode("Player") end
		Remotes.ServerNotification:FireClient(playerToFire, {type="TrickEnded", original_request_id=originalRequestId, burst_id=(guidanceCtrl and guidanceCtrl.burstId or payload.burst_id), success=false, message=payload.message})
        if originalRequestId then pendingClientRequests[originalRequestId] = nil end
        warn("RoSocketServiceHandler: Player", playerToFire.Name, "Gazebo trick error. Msg:", payload and payload.message or "N/A")
	elseif messageType == "CONFIGURE_DRONE_ACK" then
		Remotes.ConfigureDroneAck:FireClient(playerToFire, payload)
        if originalRequestId then pendingClientRequests[originalRequestId] = nil end
	else warn("RoSocketServiceHandler: Unknown message type:", messageType) end
end

function RoSocketServiceHandler:Init()
    coroutine.wrap(connectToOrchestrator)()
	local function _setupPlayerControllers(player)
		local playerDrone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)
		if playerDrone then
			local cfmInstance = CustomFlightModel.new(playerDrone)
			if cfmInstance then
				serverFlightModels[player.UserId] = cfmInstance
				playerLatestInputs[player.UserId] = { throttle = 0, roll = 0, pitch = 0, yaw = 0 }
                local guidanceCtrl = ServerDroneGuidance.new(playerDrone, cfmInstance)
                if guidanceCtrl then serverGuidanceControllers[player.UserId] = guidanceCtrl end
				print("RoSocketServiceHandler: Initialized Server CFM & Guidance for player", player.Name)
			else warn("RoSocketServiceHandler: Failed to initialize Server CFM for", player.Name) end
		else warn("RoSocketServiceHandler: Drone for", player.Name, "not found. Controllers not initialized.") end
	end
	Players.PlayerAdded:Connect(function(player) activePlayersByUserId[player.UserId] = player; _setupPlayerControllers(player) end)
	for _, player in ipairs(Players:GetPlayers()) do activePlayersByUserId[player.UserId] = player; _setupPlayerControllers(player) end

	Remotes.RequestTrick.OnServerInvoke = function(player, clientPayload)
        local cfm = serverFlightModels[player.UserId]
        local guidanceCtrl = serverGuidanceControllers[player.UserId]
        local originalRequestId = clientPayload.original_request_id 

		if not (cfm and guidanceCtrl and Workspace:FindFirstChild("PlayerDrone_" .. player.Name)) then
            warn("RoSocketServiceHandler:RequestTrick - Missing server components for player", player.Name)
            return { success = false, error = "Server components not ready." }
        end
        if guidanceCtrl:IsActive() or activeTrickTimeouts[originalRequestId] or pendingClientRequests[originalRequestId] or activeReorientations[player.UserId] then
            warn("RoSocketServiceHandler:RequestTrick - Player", player.Name, "operation already processing for OrigID:", originalRequestId, "Ignoring.")
            return { success = false, error = "Operation already active or being processed for this request ID." }
        end

        cfm:SetControlMode("Guidance")
		Remotes.ServerNotification:FireClient(player, {type="TrickAttempting", original_request_id=originalRequestId})
        print("RoSocketServiceHandler: Player", player.Name, "REQUEST_TRICK. OrigID:", originalRequestId)
        pendingClientRequests[originalRequestId] = {player = player, isGazeboAttempted = false, clientPayload = clientPayload}

		if socketConnection and socketConnection.readyState == "OPEN" then
			local serverPayload = {type = "REQUEST_TRICK", payload = clientPayload}
            serverPayload.payload.roblox_client_id = tostring(player.UserId)
            pendingClientRequests[originalRequestId].isGazeboAttempted = true

			local successSend, errSend = pcall(socketConnection.Send, socketConnection, HttpService:JSONEncode(serverPayload))
			if successSend then
                if activeTrickTimeouts[originalRequestId] then task.cancel(activeTrickTimeouts[originalRequestId]) end 
                activeTrickTimeouts[originalRequestId] = task.delay(FALLBACK_TIMEOUT_DURATION, function()
                    if pendingClientRequests[originalRequestId] and not (guidanceCtrl and guidanceCtrl:IsActive()) then 
                        initiateServerFallback(player, originalRequestId, "Gazebo timed out")
                    end
                    activeTrickTimeouts[originalRequestId] = nil
                end)
                return { success = true, message = "Request forwarded to orchestrator, awaiting response or fallback." }
			else
                warn("RoSocketServiceHandler: Error sending RequestTrick to RoSocket proxy:", errSend, ". Initiating server fallback.")
                initiateServerFallback(player, originalRequestId, "Failed to send to orchestrator")
                return { success = true, message = "Failed to send to orchestrator, initiated server fallback." } 
            end
		else
            warn("RoSocketServiceHandler: RoSocket not connected. Initiating server fallback immediately for OrigID:", originalRequestId)
            initiateServerFallback(player, originalRequestId, "RoSocket not connected")
            return { success = true, message = "RoSocket not connected, initiated server fallback." } 
        end
	end

    Remotes.RequestReorient.OnServerInvoke = function(player)
        local cfm = serverFlightModels[player.UserId]
        local guidanceCtrl = serverGuidanceControllers[player.UserId]
        local drone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)

        if not (cfm and guidanceCtrl and drone and drone.PrimaryPart) then
            return { success = false, error = "Server components not ready for reorient." }
        end
        if guidanceCtrl:IsActive() or activeReorientations[player.UserId] then
            local activeReq = "Unknown"
            for reqId, data in pairs(pendingClientRequests) do if data.player == player then activeReq = reqId; break; end end
            warn("RoSocketServiceHandler:Reorient - Player", player.Name, "another operation active (TrickID:", activeReq, "Reorienting:", tostring(activeReorientations[player.UserId]),"). Ignoring.")
            return { success = false, error = "Another operation (trick/reorient) is active."}
        end

        print("RoSocketServiceHandler: Player", player.Name, "requested reorient.")
        activeReorientations[player.UserId] = true 
        cfm:SetControlMode("Guidance") 

        local currentCFrame = drone.PrimaryPart.CFrame
        local _, yaw, _ = currentCFrame:ToOrientation() 
        local targetHomeCFrame = CFrame.new(currentCFrame.Position) * CFrame.Angles(0, yaw, 0) 

        local reorientFrames = {
            {t = 0, cframe = currentCFrame, lin_vel = {0,0,0}, ang_vel = {0,0,0}}, 
            {t = Config.REORIENT_DURATION, cframe = targetHomeCFrame, lin_vel = {0,0,0}, ang_vel = {0,0,0}} 
        }
        local reorientBurstId = "server_reorient_" .. HttpService:GenerateGUID(false)
        guidanceCtrl:StartGuidance(reorientBurstId, reorientFrames, currentCFrame) 

        Remotes.ServerNotification:FireClient(player, {type="ReorientStarted", burst_id=reorientBurstId})
        
        return { success = true, message = "Reorientation started."}
    end

	Remotes.ConfigureDrone.OnServerInvoke = function(player, clientPayload)
		if socketConnection and socketConnection.Send then
			local serverPayload = {type = "CONFIGURE_DRONE", payload = clientPayload}
            serverPayload.payload.roblox_client_id = tostring(player.UserId)
			local s,e = pcall(socketConnection.Send, socketConnection, HttpService:JSONEncode(serverPayload))
			if s then 
                pendingClientRequests[clientPayload.original_request_id] = {player=player, clientPayload = clientPayload}
                return {success=true} 
            else 
                return {success=false, error=tostring(e)} 
            end
		else return {success=false, error="Not connected."} end
	end

	Remotes.ClientDroneInputs.OnServerEvent:Connect(function(player, inputs)
		if serverFlightModels[player.UserId] and inputs then playerLatestInputs[player.UserId] = inputs end
	end)

	RunService.Heartbeat:Connect(function(deltaTime)
		for userId, cfmInstance in pairs(serverFlightModels) do
			local player = activePlayersByUserId[userId]
            local guidanceCtrl = serverGuidanceControllers[userId]
			if not player or not cfmInstance.IsInitialized then continue end
			
            if cfmInstance.ControlMode == "Player" then
			    local inputs = playerLatestInputs[userId] or { throttle = 0, roll = 0, pitch = 0, yaw = 0 }
			    cfmInstance:Update(deltaTime, inputs.throttle, inputs.roll, inputs.pitch, inputs.yaw)
            elseif cfmInstance.ControlMode == "Guidance" and guidanceCtrl and guidanceCtrl:IsActive() then
                local stillGuiding = guidanceCtrl:Update(deltaTime)
                if not stillGuiding then
                    local completedBurstId = guidanceCtrl.burstId 
                    local originalReqIdForCompletedBurst = nil
                    local isReorient = string.sub(completedBurstId or "", 1, 16) == "server_reorient_"

                    for reqId, data in pairs(pendingClientRequests) do
                        if data.system_request_id == completedBurstId then
                            originalReqIdForCompletedBurst = reqId
                            pendingClientRequests[reqId] = nil; 
                            break
                        end
                    end
                    
                    guidanceCtrl:EndGuidance(false) 
                    cfmInstance:SetControlMode("Player")

                    if isReorient then
                        Remotes.ServerNotification:FireClient(player, {type="ReorientComplete", burst_id=completedBurstId, success=true})
                        activeReorientations[player.UserId] = nil 
                        print("RoSocketServiceHandler: Server Reorientation completed for", player.Name)
                    else
                        Remotes.ServerNotification:FireClient(player, {type="TrickEnded", original_request_id=originalReqIdForCompletedBurst, burst_id=completedBurstId, success=true})
                        print("RoSocketServiceHandler: ServerDroneGuidance (Trick) completed for", player.Name, "Burst:", completedBurstId)
                    end
                end
            end
		end
	end)
	print("RoSocketServiceHandler: Initialized.")
end

function RoSocketServiceHandler:PlayerRemoved(player)
	if player and activePlayersByUserId[player.UserId] then
		activePlayersByUserId[player.UserId] = nil
		local cfm = serverFlightModels[player.UserId]; if cfm then cfm:Cleanup(); serverFlightModels[player.UserId] = nil end
        local gCtrl = serverGuidanceControllers[player.UserId]; if gCtrl then gCtrl:EndGuidance(true); serverGuidanceControllers[player.UserId] = nil end
		playerLatestInputs[player.UserId] = nil
        activeReorientations[player.UserId] = nil 
        local reqsToClean = {}
        for reqId, data in pairs(pendingClientRequests) do if data.player == player then table.insert(reqsToClean, reqId) end end
        for _, reqId in ipairs(reqsToClean) do 
            if activeTrickTimeouts[reqId] then task.cancel(activeTrickTimeouts[reqId]); activeTrickTimeouts[reqId] = nil end
            pendingClientRequests[reqId] = nil
        end
		print("RoSocketServiceHandler: Cleaned up for removed player", player.Name)
	end
end

return RoSocketServiceHandler