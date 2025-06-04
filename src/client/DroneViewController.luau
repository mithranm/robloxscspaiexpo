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
local FPV_OFFSET_CFRAME = CFrame.new(0, 0.05, -0.02) -- Classic FPV offset (slightly up, slightly in front of mount)
local FPV_FIELD_OF_VIEW = 80 

local previousCameraType = Enum.CameraType.Custom
local previousFieldOfView = 70

local lastPrintTime = 0
local printInterval = 1 -- Print camera CFrame every 1 second

function DroneViewController:Initialize(droneModel, primaryBody)
    droneInstance = droneModel
    dronePrimaryBody = primaryBody

    cameraTargetPart = droneInstance:FindFirstChild("CameraMount") or dronePrimaryBody

    if not cameraTargetPart or not cameraTargetPart:IsA("BasePart") then
        warn("DroneViewController: Could not find a valid cameraTargetPart (CameraMount or primaryBody) on drone:", droneInstance and droneInstance.Name)
        return
    end
    
    previousCameraType = camera.CameraType
    previousFieldOfView = camera.FieldOfView

    camera.CameraType = Enum.CameraType.Scriptable
    camera.FieldOfView = FPV_FIELD_OF_VIEW
    
    camera.CameraSubject = nil 

    print("DroneViewController Initialized for", droneInstance.Name, "- Targeting:", cameraTargetPart.Name, "with Offset:", FPV_OFFSET_CFRAME)
end

function DroneViewController:Update(deltaTime)
    if not cameraTargetPart or not cameraTargetPart.Parent then
        if camera.CameraType == Enum.CameraType.Scriptable then
             self:Cleanup() 
        end
        return
    end

    if camera.CameraType ~= Enum.CameraType.Scriptable then
        return
    end

    camera.CFrame = cameraTargetPart.CFrame * FPV_OFFSET_CFRAME

    -- Throttled log of camera position
    if time() - lastPrintTime > printInterval then
        -- print(string.format("DroneViewController: Camera CFrame: Pos(%.2f, %.2f, %.2f) TargetPart CFrame: Pos(%.2f, %.2f, %.2f)", 
        --     camera.CFrame.Position.X, camera.CFrame.Position.Y, camera.CFrame.Position.Z,
        --     cameraTargetPart.CFrame.Position.X, cameraTargetPart.CFrame.Position.Y, cameraTargetPart.CFrame.Position.Z))
        lastPrintTime = time()
    end
end

function DroneViewController:Cleanup()
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