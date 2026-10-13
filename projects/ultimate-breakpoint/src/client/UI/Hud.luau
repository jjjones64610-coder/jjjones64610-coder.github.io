--!strict
--[[
	Hud — only what helps a decision, plus short-lived feedback that says what
	just happened (and never more than one thing in one place).

	  Top     scoreboard (score, clock, phase) with the mode chip under it:
	          "MINI 3v3 · 2 PLAYERS + 4 BOTS", "RANKED · NORMAL 7v7", or the
	          lobby line during warm-up; the attack direction; the bench line
	          ("ON THE BENCH — you're in next point"); wind.
	  Centre  the crosshair. Just above it, feedback chips: the ready-made
	          MovementController.Feedback texts ("NEED SPEED", "ONE PER JUMP",
	          "PRECISION LANDING -40 ms", 0.6 s; UIController routes them).
	          Just below it, the context line: what the movement keys do right
	          now, from MovementController.contextHint() with the bound keys
	          ("Q SNAP CUT · F BURST", "Q SWING LEFT · SPACE HOP · E SWING
	          RIGHT"); everyday meanings (Space jump, C slide, E layout) are
	          left out so the line stays short.
	  Left    the combo chain, visible from the first technique (a lone jump
	          does not count): count, points and tier word with a pop and a
	          rising tick (AudioController.comboTick) per technique, over a bar
	          that drains through the 1.5 s chain window. A chain of two or more
	          becomes a 1.2 s card when it ends ("catch or block within 2 s for
	          x2"); a conversion the server confirms shows the x2 card. The
	          optional technique labels sit under it (setting, off by default;
	          at most 3, 1.2 s each).
	  Bottom  cooldown pips labelled with the bound key ("F BURST"); a press
	          refused for cooldown flashes its pip instead of printing text.
	          The exertion bar (pulses under 25, with "release SHIFT to
	          recover"), the mark chip while you mark (hand stance + the side
	          your team forces), the stall count, and one feedback line for
	          releases and drills.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local MovementConfig = require(Shared.Config.Movement)
local ModesConfig = require(Shared.Config.Modes)
local TeamsConfig = require(Shared.Config.Teams)
local MovementSim = require(Shared.Movement.MovementSim)
local ComboEvaluator = require(Shared.Rules.ComboEvaluator)
local Theme = require(script.Parent.Theme)

local make = Theme.make
local C = Theme.Colors

local Hud = {}

local controllers: any
local player = Players.LocalPlayer

local CHIP_TIME = 0.6
local CARD_TIME = 1.2
local CONVERT_CARD_TIME = 2.2
local CHAIN_ORPHAN = 0.25 -- a live chain whose window ran out without an end card fades after this
local FEED_MAX = 3
local FEED_LIFE = 1.2
local FEED_FADE = 0.3
local LOW_EXERTION = 25
local PIP_FLASH = 0.35
local CONTEXT_MAX = 3
local CONTEXT_EVERY = 0.06

-- Cooldown pips: sim readiness key, the action whose key is shown, label.
local PIPS = {
	{ key = "BurstStep", action = "Burst", label = "BURST" },
	{ key = "Dive", action = "Dive", label = "DIVE" },
	{ key = "MomentumCancel", action = "Cut", label = "PLANT" },
	{ key = "Slide", action = "Slide", label = "SLIDE" },
	{ key = "Air", action = "Cut", label = "AIR" },
}

-- Context line: actions in display order, and the labels that are just the
-- action's everyday meaning (left out).
local CONTEXT_ORDER = { "Cut", "Slide", "Burst", "Jump", "Dive" }
local PLAIN: { [string]: string } = { Jump = "JUMP", Slide = "SLIDE", Dive = "LAYOUT" }

type FeedEntry = { label: TextLabel, born: number }
type PipRef = { fill: Frame, label: TextLabel, stroke: UIStroke?, action: string, text: string }

local refs: { [string]: any } = {}
local pips: { [string]: PipRef } = {}
local pipFlashAt: { [string]: number } = {}
local feedEntries: { FeedEntry } = {}
local tweens: { [Instance]: Tween } = {}

local chainMode = "hidden" -- "hidden" | "live" | "card"
local cardUntil = 0
local chainZeroSince: number? = nil
local lastConverted: { startT: number, endT: number }? = nil
local contextText = ""
local lastContext = 0

local function now(): number
	return Net.now()
end

-- Plays a tween on `inst`, cancelling the one still running on it (so a fade
-- that started earlier can never hide a message shown after it).
local function tweenTo(inst: Instance, info: TweenInfo, goal: { [string]: any })
	local old = tweens[inst]
	if old then
		old:Cancel()
	end
	local tw = TweenService:Create(inst, info, goal)
	tweens[inst] = tw
	tw:Play()
end

local function stopTween(inst: Instance)
	local old = tweens[inst]
	if old then
		old:Cancel()
		tweens[inst] = nil
	end
end

local function pill(parent: Instance, name: string, pos: UDim2, size: UDim2, anchor: Vector2?): Frame
	local f = Theme.panel({
		Name = name,
		Position = pos,
		Size = size,
		AnchorPoint = anchor or Vector2.new(0.5, 0),
		Parent = parent,
	})
	return f
end

local function keyOf(action: string): string
	return controllers.InputController.keyLabel(action)
end

-- "Snap Cut" / "Sold Cut" / "Roll-out" ... for a technique event.
local function techName(tech: string, info: string?): string
	local name = (MovementConfig.TechNames :: any)[tech] or tech
	if tech == "PivotSwing" and info == "Sold" then
		return "Sold Swing"
	elseif info == "Restart" then
		return "Restart Cut"
	elseif info == "Sold" then
		return "Sold Cut"
	elseif info == "RollOut" then
		return "Roll-out"
	elseif info == "Explosive" then
		return "Explosive Burst"
	elseif info == "SlideHop" then
		return "Slide Hop"
	elseif info == "PlantJump" then
		return "Plant Jump"
	end
	return name
end

local function points(tech: string): number
	return (MovementConfig.ComboPoints :: any)[tech] or 0
end

function Hud.build(parent: ScreenGui, c: any)
	controllers = c

	-- scoreboard + mode chip ---------------------------------------------------
	local board = pill(parent, "Scoreboard", UDim2.new(0.5, 0, 0, 10), UDim2.fromOffset(420, 80))
	refs.teamA = Theme.label(TeamsConfig.A.Name, 18, {
		Parent = board,
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.fromOffset(110, 22),
		TextColor3 = C.TeamA,
		Font = Theme.Fonts.Heavy,
	})
	refs.scoreA = Theme.label("0", 34, {
		Parent = board,
		Position = UDim2.fromOffset(14, 26),
		Size = UDim2.fromOffset(110, 34),
		Font = Theme.Fonts.Heavy,
	})
	refs.teamB = Theme.label(TeamsConfig.B.Name, 18, {
		Parent = board,
		Position = UDim2.new(1, -124, 0, 8),
		Size = UDim2.fromOffset(110, 22),
		TextColor3 = C.TeamB,
		Font = Theme.Fonts.Heavy,
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	refs.scoreB = Theme.label("0", 34, {
		Parent = board,
		Position = UDim2.new(1, -124, 0, 26),
		Size = UDim2.fromOffset(110, 34),
		Font = Theme.Fonts.Heavy,
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	refs.clock = Theme.label("0:00", 26, {
		Parent = board,
		Position = UDim2.new(0.5, -70, 0, 4),
		Size = UDim2.fromOffset(140, 30),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Gold,
		Font = Theme.Fonts.Heavy,
	})
	refs.phase = Theme.label("WARMUP", 13, {
		Parent = board,
		Position = UDim2.new(0.5, -90, 0, 36),
		Size = UDim2.fromOffset(180, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Muted,
	})
	refs.modeChip = Theme.label("", 12, {
		Name = "ModeChip",
		Parent = board,
		Position = UDim2.new(0, 12, 0, 58),
		Size = UDim2.new(1, -24, 0, 16),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Accent,
	})

	-- attack direction arrow + bench line -----------------------------------------
	local arrowHolder = make("Frame", {
		Name = "Attack",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 96),
		Size = UDim2.fromOffset(260, 30),
		Parent = parent,
	})
	refs.attackArrow = Theme.label(">", 26, {
		Parent = arrowHolder,
		Size = UDim2.fromOffset(30, 30),
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	refs.attackText = Theme.label("", 14, {
		Parent = arrowHolder,
		Position = UDim2.fromOffset(34, 6),
		Size = UDim2.fromOffset(230, 18),
		TextColor3 = C.Text,
	})
	refs.bench = Theme.label("ON THE BENCH — you're in next point", 16, {
		Name = "Bench",
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 128),
		Size = UDim2.fromOffset(520, 22),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Gold,
		Font = Theme.Fonts.Heavy,
		TextStrokeTransparency = 0.6,
		Visible = false,
	})

	-- wind ----------------------------------------------------------------
	local wind = pill(parent, "Wind", UDim2.new(1, -16, 0, 10), UDim2.fromOffset(110, 44), Vector2.new(1, 0))
	refs.windArrow = Theme.label(">", 26, {
		Parent = wind,
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.fromOffset(28, 28),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Accent,
	})
	refs.windText = Theme.label("CALM", 14, {
		Parent = wind,
		Position = UDim2.fromOffset(40, 13),
		Size = UDim2.fromOffset(66, 18),
	})
	refs.wind = wind

	-- exertion + cooldown pips ---------------------------------------------
	local bottom = make("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(410, 46),
		Parent = parent,
	})
	local barBack = make("Frame", {
		Name = "ExertionBack",
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -8),
		Size = UDim2.new(1, 0, 0, 8),
		Parent = bottom,
		Theme.corner(4),
	})
	refs.exertion = make("Frame", {
		Name = "Exertion",
		BackgroundColor3 = C.Good,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = barBack,
		Theme.corner(4),
	})
	refs.exertionHint = Theme.label("", 13, {
		Name = "ExertionHint",
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -68),
		Size = UDim2.fromOffset(410, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Sloppy,
		TextStrokeTransparency = 0.6,
		Visible = false,
	})
	local pipRow = make("Frame", {
		Name = "Pips",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		Parent = bottom,
		Theme.list(8, true),
	});
	(pipRow:FindFirstChildOfClass("UIListLayout") :: UIListLayout).HorizontalAlignment = Enum.HorizontalAlignment.Center
	for i, def in PIPS do
		local p = Theme.panel({ Name = def.key, Size = UDim2.fromOffset(74, 26), LayoutOrder = i, Parent = pipRow })
		local fill = make("Frame", {
			Name = "Fill",
			BackgroundColor3 = (Theme.TechColors :: any)[def.key] or C.Accent,
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Parent = p,
			Theme.corner(10),
		}) :: Frame
		local label = Theme.label(def.label, 12, {
			Parent = p,
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			RichText = true,
		})
		pips[def.key] = {
			fill = fill,
			label = label,
			stroke = p:FindFirstChildOfClass("UIStroke"),
			action = def.action,
			text = def.label,
		}
	end

	-- combo chain widget + technique feed ---------------------------------------------
	local chain = make("CanvasGroup", {
		Name = "Chain",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 18, 0.5, 0),
		Size = UDim2.fromOffset(300, 92),
		Visible = false,
		Parent = parent,
	}) :: CanvasGroup
	refs.chain = chain
	local scale = Instance.new("UIScale")
	scale.Parent = chain
	refs.chainScale = scale
	refs.chainHead = Theme.label("", 26, {
		Name = "Head",
		Parent = chain,
		Size = UDim2.fromOffset(300, 38),
		Font = Theme.Fonts.Heavy,
		RichText = true,
		TextColor3 = C.Text,
		TextStrokeTransparency = 0.6,
	})
	refs.chainLast = Theme.label("", 13, {
		Name = "Last",
		Parent = chain,
		Position = UDim2.fromOffset(2, 40),
		Size = UDim2.fromOffset(298, 18),
		TextColor3 = C.Muted,
		TextStrokeTransparency = 0.7,
	})
	local barBg = make("Frame", {
		Name = "WindowBack",
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(2, 62),
		Size = UDim2.fromOffset(200, 5),
		Parent = chain,
		Theme.corner(3),
	})
	refs.chainBarBack = barBg
	refs.chainBar = make("Frame", {
		Name = "Window",
		BackgroundColor3 = C.Gold,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = barBg,
		Theme.corner(3),
	})
	refs.chainSub = Theme.label("", 13, {
		Name = "Sub",
		Parent = chain,
		Position = UDim2.fromOffset(2, 70),
		Size = UDim2.fromOffset(298, 18),
		TextColor3 = C.Muted,
		TextStrokeTransparency = 0.7,
	})
	refs.feedList = make("Frame", {
		Name = "TechFeed",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, 18, 0.5, 54),
		Size = UDim2.fromOffset(300, 80),
		Parent = parent,
		Theme.list(2),
	})

	-- feedback line (releases, drills) -----------------------------------------------
	refs.feedback = Theme.label("", 20, {
		Name = "Feedback",
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -90),
		Size = UDim2.fromOffset(700, 26),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.5,
		TextTransparency = 1,
		TextStrokeColor3 = Color3.new(0, 0, 0),
	})

	-- big banner + highlight -------------------------------------------------------
	refs.banner = Theme.label("", 56, {
		Name = "Banner",
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.32),
		Size = UDim2.fromOffset(900, 64),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.Fonts.Heavy,
		TextStrokeTransparency = 0.4,
		TextTransparency = 1,
	})
	refs.bannerSub = Theme.label("", 20, {
		Name = "BannerSub",
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.32, 44),
		Size = UDim2.fromOffset(900, 26),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Muted,
		TextTransparency = 1,
	})
	local hl = pill(parent, "Highlight", UDim2.new(0.5, 0, 0, 156), UDim2.fromOffset(560, 54))
	hl.Visible = false
	refs.hlName = Theme.label("", 14, {
		Parent = hl,
		Position = UDim2.fromOffset(14, 4),
		Size = UDim2.new(1, -28, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Muted,
	})
	refs.hlText = Theme.label("", 24, {
		Parent = hl,
		Position = UDim2.fromOffset(14, 20),
		Size = UDim2.new(1, -28, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.Fonts.Heavy,
		TextColor3 = C.Gold,
	})
	refs.highlight = hl

	-- toasts ---------------------------------------------------------------------
	refs.toasts = make("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 66),
		Size = UDim2.fromOffset(300, 300),
		Parent = parent,
		Theme.list(6),
	})

	-- stall + mark chip ------------------------------------------------------------
	local stall = pill(parent, "Stall", UDim2.new(0.5, 0, 1, -150), UDim2.fromOffset(180, 46), Vector2.new(0.5, 1))
	stall.Visible = false
	refs.stallText = Theme.label("STALL 0", 26, {
		Parent = stall,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.Fonts.Heavy,
	})
	refs.stall = stall
	local mark = pill(parent, "Mark", UDim2.new(0.5, 0, 1, -204), UDim2.fromOffset(360, 28), Vector2.new(0.5, 1))
	mark.Visible = false
	refs.markText = Theme.label("", 14, {
		Parent = mark,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		RichText = true,
	})
	refs.mark = mark

	-- crosshair, chips above it, context line below it ---------------------------------
	refs.crosshair = make("Frame", {
		Name = "Crosshair",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(6, 6),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Parent = parent,
		Theme.corner(3),
	})
	refs.chip = Theme.label("", 18, {
		Name = "Chip",
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0.5, -24),
		Size = UDim2.fromOffset(640, 26),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.Fonts.Heavy,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		TextStrokeColor3 = Color3.new(0, 0, 0),
	})
	refs.context = Theme.label("", 13, {
		Name = "Context",
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 22),
		Size = UDim2.fromOffset(640, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Text,
		TextTransparency = 0.2,
		TextStrokeTransparency = 0.7,
		RichText = true,
	})
	refs.hint = Theme.label("", 14, {
		Name = "Hint",
		Parent = parent,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.fromOffset(440, 18),
		TextColor3 = C.Muted,
		RichText = true,
	})

	-- pip and context labels follow rebinds and the input scheme
	local function refreshKeys()
		for _, pip in pips do
			pip.label.Text = Theme.keyText(keyOf(pip.action), pip.text)
		end
		contextText = "\0" -- forces the context line to rebuild
	end
	controllers.SettingsController.Changed:Connect(refreshKeys)
	controllers.InputController.SchemeChanged:Connect(refreshKeys)
	refreshKeys()
end

---------------------------------------------------------------------------
-- transient messages
---------------------------------------------------------------------------

local bannerToken = 0
function Hud.banner(text: string, sub: string?, color: Color3?, duration: number?)
	bannerToken += 1
	local token = bannerToken
	local b = refs.banner :: TextLabel
	local s = refs.bannerSub :: TextLabel
	stopTween(s)
	b.Text = text
	b.TextColor3 = color or C.Text
	s.Text = sub or ""
	b.TextTransparency = 0
	s.TextTransparency = if sub then 0 else 1
	b.TextSize = 70
	tweenTo(b, TweenInfo.new(0.25, Enum.EasingStyle.Back), { TextSize = 56 })
	task.delay(duration or 1.8, function()
		if token == bannerToken then
			tweenTo(b, TweenInfo.new(0.4), { TextTransparency = 1 })
			tweenTo(s, TweenInfo.new(0.4), { TextTransparency = 1 })
		end
	end)
end

local feedbackToken = 0
function Hud.feedback(text: string, color: Color3?, duration: number?)
	feedbackToken += 1
	local token = feedbackToken
	local f = refs.feedback :: TextLabel
	stopTween(f)
	f.Text = text
	f.TextColor3 = color or C.Text
	f.TextTransparency = 0
	task.delay(duration or 1.6, function()
		if token == feedbackToken then
			tweenTo(f, TweenInfo.new(0.35), { TextTransparency = 1 })
		end
	end)
end

-- A short chip just above the crosshair (0.6 s by default); the newest
-- replaces the previous one.
local chipToken = 0
function Hud.chip(text: string, color: Color3?, duration: number?)
	chipToken += 1
	local token = chipToken
	local l = refs.chip :: TextLabel
	stopTween(l)
	l.Text = text
	l.TextColor3 = color or C.Text
	l.TextTransparency = 0
	l.TextStrokeTransparency = 0.5
	l.TextSize = 22
	tweenTo(l, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { TextSize = 18 })
	task.delay(duration or CHIP_TIME, function()
		if token == chipToken then
			tweenTo(l, TweenInfo.new(0.2), { TextTransparency = 1, TextStrokeTransparency = 1 })
		end
	end)
end

-- Flashes a cooldown pip ("BurstStep", "Dive", "MomentumCancel", "Slide"):
-- the press was refused because that technique is still recharging.
function Hud.flashPip(key: string)
	if pips[key] then
		pipFlashAt[key] = os.clock()
	end
end

function Hud.toast(text: string, color: Color3?, duration: number?)
	local t = Theme.panel({ Size = UDim2.fromOffset(300, 40), Parent = refs.toasts })
	Theme.label(text, 15, {
		Parent = t,
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -20, 1, 0),
		TextColor3 = color or C.Text,
		TextWrapped = true,
	})
	task.delay(duration or 4, function()
		t:Destroy()
	end)
end

local hlToken = 0
function Hud.highlight(name: string, text: string, team: string?)
	hlToken += 1
	local token = hlToken
	local hl = refs.highlight :: Frame
	refs.hlName.Text = string.upper(name)
	refs.hlText.Text = text
	local stroke = hl:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = Theme.teamColor(team)
		stroke.Transparency = 0
	end
	hl.Visible = true
	hl.Size = UDim2.fromOffset(600, 60)
	tweenTo(hl, TweenInfo.new(0.2, Enum.EasingStyle.Back), { Size = UDim2.fromOffset(560, 54) })
	task.delay(2.6, function()
		if token == hlToken then
			hl.Visible = false
		end
	end)
end

-- Optional technique label (Settings > Technique labels; off by default).
function Hud.techLabel(tech: string, quality: string, info: string?)
	if not controllers.SettingsController.get("ShowTechLabels") then
		return
	end
	if tech == "Jump" then
		return
	end
	local name = techName(tech, info)
	local label =
		Theme.label(string.upper(name) .. (if quality ~= "Clean" then "  " .. string.upper(quality) else ""), 16, {
			Parent = refs.feedList,
			Size = UDim2.new(1, 0, 0, 22),
			TextColor3 = if quality == "Clean"
				then ((Theme.TechColors :: any)[tech] or C.Text)
				else Theme.qualityColor(quality),
			Font = Theme.Fonts.Heavy,
			TextStrokeTransparency = 0.6,
		})
	table.insert(feedEntries, { label = label, born = os.clock() })
	while #feedEntries > FEED_MAX do
		local e = table.remove(feedEntries, 1)
		if e then
			e.label:Destroy()
		end
	end
end

function Hud.setHint(text: string)
	refs.hint.Text = text
end

---------------------------------------------------------------------------
-- combo chain
---------------------------------------------------------------------------

local function headText(count: number, score: number, tier: string?): string
	local tierText = ""
	if tier then
		tierText = string.format('  <font color="#%s">%s</font>', Theme.tierColor(tier):ToHex(), tier)
	end
	return string.format('<font size="34" color="#%s">x%d</font>  %d%s', C.Gold:ToHex(), count, score, tierText)
end

local function pop(strength: number)
	local sc = refs.chainScale :: UIScale
	sc.Scale = strength
	tweenTo(sc, TweenInfo.new(0.14, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
end

local function showChain()
	local g = refs.chain :: CanvasGroup
	stopTween(g)
	g.GroupTransparency = 0
	g.Visible = controllers.SettingsController.get("ShowComboFeed") ~= false
end

local function hideChain()
	if chainMode == "hidden" then
		return
	end
	chainMode = "hidden"
	chainZeroSince = nil
	tweenTo(refs.chain, TweenInfo.new(0.25), { GroupTransparency = 1 })
end

-- Does a chain hold anything but jumps? (A lone jump is not worth a widget.)
local function hasKeyTech(techs: { string }): boolean
	for _, tech in techs do
		if tech ~= "Jump" and points(tech) > 0 then
			return true
		end
	end
	return false
end

-- MovementController.ComboChanged: a technique joined the local chain.
function Hud.comboChanged(total: number, gained: number, e: any)
	if gained <= 0 or type(e) ~= "table" then
		return
	end
	local c = ComboEvaluator.active(controllers.MovementController.combo(), now())
	if not c then
		return
	end
	local techs: { string } = {}
	for _, entry in c.entries do
		table.insert(techs, entry.tech)
	end
	if not hasKeyTech(techs) then
		return
	end
	chainMode = "live"
	chainZeroSince = nil
	refs.chainHead.Text = headText(c.scoring, total, ComboEvaluator.tier(total))
	refs.chainLast.Text = string.upper(techName(e.tech, e.info))
		.. (if e.quality ~= "Clean" then "  ·  " .. string.upper(e.quality) else "")
	refs.chainLast.TextColor3 = if e.quality == "Clean"
		then ((Theme.TechColors :: any)[e.tech] or C.Muted)
		else Theme.qualityColor(e.quality)
	refs.chainSub.Text = ""
	refs.chainBarBack.Visible = true
	showChain()
	pop(if e.quality == "Perfect" then 1.3 else 1.16)
	if e.tech ~= "Jump" then
		controllers.AudioController.comboTick(c.scoring, e.quality == "Perfect")
	end
end

-- MovementController.ChainEnded: the local chain timed out (unconverted).
function Hud.chainEnded(summary: any)
	if type(summary) ~= "table" then
		return
	end
	local conv = lastConverted
	if conv and summary.startT <= conv.endT + 0.05 and summary.endT >= conv.startT - 0.05 then
		return -- the server already converted this chain; its card is showing
	end
	if (summary.count or 0) < 2 or not hasKeyTech(summary.techs or {}) then
		if chainMode == "live" then
			hideChain()
		end
		return
	end
	chainMode = "card"
	cardUntil = os.clock() + CARD_TIME
	refs.chainHead.Text = headText(summary.count, summary.total, summary.tier)
	refs.chainLast.Text = "CHAIN COMPLETE"
	refs.chainLast.TextColor3 = C.Text
	refs.chainSub.Text = "catch or block within 2 s for x2"
	refs.chainBarBack.Visible = false
	showChain()
	pop(1.08)
	if summary.tier then
		controllers.AudioController.play("ComboEnd")
	end
end

-- The server's Combo event: a chain was converted by a catch / block / D.
function Hud.comboConverted(summary: any)
	if type(summary) ~= "table" or not summary.converted then
		return
	end
	lastConverted = {
		startT = if type(summary.startT) == "number" then summary.startT else now(),
		endT = if type(summary.endT) == "number" then summary.endT else now(),
	}
	chainMode = "card"
	cardUntil = os.clock() + CONVERT_CARD_TIME
	refs.chainHead.Text = headText(summary.count or 0, summary.score or 0, summary.tier)
	refs.chainLast.Text = string.upper(tostring(summary.payoff or "PLAY")) .. "  ·  CHAIN CONVERTED  x2"
	refs.chainLast.TextColor3 = C.Gold
	refs.chainSub.Text = ""
	refs.chainBarBack.Visible = false
	showChain()
	pop(1.35)
	controllers.AudioController.play("ComboConvert")
end

local function updateChain(t: number, clock: number)
	if chainMode == "live" then
		local left = ComboEvaluator.windowLeft(controllers.MovementController.combo(), t)
		refs.chainBar.Size = UDim2.fromScale(left, 1)
		refs.chainBar.BackgroundColor3 = if left > 0.35 then C.Gold else C.Sloppy
		if left <= 0 then
			-- the end card normally follows at once; fade if it never comes
			local since = chainZeroSince or clock
			chainZeroSince = since
			if clock - since > CHAIN_ORPHAN then
				hideChain()
			end
		end
	elseif chainMode == "card" and clock > cardUntil then
		hideChain()
	end
	if chainMode ~= "hidden" then
		refs.chain.Visible = controllers.SettingsController.get("ShowComboFeed") ~= false
	end
end

---------------------------------------------------------------------------
-- per-frame
---------------------------------------------------------------------------

local function screenArrowRotation(worldDir: Vector3): number
	local yaw = controllers.CameraController.getYaw()
	local camForward = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	local camRight = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
	local x = worldDir:Dot(camRight)
	local y = worldDir:Dot(camForward)
	-- the glyph points right (+x screen) at 0 degrees; up the screen = -90
	return math.deg(math.atan2(-y, x))
end

local function attrNumber(inst: Instance, name: string): number
	local v = inst:GetAttribute(name)
	return if type(v) == "number" then v else 0
end

-- "MINI 3v3 · 2 PLAYERS + 4 BOTS" / "RANKED · NORMAL 7v7 · 14 PLAYERS" /
-- the lobby line during warm-up.
local function modeChipText(state: Instance, phase: string): string
	if phase == "Intermission" or phase == "Boot" then
		local lobby = state:GetAttribute("Lobby")
		if type(lobby) == "string" and lobby ~= "" then
			return string.upper(lobby)
		end
		return if state:GetAttribute("RankedNext") == true then "NEXT MATCH IS RANKED" else ""
	end
	local modeId = state:GetAttribute("Mode")
	local rules = if type(modeId) == "string" then ModesConfig.List[modeId] else nil
	local name = if rules then string.upper(rules.id) .. " " .. rules.Short else string.upper(tostring(modeId or ""))
	local humans = attrNumber(state, "HumansA") + attrNumber(state, "HumansB")
	local bots = attrNumber(state, "BotsA") + attrNumber(state, "BotsB")
	local count = string.format("%d PLAYER%s", humans, if humans == 1 then "" else "S")
	if bots > 0 then
		count ..= string.format(" + %d BOT%s", bots, if bots == 1 then "" else "S")
	end
	local text = name .. "  ·  " .. count
	if state:GetAttribute("Ranked") == true then
		text = "RANKED  ·  " .. text
	end
	return text
end

-- The context line: the non-obvious things the movement keys do right now.
local function buildContext(): string
	local hint = controllers.MovementController.contextHint()
	local entries: { { label: string, keys: { string } } } = {}
	for _, action in CONTEXT_ORDER do
		local label = hint[action]
		if label and label ~= PLAIN[action] then
			local key = keyOf(action)
			local merged = false
			for _, entry in entries do
				if entry.label == label then
					if key ~= "" then
						table.insert(entry.keys, key)
					end
					merged = true
					break
				end
			end
			if not merged and #entries < CONTEXT_MAX then
				table.insert(entries, { label = label, keys = if key ~= "" then { key } else {} })
			end
		end
	end
	local parts: { string } = {}
	for _, entry in entries do
		table.insert(parts, Theme.keyText(table.concat(entry.keys, "/"), entry.label))
	end
	return table.concat(parts, "  ·  ")
end

local function exertionHint(): string
	local key = keyOf("Sprint")
	if key ~= "" and not controllers.SettingsController.get("AutoSprint") then
		return string.format("LOW ENERGY — release %s to recover", key)
	end
	return "LOW ENERGY — ease off to a jog to recover"
end

function Hud.update(_dt: number)
	local state = Net.state()
	local t = now()
	local clock = os.clock()
	local phase: string = (state:GetAttribute("Phase") or "Boot") :: string
	refs.scoreA.Text = tostring(state:GetAttribute("ScoreA") or 0)
	refs.scoreB.Text = tostring(state:GetAttribute("ScoreB") or 0)
	local matchEnd = state:GetAttribute("MatchEnd")
	local phaseEnd = state:GetAttribute("PhaseEnd")
	if phase == "Intermission" then
		refs.clock.Text = if type(phaseEnd) == "number" and phaseEnd > 0
			then Theme.formatTime(phaseEnd - t)
			else "--:--"
		refs.phase.Text = "WARMUP · press M to vote"
	else
		refs.clock.Text = if type(matchEnd) == "number" then Theme.formatTime(matchEnd - t) else "0:00"
		local label = string.upper(phase)
		if phase == "PointSetup" and type(phaseEnd) == "number" then
			label = "LINE UP  " .. math.max(0, math.ceil(phaseEnd - t))
		elseif phase == "PointOver" then
			label = "GOAL"
		elseif state:GetAttribute("Universe") then
			label = "UNIVERSE POINT"
		elseif state:GetAttribute("CapReached") then
			label = "CAP · FINISH THE POINT"
		end
		refs.phase.Text = label
	end
	local chipText = modeChipText(state, phase)
	refs.modeChip.Text = chipText
	refs.modeChip.TextColor3 = if state:GetAttribute("Ranked") == true then C.Gold else C.Accent

	-- attack direction + bench
	local character = player.Character
	local myTeam = if character then character:GetAttribute("UBTeam") else nil
	local role = if character then character:GetAttribute("UBRole") else nil
	if (myTeam == "A" or myTeam == "B") and phase ~= "Intermission" then
		local side = state:GetAttribute(if myTeam == "A" then "AttackA" else "AttackB")
		local dir = if side == "East" then Vector3.new(1, 0, 0) else Vector3.new(-1, 0, 0)
		refs.attackArrow.Rotation = screenArrowRotation(dir)
		refs.attackArrow.TextColor3 = Theme.teamColor(myTeam)
		local offense = state:GetAttribute("Offense")
		refs.attackText.Text = if offense == myTeam
			then "YOUR DISC · ATTACK THIS WAY"
			else "DEFENSE · STOP THEM SCORING"
		refs.attackArrow.Visible = true
	else
		refs.attackArrow.Visible = false
		refs.attackText.Text = ""
	end
	refs.bench.Visible = role == "Bench" and phase ~= "Intermission"

	-- wind
	local w = state:GetAttribute("Wind")
	if typeof(w) == "Vector3" and w.Magnitude > 0.1 then
		refs.wind.Visible = true
		refs.windArrow.Rotation = screenArrowRotation(Vector3.new(w.X, 0, w.Z).Unit)
		refs.windText.Text = string.format("WIND %.0f", w.Magnitude)
	else
		refs.wind.Visible = false
	end

	-- exertion and cooldown pips
	local sim = controllers.MovementController.sim()
	local ex = sim.exertion / MovementConfig.ExertionMax
	local bar = refs.exertion :: Frame
	bar.Size = UDim2.fromScale(math.clamp(ex, 0, 1), 1)
	bar.BackgroundColor3 = if ex > 0.5 then C.Good elseif ex > 0.2 then C.Gold else C.Bad
	local low = sim.exertion < LOW_EXERTION
	bar.BackgroundTransparency = if low then 0.3 + 0.3 * math.sin(clock * 9) else 0
	refs.exertionHint.Visible = low
	if low then
		refs.exertionHint.Text = exertionHint()
	end
	for key, pip in pips do
		local ready: number
		if key == "Air" then
			ready = if sim.airRedirectUsed then 0 else 1
		else
			ready = MovementSim.readiness(sim, key)
		end
		pip.fill.Size = UDim2.fromScale(ready, 1)
		pip.fill.BackgroundTransparency = if ready >= 1 then 0.45 else 0.75
		local stroke = pip.stroke
		if stroke then
			local flashing = clock - (pipFlashAt[key] or -math.huge) < PIP_FLASH
			stroke.Color = if flashing then C.Bad else C.Stroke
			stroke.Thickness = if flashing then 2 else 1
			stroke.Transparency = if flashing then 0 else 0.3
		end
	end

	-- combo chain + technique feed
	updateChain(t, clock)
	for i = #feedEntries, 1, -1 do
		local e = feedEntries[i]
		local age = clock - e.born
		if age > FEED_LIFE then
			e.label:Destroy()
			table.remove(feedEntries, i)
		elseif age > FEED_LIFE - FEED_FADE then
			e.label.TextTransparency = (age - (FEED_LIFE - FEED_FADE)) / FEED_FADE
		end
	end

	-- stall
	local holderId = state:GetAttribute("HolderId")
	local stall: number = (state:GetAttribute("Stall") or 0) :: number
	local stallMax: number = (state:GetAttribute("StallMax") or 10) :: number
	local stallState = state:GetAttribute("StallState") or "None"
	local inPlay = phase == "Live" and type(holderId) == "number" and holderId ~= 0
	local involved = holderId == player.UserId or state:GetAttribute("MarkerId") == player.UserId
	refs.stall.Visible = inPlay and involved
	if inPlay then
		local text = "STALL " .. tostring(stall)
		if stallState == "DoubleTeam" then
			text = "DOUBLE TEAM"
		elseif stallState == "DiscSpace" then
			text = "DISC SPACE"
		elseif stallState == "Unmarked" then
			text = "NO MARK"
		end
		refs.stallText.Text = text
		refs.stallText.TextColor3 = if stall >= stallMax - 3
			then C.Bad
			elseif stall >= stallMax - 5 then C.Gold
			else C.Text
	end

	-- mark chip: your hands and the side your team forces
	local marking = controllers.CatchController.isMarking()
	refs.mark.Visible = marking
	if marking then
		local stance = string.upper(controllers.CatchController.markStance())
		local force = state:GetAttribute(if myTeam == "B" then "ForceB" else "ForceA")
		local parts = { stance .. " HANDS" }
		if (myTeam == "A" or myTeam == "B") and (force == "FH" or force == "BH") then
			table.insert(parts, "FORCE " .. force)
		end
		table.insert(parts, Theme.keyText(keyOf("Slide"), "SWITCH"))
		refs.markText.Text = table.concat(parts, "  ·  ")
	end

	-- crosshair + context line
	local locked = controllers.CameraController.isLocked()
	refs.crosshair.Visible = locked
	refs.context.Visible = locked
	if locked and clock - lastContext >= CONTEXT_EVERY then
		lastContext = clock
		local text = buildContext()
		if text ~= contextText then
			contextText = text
			refs.context.Text = text
		end
	end
end

return Hud
