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
Config.MAX_THRUST_FORCE = 80 

Config.TARGET_PITCH_RATE_MAX = math.rad(180) -- degrees/sec
Config.TARGET_ROLL_RATE_MAX = math.rad(180)  -- degrees/sec
Config.TARGET_YAW_RATE_MAX = math.rad(120)   -- degrees/sec

Config.ATTITUDE_P_GAIN = 0.03  
Config.ATTITUDE_D_GAIN = 0.015     

Config.DRAG_COEFFICIENT_LINEAR = 0.08    
Config.DRAG_COEFFICIENT_QUADRATIC = 0.05 
Config.DRAG_COEFFICIENT_ANGULAR = 0.15   

-- Safe Envelope 
Config.MAX_SAFE_ATTITUDE_DEGREES = 75
Config.MAX_SAFE_ROLL_RATE_DPS = 360 
Config.MAX_SAFE_PITCH_RATE_DPS = 360 
Config.MAX_SAFE_YAW_RATE_DPS = 270   

-- PD Controller Gains for SERVER Guided Modes (Gazebo or Fallback)
Config.GUIDANCE_POS_KP = 25  
Config.GUIDANCE_POS_KD = 10  
Config.GUIDANCE_ROT_KP = 15  
Config.GUIDANCE_ROT_KD = 5   

Config.TRICK_ACTIVATION_DELAY = 0.5 

-- Reorientation (F key)
Config.REORIENT_DURATION = 0.75 
Config.REORIENT_ROT_KP = 20 
Config.REORIENT_ROT_KD = 3  

return Config