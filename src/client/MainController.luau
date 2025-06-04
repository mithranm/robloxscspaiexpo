-- src/client/MainController.luau (ModuleScript)
local _Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local _Config = require(ReplicatedStorage.Shared.Config)
local _Remotes = require(ReplicatedStorage.Shared.Remotes)
local ClientToServerBridge = require(script.Parent.ClientToServerBridge)
local DroneViewController = require(script.Parent.DroneViewController)

local MainController = {}

local player = nil
local MyDrone = nil
local MyDroneBody = nil
local myGazeboDroneNameForRequest = nil 

local MODE_PLAYER_CONTROL = "PlayerControl"
local MODE_AWAITING_TRICK_START = "AwaitingTrickStart" 
local MODE_TRICK_IN_PROGRESS = "TrickInProgress" 
local MODE_REORIENTING = "Reorienting" 

local currentMode = MODE_PLAYER_CONTROL
local activeOriginalRequestId = nil 
local droneInitialized = false

local heartbeatConnection = nil
local renderSteppedConnection = nil

local inputControllerRef = nil
local lastHeartbeatLogTime = 0
local heartbeatLogInterval = 1

local function getCFrameQuaternion(cf: CFrame): (number, number, number, number)
    local _, _, _, R00, R01, R02, R10, R11, R12, R20, R21, R22 = cf:GetComponents()
    local trace = R00 + R11 + R22; local S, qw, qx, qy, qz
    if trace > 0 then S = math.sqrt(trace + 1.0) * 2; qw = 0.25 * S; qx = (R21 - R12) / S; qy = (R02 - R20) / S; qz = (R10 - R01) / S
    elseif (R00 > R11) and (R00 > R22) then S = math.sqrt(1.0 + R00 - R11 - R22) * 2; qw = (R21 - R12) / S; qx = 0.25 * S; qy = (R01 + R10) / S; qz = (R02 + R20) / S
    elseif R11 > R22 then S = math.sqrt(1.0 + R11 - R00 - R22) * 2; qw = (R02 - R20) / S; qx = (R01 + R10) / S; qy = 0.25 * S; qz = (R12 + R21) / S
    else S = math.sqrt(1.0 + R22 - R00 - R11) * 2; qw = (R10 - R01) / S; qx = (R02 + R20) / S; qy = (R12 + R21) / S; qz = 0.25 * S end
    return qx, qy, qz, qw
end

local function getDroneCurrentState(droneModel)
	if not droneModel or not droneModel.PrimaryPart then
		return {cframe = CFrame.new(), linear_velocity = Vector3.zero, angular_velocity = Vector3.zero, mass_kg = _Config.DRONE_MASS_KG_DEFAULT, position = Vector3.zero}
	end
	local body = droneModel.PrimaryPart
	return {
		cframe = body.CFrame, linear_velocity = body.AssemblyLinearVelocity,
		angular_velocity = body.AssemblyAngularVelocity, mass_kg = _Config.DRONE_MASS_KG_DEFAULT,
        position = body.Position
	}
end


