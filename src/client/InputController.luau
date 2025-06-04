-- src/client/InputController.luau (ModuleScript)
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local InputController = {}
InputController.InputState = { -- For keyboard-derived roll, pitch, yaw
    throttle = 0, -- This will be effectively currentThrottleLevel
    roll = 0,
    pitch = 0,
    yaw = 0
}
InputController.activeInputs = { -- Tracks active keyboard keys for flight controls
    YawLeft = false,
    YawRight = false,
    PitchUp = false,
    PitchDown = false,
    RollLeft = false,
    RollRight = false,
}
InputController.TrickButtonPressed = Instance.new("BindableEvent")

local currentThrottleLevel = 0 -- For keyboard throttle W/S/Q/E
local THROTTLE_ADJUST_INCREMENT = 0.1
local THROTTLE_ADJUST_ACTION_INC = "AdjustThrottleIncrement"
local THROTTLE_ADJUST_ACTION_DEC = "AdjustThrottleDecrement"
local THROTTLE_SET_MIN_ACTION = "SetThrottleMin"
local THROTTLE_SET_MAX_ACTION = "SetThrottleMax"

local player

local function handleTrickButton(actionName, inputState, inputObject)
    if inputState == Enum.UserInputState.Begin then
        print("InputController: handleTrickButton - Action:", actionName, "State:", inputState) -- ADDED DEBUG
        if actionName == "TriggerTrick1_Num1" then 
            InputController.TrickButtonPressed:Fire("barrel_roll", "RIGHT")
            print("InputController: Fired TrickButtonPressed for barrel_roll RIGHT") -- ADDED DEBUG
            return Enum.ContextActionResult.Sink
        elseif actionName == "TriggerTrick2_Num2" then 
            InputController.TrickButtonPressed:Fire("barrel_roll", "LEFT")
            print("InputController: Fired TrickButtonPressed for barrel_roll LEFT") -- ADDED DEBUG
            return Enum.ContextActionResult.Sink
        end
    end
    return Enum.ContextActionResult.Pass
end

local function handleThrottleAdjustAction(actionName, inputState, inputObject, adjustment)
    if inputState == Enum.UserInputState.Begin then
        currentThrottleLevel = math.clamp(currentThrottleLevel + adjustment, 0, 1)
        print(string.format("InputController: handleThrottleAdjustAction: currentThrottleLevel (keyboard) is now %.2f. Action: %s, InputState: %s", currentThrottleLevel, actionName, tostring(inputState)))
        return Enum.ContextActionResult.Sink
    end
    return Enum.ContextActionResult.Pass
end

local function handleThrottleSetAction(actionName, inputState, inputObject, value)
    if inputState == Enum.UserInputState.Begin then
        currentThrottleLevel = math.clamp(value, 0, 1)
        print(string.format("InputController: handleThrottleSetAction: currentThrottleLevel (keyboard) is now %.2f. Action: %s, InputState: %s", currentThrottleLevel, actionName, tostring(inputState)))
        return Enum.ContextActionResult.Sink
    end
    return Enum.ContextActionResult.Pass
end

local function handleTestKeyAction(actionName, inputState, inputObject)
	if inputState == Enum.UserInputState.Begin then 
        print("InputController: TEST KEY ACTION '" .. actionName .. "' FIRED (F key pressed)")
        return Enum.ContextActionResult.Pass
	elseif inputState == Enum.UserInputState.End then 
        print("InputController: TEST KEY ACTION '" .. actionName .. "' ENDED (F key released)")
        return Enum.ContextActionResult.Pass
	end
	return Enum.ContextActionResult.Pass
end

