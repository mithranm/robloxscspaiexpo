-- src/client/InputController.luau (ModuleScript)
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local _Config = require(ReplicatedStorage.Shared.Config)
local _Remotes = require(ReplicatedStorage.Shared.Remotes) 

local InputController = {}
InputController.InputState = {throttle = 0, roll = 0, pitch = 0, yaw = 0}
InputController.activeKeyboardInputs = { 
    YawLeft = false, YawRight = false,
    PitchForward = false, PitchBackward = false,
    RollLeft = false, RollRight = false
}
InputController.TrickButtonPressed = Instance.new("BindableEvent")
InputController.ReorientButtonPressed = Instance.new("BindableEvent") 

local currentKeyboardThrottleLevel = 0 
local THROTTLE_ADJUST_INCREMENT = 0.1
local THROTTLE_ADJUST_ACTION_INC = "AdjustThrottleIncrement"
local THROTTLE_ADJUST_ACTION_DEC = "AdjustThrottleDecrement"
local THROTTLE_SET_MIN_ACTION = "SetThrottleMin"
local THROTTLE_SET_MAX_ACTION = "SetThrottleMax"

local player

local lastTrickPressTime = 0
local TRICK_DEBOUNCE_TIME = 0.5 

local lastReorientPressTime = 0
local REORIENT_DEBOUNCE_TIME = 1.0

local gamepadConnected = false
local gamepadThrottle = 0 
local gamepadYaw = 0    
local gamepadPitch = 0  
local gamepadRoll = 0   

local function handleReorientButton(actionName, inputState, inputObject)
    if inputState == Enum.UserInputState.Begin then
        local currentTime = tick()
        if currentTime - lastReorientPressTime < REORIENT_DEBOUNCE_TIME then
            return Enum.ContextActionResult.Sink
        end
        lastReorientPressTime = currentTime
        InputController.ReorientButtonPressed:Fire()
        print("InputController: Fired ReorientButtonPressed")
        return Enum.ContextActionResult.Sink
    end
    return Enum.ContextActionResult.Pass
end


local function handleTrickButton(actionName, inputState, inputObject)
    if inputState == Enum.UserInputState.Begin then
        local currentTime = tick()
        if currentTime - lastTrickPressTime < TRICK_DEBOUNCE_TIME then
            return Enum.ContextActionResult.Sink 
        end
        lastTrickPressTime = currentTime
        if actionName == "TriggerTrick1_Num1" then
            InputController.TrickButtonPressed:Fire("barrel_roll", "RIGHT")
        elseif actionName == "TriggerTrick2_Num2" then 
            InputController.TrickButtonPressed:Fire("barrel_roll", "LEFT")
        end
        return Enum.ContextActionResult.Sink
    end
    return Enum.ContextActionResult.Pass
end

local function handleThrottleAdjustAction(actionName, inputState, inputObject, adjustment)
    if inputState == Enum.UserInputState.Begin then
        currentKeyboardThrottleLevel = math.clamp(currentKeyboardThrottleLevel + adjustment, 0, 1)
        return Enum.ContextActionResult.Sink
    end
    return Enum.ContextActionResult.Pass
end

local function handleThrottleSetAction(actionName, inputState, inputObject, value)
    if inputState == Enum.UserInputState.Begin then
        currentKeyboardThrottleLevel = math.clamp(value, 0, 1)
        return Enum.ContextActionResult.Sink
    end
    return Enum.ContextActionResult.Pass
end

function InputController:handleKeyboardFlightControlAction(actionName, inputState, inputObject)
    local isBegin = (inputState == Enum.UserInputState.Begin)
    if self.activeKeyboardInputs[actionName] ~= nil then self.activeKeyboardInputs[actionName] = isBegin
    else return Enum.ContextActionResult.Pass end
    
    if self.activeKeyboardInputs.YawLeft and not self.activeKeyboardInputs.YawRight then self.InputState.yaw = -1
    elseif self.activeKeyboardInputs.YawRight and not self.activeKeyboardInputs.YawLeft then self.InputState.yaw = 1
    else self.InputState.yaw = 0 end 

    if self.activeKeyboardInputs.PitchForward and not self.activeKeyboardInputs.PitchBackward then self.InputState.pitch = 1
    elseif self.activeKeyboardInputs.PitchBackward and not self.activeKeyboardInputs.PitchForward then self.InputState.pitch = -1
    else self.InputState.pitch = 0 end

    if self.activeKeyboardInputs.RollLeft and not self.activeKeyboardInputs.RollRight then self.InputState.roll = -1
    elseif self.activeKeyboardInputs.RollRight and not self.activeKeyboardInputs.RollLeft then self.InputState.roll = 1
    else self.InputState.roll = 0 end
    
    return Enum.ContextActionResult.Pass
end

