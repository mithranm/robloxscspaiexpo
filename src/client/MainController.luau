-- src/client/MainController.luau (ModuleScript)
local _Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local _StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local _Config = require(ReplicatedStorage.Shared.Config)
local _Remotes = require(ReplicatedStorage.Shared.Remotes)
local ClientToServerBridge = require(script.Parent.ClientToServerBridge)
local DroneViewController = require(script.Parent.DroneViewController)
-- CustomFlightModel is no longer directly used by client MainController for physics
-- local CustomFlightModel = require(ReplicatedStorage.Shared.DronePhysics.CustomFlightModel)
local TrickGuidanceController = require(ReplicatedStorage.Shared.DronePhysics.TrickGuidanceController)

local MainController = {}

local player = nil
local MyDrone = nil
local MyDroneBody = nil -- Store the drone's body part
local myGazeboDroneName = nil

local currentMode = "PlayerControl" -- Modes: PlayerControl, TrickMode
local currentOriginalRequestId = nil
local droneInitialized = false

local heartbeatConnection = nil
local renderSteppedConnection = nil

local inputControllerRef = nil
-- local flightModelInstance = nil -- Client no longer manages its own physics-applying flight model instance

local lastHeartbeatLogTime = 0
local heartbeatLogInterval = 1

-- Helper function to get current drone state directly from the model
local function getDroneCurrentState(droneModel)
	if not droneModel or not droneModel.PrimaryPart then
		return {
			cframe = CFrame.new(), position = Vector3.new(),
			linear_velocity = Vector3.new(), angular_velocity = Vector3.new(),
			mass_kg = _Config.DRONE_MASS_KG_DEFAULT, -- Fallback mass
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
	MyDroneBody = MyDrone:WaitForChild("Body", 7) -- Or MyDrone.PrimaryPart

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

	-- Client no longer initializes its own CustomFlightModel for physics
	-- flightModelInstance = CustomFlightModel.new(MyDrone)
	-- if not flightModelInstance then ... return end
	-- print("MainController: CustomFlightModel instance created (client-side, for state reading if needed).")

    -- TrickGuidanceController:Initialize no longer takes flightModelInstance
	TrickGuidanceController:Initialize(MyDrone)
	print("MainController: TrickGuidanceController initialized for '", MyDrone.Name, "'.")

	DroneViewController:Initialize(MyDrone, MyDroneBody)
	print("MainController: DroneViewController initialized for '", MyDrone.Name, "' with target '", MyDroneBody.Name, "'.")

	if inputControllerRef then
		inputControllerRef:Initialize()
		inputControllerRef.TrickButtonPressed.Event:Connect(function(trickType, direction)
			if currentMode ~= "PlayerControl" or not MyDrone or not myGazeboDroneName or myGazeboDroneName == "" then return end
			print("MainController: Trick button pressed - ", trickType, direction, "for drone '"..MyDrone.Name.."'")
			
            currentMode = "TrickMode"
            -- Client no longer directly tells CFM to stop player control. Server will handle this.
            -- if flightModelInstance then flightModelInstance:SetPlayerControl(false) end

			local currentState = getDroneCurrentState(MyDrone) -- Use helper to get state from model
			local m = currentState.mass_kg
			local qx, qy, qz, qw = currentState.cframe:ToQuaternion()
			local isp = {
				pos = {currentState.position.X, currentState.position.Y, currentState.position.Z},
				orient = {qx, qy, qz, qw},
				lin_vel = {currentState.linear_velocity.X, currentState.linear_velocity.Y, currentState.linear_velocity.Z},
				ang_vel = {currentState.angular_velocity.X, currentState.angular_velocity.Y, currentState.angular_velocity.Z},
				mass_kg = m
			}
			currentOriginalRequestId = ClientToServerBridge:RequestTrick({drone_name=myGazeboDroneName,trick_type=trickType,direction=direction,initial_state=isp})

			if not currentOriginalRequestId then
				warn("MainController: RequestTrick failed for '"..MyDrone.Name.."'. Reverting.")
				currentMode="PlayerControl"
                -- if flightModelInstance then flightModelInstance:SetPlayerControl(true) end
			else
				print("MainController: Trick requested for '"..MyDrone.Name.."':",currentOriginalRequestId)
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
		if payload.original_request_id == currentOriginalRequestId and currentMode == "TrickMode" then
			TrickGuidanceController:StartTrick(payload.burst_id, {})
            -- Server now controls if player inputs are applied. Client just signals trick mode.
		end
	end)

	ClientToServerBridge.OnTrickDataChunk.Event:Connect(function(payload)
		if payload.original_request_id == currentOriginalRequestId and currentMode == "TrickMode" and payload.burst_id == TrickGuidanceController:GetCurrentBurstId() then
			TrickGuidanceController:AddFrames(payload.burst_id, payload.frames)
		end
	end)

	ClientToServerBridge.OnTrickDataEnded.Event:Connect(function(payload)
		if payload.original_request_id == currentOriginalRequestId and currentMode == "TrickMode" and payload.burst_id == TrickGuidanceController:GetCurrentBurstId() then
			TrickGuidanceController:EndTrick(payload.burst_id)
			currentMode = "PlayerControl"
			currentOriginalRequestId = nil
			-- Server will resume taking player inputs.
            -- if flightModelInstance then flightModelInstance:SetPlayerControl(true) end
		end
	end)

	ClientToServerBridge.OnTrickError.Event:Connect(function(payload)
		if payload.original_request_id == currentOriginalRequestId and currentMode == "TrickMode" then
			if TrickGuidanceController:IsActive() then
				TrickGuidanceController:EndTrick(TrickGuidanceController:GetCurrentBurstId(), true)
			end
			currentMode = "PlayerControl"
			currentOriginalRequestId = nil
            -- Server will resume taking player inputs.
			-- if flightModelInstance then flightModelInstance:SetPlayerControl(true) end
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

        -- Client no longer checks for anchoring to skip physics, server handles that.
		-- if MyDrone.PrimaryPart and MyDrone.PrimaryPart.Anchored then ... return end

		if currentMode == "PlayerControl" then
			if inputControllerRef and ClientToServerBridge then
				local inputs = inputControllerRef:GetInputs()
				ClientToServerBridge:SendDroneInputs(inputs) -- Send inputs to server
                -- DO NOT CALL: flightModelInstance:Update(deltaTime, inputs.throttle, inputs.roll, inputs.pitch, inputs.yaw)
			else
				if doLog then print("Heartbeat: inputControllerRef or ClientToServerBridge MISSING") end
			end
            
            -- Log current state read from replicated drone
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

		elseif currentMode == "TrickMode" then
            -- TrickGuidanceController:Update on client now does not apply forces directly.
            -- It might update its internal state or prepare data if it were to send targets to server.
            -- For now, it's mostly passive on the client side for physics.
			if TrickGuidanceController:IsActive() then
                local droneCurrentState = getDroneCurrentState(MyDrone)
				local guiding = TrickGuidanceController:Update(deltaTime,droneCurrentState.cframe,droneCurrentState.linear_velocity,droneCurrentState.angular_velocity)
				if not guiding and TrickGuidanceController:IsTrickCompleteOrError() then
					currentMode="PlayerControl"; currentOriginalRequestId=nil;
					if doLog then print("MainController: Trick ended or errored (client state), back to PlayerControl.") end
				end
			end
		elseif currentMode == "AssistanceMode" then
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
			DroneViewController:Update(deltaTime) -- Allow cleanup if drone becomes nil
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