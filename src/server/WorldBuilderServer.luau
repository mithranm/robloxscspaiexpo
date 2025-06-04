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
    if gzPose and gzPose.pos and gzPose.orient_quat then
        local gz_pos_table = gzPose.pos 
        local gz_pos_x = (typeof(gz_pos_table) == "table" and gz_pos_table.x) or (type(gz_pos_table) == "table" and gz_pos_table[1]) or 0
        local gz_pos_y = (typeof(gz_pos_table) == "table" and gz_pos_table.y) or (type(gz_pos_table) == "table" and gz_pos_table[2]) or 0
        local gz_pos_z = (typeof(gz_pos_table) == "table" and gz_pos_table.z) or (type(gz_pos_table) == "table" and gz_pos_table[3]) or 0

        local gz_q_table = gzPose.orient_quat 
        local gz_q_x_val = (type(gz_q_table) == "table" and gz_q_table[1]) or 0
        local gz_q_y_val = (type(gz_q_table) == "table" and gz_q_table[2]) or 0
        local gz_q_z_val = (type(gz_q_table) == "table" and gz_q_table[3]) or 0
        local gz_q_w_val = (type(gz_q_table) == "table" and gz_q_table[4]) or 1 

        local rb_x = -gz_pos_y 
        local rb_y = gz_pos_z  
        local rb_z = gz_pos_x  

        local roblox_q_x = -gz_q_y_val 
        local roblox_q_y = gz_q_z_val  
        local roblox_q_z = -gz_q_x_val 
        local roblox_q_w = gz_q_w_val  

        return CFrame.new(rb_x, rb_y, rb_z) * CFrame.new(0, 0, 0, roblox_q_x, roblox_q_y, roblox_q_z, roblox_q_w)
    end
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
    obstaclesFolder:ClearAllChildren() 
    
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
    body.Name = "Body"
    body.Shape = Enum.PartType.Block
    body.Size = Vector3.new(1, 0.5, 1) -- TEMPORARILY LARGER for inertia test (was 0.2, 0.1, 0.2)
    body.BrickColor = BrickColor.new("Medium stone grey")
    body.Material = Enum.Material.Plastic
    body.Anchored = false
    body.CanCollide = true
    body.Parent = droneModel
    droneModel.PrimaryPart = body
    
    -- ActualMassKg NumberValue is now less critical if CFM uses GetMass(), but good for reference
    local massValue = Instance.new("NumberValue")
    massValue.Name = "ActualMassKg"
    -- Value will be based on new size and default density used in CFM init if not overridden
    -- For density 0.7 and size 1,0.5,1, volume is 0.5, mass would be 0.35
    massValue.Value = 0.35 -- Approximate, actual will be calculated by CFM
    massValue.Parent = body

    local cameraMount = Instance.new("Part")
    cameraMount.Name = "CameraMount"
    cameraMount.Size = Vector3.new(0.01,0.01,0.01)
    cameraMount.Transparency = 1
    cameraMount.CanCollide = false
    cameraMount.Anchored = false
    cameraMount.Massless = true
    cameraMount.CFrame = body.CFrame * CFrame.new(0, body.Size.Y * 0.1, -(body.Size.Z/2 + 0.005)) 
    cameraMount.Parent = droneModel

    local weldCam = Instance.new("WeldConstraint")
    weldCam.Name = "WeldCamToBody"
    weldCam.Part0 = body
    weldCam.Part1 = cameraMount
    weldCam.Parent = cameraMount
    
    local bodyAttachment = body:FindFirstChild("BodyAttachment")
	if not bodyAttachment then
		bodyAttachment = Instance.new("Attachment")
		bodyAttachment.Name = "BodyAttachment"
		bodyAttachment.Position = Vector3.new(0,0,0) 
		bodyAttachment.Parent = body
	end
    
    droneModel.Parent = droneModelsFolder
    print("WorldBuilderServer: Default drone template created:", droneModel.Name, "with CameraMount and BodyAttachment. Body size:", body.Size)
    return droneModel
end

