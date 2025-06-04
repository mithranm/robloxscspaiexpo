-- src/client/MainController.luau (ModuleScript)
local _Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local _StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService") -- Added for GenerateGUID

local _Config = require(ReplicatedStorage.Shared.Config)
local _Remotes = require(ReplicatedStorage.Shared.Remotes)
local ClientToServerBridge = require(script.Parent.ClientToServerBridge)
local DroneViewController = require(script.Parent.DroneViewController)
local TrickGuidanceController = require(ReplicatedStorage.Shared.DronePhysics.TrickGuidanceController)

local MainController = {}

local player = nil
local MyDrone = nil
local MyDroneBody = nil 
local myGazeboDroneName = nil

local currentMode = "PlayerControl" 
local currentOriginalRequestId = nil -- Stores the ID of the currently active trick request
local droneInitialized = false

local heartbeatConnection = nil
local renderSteppedConnection = nil
local trickRequestTimeoutTask = nil -- To manage the timeout for REQUEST_TRICK

local inputControllerRef = nil

local lastHeartbeatLogTime = 0
local heartbeatLogInterval = 1

-- Define a simple pre-programmed barrel roll trajectory
local function generatePreProgrammedBarrelRoll(startCFrame: CFrame, direction: string, duration: number, steps: number)
	local frames = {}
	local totalRotation = math.rad(360) * (direction == "LEFT" and 1 or -1)
	local forwardMovementPerSecond = 2.5 -- meters per second forward
	
	local rollAxisWorld = startCFrame.LookVector 
    
    local worldAngVel = rollAxisWorld * (totalRotation / duration)

	for i = 0, steps do
		local t = (i / steps) * duration
		local fraction = i / steps

        local currentRotationDelta = CFrame.fromAxisAngle(rollAxisWorld, totalRotation * fraction)
		local targetOrientation = currentRotationDelta * startCFrame.Rotation
		
		local currentPosition = startCFrame.Position + startCFrame.LookVector * (forwardMovementPerSecond * t)
		
		local frameCFrame = CFrame.new(currentPosition) * targetOrientation
        
        local worldLinVel = startCFrame.LookVector * forwardMovementPerSecond

		table.insert(frames, {
			t = t,
			cframe = frameCFrame, 
			lin_vel = {worldLinVel.X, worldLinVel.Y, worldLinVel.Z},
			ang_vel = {worldAngVel.X, worldAngVel.Y, worldAngVel.Z}, 
		})
	end
	return frames
end


local function getDroneCurrentState(droneModel)
	if not droneModel or not droneModel.PrimaryPart then
		return {
			cframe = CFrame.new(), position = Vector3.new(),
			linear_velocity = Vector3.new(), angular_velocity = Vector3.new(),
			mass_kg = _Config.DRONE_MASS_KG_DEFAULT, 
            isStable = false, breachReason = "NO_MODEL_PRIMARYPART"
		}
	end
	local body = droneModel.PrimaryPart
	local currentCFrame = body.CFrame
	local currentPosition = currentCFrame.Position
	local currentLinVel = body.AssemblyLinearVelocity
	local currentAngVel = body.AssemblyAngularVelocity
	local currentMass = body:GetMass()

	local upVector = currentCFrame.UpVector
	local worldUp = Vector3.new(0, 1, 0)
	local tiltAngleRad = math.acos(math.clamp(upVector:Dot(worldUp), -1, 1))
	local tiltAngleDeg = math.deg(tiltAngleRad)
	local localAngVel = currentCFrame:VectorToObjectSpace(currentAngVel)

	local isStable = true; local breachReason = "NONE"
	if tiltAngleDeg > _Config.MAX_SAFE_ATTITUDE_DEGREES then isStable = false; breachReason = "EXCESSIVE_TILT"
	elseif math.abs(math.deg(localAngVel.X)) > _Config.MAX_SAFE_ROLL_RATE_DPS then isStable = false; breachReason = "EXCESSIVE_ROLL_RATE"
	elseif math.abs(math.deg(localAngVel.Y)) > _Config.MAX_SAFE_PITCH_RATE_DPS then isStable = false; breachReason = "EXCESSIVE_PITCH_RATE"
	elseif math.abs(math.deg(localAngVel.Z)) > _Config.MAX_SAFE_YAW_RATE_DPS then isStable = false; breachReason = "EXCESSIVE_YAW_RATE"
	end

	return {
		cframe = currentCFrame, position = currentPosition,
		linear_velocity = currentLinVel, angular_velocity = currentAngVel,
		mass_kg = currentMass,
		isStable = isStable, breachReason = breachReason,
		currentTiltDegrees = tiltAngleDeg, localAngularVelocity = localAngVel
	}
