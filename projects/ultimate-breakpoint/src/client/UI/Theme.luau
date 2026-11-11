--!strict
-- Visual language for every screen: dark translucent panels, bold condensed
-- type, team colours as accents. `make` builds instance trees declaratively.
-- Technique colours (one per technique, shared by HUD and world effects) and
-- combo tier colours live here too, plus `keyText` for "Q SNAP CUT" style
-- key prompts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Art = require(ReplicatedStorage:WaitForChild("Shared").Config.Art)

local Theme = {}

Theme.Colors = {
	Panel = Color3.fromRGB(14, 16, 24),
	PanelLight = Color3.fromRGB(28, 32, 44),
	Stroke = Color3.fromRGB(70, 80, 104),
	Text = Color3.fromRGB(240, 244, 250),
	Muted = Color3.fromRGB(150, 160, 180),
	Accent = Color3.fromRGB(90, 230, 255),
	Gold = Color3.fromRGB(255, 205, 70),
	Good = Color3.fromRGB(90, 240, 150),
	Bad = Color3.fromRGB(255, 90, 100),
	Perfect = Color3.fromRGB(255, 215, 80),
	Clean = Color3.fromRGB(210, 240, 255),
	Sloppy = Color3.fromRGB(255, 150, 90),
	Gassed = Color3.fromRGB(170, 170, 180),
	TeamA = Color3.fromRGB(32, 140, 255),
	TeamB = Color3.fromRGB(255, 120, 30),
}

Theme.Fonts = {
	Heavy = Enum.Font.GothamBlack,
	Bold = Enum.Font.GothamBold,
	Medium = Enum.Font.GothamMedium,
	Body = Enum.Font.Gotham,
}

-- Technique colours: each technique has a distinct, readable colour.
Theme.TechColors = {
	SnapCut = Color3.fromRGB(90, 230, 255),
	MomentumCancel = Color3.fromRGB(255, 120, 200),
	FakeCommit = Color3.fromRGB(200, 160, 255),
	BurstStep = Color3.fromRGB(255, 150, 40),
	Slide = Color3.fromRGB(230, 210, 150),
	SlideCut = Color3.fromRGB(250, 230, 120),
	Dive = Color3.fromRGB(255, 255, 255),
	RecoveryChain = Color3.fromRGB(120, 255, 170),
	AirRedirect = Color3.fromRGB(140, 180, 255),
	PrecisionLanding = Color3.fromRGB(255, 215, 80),
	WallRebound = Color3.fromRGB(255, 90, 200),
	AerialReach = Color3.fromRGB(180, 255, 255),
	Jump = Color3.fromRGB(200, 210, 230),
	PivotSwing = Color3.fromRGB(120, 220, 255),
	Break = Color3.fromRGB(255, 215, 80),
	-- tech engine
	Cut = Color3.fromRGB(90, 230, 255),
	Juke = Color3.fromRGB(200, 160, 255),
	PlantStop = Color3.fromRGB(255, 120, 200),
	LandingSlide = Color3.fromRGB(255, 215, 80),
	SlideHop = Color3.fromRGB(250, 230, 120),
	BurstKick = Color3.fromRGB(255, 150, 40),
	AirDodge = Color3.fromRGB(140, 180, 255),
	Wavedash = Color3.fromRGB(120, 255, 230),
	ReverseSnap = Color3.fromRGB(255, 90, 200),
	BurstDive = Color3.fromRGB(255, 110, 60),
	DiscReset = Color3.fromRGB(90, 230, 255),
	Layout = Color3.fromRGB(255, 255, 255),
	TechRoll = Color3.fromRGB(120, 255, 170),
	Sky = Color3.fromRGB(180, 255, 255),
	-- world-class tech
	FlipReset = Color3.fromRGB(255, 70, 220),
	ResetFlip = Color3.fromRGB(255, 70, 220),
	Stall = Color3.fromRGB(160, 120, 255),
	ZapDash = Color3.fromRGB(120, 255, 255),
	WallKick = Color3.fromRGB(255, 160, 60),
	Pinch = Color3.fromRGB(255, 60, 90),
}

-- Combo tier words (ComboEvaluator.Tiers) and their colours.
Theme.TierColors = {
	NICE = Color3.fromRGB(210, 240, 255),
	SLICK = Color3.fromRGB(90, 230, 255),
	FILTHY = Color3.fromRGB(255, 150, 90),
	BREAKPOINT = Color3.fromRGB(255, 215, 80),
} :: { [string]: Color3 }

function Theme.tierColor(tier: string?): Color3
	return if tier then Theme.TierColors[tier] or Theme.Colors.Gold else Theme.Colors.Text
end

function Theme.qualityColor(q: string): Color3
	return (Theme.Colors :: any)[q] or Theme.Colors.Text
end

function Theme.teamColor(team: string?): Color3
	if team == "A" then
		return Theme.Colors.TeamA
	elseif team == "B" then
		return Theme.Colors.TeamB
	end
	return Theme.Colors.Muted
end

export type Props = { [any]: any }

-- make("Frame", { Size = ..., [1] = child, [2] = child })
function Theme.make(className: string, props: Props?): Instance
	local inst = Instance.new(className)
	local parent: Instance? = nil
	if props then
		for k, v in props do
			if type(k) == "number" then
				(v :: Instance).Parent = inst
			elseif k == "Parent" then
				parent = v
			else
				(inst :: any)[k] = v
			end
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

