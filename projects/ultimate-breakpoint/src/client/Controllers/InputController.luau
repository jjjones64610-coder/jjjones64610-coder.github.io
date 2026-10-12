--!strict
--[[
	InputController — one input vocabulary for keyboard/mouse, gamepad and
	touch. Raw inputs become named actions (Config/Input) that the movement,
	throw and catch controllers interpret in context. The same physical key
	may map to several actions (Q = Cut, or Bank Left while holding the disc);
	consumers decide which applies.

	Roblox's default character controls are disabled: this controller reads
	movement itself so every technique responds on the exact frame pressed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)

local InputController = {}

InputController.ActionBegan = Signal.new() -- (action)
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

local MOVE_KEYS: { { any } } = {
	{ Enum.KeyCode.W, Vector2.new(0, 1) },
	{ Enum.KeyCode.Up, Vector2.new(0, 1) },
	{ Enum.KeyCode.S, Vector2.new(0, -1) },
	{ Enum.KeyCode.Down, Vector2.new(0, -1) },
	{ Enum.KeyCode.A, Vector2.new(-1, 0) },
	{ Enum.KeyCode.Left, Vector2.new(-1, 0) },
	{ Enum.KeyCode.D, Vector2.new(1, 0) },
	{ Enum.KeyCode.Right, Vector2.new(1, 0) },
}

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

function InputController.scheme(): string
	return scheme
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
		InputController.ActionBegan:Fire(action)
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

function InputController.setMenuOpen(open: boolean)
	menuOpen = open
	if open then
		for action in table.clone(held) do
			InputController.fire(action, false)
		end
	end
end

function InputController.menuOpen(): boolean
	return menuOpen
end

function InputController.setTouchStick(v: Vector2)
	touchStick = v
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
	for _, entry in MOVE_KEYS do
		if UserInputService:IsKeyDown(entry[1]) then
			kb += entry[2]
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

function InputController.sprinting(): boolean
	if menuOpen then
		return false
	end
	local settings = controllers.SettingsController
	if scheme == "Touch" then
		if settings.get("AutoSprintTouch") and touchStick.Magnitude > 0.85 then
			return true
		end
		return sprintToggle
	end
	if settings.get("ToggleSprint") then
		return sprintToggle
	end
	return held.Sprint == true
end

function InputController.Init(c: any)
	controllers = c
end

function InputController.Start()
	-- take over character controls
	local player = Players.LocalPlayer
	task.spawn(function()
		local ok, PlayerModule = pcall(function()
			return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript) :: any
		end)
		if ok and PlayerModule then
			local controls = PlayerModule:GetControls()
			controls:Disable()
		end
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

	UserInputService.InputEnded:Connect(function(input, _gameProcessed)
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
			if p.Magnitude < 0.15 then
				p = Vector2.zero
			end
			gamepadStick = if p.Magnitude > 1 then p.Unit else p
			if p.Magnitude > 0 then
				setScheme("Gamepad")
			end
		elseif input.UserInputType == Enum.UserInputType.MouseWheel and not gameProcessed and not menuOpen then
			InputController.Wheel:Fire(input.Position.Z)
		end
	end)

	UserInputService.WindowFocusReleased:Connect(function()
		for action in table.clone(held) do
			InputController.fire(action, false)
		end
		gamepadStick = Vector2.zero
	end)

	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		setScheme("Touch")
	end
end

return InputController
