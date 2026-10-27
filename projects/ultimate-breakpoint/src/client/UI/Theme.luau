--!strict
-- Visual language for every screen: dark translucent panels, bold condensed
-- type, team colours as accents. `make` builds instance trees declaratively.
-- Technique colours (one per technique, shared by HUD and world effects) and
-- combo tier colours live here too, plus `keyText` for "Q SNAP CUT" style
-- key prompts.

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
