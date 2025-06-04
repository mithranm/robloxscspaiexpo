local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local CustomFlightModel = {}
CustomFlightModel.__index = CustomFlightModel

local lastLogTime = {}
local logInterval = 0.5 -- seconds

function CustomFlightModel.new(droneModelInstance)
	local self = setmetatable({}, CustomFlightModel)

	self.IsInitialized = false
	self.ControlMode = "Player" 

	self.droneInstance = droneModelInstance
	self.originalName = (droneModelInstance and droneModelInstance.Name) or ("CFM_Unknown_"..math.random(1000))
	self.droneBody = nil
	self.actualMassKg = Config.DRONE_MASS_KG_DEFAULT 

	self.vectorForce = nil; self.torque = nil; self.bodyAttachment = nil
	self.prevPitchError = 0; self.prevRollError = 0; self.prevYawError = 0
	self.lastAppliedForces = {force = Vector3.zero, torque = Vector3.zero}
	lastLogTime[self] = 0

	if not self:Initialize(droneModelInstance) then
		warn(self.originalName, "CustomFlightModel.new: Initialization failed.")
		return nil
	end
	return self
end

function CustomFlightModel:Initialize(droneModelInstance)
	if not droneModelInstance or not droneModelInstance:IsA("Model") then
		warn(self.originalName, "CFM:Initialize - Invalid drone model.")
		return false
	end
	self.droneInstance = droneModelInstance
	self.droneBody = self.droneInstance:FindFirstChild("Body") or self.droneInstance.PrimaryPart

	if not self.droneBody or not self.droneBody:IsA("BasePart") then
		warn(self.originalName, "CFM:Initialize - Drone model missing 'Body' BasePart or PrimaryPart.")
		return false
	end

	self.droneBody.Massless = false 
	local massTag = self.droneBody:FindFirstChild("ActualMassKg")
	local targetMass = Config.DRONE_MASS_KG_DEFAULT
	if massTag and massTag:IsA("NumberValue") and massTag.Value > 0.001 then targetMass = massTag.Value end
	
	local densityToSet; local volume = self.droneBody.Size.X * self.droneBody.Size.Y * self.droneBody.Size.Z
	if volume > 0.000001 then densityToSet = targetMass / volume else densityToSet = 0.7 end
	self.droneBody.CustomPhysicalProperties = PhysicalProperties.new(densityToSet, 0.5, 0.5, 1, 1) 
    self.actualMassKg = self.droneBody:GetMass() 
	print(self.originalName, "CFM:Initialize - Mass (GetMass):", self.actualMassKg)

	self.bodyAttachment = self.droneBody:FindFirstChild("BodyAttachment")
	if not self.bodyAttachment then
		self.bodyAttachment = Instance.new("Attachment"); self.bodyAttachment.Name = "BodyAttachment"
		self.bodyAttachment.Position = Vector3.zero; self.bodyAttachment.Parent = self.droneBody
	end

	if self.droneBody:FindFirstChild("CustomVectorForce") then self.droneBody.CustomVectorForce:Destroy() end
	self.vectorForce = Instance.new("VectorForce"); self.vectorForce.Name = "CustomVectorForce"
	self.vectorForce.Attachment0 = self.bodyAttachment; self.vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	self.vectorForce.Force = Vector3.zero; self.vectorForce.Enabled = true; self.vectorForce.Parent = self.droneBody

	if self.droneBody:FindFirstChild("CustomTorque") then self.droneBody.CustomTorque:Destroy() end
	self.torque = Instance.new("Torque"); self.torque.Name = "CustomTorque"
	self.torque.Attachment0 = self.bodyAttachment; self.torque.RelativeTo = Enum.ActuatorRelativeTo.World 
	self.torque.Torque = Vector3.zero; self.torque.Enabled = true; self.torque.Parent = self.droneBody

	self.droneBody.AssemblyLinearVelocity = Vector3.zero; self.droneBody.AssemblyAngularVelocity = Vector3.zero
	self.IsInitialized = true; self.ControlMode = "Player" 
	return true
end

