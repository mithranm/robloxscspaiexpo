-- src/client/InputController.luau (ModuleScript)
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local InputController = {}
InputController.InputState = { throttle = 0, roll = 0, pitch = 0, yaw = 0, trick1 = false, trick2 = false }
InputController.TrickButtonPressed = Instance.new("BindableEvent")

local player -- Will be set in Initialize
local touchGui, leftStick, rightStick, trickButton1_Touch -- For touch controls

-- ... (processAnalogInput, updateGamepadInput, handleTouchInput, handleTrickButton functions as before) ...
local function processAnalogInput(rawValue, deadzone) if math.abs(rawValue) < deadzone then return 0 end; return math.sign(rawValue) * (math.abs(rawValue) - deadzone) / (1 - deadzone) end
local function updateGamepadInput()
	local gamepads = UserInputService:GetGamepads()
	if #gamepads > 0 then
		local gamepad = gamepads[1] 
		InputController.InputState.throttle = processAnalogInput(-gamepad:GetState().LeftStick.Y, Config.INPUT_DEADZONE_STICK) * Config.GAMEPAD_STICK_SENSITIVITY
		InputController.InputState.yaw = processAnalogInput(gamepad:GetState().LeftStick.X, Config.INPUT_DEADZONE_STICK) * Config.GAMEPAD_STICK_SENSITIVITY
		InputController.InputState.pitch = processAnalogInput(-gamepad:GetState().RightStick.Y, Config.INPUT_DEADZONE_STICK) * Config.GAMEPAD_STICK_SENSITIVITY
		InputController.InputState.roll = processAnalogInput(gamepad:GetState().RightStick.X, Config.INPUT_DEADZONE_STICK) * Config.GAMEPAD_STICK_SENSITIVITY
		if gamepad:GetState()[Enum.KeyCode.ButtonR1] == Enum.UserInputState.Begin then InputController.TrickButtonPressed:Fire("barrel_roll", "RIGHT") end
	end
end
local function handleTouchInput(actionName, inputState, inputObject) return Enum.ContextActionResult.Pass end -- Placeholder
local function handleTrickButton(actionName, inputState, inputObject) if inputState == Enum.UserInputState.Begin then if actionName == "TriggerTrick1" then InputController.TrickButtonPressed:Fire("barrel_roll", "RIGHT"); return Enum.ContextActionResult.Sink elseif actionName == "TriggerTrick2_L" then InputController.TrickButtonPressed:Fire("barrel_roll", "LEFT"); return Enum.ContextActionResult.Sink end end; return Enum.ContextActionResult.Pass end

function InputController:Initialize()
    if self.isInitialized then return end -- Prevent double init

    player = Players.LocalPlayer -- Get player at initialization
    if not player then warn("InputController: LocalPlayer not found during Initialize."); return end

	local playerGui = player:WaitForChild("PlayerGui")
	touchGui = playerGui:FindFirstChild("DroneTouchControls") 
	if touchGui then
		-- ... (touch GUI setup as before) ...
	else
		warn("InputController: DroneTouchControls GUI not found.")
	end
	ContextActionService:BindAction("TriggerTrick1", handleTrickButton, false, Enum.KeyCode.E)
	ContextActionService:BindAction("TriggerTrick2_L", handleTrickButton, false, Enum.KeyCode.Q)
	UserInputService.InputChanged:Connect(function(input, gameProcessedEvent)
		if gameProcessedEvent then return end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local isDown = (input.UserInputState == Enum.UserInputState.Begin or input.UserInputState == Enum.UserInputState.Change)
			if input.KeyCode == Enum.KeyCode.W then InputController.InputState.throttle = isDown and 1 or 0
			elseif input.KeyCode == Enum.KeyCode.S then InputController.InputState.throttle = isDown and -0.5 or 0 end
			if input.KeyCode == Enum.KeyCode.A then InputController.InputState.yaw = isDown and -1 or 0
			elseif input.KeyCode == Enum.KeyCode.D then InputController.InputState.yaw = isDown and 1 or 0 end
			if input.KeyCode == Enum.KeyCode.Up then InputController.InputState.pitch = isDown and 1 or 0
			elseif input.KeyCode == Enum.KeyCode.Down then InputController.InputState.pitch = isDown and -1 or 0 end
			if input.KeyCode == Enum.KeyCode.Left then InputController.InputState.roll = isDown and -1 or 0
			elseif input.KeyCode == Enum.KeyCode.Right then InputController.InputState.roll = isDown and 1 or 0 end
		end
	end)
	self.isInitialized = true
	print("InputController Initialized.")
end

function InputController:GetInputs()
	if UserInputService.GamepadEnabled then updateGamepadInput() end
	return { throttle = self.InputState.throttle, roll = self.InputState.roll, pitch = self.InputState.pitch, yaw = self.InputState.yaw }
end

return InputController