function Theme.corner(radius: number?): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 10)
	return c
end

function Theme.stroke(color: Color3?, thickness: number?, transparency: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.Colors.Stroke
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0.3
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	return s
end

function Theme.padding(px: number): UIPadding
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, px)
	p.PaddingRight = UDim.new(0, px)
	p.PaddingTop = UDim.new(0, px)
	p.PaddingBottom = UDim.new(0, px)
	return p
end

function Theme.panel(props: Props?): Frame
	local f = Theme.make("Frame", {
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = 0.18,
		BorderSizePixel = 0,
		Theme.corner(12) :: Instance,
		Theme.stroke() :: Instance,
	}) :: Frame
	if props then
		for k, v in props do
			if type(k) == "number" then
				(v :: Instance).Parent = f
			else
				(f :: any)[k] = v
			end
		end
	end
	return f
end

function Theme.label(text: string, size: number, props: Props?): TextLabel
	local l = Theme.make("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		TextSize = size,
		Font = Theme.Fonts.Bold,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, size + 6),
	}) :: TextLabel
	if props then
		for k, v in props do
			if type(k) == "number" then
				(v :: Instance).Parent = l
			else
				(l :: any)[k] = v
			end
		end
	end
	return l
end

-- Puts an uploaded image (Config/Art) behind a frame or button in place of
-- its drawn background and outline. Does nothing for an empty slot. With
-- `plainColor`, the image shows only while the background is that colour:
-- a button recoloured to show a state (selected tab, toggle on, the gold
-- call to action) keeps its drawn look, so the state stays readable.
function Theme.skin(target: GuiObject, artName: string, plainColor: Color3?): ImageLabel?
	local image = Art.image(artName)
	if not image then
		return nil
	end
	local img = Instance.new("ImageLabel")
	img.Name = "Skin"
	img.BackgroundTransparency = 1
	img.Image = image
	img.ScaleType = Enum.ScaleType.Stretch
	img.Size = UDim2.fromScale(1, 1)
	img.ZIndex = target.ZIndex
	img.Parent = target
	-- A child always draws over its parent, so on a button the image would
	-- cover the button's own label: draw the label again on top of the image
	-- (kept in sync) and hide the original while the skin shows.
	local label: TextLabel? = nil
	if target:IsA("TextButton") then
		local btn = target :: TextButton
		local l = Instance.new("TextLabel")
		l.Name = "SkinText"
		l.BackgroundTransparency = 1
		l.Size = UDim2.fromScale(1, 1)
		l.ZIndex = btn.ZIndex + 1
		l.Parent = btn
		local function sync()
			l.Text = btn.Text
			l.Font = btn.Font
			l.TextSize = btn.TextSize
			l.TextColor3 = btn.TextColor3
			l.TextWrapped = btn.TextWrapped
			l.RichText = btn.RichText
			l.TextXAlignment = btn.TextXAlignment
			l.TextYAlignment = btn.TextYAlignment
			l.TextScaled = btn.TextScaled
		end
		sync()
		for _, prop in { "Text", "Font", "TextSize", "TextColor3", "TextWrapped", "RichText", "TextScaled" } do
			btn:GetPropertyChangedSignal(prop):Connect(sync)
		end
		btn:GetPropertyChangedSignal("ZIndex"):Connect(function()
			img.ZIndex = btn.ZIndex
			l.ZIndex = btn.ZIndex + 1
		end)
		label = l
	end
	local drawnTransparency = target.BackgroundTransparency
	local function update()
		local skinned = plainColor == nil or target.BackgroundColor3 == plainColor
		img.Visible = skinned
		local l = label
		if l then
			l.Visible = skinned;
			(target :: TextButton).TextTransparency = if skinned then 1 else 0
		end
		target.BackgroundTransparency = if skinned then 1 else drawnTransparency
		for _, child in target:GetChildren() do
			if child:IsA("UIStroke") then
				child.Enabled = not skinned
			end
		end
	end
	update()
	if plainColor then
		target:GetPropertyChangedSignal("BackgroundColor3"):Connect(update)
	end
	return img
end

function Theme.button(text: string, props: Props?): TextButton
	local b = Theme.make("TextButton", {
		BackgroundColor3 = Theme.Colors.PanelLight,
		BackgroundTransparency = 0.05,
		AutoButtonColor = true,
		Text = text,
		TextSize = 16,
		Font = Theme.Fonts.Bold,
		TextColor3 = Theme.Colors.Text,
		Size = UDim2.fromOffset(160, 38),
		Theme.corner(8) :: Instance,
		Theme.stroke(Theme.Colors.Stroke, 1, 0.4) :: Instance,
	}) :: TextButton
	if props then
		for k, v in props do
			if type(k) == "number" then
				(v :: Instance).Parent = b
			else
				(b :: any)[k] = v
			end
		end
	end
	Theme.skin(b, "Button", Theme.Colors.PanelLight)
	return b
end

function Theme.list(padding: number?, horizontal: boolean?): UIListLayout
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, padding or 6)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	return l
end

-- Rich-text prompt "<key> LABEL" with the key in the accent colour; just the
-- label when no key is bound (touch). Labels must not contain markup.
function Theme.keyText(key: string, label: string): string
	if key == "" then
		return label
	end
	return string.format('<font color="#5AE6FF">%s</font> %s', key, label)
end

function Theme.formatTime(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

return Theme
