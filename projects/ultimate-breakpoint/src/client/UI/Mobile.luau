--!strict
--[[
	Mobile — touch controls with the full technique set.

	Left half: floating thumbstick (push it fully to auto-sprint, or use the
	SPRINT toggle). Right side: THROW/REACH (hold to charge), JUMP, CUT, SLIDE,
	DIVE, BURST, FAKE/MARK. While holding the disc, bank and type buttons
	appear. Dragging on empty screen space turns the camera.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)

local make = Theme.make
local C = Theme.Colors

local Mobile = {}

local controllers: any
local refs: { [string]: any } = {}
local stickTouch: InputObject? = nil
local stickOrigin = Vector2.zero
local cameraTouches: { [InputObject]: Vector2 } = {}
local buttonTouches: { [InputObject]: boolean } = {}

local STICK_RADIUS = 64

local function circleButton(
	parent: Instance,
	name: string,
	text: string,
	pos: UDim2,
	size: number,
	color: Color3?
): TextButton
	local b = make("TextButton", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = pos,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = color or C.Panel,
		BackgroundTransparency = 0.25,
		Text = text,
		TextSize = if size > 80 then 16 else 12,
		Font = Theme.Fonts.Heavy,
		TextColor3 = C.Text,
		AutoButtonColor = false,
		Parent = parent,
		Theme.corner(size) :: Instance,
		Theme.stroke(C.Stroke, 2, 0.2) :: Instance,
	}) :: TextButton
	return b
end

local function bindHold(button: TextButton, actionName: string)
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			buttonTouches[input] = true
			button.BackgroundTransparency = 0.05
			controllers.InputController.fire(actionName, true)
		end
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			buttonTouches[input] = nil
			button.BackgroundTransparency = 0.25
			controllers.InputController.fire(actionName, false)
		end
	end)
end

function Mobile.build(parent: ScreenGui, c: any)
	controllers = c
	local layer = make("Frame", {
		Name = "Touch",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = parent,
	}) :: Frame
	refs.layer = layer

	local stickBase = make("Frame", {
		Name = "StickBase",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(STICK_RADIUS * 2, STICK_RADIUS * 2),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.6,
		Visible = false,
		Parent = layer,
		Theme.corner(STICK_RADIUS),
	}) :: Frame
	local knob = make("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(52, 52),
		BackgroundColor3 = C.Text,
		BackgroundTransparency = 0.4,
		Parent = stickBase,
		Theme.corner(26),
	}) :: Frame
	refs.stickBase = stickBase
	refs.knob = knob

	local right = make("Frame", {
		Name = "Buttons",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -20, 1, -20),
		Size = UDim2.fromOffset(330, 300),
		BackgroundTransparency = 1,
		Parent = layer,
	})
	refs.buttons = right
	bindHold(circleButton(right, "Primary", "THROW\nREACH", UDim2.fromOffset(250, 220), 104, C.Accent), "Primary")
	bindHold(circleButton(right, "Jump", "JUMP", UDim2.fromOffset(150, 250), 70), "Jump")
	bindHold(circleButton(right, "Cut", "CUT", UDim2.fromOffset(160, 160), 66), "Cut")
	bindHold(circleButton(right, "Slide", "SLIDE", UDim2.fromOffset(60, 260), 60), "Slide")
	bindHold(circleButton(right, "Dive", "DIVE", UDim2.fromOffset(240, 110), 66), "Dive")
	bindHold(circleButton(right, "Burst", "BURST", UDim2.fromOffset(80, 175), 60), "Burst")
	bindHold(circleButton(right, "Secondary", "FAKE\nMARK", UDim2.fromOffset(310, 120), 58), "Secondary")
	local sprint = circleButton(right, "Sprint", "SPRINT", UDim2.fromOffset(40, 90), 54)
	sprint.Activated:Connect(function()
		controllers.InputController.toggleTouchSprint()
	end)

	local discRow = make("Frame", {
		Name = "DiscButtons",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -360, 1, -30),
		Size = UDim2.fromOffset(250, 60),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = layer,
		Theme.list(8, true),
	})
	refs.discRow = discRow
	for i, def in
		{ { "BankLeft", "< BANK" }, { "BankRight", "BANK >" }, { "TypeNext", "TYPE" }, { "LeadLock", "LEAD" } }
	do
		local b =
			Theme.button(def[2], { Parent = discRow, LayoutOrder = i, Size = UDim2.fromOffset(56, 52), TextSize = 12 })
		bindHold(b, def[1])
	end
	local menu = Theme.button("MENU", {
		Parent = layer,
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.fromOffset(16, 66),
		Size = UDim2.fromOffset(70, 34),
		TextSize = 13,
	})
	menu.Activated:Connect(function()
		controllers.UIController.toggleMenu()
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType ~= Enum.UserInputType.Touch or not layer.Visible or gameProcessed then
			return
		end
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		local screen = workspace.CurrentCamera.ViewportSize
		if pos.X < screen.X * 0.42 and stickTouch == nil then
			stickTouch = input
			stickOrigin = pos
			stickBase.Position = UDim2.fromOffset(pos.X, pos.Y)
			stickBase.Visible = true
		else
			cameraTouches[input] = pos
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		if input == stickTouch then
			local delta = pos - stickOrigin
			if delta.Magnitude > STICK_RADIUS then
				delta = delta.Unit * STICK_RADIUS
			end
			knob.Position = UDim2.new(0.5, delta.X, 0.5, delta.Y)
			local v = delta / STICK_RADIUS
			controllers.InputController.setTouchStick(Vector2.new(v.X, -v.Y))
		elseif cameraTouches[input] then
			local last = cameraTouches[input]
			controllers.CameraController.addTouchDelta(pos - last)
			cameraTouches[input] = pos
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input == stickTouch then
			stickTouch = nil
			stickBase.Visible = false
			knob.Position = UDim2.fromScale(0.5, 0.5)
			controllers.InputController.setTouchStick(Vector2.zero)
		end
		cameraTouches[input] = nil
	end)
	local _ = Players
end

function Mobile.update()
	local touch = controllers.InputController.scheme() == "Touch"
	local layer = refs.layer :: Frame
	layer.Visible = touch and not controllers.InputController.menuOpen()
	if not touch then
		return
	end
	local scale = controllers.SettingsController.get("TouchButtonScale") or 1
	local uiScale = refs.buttons:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = refs.buttons
	end
	(uiScale :: UIScale).Scale = scale
	refs.discRow.Visible = controllers.ThrowController.isHolding()
end

return Mobile
