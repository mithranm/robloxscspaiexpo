# Specification.md (Roblox Rojo Repository Perspective)

**Project Title:** Roblox FPV Drone Client with Gazebo-Assisted Maneuvers (Custom Physics & Configurable Drone)

**Version:** 3.0 (Parameterized Tricks, CSV Logging Ack, Drone Config Request)

**1. Overview & Purpose**

This document specifies the requirements for the Roblox client-side components of an FPV drone simulator. Players control drones using custom-scripted Luau flight dynamics (gravity, thrust, drag), with Roblox's engine handling collisions and motion integration. For complex "trick" maneuvers, the client requests trajectory guidance from an external Node.js Orchestration Server, which uses Gazebo for simulation. The client receives this guidance via `RoSocket` (over `HttpService`) and uses a Luau PD controller to steer its physics-enabled drone. Additionally, clients can request the Orchestration Server to (conceptually) use custom drone parameters for simulations.

**2. System Architecture within this Repository's Scope**

```
Roblox Client (Luau Scripts - this repository's deliverable)
│
├── Player Input Handling ───▶ Custom Flight Dynamics Module (Luau) ───▶ Apply Forces/Torques
│                                   │ - Custom Gravity, Thrust/Drag Model
│
├── UI Module (FPV View, HUD, Trick Buttons, Drone Config UI?)
│
├── Trick Activation Logic
│   │ - Detects trick conditions
│   └─ Sends REQUEST_TRICK (+ current state) via RoSocket Server Bridge
│
├── Drone Configuration Requester
│   └─ Sends CONFIGURE_DRONE (+ drone_params) via RoSocket Server Bridge
│
├── RoSocket Server Bridge Interface (Client-Side: RemoteEvents/Functions)
│   │ - Communicates with Server Script that uses actual RoSocket Lua Lib
│   └─ Receives Gazebo Trajectory Burst Data & Config ACKs
│
├── Trajectory Guidance Controller (Luau PD Controller)
│   │ - Activated for "trick mode", uses Gazebo trajectory data
│   └─ Calculates & applies forces/torques to local drone
│
└── Drone Model Setup (Roblox Parts)
    │ - BasePart.Massless = true (for custom gravity)
    └─ Collision Geometry, interacts with Roblox environment
```

**3. Functional Requirements**

**3.1. Drone Control & Custom Physics (Client-Side Luau)**
    *   **Custom Gravity & Forces:** Drone's `BasePart.Massless = true`. Luau scripts in `RunService.Stepped` apply custom gravity, thrust from player input, and basic air drag forces using `VectorForce` and `Torque` objects.
    *   Roblox engine integrates forces and handles collisions.

**3.2. User Interface (Client-Side Luau)**
    *   FPV View, HUD (scripted flight values).
    *   Button(s) for trick maneuvers.
    *   (Optional V3+) UI for players to input/select custom drone parameters (mass, rotor layout, etc.).

**3.3. Trick Maneuver System (Client-Side Luau)**
    *   **Activation:** On trick trigger, capture drone state, generate `original_request_id`. Send `REQUEST_TRICK` message (containing `roblox_client_id`, `original_request_id`, `drone_name`, `trick_type`, `initial_state`) to a Roblox Server Script via `RemoteFunction`.
    *   **Server Script Forwarding:** The Server Script uses its `RoSocket` instance to forward this `REQUEST_TRICK` to the Node.js Orchestration Server.
    *   **Guidance Data Reception:** The Server Script receives `TRICK_DATA_START/CHUNK/END/ERROR` messages from the Orchestrator via its `RoSocket.OnMessageReceived`. It then fires `RemoteEvent`s to the specific client with this data.
    *   **Client-Side Processing:** The client listens for these `RemoteEvent`s. On receiving trick data, it activates a Luau PD Trajectory Guidance Controller.
    *   **Trajectory Guidance Controller (Luau PD):** Guides the physics-enabled drone by applying forces/torques to follow the Gazebo trajectory.
    *   **Collision During Trick:** If Roblox detects a collision, abort trick, display "CRASHED," trigger respawn.

**3.4. Drone Configuration Request System (Client-Side Luau)**
    *   **UI Input (Optional V3+):** Player provides custom drone parameters (e.g., hull dimensions, mass, arm lengths from `drone_params.json` structure).
    *   **Request:** Client script sends `CONFIGURE_DRONE` message (containing `roblox_client_id`, `original_request_id`, `drone_params`) to a Roblox Server Script via `RemoteFunction`.
    *   **Server Script Forwarding:** Server Script forwards this to the Node.js Orchestration Server via `RoSocket`.
    *   **Acknowledgement Reception:** Server Script receives `CONFIGURE_DRONE_ACK` from Orchestrator and fires a `RemoteEvent` to the client.
    *   **Client Feedback:** Client displays acknowledgment/status message to the player. *Actual use of these parameters by Gazebo for the specific player's tricks is a future enhancement on the Orchestrator/Gazebo side.*

**3.5. Communication (Roblox Server Script with `RoSocket` Lua Lib)**
    *   A **Server Script** in `ServerScriptService` will:
        *   Require and initialize the `RoSocket` Lua library from `ServerStorage`.
        *   Connect to the Node.js Gazebo Orchestration Server's WebSocket endpoint (e.g., `ws://scspdrone.mithran.org:28642/ws_gazebo_orchestrator`).
        *   Handle `RemoteFunction` calls from clients for `REQUEST_TRICK` and `CONFIGURE_DRONE`. It will add `roblox_client_id` (derived from the Player object) and `original_request_id` (passed from client) to the payload sent to the Orchestrator.
        *   Listen to `RoSocket.Socket.OnMessageReceived`. When messages like `TRICK_DATA_CHUNK` arrive from the Orchestrator, parse them and use `RemoteEvent:FireClient(player, data_payload)` to send the relevant data to the correct client.
    *   Client-side Luau modules (`RoSocketManager.module.luau` or similar) will use `RemoteEvent:Connect()` and `RemoteFunction:InvokeServer()` to interact with this server script.

**3.6. Player Respawn Logic**
    *   Standard: On crash, move drone to spawn, reset physics.

**4. Non-Functional Requirements**
    *   Responsiveness, Smoothness, Rate Limit Adherence.

**5. Rojo & Wally Project Structure**
    *   Key Luau modules: `CustomDronePhysics.module.lua`, `TrickGuidanceController.module.lua`, `ClientToServerBridge.module.lua` (handles RemoteEvent/Function client-side calls), and a corresponding Server-Side `RoSocketHandler.module.lua` (or directly in `init.server.luau`).