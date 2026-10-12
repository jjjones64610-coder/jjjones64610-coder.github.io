--!strict
--[[
	CameraController — over-the-shoulder orbit camera that doubles as the aim.

	Yaw/pitch come from the mouse (locked to the centre during play), the right
	gamepad stick or a touch drag. The camera pulls in when something solid is
	behind the player, widens its FOV slightly with speed and can add a small,
	optional shake. It never takes control away (no forced cinematics).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CameraController = {}

local controllers: any
local camera: Camera
local yaw = 0
local pitch = math.rad(-12)
local distance = 12
local targetDistance = 12
local focus: Vector3? = nil
local fov = 72
local kick = 0
local shakeAmp = 0
local shakeUntil = 0
local locked = true
local gamepadLook = Vector2.zero
local touchDelta = Vector2.zero

local MIN_PITCH = math.rad(-70)
local MAX_PITCH = math.rad(55)
local SHOULDER = 1.7

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

function CameraController.kick(amount: number)
	kick = math.max(kick, amount)
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

function CameraController.isLocked(): boolean
	return locked and not controllers.InputController.menuOpen()
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
	local target = root.Position + Vector3.new(0, 2.3, 0)
	local f = focus
	if f == nil or (f - target).Magnitude > 30 then
		f = target
	else
		f = f:Lerp(target, 1 - math.exp(-28 * dt))
	end
	focus = f

	local rot = CFrame.fromOrientation(pitch, yaw, 0)
	local look = rot.LookVector
	local right = rot.RightVector
	distance += (targetDistance - distance) * (1 - math.exp(-10 * dt))
	local pivot = (f :: Vector3) + right * SHOULDER
	local desired = pivot - look * distance

	-- pull in when blocked
	local exclude: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	local bots = workspace:FindFirstChild("UBBots")
	if bots then
		table.insert(exclude, bots)
	end
	local visuals = workspace:FindFirstChild("UBVisuals")
	if visuals then
		table.insert(exclude, visuals)
	end
	rayParams.FilterDescendantsInstances = exclude
	local hit = workspace:Raycast(pivot, desired - pivot, rayParams)
	local camPos = if hit then hit.Position + hit.Normal * 0.4 else desired

	-- feel: speed FOV, kick, shake
	local v = root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local baseFov = settings.get("FieldOfView")
	local targetFov = baseFov + math.clamp((speed - 17) / 9, 0, 1) * 5 + kick
	fov += (targetFov - fov) * (1 - math.exp(-8 * dt))
	kick = math.max(0, kick - 30 * dt)
	camera.FieldOfView = fov

	local cf = CFrame.lookAt(camPos, camPos + look)
	local clock = os.clock()
	if clock < shakeUntil then
		local a = shakeAmp * (shakeUntil - clock) / 0.3
		cf *= CFrame.new(math.noise(clock * 30, 1) * a, math.noise(clock * 30, 2) * a, 0)
	else
		shakeAmp = 0
	end
	camera.CFrame = cf
	camera.Focus = CFrame.new(f :: Vector3)
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
				targetDistance = math.clamp(targetDistance - input.Position.Z * 1.5, 7, 22)
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
			focus = nil
		end
	end)
	RunService:BindToRenderStep("UBCamera", Enum.RenderPriority.Camera.Value + 1, update)
end

return CameraController