function CustomFlightModel:SetControlMode(mode: string)
    if self.ControlMode ~= mode then
        self.ControlMode = mode
        if self.vectorForce and self.torque and self.vectorForce.Parent and self.torque.Parent then
            self.vectorForce.Force = Vector3.zero; self.torque.Torque = Vector3.zero
            self.lastAppliedForces = {force = Vector3.zero, torque = Vector3.zero}
        end
    end
end

function CustomFlightModel:ApplyGuidanceForces(targetWorldForce: Vector3, targetWorldTorque: Vector3, isFinalOverride: boolean?)
	if not self.IsInitialized then return end
    if not isFinalOverride and self.ControlMode ~= "Guidance" then return end
	if not self.droneBody or not self.droneBody.Parent then self.IsInitialized = false; return end
	if not self.vectorForce or not self.torque or not self.vectorForce.Parent or not self.torque.Parent then return end

    if isFinalOverride then 
        self.vectorForce.Force = Vector3.zero; self.torque.Torque = Vector3.zero
    else
        self.vectorForce.Force = targetWorldForce; self.torque.Torque = targetWorldTorque
    end
	self.lastAppliedForces = {force = self.vectorForce.Force, torque = self.torque.Torque}
end

function CustomFlightModel:Update(deltaTime, inputThrottle, inputRoll, inputPitch, inputYaw)
	if not self.IsInitialized or not self.droneBody or not self.droneBody.Parent then return end
    if not self.vectorForce or not self.torque or not self.vectorForce.Parent or not self.torque.Parent then return end
	if self.ControlMode ~= "Player" then return end

	local currentCFrame = self.droneBody.CFrame
	local currentAngVelWorld = self.droneBody.AssemblyAngularVelocity
	local currentLinVelWorld = self.droneBody.AssemblyLinearVelocity
	local currentAngVelLocal = currentCFrame:VectorToObjectSpace(currentAngVelWorld)
	self.actualMassKg = self.droneBody:GetMass() 

	local desiredPitchRate = inputPitch * Config.TARGET_PITCH_RATE_MAX
	local desiredYawRate   = inputYaw   * Config.TARGET_YAW_RATE_MAX 
	local desiredRollRate  = inputRoll  * Config.TARGET_ROLL_RATE_MAX 

	local targetAngVelLocal = Vector3.new(desiredPitchRate, desiredYawRate, desiredRollRate)

	local errorAngVelLocal = targetAngVelLocal - currentAngVelLocal
	local pTorqueLocal = errorAngVelLocal * Config.ATTITUDE_P_GAIN
	local dTorqueLocal = -currentAngVelLocal * Config.ATTITUDE_D_GAIN 
	local netTorqueLocal = pTorqueLocal + dTorqueLocal
	local netTorqueWorld = currentCFrame:VectorToWorldSpace(netTorqueLocal)

    -- Altitude-based thrust scaling
    local effectiveMaxThrust = Config.MAX_THRUST_FORCE
    if Config.ALTITUDE_THRUST_SCALING_ENABLED then
        local currentAltitude = self.droneBody.Position.Y
        local altitudeDifference = currentAltitude - Config.REFERENCE_ALTITUDE_FOR_MAX_THRUST
        local thrustEfficiency = 1.0

        if altitudeDifference > 0 then -- Only apply penalty if above reference altitude
            thrustEfficiency = 1.0 - (altitudeDifference * Config.THRUST_FALLOFF_FACTOR_PER_METER)
            thrustEfficiency = math.max(Config.MIN_THRUST_EFFICIENCY_AT_ALTITUDE, thrustEfficiency)
        end
        effectiveMaxThrust = Config.MAX_THRUST_FORCE * thrustEfficiency
    end

	local currentThrustMagnitude = math.max(0, inputThrottle) * effectiveMaxThrust
	local thrustForceWorld = currentCFrame.UpVector * currentThrustMagnitude

	local gravityForce = Vector3.new(0, Config.CUSTOM_GRAVITY_Y * self.actualMassKg, 0)
	local linearDragForce = -currentLinVelWorld * Config.DRAG_COEFFICIENT_LINEAR
	local speed = currentLinVelWorld.Magnitude
	local quadraticDragForce = Vector3.new()
	if speed > 0.01 then quadraticDragForce = -currentLinVelWorld.Unit * speed * speed * Config.DRAG_COEFFICIENT_QUADRATIC end
	local angularDragTorqueWorld = -currentAngVelWorld * Config.DRAG_COEFFICIENT_ANGULAR

	local finalAppliedForce = thrustForceWorld + gravityForce + linearDragForce + quadraticDragForce
    local finalAppliedTorque = netTorqueWorld + angularDragTorqueWorld

	self.vectorForce.Force = finalAppliedForce
	self.torque.Torque = finalAppliedTorque
	self.lastAppliedForces = {force = self.vectorForce.Force, torque = self.torque.Torque}

	if time() - (lastLogTime[self] or 0) > logInterval then
        if Config.ALTITUDE_THRUST_SCALING_ENABLED and (inputThrottle > 0.1 or math.random() < 0.05) then
            -- print(string.format("CFM: Altitude: %.1f, AltDiff: %.1f, ThrustEff: %.2f, EffMaxThrust: %.1f, ActualThrust: %.1f", 
            --    self.droneBody.Position.Y, self.droneBody.Position.Y - Config.REFERENCE_ALTITUDE_FOR_MAX_THRUST,
            --    (effectiveMaxThrust / Config.MAX_THRUST_FORCE), effectiveMaxThrust, currentThrustMagnitude))
        end
        lastLogTime[self] = time()
    end
