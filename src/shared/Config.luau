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
Config.MAX_THRUST_FORCE = 80 -- Base thrust at reference altitude

Config.TARGET_PITCH_RATE_MAX = math.rad(270) -- degrees/sec (Increased from 180)
Config.TARGET_ROLL_RATE_MAX = math.rad(270)  -- degrees/sec (Increased from 180)
Config.TARGET_YAW_RATE_MAX = math.rad(220)   -- degrees/sec (Increased significantly from 120)

Config.ATTITUDE_P_GAIN = 0.045  -- Increased from 0.03 for snappier response
Config.ATTITUDE_D_GAIN = 0.022  -- Increased from 0.015, adjust if too wobbly or too sluggish

Config.DRAG_COEFFICIENT_LINEAR = 0.07    -- Slightly reduced
Config.DRAG_COEFFICIENT_QUADRATIC = 0.04 -- Slightly reduced
Config.DRAG_COEFFICIENT_ANGULAR = 0.08   -- Significantly reduced from 0.15 for faster rotation

-- Altitude-Based Thrust Scaling
Config.ALTITUDE_THRUST_SCALING_ENABLED = true
Config.REFERENCE_ALTITUDE_FOR_MAX_THRUST = 0 -- Y-coordinate (e.g., sea level)
Config.THRUST_FALLOFF_FACTOR_PER_METER = 0.0005 -- e.g., 0.05% thrust loss per meter above ref. altitude
                                              -- (Value is a fraction, so 0.0005 means 1 - (altitude_diff * 0.0005))
Config.MIN_THRUST_EFFICIENCY_AT_ALTITUDE = 0.2 -- Drone always has at least 20% of its base thrust

-- Safe Envelope (Consider adjusting if snappier controls lead to more extreme states)
Config.MAX_SAFE_ATTITUDE_DEGREES = 80 -- Increased slightly
Config.MAX_SAFE_ROLL_RATE_DPS = 450 
Config.MAX_SAFE_PITCH_RATE_DPS = 450 
Config.MAX_SAFE_YAW_RATE_DPS = 360   

-- PD Controller Gains for SERVER Guided Modes (Gazebo or Fallback)
Config.GUIDANCE_POS_KP = 25  
Config.GUIDANCE_POS_KD = 10  
Config.GUIDANCE_ROT_KP = 18  -- Slightly increased for server guidance responsiveness
Config.GUIDANCE_ROT_KD = 6   -- Slightly increased

Config.TRICK_ACTIVATION_DELAY = 0.5 

-- Reorientation (F key)
Config.REORIENT_DURATION = 0.65 -- Slightly faster reorient
Config.REORIENT_ROT_KP = 22 
Config.REORIENT_ROT_KD = 3.5  
Config.REORIENT_TIMEOUT_BUFFER = 0.5 

return Config