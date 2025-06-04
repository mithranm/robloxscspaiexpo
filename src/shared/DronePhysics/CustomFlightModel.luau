local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local CustomFlightModel = {}
CustomFlightModel.__index = CustomFlightModel

local lastLogTime = {}
local logInterval = 0.5

function CustomFlightModel.new(droneModelInstance)
	local self = setmetatable({}, CustomFlightModel)

	self.IsInitialized = false
	self.IsPlayerControlled = true
	self.IsInAssistanceMode = false

	self.droneInstance = nil
	self.originalName = (droneModelInstance and droneModelInstance.Name) or ("CFM_Unknown_"..math.random(1000))
	self.droneBody = nil
	self.actualMassKg = Config.DRONE_MASS_KG_DEFAULT

	self.vectorForce = nil
	self.torque = nil
	self.bodyAttachment = nil

	self.prevPitchError = 0
	self.prevRollError = 0
	self.prevYawError = 0

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
		warn(self.originalName, "CustomFlightModel:Initialize - Invalid drone model instance provided.")
		return false
	end
	self.droneInstance = droneModelInstance
	self.droneBody = self.droneInstance:FindFirstChild("Body") or self.droneInstance.PrimaryPart

	if not self.droneBody or not self.droneBody:IsA("BasePart") then
		warn(self.originalName, "CustomFlightModel:Initialize - Drone model missing 'Body' BasePart or PrimaryPart.")
		return false
	end

	print(self.originalName, "CustomFlightModel:Initialize - Drone Body:", self.droneBody.Name, "Initial CFrame:", self.droneBody.CFrame, "Anchored:", self.droneBody.Anchored)

	self.droneBody.Massless = false
	print(self.originalName, "CustomFlightModel:Initialize - Set", self.droneBody.Name, ".Massless = false")

	local massTag = self.droneBody:FindFirstChild("ActualMassKg")
	local targetMass = Config.DRONE_MASS_KG_DEFAULT
	if massTag and massTag:IsA("NumberValue") and massTag.Value > 0.001 then
		targetMass = massTag.Value
		print(self.originalName, "CustomFlightModel:Initialize - Using ActualMassKg tag value:", targetMass)
	else
		warn(self.originalName, "CustomFlightModel:Initialize - No valid ActualMassKg tag. CFM internal actualMassKg will be:", self.actualMassKg, ". Will use part's default mass or density for PhysProps.")
		targetMass = self.actualMassKg
	end
	self.actualMassKg = targetMass

	local densityToSet
	local volume = self.droneBody.Size.X * self.droneBody.Size.Y * self.droneBody.Size.Z
	if volume > 0.000001 then
		densityToSet = self.actualMassKg / volume
	else
		warn(self.originalName, "CustomFlightModel:Initialize - Drone body has zero or very small volume. Using default density (0.7) for PhysicalProperties.")
		densityToSet = 0.7
	end
	local physProps = PhysicalProperties.new(densityToSet, 0.5, 0.5, 1, 1)
	self.droneBody.CustomPhysicalProperties = physProps
	print(self.originalName, "CustomFlightModel:Initialize - Set CustomPhysicalProperties. Target Mass:", self.actualMassKg, "Calculated Density:", densityToSet, "Actual Part Mass from GetMass():", self.droneBody:GetMass())


	self.bodyAttachment = self.droneBody:FindFirstChild("BodyAttachment")
	if not self.bodyAttachment then
		self.bodyAttachment = Instance.new("Attachment")
		self.bodyAttachment.Name = "BodyAttachment"
		self.bodyAttachment.Position = Vector3.new(0,0,0)
		self.bodyAttachment.Parent = self.droneBody
		print(self.originalName, "CustomFlightModel:Initialize - Created BodyAttachment.")
	else
		print(self.originalName, "CustomFlightModel:Initialize - Found existing BodyAttachment.")
	end

	if self.droneBody:FindFirstChild("CustomVectorForce") then self.droneBody.CustomVectorForce:Destroy() end
	self.vectorForce = Instance.new("VectorForce")
	self.vectorForce.Name = "CustomVectorForce"
	self.vectorForce.Attachment0 = self.bodyAttachment
	self.vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	self.vectorForce.Force = Vector3.new(0, 0, 0)
	self.vectorForce.Enabled = true
	self.vectorForce.Parent = self.droneBody
	print(self.originalName, "CustomFlightModel:Initialize - Created CustomVectorForce.")

	if self.droneBody:FindFirstChild("CustomTorque") then self.droneBody.CustomTorque:Destroy() end
	self.torque = Instance.new("Torque")
	self.torque.Name = "CustomTorque"
	self.torque.Attachment0 = self.bodyAttachment
	self.torque.RelativeTo = Enum.ActuatorRelativeTo.World
	self.torque.Torque = Vector3.new(0, 0, 0)
	self.torque.Enabled = true
	self.torque.Parent = self.droneBody
	print(self.originalName, "CustomFlightModel:Initialize - Created CustomTorque.")

	self.droneBody.AssemblyLinearVelocity = Vector3.zero
	self.droneBody.AssemblyAngularVelocity = Vector3.zero
	print(self.originalName, "CustomFlightModel:Initialize - Zeroed initial velocities for", self.droneBody.Name)

	self.IsInitialized = true
	self.IsPlayerControlled = true
	self.IsInAssistanceMode = false
	print(self.originalName, "CustomFlightModel: Initialized successfully. Effective Mass (GetMass):", self.droneBody:GetMass(), "kg. CFM actualMassKg:", self.actualMassKg, "kg. Body CFrame:", self.droneBody.CFrame)
	return true
