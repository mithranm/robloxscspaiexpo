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
local rawGamepad_LeftStickY_Thrust = 0
local rawGamepad_LeftStickX_Roll = 0
local rawGamepad_RightStickY_Pitch = 0
local rawGamepad_RightStickX_Yaw = 0

local lastKeyboardLogTime = 0
local keyboardLogInterval = 1 -- seconds

local function handleReorientButton(actionName, inputState, inputObject)
    if inputState == Enum.UserInputState.Begin then
        local currentTime = tick()
        if currentTime - lastReorientPressTime < REORIENT_DEBOUNCE_TIME then
            return Enum.ContextActionResult.Sink
        end
        lastReorientPressTime = currentTime
        InputController.ReorientButtonPressed:Fire()
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
        
        local trickType = nil
        local direction = nil

        if actionName == "TriggerTrick1_Num1" or actionName == "GamepadBarrelRollRight" then
            trickType = "barrel_roll"
            direction = "RIGHT"
        elseif actionName == "TriggerTrick2_Num2" or actionName == "GamepadBarrelRollLeft" then 
            trickType = "barrel_roll"
            direction = "LEFT"
        end

        if trickType and direction then
            InputController.TrickButtonPressed:Fire(trickType, direction)
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

    if self.activeKeyboardInputs[actionName] == nil then
        warn("InputController:handleKeyboardFlightControlAction - Unknown actionName:", actionName)
        return Enum.ContextActionResult.Pass 
    end

    self.activeKeyboardInputs[actionName] = isBegin 
    
    -- Standard mapping for self.InputState based on raw key presses:
    -- Yaw: A key (YawLeft) -> -1; D key (YawRight) -> +1
    -- Pitch: Up key (PitchForward) -> -1; Down key (PitchBackward) -> +1
    -- Roll: Left key (RollLeft) -> -1; Right key (RollRight) -> +1
    -- The GetInputs() function will handle any necessary inversion for specific controls.
    if self.activeKeyboardInputs.YawLeft and not self.activeKeyboardInputs.YawRight then self.InputState.yaw = -1 
    elseif self.activeKeyboardInputs.YawRight and not self.activeKeyboardInputs.YawLeft then self.InputState.yaw = 1
    else self.InputState.yaw = 0 end 

    if self.activeKeyboardInputs.PitchForward and not self.activeKeyboardInputs.PitchBackward then self.InputState.pitch = -1 
    elseif self.activeKeyboardInputs.PitchBackward and not self.activeKeyboardInputs.PitchForward then self.InputState.pitch = 1 
    else self.InputState.pitch = 0 end

    if self.activeKeyboardInputs.RollLeft and not self.activeKeyboardInputs.RollRight then self.InputState.roll = -1
    elseif self.activeKeyboardInputs.RollRight and not self.activeKeyboardInputs.RollLeft then self.InputState.roll = 1
    else self.InputState.roll = 0 end
    
    if time() - lastKeyboardLogTime > keyboardLogInterval then
        lastKeyboardLogTime = time()
    end

    return Enum.ContextActionResult.Sink 
end

local function handleGamepadInput(actionName, inputState, inputObject: InputObject)
    if inputObject.UserInputType ~= Enum.UserInputType.Gamepad1 then
        return Enum.ContextActionResult.Pass
    end

    if inputObject.KeyCode == Enum.KeyCode.Thumbstick1 then
        rawGamepad_LeftStickY_Thrust = inputObject.Position.Y 
        rawGamepad_LeftStickX_Roll = inputObject.Position.X   
    elseif inputObject.KeyCode == Enum.KeyCode.Thumbstick2 then 
        rawGamepad_RightStickY_Pitch = inputObject.Position.Y 
        rawGamepad_RightStickX_Yaw = inputObject.Position.X   
    end

    if actionName == "GamepadReorient" then
         if inputState == Enum.UserInputState.Begin then
            if inputObject.KeyCode == Enum.KeyCode.ButtonA then 
                local currentTime = tick()
                if currentTime - lastReorientPressTime < REORIENT_DEBOUNCE_TIME then return Enum.ContextActionResult.Sink end
                lastReorientPressTime = currentTime
                InputController.ReorientButtonPressed:Fire()
                return Enum.ContextActionResult.Sink
            end
        end
    end
    
    return Enum.ContextActionResult.Pass
end