local function findPlayerDroneAndInitialize()
	if droneInitialized then return end
	if not player then warn("MainController: Player object nil."); return end

	MyDrone = Workspace:FindFirstChild("PlayerDrone_" .. player.Name)
	if not MyDrone then return end
	MyDroneBody = MyDrone:WaitForChild("Body", 7)
	if not MyDroneBody then warn("MainController: Player drone body missing."); MyDrone = nil; return end
	
    print("MainController: Player drone '", MyDrone.Name, "' identified.")
    local gazeboNameTag = MyDrone:WaitForChild("GazeboDroneName", 2)
	if gazeboNameTag and gazeboNameTag:IsA("StringValue") and gazeboNameTag.Value ~= "" then
		myGazeboDroneNameForRequest = gazeboNameTag.Value
	else
		warn("MainController: GazeboDroneName tag missing for ", MyDrone.Name, ". Using client-generated fallback for requests.")
		myGazeboDroneNameForRequest = "drone_CLIENT_FALLBACK_"..player.UserId
	end
	print("MainController: Gazebo Ref for requests: ", myGazeboDroneNameForRequest)

	DroneViewController:Initialize(MyDrone, MyDroneBody)

	if inputControllerRef then
		inputControllerRef:Initialize()
		inputControllerRef.TrickButtonPressed.Event:Connect(function(trickType, direction)
            print("MainController: TrickButton - Mode:", currentMode, "Type:", trickType)
			if currentMode ~= MODE_PLAYER_CONTROL or not MyDrone or not MyDroneBody then
                warn("MainController: Cannot init trick. Mode:", currentMode, "or drone not ready.")
                return
            end
			
			local currentState = getDroneCurrentState(MyDrone)
			local qx, qy, qz, qw = getCFrameQuaternion(currentState.cframe)
			local isp = {
				pos={currentState.position.X, currentState.position.Y, currentState.position.Z},
				orient={qx,qy,qz,qw}, lin_vel={currentState.linear_velocity.X,currentState.linear_velocity.Y,currentState.linear_velocity.Z},
				ang_vel={currentState.angular_velocity.X,currentState.angular_velocity.Y,currentState.angular_velocity.Z},
				mass_kg=currentState.mass_kg
			}
            local newRequestId = HttpService:GenerateGUID(false)
			
            print("MainController: Requesting SERVER-SIDE trick. New OrigReqID:", newRequestId)
            currentMode = MODE_AWAITING_TRICK_START 
            activeOriginalRequestId = newRequestId 

			local invokeResult = ClientToServerBridge:RequestTrick({
                original_request_id = newRequestId, 
                drone_name = myGazeboDroneNameForRequest,
                trick_type = trickType, direction = direction, initial_state = isp
            })

			if not invokeResult or not invokeResult.success then 
				warn("MainController: Server or Bridge indicated failure for trick request. Msg:", invokeResult and invokeResult.error or "Bridge pcall failed or server error")
                currentMode = MODE_PLAYER_CONTROL 
                activeOriginalRequestId = nil 
			else
				print("MainController: Trick request sent to server for OrigReqID:", newRequestId, ". Server/Bridge response:", invokeResult.message or "OK")
			end
		end)

        inputControllerRef.ReorientButtonPressed.Event:Connect(function()
            if not MyDrone then
                print("MainController: Reorient pressed but no drone.")
                return
            end

            if currentMode == MODE_REORIENTING then
                print("MainController: Reorient pressed but already in MODE_REORIENTING.")
                return
            end

            print("MainController: Reorient button pressed. Current Mode:", currentMode, ". Attempting to switch to MODE_REORIENTING and invoke server.")
            currentMode = MODE_REORIENTING
            -- Clear any active trick ID on the client, as reorientation takes precedence.
            -- The server will handle cancelling its own pending trick operations for this player.
            if activeOriginalRequestId then
                print("MainController: Reorient action is clearing activeOriginalRequestId:", activeOriginalRequestId)
                activeOriginalRequestId = nil
            end
            
            local success, result = pcall(_Remotes.RequestReorient.InvokeServer, _Remotes.RequestReorient)
            if not success or not result or not result.success then
                warn("MainController: Reorient request failed or server rejected. Reverting to PLAYER_CONTROL. Error:", result)
                currentMode = MODE_PLAYER_CONTROL 
            else
                print("MainController: Reorient request accepted by server.")
            end
        end)

	end
	droneInitialized = true
	print("MainController: Full drone initialization complete.")
end

