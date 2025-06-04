-- src/shared/DronePhysics/CustomFlightModel.luau
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local CustomFlightModel = {}
CustomFlightModel.__index = CustomFlightModel

CustomFlightModel.IsInitialized = false
CustomFlightModel.IsPlayerControlled = true -- True if player inputs drive it, false if Gazebo guidance is active
CustomFlightModel.IsInAssistanceMode = false -- Specifically for Gazebo assistance

local droneInstance = nil
local droneBody = nil -- Primary part of the drone for physics
local actualMassKg = Config.DRONE_MASS_KG_DEFAULT

-- Physics objects (reused)
local vectorForce = nil
local torque = nil
local bodyAttachment = nil -- Attachment for forces/torques

-- For PD Attitude Control
local prevPitchError = 0
local prevRollError = 0
local prevYawError = 0

function CustomFlightModel:Initialize(droneModelInstance)
	if not droneModelInstance or not droneModelInstance:IsA("Model") then
		warn("CustomFlightModel:Initialize - Invalid drone model instance provided.")
		return false
	end
	droneInstance = droneModelInstance
	droneBody = droneInstance:FindFirstChild("Body") or droneInstance.PrimaryPart

	if not droneBody or not droneBody:IsA("BasePart") then
		warn("CustomFlightModel:Initialize - Drone model missing 'Body' BasePart or PrimaryPart.")
		return false
	end

	local massTag = droneBody:FindFirstChild("ActualMassKg")
	if massTag and massTag:IsA("NumberValue") then
		actualMassKg = massTag.Value
	else
		actualMassKg = Config.DRONE_MASS_KG_DEFAULT
		warn("CustomFlightModel: Using default mass", actualMassKg, "kg for drone", droneInstance.Name)
	end
	
	droneBody.Massless = true -- Ensure it's massless for custom gravity/forces

	-- Setup Attachment if not exists
	bodyAttachment = droneBody:FindFirstChild("BodyAttachment")
	if not bodyAttachment then
		bodyAttachment = Instance.new("Attachment")
		bodyAttachment.Name = "BodyAttachment"
		bodyAttachment.Position = Vector3.new(0,0,0) -- At the center of the body part
		bodyAttachment.Parent = droneBody
	end

	-- Setup VectorForce
	vectorForce = droneBody:FindFirstChild("CustomVectorForce")
	if vectorForce then vectorForce:Destroy() end -- Clear old one
	vectorForce = Instance.new("VectorForce")
	vectorForce.Name = "CustomVectorForce"
	vectorForce.Attachment0 = bodyAttachment
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.Force = Vector3.new(0, 0, 0)
	vectorForce.Enabled = true
	vectorForce.Parent = droneBody

	-- Setup Torque
	torque = droneBody:FindFirstChild("CustomTorque")
	if torque then torque:Destroy() end -- Clear old one
	torque = Instance.new("Torque")
	torque.Name = "CustomTorque"
	torque.Attachment0 = bodyAttachment
	torque.RelativeTo = Enum.ActuatorRelativeTo.World -- Torques are often easier in world space from local calculations
	torque.Torque = Vector3.new(0, 0, 0)
	torque.Enabled = true
	torque.Parent = droneBody
	
	self.IsInitialized = true
	self.IsPlayerControlled = true
	self.IsInAssistanceMode = false
	print("CustomFlightModel: Initialized for drone -", droneInstance.Name, "Mass:", actualMassKg, "kg")
	return true
end

