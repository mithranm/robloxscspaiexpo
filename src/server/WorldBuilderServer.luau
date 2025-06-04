-- src/server/WorldBuilderServer.luau
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage.Shared.Config)

local WorldBuilderServer = {}

local obstaclesFolder = Workspace:FindFirstChild("GazeboObstacles")
if not obstaclesFolder then
	obstaclesFolder = Instance.new("Folder")
	obstaclesFolder.Name = "GazeboObstacles"
	obstaclesFolder.Parent = Workspace
end

local droneModelsFolder = ServerStorage:FindFirstChild("DroneModelsStorage")
if not droneModelsFolder then
	droneModelsFolder = Instance.new("Folder")
	droneModelsFolder.Name = "DroneModelsStorage"
	droneModelsFolder.Parent = ServerStorage
end

local GZ_COLOR_TO_ROBLOX_COLOR = {}
local function getRobloxColor(gazeboColorName)
    if gazeboColorName and GZ_COLOR_TO_ROBLOX_COLOR[gazeboColorName] then
        local mappedColorValue = GZ_COLOR_TO_ROBLOX_COLOR[gazeboColorName]
        local success, brickColor = pcall(BrickColor.new, mappedColorValue)
        if success then
            return brickColor
        else
            warn("WorldBuilderServer:getRobloxColor - Could not create BrickColor from mapped value '" .. tostring(mappedColorValue) .. "' for Gazebo color '" .. gazeboColorName .. "'. Using default.")
        end
    elseif gazeboColorName then
        -- warn("WorldBuilderServer:getRobloxColor - Gazebo color '" .. gazeboColorName .. "' not found in GZ_COLOR_TO_ROBLOX_COLOR map. Using default.")
    end
    return BrickColor.new("Medium stone grey") 
end
local function gazeboPoseToRobloxCFrame(gzPose)
    -- Placeholder: needs actual implementation
    if gzPose then end -- to silence unused variable warning for now
    return CFrame.new()
end

local function fetchJsonData(endpointUrl)
	if not HttpService.HttpEnabled then
		warn("WorldBuilderServer: HttpService not enabled.")
		return nil, "HttpService not enabled"
	end
    print("WorldBuilderServer: Attempting to fetch from:", endpointUrl)
	local requestParameters = { Url = endpointUrl, Method = "GET", Headers = {["Content-Type"] = "application/json"} }
	local success, result = pcall(HttpService.RequestAsync, HttpService, requestParameters)

	if not success then
		warn("WorldBuilderServer: HTTP GET request to", endpointUrl, "pcall failed:", result)
		return nil, "HTTP GET pcall failed: " .. tostring(result)
	end
	
	if not result or not result.Success then
	    warn("WorldBuilderServer: HTTP GET request to", endpointUrl, "failed. StatusCode:", result and result.StatusCode, "Body:", result and result.Body)
	    return nil, "HTTP GET failed: " .. (result and result.StatusMessage or "Unknown HTTP error")
	end

	local decodedSuccess, data = pcall(HttpService.JSONDecode, HttpService, result.Body)
	if not decodedSuccess then
		warn("WorldBuilderServer: JSONDecode failed for data from", endpointUrl, ":", data)
		return nil, "JSON Decode failed: " .. tostring(data)
	end
	if data and data.error then
		warn("WorldBuilderServer: Orchestrator returned error from", endpointUrl, ":", data.error)
		return nil, "Orchestrator error: " .. tostring(data.error)
	end
	return data
end

function WorldBuilderServer:CreateDefaultObstacles()
    print("WorldBuilderServer: Creating default fallback obstacles.")
    obstaclesFolder:ClearAllChildren() -- Clear any previous attempts
    
    local function createBox(name, pos, size, color)
        local box = Instance.new("Part")
        box.Name = name
        box.Shape = Enum.PartType.Block
        box.Size = size
        box.Position = pos
        box.BrickColor = color or BrickColor.new("Medium stone grey")
        box.Anchored = true
        box.Parent = obstaclesFolder
    end
    createBox("DefaultPillar1", Vector3.new(10, 2.5, 0), Vector3.new(1,5,1), BrickColor.new("Institutional white"))
    createBox("DefaultHoopBottom", Vector3.new(0, 1, 15), Vector3.new(5,0.5,0.5), BrickColor.new("Bright red"))
    createBox("DefaultHoopTop", Vector3.new(0, 4, 15), Vector3.new(5,0.5,0.5), BrickColor.new("Bright red"))
    createBox("DefaultHoopLeft", Vector3.new(-2.25, 2.5, 15), Vector3.new(0.5,3,0.5), BrickColor.new("Bright red"))
    createBox("DefaultHoopRight", Vector3.new(2.25, 2.5, 15), Vector3.new(0.5,3,0.5), BrickColor.new("Bright red"))
