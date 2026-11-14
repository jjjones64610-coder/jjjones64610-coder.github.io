--!strict
--[[
	InputController — the one place raw input becomes actions
	(docs/CORE_DESIGN.md). Keyboard / mouse, gamepad and touch all map onto
	the same short list in Config/Input: move, Jump, Burst, Primary,
	Secondary (+ Menu), and the Ability chord (Jump + Burst together).
	Nothing else in the game reads a key.

	Movement:
	  * WASD / arrows count only when they were pressed while no TextBox (chat
	    included) had focus, so typing never walks the character.
	  * Gamepad and touch sticks are reshaped (Config/Input Stick): below the
	    dead zone they read 0, from Full they read 1, linear in between.
	The Ability chord: every action in Config/Input.AbilityChord went down
	within its window. The actions still fire themselves first, so the jump
	is never delayed.

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
local scheme = "KBM"
local controls: any = nil

-- movement keys pressed while not typing (cleared on release / focus loss)
local moveKeys: { [Enum.KeyCode]: boolean } = {}

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

local function rebuild()
	keyMap = {}
	for _, s in { "keyboard", "gamepad" } do
		local b = controllers.SettingsController.bindings(s)
		for action, keys in b do
			if not table.find(InputConfig.Actions, action) then
				continue -- only the core actions can be bound (Config/Input)
			end
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

-- The ability chord (Config/Input AbilityChord): every listed action went
-- down within the window. The action itself still fires first.
local chordAt: { [string]: number } = {}
local CHORD = InputConfig.AbilityChord

local function checkChord(action: string)
	if not table.find(CHORD.actions, action) then
		return
	end
	local t = os.clock()
	chordAt[action] = t
	for _, a in CHORD.actions do
		local at = chordAt[a]
		if not held[a] or at == nil or t - at > CHORD.window then
			return
		end
	end
	table.clear(chordAt)
	InputController.ActionBegan:Fire("Ability", scheme)
	InputController.ActionEnded:Fire("Ability")
end

function InputController.fire(action: string, began: boolean)
	if began then
		if held[action] then
			return
		end
		held[action] = true
		InputController.ActionBegan:Fire(action, scheme)
		checkChord(action)
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
