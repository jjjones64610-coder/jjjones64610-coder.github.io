--!strict
--[[
	MainMenu — the title screen shown when you join: the store art behind,
	the ULTIMATE: BREAKPOINT logo, your level and coins, and PLAY 3v3 / PLAY
	7v7 / TRAINING / SHOP / LOCKER / SETTINGS (a mode button is your vote, and
	alone it starts the match against bots at once). While it is up your character doesn't move
	(the input "menu open" flag) and the white-circle cursor follows the
	mouse. PLAY drops you into the match flow; the other buttons open the
	tab menu on that page. Art and sounds are ForgeGUI-made (Config/Art,
	Config/Audio).
]]

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Art = require(Shared.Config.Art)
local Theme = require(script.Parent.Theme)
local Menu = require(script.Parent.Menu)
local Net = require(Shared.Net)

local MainMenu = {}

local controllers: any
local gui: Frame? = nil
local info: TextLabel? = nil
local shown = false

local C = Theme.Colors

function MainMenu.isShown(): boolean
	return shown
end

local function hide(then_: (() -> ())?)
	local g = gui
	if not g or not shown then
		return
	end
	shown = false
	controllers.AudioController.play("MenuWhoosh")
	TweenService:Create(g, TweenInfo.new(0.35), { Position = UDim2.fromScale(0, -1) }):Play()
	task.delay(0.36, function()
		g.Visible = false
		g.Position = UDim2.fromScale(0, 0)
	end)
	controllers.InputController.setMenuOpen(false)
	if then_ then
		then_()
	end
end

function MainMenu.show()
	local g = gui
	if not g then
		return
	end
	shown = true
	g.Visible = true
	controllers.InputController.setMenuOpen(true)
	MainMenu.refresh()
end

function MainMenu.refresh()
	local l = info
	local p = Menu.profile()
	if l then
		l.Text = if p
			then string.format(
				'LEVEL %d  ·  <font color="#FFCD46">%d COINS</font>  ·  %s',
				p.level or 1,
				p.coins or 0,
				p.division or "Bronze"
			)
			else "Loading your profile..."
	end
end

local function bigButton(parent: Instance, order: number, text: string, primary: boolean, onClick: () -> ())
	local b = Theme.button(text, {
		Parent = parent,
		LayoutOrder = order,
		Size = UDim2.fromOffset(if primary then 320 else 280, if primary then 58 else 44),
		TextSize = if primary then 26 else 18,
		Font = Theme.Fonts.Heavy,
		BackgroundColor3 = if primary then C.Accent else C.PanelLight,
		TextColor3 = if primary then Color3.new(0, 0, 0) else C.Text,
	})
	b.Activated:Connect(function()
		controllers.AudioController.play("UiClick")
		onClick()
	end)
	return b
end

function MainMenu.build(parent: ScreenGui, c: any)
	controllers = c
	local root = Instance.new("Frame")
	root.Name = "MainMenu"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Color3.fromRGB(8, 10, 16)
	root.BorderSizePixel = 0
	root.ZIndex = 50
	root.Parent = parent
	local bg = Art.ui("MenuBackground")
	if bg then
		local img = Instance.new("ImageLabel")
		img.Name = "Background"
		img.Size = UDim2.fromScale(1, 1)
		img.BackgroundTransparency = 1
		img.Image = bg
		img.ScaleType = Enum.ScaleType.Crop
		img.ImageTransparency = 0.15
		img.ZIndex = 50
		img.Parent = root
	end
	-- a dark sweep on the left so the buttons read over the art
	local shade = Instance.new("Frame")
	shade.Size = UDim2.fromScale(0.55, 1)
	shade.BackgroundColor3 = Color3.new(0, 0, 0)
	shade.BorderSizePixel = 0
	shade.ZIndex = 51
	shade.Parent = root
	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	grad.Parent = shade

	local col = Instance.new("Frame")
	col.Name = "Column"
	col.BackgroundTransparency = 1
	col.Position = UDim2.new(0, 60, 0, 40)
	col.Size = UDim2.new(0, 520, 1, -80)
	col.ZIndex = 52
	col.Parent = root
	local list = Theme.list(12)
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Parent = col

	local logo = Art.ui("Logo")
	if logo then
		local l = Instance.new("ImageLabel")
		l.Name = "Logo"
		l.BackgroundTransparency = 1
		l.Image = logo
		l.ScaleType = Enum.ScaleType.Fit
		l.Size = UDim2.fromOffset(480, 230)
		l.LayoutOrder = 1
		l.ZIndex = 52
		l.Parent = col
	else
		Theme.label("ULTIMATE: BREAKPOINT", 44, {
			Parent = col,
			LayoutOrder = 1,
			Size = UDim2.fromOffset(520, 60),
			Font = Theme.Fonts.Heavy,
		})
	end
	info = Theme.label("", 16, {
		Parent = col,
		LayoutOrder = 2,
		Size = UDim2.fromOffset(480, 24),
		RichText = true,
		TextColor3 = C.Text,
	})
	-- pick a mode: it is your vote for the next match, and alone it starts now
	local function play(mode: string)
		hide(function()
			Net.event("Action"):FireServer("Vote", { mode = mode })
			Net.event("Action"):FireServer("StartNow", nil)
		end)
	end
	bigButton(col, 3, "PLAY 3v3 (MINI)", true, function()
		play("Mini")
	end)
	bigButton(col, 4, "PLAY 7v7 (FULL FIELD)", true, function()
		play("Normal")
	end)
	bigButton(col, 5, "TRAINING", false, function()
		hide(function()
			Net.event("Action"):FireServer("EnterTraining", nil)
		end)
	end)
	bigButton(col, 6, "SHOP", false, function()
		hide(function()
			Menu.openTab("Shop")
		end)
	end)
	bigButton(col, 7, "LOCKER", false, function()
		hide(function()
			Menu.openTab("Locker")
		end)
	end)
	bigButton(col, 8, "SETTINGS", false, function()
		hide(function()
			Menu.openTab("Settings")
		end)
	end)
	for _, d in col:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = math.max(d.ZIndex, 52)
		end
	end
	gui = root
	MainMenu.show()
end

return MainMenu
