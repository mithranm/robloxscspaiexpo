-- src/shared/Config.luau
local Workspace = game:GetService("Workspace")
local Config = {}

-- Orchestrator
Config.ORCHESTRATOR_HTTP_BASE_URL = "http://scspdrone.mithran.org:28642" 
Config.ROSOCKET_CONNECTION_URL = string.gsub(Config.ORCHESTRATOR_HTTP_BASE_URL, "http", "ws") .. "/ws_gazebo_orchestrator"
Config.WORLD_OBSTACLES_ENDPOINT = Config.ORCHESTRATOR_HTTP_BASE_URL .. "/world_obstacles"
Config.DRONE_SPECS_ENDPOINT = Config.ORCHESTRATOR_HTTP_BASE_URL .. "/drone_specs"
Config.HTTP_TIMEOUT_SECONDS = 5 -- Timeout for HTTP requests to orchestrator

-- Drone Physics (Player Controlled Flight)
Config.DRONE_MASS_KG_DEFAULT = 0.05 -- Fallback mass if not fetched
Config.CUSTOM_GRAVITY_Y = -Workspace.Gravity -- Use Roblox's gravity value but apply manually
Config.MAX_THRUST_FORCE = 1.5 -- Newtons (tune based on mass and desired acceleration)

Config.TARGET_PITCH_RATE_MAX = math.rad(180) -- Max rad/s for pitch input
Config.TARGET_ROLL_RATE_MAX = math.rad(180)  -- Max rad/s for roll input
Config.TARGET_YAW_RATE_MAX = math.rad(120)   -- Max rad/s for yaw input

Config.ATTITUDE_P_GAIN = 2.5   -- Proportional gain for reaching target angular rates (tune this!)
Config.ATTITUDE_D_GAIN = 0.15  -- Derivative gain for damping angular oscillations (tune this!)
                              -- For MoI around 1e-5 to 1e-6, these gains are starting points.
                              -- Smaller MoI generally needs smaller gains or higher damping.

Config.DRAG_COEFFICIENT_LINEAR = 0.08    -- Tune this
Config.DRAG_COEFFICIENT_QUADRATIC = 0.05 -- Tune this
Config.DRAG_COEFFICIENT_ANGULAR = 0.02   -- Tune this

-- Safe Envelope (for Gazebo takeover)
Config.MAX_SAFE_ATTITUDE_DEGREES = 75
Config.MAX_SAFE_ROLL_RATE_DPS = 360  -- Degrees per second
Config.MAX_SAFE_PITCH_RATE_DPS = 360 -- Degrees per second
Config.MAX_SAFE_YAW_RATE_DPS = 270   -- Degrees per second
-- Add more envelope params like min/max altitude if needed

-- PD Controller Gains for Gazebo Guided Modes (Tricks/Assistance)
Config.GUIDANCE_POS_KP = 75 
Config.GUIDANCE_POS_KD = 15 
Config.GUIDANCE_ROT_KP = 40 
Config.GUIDANCE_ROT_KD = 5  

Config.TRICK_ACTIVATION_DELAY = 0.5

-- Input Configuration
Config.INPUT_DEADZONE_STICK = 0.15 
Config.TOUCH_STICK_SENSITIVITY = 1.0 
Config.GAMEPAD_STICK_SENSITIVITY = 1.0 

return Config