end

function CustomFlightModel:GetCurrentState()
	if not self.IsInitialized or not self.droneBody or not self.droneBody.Parent then
		return {
			cframe = CFrame.new(), position = Vector3.new(),
			linear_velocity = Vector3.new(), angular_velocity = Vector3.new(),
			mass_kg = self.actualMassKg,
			isStable = false,
			breachReason = "NOT_INITIALIZED"
		}
	end

	local currentCFrame = self.droneBody.CFrame
	local currentPosition = currentCFrame.Position
	local currentLinVel = self.droneBody.AssemblyLinearVelocity
	local currentAngVel = self.droneBody.AssemblyAngularVelocity
	local currentMass = self.droneBody:GetMass()

	local upVector = currentCFrame.UpVector
	local worldUp = Vector3.new(0, 1, 0)
	local tiltAngleRad = math.acos(math.clamp(upVector:Dot(worldUp), -1, 1))
	local tiltAngleDeg = math.deg(tiltAngleRad)

	local localAngVel = currentCFrame:VectorToObjectSpace(currentAngVel)

	local isStable = true
	local breachReason = "NONE"

	if tiltAngleDeg > Config.MAX_SAFE_ATTITUDE_DEGREES then isStable = false; breachReason = "EXCESSIVE_TILT"
	elseif math.abs(math.deg(localAngVel.X)) > Config.MAX_SAFE_ROLL_RATE_DPS then isStable = false; breachReason = "EXCESSIVE_ROLL_RATE"
	elseif math.abs(math.deg(localAngVel.Y)) > Config.MAX_SAFE_PITCH_RATE_DPS then isStable = false; breachReason = "EXCESSIVE_PITCH_RATE"
	elseif math.abs(math.deg(localAngVel.Z)) > Config.MAX_SAFE_YAW_RATE_DPS then isStable = false; breachReason = "EXCESSIVE_YAW_RATE" end

	return {
		cframe = currentCFrame, position = currentPosition,
		linear_velocity = currentLinVel, angular_velocity = currentAngVel,
		mass_kg = currentMass, isStable = isStable, breachReason = breachReason,
		currentTiltDegrees = tiltAngleDeg, localAngularVelocity = localAngVel
	}
end

