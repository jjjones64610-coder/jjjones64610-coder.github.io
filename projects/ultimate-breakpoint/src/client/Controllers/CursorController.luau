--!strict
--[[
	CursorController — the only cursor is a white circle. The system mouse
	arrow is never shown: in play (mouse locked) the circle sits at the centre
	as the crosshair; in menus it follows the mouse (clicks still work, the
	arrow is just hidden). On touch it is hidden; on a gamepad it stays at the
	centre.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CursorController = {}

local controllers: any
local player = Players.LocalPlayer
local ring: Frame? = nil
local dot: Frame? = nil

local SIZE = 22
local THICKNESS = 2

local function build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "UBCursor"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 100 -- above every other screen
	gui.Parent = player:WaitForChild("PlayerGui")
	local r = Instance.new("Frame")
	r.Name = "Ring"
	r.AnchorPoint = Vector2.new(0.5, 0.5)
	r.Size = UDim2.fromOffset(SIZE, SIZE)
	r.BackgroundTransparency = 1
	r.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = r
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = THICKNESS
	stroke.Transparency = 0.05
	stroke.Parent = r
	-- a thin dark outline under it so it reads on bright turf and sky
	local shadow = Instance.new("UIStroke")
	shadow.Name = "Shadow"
	shadow.Color = Color3.new(0, 0, 0)
	shadow.Thickness = THICKNESS + 2
	shadow.Transparency = 0.75
	shadow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	local inner = Instance.new("Frame")
	inner.Name = "Outline"
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.new(1, 0, 1, 0)
	inner.BackgroundTransparency = 1
	inner.ZIndex = 0
	inner.Parent = r
	local ic = Instance.new("UICorner")
	ic.CornerRadius = UDim.new(1, 0)
	ic.Parent = inner
	shadow.Parent = inner
	local d = Instance.new("Frame")
	d.Name = "Dot"
	d.AnchorPoint = Vector2.new(0.5, 0.5)
	d.Position = UDim2.fromScale(0.5, 0.5)
	d.Size = UDim2.fromOffset(3, 3)
	d.BackgroundColor3 = Color3.new(1, 1, 1)
	d.BorderSizePixel = 0
	d.Parent = r
	local dc = Instance.new("UICorner")
	dc.CornerRadius = UDim.new(1, 0)
	dc.Parent = d
	ring = r
	dot = d
end

local function update()
	local r = ring
	if not r then
		return
	end
	UserInputService.MouseIconEnabled = false
	local scheme = controllers.InputController.scheme()
	if scheme == "Touch" then
		r.Visible = false
		return
	end
	r.Visible = true
	local locked = controllers.CameraController.isLocked() and not controllers.InputController.menuOpen()
	local cam = workspace.CurrentCamera
	if locked or scheme == "Gamepad" or not cam then
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		r.Position = UDim2.fromOffset(vp.X / 2, vp.Y / 2)
	else
		local m = UserInputService:GetMouseLocation()
		r.Position = UDim2.fromOffset(m.X, m.Y)
	end
	local d = dot
	if d then
		d.Visible = locked
	end
end

function CursorController.Init(c: any)
	controllers = c
end

function CursorController.Start()
	build()
	RunService:BindToRenderStep("UBCursor", Enum.RenderPriority.Last.Value, update)
end

return CursorController