end

function WorldBuilderServer:BuildObstacles()
	local obstaclesDataPackage, err = fetchJsonData(Config.WORLD_OBSTACLES_ENDPOINT)
	if not obstaclesDataPackage or not obstaclesDataPackage.obstacles then
		warn("WorldBuilderServer:BuildObstacles - Failed to fetch obstacles. Creating default obstacles.", err)
		self:CreateDefaultObstacles()
		return
	end
	-- ... (rest of BuildObstacles logic from previous response, using obstaclesDataPackage.obstacles) ...
    local obstaclesData = obstaclesDataPackage.obstacles
	print("WorldBuilderServer: Creating/updating", #obstaclesData, "obstacles from orchestrator.")
	
	local existingObstacleNames = {}
	for _, child in ipairs(obstaclesFolder:GetChildren()) do existingObstacleNames[child.Name] = child end
	local currentObstacleNames = {}

	for _, data in ipairs(obstaclesData) do
		local partName = data.name; currentObstacleNames[partName] = true
		local part = existingObstacleNames[partName]
		if not part then part = Instance.new("Part"); part.Name = partName; part.Parent = obstaclesFolder end
		part.Anchored = data.is_static or true; part.Material = Enum.Material.SmoothPlastic
		part.TopSurface, part.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
		part.CanCollide = true
		if data.type == "box" then
			part.Shape = Enum.PartType.Block
			local gzSize = data.size; part.Size = Vector3.new(gzSize.x or 1, gzSize.z or 1, gzSize.y or 1)
		elseif data.type == "cylinder" then
			part.Shape = Enum.PartType.Cylinder
			local gzSize = data.size; local d = (gzSize.radius or 0.5) * 2; local l = gzSize.length or 1
			part.Size = Vector3.new(d, l, d)
		elseif data.type == "sphere" then
			part.Shape = Enum.PartType.Ball
			local gzSize = data.size; local d = (gzSize.radius or 0.5) * 2
			part.Size = Vector3.new(d, d, d)
		else part.Shape = Enum.PartType.Block; part.Size = Vector3.new(1,1,1) end
		part.CFrame = gazeboPoseToRobloxCFrame(data.pose)
		part.BrickColor = getRobloxColor(data.color)
		part.Transparency = 0
	end
	for name, oldPart in pairs(existingObstacleNames) do if not currentObstacleNames[name] then oldPart:Destroy() end end
	print("WorldBuilderServer: Obstacle creation/update complete.")
end

function WorldBuilderServer:CreateDefaultDroneTemplate()
    print("WorldBuilderServer: Creating default fallback drone template.")
    local existingTemplate = droneModelsFolder:FindFirstChild("GazeboDroneTemplate_Default")
    if existingTemplate then existingTemplate:Destroy() end

    local droneModel = Instance.new("Model")
    droneModel.Name = "GazeboDroneTemplate_Default"
    local body = Instance.new("Part")
    body.Name = "Body"; body.Shape = Enum.PartType.Block
    body.Size = Vector3.new(0.1, 0.02, 0.05); body.BrickColor = BrickColor.new("Medium stone grey")
    body.Material = Enum.Material.Plastic; body.Massless = true; body.CanCollide = true
    body.Anchored = false; body.Parent = droneModel; droneModel.PrimaryPart = body
    local massValue = Instance.new("NumberValue"); massValue.Name = "ActualMassKg"
    massValue.Value = Config.DRONE_MASS_KG_DEFAULT; massValue.Parent = body
    -- Simplified: No arms/rotors for default template for brevity
    droneModel.Parent = droneModelsFolder
    print("WorldBuilderServer: Default drone template created:", droneModel.Name)
    return droneModel
end

function WorldBuilderServer:CreateDroneTemplateFromSpecs()
	local droneSpecs, err = fetchJsonData(Config.DRONE_SPECS_ENDPOINT)
	if not droneSpecs then
		warn("WorldBuilderServer:CreateDroneTemplateFromSpecs - Failed to fetch drone specs. Creating default template.", err)
		return self:CreateDefaultDroneTemplate()
	end
	-- ... (rest of CreateDroneTemplateFromSpecs logic from previous response, using droneSpecs) ...
    print("WorldBuilderServer: Generating drone template from fetched specs:", droneSpecs)
	local existingTemplate = droneModelsFolder:FindFirstChild("GazeboDroneTemplate_Fetched")
	if existingTemplate then existingTemplate:Destroy() end
	local droneModel = Instance.new("Model"); droneModel.Name = "GazeboDroneTemplate_Fetched"
	local bodyParams = droneSpecs.hull
	if not bodyParams then return self:CreateDefaultDroneTemplate() end
	local body = Instance.new("Part"); body.Name = "Body"; body.Shape = Enum.PartType.Block
	body.Size = Vector3.new(bodyParams.length or 0.1, bodyParams.height or 0.02, bodyParams.width or 0.05)
	body.BrickColor = BrickColor.new("Medium stone grey"); body.Material = Enum.Material.Plastic
	body.Massless = true; body.CanCollide = true; body.Anchored = false
	body.Parent = droneModel; droneModel.PrimaryPart = body
	local massValue = Instance.new("NumberValue"); massValue.Name = "ActualMassKg"
	massValue.Value = bodyParams.mass or Config.DRONE_MASS_KG_DEFAULT; massValue.Parent = body
	local armParams = droneSpecs.arms; local rotorParams = droneSpecs.rotors
	if armParams and rotorParams then
		local numArms = armParams.count or 4; local armL = armParams.length or 0.06; local propD = rotorParams.prop_diameter or 0.03
		for i = 1, numArms do
			local angle = (i - 1) * (2 * math.pi / numArms) 
			local armX = (body.Size.X/2 + armL/2) * math.cos(angle); local armZ = -(body.Size.Z/2 + armL/2) * math.sin(angle)
			local armP = Instance.new("Part"); armP.Name = "Arm"..i; armP.Shape=Enum.PartType.Block; armP.Size=Vector3.new(armL,0.005,0.005)
			armP.BrickColor=BrickColor.new("Dark stone grey"); armP.Material=Enum.Material.Plastic; armP.Massless=true; armP.CanCollide=false; armP.Anchored=false
			armP.CFrame = CFrame.new(armX,0,armZ)*CFrame.Angles(0,-angle,0); armP.Parent=droneModel
			local rX = (body.Size.X/2+armL)*math.cos(angle); local rZ = -(body.Size.Z/2+armL)*math.sin(angle)
			local rP = Instance.new("Part"); rP.Name="Rotor"..i; rP.Shape=Enum.PartType.Cylinder; rP.Size=Vector3.new(propD,0.005,propD)
			rP.BrickColor=BrickColor.new("Black"); rP.Material=Enum.Material.Plastic; rP.Massless=true; rP.CanCollide=false; rP.Anchored=false
			rP.CFrame=CFrame.new(rX,0.005,rZ)*CFrame.Angles(0,-angle,0); rP.Parent=droneModel
			local bW=Instance.new("WeldConstraint"); bW.Part0=body; bW.Part1=armP; bW.Parent=armP
			local rW=Instance.new("WeldConstraint"); rW.Part0=armP; rW.Part1=rP; rW.Parent=rP
		end
	end
	droneModel.Parent = droneModelsFolder
	print("WorldBuilderServer: Fetched drone template created:", droneModel.Name)
	return droneModel
end

function WorldBuilderServer:InitializeWorldState()
	print("WorldBuilderServer: Initializing world state from orchestrator...")
	local template = self:CreateDroneTemplateFromSpecs() -- This will create default if fetch fails
	if not template then
		warn("WorldBuilderServer: CRITICAL - Failed to create any drone template. Player drones cannot be spawned.")
	end
	self:BuildObstacles() -- This will create default if fetch fails
	print("WorldBuilderServer: World state initialization complete.")
end

return WorldBuilderServer