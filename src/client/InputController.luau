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
    YawLeft = false, YawRight = false,       -- 'A' key, 'D' key
    PitchForward = false, PitchBackward = false, -- 'UpArrow' key, 'DownArrow' key
    RollLeft = false, RollRight = false        -- 'LeftArrow' key, 'RightArrow' key
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
    if self.activeKeyboardInputs[actionName] ~= nil then
        self.activeKeyboardInputs[actionName] = isBegin
    else
        warn("InputController:handleKeyboardFlightControlAction - Unknown actionName:", actionName)
        return Enum.ContextActionResult.Pass
    end
    
    -- Yaw: 'A' for Yaw Right, 'D' for Yaw Left.
    -- InputState.yaw: Positive for Yaw Right, Negative for Yaw Left.
    if self.activeKeyboardInputs.YawLeft and not self.activeKeyboardInputs.YawRight then self.InputState.yaw = 1  -- 'A' key = Yaw Right
    elseif self.activeKeyboardInputs.YawRight and not self.activeKeyboardInputs.YawLeft then self.InputState.yaw = -1 -- 'D' key = Yaw Left
    else self.InputState.yaw = 0 end 

    -- Pitch: 'UpArrow' for Pitch Up, 'DownArrow' for Pitch Down.
    -- InputState.pitch: Positive for Pitch Up, Negative for Pitch Down.
    if self.activeKeyboardInputs.PitchForward and not self.activeKeyboardInputs.PitchBackward then self.InputState.pitch = 1  -- 'UpArrow' key = Pitch Up
    elseif self.activeKeyboardInputs.PitchBackward and not self.activeKeyboardInputs.PitchForward then self.InputState.pitch = -1 -- 'DownArrow' key = Pitch Down
    else self.InputState.pitch = 0 end

    -- Roll: 'LeftArrow' for Roll Right, 'RightArrow' for Roll Left.
    -- InputState.roll: Positive for Roll Right, Negative for Roll Left.
    if self.activeKeyboardInputs.RollLeft and not self.activeKeyboardInputs.RollRight then self.InputState.roll = 1  -- 'LeftArrow' key = Roll Right
    elseif self.activeKeyboardInputs.RollRight and not self.activeKeyboardInputs.RollLeft then self.InputState.roll = -1 -- 'RightArrow' key = Roll Left
    else self.InputState.roll = 0 end
    
    return Enum.ContextActionResult.Pass
end

local function handleGamepadInput(actionName, inputState, inputObject: InputObject)
    if inputObject.UserInputType == Enum.UserInputType.Gamepad1 then
        if inputObject.KeyCode == Enum.KeyCode.ButtonL3 then -- Left Stick
            gamepadThrottle = -inputObject.Position.Y -- Stick Up (Y negative) -> positive throttle value for calculation
            gamepadYaw = inputObject.Position.X      -- Stick Right (X positive) -> positive raw yaw input
        elseif inputObject.KeyCode == Enum.KeyCode.ButtonR3 then -- Right Stick
            gamepadPitch = -inputObject.Position.Y -- Stick Up (Y negative) -> positive raw pitch input
            gamepadRoll = inputObject.Position.X   -- Stick Right (X positive) -> positive raw roll input
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
    
    local flightControlHandler = function(actionName, inputState, inputObject)
        return self:handleKeyboardFlightControlAction(actionName, inputState, inputObject)
    end
    
    -- Action names for binding correspond to keys in `activeKeyboardInputs`
	ContextActionService:BindAction("YawLeft",       flightControlHandler, false, Enum.KeyCode.A)          -- 'A' key
	ContextActionService:BindAction("YawRight",      flightControlHandler, false, Enum.KeyCode.D)          -- 'D' key
	ContextActionService:BindAction("PitchForward",  flightControlHandler, false, Enum.KeyCode.Up)         -- 'UpArrow' key
	ContextActionService:BindAction("PitchBackward", flightControlHandler, false, Enum.KeyCode.Down)       -- 'DownArrow' key
	ContextActionService:BindAction("RollLeft",      flightControlHandler, false, Enum.KeyCode.Left)       -- 'LeftArrow' key
	ContextActionService:BindAction("RollRight",     flightControlHandler, false, Enum.KeyCode.Right)      -- 'RightArrow' key
    
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
    local finalThrottle, finalRoll, finalPitch, finalYaw

    if gamepadConnected then
        local deadzone = 0.15
        
        -- Throttle: Left stick Y. gamepadThrottle is -inputObject.Position.Y.
        -- Stick Up (Y negative) -> gamepadThrottle positive raw.
        -- (gamepadThrottle + 1) / 2 maps raw [-1, 1] to final [0, 1]. Correct.
        if math.abs(gamepadThrottle) > deadzone then finalThrottle = (gamepadThrottle + 1) / 2 else finalThrottle = currentKeyboardThrottleLevel end
        
        -- Roll: Right stick X. gamepadRoll is inputObject.Position.X.
        -- Stick Right (X positive) -> gamepadRoll positive raw.
        -- finalRoll should be positive for Roll Right. This is correct.
        if math.abs(gamepadRoll) > deadzone then finalRoll = gamepadRoll else finalRoll = self.InputState.roll end

        -- Pitch: Right stick Y. gamepadPitch is -inputObject.Position.Y.
        -- Stick Up (Y negative) -> gamepadPitch positive raw.
        -- finalPitch should be positive for Pitch Up. This is correct as gamepadPitch is positive for stick up.
        if math.abs(gamepadPitch) > deadzone then finalPitch = gamepadPitch else finalPitch = self.InputState.pitch end
        
        -- Yaw: Left stick X. gamepadYaw is inputObject.Position.X.
        -- Stick Right (X positive) -> gamepadYaw positive raw.
        -- finalYaw should be positive for Yaw Right. This is correct.
        if math.abs(gamepadYaw) > deadzone then finalYaw = gamepadYaw else finalYaw = self.InputState.yaw end
        
    else
        finalThrottle = currentKeyboardThrottleLevel
        finalRoll = self.InputState.roll
        finalPitch = self.InputState.pitch
        finalYaw = self.InputState.yaw
    end
    
	return {
        throttle = math.clamp(finalThrottle, 0, 1), 
        roll = math.clamp(finalRoll, -1, 1), 
        pitch = math.clamp(finalPitch, -1, 1), 
        yaw = math.clamp(finalYaw, -1, 1)
    }
end

return InputController