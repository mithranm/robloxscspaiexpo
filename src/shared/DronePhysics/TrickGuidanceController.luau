-- src/shared/DronePhysics/TrickGuidanceController.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- local Workspace = game:GetService("Workspace") -- Not directly used, remove or prefix
local Config = require(ReplicatedStorage.Shared.Config)

local TrickGuidanceController = {}
TrickGuidanceController.__index = TrickGuidanceController

local droneInstance = nil
local droneBody = nil
-- local customFlightModelRef = nil -- No longer directly used to apply forces on client

local isActive = false
local currentBurstId = nil
local trajectoryFrames = {}
local currentFrameIndex = 1
local timeIntoCurrentSegment = 0
local isCompleteOrError = false

-- Helper to get quaternion components from a CFrame
local function _getCFrameQuaternion(cf: CFrame): (number, number, number, number)
    local _, _, _, R00, R01, R02, R10, R11, R12, R20, R21, R22 = cf:GetComponents()
    local trace = R00 + R11 + R22
    local S, qw, qx, qy, qz
    if trace > 0 then S = math.sqrt(trace + 1.0) * 2; qw = 0.25 * S; qx = (R21 - R12) / S; qy = (R02 - R20) / S; qz = (R10 - R01) / S
    elseif (R00 > R11) and (R00 > R22) then S = math.sqrt(1.0 + R00 - R11 - R22) * 2; qw = (R21 - R12) / S; qx = 0.25 * S; qy = (R01 + R10) / S; qz = (R02 + R20) / S
    elseif R11 > R22 then S = math.sqrt(1.0 + R11 - R00 - R22) * 2; qw = (R02 - R20) / S; qx = (R01 + R10) / S; qy = 0.25 * S; qz = (R12 + R21) / S
    else S = math.sqrt(1.0 + R22 - R00 - R11) * 2; qw = (R10 - R01) / S; qx = (R02 + R20) / S; qy = (R12 + R21) / S; qz = 0.25 * S end
    return qx, qy, qz, qw
end

local function cframeFromPosQuat(pos: Vector3, qOrient: {number}) : CFrame
    if not qOrient or #qOrient < 4 then return CFrame.new(pos) end
    return CFrame.new(pos.X, pos.Y, pos.Z, qOrient[1], qOrient[2], qOrient[3], qOrient[4])
end


-- Initialize no longer takes flightModel
function TrickGuidanceController:Initialize(droneModel)
	droneInstance = droneModel
	droneBody = droneInstance and (droneInstance:FindFirstChild("Body") or droneInstance.PrimaryPart)
	-- customFlightModelRef = flightModel -- Removed
	isActive = false
	isCompleteOrError = false
	print("TrickGuidanceController: Initialized (Client-side). Drone:", droneInstance and droneInstance.Name, ". Physics is server-side; this controller will not apply forces.")
end

function TrickGuidanceController:StartTrick(burstId, initialFrames)
	if not droneBody then
		warn("TrickGuidanceController: Cannot start trick, droneBody not initialized properly.")
		self:EndTrick(burstId, true)
		return
	end

	print("TrickGuidanceController: Starting trick/guidance state for burst:", burstId, "(Client-side, no direct physics control)")
	isActive = true
	isCompleteOrError = false
	currentBurstId = burstId
	trajectoryFrames = initialFrames or {}
	currentFrameIndex = 1
	timeIntoCurrentSegment = 0

	-- Client no longer tells a CFM to stop player control
	-- customFlightModelRef:SetPlayerControl(false)
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
	print("TrickGuidanceController: Ending trick/guidance state for burst:", currentBurstId or burstId, "Error:", tostring(wasError), "(Client-side)")
	isActive = false
	isCompleteOrError = true
    -- Client no longer directly applies forces or tells CFM to resume player control
	-- if customFlightModelRef then
	-- 	customFlightModelRef:ApplyGuidanceForces(Vector3.zero, Vector3.zero)
	-- 	customFlightModelRef:SetPlayerControl(true)
	-- end
	currentBurstId = nil
	trajectoryFrames = {}
	currentFrameIndex = 1
	timeIntoCurrentSegment = 0
end

function TrickGuidanceController:IsActive() return isActive end
function TrickGuidanceController:GetCurrentBurstId() return currentBurstId end
function TrickGuidanceController:IsTrickCompleteOrError() return isCompleteOrError end

function TrickGuidanceController:Update(deltaTime, currentCFrame: CFrame, currentLinVel: Vector3, currentAngVel: Vector3)
	if not isActive or not droneBody then return false end -- No customFlightModelRef check
	if #trajectoryFrames == 0 or currentFrameIndex > #trajectoryFrames then
		-- If we are past the last frame, we just keep returning true until EndTrick is called.
		-- No forces are applied from here anymore.
		return true
	end

	-- Logic to advance through trajectory frames for state tracking (e.g., for UI)
    -- but NO force application.
	local targetFrame = trajectoryFrames[currentFrameIndex]
	local nextTargetFrame = trajectoryFrames[currentFrameIndex + 1]
	timeIntoCurrentSegment += deltaTime

	if nextTargetFrame then
		local segmentDuration = nextTargetFrame.t - targetFrame.t
		if segmentDuration <= 0 then segmentDuration = 0.001 end
		
		if timeIntoCurrentSegment >= segmentDuration then
			currentFrameIndex += 1
			timeIntoCurrentSegment = 0
		end
	else
        -- At the last frame, do nothing further here until EndTrick
	end
    
    -- DO NOT APPLY FORCES:
	-- local interpPos: Vector3 ...
	-- customFlightModelRef:ApplyGuidanceForces(targetForce, targetTorqueWorld)

	return true
end

return TrickGuidanceController