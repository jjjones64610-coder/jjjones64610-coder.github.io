--!strict
--[[
	InputController — one input vocabulary for keyboard/mouse, gamepad and
	touch. Raw inputs become named actions (Config/Input) that the movement,
	throw and catch controllers interpret in context. The same physical key
	may map to several actions; consumers decide which applies (while holding
	the disc MovementController turns Cut / Dive into the Quick Swing).

	Movement:
	  * WASD / arrows count only when they were pressed while no TextBox (chat
	    included) had focus, so typing never walks the character.
	  * Gamepad and touch sticks are reshaped (Config/Input Stick): below the
	    dead zone they read 0, from Full they read 1, linear in between, so small
	    tilts start at a crawl and pads that never report 1.0 still reach top
	    speed.
	Sprint (sprinting()):
	  * Shift (hold) sprints at once; ToggleSprint turns it into a toggle.
	  * AutoSprint (setting, default on): once the move input has stayed at
	    least 0.9 for 0.3 s inside a 35 degree cone, you sprint until the input
	    drops (dips shorter than Config/Input AutoSprint.Grace are forgiven).
	    A plant (Cut with no direction held) never drops it: the no-input
	    moment is part of the technique, so the restart keeps sprint speed.
	  * Touch keeps its SPRINT toggle and AutoSprintTouch (stick pushed fully).

	Roblox's default character controls are off: StarterPlayer uses the
	Scriptable movement modes and the ControlModule is disabled again on every
	input-type change (switching device would otherwise re-enable it and it
	would call Humanoid:Move against MovementController).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)
local InputConfig = require(Shared.Config.Input)

local InputController = {}

InputController.ActionBegan = Signal.new() -- (action, scheme)
InputController.ActionEnded = Signal.new() -- (action)
InputController.Wheel = Signal.new() -- (delta)
InputController.SchemeChanged = Signal.new() -- (scheme)

local controllers: any
local held: { [string]: boolean } = {}
local keyMap: { [string]: { string } } = {}
local menuOpen = false
local gamepadStick = Vector2.zero
local touchStick = Vector2.zero
local sprintToggle = false
local scheme = "KBM"
local controls: any = nil

-- movement keys pressed while not typing (cleared on release / focus loss)
local moveKeys: { [Enum.KeyCode]: boolean } = {}

local auto = {
	since = nil :: number?, -- the strong input started (charging)
	dir = Vector2.zero, -- direction the charge started in
	weakSince = nil :: number?, -- the input dropped below MinMagnitude
	active = false,
}

local MOVE_KEYS: { [Enum.KeyCode]: Vector2 } = {
	[Enum.KeyCode.W] = Vector2.new(0, 1),
	[Enum.KeyCode.Up] = Vector2.new(0, 1),
	[Enum.KeyCode.S] = Vector2.new(0, -1),
	[Enum.KeyCode.Down] = Vector2.new(0, -1),
	[Enum.KeyCode.A] = Vector2.new(-1, 0),
	[Enum.KeyCode.Left] = Vector2.new(-1, 0),
	[Enum.KeyCode.D] = Vector2.new(1, 0),
	[Enum.KeyCode.Right] = Vector2.new(1, 0),
}

local AUTO = InputConfig.AutoSprint
local AUTO_CONE = math.cos(math.rad(AUTO.MaxAngle))

local function rebuild()
	keyMap = {}
	for _, s in { "keyboard", "gamepad" } do
		local b = controllers.SettingsController.bindings(s)
		for action, keys in b do
			for _, k in keys do
				local list = keyMap[k]
				if not list then
					list = {}
					keyMap[k] = list
				end
				if not table.find(list, action) then
					table.insert(list, action)
				end
			end
		end
	end
end

local function inputName(input: InputObject): string
	local t = input.UserInputType
	if
		t == Enum.UserInputType.MouseButton1
		or t == Enum.UserInputType.MouseButton2
		or t == Enum.UserInputType.MouseButton3
	then
		return t.Name
	end
	return input.KeyCode.Name
end

local function setScheme(s: string)
	if s ~= scheme then
		scheme = s
		InputController.SchemeChanged:Fire(s)
	end
end

-- Dead zone + full-push rescale (keeps the direction).
local function shape(v: Vector2, dead: number, full: number): Vector2
	local m = v.Magnitude
	if m < dead or m < 1e-4 then
		return Vector2.zero
	end
	local r = if m >= full then 1 else (m - dead) / (full - dead)
	return v * (r / m)
end

function InputController.scheme(): string
	return scheme
end

-- Short label of the key bound to `action` for the current scheme ("Q",
-- "SHIFT", "X"); "" on touch or when nothing is bound. Follows rebinds.
function InputController.keyLabel(action: string): string
	if scheme == "Touch" then
		return ""
	end
	return controllers.SettingsController.keyLabel(action, if scheme == "Gamepad" then "gamepad" else "keyboard")
end

function InputController.fire(action: string, began: boolean)
	if began then
		if held[action] then
			return
		end
		held[action] = true
		if action == "Sprint" and controllers.SettingsController.get("ToggleSprint") then
			sprintToggle = not sprintToggle
		end
		InputController.ActionBegan:Fire(action, scheme)
	else
		if not held[action] then
			return
		end
		held[action] = nil
		InputController.ActionEnded:Fire(action)
	end
end

function InputController.isHeld(action: string): boolean
	return held[action] == true
end

-- Ends every held action; `forgetKeys` also drops the movement keys (typing,
-- focus loss). A menu keeps them: rawMove is zero while it is open and a key
-- released meanwhile is noticed by IsKeyDown.
local function releaseAll(forgetKeys: boolean)
	for action in table.clone(held) do
		InputController.fire(action, false)
	end
	if forgetKeys then
		table.clear(moveKeys)
	end
end

function InputController.setMenuOpen(open: boolean)
	menuOpen = open
	if open then
		releaseAll(false)
	end
end

function InputController.menuOpen(): boolean
	return menuOpen
end

-- Raw touch stick (x = right, y = forward, magnitude 0..1); shaped here.
function InputController.setTouchStick(v: Vector2)
	touchStick = shape(v, InputConfig.Stick.TouchDead, InputConfig.Stick.TouchFull)
end

function InputController.toggleTouchSprint()
	sprintToggle = not sprintToggle
end

local function typing(): boolean
	return UserInputService:GetFocusedTextBox() ~= nil
end

-- Raw 2D stick: x = right, y = forward. Magnitude 0..1.
function InputController.rawMove(): Vector2
	if menuOpen or typing() then
		return Vector2.zero
	end
	local kb = Vector2.zero
	for key, dir in MOVE_KEYS do
		if moveKeys[key] then
			if UserInputService:IsKeyDown(key) then
				kb += dir
			else
				moveKeys[key] = nil -- a release we never saw (focus loss)
			end
		end
	end
	if kb.Magnitude > 1 then
		kb = kb.Unit
	end
	local best = kb
	if gamepadStick.Magnitude > best.Magnitude then
		best = gamepadStick
	end
	if touchStick.Magnitude > best.Magnitude then
		best = touchStick
	end
	return best
end

-- Camera-relative horizontal world direction (magnitude 0..1).
function InputController.moveVector(): Vector3
	local raw = InputController.rawMove()
	if raw.Magnitude < 0.01 then
		return Vector3.zero
	end
	local yaw = controllers.CameraController.getYaw()
	local forward = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	local right = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
	return forward * raw.Y + right * raw.X
end

-- True while the movement sim is in a plant (brake + restart window).
local function planting(): boolean
	local mc = controllers and controllers.MovementController
	return mc ~= nil and mc.sim().plantAt > 0
end

-- AutoSprint state machine (time based, so calling it several times per
-- frame is harmless).
local function autoSprinting(): boolean
	local t = os.clock()
	local raw = InputController.rawMove()
	local m = raw.Magnitude
	if m >= AUTO.MinMagnitude then
		auto.weakSince = nil
		local d = raw / m
		local since = auto.since
		if auto.active then
			return true
		elseif since == nil or d:Dot(auto.dir) < AUTO_CONE then
			auto.since = t
			auto.dir = d
		elseif t - since >= AUTO.ChargeTime then
			auto.active = true
		end
	else
		local weak = auto.weakSince
		if weak == nil then
			auto.weakSince = t
		elseif t - weak > AUTO.Grace and not planting() then
			auto.active = false
			auto.since = nil
		end
	end
	return auto.active
end

function InputController.sprinting(): boolean
	if menuOpen then
		return false
	end
	local settings = controllers.SettingsController
	local autoOn = autoSprinting() and settings.get("AutoSprint") == true
	if scheme == "Touch" then
		if settings.get("AutoSprintTouch") and touchStick.Magnitude > 0.85 then
			return true
		end
		return sprintToggle or autoOn
	end
	if settings.get("ToggleSprint") then
		return sprintToggle or autoOn
	end
	return held.Sprint == true or autoOn
end

local function disableDefaultControls()
	if controls then
		pcall(function()
			controls:Disable()
		end)
	end
end

function InputController.Init(c: any)
	controllers = c
end

function InputController.Start()
	-- take over character controls (Scriptable movement modes are set in the
	-- project; this is the backup, repeated whenever the input type changes)
	local player = Players.LocalPlayer
	task.spawn(function()
		local ok, PlayerModule = pcall(function()
			return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript) :: any
		end)
		if ok and PlayerModule then
			local okControls, c = pcall(function()
				return PlayerModule:GetControls()
			end)
			if okControls then
				controls = c
				disableDefaultControls()
			end
		end
	end)
	UserInputService.LastInputTypeChanged:Connect(function()
		disableDefaultControls()
	end)
	GuiService.AutoSelectGuiEnabled = false

	rebuild()
	controllers.SettingsController.Changed:Connect(function(key)
		if key == "Bindings" or key == "All" then
			rebuild()
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		local t = input.UserInputType
		if t == Enum.UserInputType.Gamepad1 then
			setScheme("Gamepad")
		elseif
			t == Enum.UserInputType.Keyboard
			or t == Enum.UserInputType.MouseButton1
			or t == Enum.UserInputType.MouseButton2
		then
			setScheme("KBM")
		elseif t == Enum.UserInputType.Touch then
			setScheme("Touch")
		end
		if gameProcessed or typing() then
			return
		end
		if t == Enum.UserInputType.Keyboard and MOVE_KEYS[input.KeyCode] then
			moveKeys[input.KeyCode] = true
		end
		local name = inputName(input)
		local actions = keyMap[name]
		if not actions then
			return
		end
		for _, action in actions do
			if action == "Menu" or action == "CameraLock" or not menuOpen then
				InputController.fire(action, true)
			end
		end
	end)

	-- releases are honoured even when the engine processed them (no stuck keys)
	UserInputService.InputEnded:Connect(function(input, _gameProcessed)
		if input.UserInputType == Enum.UserInputType.Keyboard then
			moveKeys[input.KeyCode] = nil
		end
		local actions = keyMap[inputName(input)]
		if actions then
			for _, action in actions do
				InputController.fire(action, false)
			end
		end
	end)

	UserInputService.InputChanged:Connect(function(input, gameProcessed)
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			local p = Vector2.new(input.Position.X, input.Position.Y)
			gamepadStick = shape(p, InputConfig.Stick.GamepadDead, InputConfig.Stick.GamepadFull)
			if gamepadStick.Magnitude > 0 then
				setScheme("Gamepad")
			end
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and not gameProcessed and not menuOpen then
			InputController.Wheel:Fire(input.Position.Z)
		end
	end)

	-- typing (chat, menus) or leaving the window never leaves keys held
	UserInputService.TextBoxFocused:Connect(function()
		releaseAll(true)
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		releaseAll(true)
		gamepadStick = Vector2.zero
		touchStick = Vector2.zero
	end)

	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		setScheme("Touch")
	end
end

return InputController
