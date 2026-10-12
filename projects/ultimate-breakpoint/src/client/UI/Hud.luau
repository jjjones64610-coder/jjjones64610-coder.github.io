--!strict
--[[
	Hud — only what helps a decision: score, clock, which way you attack,
	possession, stall count, wind, exertion and cooldowns, plus short-lived
	feedback (technique labels, timing, highlights, banners).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local MovementConfig = require(Shared.Config.Movement)
local TeamsConfig = require(Shared.Config.Teams)
local MovementSim = require(Shared.Movement.MovementSim)
local ComboEvaluator = require(Shared.Rules.ComboEvaluator)
local Theme = require(script.Parent.Theme)

local make = Theme.make
local C = Theme.Colors

local Hud = {}

local controllers: any
local player = Players.LocalPlayer

local refs: { [string]: any } = {}
local feedEntries: { { label: TextLabel, born: number } } = {}

local function now(): number
	return Net.now()
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

function Hud.build(parent: ScreenGui, c: any)
	controllers = c

	-- scoreboard ---------------------------------------------------------
	local board = pill(parent, "Scoreboard", UDim2.new(0.5, 0, 0, 10), UDim2.fromOffset(420, 64))
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

	-- attack direction arrow ---------------------------------------------
	local arrowHolder = make("Frame", {
		Name = "Attack",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 80),
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

	-- exertion + cooldowns -------------------------------------------------
	local bottom = make("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(340, 46),
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
	local pips = make("Frame", {
		Name = "Pips",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		Parent = bottom,
		Theme.list(8, true),
	});
	(pips:FindFirstChildOfClass("UIListLayout") :: UIListLayout).HorizontalAlignment = Enum.HorizontalAlignment.Center
	refs.pips = {}
	for i, def in
		{
			{ key = "BurstStep", label = "BURST" },
			{ key = "Dive", label = "DIVE" },
			{ key = "MomentumCancel", label = "PLANT" },
			{ key = "Slide", label = "SLIDE" },
			{ key = "Air", label = "AIR" },
		}
	do
		local p = Theme.panel({ Name = def.key, Size = UDim2.fromOffset(60, 26), LayoutOrder = i, Parent = pips })
		local fill = make("Frame", {
			Name = "Fill",
			BackgroundColor3 = (Theme.TechColors :: any)[def.key] or C.Accent,
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Parent = p,
			Theme.corner(10),
		})
		Theme.label(def.label, 12, {
			Parent = p,
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		refs.pips[def.key] = fill
	end

	-- combo feed -------------------------------------------------------------
	local feed = make("Frame", {
		Name = "ComboFeed",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 18, 0.55, 0),
		Size = UDim2.fromOffset(260, 260),
		Parent = parent,
	})
	refs.comboTotal = Theme.label("", 22, {
		Parent = feed,
		Size = UDim2.fromOffset(260, 28),
		Font = Theme.Fonts.Heavy,
		TextColor3 = C.Gold,
	})
	refs.feedList = make("Frame", {
		Name = "List",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 32),
		Size = UDim2.fromOffset(260, 220),
		Parent = feed,
		Theme.list(2),
	})
	refs.feed = feed

	-- timing feedback line ------------------------------------------------------
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
	local hl = pill(parent, "Highlight", UDim2.new(0.5, 0, 0, 118), UDim2.fromOffset(560, 54))
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

	-- stall + crosshair ------------------------------------------------------------
	local stall = pill(parent, "Stall", UDim2.new(0.5, 0, 1, -150), UDim2.fromOffset(180, 46), Vector2.new(0.5, 1))
	stall.Visible = false
	refs.stallText = Theme.label("STALL 0", 26, {
		Parent = stall,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.Fonts.Heavy,
	})
	refs.stall = stall
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
	refs.hint = Theme.label("", 14, {
		Name = "Hint",
		Parent = parent,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.fromOffset(520, 18),
		TextColor3 = C.Muted,
	})
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
	b.Text = text
	b.TextColor3 = color or C.Text
	s.Text = sub or ""
	b.TextTransparency = 0
	s.TextTransparency = if sub then 0 else 1
	b.TextSize = 70
	TweenService:Create(b, TweenInfo.new(0.25, Enum.EasingStyle.Back), { TextSize = 56 }):Play()
	task.delay(duration or 1.8, function()
		if token == bannerToken then
			TweenService:Create(b, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
			TweenService:Create(s, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
		end
	end)
end

local feedbackToken = 0
function Hud.feedback(text: string, color: Color3?, duration: number?)
	feedbackToken += 1
	local token = feedbackToken
	local f = refs.feedback :: TextLabel
	f.Text = text
	f.TextColor3 = color or C.Text
	f.TextTransparency = 0
	task.delay(duration or 1.6, function()
		if token == feedbackToken then
			TweenService:Create(f, TweenInfo.new(0.35), { TextTransparency = 1 }):Play()
		end
	end)
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
	TweenService:Create(hl, TweenInfo.new(0.2, Enum.EasingStyle.Back), { Size = UDim2.fromOffset(560, 54) }):Play()
	task.delay(2.6, function()
		if token == hlToken then
			hl.Visible = false
		end
	end)
end

function Hud.techLabel(tech: string, quality: string, info: string?)
	if not controllers.SettingsController.get("ShowTechLabels") then
		return
	end
	if tech == "Jump" then
		return
	end
	local name = (MovementConfig.TechNames :: any)[tech] or tech
	if info == "Restart" then
		name = "Restart Cut"
	elseif info == "Sold" then
		name = "Sold Cut"
	elseif info == "RollOut" then
		name = "Roll-out"
	elseif info == "Explosive" then
		name = "Explosive Burst"
	end
	local label =
		Theme.label(string.upper(name) .. (if quality ~= "Clean" then "  " .. string.upper(quality) else ""), 18, {
			Parent = refs.feedList,
			TextColor3 = if quality == "Clean"
				then ((Theme.TechColors :: any)[tech] or C.Text)
				else Theme.qualityColor(quality),
			Font = Theme.Fonts.Heavy,
			TextStrokeTransparency = 0.6,
		})
	table.insert(feedEntries, { label = label, born = os.clock() })
	while #feedEntries > 7 do
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

function Hud.update(_dt: number)
	local state = Net.state()
	local t = now()
	local phase = state:GetAttribute("Phase") or "Boot"
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
		local label = string.upper(tostring(phase))
		if phase == "PointSetup" and type(phaseEnd) == "number" then
			label = "LINE UP  " .. math.max(0, math.ceil(phaseEnd - t))
		elseif phase == "PointOver" then
			label = "GOAL"
		elseif state:GetAttribute("Universe") then
			label = "UNIVERSE POINT"
		elseif state:GetAttribute("CapReached") then
			label = "CAP · FINISH THE POINT"
		end
		refs.phase.Text = label .. "  ·  " .. tostring(state:GetAttribute("ModeName") or "")
	end

	-- attack direction for my team
	local myTeam = if player.Character then player.Character:GetAttribute("UBTeam") else nil
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

	-- wind
	local w = state:GetAttribute("Wind")
	if typeof(w) == "Vector3" and w.Magnitude > 0.1 then
		refs.wind.Visible = true
		refs.windArrow.Rotation = screenArrowRotation(Vector3.new(w.X, 0, w.Z).Unit)
		refs.windText.Text = string.format("WIND %.0f", w.Magnitude)
	else
		refs.wind.Visible = false
	end

	-- exertion and cooldowns
	local sim = controllers.MovementController.sim()
	local ex = sim.exertion / MovementConfig.ExertionMax
	refs.exertion.Size = UDim2.fromScale(math.clamp(ex, 0, 1), 1)
	refs.exertion.BackgroundColor3 = if ex > 0.5 then C.Good elseif ex > 0.2 then C.Gold else C.Bad
	for key, fill in refs.pips do
		local ready: number
		if key == "Air" then
			ready = if sim.airRedirectUsed then 0 else 1
		else
			ready = MovementSim.readiness(sim, key)
		end
		fill.Size = UDim2.fromScale(ready, 1)
		fill.BackgroundTransparency = if ready >= 1 then 0.45 else 0.75
	end

	-- combo feed fade + total
	local clock = os.clock()
	for i = #feedEntries, 1, -1 do
		local e = feedEntries[i]
		local age = clock - e.born
		if age > 2.4 then
			e.label:Destroy()
			table.remove(feedEntries, i)
		elseif age > 1.6 then
			e.label.TextTransparency = (age - 1.6) / 0.8
		end
	end
	local chain = ComboEvaluator.active(controllers.MovementController.combo(), t)
	if chain and chain.scoring >= 2 and controllers.SettingsController.get("ShowComboFeed") then
		local total = ComboEvaluator.total(chain)
		local tier = ComboEvaluator.tier(total)
		refs.comboTotal.Text = string.format("COMBO %d%s", total, if tier then "  · " .. tier else "")
	else
		refs.comboTotal.Text = ""
	end
	refs.feed.Visible = controllers.SettingsController.get("ShowComboFeed") ~= false

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

	refs.crosshair.Visible = controllers.CameraController.isLocked()
end

return Hud
