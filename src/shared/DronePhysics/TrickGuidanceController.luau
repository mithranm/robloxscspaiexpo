-- src/shared/DronePhysics/TrickGuidanceController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- local Workspace = game:GetService("Workspace") -- Not directly used, remove or prefix
local Config = require(ReplicatedStorage.Shared.Config)

local TrickGuidanceController = {}
TrickGuidanceController.__index = TrickGuidanceController

local droneInstance = nil
local droneBody = nil
local customFlightModelRef = nil 

local isActive = false
local currentBurstId = nil
local trajectoryFrames = {} 
local currentFrameIndex = 1
-- local _timeSinceLastFrame = 0 -- Prefixed as unused
local timeIntoCurrentSegment = 0
local isCompleteOrError = false

-- Helper to get quaternion components from a CFrame
local function _getCFrameQuaternion(cf: CFrame): (number, number, number, number)
    local _, _, _, R00, R01, R02, R10, R11, R12, R20, R21, R22 = cf:GetComponents()
    -- Conversion from rotation matrix to quaternion (common algorithm)
    local trace = R00 + R11 + R22
    local S, qw, qx, qy, qz
    if trace > 0 then
        S = math.sqrt(trace + 1.0) * 2
        qw = 0.25 * S
        qx = (R21 - R12) / S
        qy = (R02 - R20) / S
        qz = (R10 - R01) / S
    elseif (R00 > R11) and (R00 > R22) then
        S = math.sqrt(1.0 + R00 - R11 - R22) * 2
        qw = (R21 - R12) / S
        qx = 0.25 * S
        qy = (R01 + R10) / S
        qz = (R02 + R20) / S
    elseif R11 > R22 then
        S = math.sqrt(1.0 + R11 - R00 - R22) * 2
        qw = (R02 - R20) / S
        qx = (R01 + R10) / S
        qy = 0.25 * S
        qz = (R12 + R21) / S
    else
        S = math.sqrt(1.0 + R22 - R00 - R11) * 2
        qw = (R10 - R01) / S
        qx = (R02 + R20) / S
        qy = (R12 + R21) / S
        qz = 0.25 * S
    end
    return qx, qy, qz, qw
end

-- Helper: Create CFrame from position Vector3 and quaternion components (array or individual)
local function cframeFromPosQuat(pos: Vector3, qOrient: {number}) : CFrame
    if not qOrient or #qOrient < 4 then return CFrame.new(pos) end
    return CFrame.new(pos.X, pos.Y, pos.Z, qOrient[1], qOrient[2], qOrient[3], qOrient[4])
end


function TrickGuidanceController:Initialize(droneModel, flightModel)
	droneInstance = droneModel
	droneBody = droneInstance and (droneInstance:FindFirstChild("Body") or droneInstance.PrimaryPart)
	customFlightModelRef = flightModel
	isActive = false
	isCompleteOrError = false
	print("TrickGuidanceController: Initialized for drone:", droneInstance and droneInstance.Name)
end

function TrickGuidanceController:StartTrick(burstId, initialFrames)
	if not droneBody or not customFlightModelRef then 
		warn("TrickGuidanceController: Cannot start trick, not initialized properly.")
		self:EndTrick(burstId, true) 
		return 
	end
	
	print("TrickGuidanceController: Starting trick/guidance for burst:", burstId)
	isActive = true
	isCompleteOrError = false
	currentBurstId = burstId
	trajectoryFrames = initialFrames or {}
	currentFrameIndex = 1
	-- _timeSinceLastFrame = 0
	timeIntoCurrentSegment = 0
	
	customFlightModelRef:SetPlayerControl(false) 
end

function TrickGuidanceController:AddFrames(burstId, newFrames)
	if not isActive or burstId ~= currentBurstId then return end
	if newFrames and #newFrames > 0 then
		for _, frame in ipairs(newFrames) do
			table.insert(trajectoryFrames, frame)
		end
	end
end

function TrickGuidanceController:EndTrick(burstId, wasError)
	if burstId ~= currentBurstId and currentBurstId ~= nil then 
		if currentBurstId ~= nil and burstId ~= currentBurstId then return end
	end
	print("TrickGuidanceController: Ending trick/guidance for burst:", currentBurstId or burstId, "Error:", tostring(wasError))
	isActive = false
	isCompleteOrError = true 
	if customFlightModelRef then
		customFlightModelRef:ApplyGuidanceForces(Vector3.zero, Vector3.zero) 
		customFlightModelRef:SetPlayerControl(true) 
	end
    currentBurstId = nil 
	trajectoryFrames = {}
	currentFrameIndex = 1
    timeIntoCurrentSegment = 0
    -- _timeSinceLastFrame = 0
end

function TrickGuidanceController:IsActive() return isActive end
function TrickGuidanceController:GetCurrentBurstId() return currentBurstId end
function TrickGuidanceController:IsTrickCompleteOrError() return isCompleteOrError end

