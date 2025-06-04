-- src/serverstorage/RoSocket/reader/init.lua
--[[
			- RO SOCKET -
		Module responsible for helping main module to send external API calls
		Be aware of what you modify, and make sure you know what you're doing.
		Running this in studio with a server update rate higher than 50 (per second) will lead in ratelimits.

		• Creator: @binarychunk
]]--
-----------------------------------------------
local Reader = {}
local Dictionary = require(script.Dictionary)
local Errors = require(script.Errors)
-- Corrected path: Signature is a sibling of the "RoSocket" ModuleScript (which is script.Parent from here)
local Signature = require(script.Parent.Signature)
-----------------------------------------------
local HttpService = game:GetService("HttpService")
-----------------------------------------------
-- Luau type for HTTPService response tables (simplified)
export type HttpRequestAsyncResponse = {
	Success: boolean,
	StatusCode: number,
	StatusMessage: string,
	Headers: {[string]: string},
	Body: string -- Body is a string, needs JSONDecode
}

-- Luau type for what the RoSocket backend sends after a /connect call
export type RoSocketConnectionResponseData = {
	success: boolean, -- Note: often lowercase 's' from Node.js backends
	UUID: string?,
	Socket: string?, -- The original target WebSocket URL
	message: string? -- Error message if success is false
}

-- Luau type for what RoSocket backend sends for Disconnect, Send operations
export type RoSocketActionResponseData = {
	success: boolean,
	message: string?
}

-- Luau type for what RoSocket backend sends for Get (messages) or GetErrors
-- Assuming it's an array of objects, or an error object if the call itself failed
export type RoSocketGetDataItem = {id: any, message: string} -- Example structure of items in the array
export type RoSocketGetResponseData = {any} | {success:boolean, message:string?} -- Array or error object

-----------------------------------------------
-- IMPORTANT: SET THIS TO YOUR RoSocket NODE.JS BACKEND/PROXY URL
-- This is NOT the Gazebo orchestrator URL, but the URL of the RoSocket server
-- that implements the /connect, /send, /get HTTP endpoints.
-- Example: "http://localhost:3000" or "http://your.rosocket.proxy.com"
local SOCKET_SERVER_URL = "http://scspdrone.mithran.org" -- Assuming RoSocket proxy is on port 80 here
-- If your RoSocket proxy is on a different port, e.g., 3000, use:
-- local SOCKET_SERVER_URL = "http://scspdrone.mithran.org:3000"
-----------------------------------------------
local WSS_PATTERN = "^wss?://[%w%.:%-/%?&=#~_]+" -- More permissive for URLs with paths/queries
-----------------------------------------------
function Reader:FormatText(text: string, ...: any?): string
	assert(text, Errors.EMPTY_TEXT_TO_FORMAT)
	assert(typeof(text) == "string", string.format(Errors.INVALID_ARGUMENT_TYPE, "text", "string", typeof(text)))

	return `{Signature.Signature} {Signature.Splitter} {text}`
end

if SOCKET_SERVER_URL == "" or SOCKET_SERVER_URL == "http://scspdrone.mithran.org" and not string.find(SOCKET_SERVER_URL, ":%d+") then
	-- Basic check if it's the default placeholder or missing a port if it's not a standard one.
    -- This warning might be too aggressive if scspdrone.mithran.org is indeed serving the proxy on port 80.
    -- For now, let's assume it might need a port if it's not explicitly localhost.
    if SOCKET_SERVER_URL == "" then
	    -- More specific warning if it's not localhost or a .org domain (common for public services)
        -- and doesn't have a port.
    end
    -- Keep a general warning if it's empty.
    if SOCKET_SERVER_URL == "" then
        warn(Reader:FormatText("RoSocket Reader: CRITICAL - SOCKET_SERVER_URL is not set! RoSocket backend communication will fail. Please configure this in src/serverstorage/RoSocket/reader/init.lua"))
    end
end


function Reader:ValidateWSSLink(link: string): boolean
	assert(link, Errors.EMPTY_WSS_LINK_TO_VALIDATE)
	assert(typeof(link) == "string", string.format(Errors.INVALID_ARGUMENT_TYPE, "link", "string", typeof(link)))

	return string.match(link, WSS_PATTERN) and true or false
end

