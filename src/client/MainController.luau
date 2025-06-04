-- src/client/MainController.luau (ModuleScript)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui") -- Correct service name
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- script.Parent here will be the "Client" LocalScript (from init.client.luau)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local ClientToServerBridge = require(script.Parent.ClientToServerBridge) 
-- InputController will be passed in via Start dependencies
-- local InputController = require(script.Parent.InputController) 
local DroneViewController = require(script.Parent.DroneViewController) 
local CustomFlightModel = require(ReplicatedStorage.Shared.DronePhysics.CustomFlightModel) 
local TrickGuidanceController = require(ReplicatedStorage.Shared.DronePhysics.TrickGuidanceController)
-- local AssistanceController = require(ReplicatedStorage.Shared.DronePhysics.AssistanceController)

local MainController = {}

local player = nil -- Will be set by Start()
local MyDrone = nil 
local myGazeboDroneName = nil 

local currentMode = "PlayerControl" 
local currentOriginalRequestId = nil 
local droneInitialized = false
local heartbeatConnection = nil
local inputControllerRef = nil -- To store the passed InputController

local function findPlayerDroneAndInitialize()
	if droneInitialized then return end
	if not player then 
		warn("MainController: Player object not set in findPlayerDroneAndInitialize. Cannot proceed.")
		return 
	end

	local expectedDroneName = "PlayerDrone_" .. player.Name
	local droneInstance = Workspace:FindFirstChild(expectedDroneName)

	if not droneInstance then
		print("MainController: Player drone '", expectedDroneName, "' not found yet in Workspace. Will retry via Heartbeat.")
		return -- Exit here, Heartbeat will call again
	end

    -- Drone instance found, now check for Body or PrimaryPart
	local droneBody = droneInstance:FindFirstChild("Body") -- Prefer "Body" as per original logic
    if not droneBody then
        droneBody = droneInstance.PrimaryPart -- Fallback to PrimaryPart
        if droneBody then
            print("MainController: Player drone '", expectedDroneName, "' found. 'Body' part missing, falling back to PrimaryPart '", droneBody.Name, "'.")
        else
            warn("MainController: Player drone '", expectedDroneName, "' found, but NEITHER 'Body' part NOR PrimaryPart found. Cannot initialize this attempt.")
            return -- Cannot proceed without a body/primary part for this attempt
        end
    end

    -- At this point, droneInstance is valid, and droneBody (either "Body" or PrimaryPart) is valid.
	MyDrone = droneInstance -- Assign to module-level variable
	print("MainController: Player drone '", MyDrone.Name, "' identified with body/primary part '", droneBody.Name, "'. Proceeding with initialization.")

    -- GazeboDroneName logic
    local gazeboNameTag = MyDrone:FindFirstChild("GazeboDroneName")
    if gazeboNameTag and gazeboNameTag:IsA("StringValue") and gazeboNameTag.Value ~= "" then
        myGazeboDroneName = gazeboNameTag.Value
    else
        warn("MainController: Player drone '"..MyDrone.Name.."' found, but 'GazeboDroneName' StringValue tag is missing/empty!")
        if gazeboNameTag then 
            local conn 
            conn = gazeboNameTag:GetPropertyChangedSignal("Value"):Connect(function()
                if gazeboNameTag.Value ~= "" then 
					myGazeboDroneName = gazeboNameTag.Value
					print("MainController: GazeboDroneName updated for '"..MyDrone.Name.."':", myGazeboDroneName)
					if conn then conn:Disconnect() end 
				end
            end)
            task.delay(5, function() if conn and conn.Connected then conn:Disconnect(); print("MainController: GazeboDroneName listener timed out for '"..MyDrone.Name.."'.") end end)
        end
    end
    print("MainController: Gazebo Ref for drone '", MyDrone.Name, "':", myGazeboDroneName or "PENDING")
	
	local cfmInitSuccess = CustomFlightModel:Initialize(MyDrone)
	if not cfmInitSuccess then 
		warn("MainController: CustomFlightModel:Initialize FAILED for '", MyDrone.Name, "'. Aborting further initialization for this attempt.")
		MyDrone = nil -- Important: un-set MyDrone if CFM fails, so Heartbeat doesn't use a partially init'd drone
		return 
	end
	print("MainController: CustomFlightModel initialized for '", MyDrone.Name, "'.")

	TrickGuidanceController:Initialize(MyDrone, CustomFlightModel)
	print("MainController: TrickGuidanceController initialized for '", MyDrone.Name, "'.")

    -- Use the determined droneBody for DroneViewController
	DroneViewController:Initialize(MyDrone, droneBody) 
	print("MainController: DroneViewController initialized for '", MyDrone.Name, "' with target '", droneBody.Name, "'.")
	
	if inputControllerRef then
		inputControllerRef:Initialize() 
		inputControllerRef.TrickButtonPressed:Connect(function(trickType, direction)
			if currentMode ~= "PlayerControl" or not MyDrone or not myGazeboDroneName or myGazeboDroneName == "" or not CustomFlightModel.IsInitialized then return end
			print("MainController: Trick button pressed - ", trickType, direction, "for drone '"..MyDrone.Name.."'")
			currentMode = "TrickMode"; CustomFlightModel:SetPlayerControl(false) 
			local cs = CustomFlightModel:GetCurrentState(); local m = cs.mass_kg
			local isp = {pos={cs.position.X,cs.position.Y,cs.position.Z},orient={cs.cframe.Rotation:ToQuaternion()},lin_vel={cs.linear_velocity.X,cs.linear_velocity.Y,cs.linear_velocity.Z},ang_vel={cs.angular_velocity.X,cs.angular_velocity.Y,cs.angular_velocity.Z},mass_kg=m}
			currentOriginalRequestId = ClientToServerBridge:RequestTrick({drone_name=myGazeboDroneName,trick_type=trickType,direction=direction,initial_state=isp})
			if not currentOriginalRequestId then 
				warn("MainController: RequestTrick failed for '"..MyDrone.Name.."'. Reverting to PlayerControl.")
				currentMode="PlayerControl";CustomFlightModel:SetPlayerControl(true) 
			else 
				print("MainController: Trick requested for '"..MyDrone.Name.."':",currentOriginalRequestId) 
			end
		end)
		print("MainController: InputController initialized and connected for '", MyDrone.Name, "'.")
	else
		warn("MainController: InputController reference not provided during Start(). Input will not work for '", (MyDrone and MyDrone.Name or expectedDroneName), "'.")
	end

	droneInitialized = true
	print("MainController: Full drone initialization complete for '", MyDrone.Name, "'.")
