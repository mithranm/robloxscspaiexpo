-- src/shared/DronePhysics/TrickGuidanceController.luau
-- This module is now heavily simplified. It no longer applies physics on the client.
-- Its primary role, if any, would be to process trajectory data for purely visual interpolation
-- if the server streams it. For a fully server-authoritative model where client just observes,
-- this module might not even be strictly needed by MainController anymore.

local TrickGuidanceController = {}
TrickGuidanceController.__index = TrickGuidanceController

-- Store drone model for potential future visual interpolation needs.
local droneInstance = nil 
local droneBody = nil

function TrickGuidanceController:Initialize(droneModel)
	droneInstance = droneModel
	droneBody = droneInstance and (droneInstance:FindFirstChild("Body") or droneInstance.PrimaryPart)
	print("TrickGuidanceController: Initialized (Client-side, NO PHYSICS). Drone:", droneInstance and droneInstance.Name)
end

-- These functions are now mostly no-ops or for state tracking if server sends detailed info.
-- The client doesn't *act* on this data to control physics.

function TrickGuidanceController:StartTrick(burstId, initialFrames, massForPD_unused)
	-- print("TrickGuidanceController (Client): Notified StartTrick for burst:", burstId, "- Server is authoritative.")
end

function TrickGuidanceController:AddFrames(burstId, newFrames)
	-- print("TrickGuidanceController (Client): Notified AddFrames for burst:", burstId, "- Server is authoritative.")
end

function TrickGuidanceController:EndTrick(burstId, wasError)
	-- print("TrickGuidanceController (Client): Notified EndTrick for burst:", burstId, "Error:", tostring(wasError), "- Server is authoritative.")
end

function TrickGuidanceController:IsActive() 
    -- Client doesn't manage active physics state for tricks anymore.
    -- This might return true if server explicitly tells client a trick is active for UI.
    return false 
end

function TrickGuidanceController:GetCurrentBurstId() 
    return nil -- Client doesn't track this for physics.
end

function TrickGuidanceController:IsTrickCompleteOrError() 
    return true -- Assume complete/error as client doesn't manage this.
end

function TrickGuidanceController:Update(deltaTime, currentCFrame, currentLinVel, currentAngVel)
    -- No-op for physics. Return true to satisfy MainController's old call pattern if it still calls it,
    -- but ideally MainController wouldn't call this during server-auth tricks.
	return true 
end

function TrickGuidanceController:Cleanup()
    -- print("TrickGuidanceController (Client): Cleanup. Drone:", droneInstance and droneInstance.Name or "N/A")
    droneInstance = nil
    droneBody = nil
end

return TrickGuidanceController