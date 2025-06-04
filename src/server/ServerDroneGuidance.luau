-- src/server/ServerDroneGuidance.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local ServerDroneGuidance = {}
ServerDroneGuidance.__index = ServerDroneGuidance

function ServerDroneGuidance.new(droneModelInstance, customFlightModelInstance)
	local self = setmetatable({}, ServerDroneGuidance)
	self.droneInstance = droneModelInstance
	self.droneBody = droneModelInstance and (droneModelInstance:FindFirstChild("Body") or droneModelInstance.PrimaryPart)
	self.cfm = customFlightModelInstance 

	self.isActive = false
	self.burstId = nil
	self.trajectoryFrames = {}
	self.currentFrameIndex = 1
	self.timeIntoCurrentSegment = 0
	self.actualMassKg = self.droneBody and self.droneBody:GetMass() or Config.DRONE_MASS_KG_DEFAULT
    if self.actualMassKg < 0.001 then self.actualMassKg = Config.DRONE_MASS_KG_DEFAULT end
    self.startYawCFrame = CFrame.new() 

	if not self.droneBody or not self.cfm or not self.cfm.IsInitialized then
		warn("ServerDroneGuidance.new: Failed initialization - missing droneBody or CFM. Drone:", droneModelInstance and droneModelInstance.Name)
		return nil
	end
	print("ServerDroneGuidance.new: Initialized for", self.droneInstance.Name, "with mass", self.actualMassKg)
	return self
end

