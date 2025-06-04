-- src/client/DroneViewController.luau
local _RunService = game:GetService("RunService")
local _UserInputService = game:GetService("UserInputService") -- For potential future input-based camera adjustments
local Players = game:GetService("Players")

local DroneViewController = {}
DroneViewController.__index = DroneViewController

local droneInstance = nil
local dronePrimaryBody = nil -- The main body part of the drone
local cameraTargetPart = nil -- The specific part the camera will follow (e.g., a dedicated "CameraMount" or the droneBody)

local camera = workspace.CurrentCamera

-- FPV Camera Offset from the cameraTargetPart's CFrame
-- X:0, Y:0.05 (slightly above center of part), Z:-0.1 (slightly in front of part center to simulate lens position)
-- If Z is positive, it's behind the part's origin. Negative is in front.
-- For true FPV, you want it at the 'nose' of the drone.
local FPV_OFFSET_CFRAME = CFrame.new(0, 0.05, -0.02) -- Small offset forward and up from part origin
local FPV_FIELD_OF_VIEW = 80 -- Wider FOV for FPV feel

local previousCameraType = Enum.CameraType.Custom
local previousFieldOfView = 70

function DroneViewController:Initialize(droneModel, primaryBody)
    droneInstance = droneModel
    dronePrimaryBody = primaryBody

    -- Try to find a specific camera part, otherwise default to the primary body
    cameraTargetPart = droneInstance:FindFirstChild("CameraMount") or dronePrimaryBody

    if not cameraTargetPart or not cameraTargetPart:IsA("BasePart") then
        warn("DroneViewController: Could not find a valid cameraTargetPart (CameraMount or primaryBody) on drone:", droneInstance and droneInstance.Name)
        return
    end
    
    previousCameraType = camera.CameraType
    previousFieldOfView = camera.FieldOfView

    camera.CameraType = Enum.CameraType.Scriptable
    camera.FieldOfView = FPV_FIELD_OF_VIEW
    
    -- Ensure the camera subject is not interfering
    camera.CameraSubject = nil 

    print("DroneViewController Initialized for", droneInstance.Name, "- Targeting:", cameraTargetPart.Name)
end

function DroneViewController:Update(deltaTime)
    if not cameraTargetPart or not cameraTargetPart.Parent then
        -- Drone or target part might have been destroyed
        if camera.CameraType == Enum.CameraType.Scriptable then
             self:Cleanup() -- Revert camera if drone is gone
        end
        return
    end

    if camera.CameraType ~= Enum.CameraType.Scriptable then
        -- Someone else changed the camera type, respect it or re-assert scriptable
        -- For now, we'll just stop updating if not scriptable
        return
    end

    -- Set the camera CFrame to be relative to the cameraTargetPart's CFrame
    -- The FPV_OFFSET_CFRAME is applied in the local space of the cameraTargetPart
    camera.CFrame = cameraTargetPart.CFrame * FPV_OFFSET_CFRAME
end

function DroneViewController:Cleanup()
    -- Revert camera settings to what they were before this controller took over
    if camera then
        camera.CameraType = previousCameraType
        camera.FieldOfView = previousFieldOfView
        if Players.LocalPlayer and Players.LocalPlayer.Character and Players.LocalPlayer.Character:FindFirstChild("Humanoid") then
            camera.CameraSubject = Players.LocalPlayer.Character.Humanoid
        end
    end
    droneInstance = nil
    dronePrimaryBody = nil
    cameraTargetPart = nil
    print("DroneViewController Cleaned up and camera reverted.")
end

return DroneViewController