function WorldBuilderServer:CreateDroneTemplateFromSpecs()
	local droneSpecsPackage, err = fetchJsonData(Config.DRONE_SPECS_ENDPOINT)
	if not droneSpecsPackage or typeof(droneSpecsPackage) ~= "table" then 
		warn("WorldBuilderServer:CreateDroneTemplateFromSpecs - Failed to fetch or parse drone specs. Creating default template. Error:", err, "Received:", droneSpecsPackage)
		return self:CreateDefaultDroneTemplate()
	end
    local droneSpecs = droneSpecsPackage

	print("WorldBuilderServer: Generating drone template from fetched specs.")
	local existingTemplate = droneModelsFolder:FindFirstChild("GazeboDroneTemplate_Fetched")
	if existingTemplate then existingTemplate:Destroy() end

	local droneModel = Instance.new("Model")
	droneModel.Name = "GazeboDroneTemplate_Fetched"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Shape = Enum.PartType.Block
    
	local elecStackDims = droneSpecs.electronics_stack and droneSpecs.electronics_stack.dimensions_m
	if elecStackDims and #elecStackDims == 3 then
		body.Size = Vector3.new(elecStackDims[2], elecStackDims[3], elecStackDims[1]) 
	else
		body.Size = Vector3.new(0.04, 0.03, 0.04) 
        warn("WorldBuilderServer: Using fallback size for electronics stack.")
	end
	body.BrickColor = BrickColor.new("Medium stone grey")
	body.Material = Enum.Material.Plastic
	body.Anchored = false
	body.CanCollide = true 
	body.Parent = droneModel
	droneModel.PrimaryPart = body

	local massValue = Instance.new("NumberValue")
	massValue.Name = "ActualMassKg"
	massValue.Value = droneSpecs.vehicle_total_mass_kg_AUW or Config.DRONE_MASS_KG_DEFAULT
	massValue.Parent = body
    
	local function createAndWeldComponent(name, size, cframeOffsetRelativeToBody, componentParentModel, shape, color)
		local component = Instance.new("Part")
		component.Name = name
		component.Shape = shape or Enum.PartType.Block
		component.Size = size
		component.BrickColor = color or BrickColor.new("Dark stone grey")
		component.Material = Enum.Material.Metal
		component.Anchored = false
		component.CanCollide = false
		component.Massless = true
        component.CFrame = body.CFrame * cframeOffsetRelativeToBody
		component.Parent = componentParentModel

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = body 
		weld.Part1 = component
		weld.Parent = component
		return component
	end
    
    local motorPositions = droneSpecs.motor_positions_relative_to_cog_m
    local rotorSpecs = droneSpecs.rotors
    
    if motorPositions and rotorSpecs then
        local motorDiameter = rotorSpecs.prop_diameter_m or 0.127
        local motorHeight = 0.02 
        local motorSize = Vector3.new(motorDiameter, motorHeight, motorDiameter) 

        for motorName, pos_m_array in pairs(motorPositions) do
            if #pos_m_array == 3 then
                local robloxX_offset = -pos_m_array[2] 
                local robloxY_offset = pos_m_array[3]  
                local robloxZ_offset = pos_m_array[1]  
                
                local motorCFrameOffset = CFrame.new(robloxX_offset, robloxY_offset, robloxZ_offset)
                createAndWeldComponent(motorName, motorSize, motorCFrameOffset, droneModel, Enum.PartType.Cylinder, BrickColor.new("Black"))
            else
                warn("WorldBuilderServer: Invalid position array for motor", motorName)
            end
        end
    else
        warn("WorldBuilderServer: Missing motor_positions_relative_to_cog_m or rotorSpecs for detailed drone build.")
    end

    if droneSpecs.battery and droneSpecs.battery.dimensions_m and #droneSpecs.battery.dimensions_m == 3 then
        local battDims = droneSpecs.battery.dimensions_m
        local battRobloxSize = Vector3.new(battDims[2], battDims[3], battDims[1])
        local battCFrameOffset = CFrame.new(0, -(body.Size.Y/2 + battRobloxSize.Y/2), 0) 
        createAndWeldComponent("Battery", battRobloxSize, battCFrameOffset, droneModel)
    else
        warn("WorldBuilderServer: Missing or invalid battery dimensions.")
    end

    local camPart = nil
    if droneSpecs.camera_fpv and droneSpecs.camera_fpv.dimensions_m and #droneSpecs.camera_fpv.dimensions_m == 3 then
        local camDims = droneSpecs.camera_fpv.dimensions_m
        local camRobloxSize = Vector3.new(camDims[2], camDims[3], camDims[1])
        local camCFrameOffset = CFrame.new(0, 0, -(body.Size.Z/2 + camRobloxSize.Z/2) ) 
        camPart = createAndWeldComponent("FPVCamVisual", camRobloxSize, camCFrameOffset, droneModel)
    else
        warn("WorldBuilderServer: Missing or invalid FPV camera dimensions. Using default CameraMount position.")
    end
    
    local cameraMount = Instance.new("Part")
    cameraMount.Name = "CameraMount"
    cameraMount.Size = Vector3.new(0.01,0.01,0.01)
    cameraMount.Transparency = 1
    cameraMount.CanCollide = false
    cameraMount.Anchored = false
    cameraMount.Massless = true
    if camPart then 
        cameraMount.CFrame = camPart.CFrame * CFrame.new(0, camPart.Size.Y * 0.1, -(camPart.Size.Z/2 + 0.005)) 
        local camWeld = Instance.new("WeldConstraint"); camWeld.Name = "WeldMountToCam"; camWeld.Part0 = camPart; camWeld.Part1 = cameraMount; camWeld.Parent = cameraMount;
    else 
        cameraMount.CFrame = body.CFrame * CFrame.new(0, body.Size.Y * 0.1, -(body.Size.Z/2 + 0.005)) 
        local bodyWeld = Instance.new("WeldConstraint"); bodyWeld.Name = "WeldMountToBody"; bodyWeld.Part0 = body; bodyWeld.Part1 = cameraMount; bodyWeld.Parent = cameraMount;
    end
    cameraMount.Parent = droneModel

    local bodyAttachmentFetched = body:FindFirstChild("BodyAttachment")
	if not bodyAttachmentFetched then
		bodyAttachmentFetched = Instance.new("Attachment")
		bodyAttachmentFetched.Name = "BodyAttachment"
		bodyAttachmentFetched.Position = Vector3.new(0,0,0) 
		bodyAttachmentFetched.Parent = body
	end
	
	droneModel.Parent = droneModelsFolder
	print("WorldBuilderServer: Fetched drone template created:", droneModel.Name, "with total mass:", massValue.Value)
	return droneModel
