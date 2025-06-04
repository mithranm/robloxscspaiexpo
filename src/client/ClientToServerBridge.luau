-- src/client/ClientToServerBridge.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local HttpService = game:GetService("HttpService") -- Still needed for GenerateGUID

local Bridge = {}

Bridge.OnTrickDataStarted = Instance.new("BindableEvent")
Bridge.OnTrickDataChunk = Instance.new("BindableEvent")
Bridge.OnTrickDataEnded = Instance.new("BindableEvent")
Bridge.OnTrickError = Instance.new("BindableEvent")
Bridge.OnConfigureDroneAck = Instance.new("BindableEvent")

function Bridge:RequestTrick(payload)
	-- payload.original_request_id is now expected to be set by the caller (MainController)
	if not payload.original_request_id then 
        payload.original_request_id = HttpService:GenerateGUID(false)
        warn("ClientToServerBridge:RequestTrick - original_request_id was not in payload, generated one:", payload.original_request_id)
    end
	print("ClientToServerBridge: Sending RequestTrick:", payload.original_request_id, "TrickType:", payload.trick_type)
	local success, result = pcall(Remotes.RequestTrick.InvokeServer, Remotes.RequestTrick, payload)
	if success then
		print("ClientToServerBridge: RequestTrick InvokeServer result:", result)
		if result and result.success then
			return payload.original_request_id -- Return the ID on success, as it was successfully forwarded
		else
			local errorMsg = (result and result.error) or "Failed to forward request to orchestrator."
			Bridge.OnTrickError:Fire({ original_request_id = payload.original_request_id, message = errorMsg})
			return nil
		end
	else
		warn("ClientToServerBridge: Error invoking RequestTrick:", result)
		Bridge.OnTrickError:Fire({ original_request_id = payload.original_request_id, message = "Roblox server invoke error: " .. tostring(result)})
		return nil
	end
end

function Bridge:ConfigureDrone(droneParamsPayload)
	droneParamsPayload.original_request_id = HttpService:GenerateGUID(false)
	print("ClientToServerBridge: Sending ConfigureDrone:", droneParamsPayload.original_request_id)
	local success, result = pcall(Remotes.ConfigureDrone.InvokeServer, Remotes.ConfigureDrone, droneParamsPayload)
	if success then
		print("ClientToServerBridge: ConfigureDrone InvokeServer result:", result)
	else
		warn("ClientToServerBridge: Error invoking ConfigureDrone:", result)
	end
	return droneParamsPayload.original_request_id
end

Remotes.TrickDataStarted.OnClientEvent:Connect(function(payload) Bridge.OnTrickDataStarted:Fire(payload) end)
Remotes.TrickDataChunk.OnClientEvent:Connect(function(payload) Bridge.OnTrickDataChunk:Fire(payload) end)
Remotes.TrickDataEnded.OnClientEvent:Connect(function(payload) Bridge.OnTrickDataEnded:Fire(payload) end)
Remotes.TrickError.OnClientEvent:Connect(function(payload) Bridge.OnTrickError:Fire(payload) end)
Remotes.ConfigureDroneAck.OnClientEvent:Connect(function(payload) Bridge.OnConfigureDroneAck:Fire(payload) end)

print("ClientToServerBridge initialized.")

-- Modified to use the new RemoteEvent for server-side physics
function Bridge:SendDroneInputs(inputs)
	Remotes.ClientDroneInputs:FireServer(inputs)
end

return Bridge