function CustomFlightModel:SetPlayerControl(isPlayerInControl)
	self.IsPlayerControlled = isPlayerInControl
	if isPlayerInControl then
		self.IsInAssistanceMode = false
		print(self.originalName, "CustomFlightModel: Player control ENABLED (Server-side perspective)")
	else
		print(self.originalName, "CustomFlightModel: Player control DISABLED (Server-side perspective, e.g., for trick mode)")
	end
end

function CustomFlightModel:SetAssistanceMode(isAssisting)
	self.IsInAssistanceMode = isAssisting
	self:SetPlayerControl(not isAssisting)
end

function CustomFlightModel:ApplyGuidanceForces(targetWorldForce, targetWorldTorque)
	if not self.IsInitialized or self.IsPlayerControlled then return end
	if not self.droneBody or not self.droneBody.Parent then self.IsInitialized = false; return end
	if not self.vectorForce or not self.torque then
		warn(self.originalName, "CustomFlightModel:ApplyGuidanceForces - Physics objects not ready")
		return
	end

	local currentMass = self.droneBody:GetMass()
	local gravityForce = Vector3.new(0, Config.CUSTOM_GRAVITY_Y * currentMass, 0)

	local velocity = self.droneBody.AssemblyLinearVelocity
	local angularVelocity = self.droneBody.AssemblyAngularVelocity
	local linearDragForce = -velocity * Config.DRAG_COEFFICIENT_LINEAR
	local speed = velocity.Magnitude
	local quadraticDragForce = Vector3.new()
	if speed > 0.01 then quadraticDragForce = -velocity.Unit * speed * speed * Config.DRAG_COEFFICIENT_QUADRATIC end
	local angularDragTorque = -angularVelocity * Config.DRAG_COEFFICIENT_ANGULAR

	self.vectorForce.Force = gravityForce + linearDragForce + quadraticDragForce + targetWorldForce
	self.torque.Torque = angularDragTorque + targetWorldTorque
	self.lastAppliedForces = {force = self.vectorForce.Force, torque = self.torque.Torque}
end

