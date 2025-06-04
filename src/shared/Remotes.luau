-- src/shared/Remotes.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

local remoteFolder = ReplicatedStorage:FindFirstChild("RemoteComms")
if not remoteFolder then
	remoteFolder = Instance.new("Folder")
	remoteFolder.Name = "RemoteComms"
	remoteFolder.Parent = ReplicatedStorage
end

local function getOrCreateRemote(name, className)
	local remote = remoteFolder:FindFirstChild(name)
	if not remote or not remote:IsA(className) then
		if remote then remote:Destroy() end
		remote = Instance.new(className)
		remote.Name = name
		remote.Parent = remoteFolder
	end
	return remote
end

Remotes.RequestTrick = getOrCreateRemote("RequestTrick", "RemoteFunction")
Remotes.ConfigureDrone = getOrCreateRemote("ConfigureDrone", "RemoteFunction") 
Remotes.RequestAssistance = getOrCreateRemote("RequestAssistance", "RemoteFunction") -- NEW FOR LATER

Remotes.TrickDataStarted = getOrCreateRemote("TrickDataStarted", "RemoteEvent")
Remotes.TrickDataChunk = getOrCreateRemote("TrickDataChunk", "RemoteEvent")
Remotes.TrickDataEnded = getOrCreateRemote("TrickDataEnded", "RemoteEvent")
Remotes.TrickError = getOrCreateRemote("TrickError", "RemoteEvent")
Remotes.ConfigureDroneAck = getOrCreateRemote("ConfigureDroneAck", "RemoteEvent")

Remotes.AssistanceDataStarted = getOrCreateRemote("AssistanceDataStarted", "RemoteEvent") -- NEW FOR LATER
Remotes.AssistanceDataChunk = getOrCreateRemote("AssistanceDataChunk", "RemoteEvent") -- NEW FOR LATER
Remotes.AssistanceDataEnded = getOrCreateRemote("AssistanceDataEnded", "RemoteEvent") -- NEW FOR LATER
Remotes.AssistanceError = getOrCreateRemote("AssistanceError", "RemoteEvent") -- NEW FOR LATER

Remotes.ServerNotification = getOrCreateRemote("ServerNotification", "RemoteEvent")

return Remotes