end


local function findPlayerDroneAndInitialize()
	if droneInitialized then return end
	if not player then
		warn("MainController: Player object not set in findPlayerDroneAndInitialize. Cannot proceed.")
		return
	end

	local expectedDroneName = "PlayerDrone_" .. player.Name
	local droneInstance = Workspace:FindFirstChild(expectedDroneName)

	if not droneInstance then
		return
	end

	MyDrone = droneInstance
	MyDroneBody = MyDrone:WaitForChild("Body", 7) 

	if not MyDroneBody then
		warn("MainController: Player drone '", expectedDroneName, "' found, but 'Body' part did NOT appear. Drone might not be fully spawned or configured correctly.")
		MyDrone = nil
		return
	end

	print("MainController: Player drone '", MyDrone.Name, "' identified with body '", MyDroneBody.Name, "'. Initial CFrame:", MyDrone:GetPrimaryPartCFrame())

	local gazeboNameTag = MyDrone:FindFirstChild("GazeboDroneName")
	if gazeboNameTag and gazeboNameTag:IsA("StringValue") and gazeboNameTag.Value ~= "" then
		myGazeboDroneName = gazeboNameTag.Value
	else
		warn("MainController: Player drone '"..MyDrone.Name.."' 'GazeboDroneName' tag missing/empty!")
		myGazeboDroneName = "drone_p_fallback_"..player.UserId
	end
	print("MainController: Gazebo Ref for drone '", MyDrone.Name, "':", myGazeboDroneName)
    
	TrickGuidanceController:Initialize(MyDrone)
	print("MainController: TrickGuidanceController initialized for '", MyDrone.Name, "'.")

	DroneViewController:Initialize(MyDrone, MyDroneBody)
	print("MainController: DroneViewController initialized for '", MyDrone.Name, "' with target '", MyDroneBody.Name, "'.")

	if inputControllerRef then
		inputControllerRef:Initialize()
		inputControllerRef.TrickButtonPressed.Event:Connect(function(trickType, direction)
            print("MainController: TrickButtonPressed.Event received - Type:", trickType, "Direction:", direction, "CurrentMode:", currentMode)

			if (currentMode :: any) ~= "PlayerControl" or not MyDrone or not MyDroneBody or not myGazeboDroneName or myGazeboDroneName == "" then 
                warn("MainController: TrickButtonPressed.Event - Conditions not met. Mode:", currentMode, "MyDrone:", MyDrone, "MyDroneBody:", MyDroneBody, "GazeboName:", myGazeboDroneName)
                return 
            end
			print("MainController: Trick button pressed - ", trickType, direction, "for drone '"..MyDrone.Name.."'")
			
            currentMode = "TrickMode" 

			local currentState = getDroneCurrentState(MyDrone)
			local m = currentState.mass_kg
            -- CORRECTED: Use colon for CFrame method call
			local qx, qy, qz, qw = currentState.cframe:ToQuaternion() 
			local isp = {
				pos = {currentState.position.X, currentState.position.Y, currentState.position.Z},
				orient = {qx, qy, qz, qw},
				lin_vel = {currentState.linear_velocity.X, currentState.linear_velocity.Y, currentState.linear_velocity.Z},
				ang_vel = {currentState.angular_velocity.X, currentState.angular_velocity.Y, currentState.angular_velocity.Z},
				mass_kg = m
			}
            
            local newRequestId = HttpService:GenerateGUID(false)
			currentOriginalRequestId = newRequestId 

            if trickRequestTimeoutTask then
                task.cancel(trickRequestTimeoutTask)
                trickRequestTimeoutTask = nil
            end

			print("MainController: Requesting trick from server. Original Request ID:", currentOriginalRequestId)
			local bridgeForwardSuccessId = ClientToServerBridge:RequestTrick({
                original_request_id = currentOriginalRequestId, 
                drone_name=myGazeboDroneName,
                trick_type=trickType,
                direction=direction,
                initial_state=isp
            })

			if not bridgeForwardSuccessId then
				warn("MainController: ClientToServerBridge:RequestTrick returned failure for ID '"..currentOriginalRequestId.."'. Reverting to PlayerControl.")
				currentMode="PlayerControl"
                currentOriginalRequestId = nil
			else
				print("MainController: Trick request forwarded to server for '"..MyDrone.Name.."'. Original Request ID:", currentOriginalRequestId, ". Waiting for TRICK_DATA_START or 1s timeout...")
                
                trickRequestTimeoutTask = task.delay(_Config.TRICK_ACTIVATION_DELAY + 0.5, function() 
                    trickRequestTimeoutTask = nil 

                    if currentOriginalRequestId == newRequestId and (currentMode :: any) == "TrickMode" and not TrickGuidanceController:IsActive() then
                        warn("MainController: REQUEST_TRICK timed out for ID:", newRequestId, ". Using pre-programmed fallback for", trickType, direction)
                        
                        local fallbackFrames = generatePreProgrammedBarrelRoll(currentState.cframe, direction, 2.0, 40) 
                        local fallbackBurstId = "fallback_" .. HttpService:GenerateGUID(false)
                        
                        TrickGuidanceController:StartTrick(fallbackBurstId, {}) 
                        TrickGuidanceController:AddFrames(fallbackBurstId, fallbackFrames)
                        print("MainController: Started pre-programmed fallback trick:", fallbackBurstId, "with", #fallbackFrames, "frames.")

                        task.delay(2.0, function()
                            if TrickGuidanceController:GetCurrentBurstId() == fallbackBurstId then
                                print("MainController: Ending pre-programmed fallback trick:", fallbackBurstId)
                                TrickGuidanceController:EndTrick(fallbackBurstId, false) 
                                if (currentMode :: any) == "TrickMode" and currentOriginalRequestId == newRequestId then 
                                    currentMode = "PlayerControl"
                                    currentOriginalRequestId = nil 
                                    print("MainController: Fallback trick complete. Reverted to PlayerControl.")
                                end
                            end
                        end)
                    elseif currentOriginalRequestId == newRequestId and (currentMode :: any) == "TrickMode" and TrickGuidanceController:IsActive() then
                         print("MainController: Timeout for ID", newRequestId, "occurred, but Gazebo trick already started. No fallback needed.")
                    else
                         print("MainController: Timeout for ID", newRequestId, "occurred, but state is no longer relevant for fallback (Mode:", currentMode, "IsTGCActive:", TrickGuidanceController:IsActive(), ").")
                    end
                end)
			end
		end)
		print("MainController: InputController initialized and connected for '", MyDrone.Name, "'.")
	else
		warn("MainController: InputController reference not provided. Input will not work for '", (MyDrone and MyDrone.Name or expectedDroneName), "'.")
	end

	droneInitialized = true
	print("MainController: Full drone initialization complete for '", MyDrone.Name, "'. Physics is server-side.")
end

function MainController:Start(dependencies)
	player = dependencies.Player
	inputControllerRef = dependencies.InputController

	if not player then
		warn("MainController:Start() - Player object was not provided.")
		return
	end
	print("MainController: Start called for player", player.Name, "- Physics will be SERVER-SIDE.")

	ClientToServerBridge.OnTrickDataStarted.Event:Connect(function(payload)
        print("MainController: OnTrickDataStarted received for payload.original_request_id:", payload.original_request_id, "currentOriginalRequestId:", currentOriginalRequestId)
		
        if payload.original_request_id == currentOriginalRequestId and (currentMode :: any) == "TrickMode" then
            if trickRequestTimeoutTask then 
                print("MainController: Gazebo responded for TRICK_DATA_START. Cancelling fallback timeout task for ID:", currentOriginalRequestId)
                task.cancel(trickRequestTimeoutTask) 
                trickRequestTimeoutTask = nil
            end
            
            if TrickGuidanceController:IsActive() and TrickGuidanceController:GetCurrentBurstId() ~= payload.burst_id then
                if string.sub(TrickGuidanceController:GetCurrentBurstId(), 1, 8) == "fallback" then
                     print("MainController: Gazebo data arrived LATE for", payload.original_request_id, "while fallback trick", TrickGuidanceController:GetCurrentBurstId(), "was active. Ending fallback.")
                     TrickGuidanceController:EndTrick(TrickGuidanceController:GetCurrentBurstId(), true) 
                else
                    print("MainController: Already in a Gazebo trick", TrickGuidanceController:GetCurrentBurstId(), "but new TRICK_DATA_START arrived for same original_request_id. This might be a duplicate or error.")
                end
            end

			TrickGuidanceController:StartTrick(payload.burst_id, {})
            print("MainController: TRICK_DATA_START processed for Gazebo-guided trick:", payload.burst_id)
		else
            warn("MainController: Received TRICK_DATA_START for an unexpected request ID or mode. Payload ID:", payload.original_request_id, "Current ID:", currentOriginalRequestId, "Mode:", currentMode)
        end
	end)

	ClientToServerBridge.OnTrickDataChunk.Event:Connect(function(payload)
		if payload.original_request_id == currentOriginalRequestId and (currentMode :: any) == "TrickMode" and TrickGuidanceController:IsActive() and payload.burst_id == TrickGuidanceController:GetCurrentBurstId() then
            if string.sub(TrickGuidanceController:GetCurrentBurstId(), 1, 8) == "fallback" then
                return
            end
			TrickGuidanceController:AddFrames(payload.burst_id, payload.frames)
		end
	end)

	ClientToServerBridge.OnTrickDataEnded.Event:Connect(function(payload)
		if payload.original_request_id == currentOriginalRequestId and (currentMode :: any) == "TrickMode" and TrickGuidanceController:IsActive() and payload.burst_id == TrickGuidanceController:GetCurrentBurstId() then
            if string.sub(TrickGuidanceController:GetCurrentBurstId(), 1, 8) == "fallback" then
                print("MainController: Received TRICK_DATA_END from server while fallback trick was active. Ending fallback early.")
            end
			TrickGuidanceController:EndTrick(payload.burst_id)
			currentMode = "PlayerControl"
			currentOriginalRequestId = nil
		end
	end)

	ClientToServerBridge.OnTrickError.Event:Connect(function(payload)
        print("MainController: OnTrickError received for payload.original_request_id:", payload.original_request_id, "currentOriginalRequestId:", currentOriginalRequestId)
		if payload.original_request_id == currentOriginalRequestId and (currentMode :: any) == "TrickMode" then
            if trickRequestTimeoutTask then
                task.cancel(trickRequestTimeoutTask)
                trickRequestTimeoutTask = nil
                print("MainController: OnTrickError - Cancelled pending fallback timeout.")
            end
			if TrickGuidanceController:IsActive() then
				TrickGuidanceController:EndTrick(TrickGuidanceController:GetCurrentBurstId(), true) 
			end
			currentMode = "PlayerControl"
			currentOriginalRequestId = nil
            warn("MainController: TrickError received from server:", payload.message, ". Reverted to PlayerControl.")
		end
	end)

	if heartbeatConnection and heartbeatConnection.Connected then
		heartbeatConnection:Disconnect()
	end
	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		local doLog = false
		if time() - lastHeartbeatLogTime > heartbeatLogInterval then
			doLog = true
			lastHeartbeatLogTime = time()
		end

		if not droneInitialized then
			if doLog then print("Heartbeat: Drone NOT initialized, attempting to find/init PlayerDrone_" .. player.Name); end
			findPlayerDroneAndInitialize()
			return
		end

		if not MyDrone or not MyDrone.Parent or not MyDroneBody or not MyDroneBody.Parent then
			if doLog then
				print("Heartbeat: MyDrone or MyDroneBody not ready. MyDrone:", MyDrone, "Parent:", MyDrone and MyDrone.Parent)
			end
			if MyDrone and not MyDrone.Parent then
				warn("Heartbeat: MyDrone lost its parent! Resetting droneInitialized.")
				droneInitialized = false; MyDrone = nil; MyDroneBody = nil;
				if DroneViewController then DroneViewController:Cleanup() end
			end
			return
		end

		if (currentMode :: any) == "PlayerControl" then
			if inputControllerRef and ClientToServerBridge then
				local inputs = inputControllerRef:GetInputs()
				ClientToServerBridge:SendDroneInputs(inputs) 
			else
				if doLog then print("Heartbeat: inputControllerRef or ClientToServerBridge MISSING") end
			end
            
            if doLog then
                local droneCurrentState = getDroneCurrentState(MyDrone)
                 print(string.format("HeartbeatClient[%s]: Mode:%s Pos(%.1f,%.1f,%.1f) LinVel(%.1f,%.1f,%.1f) AngVel(%.1f,%.1f,%.1f) Tilt:%.0f Stab:%s (%s)",
                    MyDrone.Name,
                    currentMode,
                    droneCurrentState.position.X, droneCurrentState.position.Y, droneCurrentState.position.Z,
                    droneCurrentState.linear_velocity.X, droneCurrentState.linear_velocity.Y, droneCurrentState.linear_velocity.Z,
                    math.deg(droneCurrentState.localAngularVelocity.X), math.deg(droneCurrentState.localAngularVelocity.Y), math.deg(droneCurrentState.localAngularVelocity.Z),
                    droneCurrentState.currentTiltDegrees,
                    tostring(droneCurrentState.isStable),
                    tostring(droneCurrentState.breachReason)
                ))
            end

		elseif (currentMode :: any) == "TrickMode" then
			if TrickGuidanceController:IsActive() then
                local droneCurrentState = getDroneCurrentState(MyDrone)
				local guiding = TrickGuidanceController:Update(deltaTime,droneCurrentState.cframe,droneCurrentState.linear_velocity,droneCurrentState.angular_velocity)
				if not guiding and TrickGuidanceController:IsTrickCompleteOrError() then
					currentMode="PlayerControl"; 
                    if TrickGuidanceController:GetCurrentBurstId() and string.sub(TrickGuidanceController:GetCurrentBurstId(), 1, 8) == "fallback" then
                        currentOriginalRequestId = nil 
                    end
					if doLog then print("MainController: Trick ended or errored (client state for burst", TrickGuidanceController:GetCurrentBurstId(), "), back to PlayerControl.") end
                    TrickGuidanceController:EndTrick(TrickGuidanceController:GetCurrentBurstId(), TrickGuidanceController:IsTrickCompleteOrError()) 
				end
			end
		elseif (currentMode :: any) == "AssistanceMode" then
			if doLog then print("MainController: In AssistanceMode (logic pending).") end
		end

	end)

	if renderSteppedConnection and renderSteppedConnection.Connected then
		renderSteppedConnection:Disconnect()
	end
	renderSteppedConnection = RunService.RenderStepped:Connect(function(deltaTime)
		if droneInitialized and MyDrone and MyDrone.Parent then
			if DroneViewController then DroneViewController:Update(deltaTime) end
		elseif DroneViewController then
			DroneViewController:Update(deltaTime) 
		end
	end)

	task.wait(0.7)
	findPlayerDroneAndInitialize()
	if not droneInitialized then
		warn("MainController:Start - Initial findPlayerDroneAndInitialize FAILED. Heartbeat will continue trying.")
	end

	print("MainController module started. Heartbeat and RenderStepped connected. Client sends inputs to server.")
end

return MainController