local function handleGamepadInput(actionName, inputState, inputObject: InputObject)
    if inputObject.UserInputType == Enum.UserInputType.Gamepad1 then
        if inputObject.KeyCode == Enum.KeyCode.ButtonL3 then
            gamepadThrottle = -inputObject.Position.Y 
            gamepadYaw = inputObject.Position.X
        elseif inputObject.KeyCode == Enum.KeyCode.ButtonR3 then
            gamepadPitch = -inputObject.Position.Y 
            gamepadRoll = inputObject.Position.X
        elseif inputObject.KeyCode == Enum.KeyCode.ButtonA and inputState == Enum.UserInputState.Begin then
            local currentTime = tick()
            if currentTime - lastReorientPressTime < REORIENT_DEBOUNCE_TIME then return Enum.ContextActionResult.Pass end
            lastReorientPressTime = currentTime
            InputController.ReorientButtonPressed:Fire()
        end
    end
    return Enum.ContextActionResult.Pass
end


function InputController:Initialize()
    if self.isInitialized then return end
    player = Players.LocalPlayer
    if not player then warn("InputController: LocalPlayer not found."); return end
	
    local function cas_AdjThrInc(a,s,o) return handleThrottleAdjustAction(a,s,o, THROTTLE_ADJUST_INCREMENT) end
    local function cas_AdjThrDec(a,s,o) return handleThrottleAdjustAction(a,s,o, -THROTTLE_ADJUST_INCREMENT) end
    local function cas_SetThrMin(a,s,o) return handleThrottleSetAction(a,s,o, 0) end
    local function cas_SetThrMax(a,s,o) return handleThrottleSetAction(a,s,o, 1) end
	ContextActionService:BindAction(THROTTLE_ADJUST_ACTION_INC, cas_AdjThrInc, false, Enum.KeyCode.E) 
	ContextActionService:BindAction(THROTTLE_ADJUST_ACTION_DEC, cas_AdjThrDec, false, Enum.KeyCode.Q) 
    ContextActionService:BindAction(THROTTLE_SET_MIN_ACTION, cas_SetThrMin, false, Enum.KeyCode.S)    
    ContextActionService:BindAction(THROTTLE_SET_MAX_ACTION, cas_SetThrMax, false, Enum.KeyCode.W)    
    
    ContextActionService:BindAction("TriggerTrick1_Num1", handleTrickButton, false, Enum.KeyCode.One)
	ContextActionService:BindAction("TriggerTrick2_Num2", handleTrickButton, false, Enum.KeyCode.Two)
    ContextActionService:BindAction("ReorientDrone", handleReorientButton, false, Enum.KeyCode.F) 
    
	ContextActionService:BindAction("YawLeft",       function(...) self:handleKeyboardFlightControlAction(...) end, false, Enum.KeyCode.A)
	ContextActionService:BindAction("YawRight",      function(...) self:handleKeyboardFlightControlAction(...) end, false, Enum.KeyCode.D)
	ContextActionService:BindAction("PitchForward",  function(...) self:handleKeyboardFlightControlAction(...) end, false, Enum.KeyCode.Up)
	ContextActionService:BindAction("PitchBackward", function(...) self:handleKeyboardFlightControlAction(...) end, false, Enum.KeyCode.Down)
	ContextActionService:BindAction("RollLeft",      function(...) self:handleKeyboardFlightControlAction(...) end, false, Enum.KeyCode.Left)
	ContextActionService:BindAction("RollRight",     function(...) self:handleKeyboardFlightControlAction(...) end, false, Enum.KeyCode.Right)
    
    ContextActionService:BindAction("GamepadFlightControls", handleGamepadInput, false, 
        Enum.UserInputType.Gamepad1) 

    UserInputService.GamepadConnected:Connect(function(gamepad)
        if gamepad.UserInputType == Enum.UserInputType.Gamepad1 then gamepadConnected = true end
    end)
    UserInputService.GamepadDisconnected:Connect(function(gamepad)
        if gamepad.UserInputType == Enum.UserInputType.Gamepad1 then gamepadConnected = false end
    end)
    gamepadConnected = false
    for _, gamepadEnum in ipairs(UserInputService:GetConnectedGamepads()) do
        if gamepadEnum == Enum.UserInputType.Gamepad1 then
            gamepadConnected = true
            break
        end
    end

    currentKeyboardThrottleLevel = 0; self.InputState.roll = 0; self.InputState.pitch = 0; self.InputState.yaw = 0
    self.isInitialized = true
	print("InputController Initialized. Keyboard: QESW Throttle, A/D Yaw, Arrows Pitch/Roll. Gamepad supported.")
end

function InputController:GetInputs()
    local finalThrottle, finalRoll, finalPitch, finalYaw = 
        currentKeyboardThrottleLevel, self.InputState.roll, self.InputState.pitch, self.InputState.yaw

    if gamepadConnected then
        local deadzone = 0.15
        if math.abs(gamepadThrottle) > deadzone then finalThrottle = (gamepadThrottle + 1) / 2 end 
        if math.abs(gamepadRoll) > deadzone then finalRoll = gamepadRoll end
        if math.abs(gamepadPitch) > deadzone then finalPitch = gamepadPitch end
        if math.abs(gamepadYaw) > deadzone then finalYaw = gamepadYaw end
    end
    
	return {
        throttle = math.clamp(finalThrottle, 0, 1), 
        roll = math.clamp(finalRoll, -1, 1), 
        pitch = math.clamp(finalPitch, -1, 1), 
        yaw = math.clamp(finalYaw, -1, 1)
    }
end

return InputController