function ServerDroneGuidance:StartGuidance(burstId, frames, keepYawFromCFrame)
	if not self.droneBody or not self.cfm then return end
	if self.isActive then self:EndGuidance(true) end

	print("ServerDroneGuidance: Starting guidance for burst:", burstId, "Frames:", #frames, "Drone:", self.droneInstance.Name)
	self.isActive = true
	self.burstId = burstId
	self.trajectoryFrames = frames or {}
	self.currentFrameIndex = 1
	self.timeIntoCurrentSegment = 0
	self.actualMassKg = self.droneBody:GetMass() 
    if self.actualMassKg < 0.001 then self.actualMassKg = Config.DRONE_MASS_KG_DEFAULT end
    
    if keepYawFromCFrame then
        self.startYawCFrame = CFrame.Angles(0, select(2, keepYawFromCFrame:ToOrientation()), 0) 
    else
        self.startYawCFrame = CFrame.Angles(0, select(2, self.droneBody.CFrame:ToOrientation()), 0)
    end
    print("ServerDroneGuidance:StartGuidance - Using mass:", self.actualMassKg, "Start Yaw CFrame:", self.startYawCFrame)

    if #self.trajectoryFrames > 0 and self.burstId and string.sub(self.burstId, 1, 15) == "server_fallback" then -- Only add for fallbacks or specific reorients
        local lastFrame = self.trajectoryFrames[#self.trajectoryFrames]
        local homePos = lastFrame.cframe.Position 
        if string.sub(self.burstId, 1, 15) == "server_fallback" then -- For barrel roll, project slightly forward
            homePos = homePos + (lastFrame.cframe.LookVector * 2) 
        end
        
        local homeOrient = self.startYawCFrame 
        local homeCFrame = CFrame.new(homePos) * homeOrient

        local _, currentLastRoll, currentLastPitch = lastFrame.cframe:ToEulerAnglesXYZ()
        if math.abs(currentLastRoll) > math.rad(5) or math.abs(currentLastPitch) > math.rad(5) or self.burstId == "server_reorient" then -- Add if not level or if it's a reorient command
             table.insert(self.trajectoryFrames, {
                t = lastFrame.t + Config.REORIENT_DURATION, 
                cframe = homeCFrame,
                lin_vel = {0,0,0}, 
                ang_vel = {0,0,0}  
            })
            print("ServerDroneGuidance: Added final reorient frame to trajectory for burst:", self.burstId)
        end
    end
end

function ServerDroneGuidance:EndGuidance(wasAbrupt)
	if not self.isActive then return end
	local droneName = self.droneInstance and self.droneInstance.Name or "N/A"
	print("ServerDroneGuidance: Ending guidance for burst:", self.burstId, "Abrupt:", tostring(wasAbrupt), "Drone:", droneName)
	self.isActive = false
	
    if self.cfm and self.cfm.ApplyGuidanceForces then
	    self.cfm:ApplyGuidanceForces(Vector3.zero, Vector3.zero, true) 
    end

	self.burstId = nil
	self.trajectoryFrames = {}
	self.currentFrameIndex = 1
	self.timeIntoCurrentSegment = 0
end

function ServerDroneGuidance:IsActive()
	return self.isActive
end

function ServerDroneGuidance:Update(deltaTime)
	if not self.isActive or not self.droneBody or not self.droneBody.Parent or not self.cfm then
		if self.isActive then self:EndGuidance(true) end
		return false 
	end

	if #self.trajectoryFrames == 0 or self.currentFrameIndex > #self.trajectoryFrames then
		if #self.trajectoryFrames > 0 and self.currentFrameIndex > #self.trajectoryFrames then
			print("ServerDroneGuidance:Update - Reached end of trajectory for burst:", self.burstId)
		elseif #self.trajectoryFrames == 0 then
            print("ServerDroneGuidance:Update - Active but no trajectory frames for burst:", self.burstId)
        end
		self:EndGuidance(false)
		return false 
	end

	local currentCFrame = self.droneBody.CFrame
	local currentLinVel = self.droneBody.AssemblyLinearVelocity
	local currentAngVel = self.droneBody.AssemblyAngularVelocity
    self.actualMassKg = self.droneBody:GetMass() 
    if self.actualMassKg < 0.001 then self.actualMassKg = Config.DRONE_MASS_KG_DEFAULT end

	local targetFrameData = self.trajectoryFrames[self.currentFrameIndex]
	local nextFrameData = self.trajectoryFrames[self.currentFrameIndex + 1]

	local interpPos: Vector3; local interpLinVel: Vector3
	local interpAngVelWorld: Vector3; local interpOrientation: CFrame
    local currentKpRot, currentKdRot = Config.GUIDANCE_ROT_KP, Config.GUIDANCE_ROT_KD

    -- Use reorient gains if this is the last segment and it's a reorienting frame
    if not nextFrameData and self.burstId and (string.sub(self.burstId, 1, 15) == "server_fallback" or string.sub(self.burstId, 1,16) == "server_reorient_") then
        if targetFrameData.lin_vel[1] == 0 and targetFrameData.lin_vel[2] == 0 and targetFrameData.lin_vel[3] == 0 then
            currentKpRot = Config.REORIENT_ROT_KP
            currentKdRot = Config.REORIENT_ROT_KD
        end
    end


	self.timeIntoCurrentSegment += deltaTime

	if nextFrameData then
		local segmentDuration = nextFrameData.t - targetFrameData.t
		if segmentDuration <= 0.0001 then segmentDuration = 0.0001 end
		local alpha = math.clamp(self.timeIntoCurrentSegment / segmentDuration, 0, 1)
		interpPos = targetFrameData.cframe.Position:Lerp(nextFrameData.cframe.Position, alpha)
		interpOrientation = targetFrameData.cframe:Lerp(nextFrameData.cframe, alpha)
		local targetLinVelVec = Vector3.new(unpack(targetFrameData.lin_vel))
		local nextLinVelVec = Vector3.new(unpack(nextFrameData.lin_vel))
		interpLinVel = targetLinVelVec:Lerp(nextLinVelVec, alpha)
		local targetAngVelVec = Vector3.new(unpack(targetFrameData.ang_vel))
		local nextAngVelVec = Vector3.new(unpack(nextFrameData.ang_vel))
		interpAngVelWorld = targetAngVelVec:Lerp(nextAngVelVec, alpha)

		if self.timeIntoCurrentSegment >= segmentDuration then
			self.currentFrameIndex += 1; self.timeIntoCurrentSegment = 0
		end
	else
		interpPos = targetFrameData.cframe.Position; interpOrientation = targetFrameData.cframe
		interpLinVel = Vector3.new(unpack(targetFrameData.lin_vel))
		interpAngVelWorld = Vector3.new(unpack(targetFrameData.ang_vel))
        local holdDuration = Config.REORIENT_DURATION * 0.5
        if self.burstId and string.sub(self.burstId,1,15) ~= "server_fallback" and string.sub(self.burstId,1,16) ~= "server_reorient_" then
            holdDuration = 0.1 -- Shorter hold for non-reorient last frames
        end
		if self.timeIntoCurrentSegment > holdDuration then self.currentFrameIndex +=1 end 
	end

	local posError = interpPos - currentCFrame.Position
	local forceP = posError * Config.GUIDANCE_POS_KP
	local velError = interpLinVel - currentLinVel
	local forceD = velError * Config.GUIDANCE_POS_KD
	local pdPosForce = forceP + forceD

    local errorCFrame = interpOrientation * currentCFrame:Inverse()
    local axis, angle = errorCFrame:ToAxisAngle()
    local rotErrorAxisAngle = axis * angle
	local torquePRot = rotErrorAxisAngle * currentKpRot 
    local angVelErrorWorld = interpAngVelWorld - currentAngVel 
	local torqueDRot = angVelErrorWorld * currentKdRot 
	local pdRotTorque = torquePRot + torqueDRot
    
    local gravityCompensationForce = Vector3.new(0, -Config.CUSTOM_GRAVITY_Y * self.actualMassKg, 0)
    local finalTargetForce = pdPosForce + gravityCompensationForce
    
	self.cfm:ApplyGuidanceForces(finalTargetForce, pdRotTorque)

	return true 
end

function ServerDroneGuidance.generatePreProgrammedBarrelRoll(startCFrame: CFrame, direction: string, duration: number, steps: number)
	local frames = {}
	local totalRotation = math.rad(360) * (direction == "LEFT" and 1 or -1)
	local forwardMovementPerSecond = 5
	local rollAxisWorld = startCFrame.LookVector
    local initialYawCFrame = CFrame.Angles(0, select(2, startCFrame:ToOrientation()), 0)

	for i = 0, steps -1 do 
		local t = (i / steps) * duration; local fraction = i / steps
        local currentRotationDelta = CFrame.fromAxisAngle(rollAxisWorld, totalRotation * fraction)
		local targetOrientation = currentRotationDelta * startCFrame.Rotation
		local currentPosition = startCFrame.Position + startCFrame.LookVector * (forwardMovementPerSecond * t)
		local frameCFrame = CFrame.new(currentPosition) * targetOrientation
        local worldLinVel = startCFrame.LookVector * forwardMovementPerSecond
        local worldAngVel = rollAxisWorld * (totalRotation / duration) 
		table.insert(frames, {t = t, cframe = frameCFrame, lin_vel = {worldLinVel.X, worldLinVel.Y, worldLinVel.Z}, ang_vel = {worldAngVel.X, worldAngVel.Y, worldAngVel.Z}})
	end

    local lastRollFrame = frames[#frames] or {t = 0, cframe = startCFrame, lin_vel={0,0,0}} 
    local homePosition = lastRollFrame.cframe.Position + (Vector3.new(unpack(lastRollFrame.lin_vel)).Unit * forwardMovementPerSecond * (duration / steps) * 0.5) 
    local homeOrientationCFrame = CFrame.new(homePosition) * initialYawCFrame 
    
    table.insert(frames, {
        t = duration, 
        cframe = homeOrientationCFrame,
        lin_vel = {0,0,0}, 
        ang_vel = {0,0,0}  
    })
	return frames
end

return ServerDroneGuidance