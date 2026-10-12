--!strict
-- Tiny construction helpers shared by the arena and training builders.

local Build = {}

export type Props = { [string]: any }

-- Creates an anchored, non-interactive decorative part. Pass `solid = true`
-- for geometry players stand on or collide with.
function Build.part(parent: Instance, props: Props): BasePart
	local className = props.ClassName or "Part"
	local p = Instance.new(className) :: BasePart
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	local solid = props.solid == true
	p.CanCollide = solid
	p.CanTouch = false
	p.CanQuery = solid
	p.CastShadow = props.CastShadow == true
	for k, v in props do
		if k ~= "ClassName" and k ~= "solid" and k ~= "Parent" and k ~= "CastShadow" then
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

function Build.model(parent: Instance, name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

function Build.folder(parent: Instance, name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

-- A text label painted on the top face of a flat part.
function Build.topText(p: BasePart, text: string, color: Color3, transparency: number?, font: Enum.Font?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.LightInfluence = 0.6
	gui.Parent = p
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.TextScaled = true
	label.Font = font or Enum.Font.GothamBlack
	label.TextColor3 = color
	label.TextTransparency = transparency or 0
	label.Parent = gui
end

-- Billboard sign floating above a part.
function Build.sign(adornee: BasePart, title: string, subtitle: string?, color: Color3?): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(260, 74)
	gui.StudsOffset = Vector3.new(0, 4.5, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 140
	gui.LightInfluence = 0
	gui.Adornee = adornee
	gui.Parent = adornee
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
	frame.BackgroundTransparency = 0.15
	frame.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Color3.fromRGB(90, 230, 255)
	stroke.Thickness = 2
	stroke.Parent = frame
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.new(1, -16, 0, 34)
	t.Position = UDim2.fromOffset(8, 6)
	t.Font = Enum.Font.GothamBlack
	t.TextScaled = true
	t.TextColor3 = Color3.new(1, 1, 1)
	t.Text = title
	t.Parent = frame
	if subtitle then
		local s = Instance.new("TextLabel")
		s.BackgroundTransparency = 1
		s.Size = UDim2.new(1, -16, 0, 22)
		s.Position = UDim2.fromOffset(8, 42)
		s.Font = Enum.Font.GothamMedium
		s.TextScaled = true
		s.TextColor3 = Color3.fromRGB(190, 200, 215)
		s.Text = subtitle
		s.Parent = frame
	end
	return gui
end

function Build.light(parent: BasePart, className: string, props: Props): Light
	local l = Instance.new(className) :: Light
	for k, v in props do
		(l :: any)[k] = v
	end
	l.Parent = parent
	return l
end

return Build