function InputController:Initialize()
    if self.isInitialized then return end
    player = Players.LocalPlayer
    if not player then warn("InputController: LocalPlayer not found."); return end
	
    local cas_AdjThrInc = function(a,s,o) return handleThrottleAdjustAction(a,s,o, THROTTLE_ADJUST_INCREMENT) end
    local cas_AdjThrDec = function(a,s,o) return handleThrottleAdjustAction(a,s,o, -THROTTLE_ADJUST_INCREMENT) end
    local cas_SetThrMin = function(a,s,o) return handleThrottleSetAction(a,s,o, 0) end
    local cas_SetThrMax = function(a,s,o) return handleThrottleSetAction(a,s,o, 1) end
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
    
	ContextActionService:BindAction("YawLeft",       flightControlHandler, false, Enum.KeyCode.A)
	ContextActionService:BindAction("YawRight",      flightControlHandler, false, Enum.KeyCode.D)
	ContextActionService:BindAction("PitchForward",  flightControlHandler, false, Enum.KeyCode.Up)     
	ContextActionService:BindAction("PitchBackward", flightControlHandler, false, Enum.KeyCode.Down)   
	ContextActionService:BindAction("RollLeft",      flightControlHandler, false, Enum.KeyCode.Left)
	ContextActionService:BindAction("RollRight",     flightControlHandler, false, Enum.KeyCode.Right)
    
    ContextActionService:BindAction("GamepadEvents", handleGamepadInput, false, Enum.UserInputType.Gamepad1)
    ContextActionService:BindAction("GamepadBarrelRollLeft", handleTrickButton, false, Enum.KeyCode.ButtonL1) 
    ContextActionService:BindAction("GamepadBarrelRollRight", handleTrickButton, false, Enum.KeyCode.ButtonR1) 
    ContextActionService:BindAction("GamepadReorient", handleGamepadInput, false, Enum.KeyCode.ButtonA)

    UserInputService.GamepadConnected:Connect(function(gamepad)
        if gamepad.UserInputType == Enum.UserInputType.Gamepad1 then 
            gamepadConnected = true 
        end
    end)
    UserInputService.GamepadDisconnected:Connect(function(gamepad)
        if gamepad.UserInputType == Enum.UserInputType.Gamepad1 then 
            gamepadConnected = false
            rawGamepad_LeftStickY_Thrust = 0; rawGamepad_LeftStickX_Roll = 0
            rawGamepad_RightStickY_Pitch = 0; rawGamepad_RightStickX_Yaw = 0
        end
    end)
    gamepadConnected = false 
    for _, gamepadEnum in ipairs(UserInputService:GetConnectedGamepads()) do
        if gamepadEnum == Enum.UserInputType.Gamepad1 then gamepadConnected = true; break end
    end

    for key, _ in pairs(self.activeKeyboardInputs) do self.activeKeyboardInputs[key] = false end
    currentKeyboardThrottleLevel = 0; self.InputState.roll = 0; self.InputState.pitch = 0; self.InputState.yaw = 0
    self.isInitialized = true
	print("InputController Initialized. Keyboard & Gamepad logic updated.")
end