function CustomFlightModel:GetCurrentState()
	if not self.IsInitialized or not droneBody or not droneBody.Parent then
		return {
			cframe = CFrame.new(), position = Vector3.new(),
			linear_velocity = Vector3.new(), angular_velocity = Vector3.new(),
			mass_kg = actualMassKg,
			isStable = false -- Default to not stable if not initialized
		}
	end
	
	local currentCFrame = droneBody.CFrame
	local currentPosition = droneBody.Position
	local currentLinVel = droneBody.AssemblyLinearVelocity
	local currentAngVel = droneBody.AssemblyAngularVelocity

	-- Check safe envelope
	local upVector = currentCFrame.UpVector
	local worldUp = Vector3.new(0, 1, 0)
	local tiltAngleRad = math.acos(math.clamp(upVector:Dot(worldUp), -1, 1))
	local tiltAngleDeg = math.deg(tiltAngleRad)

	local localAngVel = currentCFrame:VectorToObjectSpace(currentAngVel)

	local isStable = true
	local breachReason = "NONE"

	if tiltAngleDeg > Config.MAX_SAFE_ATTITUDE_DEGREES then
		isStable = false
		breachReason = "EXCESSIVE_TILT"
	elseif math.abs(math.deg(localAngVel.X)) > Config.MAX_SAFE_ROLL_RATE_DPS then -- Roll is around local X
		isStable = false
		breachReason = "EXCESSIVE_ROLL_RATE"
	elseif math.abs(math.deg(localAngVel.Y)) > Config.MAX_SAFE_PITCH_RATE_DPS then -- Pitch is around local Y
		isStable = false
		breachReason = "EXCESSIVE_PITCH_RATE"
	elseif math.abs(math.deg(localAngVel.Z)) > Config.MAX_SAFE_YAW_RATE_DPS then -- Yaw is around local Z
		isStable = false
		breachReason = "EXCESSIVE_YAW_RATE"
	end

	return {
		cframe = currentCFrame,
		position = currentPosition,
		linear_velocity = currentLinVel,
		angular_velocity = currentAngVel,
		mass_kg = actualMassKg,
		isStable = isStable,
		breachReason = breachReason,
		currentTiltDegrees = tiltAngleDeg,
		localAngularVelocity = localAngVel -- rad/s
	}
end

function CustomFlightModel:SetPlayerControl(isPlayerInControl)
	self.IsPlayerControlled = isPlayerInControl
	if isPlayerInControl then
		self.IsInAssistanceMode = false -- Player control implies not in assistance
		print(droneInstance and droneInstance.Name, "CustomFlightModel: Player control ENABLED")
	else
		print(droneInstance and droneInstance.Name, "CustomFlightModel: Player control DISABLED (Gazebo guidance active)")
	end
end

function CustomFlightModel:SetAssistanceMode(isAssisting)
    self.IsInAssistanceMode = isAssisting
    self:SetPlayerControl(not isAssisting) -- Assistance mode means player is not in control
end

-- Called by guidance controllers (Trick or Assistance)
function CustomFlightModel:ApplyGuidanceForces(targetWorldForce, targetWorldTorque)
	if not self.IsInitialized or self.IsPlayerControlled then return end -- Only apply if guidance is active

	-- Gravity is always applied
	local gravityForce = Vector3.new(0, Config.CUSTOM_GRAVITY_Y * actualMassKg, 0)
	
	-- Drag (still applies during guidance)
	local velocity = droneBody.AssemblyLinearVelocity
	local angularVelocity = droneBody.AssemblyAngularVelocity
	local linearDragForce = -velocity * Config.DRAG_COEFFICIENT_LINEAR 
	local speed = velocity.Magnitude
	local quadraticDragForce = Vector3.new()
	if speed > 0.01 then quadraticDragForce = -velocity.Unit * speed * speed * Config.DRAG_COEFFICIENT_QUADRATIC end
	local angularDragTorque = -angularVelocity * Config.DRAG_COEFFICIENT_ANGULAR
	
	vectorForce.Force = gravityForce + linearDragForce + quadraticDragForce + targetWorldForce
	torque.Torque = angularDragTorque + targetWorldTorque
end