function Reader:Connect(targetWebSocketUrl: string): RoSocketConnectionResponseData
	if SOCKET_SERVER_URL == "" then
		warn(self:FormatText("SOCKET_SERVER_URL not configured."))
		return {success = false, message = "RoSocket backend URL not configured."}
	end

	-- The targetWebSocketUrl (e.g., your Gazebo orchestrator's ws:// address) goes into the body.
	-- The RoSocket library's /connect endpoint will use this.
	local requestBody = {Socket = tostring(targetWebSocketUrl)}
	local requestParameters = {
		Url = SOCKET_SERVER_URL .. Dictionary.Connection, -- URL is to the RoSocket HTTP Backend
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode(requestBody)
	}

	local successCall, response = pcall(HttpService.RequestAsync, HttpService, requestParameters)
	local Response: HttpRequestAsyncResponse = response -- Add type hint

	if not successCall then
		warn(self:FormatText(`HttpService:RequestAsync pcall failed for Connect: {tostring(Response)}`))
		return {success = false, message = "HTTP request pcall failed: " .. tostring(Response)}
	end

	if not Response or not Response.Success then
		warn(self:FormatText(`Failed to reach RoSocket backend at {requestParameters.Url} | StatusCode: {Response and Response.StatusCode or "N/A"}, Body: {Response and Response.Body or "N/A"}`))
		return {success = false, message = "HTTP request to RoSocket backend failed: " .. (Response and Response.StatusMessage or "Unknown error")}
	end

	local decodedSuccess, decodedResult = pcall(HttpService.JSONDecode, HttpService, Response.Body)
	local DecodedResult: RoSocketConnectionResponseData = decodedResult -- Add type hint

	if not decodedSuccess then
		warn(self:FormatText(`Failed to decode JSON response from Connect | Error {tostring(DecodedResult)} | Body: {Response.Body}`))
		return {success = false, message = "Failed to decode JSON response: " .. tostring(DecodedResult)}
	end

	if DecodedResult and DecodedResult.success then
		print(self:FormatText(`Successfully initiated connection via RoSocket backend for {targetWebSocketUrl}! UUID: {DecodedResult.UUID or "N/A"}`))
	else
		warn(self:FormatText(`RoSocket backend indicated connection failure for {targetWebSocketUrl}: {DecodedResult and DecodedResult.message or "No message"}`))
	end
	return DecodedResult -- Contains success, UUID, Socket, or success=false, message
end

function Reader:Disconnect(id: string): RoSocketActionResponseData
	if SOCKET_SERVER_URL == "" then return {success = false, message="RoSocket backend URL not configured."} end
	local requestParameters = {Url = SOCKET_SERVER_URL .. Dictionary.Disconnection, Method = "POST", Headers = {["Content-Type"] = "application/json"}, Body = HttpService:JSONEncode({UUID = tostring(id)})}
	local sC, R = pcall(HttpService.RequestAsync, HttpService, requestParameters); local Response: HttpRequestAsyncResponse = R
	if not sC then return {success=false, message="HTTP pcall failed: "..tostring(Response)} end
	if not Response or not Response.Success then return {success=false, message="HTTP request failed: "..(Response and Response.StatusMessage or "Unknown")} end
	local dS, dR = pcall(HttpService.JSONDecode, HttpService, Response.Body); local DecodedResult: RoSocketActionResponseData = dR
	if not dS then return {success=false, message="JSON Decode failed: "..tostring(DecodedResult)} end
	return DecodedResult
end

function Reader:Send(id: string, message: string): RoSocketActionResponseData
	if SOCKET_SERVER_URL == "" then return {success = false, message="RoSocket backend URL not configured."} end
	local requestParameters = {Url = SOCKET_SERVER_URL .. Dictionary.Send, Method = "POST", Headers = {["Content-Type"] = "application/json"}, Body = HttpService:JSONEncode({UUID = tostring(id), Message = tostring(message)})}
	local sC, R = pcall(HttpService.RequestAsync, HttpService, requestParameters); local Response: HttpRequestAsyncResponse = R
	if not sC then return {success=false, message="HTTP pcall failed: "..tostring(Response)} end
	if not R or not R.Success then return {success=false, message="HTTP request failed: "..(R and R.StatusMessage or "Unknown")} end
	local dS, dR = pcall(HttpService.JSONDecode, HttpService, R.Body); local DecodedResult: RoSocketActionResponseData = dR
	if not dS then return {success=false, message="JSON Decode failed: "..tostring(DecodedResult)} end
	return DecodedResult
end

function Reader:Get(id: string): RoSocketGetResponseData
	if SOCKET_SERVER_URL == "" then return {} end -- Return empty table for Get if no URL
	local requestParameters = {Url = SOCKET_SERVER_URL .. Dictionary.Get, Method = "POST", Headers = {["Content-Type"] = "application/json"}, Body = HttpService:JSONEncode({UUID = tostring(id)})}
	local sC, R = pcall(HttpService.RequestAsync, HttpService, requestParameters); local Response: HttpRequestAsyncResponse = R
	if not sC or not R or not R.Success then return {} end
	local dS, dR = pcall(HttpService.JSONDecode, HttpService, R.Body); local DecodedResult: RoSocketGetResponseData = dR
	if not dS then return {} end
	return DecodedResult
end

function Reader:GetErrors(id: string): RoSocketGetResponseData
	if SOCKET_SERVER_URL == "" then return {} end
	local requestParameters = {Url = SOCKET_SERVER_URL .. Dictionary.GetErrors, Method = "POST", Headers = {["Content-Type"] = "application/json"}, Body = HttpService:JSONEncode({UUID = tostring(id)})}
	local sC, R = pcall(HttpService.RequestAsync, HttpService, requestParameters); local Response: HttpRequestAsyncResponse = R
	if not sC or not R or not R.Success then return {} end
	local dS, dR = pcall(HttpService.JSONDecode, HttpService, R.Body); local DecodedResult: RoSocketGetResponseData = dR
	if not dS then return {} end
	return DecodedResult
end

return Reader