function TrickGuidanceController:Update(deltaTime, currentCFrame: CFrame, currentLinVel: Vector3, currentAngVel: Vector3)
	if not isActive or not droneBody or not customFlightModelRef then return false end 
	if #trajectoryFrames == 0 or currentFrameIndex > #trajectoryFrames then
		if #trajectoryFrames > 0 and currentFrameIndex > #trajectoryFrames then
            local lastFrame = trajectoryFrames[#trajectoryFrames]
            if lastFrame then
                local targetPos = _G.Vector3.new(lastFrame.pos[1], lastFrame.pos[2], lastFrame.pos[3])
                local targetOrientCFrame = cframeFromPosQuat(_G.Vector3.zero(), lastFrame.orient) -- Rotation only
                local targetLinVel = _G.Vector3.new(lastFrame.lin_vel[1], lastFrame.lin_vel[2], lastFrame.lin_vel[3])
                local targetAngVelWorld = targetOrientCFrame:VectorToWorldSpace(_G.Vector3.new(lastFrame.ang_vel[1], lastFrame.ang_vel[2], lastFrame.ang_vel[3]))
                
                local _droneMass = customFlightModelRef:GetCurrentState().mass_kg -- prefixed as unused
    	        local posError = targetPos - currentCFrame.Position
    	        local targetForce = posError * Config.GUIDANCE_POS_KP - (currentLinVel - targetLinVel) * Config.GUIDANCE_POS_KD
    	        local rotErrorCFrame = targetOrientCFrame * currentCFrame.Rotation:Inverse() 
    	        local axis, angle = rotErrorCFrame:ToAxisAngle()
    	        local rotErrorVector = axis * angle 
    	        local angVelError = targetAngVelWorld - currentAngVel 
    	        local targetTorque = rotErrorVector * Config.GUIDANCE_ROT_KP + angVelError * Config.GUIDANCE_ROT_KD
    	        customFlightModelRef:ApplyGuidanceForces(targetForce, targetTorque)
            end
		end
		return true 
	end

	local targetFrame = trajectoryFrames[currentFrameIndex]
	local nextTargetFrame = trajectoryFrames[currentFrameIndex + 1]
	
	timeIntoCurrentSegment += deltaTime

	local interpPos: Vector3
	local interpOrientRot: CFrame -- Just the target rotation CFrame (world space)
	local interpLinVel: Vector3
	local interpAngVelLocal: Vector3

	if nextTargetFrame then
		local segmentDuration = nextTargetFrame.t - targetFrame.t
		if segmentDuration <= 0 then segmentDuration = 0.001 end 
		local alpha = math.clamp(timeIntoCurrentSegment / segmentDuration, 0, 1)

		interpPos = _G.Vector3.new(targetFrame.pos[1], targetFrame.pos[2], targetFrame.pos[3]):Lerp(
			_G.Vector3.new(nextTargetFrame.pos[1], nextTargetFrame.pos[2], nextTargetFrame.pos[3]), alpha
		)
		local rot1 = cframeFromPosQuat(_G.Vector3.zero(), targetFrame.orient) -- CFrame with only rotation
		local rot2 = cframeFromPosQuat(_G.Vector3.zero(), nextTargetFrame.orient) -- CFrame with only rotation
		interpOrientRot = rot1:Lerp(rot2, alpha) 
		
		interpLinVel = _G.Vector3.new(targetFrame.lin_vel[1], targetFrame.lin_vel[2], targetFrame.lin_vel[3]):Lerp(
			_G.Vector3.new(nextTargetFrame.lin_vel[1], nextTargetFrame.lin_vel[2], nextTargetFrame.lin_vel[3]), alpha
		)
		interpAngVelLocal = _G.Vector3.new(targetFrame.ang_vel[1], targetFrame.ang_vel[2], targetFrame.ang_vel[3]):Lerp(
			_G.Vector3.new(nextTargetFrame.ang_vel[1], nextTargetFrame.ang_vel[2], nextTargetFrame.ang_vel[3]), alpha
		)
		
		if timeIntoCurrentSegment >= segmentDuration then
			currentFrameIndex += 1
			timeIntoCurrentSegment = 0 
		end
	else 
		interpPos = _G.Vector3.new(targetFrame.pos[1], targetFrame.pos[2], targetFrame.pos[3])
		interpOrientRot = cframeFromPosQuat(_G.Vector3.zero(), targetFrame.orient)
		interpLinVel = _G.Vector3.new(targetFrame.lin_vel[1], targetFrame.lin_vel[2], targetFrame.lin_vel[3])
		interpAngVelLocal = _G.Vector3.new(targetFrame.ang_vel[1], targetFrame.ang_vel[2], targetFrame.ang_vel[3])
	end

	local _droneMass = customFlightModelRef:GetCurrentState().mass_kg -- prefixed as unused
	local targetWorldCFrame = CFrame.new(interpPos) * interpOrientRot.Rotation 
	
	local posError = targetWorldCFrame.Position - currentCFrame.Position
	local desiredWorldLinVel = interpLinVel 
	local velError = desiredWorldLinVel - currentLinVel
	local targetForce = posError * Config.GUIDANCE_POS_KP + velError * Config.GUIDANCE_POS_KD
	
	local targetWorldRot = targetWorldCFrame.Rotation
	local currentWorldRot = currentCFrame.Rotation
	local rotErrorCFrame = targetWorldRot * currentWorldRot:Inverse()
	local axis, angle = rotErrorCFrame:ToAxisAngle()
	local rotErrorVectorWorld = axis * angle 

	local targetWorldAngVel = targetWorldCFrame:VectorToWorldSpace(interpAngVelLocal) 
	local angVelErrorWorld = targetWorldAngVel - currentAngVel
	
	local targetTorqueWorld = rotErrorVectorWorld * Config.GUIDANCE_ROT_KP + angVelErrorWorld * Config.GUIDANCE_ROT_KD
	
	customFlightModelRef:ApplyGuidanceForces(targetForce, targetTorqueWorld)
	
	return true 
end

return TrickGuidanceController