end

function MainController:Start(dependencies)
	player = dependencies.Player
	inputControllerRef = dependencies.InputController -- Store reference

	if not player then
		warn("MainController:Start() - Player object was not provided in dependencies.")
		return
	end
	print("MainController: Start called for player", player.Name)

	-- Trick Handling Events
	ClientToServerBridge.OnTrickDataStarted.Event:Connect(function(payload) if payload.original_request_id==currentOriginalRequestId and currentMode=="TrickMode" then TrickGuidanceController:StartTrick(payload.burst_id,{}) end end)
	ClientToServerBridge.OnTrickDataChunk.Event:Connect(function(payload) if payload.original_request_id==currentOriginalRequestId and currentMode=="TrickMode" and payload.burst_id==TrickGuidanceController:GetCurrentBurstId() then TrickGuidanceController:AddFrames(payload.burst_id,payload.frames) end end)
	ClientToServerBridge.OnTrickDataEnded.Event:Connect(function(payload) if payload.original_request_id==currentOriginalRequestId and currentMode=="TrickMode" and payload.burst_id==TrickGuidanceController:GetCurrentBurstId() then TrickGuidanceController:EndTrick(payload.burst_id);currentMode="PlayerControl";currentOriginalRequestId=nil end end)
	ClientToServerBridge.OnTrickError.Event:Connect(function(payload) if payload.original_request_id==currentOriginalRequestId and currentMode=="TrickMode" then if TrickGuidanceController:IsActive()then TrickGuidanceController:EndTrick(TrickGuidanceController:GetCurrentBurstId(),true)end;currentMode="PlayerControl";currentOriginalRequestId=nil end end)

	-- Main game loop
	if heartbeatConnection and heartbeatConnection.Connected then heartbeatConnection:Disconnect() end
	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if not droneInitialized then findPlayerDroneAndInitialize(); return end
		if not MyDrone or not MyDrone.Parent or not CustomFlightModel.IsInitialized then return end
		
		local droneCurrentState = CustomFlightModel:GetCurrentState()

		if currentMode == "PlayerControl" then
			if inputControllerRef then
				local inputs = inputControllerRef:GetInputs()
				CustomFlightModel:Update(deltaTime, inputs.throttle, inputs.roll, inputs.pitch, inputs.yaw)
			else
				CustomFlightModel:Update(deltaTime, 0,0,0,0) -- No input if controller missing
			end
			
			if not droneCurrentState.isStable then
				warn("MainController: Safe envelope breached!", droneCurrentState.breachReason)
				currentMode = "AssistanceMode"; CustomFlightModel:SetAssistanceMode(true)
				print("MainController: TODO - Request Gazebo assistance for", droneCurrentState.breachReason)
                task.wait(0.1); warn("Assistance reverting."); currentMode="PlayerControl"; CustomFlightModel:SetAssistanceMode(false)
			end
		elseif currentMode == "TrickMode" then
			if TrickGuidanceController:IsActive() then
				local guiding = TrickGuidanceController:Update(deltaTime,droneCurrentState.cframe,droneCurrentState.linear_velocity,droneCurrentState.angular_velocity)
				if not guiding and TrickGuidanceController:IsTrickCompleteOrError() then currentMode="PlayerControl";currentOriginalRequestId=nil end
			end
		elseif currentMode == "AssistanceMode" then
			print("Assistance Mode - logic pending"); task.wait(0.1); warn("Assistance reverting."); currentMode="PlayerControl"; CustomFlightModel:SetAssistanceMode(false)
		end
		
		if DroneViewController then DroneViewController:Update(deltaTime) end
	end)

	-- Initial attempt to find drone after a short delay, Heartbeat will continue trying
	if not droneInitialized then 
		task.wait(0.5) -- Wait a bit for Workspace replication
		findPlayerDroneAndInitialize()
	end
	
	print("MainController module started and Heartbeat connected.")
end

-- No script.Destroying here, init.client.luau would manage global cleanup if needed
-- or this module could return a :Cleanup() method

return MainController