-- This updates InputController.activeInputs AND InputController.InputState for keyboard
function InputController:handleFlightControlAction(actionName, inputState, inputObject)
    local isBegin = (inputState == Enum.UserInputState.Begin)

    if self.activeInputs[actionName] ~= nil then
        self.activeInputs[actionName] = isBegin
    else
        warn("InputController: Unrecognized actionName in handleFlightControlAction:" .. tostring(actionName))
        return Enum.ContextActionResult.Pass
    end

    local oldYaw = self.InputState.yaw
    local oldPitch = self.InputState.pitch
    local oldRoll = self.InputState.roll

    if self.activeInputs.YawLeft and not self.activeInputs.YawRight then self.InputState.yaw = -1
    elseif self.activeInputs.YawRight and not self.activeInputs.YawLeft then self.InputState.yaw = 1
    else self.InputState.yaw = 0
    end

    if self.activeInputs.PitchUp and not self.activeInputs.PitchDown then self.InputState.pitch = 1
    elseif self.activeInputs.PitchDown and not self.activeInputs.PitchUp then self.InputState.pitch = -1
    else self.InputState.pitch = 0
    end

    if self.activeInputs.RollLeft and not self.activeInputs.RollRight then self.InputState.roll = -1
    elseif self.activeInputs.RollRight and not self.activeInputs.RollLeft then self.InputState.roll = 1
    else self.InputState.roll = 0
    end

    if oldYaw ~= self.InputState.yaw or oldPitch ~= self.InputState.pitch or oldRoll ~= self.InputState.roll then
         print(string.format("InputController: FlightControlAction UPDATED InputState (Keyboard) -> T(curr):%.2f Y:%.0f P:%.0f R:%.0f", currentThrottleLevel, self.InputState.yaw, self.InputState.pitch, self.InputState.roll))
    end
    return Enum.ContextActionResult.Pass
end

function InputController:Initialize()
    if self.isInitialized then return end
    player = Players.LocalPlayer
    if not player then warn("InputController: LocalPlayer not found during Initialize."); return end
	
    -- Throttle adjustment/set bindings
    local function cas_AdjustThrottleInc(a,s,o) return handleThrottleAdjustAction(a,s,o, THROTTLE_ADJUST_INCREMENT) end
    local function cas_AdjustThrottleDec(a,s,o) return handleThrottleAdjustAction(a,s,o, -THROTTLE_ADJUST_INCREMENT) end
    local function cas_SetThrottleMin(a,s,o) return handleThrottleSetAction(a,s,o, 0) end
    local function cas_SetThrottleMax(a,s,o) return handleThrottleSetAction(a,s,o, 1) end

	ContextActionService:BindAction(THROTTLE_ADJUST_ACTION_INC, cas_AdjustThrottleInc, false, Enum.KeyCode.E)
	ContextActionService:BindAction(THROTTLE_ADJUST_ACTION_DEC, cas_AdjustThrottleDec, false, Enum.KeyCode.Q)
    ContextActionService:BindAction(THROTTLE_SET_MIN_ACTION, cas_SetThrottleMin, false, Enum.KeyCode.S) 
    ContextActionService:BindAction(THROTTLE_SET_MAX_ACTION, cas_SetThrottleMax, false, Enum.KeyCode.W) 
    
    -- Trick bindings
    ContextActionService:BindAction("TriggerTrick1_Num1", handleTrickButton, false, Enum.KeyCode.One)
	ContextActionService:BindAction("TriggerTrick2_Num2", handleTrickButton, false, Enum.KeyCode.Two)
    
    -- Test key binding
    ContextActionService:BindAction("TestFKey", handleTestKeyAction, false, Enum.KeyCode.F)

    -- Flight control bindings (Keyboard)
	ContextActionService:BindAction("YawLeft", function(...) self:handleFlightControlAction(...) end, false, Enum.KeyCode.A)
	ContextActionService:BindAction("YawRight", function(...) self:handleFlightControlAction(...) end, false, Enum.KeyCode.D)
	ContextActionService:BindAction("PitchUp", function(...) self:handleFlightControlAction(...) end, false, Enum.KeyCode.Up)
	ContextActionService:BindAction("PitchDown", function(...) self:handleFlightControlAction(...) end, false, Enum.KeyCode.Down)
	ContextActionService:BindAction("RollLeft", function(...) self:handleFlightControlAction(...) end, false, Enum.KeyCode.Left)
	ContextActionService:BindAction("RollRight", function(...) self:handleFlightControlAction(...) end, false, Enum.KeyCode.Right)
    
    -- Initialize states
    currentThrottleLevel = 0
    self.InputState.roll = 0
    self.InputState.pitch = 0
    self.InputState.yaw = 0
    
    self.isInitialized = true
	print("InputController Initialized for KEYBOARD ONLY: Q/E/W/S throttle, A/D/Arrows for control, 1/2 tricks.")
end

function InputController:GetInputs()
    print(string.format("InputController:GetInputs() returning -> T:%.2f R:%.2f P:%.2f Y:%.2f",
       currentThrottleLevel, self.InputState.roll, self.InputState.pitch, self.InputState.yaw))

	return {
        throttle = currentThrottleLevel,
        roll = self.InputState.roll,
        pitch = self.InputState.pitch,
        yaw = self.InputState.yaw
    }
end

return InputController