-- src/serverstorage/RoSocket/init.lua
local RoSocket = {}
local Reader = require(script.reader)
local Errors = require(script.reader.Errors)
local Signal = require(script.Signal)
local Maid = require(script.Maid)

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local SOCKET_SERVER_UPDATES = 0.10

if RunService:IsServer() == false then
	error(Reader:FormatText(Errors.INVALID_REQUIREMENT_CONTEXT))
end
if not HttpService.HttpEnabled then
	warn(Reader:FormatText(Errors.HTTP_SERVICE_DISABLED .. " RoSocket may not function correctly or at all."))
end

local MaidSocketContainer = Maid.new()
local Sockets = {} -- [uuid: string] = socketEntry

export type RoSocketInstance = {
	UUID: string,
	Socket: string,
	readyState: string,
	binaryType: string,
	OnDisconnect: RBXScriptSignal,
	OnMessageReceived: RBXScriptSignal,
	OnErrorReceived: RBXScriptSignal,
	Disconnect: (self: RoSocketInstance) -> boolean,
	Send: (self: RoSocketInstance, message: string) -> boolean,
	Messages: {{id: any, message: string}},
	Errors: {{id: any, message: string}},
	error: string? -- For initial connection error
}

RoSocket.Version = "1.0.1"
RoSocket.Maid = Maid

-- This is the type for the __call metamethod
type RoSocketConnectFn = (self: typeof(RoSocket), targetWebSocketUrl: string) -> RoSocketInstance
export type RoSocketModule = typeof(RoSocket) & { Connect: RoSocketConnectFn, __call: RoSocketConnectFn }