function MainController:Start(dependencies)
	player = dependencies.Player; inputControllerRef = dependencies.InputController
	if not player then warn("MainController:Start() - Player object nil."); return end
	print("MainController: Start called for player", player.Name, ". All tricks server-authoritative.")

    _Remotes.ServerNotification.OnClientEvent:Connect(function(payload)
        print("MainController: ServerNotification Received:", payload.type, " | Current Client Mode:", currentMode, " | PayloadOrigID:", payload.original_request_id or "N/A", " | ClientActiveID:", activeOriginalRequestId or "N/A")
        
        if payload.type == "TrickAttempting" then
            if payload.original_request_id == activeOriginalRequestId then
                print("MainController: Server is Attempting Trick for active request:", activeOriginalRequestId)
            else
                 print("MainController: ServerNotification TrickAttempting for mismatched/old request ID. Current active:", activeOriginalRequestId, ". Ignoring.")
            end
        elseif payload.type == "TrickStarted" then
            if payload.original_request_id == activeOriginalRequestId and currentMode == MODE_AWAITING_TRICK_START then
                currentMode = MODE_TRICK_IN_PROGRESS 
                print("MainController: Server Started Trick (", payload.source or "N/A", "). Burst:", payload.burst_id, "For Req:", activeOriginalRequestId, ". Mode set to TRICK_IN_PROGRESS.")
            elseif currentMode ~= MODE_TRICK_IN_PROGRESS and payload.original_request_id == activeOriginalRequestId then
                -- This could happen if client was in PlayerControl, server started trick (e.g. from previous session or edge case)
                print("MainController: ServerNotification TrickStarted for current activeOriginalRequestId, client wasn't in AWAITING_TRICK_START. Setting mode to TRICK_IN_PROGRESS. Burst:", payload.burst_id, "ReqID:", payload.original_request_id)
                currentMode = MODE_TRICK_IN_PROGRESS
            elseif payload.original_request_id ~= activeOriginalRequestId then
                 print("MainController: ServerNotification TrickStarted for mismatched/old request ID (", payload.original_request_id,"). Current active client ID:", activeOriginalRequestId, ". Ignoring.")
            end
        elseif payload.type == "TrickEnded" then
            -- Only transition to PlayerControl if the TrickEnded matches the client's active trick, OR if there's no active trick ID (general cleanup)
            if not activeOriginalRequestId or payload.original_request_id == activeOriginalRequestId then
                currentMode = MODE_PLAYER_CONTROL
                print("MainController: Server Ended Trick. Success:", tostring(payload.success), ". Mode set to PlayerControl. ActiveID (", activeOriginalRequestId or "N/A", ") cleared.")
                activeOriginalRequestId = nil 
            else
                print("MainController: ServerNotification TrickEnded for a different request ID (", payload.original_request_id, ") than client's current (", activeOriginalRequestId ,"). Client mode remains:", currentMode)
            end
        elseif payload.type == "ReorientComplete" then 
            print("MainController: Received ServerNotification ReorientComplete. Current client mode:", currentMode, "BurstID on payload:", payload.burst_id or "N/A")
            if currentMode == MODE_REORIENTING then
                currentMode = MODE_PLAYER_CONTROL
                -- activeOriginalRequestId should have been cleared when reorient was initiated by client,
                -- or if it was a stale trick ID, this confirms it should be nil.
                activeOriginalRequestId = nil 
                print("MainController: ReorientComplete processed. Mode set to PlayerControl. Active Request ID confirmed cleared.")
            else
                print("MainController: ServerNotification ReorientComplete, but client not in Reorienting mode. Current mode:", currentMode, ". Client mode remains:", currentMode, ". ActiveReqID:", activeOriginalRequestId or "N/A")
                -- If server says reorient is done, and we had an activeOriginalRequestId, it's probably safe to clear it
                -- as reorient would have cancelled any server-side trick.
                if activeOriginalRequestId then
                    print("MainController: Clearing activeOriginalRequestId due to ReorientComplete, even though not in MODE_REORIENTING.")
                    activeOriginalRequestId = nil
                end
            end
        end
    end)

	if heartbeatConnection then heartbeatConnection:Disconnect() end
	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		local doLog = time() - lastHeartbeatLogTime > heartbeatLogInterval
		if doLog then lastHeartbeatLogTime = time() end
		if not droneInitialized then if doLog then print("Heartbeat: Drone NOT init"); end; findPlayerDroneAndInitialize(); return end
		if not MyDrone or not MyDrone.Parent or not MyDroneBody or not MyDroneBody.Parent then
			if MyDrone and not MyDrone.Parent then
				warn("Heartbeat: MyDrone lost parent! Resetting."); droneInitialized = false; MyDrone = nil; MyDroneBody = nil;
				if DroneViewController then DroneViewController:Cleanup() end
                currentMode = MODE_PLAYER_CONTROL; activeOriginalRequestId = nil;
			end
			return
		end

		if currentMode == MODE_PLAYER_CONTROL then
			if inputControllerRef then ClientToServerBridge:SendDroneInputs(inputControllerRef:GetInputs()) end
        elseif currentMode == MODE_REORIENTING then
            if doLog then print("MainController: Heartbeat - Client Mode: Reorienting (Server Authoritative), ActiveReqID:", activeOriginalRequestId or "N/A") end
		end
        if doLog and MyDrone and MyDrone.PrimaryPart then
            print(string.format("HeartbeatClient[%s]: Mode:%s ActiveReqID:%s Pos(%.1f,%.1f,%.1f)", MyDrone.Name, currentMode, activeOriginalRequestId or "N/A", MyDrone.PrimaryPart.Position.X, MyDrone.PrimaryPart.Position.Y, MyDrone.PrimaryPart.Position.Z))
        end
	end)

	if renderSteppedConnection then renderSteppedConnection:Disconnect() end
	renderSteppedConnection = RunService.RenderStepped:Connect(function(deltaTime)
		if droneInitialized and MyDrone and MyDrone.Parent then DroneViewController:Update(deltaTime)
		elseif DroneViewController then DroneViewController:Update(deltaTime) end
	end)

	task.wait(0.7); findPlayerDroneAndInitialize(); print("MainController module started.")
end

return MainController