end

function WorldBuilderServer:InitializeWorldState()
	print("WorldBuilderServer: Initializing world state...")

	local defaultTemplate = self:CreateDefaultDroneTemplate()
	if not defaultTemplate then
		warn("WorldBuilderServer: CRITICAL - Failed to create default drone template.")
	end
	print("WorldBuilderServer: Default drone template ensured.")

	coroutine.wrap(function()
		print("WorldBuilderServer: Starting asynchronous fetch for drone specs...")
		local fetchedTemplate = self:CreateDroneTemplateFromSpecs() 
		if fetchedTemplate and fetchedTemplate.Name == "GazeboDroneTemplate_Fetched" then
			print("WorldBuilderServer: Asynchronous drone spec fetch and template creation successful.")
		elseif fetchedTemplate then 
			print("WorldBuilderServer: Asynchronous drone spec fetch resulted in using/recreating default template.")
		else
			warn("WorldBuilderServer: Asynchronous drone spec fetch and template creation failed critically (returned nil).")
		end
	end)()

    self:CreateDefaultObstacles()
    print("WorldBuilderServer: Default obstacles ensured.")

    coroutine.wrap(function()
        print("WorldBuilderServer: Starting asynchronous fetch for world obstacles...")
        self:BuildObstacles() 
        print("WorldBuilderServer: Asynchronous obstacle build process complete (or fallback used).")
    end)()

	print("WorldBuilderServer: Synchronous part of world state initialization complete. Fetched assets may load in background.")
end

return WorldBuilderServer