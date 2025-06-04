-- src/shared/Config.luau
local Config = {}

-- Orchestrator
Config.ORCHESTRATOR_HTTP_BASE_URL = "http://scspdrone.mithran.org:28642" 
Config.ROSOCKET_CONNECTION_URL = string.gsub(Config.ORCHESTRATOR_HTTP_BASE_URL, "http", "ws") .. "/ws_gazebo_orchestrator"
Config.WORLD_OBSTACLES_ENDPOINT = Config.ORCHESTRATOR_HTTP_BASE_URL .. "/world_obstacles"
Config.DRONE_SPECS_ENDPOINT = Config.ORCHESTRATOR_HTTP_BASE_URL .. "/drone_specs"
Config.HTTP_TIMEOUT_SECONDS = 5 

-- Drone Physics (Player Controlled Flight)
Config.DRONE_MASS_KG_DEFAULT = 0.05 
Config.CUSTOM_GRAVITY_Y = -196.2 
Config.MAX_THRUST_FORCE = 80 -- For larger drone body (1, 0.5, 1) with density 0.7 giving ~0.35kg mass

Config.TARGET_PITCH_RATE_MAX = math.rad(180) 
Config.TARGET_ROLL_RATE_MAX = math.rad(180)  
Config.TARGET_YAW_RATE_MAX = math.rad(120)   

-- ADJUSTED GAINS: These were likely too low previously.
Config.ATTITUDE_P_GAIN = 0.05  -- Significantly increased P-Gain for responsiveness (was 0.0001)
Config.ATTITUDE_D_GAIN = 0.005     -- Added some D-Gain for damping (was 0.0)

Config.DRAG_COEFFICIENT_LINEAR = 0.08    
Config.DRAG_COEFFICIENT_QUADRATIC = 0.05 
Config.DRAG_COEFFICIENT_ANGULAR = 0.02   

-- Safe Envelope 
Config.MAX_SAFE_ATTITUDE_DEGREES = 75
Config.MAX_SAFE_ROLL_RATE_DPS = 360 
Config.MAX_SAFE_PITCH_RATE_DPS = 360 
Config.MAX_SAFE_YAW_RATE_DPS = 270   

-- PD Controller Gains for Gazebo Guided Modes (these seem okay for now)
Config.GUIDANCE_POS_KP = 75 
Config.GUIDANCE_POS_KD = 15 
Config.GUIDANCE_ROT_KP = 40 
Config.GUIDANCE_ROT_KD = 5  

Config.TRICK_ACTIVATION_DELAY = 0.5

-- Input Configuration (Gamepad/Touch related constants removed)
-- Config.INPUT_DEADZONE_STICK = 0.15 -- REMOVED
-- Config.TOUCH_STICK_SENSITIVITY = 1.0 -- REMOVED (not used for flight)
-- Config.GAMEPAD_STICK_SENSITIVITY = 1.0 -- REMOVED

return Config