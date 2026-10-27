--!strict
--[[
	ThrowHud — the thrower's panel, kept small so the field stays readable:
	  * throw type, release height chip and bank
	  * type chips (1-5) and the power meter with its Perfect band (and the
	    Lead assist's ideal-power mark)
	  * the step gauge: a top-down view around your pivot foot (up = where
	    you aim): the step range, your free foot, the nearest marker's hand
	    box (red when the preview says the throw would be blocked) and which
	    side is OPEN and which is the BREAK
	  * key hints and the throw description only for your first HINT_HOLDS
	    possessions of the session
	Release text appears only when it matters: a Perfect release, an
	overcharge, a hand block, or a hop the server did not see (released Mid).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local MovementConfig = require(Shared.Config.Movement)
local Net = require(Shared.Net)
local Theme = require(script.Parent.Theme)

local make = Theme.make
local C = Theme.Colors

local ThrowHud = {}

local HINT_HOLDS = 3
local GAUGE = 104 -- px
local GAUGE_STUDS = 6.2 -- studs from the pivot to the gauge edge
local RELEASE_TEXT_TIME = 1.6
local MARK = DiscConfig.Mark

local controllers: any
local refs: { [string]: any } = {}
local releaseText = { at = -math.huge, text = "", color = C.Text }

local function scale(): number
	return (GAUGE / 2) / GAUGE_STUDS
end

local function dot(parent: Instance, size: number, color: Color3, z: number): Frame
	return make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = z,
		Parent = parent,
		Theme.corner(size),
	}) :: Frame
end

local function buildGauge(panel: Frame)
	local gauge = make("Frame", {
		Name = "StepGauge",
		BackgroundColor3 = C.PanelLight,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(46, 76),
		Size = UDim2.fromOffset(GAUGE, GAUGE),
		Parent = panel,
		Theme.corner(GAUGE),
	}) :: Frame
	refs.gauge = gauge
	-- the step range (radius R)
	local r = math.floor(MovementConfig.Holding.StepRadius * scale() + 0.5)
	refs.ring = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(r * 2, r * 2),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = gauge,
		Theme.corner(r * 2) :: Instance,
		Theme.stroke(C.Muted, 1, 0.45) :: Instance,
	})
	-- aim direction tick
	make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 3),
		Size = UDim2.fromOffset(2, 9),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = gauge,
	})
	refs.markBox = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = C.TeamB,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 3,
		Parent = gauge,
		Theme.corner(3),
	})
	refs.markDot = dot(gauge, 9, C.Bad, 4)
	refs.markDot.Visible = false
	refs.pivotDot = dot(gauge, 10, C.Text, 5)
	refs.pivotDot.Position = UDim2.fromScale(0.5, 0.5)
	refs.footDot = dot(gauge, 12, C.Accent, 6)
	refs.leftSide = Theme.label("", 11, {
		Parent = panel,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromOffset(42, 76 + GAUGE / 2),
		Size = UDim2.fromOffset(40, 14),
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = Theme.Fonts.Heavy,
	})
	refs.rightSide = Theme.label("", 11, {
		Parent = panel,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromOffset(50 + GAUGE, 76 + GAUGE / 2),
		Size = UDim2.fromOffset(46, 14),
		Font = Theme.Fonts.Heavy,
	})
end

local function onFeedback(kind: any, payload: any)
	if kind ~= "Release" or type(payload) ~= "table" then
		return
	end
	local text, color = nil, C.Text
	if payload.blocked then
		text, color = "HAND BLOCKED — step out, fake or change height", C.Bad
	elseif payload.heightAsked == "High" and payload.heightUsed ~= "High" then
		text, color = "RELEASED MID — the hop was not seen", C.Sloppy
	elseif payload.quality == "Perfect" then
		text, color = "PERFECT RELEASE", C.Perfect
	elseif payload.quality == "Over" then
		text, color = "OVERCHARGED — less spin", C.Sloppy
	end
	if text then
		releaseText.at = os.clock()
		releaseText.text = text
		releaseText.color = color
	end
end

