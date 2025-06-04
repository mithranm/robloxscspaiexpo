-- src/client/init.client.luau
-- This LocalScript is the primary entry point for all client-side logic.
-- Rojo maps this to StarterPlayer.StarterPlayerScripts.Client

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

print("CLIENT [init.client.luau]: Starting client-side initialization...")

-- Wait for essential services if they might not be ready
local player = Players.LocalPlayer or Players.PlayerAdded:Wait()
if not player then
	warn("CLIENT [init.client.luau]: LocalPlayer not found even after waiting. Client script may not function correctly.")
	return
end

local playerGui = player:WaitForChild("PlayerGui")
if not playerGui then
	warn("CLIENT [init.client.luau]: PlayerGui not found. UI-dependent features may fail.")
	-- Continue if core logic doesn't strictly need PlayerGui immediately
end

-- All other .luau files in src/client/ will become children of this script instance.
-- For example, MainController.luau becomes script.MainController
local MainController = require(script.MainController)
local InputController = require(script.InputController) -- Also a child if in src/client
-- Add other top-level client modules here if needed

if MainController and MainController.Start then
	print("CLIENT [init.client.luau]: Calling MainController:Start()...")
	-- Pass any necessary initial dependencies if MainController.Start expects them
	MainController:Start({
		Player = player,
		PlayerGui = playerGui,
		InputController = InputController -- Pass initialized InputController
		-- Pass other initialized core modules if MainController needs them directly
	})
else
	warn("CLIENT [init.client.luau]: MainController module not found or does not have a Start function.")
end

print("CLIENT [init.client.luau]: Client-side initialization sequence complete.")