-- Main update loop when player is controlling
function CustomFlightModel:Update(deltaTime, inputThrottle, inputRoll, inputPitch, inputYaw)
	if not self.IsInitialized or not self.IsPlayerControlled or self.IsInAssistanceMode then
		if not self.IsPlayerControlled then -- If guidance mode, clear any residual player-input forces
			-- Forces/torques are handled by ApplyGuidanceForces
		end
		return
	end
	if not droneBody or not droneBody.Parent then 
		self.IsInitialized = false -- Drone got destroyed
		return
	end

	local currentCFrame = droneBody.CFrame
	local currentAngVelWorld = droneBody.AssemblyAngularVelocity
	local currentAngVelLocal = currentCFrame:VectorToObjectSpace(currentAngVelWorld)

	-- 1. Calculate Target Angular Velocities from Inputs
	-- Inputs are typically -1 to 1. Throttle 0 to 1.
	local targetRollRate = inputRoll * Config.TARGET_ROLL_RATE_MAX
	local targetPitchRate = inputPitch * Config.TARGET_PITCH_RATE_MAX 
	local targetYawRate = inputYaw * Config.TARGET_YAW_RATE_MAX
	
	-- Convert target rates to drone's local axes
	-- For FPV drones, roll input controls roll rate around drone's X-axis
	-- Pitch input controls pitch rate around drone's Y-axis
	-- Yaw input controls yaw rate around drone's Z-axis
	local targetAngVelLocal = Vector3.new(targetRollRate, targetPitchRate, targetYawRate)

	-- 2. Attitude Control (PD Controller for angular velocity)
	local errorAngVelLocal = targetAngVelLocal - currentAngVelLocal
	
	-- P Term
	local pTorqueLocal = errorAngVelLocal * Config.ATTITUDE_P_GAIN
	
	-- D Term (simplified - should use (error - prevError)/dt for true D)
	-- For simplicity here, we are damping based on current local angular velocity error rate
	-- A more robust D term would be:
	-- local pitchRateError = errorAngVelLocal.Y - prevPitchError; prevPitchError = errorAngVelLocal.Y
	-- local rollRateError  = errorAngVelLocal.X - prevRollError;  prevRollError  = errorAngVelLocal.X
	-- local yawRateError   = errorAngVelLocal.Z - prevYawError;   prevYawError   = errorAngVelLocal.Z
	-- local dTorqueLocal = Vector3.new(rollRateError, pitchRateError, yawRateError) * (Config.ATTITUDE_D_GAIN / deltaTime)
	-- For now, simpler D term acting like damping on the error itself:
	local dTorqueLocal = errorAngVelLocal * Config.ATTITUDE_D_GAIN -- This is more like damping on error, not true derivative of error
                                                                -- For a more correct PD on rate:
                                                                -- D = (currentError - prevError) / dt
                                                                -- Torque_D = K_d * ( (targetAngVelLocal - currentAngVelLocal) - (targetAngVelLocal - prevAngVelLocal) ) / dt
                                                                -- Torque_D = K_d * ( prevAngVelLocal - currentAngVelLocal ) / dt
                                                                -- This is essentially damping based on change in angular velocity.
                                                                -- Or simply: Torque_D = -K_d_effective * currentAngVelLocal (damping existing rates)
    -- Let's use a direct damping D-term on current local angular velocity to stabilize
    dTorqueLocal = -currentAngVelLocal * Config.ATTITUDE_D_GAIN

	local netTorqueLocal = pTorqueLocal + dTorqueLocal
	local netTorqueWorld = currentCFrame:VectorToWorldSpace(netTorqueLocal)
	
	-- 3. Thrust Calculation
	-- inputThrottle is 0 to 1 (or -1 to 1 if you allow reverse). Assume 0-1 for upward.
	local currentThrustMagnitude = math.max(0, inputThrottle) * Config.MAX_THRUST_FORCE 
	local thrustForceWorld = currentCFrame.UpVector * currentThrustMagnitude

	-- 4. Gravity
	local gravityForce = Vector3.new(0, Config.CUSTOM_GRAVITY_Y * actualMassKg, 0)

	-- 5. Drag
	local velocity = droneBody.AssemblyLinearVelocity
	local linearDragForce = -velocity * Config.DRAG_COEFFICIENT_LINEAR 
	local speed = velocity.Magnitude
	local quadraticDragForce = Vector3.new()
	if speed > 0.01 then quadraticDragForce = -velocity.Unit * speed * speed * Config.DRAG_COEFFICIENT_QUADRATIC end
	local angularDragTorqueWorld = -currentAngVelWorld * Config.DRAG_COEFFICIENT_ANGULAR -- Damping angular motion in world frame

	-- 6. Apply Forces and Torques
	vectorForce.Force = thrustForceWorld + gravityForce + linearDragForce + quadraticDragForce
	torque.Torque = netTorqueWorld + angularDragTorqueWorld -- Add angular drag to controller torque
end

function CustomFlightModel:Cleanup()
	if vectorForce then vectorForce:Destroy(); vectorForce = nil end
	if torque then torque:Destroy(); torque = nil end
	-- bodyAttachment is parented to droneBody, will be destroyed with it or if droneBody is cleared
	self.IsInitialized = false
	droneInstance = nil
	droneBody = nil
	print("CustomFlightModel: Cleaned up.")
end

return CustomFlightModel