function ThrowHud.build(parent: ScreenGui, c: any)
	controllers = c
	local panel = Theme.panel({
		Name = "ThrowHud",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -18),
		Size = UDim2.fromOffset(250, 214),
		Parent = parent,
	})
	panel.Visible = false
	refs.panel = panel

	refs.type = Theme.label("BACKHAND", 22, {
		Parent = panel,
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.fromOffset(150, 26),
		Font = Theme.Fonts.Heavy,
	})
	refs.height = make("TextLabel", {
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(150, 12),
		Size = UDim2.fromOffset(44, 18),
		Text = "MID",
		TextSize = 11,
		Font = Theme.Fonts.Bold,
		TextColor3 = C.Accent,
		Parent = panel,
		Theme.corner(5),
	})

	local types = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 40),
		Size = UDim2.fromOffset(196, 20),
		Parent = panel,
		Theme.list(3, true),
	})
	refs.typeChips = {}
	for i, id in DiscConfig.TypeOrder do
		local info = (DiscConfig.Types :: any)[id]
		local chip = make("TextLabel", {
			BackgroundColor3 = C.PanelLight,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(37, 20),
			Text = i .. " " .. info.Short,
			TextSize = 10,
			Font = Theme.Fonts.Bold,
			TextColor3 = C.Muted,
			LayoutOrder = i,
			Parent = types,
			Theme.corner(5),
		})
		refs.typeChips[id] = chip
	end

	-- bank indicator: a tilting disc
	refs.bankDisc = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(28, 196),
		Size = UDim2.fromOffset(34, 6),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = panel,
		Theme.corner(3),
	})
	refs.bankText = Theme.label("FLAT", 11, {
		Parent = panel,
		Position = UDim2.fromOffset(50, 188),
		Size = UDim2.fromOffset(60, 16),
		TextColor3 = C.Muted,
	})
	refs.lead = Theme.label("", 11, {
		Parent = panel,
		Position = UDim2.fromOffset(104, 188),
		Size = UDim2.fromOffset(110, 16),
		TextColor3 = C.Good,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})

	buildGauge(panel)

	-- power meter (vertical, right edge). Full = 100%; the gold band is the
	-- Perfect window; red above it is overcharge.
	local meter = make("Frame", {
		Name = "Meter",
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
		Position = UDim2.new(1, -30, 0, 12),
		Size = UDim2.fromOffset(16, 190),
		Parent = panel,
		Theme.corner(6),
	})
	local meterScale = 1.4 -- meter shows up to 140% of the charge time
	local fullY = 1 - 1 / meterScale
	local perfectH = (DiscConfig.Throw.PerfectWindow / DiscConfig.Throw.ChargeTime) / meterScale
	make("Frame", {
		Name = "Perfect",
		BackgroundColor3 = C.Perfect,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, fullY - perfectH, 0),
		Size = UDim2.new(1, 0, perfectH, 0),
		ZIndex = 2,
		Parent = meter,
	})
	make("Frame", {
		Name = "Over",
		BackgroundColor3 = C.Bad,
		BackgroundTransparency = 0.7,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, fullY - perfectH, 0),
		ZIndex = 2,
		Parent = meter,
	})
	refs.fill = make("Frame", {
		Name = "Fill",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0),
		ZIndex = 3,
		Parent = meter,
		Theme.corner(6),
	})
	refs.ideal = make("Frame", {
		Name = "Ideal",
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = C.Good,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 8, 0, 3),
		Position = UDim2.new(0, -4, 0.5, 0),
		ZIndex = 4,
		Visible = false,
		Parent = meter,
	})
	refs.meterScale = meterScale

	-- first possessions only: what the throw does and the keys
	refs.hints = Theme.panel({
		Name = "ThrowHints",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -238),
		Size = UDim2.fromOffset(250, 52),
		Parent = parent,
	})
	refs.hints.Visible = false
	refs.desc = Theme.label("", 11, {
		Parent = refs.hints,
		Position = UDim2.fromOffset(10, 5),
		Size = UDim2.fromOffset(230, 16),
		TextColor3 = C.Text,
		Font = Theme.Fonts.Medium,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	refs.keys = Theme.label("", 10, {
		Parent = refs.hints,
		Position = UDim2.fromOffset(10, 22),
		Size = UDim2.fromOffset(230, 26),
		TextColor3 = C.Muted,
		TextWrapped = true,
		Font = Theme.Fonts.Medium,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	-- release text (shown briefly after the disc has left the hand)
	refs.release = Theme.label("", 15, {
		Parent = parent,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -18),
		Size = UDim2.fromOffset(360, 22),
		TextXAlignment = Enum.TextXAlignment.Right,
		Font = Theme.Fonts.Heavy,
		TextStrokeTransparency = 0.6,
		Visible = false,
	})

	Net.event("Feedback").OnClientEvent:Connect(onFeedback)
end

local function key(action: string, fallback: string): string
	local label = controllers.InputController.keyLabel(action)
	return if label ~= "" then label else fallback
end

local function hintText(scheme: string): string
	if scheme == "Gamepad" then
		return "LS step · X swing · LT fake · B low · A hop · RT throw · D-pad bank / type · R3 lead"
	elseif scheme == "Touch" then
		return "Stick: step around your pivot · hold THROW · FAKE · bank and type buttons"
	end
	return string.format(
		"WASD step · %s/%s swing · %s fake · %s low · %s hop · %s/%s bank · wheel type · %s lead",
		key("Cut", "Q"),
		key("Dive", "E"),
		key("Secondary", "RMB"),
		key("Slide", "C"),
		key("Jump", "SPACE"),
		key("BankLeft", "Z"),
		key("BankRight", "X"),
		key("LeadLock", "R")
	)
end

local function sideLabel(label: TextLabel, side: number, open: number)
	if open == 0 then
		label.Text = ""
	elseif side == open then
		label.Text = "OPEN"
		label.TextColor3 = C.Good
	else
		label.Text = "BREAK"
		label.TextColor3 = C.Gold
	end
end

local function updateGauge(h: { [string]: any })
	local k = scale()
	local half = GAUGE / 2
	local lim = half - 6
	local function at(x: number, y: number): UDim2
		local px = math.clamp(x * k, -lim, lim)
		local py = math.clamp(-y * k, -lim, lim)
		return UDim2.fromOffset(half + px, half + py)
	end
	refs.pivotDot.BackgroundColor3 = if h.pivoted then C.Text else C.Muted
	refs.footDot.Position = at(h.stepX, h.stepY)
	refs.footDot.Visible = h.pivoted

	local m = h.marker
	if m then
		local depthLen = MARK.DepthMax - MARK.DepthMin
		local mid = (MARK.DepthMax + MARK.DepthMin) / 2
		local cx, cy = m.x + m.fx * mid, m.y + m.fy * mid
		refs.markBox.Visible = m.stance ~= "Relaxed"
		refs.markBox.Size = UDim2.fromOffset(m.halfWidth * 2 * k, depthLen * k)
		refs.markBox.Position = at(cx, cy)
		refs.markBox.Rotation = math.deg(math.atan2(m.fx, m.fy))
		refs.markBox.BackgroundColor3 = if h.blocked then C.Bad elseif m.stance == "High" then C.Gold else C.TeamB
		refs.markDot.Visible = true
		refs.markDot.Position = at(m.x, m.y)
	else
		refs.markBox.Visible = false
		refs.markDot.Visible = false
	end
	sideLabel(refs.leftSide, -1, h.openSide)
	sideLabel(refs.rightSide, 1, h.openSide)
end

local function updateRelease()
	local label = refs.release :: TextLabel
	local age = os.clock() - releaseText.at
	if age > RELEASE_TEXT_TIME then
		label.Visible = false
		return
	end
	label.Visible = true
	label.Text = releaseText.text
	label.TextColor3 = releaseText.color
	label.TextTransparency = math.clamp((age - (RELEASE_TEXT_TIME - 0.4)) / 0.4, 0, 1)
end

function ThrowHud.update()
	updateRelease()
	local h = controllers.ThrowController.hud()
	local panel = refs.panel :: Frame
	panel.Visible = h.holding
	local showHints = h.holding and h.holds <= HINT_HOLDS
	refs.hints.Visible = showHints
	if not h.holding then
		return
	end
	-- while holding the panel covers the release text's spot
	refs.release.Visible = false
	local info = (DiscConfig.Types :: any)[h.throwType]
	refs.type.Text = string.upper(info.Display)
	for id, chip in refs.typeChips do
		local selected = id == h.throwType
		chip.BackgroundColor3 = if selected then C.Accent else C.PanelLight
		chip.TextColor3 = if selected then Color3.new(0, 0, 0) else C.Muted
	end
	refs.height.Text = string.upper(h.height)
	refs.height.TextColor3 = if h.height == "High" then C.Gold elseif h.height == "Low" then C.Good else C.Accent
	local bankDeg = h.bank / h.bankSteps * DiscConfig.Throw.BankRange
	refs.bankDisc.Rotation = bankDeg
	refs.bankText.Text = if h.bank == 0
		then "FLAT"
		elseif h.bank > 0 then ("BANK R" .. h.bank)
		else ("BANK L" .. -h.bank)
	refs.lead.Text = if h.leadLock then ("LEAD: " .. (h.leadName or "aim at a teammate")) else ""
	if showHints then
		refs.desc.Text = info.Description
		refs.keys.Text = hintText(controllers.InputController.scheme())
	end
	updateGauge(h)

	local frac = math.clamp(h.charge / refs.meterScale, 0, 1)
	refs.fill.Size = UDim2.fromScale(1, frac)
	refs.fill.BackgroundColor3 = if h.phase == "Perfect"
		then C.Perfect
		elseif h.phase == "Over" then C.Bad
		else Color3.new(1, 1, 1)
	if h.idealPower then
		refs.ideal.Visible = true
		refs.ideal.Position = UDim2.new(0, -4, 1 - h.idealPower / refs.meterScale, 0)
	else
		refs.ideal.Visible = false
	end
end

return ThrowHud