function InputController:GetInputs()
    local finalThrottle, finalRoll, finalPitch, finalYaw
    local deadzone = 0.15

    finalThrottle = currentKeyboardThrottleLevel
    finalRoll = self.InputState.roll     -- Keyboard roll: -1 for Left Arrow, +1 for Right Arrow
    finalPitch = self.InputState.pitch    -- Keyboard pitch: -1 for Up Arrow (Nose Down), +1 for Down Arrow (Nose Up)
    finalYaw = self.InputState.yaw       -- Keyboard yaw: -1 for A key (Yaw Left), +1 for D key (Yaw Right)

    local isRollFromGamepad = false
    local isPitchFromGamepad = false
    local isYawFromGamepad = false
    
    if gamepadConnected then
        -- THRUST (Gamepad Left Stick Y)
        -- Raw Up is -1, Raw Down is +1. Mapped: Stick Up (-1) -> Min (0.0); Center (0) -> Hover (0.5); Down (+1) -> Max (1.0).
        if math.abs(rawGamepad_LeftStickY_Thrust) > deadzone then
            finalThrottle = (rawGamepad_LeftStickY_Thrust + 1) / 2 
        end

        -- ROLL (Gamepad Left Stick X)
        -- Raw Left is -1, Raw Right is +1. User "inverted" spec: Raw Left (-1) -> Final Roll Right (+1). So, use -raw.
        if math.abs(rawGamepad_LeftStickX_Roll) > deadzone then 
            finalRoll = -rawGamepad_LeftStickX_Roll 
            isRollFromGamepad = true
        end

        -- PITCH (Gamepad Right Stick Y)
        -- Raw Up is -1, Raw Down is +1. User "inverted" spec: Raw Up (-1) -> Final Pitch Up (+1). So, use -raw.
        if math.abs(rawGamepad_RightStickY_Pitch) > deadzone then 
            finalPitch = -rawGamepad_RightStickY_Pitch 
            isPitchFromGamepad = true
        end
        
        -- YAW (Gamepad Right Stick X)
        -- Raw Left is -1, Raw Right is +1. User "inverted" spec: Raw Left (-1) -> Final Yaw Right (+1). So, use -raw.
        if math.abs(rawGamepad_RightStickX_Yaw) > deadzone then 
            finalYaw = -rawGamepad_RightStickX_Yaw
            isYawFromGamepad = true
        end
    end
    
    -- KEYBOARD SPECIFIC INVERSIONS for Roll and Yaw to match user expectation
    -- The flight model expects:
    --   Positive Roll input -> Rolls drone RIGHT
    --   Positive Yaw input -> Yaws drone RIGHT
    -- Keyboard self.InputState:
    --   Roll: Left Arrow -> -1, Right Arrow -> +1
    --   Yaw: A key -> -1, D key -> +1
    -- To make keyboard Right Arrow roll RIGHT, and D key yaw RIGHT (matching flight model positive convention for rightward movement):
    --   If Right Arrow (+1) should roll right, and D (+1) should yaw right, then NO INVERSION is needed here if flight model handles +1 as right.
    -- The user's report "turning and tilting left and right. (left right arrow and a and d) are switched" when gamepad was fine,
    -- and then "keyboard works the way i expect but controller is reversed" after CFM was changed,
    -- implies the raw self.InputState for keyboard roll/yaw (where +1 is D/RightArrow) should result in +1 command for flight model.
    -- And the gamepad inversions (-rawGamepad_LeftStickX_Roll etc.) should also result in +1 for rightward stick deflection for the flight model.
    
    -- Let's analyze the states:
    -- Initial state: Keyboard A/D and L/R Arrows were switched. Gamepad was OK.
    --    - This meant `InputState.roll/yaw = +1` (from D/RightArrow) was causing LEFT roll/yaw in CFM.
    --    - Gamepad's `-rawX = +1` (from right stick deflection) was causing RIGHT roll/yaw in CFM.
    -- Change 1 (CFM): `desiredRate = -input * MAX_RATE` for roll/yaw.
    --    - Keyboard: `InputState.roll/yaw = +1` -> `input = +1` -> `desiredRate = -1 * MAX_RATE` -> Now causes LEFT roll/yaw. This became "correct" for user.
    --    - Gamepad: `-rawX = +1` -> `input = +1` -> `desiredRate = -1 * MAX_RATE` -> Now causes LEFT roll/yaw. This became "reversed" for user.

    -- Conclusion: The CFM should NOT invert. The gamepad's "user specified inversions" are to align its raw output with the desired *final command value*.
    -- The keyboard's `self.InputState` also provides a "final command value" (-1 for left, +1 for right).
    -- The "switched" keyboard behavior initially meant that `self.InputState.yaw = +1` (D key) was causing left yaw.
    -- This means the flight model inherently interprets +1 yaw command as "yaw left".
    -- To fix: If `self.InputState.yaw = +1` (D key, intent: yaw right) should map to a flight model command that yaws right,
    -- but the flight model interprets +1 command as "yaw left", then the input to CFM needs to be `-self.InputState.yaw`.
    
    -- Keyboard "A" (YawLeft) -> self.InputState.yaw = -1. To make drone yaw left, CFM needs +1. So, finalYaw = -self.InputState.yaw.
    -- Keyboard "D" (YawRight) -> self.InputState.yaw = +1. To make drone yaw right, CFM needs -1. So, finalYaw = -self.InputState.yaw.
    if not isYawFromGamepad and self.InputState.yaw ~= 0 then
        finalYaw = -self.InputState.yaw
    end

    -- Keyboard "LeftArrow" (RollLeft) -> self.InputState.roll = -1. To make drone roll left, CFM needs +1. So, finalRoll = -self.InputState.roll.
    -- Keyboard "RightArrow" (RollRight) -> self.InputState.roll = +1. To make drone roll right, CFM needs -1. So, finalRoll = -self.InputState.roll.
    if not isRollFromGamepad and self.InputState.roll ~= 0 then
        finalRoll = -self.InputState.roll
    end
    
    -- Gamepad logic (`finalRoll = -rawGamepad_LeftStickX_Roll`) means:
    --   If rawGamepad_LeftStickX_Roll = -1 (stick left), finalRoll becomes +1.
    --   If the flight model needs +1 to roll left (as per keyboard analysis), then gamepad stick left correctly makes it roll left.
    -- This means the existing gamepad `-raw...` inversion is correct if the flight model has this "inverted" interpretation.

	return {
        throttle = math.clamp(finalThrottle, 0, 1), 
        roll = math.clamp(finalRoll, -1, 1), 
        pitch = math.clamp(finalPitch, -1, 1), 
        yaw = math.clamp(finalYaw, -1, 1)
    }
end

return InputController