function CustomFlightModel:Update(deltaTime, inputThrottle, inputRoll, inputPitch, inputYaw)
	local env = RunService:IsServer() and "SERVER" or "CLIENT"
	local doLog = false
	local currentDroneMass = -1
	if self.droneBody and self.droneBody.Parent then currentDroneMass = self.droneBody:GetMass() else return end

	if time() - (lastLogTime[self] or 0) > logInterval or inputThrottle ~= 0 or inputRoll ~= 0 or inputPitch ~= 0 or inputYaw ~= 0 then
		doLog = true
		lastLogTime[self] = time()
	end

	if doLog then
		print(string.format("CFM:Update[%s|%s] Init:%s PCtrl:%s Assist:%s In: T:%.2f R:%.2f P:%.2f Y:%.2f Mass:%.3f",
			self.originalName, env, tostring(self.IsInitialized), tostring(self.IsPlayerControlled), tostring(self.IsInAssistanceMode),
			inputThrottle, inputRoll, inputPitch, inputYaw, currentDroneMass))
	end

	if not self.IsInitialized then return end
    -- Server-side physics: self.IsPlayerControlled is now managed by RoSocketServiceHandler's playerControlState
    -- For this CFM:Update, we assume if it's called, inputs should be processed or guidance forces applied.
    -- The IsPlayerControlled flag on the CFM instance itself is less critical here since the caller (RoSocketServiceHandler) manages state.

	if not self.vectorForce or not self.torque then
		warn(self.originalName, "CFM:Update - Physics objects not ready")
		return
	end

	local currentCFrame = self.droneBody.CFrame
	local currentPosition = currentCFrame.Position
	local currentAngVelWorld = self.droneBody.AssemblyAngularVelocity
	local currentLinVelWorld = self.droneBody.AssemblyLinearVelocity
	local currentAngVelLocal = currentCFrame:VectorToObjectSpace(currentAngVelWorld)
	currentDroneMass = self.droneBody:GetMass() -- Re-fetch in case it changed due to external factors (unlikely here)

	if doLog or inputRoll ~=0 or inputPitch ~= 0 or inputYaw ~=0 then
		print(string.format("CFM:Update AngVels - World(%.2f,%.2f,%.2f) Local(%.2f,%.2f,%.2f)",
			currentAngVelWorld.X, currentAngVelWorld.Y, currentAngVelWorld.Z,
			currentAngVelLocal.X, currentAngVelLocal.Y, currentAngVelLocal.Z))
	end

	local targetRollRate = inputRoll * Config.TARGET_ROLL_RATE_MAX
	local targetPitchRate = inputPitch * Config.TARGET_PITCH_RATE_MAX
	local targetYawRate = inputYaw * Config.TARGET_YAW_RATE_MAX
	local targetAngVelLocal = Vector3.new(targetRollRate, targetPitchRate, targetYawRate)

	local errorAngVelLocal = targetAngVelLocal - currentAngVelLocal
	local pTorqueLocal = errorAngVelLocal * Config.ATTITUDE_P_GAIN
	local dTorqueLocal = -currentAngVelLocal * Config.ATTITUDE_D_GAIN
	local netTorqueLocal = pTorqueLocal + dTorqueLocal
	local netTorqueWorld = currentCFrame:VectorToWorldSpace(netTorqueLocal)

	local currentThrustMagnitude = math.max(0, inputThrottle) * Config.MAX_THRUST_FORCE
	local thrustForceWorld = currentCFrame.UpVector * currentThrustMagnitude

	local gravityForce = Vector3.new(0, Config.CUSTOM_GRAVITY_Y * currentDroneMass, 0)

	local linearDragForce = -currentLinVelWorld * Config.DRAG_COEFFICIENT_LINEAR
	local speed = currentLinVelWorld.Magnitude
	local quadraticDragForce = Vector3.new()
	if speed > 0.01 then quadraticDragForce = -currentLinVelWorld.Unit * speed * speed * Config.DRAG_COEFFICIENT_QUADRATIC end
	local angularDragTorqueWorld = -currentAngVelWorld * Config.DRAG_COEFFICIENT_ANGULAR

	local combinedForcesWithOurGravity = thrustForceWorld + gravityForce + linearDragForce + quadraticDragForce

    -- SIMPLIFIED GROUND INTERACTION for server-side physics:
    -- Rely on Roblox's default collision response. Remove custom raycasting and force adjustment.
    -- The Body part should have CanCollide = true.
    local finalAppliedForce = combinedForcesWithOurGravity

	self.vectorForce.Force = finalAppliedForce
	self.torque.Torque = netTorqueWorld + angularDragTorqueWorld
	self.lastAppliedForces = {force = self.vectorForce.Force, torque = self.torque.Torque}

	if doLog then
		print(string.format("CFM:Update[%s|%s] Applied F:(%.1f,%.1f,%.1f) T:(%.1f,%.1f,%.1f) | DronePos:(%.1f,%.1f,%.1f) LinVelY: %.2f",
			self.originalName, env,
			self.vectorForce.Force.X, self.vectorForce.Force.Y, self.vectorForce.Force.Z,
			self.torque.Torque.X, self.torque.Torque.Y, self.torque.Torque.Z,
			currentPosition.X, currentPosition.Y, currentPosition.Z,
			currentLinVelWorld.Y
		))
	end
end

function CustomFlightModel:Cleanup()
	if self.vectorForce then self.vectorForce:Destroy(); self.vectorForce = nil end
	if self.torque then self.torque:Destroy(); self.torque = nil end

	print(self.originalName, "CustomFlightModel: Cleaned up instance.")
	if lastLogTime[self] then lastLogTime[self] = nil end
	self.IsInitialized = false
	self.droneInstance = nil
	self.droneBody = nil
end

return CustomFlightModel