function RoSocket:Connect(targetWebSocketUrl: string): RoSocketInstance
	local connectResponse = Reader:Connect(targetWebSocketUrl)

	if not (connectResponse and connectResponse.success and connectResponse.UUID) then
		local errorMessage = connectResponse and connectResponse.message or "RoSocket Reader:Connect failed to return valid data."
		warn(Reader:FormatText("RoSocket:Connect - Failed to establish initial connection via Reader. Backend Error: " .. errorMessage))
		
		local dummyOnDisconnect = Signal.new()
		local dummyOnMessage = Signal.new()
		local dummyOnError = Signal.new()
		MaidSocketContainer:GiveTask(dummyOnDisconnect)
		MaidSocketContainer:GiveTask(dummyOnMessage)
		MaidSocketContainer:GiveTask(dummyOnError)

		-- Ensure the returned table matches RoSocketInstance structure for failed connections
		local failedSocket: RoSocketInstance = {
			UUID = "N/A-" .. HttpService:GenerateGUID(false), -- Give a unique dummy UUID
			Socket = targetWebSocketUrl,
			readyState = "CLOSED",
			binaryType = "buffer",
			OnDisconnect = dummyOnDisconnect,
			OnMessageReceived = dummyOnMessage,
			OnErrorReceived = dummyOnError,
			Disconnect = function(selfPassed) return false end,
			Send = function(selfPassed, message) return false end,
			Messages = {},
			Errors = {},
			error = errorMessage
		}
		return failedSocket
	end

	local uuid = connectResponse.UUID
	if Sockets[uuid] then
		warn(Reader:FormatText("RoSocket:Connect - Socket with UUID '", uuid, "' already exists. Returning existing instance."))
		return Sockets[uuid].sockettbl
	end

	local socketEntry = {
		sockettbl = nil, 
		msgs = {},
		errors = {},
		elapsedtimer = 0,
		isDisconnected = false,
		heartbeatConnection = nil,
		onDisconnectSignal = Signal.new(),
		onMessageReceivedSignal = Signal.new(),
		onErrorReceivedSignal = Signal.new(),
	}
	Sockets[uuid] = socketEntry 

	local tbl: RoSocketInstance = {
		UUID = uuid,
		Socket = targetWebSocketUrl,
		readyState = "OPEN",
		binaryType = "buffer",
		OnDisconnect = socketEntry.onDisconnectSignal,
		OnMessageReceived = socketEntry.onMessageReceivedSignal,
		OnErrorReceived = socketEntry.onErrorReceivedSignal,
		Messages = socketEntry.msgs,
		Errors = socketEntry.errors,
		error = nil, -- Explicitly nil for optional field
		
		Disconnect = function(self: RoSocketInstance): boolean
			if socketEntry.isDisconnected then
				warn(Reader:FormatText("Socket ("..self.UUID..") is already disconnected."))
				return false
			end
			
			local disconnectBackendResult = Reader:Disconnect(self.UUID) 
			
			socketEntry.isDisconnected = true 
			self.readyState = "CLOSED"

			if socketEntry.heartbeatConnection and socketEntry.heartbeatConnection.Connected then
				socketEntry.heartbeatConnection:Disconnect()
			end
			socketEntry.heartbeatConnection = nil
			
			Sockets[self.UUID] = nil 

			socketEntry.onDisconnectSignal:Fire() 
			print(Reader:FormatText("Socket ("..self.UUID..") disconnected. Backend disconnect success: " .. tostring(disconnectBackendResult and disconnectBackendResult.success)))
			return disconnectBackendResult and disconnectBackendResult.success
		end,
		
		Send = function(self: RoSocketInstance, message: string): boolean 
			if socketEntry.isDisconnected then
				warn(Reader:FormatText("Cannot send on disconnected socket ("..self.UUID..")."))
				return false
			end
			local sendBackendResult = Reader:Send(self.UUID, message)
			return sendBackendResult and sendBackendResult.success
		end
	}
	
	socketEntry.sockettbl = tbl 

	socketEntry.heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if socketEntry.isDisconnected then return end 

		socketEntry.elapsedtimer += deltaTime
		if socketEntry.elapsedtimer >= SOCKET_SERVER_UPDATES then
			socketEntry.elapsedtimer = 0
			
			if not socketEntry.isDisconnected then
				local sucMsgs, msgsData = pcall(Reader.Get, Reader, uuid) -- uuid is upvalue here
				local MsgsDataTyped = msgsData 
				if sucMsgs and typeof(MsgsDataTyped) == "table" then
					if rawget(MsgsDataTyped, "success") ~= nil then -- It's the object {success=T/F, message=...}
						if MsgsDataTyped.success == false then
							-- warn("...")
						end
					else -- It's the array form {any}
						for _, msgobj in ipairs(MsgsDataTyped) do
							if typeof(msgobj) == "table" and msgobj.id and msgobj.message then
								local exists = false
								for _, existingMsg in ipairs(socketEntry.msgs) do if existingMsg.id == msgobj.id then exists = true; break; end end
								if not exists then
									socketEntry.onMessageReceivedSignal:Fire(msgobj.message)
									table.insert(socketEntry.msgs, msgobj)
								end
							end
						end
					end
				elseif not sucMsgs then
					-- warn("...")
				end

				local sucErrs, errsData = pcall(Reader.GetErrors, Reader, uuid) -- uuid is upvalue here
				local ErrsDataTyped = errsData 
				if sucErrs and typeof(ErrsDataTyped) == "table" then
					if rawget(ErrsDataTyped, "success") ~= nil then -- It's the object {success=T/F, message=...}
						if ErrsDataTyped.success == false then
							-- warn("...")
						end
					else -- It's the array form {any}
						for _, errObj in ipairs(ErrsDataTyped) do
							if typeof(errObj) == "table" and errObj.id and errObj.message then
								local exists = false
								for _, existingErr in ipairs(socketEntry.errors) do if existingErr.id == errObj.id then exists = true; break; end end
								if not exists then
									socketEntry.onErrorReceivedSignal:Fire(errObj.message)
									table.insert(socketEntry.errors, errObj)
								end
							end
						end
					end
				elseif not sucErrs then
					-- warn("...")
				end
			end
		end
	end)
	MaidSocketContainer:GiveTask(socketEntry.heartbeatConnection)

	-- Messages and Errors are now initialized in tbl's constructor

	setmetatable(tbl, { __index = function(_, k) 
		-- This can be used to warn about accessing non-existent properties if needed
		-- warn("RoSocket Instance: Accessing undefined property '"..tostring(k).."' on socket "..tbl.UUID)
		return nil 
	end, __metatable = "Protected RoSocket Instance"})
	
	print(Reader:FormatText("RoSocket connection instance created for UUID: " .. uuid .. ", Target: " .. targetWebSocketUrl))
	local anyValue: any = tbl
	return anyValue :: RoSocketInstance
end

-- Metatable for the RoSocket module itself, to allow calling RoSocket(url)
local metaRoSocket = {
	__index = RoSocket,
	__call = function(selfApplied, targetUrl: string): RoSocketInstance
		return selfApplied:Connect(targetUrl)
	end
}
setmetatable(RoSocket, metaRoSocket)


return RoSocket