end

function CustomFlightModel:Cleanup()
	if self.vectorForce and self.vectorForce.Parent then self.vectorForce:Destroy() end; self.vectorForce = nil
	if self.torque and self.torque.Parent then self.torque:Destroy() end; self.torque = nil
	self.IsInitialized = false; self.droneInstance = nil; self.droneBody = nil
end

function CustomFlightModel:GetCurrentState()
	if not self.IsInitialized or not self.droneBody or not self.droneBody.Parent then
		return {cframe = CFrame.new(), position = Vector3.new(),linear_velocity = Vector3.zero, angular_velocity = Vector3.zero, mass_kg = Config.DRONE_MASS_KG_DEFAULT, isStable = false, breachReason = "NOT_INITIALIZED"}
	end
	local body = self.droneBody; local currentCFrame = body.CFrame; local currentPosition = currentCFrame.Position
	local currentLinVel = body.AssemblyLinearVelocity; local currentAngVel = body.AssemblyAngularVelocity; 
    self.actualMassKg = body:GetMass(); local currentMassToReport = self.actualMassKg
	local upVector = currentCFrame.UpVector; local worldUp = Vector3.new(0, 1, 0)
	local tiltAngleRad = math.acos(math.clamp(upVector:Dot(worldUp), -1, 1)); local tiltAngleDeg = math.deg(tiltAngleRad)
	local localAngVel = currentCFrame:VectorToObjectSpace(currentAngVel); local isStable = true; local breachReason = "NONE"
	
    if tiltAngleDeg > Config.MAX_SAFE_ATTITUDE_DEGREES then isStable = false; breachReason = "EXCESSIVE_TILT"
	elseif math.abs(math.deg(localAngVel.X)) > Config.MAX_SAFE_PITCH_RATE_DPS then isStable = false; breachReason = "EXCESSIVE_PITCH_RATE" 
	elseif math.abs(math.deg(localAngVel.Y)) > Config.MAX_SAFE_YAW_RATE_DPS then isStable = false; breachReason = "EXCESSIVE_YAW_RATE" 
	elseif math.abs(math.deg(localAngVel.Z)) > Config.MAX_SAFE_ROLL_RATE_DPS then isStable = false; breachReason = "EXCESSIVE_ROLL_RATE"
    end
    return {cframe = currentCFrame, position = currentPosition, linear_velocity = currentLinVel, angular_velocity = currentAngVel, mass_kg = currentMassToReport, isStable = isStable, breachReason = breachReason, currentTiltDegrees = tiltAngleDeg, localAngularVelocity = localAngVel}
end

return CustomFlightModel