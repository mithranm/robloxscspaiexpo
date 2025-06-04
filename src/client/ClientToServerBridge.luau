-- src/client/ClientToServerBridge.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local HttpService = game:GetService("HttpService")

local Bridge = {}

Bridge.OnConfigureDroneAck = Instance.new("BindableEvent")

function Bridge:RequestTrick(payload)
	if not payload.original_request_id then 
        payload.original_request_id = HttpService:GenerateGUID(false)
        warn("ClientToServerBridge:RequestTrick - original_request_id was not in payload, generated one:", payload.original_request_id)
    end
	print("ClientToServerBridge: Sending RequestTrick:", payload.original_request_id, "TrickType:", payload.trick_type)
	
	local success, result = pcall(Remotes.RequestTrick.InvokeServer, Remotes.RequestTrick, payload)
	
    if success then
		print("ClientToServerBridge: RequestTrick InvokeServer successful. Server raw response:", result)
        -- The client's MainController now relies on ServerNotifications for trick state changes.
        -- The 'result' here is from the OnServerInvoke handler, which should indicate if the server *accepted* the request for processing.
        if typeof(result) == "table" and result.success ~= nil then
            return result -- Pass the server's immediate response back (e.g., {success=true, message="..."} or {success=false, error="..."})
        else
            -- If server returns non-table or no .success field, assume the invoke itself was okay but server response was malformed for immediate status.
            warn("ClientToServerBridge: RequestTrick InvokeServer returned unexpected result format:", result)
            return { success = true, message = "Request sent, server response format unexpected."} -- Assume sent, let notifications handle state.
        end
	else
		warn("ClientToServerBridge: Error invoking RequestTrick (pcall failed):", result)
		return { success = false, error = "InvokeServer pcall failed: " .. tostring(result) } -- Indicate pcall failure
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
	return droneParamsPayload.original_request_id -- Consider returning server's result table here too
end

-- These are for raw Gazebo data, client currently doesn't use them for physics.
Remotes.TrickDataStarted.OnClientEvent:Connect(function(payload) print("[ClientBridge] Gazebo TrickDataStarted", payload.burst_id) end)
Remotes.TrickDataChunk.OnClientEvent:Connect(function(payload) print("[ClientBridge] Gazebo TrickDataChunk", payload.burst_id) end)
Remotes.TrickDataEnded.OnClientEvent:Connect(function(payload) print("[ClientBridge] Gazebo TrickDataEnded", payload.burst_id) end)
Remotes.TrickError.OnClientEvent:Connect(function(payload) print("[ClientBridge] Gazebo TrickError", payload.message) end)

Remotes.ConfigureDroneAck.OnClientEvent:Connect(function(payload) Bridge.OnConfigureDroneAck:Fire(payload) end)

print("ClientToServerBridge initialized.")

function Bridge:SendDroneInputs(inputs)
	Remotes.ClientDroneInputs:FireServer(inputs)
end

return Bridge