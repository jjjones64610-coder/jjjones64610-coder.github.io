--!strict
--[[
	CameraController — over-the-shoulder orbit camera that doubles as the aim.

	Yaw/pitch come from the mouse (locked to the centre during play), the right
	gamepad stick or a touch drag. The mouse is never locked while a TextBox
	(chat) has focus, the game menu or the Roblox menu is open, or the player
	freed it (CameraLock key).

	Rig: the focus follows the root directly in X/Z and smooths only its height
	(absorbs landing bob). Looking up raises the orbit pivot (2.3 -> 4.5 studs)
	and pulls the camera in (to 7.5 studs) so a huck aim never scrapes the
	ground; the camera also never goes below the floor + 1.2. Walls are found
	with a sphere cast: the camera pulls in at once and eases back out. The
	field of view widens by at most 2.5 degrees at top speed (ramp tied to
	Config/Movement SprintSpeed, rising and falling slowly so cuts do not make
	it breathe); kicks are capped at 2 degrees. Mouse-wheel zoom 7..30 studs
	while not holding the disc. It never takes control away (no cinematics).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local MovementConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Movement"))

local CameraController = {}

local controllers: any
local camera: Camera
local yaw = 0
local pitch = math.rad(-12)
local distance = 12 -- smoothed zoom
local targetDistance = 12 -- zoom the wheel asks for
local collisionDistance = math.huge -- wall-limited distance (in at once, out slowly)
local focusY: number? = nil
local speedFov = 0
local kick = 0 -- requested punch (decays)
local kickShown = 0 -- what the FOV shows (eases toward kick)
local shakeAmp = 0
local shakeUntil = 0
local locked = true
local gamepadLook = Vector2.zero
local touchDelta = Vector2.zero

local MIN_PITCH = math.rad(-70)
local MAX_PITCH = math.rad(55)
local SHOULDER = 1.7
local PIVOT_HEIGHT = 2.3 -- orbit pivot above the root, level aim ...
local PIVOT_RAISE = 2.2 -- ... plus this much when looking fully up
local NEAR_DISTANCE = 7.5 -- distance when looking fully up
local MIN_ZOOM = 7
local MAX_ZOOM = 30
local FLOOR_CLEARANCE = 1.2
local WALL_RADIUS = 0.5
local WALL_OUT_RATE = 6
local FOCUS_Y_RATE = 12
local SPEED_FOV = 2.5 -- extra degrees at top speed
local SPEED_FOV_FROM = MovementConfig.SprintSpeed - 6 -- 22 with the current tuning
local SPEED_FOV_TO = MovementConfig.SprintSpeed + 4 -- 32
local MAX_KICK = 2

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

function CameraController.getYaw(): number
	return yaw
end

function CameraController.getPitch(): number
	return pitch
end

function CameraController.setYaw(y: number)
	yaw = y
end

function CameraController.getAimDirection(): Vector3
	return camera.CFrame.LookVector
end

function CameraController.getCFrame(): CFrame
	return camera.CFrame
end

-- Horizontal forward of the camera.
function CameraController.forward(): Vector3
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

-- A brief FOV punch (degrees, capped at MAX_KICK).
function CameraController.kick(amount: number)
	kick = math.max(kick, math.min(amount, MAX_KICK))
end

function CameraController.shake(amplitude: number, duration: number)
	if not controllers.SettingsController.get("CameraShake") then
		return
	end
	shakeAmp = math.max(shakeAmp, amplitude)
	shakeUntil = math.max(shakeUntil, os.clock() + duration)
end

function CameraController.setLocked(l: boolean)
	locked = l
end

-- Mouse captured for aiming: not while typing, in a menu or freed by the player.
function CameraController.isLocked(): boolean
	return locked
		and not controllers.InputController.menuOpen()
		and not GuiService.MenuIsOpen
		and UserInputService:GetFocusedTextBox() == nil
end

function CameraController.addTouchDelta(d: Vector2)
	touchDelta += d
end

local function update(dt: number)
	local player = Players.LocalPlayer
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	camera.CameraType = Enum.CameraType.Scriptable
	local settings = controllers.SettingsController
	local active = CameraController.isLocked()

	UserInputService.MouseBehavior = if active then Enum.MouseBehavior.LockCenter else Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = not active

	local invert = if settings.get("InvertY") then -1 else 1
	if active then
		local md = UserInputService:GetMouseDelta()
		local sens = 0.0042 * settings.get("MouseSensitivity")
		yaw -= md.X * sens
		pitch -= md.Y * sens * invert
	end
	if not controllers.InputController.menuOpen() then
		local gs = gamepadLook
		if gs.Magnitude > 0.12 then
			local sens = 3.4 * settings.get("GamepadSensitivity") * dt
			yaw -= gs.X * math.abs(gs.X) * sens
			pitch += gs.Y * math.abs(gs.Y) * sens * 0.7 * invert
		end
		if touchDelta.Magnitude > 0 then
			local sens = 0.006 * settings.get("TouchSensitivity")
			yaw -= touchDelta.X * sens
			pitch -= touchDelta.Y * sens * invert
		end
	end
	touchDelta = Vector2.zero
	pitch = math.clamp(pitch, MIN_PITCH, MAX_PITCH)

	if not root then
		return
	end
	local rp = root.Position
	-- focus: X/Z follow directly, height is smoothed (landing bob)
	local fy = focusY
	if fy == nil or math.abs(fy - rp.Y) > 20 then
		fy = rp.Y
	else
		fy += (rp.Y - fy) * (1 - math.exp(-FOCUS_Y_RATE * dt))
	end
	focusY = fy
	local up = math.max(pitch, 0) / MAX_PITCH -- 0 level .. 1 looking fully up
	local f = Vector3.new(rp.X, (fy :: number) + PIVOT_HEIGHT + PIVOT_RAISE * up, rp.Z)

	local rot = CFrame.fromOrientation(pitch, yaw, 0)
	local look = rot.LookVector
	local right = rot.RightVector
	distance += (targetDistance - distance) * (1 - math.exp(-10 * dt))
	local near = math.min(distance, NEAR_DISTANCE)
	local want = distance + (near - distance) * up
	local pivot = f + right * SHOULDER

	local exclude: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	for _, name in { "UBBots", "UBVisuals" } do
		local folder = workspace:FindFirstChild(name)
		if folder then
			table.insert(exclude, folder)
		end
	end
	rayParams.FilterDescendantsInstances = exclude

	-- walls pull the camera in at once and release it gently; the floor never
	-- pulls in (the height clamp below handles it)
	local allowed = want
	local hit = workspace:Spherecast(pivot, WALL_RADIUS, -look * want, rayParams)
	if hit and hit.Normal.Y <= 0.7 then
		allowed = math.max(0.5, hit.Distance)
	end
	if allowed < collisionDistance then
		collisionDistance = allowed
	else
		collisionDistance += (allowed - collisionDistance) * (1 - math.exp(-WALL_OUT_RATE * dt))
	end
	collisionDistance = math.min(collisionDistance, want)
	local camPos = pivot - look * collisionDistance
	local floor = workspace:Raycast(pivot, Vector3.new(0, -80, 0), rayParams)
	if floor then
		local minY = floor.Position.Y + FLOOR_CLEARANCE
		if camPos.Y < minY then
			camPos = Vector3.new(camPos.X, minY, camPos.Z)
		end
	end

	-- feel: speed FOV (slow to rise, slower to fall), small kicks, shake
	local v = root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local speedTarget = math.clamp((speed - SPEED_FOV_FROM) / (SPEED_FOV_TO - SPEED_FOV_FROM), 0, 1) * SPEED_FOV
	local fovRate = if speedTarget > speedFov then 3 else 1.5
	speedFov += (speedTarget - speedFov) * (1 - math.exp(-fovRate * dt))
	kick = math.max(0, kick - 12 * dt)
	kickShown += (kick - kickShown) * (1 - math.exp(-25 * dt))
	camera.FieldOfView = settings.get("FieldOfView") + speedFov + kickShown

	local cf = CFrame.lookAt(camPos, camPos + look)
	local clock = os.clock()
	if clock < shakeUntil then
		local a = shakeAmp * (shakeUntil - clock) / 0.3
		cf *= CFrame.new(math.noise(clock * 30, 1) * a, math.noise(clock * 30, 2) * a, 0)
	else
		shakeAmp = 0
	end
	camera.CFrame = cf
	camera.Focus = CFrame.new(f)
end

function CameraController.Init(c: any)
	controllers = c
	camera = workspace.CurrentCamera
end

function CameraController.Start()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		camera = workspace.CurrentCamera
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.KeyCode == Enum.KeyCode.Thumbstick2 then
			gamepadLook = Vector2.new(input.Position.X, input.Position.Y)
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and not gameProcessed then
			-- wheel zooms only while not holding a disc (then it cycles throw type)
			if not controllers.ThrowController.isHolding() then
				targetDistance = math.clamp(targetDistance - input.Position.Z * 1.5, MIN_ZOOM, MAX_ZOOM)
			end
		end
	end)
	controllers.InputController.ActionBegan:Connect(function(action)
		if action == "CameraLock" then
			locked = not locked
		end
	end)
	-- initial yaw: face the way the character faces
	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(function(character)
		local root = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?
		if root then
			local lv = root.CFrame.LookVector
			yaw = math.atan2(-lv.X, -lv.Z)
			focusY = nil
			collisionDistance = math.huge
		end
	end)
	RunService:BindToRenderStep("UBCamera", Enum.RenderPriority.Camera.Value + 1, update)
end

return CameraController
