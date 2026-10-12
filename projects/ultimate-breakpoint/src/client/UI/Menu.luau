--!strict
-- Menu — Play (votes, join, private rules), Training, Profile, Locker,
-- Leaderboard, Settings and Controls (rebinding + technique reference).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local ModesConfig = require(Shared.Config.Modes)
local ArenasConfig = require(Shared.Config.Arenas)
local InputConfig = require(Shared.Config.Input)
local MovementConfig = require(Shared.Config.Movement)
local DiscConfig = require(Shared.Config.Disc)
local ProgressionConfig = require(Shared.Config.Progression)
local Theme = require(script.Parent.Theme)

local make = Theme.make
local C = Theme.Colors

local Menu = {}

local controllers: any
local player = Players.LocalPlayer
local refs: { [string]: any } = {}
local isOpen = false
local currentTab = "Play"
local profile: any = nil
local rebinding: { action: string, button: TextButton }? = nil
local launcher = { throwType = "Backhand", power = 0.5, pitch = 10, bank = 0, offset = 0 }

local TABS = { "Play", "Training", "Profile", "Locker", "Leaderboard", "Settings", "Controls" }

local DRILLS: { any } = {
	{ id = "Tutorial", name = "Movement School", desc = "Every technique, step by step.", pb = nil },
	{
		id = "Cutting",
		name = "Cutting Course",
		desc = "Slalom time trial. Keep your speed through the gates.",
		pb = "time",
	},
	{
		id = "Shuttle",
		name = "Momentum Shuttle",
		desc = "A-B-A-B-A. Reverse direction without losing it.",
		pb = "time",
	},
	{ id = "Aerial", name = "Aerial Catch", desc = "10 launches: floaters, skimmers, layouts.", pb = "score" },
	{ id = "Range", name = "Throwing Range", desc = "10 throws at static and moving rings.", pb = "score" },
	{ id = "Interception", name = "Interception Drill", desc = "Read the thrower. Get the D.", pb = "score" },
	{ id = "Combo", name = "Combo Lab", desc = "Land eight technique chains. Rebound walls inside.", pb = nil },
}

local TECH_GUIDE = {
	"SNAP CUT — sprint, then Cut while steering 25-115 deg away. Hold a line first: committed full-speed cuts are Perfect.",
	"MOMENTUM CANCEL — Cut while steering backward (or with no direction). Then Cut/Burst 0.10-0.32 s later to restart; 0.10-0.21 s is Perfect.",
	"FAKE COMMIT — Cut while running straight (or standing): a jab step. Cut away within 0.45 s for a Sold cut (always Perfect).",
	"BURST STEP — Burst. Short, explosive, 1.6 s cooldown. Free and Perfect out of a plant; Perfect within 0.15 s of a Snap Cut.",
	"SLIDE / SLIDE CUT — Slide while fast. Cut mid-slide to leave at a new angle (0.3-0.6 s into the slide is Perfect).",
	"AIR REDIRECT — Cut in the air: bend your path up to 80 deg once per jump. Near the apex = Perfect.",
	"PRECISION LANDING — Slide within 0.15 s before touching down (or 0.06 s after): no landing penalty. After a dive it is a Roll-out.",
	"LAYOUT — Dive. Huge reach forward. Recovery Chain: Cut/Burst/Jump as your slide stops (first 0.09 s = Perfect). Too early locks you out.",
	"WALL REBOUND — Jump beside a glowing Rebound wall while airborne (special arenas and the Combo Lab).",
	"REACH — Primary without the disc: extend toward your aim for a moment. Airborne reaches are Aerial Catch Adjustments.",
	"MARK — hold Secondary near the thrower: hands up. Aim low for wide hands, high to cover hammers. Jump to lift them.",
}

local function clear(frame: Instance)
	for _, ch in frame:GetChildren() do
		if not ch:IsA("UIListLayout") and not ch:IsA("UIPadding") then
			ch:Destroy()
		end
	end
end

local function section(parent: Instance, title: string, order: number)
	Theme.label(title, 20, {
		Parent = parent,
		LayoutOrder = order,
		Font = Theme.Fonts.Heavy,
		TextColor3 = C.Accent,
	})
end

local function row(parent: Instance, order: number, height: number?): Frame
	local f = make("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -10, 0, height or 40),
		LayoutOrder = order,
		Parent = parent,
		Theme.list(8, true),
	}) :: Frame;
	(f:FindFirstChildOfClass("UIListLayout") :: UIListLayout).VerticalAlignment = Enum.VerticalAlignment.Center
	return f
end

local function action(kind: string, payload: any)
	Net.event("Action"):FireServer(kind, payload)
	controllers.AudioController.play("UiClick")
end

local function stepper(
	parent: Instance,
	order: number,
	label: string,
	value: string,
	onMinus: () -> (),
	onPlus: () -> ()
)
	local r = row(parent, order, 36)
	Theme.label(label, 15, { Parent = r, Size = UDim2.fromOffset(250, 30), LayoutOrder = 1 })
	local minus = Theme.button("-", { Parent = r, Size = UDim2.fromOffset(36, 30), LayoutOrder = 2 })
	Theme.label(
		value,
		15,
		{ Parent = r, Size = UDim2.fromOffset(90, 30), LayoutOrder = 3, TextXAlignment = Enum.TextXAlignment.Center }
	)
	local plus = Theme.button("+", { Parent = r, Size = UDim2.fromOffset(36, 30), LayoutOrder = 4 })
	minus.Activated:Connect(onMinus)
	plus.Activated:Connect(onPlus)
end

local function toggleRow(parent: Instance, order: number, label: string, value: boolean, onToggle: () -> ())
	local r = row(parent, order, 36)
	Theme.label(label, 15, { Parent = r, Size = UDim2.fromOffset(250, 30), LayoutOrder = 1 })
	local b = Theme.button(if value then "ON" else "OFF", {
		Parent = r,
		Size = UDim2.fromOffset(80, 30),
		LayoutOrder = 2,
		BackgroundColor3 = if value then C.Good else C.PanelLight,
		TextColor3 = if value then Color3.new(0, 0, 0) else C.Text,
	})
	b.Activated:Connect(onToggle)
end

---------------------------------------------------------------------------
-- tabs
---------------------------------------------------------------------------

local render: { [string]: (Instance) -> () } = {}

function render.Play(content: Instance)
	local state = Net.state()
	local phase = state:GetAttribute("Phase") or ""
	local o = 0
	local function nextOrder(): number
		o += 1
		return o
	end
	section(content, "PLAY", nextOrder())
	Theme.label(
		string.format(
			"%s  ·  %s  ·  %s",
			tostring(phase),
			tostring(state:GetAttribute("ModeName") or "Warmup"),
			tostring(state:GetAttribute("ArenaName") or "")
		),
		15,
		{
			Parent = content,
			LayoutOrder = nextOrder(),
			TextColor3 = C.Muted,
		}
	)
	local role = if player.Character then player.Character:GetAttribute("UBRole") else nil
	local r = row(content, nextOrder(), 44)
	if role ~= "Match" then
		local join = Theme.button(
			"JOIN MATCH",
			{ Parent = r, LayoutOrder = 1, BackgroundColor3 = C.Accent, TextColor3 = Color3.new(0, 0, 0) }
		)
		join.Activated:Connect(function()
			action("JoinMatch", nil)
			Menu.toggle(false)
		end)
	end
	local train = Theme.button("TRAINING GROUNDS", { Parent = r, LayoutOrder = 2, Size = UDim2.fromOffset(200, 38) })
	train.Activated:Connect(function()
		action("EnterTraining", nil)
		Menu.toggle(false)
	end)

	if phase == "Intermission" then
		local counts: any = {}
		local okJson, decoded = pcall(function()
			return HttpService:JSONDecode(state:GetAttribute("VoteCounts") or "{}")
		end)
		if okJson and type(decoded) == "table" then
			counts = decoded
		end
		section(content, "VOTE: MODE", nextOrder())
		local mr = row(content, nextOrder(), 44)
		for i, id in string.split((state:GetAttribute("VoteModes") or "") :: string, ",") do
			local m = (ModesConfig.List :: any)[id]
			if m then
				local n = if counts.mode then counts.mode[id] or 0 else 0
				local b = Theme.button(
					string.format("%s (%d)", m.Display, n),
					{ Parent = mr, LayoutOrder = i, Size = UDim2.fromOffset(150, 38) }
				)
				b.Activated:Connect(function()
					action("Vote", { mode = id })
				end)
			end
		end
		section(content, "VOTE: ARENA", nextOrder())
		local ar = row(content, nextOrder(), 44)
		for i, id in string.split((state:GetAttribute("VoteArenas") or "") :: string, ",") do
			local a = (ArenasConfig.List :: any)[id]
			if a then
				local n = if counts.arena then counts.arena[id] or 0 else 0
				local b = Theme.button(
					string.format("%s (%d)", a.Display, n),
					{ Parent = ar, LayoutOrder = i, Size = UDim2.fromOffset(200, 38), TextSize = 13 }
				)
				b.Activated:Connect(function()
					action("Vote", { arena = id })
				end)
			end
		end
	end

	if state:GetAttribute("HostId") == player.UserId then
		section(content, "PRIVATE SERVER RULES (you are the host)", nextOrder())
		local current: any = {}
		pcall(function()
			current = HttpService:JSONDecode(state:GetAttribute("PrivateConfig") or "{}")
		end)
		local base = ModesConfig.copy("Casual")
		for key, spec in ModesConfig.Editable :: any do
			local value = if current[key] ~= nil then current[key] else (base :: any)[key]
			if spec.bool then
				toggleRow(content, nextOrder(), key, value == true, function()
					action("PrivateConfig", { key = key, value = not value })
					task.delay(0.3, Menu.refresh)
				end)
			elseif spec.options then
				local idx = table.find(spec.options, value) or 1
				stepper(content, nextOrder(), key, tostring(value), function()
					action("PrivateConfig", { key = key, value = spec.options[((idx - 2) % #spec.options) + 1] })
					task.delay(0.3, Menu.refresh)
				end, function()
					action("PrivateConfig", { key = key, value = spec.options[(idx % #spec.options) + 1] })
					task.delay(0.3, Menu.refresh)
				end)
			else
				stepper(content, nextOrder(), key, tostring(value), function()
					action("PrivateConfig", { key = key, value = value - spec.step })
					task.delay(0.3, Menu.refresh)
				end, function()
					action("PrivateConfig", { key = key, value = value + spec.step })
					task.delay(0.3, Menu.refresh)
				end)
			end
		end
		local sr = row(content, nextOrder(), 44)
		local start = Theme.button("START MATCH NOW", {
			Parent = sr,
			Size = UDim2.fromOffset(200, 38),
			BackgroundColor3 = C.Good,
			TextColor3 = Color3.new(0, 0, 0),
		})
		start.Activated:Connect(function()
			action("StartNow", nil)
			Menu.toggle(false)
		end)
	end

	section(content, "QUICK CONTROLS", nextOrder())
	Theme.label(
		"WASD move · Shift sprint · Space jump · Q cut · Ctrl slide · E dive · F burst · LMB reach/throw · RMB mark/fake · B celebrate",
		14,
		{
			Parent = content,
			LayoutOrder = nextOrder(),
			TextWrapped = true,
			Size = UDim2.new(1, -10, 0, 40),
			TextColor3 = C.Muted,
		}
	)
end

function render.Training(content: Instance)
	local o = 0
	local function nextOrder(): number
		o += 1
		return o
	end
	section(content, "TRAINING GROUNDS", nextOrder())
	local r = row(content, nextOrder(), 44)
	local enter = Theme.button("GO TO TRAINING", {
		Parent = r,
		LayoutOrder = 1,
		Size = UDim2.fromOffset(180, 38),
		BackgroundColor3 = C.Accent,
		TextColor3 = Color3.new(0, 0, 0),
	})
	enter.Activated:Connect(function()
		action("EnterTraining", nil)
		Menu.toggle(false)
	end)
	local leave = Theme.button("BACK TO MATCH", { Parent = r, LayoutOrder = 2, Size = UDim2.fromOffset(180, 38) })
	leave.Activated:Connect(function()
		action("LeaveTraining", nil)
		Menu.toggle(false)
	end)
	local cancel = Theme.button("CANCEL DRILL", { Parent = r, LayoutOrder = 3, Size = UDim2.fromOffset(160, 38) })
	cancel.Activated:Connect(function()
		action("CancelDrill", nil)
	end)
	for _, d in DRILLS do
		local dr = row(content, nextOrder(), 46)
		local pbs = if profile then profile.personalBests else nil
		local pbValue = pbs and pbs[d.id]
		local pbText = if pbValue
			then (if d.pb == "time" then string.format("PB %.2f s", pbValue) else string.format("PB %d", pbValue))
			else ""
		local done = profile and profile.drillsDone and profile.drillsDone[d.id]
		Theme.label(
			(if done then "[x] " else "") .. d.name,
			16,
			{ Parent = dr, LayoutOrder = 1, Size = UDim2.fromOffset(200, 30), Font = Theme.Fonts.Heavy }
		)
		Theme.label(
			d.desc,
			13,
			{ Parent = dr, LayoutOrder = 2, Size = UDim2.fromOffset(330, 30), TextColor3 = C.Muted, TextWrapped = true }
		)
		Theme.label(pbText, 13, { Parent = dr, LayoutOrder = 3, Size = UDim2.fromOffset(90, 30), TextColor3 = C.Gold })
		local go = Theme.button("START", { Parent = dr, LayoutOrder = 4, Size = UDim2.fromOffset(80, 32) })
		go.Activated:Connect(function()
			action("StartDrill", d.id)
			Menu.toggle(false)
		end)
	end

	section(content, "FREE LAUNCHER (advanced practice)", nextOrder())
	stepper(content, nextOrder(), "Throw type", launcher.throwType, function()
		local i = table.find(DiscConfig.TypeOrder, launcher.throwType) or 1
		launcher.throwType = DiscConfig.TypeOrder[((i - 2) % #DiscConfig.TypeOrder) + 1]
		Menu.refresh()
	end, function()
		local i = table.find(DiscConfig.TypeOrder, launcher.throwType) or 1
		launcher.throwType = DiscConfig.TypeOrder[(i % #DiscConfig.TypeOrder) + 1]
		Menu.refresh()
	end)
	stepper(content, nextOrder(), "Power", string.format("%d%%", launcher.power * 100), function()
		launcher.power = math.clamp(launcher.power - 0.1, 0.1, 1)
		Menu.refresh()
	end, function()
		launcher.power = math.clamp(launcher.power + 0.1, 0.1, 1)
		Menu.refresh()
	end)
	stepper(content, nextOrder(), "Launch angle", launcher.pitch .. " deg", function()
		launcher.pitch = math.clamp(launcher.pitch - 4, -10, 40)
		Menu.refresh()
	end, function()
		launcher.pitch = math.clamp(launcher.pitch + 4, -10, 40)
		Menu.refresh()
	end)
	stepper(content, nextOrder(), "Curve (bank)", string.format("%+.1f", launcher.bank), function()
		launcher.bank = math.clamp(launcher.bank - 0.25, -1, 1)
		Menu.refresh()
	end, function()
		launcher.bank = math.clamp(launcher.bank + 0.25, -1, 1)
		Menu.refresh()
	end)
	stepper(content, nextOrder(), "Aim offset", launcher.offset .. " deg", function()
		launcher.offset = math.clamp(launcher.offset - 5, -30, 30)
		Menu.refresh()
	end, function()
		launcher.offset = math.clamp(launcher.offset + 5, -30, 30)
		Menu.refresh()
	end)
	local lr = row(content, nextOrder(), 44)
	local launch = Theme.button(
		"LAUNCH",
		{ Parent = lr, Size = UDim2.fromOffset(160, 38), BackgroundColor3 = C.Gold, TextColor3 = Color3.new(0, 0, 0) }
	)
	launch.Activated:Connect(function()
		local role = if player.Character then player.Character:GetAttribute("UBRole") else nil
		if role ~= "Training" then
			action("StartDrill", "Launcher")
			task.wait(0.4)
		end
		action("LaunchCustom", launcher)
		Menu.toggle(false)
	end)
	local setup = Theme.button("GO TO LAUNCHER", { Parent = lr, Size = UDim2.fromOffset(180, 38) })
	setup.Activated:Connect(function()
		action("StartDrill", "Launcher")
	end)
end

function render.Profile(content: Instance)
	local o = 0
	local function nextOrder(): number
		o += 1
		return o
	end
	if not profile then
		Theme.label("Loading profile...", 16, { Parent = content, LayoutOrder = 1 })
		return
	end
	section(content, string.format("LEVEL %d", profile.level), nextOrder())
	local bar = make("Frame", {
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -10, 0, 10),
		LayoutOrder = nextOrder(),
		Parent = content,
		Theme.corner(5),
	})
	make("Frame", {
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(math.clamp(profile.xpInto / math.max(profile.xpNeed, 1), 0, 1), 1),
		Parent = bar,
		Theme.corner(5),
	})
	Theme.label(
		string.format(
			"%d / %d XP to next level%s",
			profile.xpInto,
			profile.xpNeed,
			if profile.persistent then "" else "  (not saved this session)"
		),
		13,
		{
			Parent = content,
			LayoutOrder = nextOrder(),
			TextColor3 = C.Muted,
		}
	)
	section(
		content,
		string.format(
			"RANKED: %s  %d  (peak %d, %d games)",
			profile.division,
			profile.rating,
			profile.peakRating,
			profile.ratedGames
		),
		nextOrder()
	)
	section(content, "CAREER", nextOrder())
	local keys = {
		"matches",
		"wins",
		"goals",
		"assists",
		"catches",
		"completions",
		"blocks",
		"interceptions",
		"layouts",
		"hucks",
		"callahans",
		"greatests",
		"perfectReleases",
		"techs",
	}
	local grid = make("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -10, 0, 130),
		LayoutOrder = nextOrder(),
		Parent = content,
	})
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(150, 26)
	layout.CellPadding = UDim2.fromOffset(6, 4)
	layout.Parent = grid
	for _, k in keys do
		Theme.label(string.format("%s: %d", k, profile.stats[k] or 0), 14, { Parent = grid })
	end
	section(content, "TECHNIQUE MASTERY", nextOrder())
	for tech, name in MovementConfig.TechNames :: any do
		local m = profile.techMastery and profile.techMastery[tech]
		if m and m.count > 0 then
			Theme.label(
				string.format(
					"%s  ·  %d performed  ·  %d%% Perfect",
					name,
					m.count,
					math.floor(m.perfect / m.count * 100)
				),
				14,
				{
					Parent = content,
					LayoutOrder = nextOrder(),
					TextColor3 = (Theme.TechColors :: any)[tech] or C.Text,
				}
			)
		end
	end
	section(content, "ACHIEVEMENTS", nextOrder())
	for _, a in profile.achievements do
		Theme.label(
			string.format(
				"%s %s — %s (%d/%d)",
				if a.done then "[x]" else "[ ]",
				a.name,
				a.description,
				a.progress,
				a.goal
			),
			14,
			{
				Parent = content,
				LayoutOrder = nextOrder(),
				TextColor3 = if a.done then C.Gold else C.Muted,
				TextWrapped = true,
				Size = UDim2.new(1, -10, 0, 34),
			}
		)
	end
end

function render.Locker(content: Instance)
	local o = 0
	local function nextOrder(): number
		o += 1
		return o
	end
	if not profile then
		Theme.label("Loading profile...", 16, { Parent = content, LayoutOrder = 1 })
		return
	end
	Theme.label("Everything here is cosmetic. Nothing changes how you move, throw or catch.", 14, {
		Parent = content,
		LayoutOrder = nextOrder(),
		TextColor3 = C.Muted,
	})
	local slots = {
		{ key = "disc", title = "DISC SKINS", list = ProgressionConfig.DiscSkins },
		{ key = "trail", title = "TRAILS", list = ProgressionConfig.Trails },
		{ key = "celebration", title = "CELEBRATIONS", list = ProgressionConfig.Celebrations },
		{ key = "banner", title = "BANNERS", list = ProgressionConfig.Banners },
		{ key = "title", title = "TITLES", list = ProgressionConfig.Titles },
	}
	for _, slot in slots do
		section(content, slot.title, nextOrder())
		local r = make("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -10, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = nextOrder(),
			Parent = content,
		})
		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.fromOffset(150, 34)
		grid.CellPadding = UDim2.fromOffset(6, 6)
		grid.Parent = r
		local unlocked = profile.unlocked[slot.key] or {}
		local equipped = profile.equipped[slot.key]
		for _, item in slot.list do
			local has = table.find(unlocked, item.id) ~= nil
			local label = item.name
			if not has then
				label = if item.level then (item.name .. " · Lv " .. item.level) else (item.name .. " · achievement")
			end
			local b = Theme.button(label, {
				Parent = r,
				TextSize = 12,
				BackgroundColor3 = if item.id == equipped then C.Accent elseif has then C.PanelLight else C.Panel,
				TextColor3 = if item.id == equipped then Color3.new(0, 0, 0) elseif has then C.Text else C.Muted,
			})
			if item.color then
				make("Frame", {
					BackgroundColor3 = item.color,
					BorderSizePixel = 0,
					Size = UDim2.new(0, 6, 1, -8),
					Position = UDim2.fromOffset(4, 4),
					Parent = b,
				})
			end
			if has then
				b.Activated:Connect(function()
					action("Equip", { slot = slot.key, id = item.id })
				end)
			end
		end
	end
end

function render.Leaderboard(content: Instance)
	section(content, "SEASON LEADERBOARD", 1)
	local status = Theme.label("Loading...", 14, { Parent = content, LayoutOrder = 2, TextColor3 = C.Muted })
	task.spawn(function()
		local ok, data = pcall(function()
			return Net.func("GetLeaderboard"):InvokeServer()
		end)
		if not ok or type(data) ~= "table" then
			status.Text = "Leaderboard unavailable."
			return
		end
		status.Text = "Season " .. tostring(data.season)
		if #data.entries == 0 then
			status.Text ..= " — no ranked results yet (or DataStores are unavailable in Studio)."
		end
		for i, e in data.entries do
			Theme.label(string.format("#%d  %s  ·  %d  ·  %s", e.rank, e.name, e.rating, e.division), 15, {
				Parent = content,
				LayoutOrder = 2 + i,
				TextColor3 = if e.userId == player.UserId then C.Gold else C.Text,
			})
		end
	end)
end

function render.Settings(content: Instance)
	local s = controllers.SettingsController
	local o = 0
	local function nextOrder(): number
		o += 1
		return o
	end
	section(content, "SETTINGS", nextOrder())
	local numeric = {
		{ key = "MouseSensitivity", label = "Mouse sensitivity", step = 0.1, min = 0.2, max = 3 },
		{ key = "GamepadSensitivity", label = "Gamepad sensitivity", step = 0.1, min = 0.2, max = 3 },
		{ key = "TouchSensitivity", label = "Touch sensitivity", step = 0.1, min = 0.2, max = 3 },
		{ key = "FieldOfView", label = "Field of view", step = 2, min = 60, max = 90 },
		{ key = "TouchButtonScale", label = "Touch button size", step = 0.1, min = 0.7, max = 1.5 },
		{ key = "MasterVolume", label = "Master volume", step = 0.1, min = 0, max = 1 },
		{ key = "SfxVolume", label = "Effects volume", step = 0.1, min = 0, max = 1 },
		{ key = "CrowdVolume", label = "Crowd volume", step = 0.1, min = 0, max = 1 },
	}
	for _, n in numeric do
		local v = s.get(n.key)
		stepper(content, nextOrder(), n.label, string.format(if n.step < 1 then "%.1f" else "%d", v), function()
			s.set(n.key, math.clamp(math.floor((v - n.step) * 10 + 0.5) / 10, n.min, n.max))
			Menu.refresh()
		end, function()
			s.set(n.key, math.clamp(math.floor((v + n.step) * 10 + 0.5) / 10, n.min, n.max))
			Menu.refresh()
		end)
	end
	local toggles = {
		{ key = "InvertY", label = "Invert camera Y" },
		{ key = "CameraShake", label = "Camera shake (subtle)" },
		{ key = "ShowComboFeed", label = "Combo feed" },
		{ key = "ShowTechLabels", label = "Technique labels" },
		{ key = "TrajectoryPreview", label = "Throw preview arc" },
		{ key = "ToggleSprint", label = "Toggle sprint (instead of hold)" },
		{ key = "AutoSprintTouch", label = "Auto-sprint on touch (push stick fully)" },
		{ key = "LeftHanded", label = "Left-handed thrower" },
	}
	for _, t in toggles do
		toggleRow(content, nextOrder(), t.label, s.get(t.key) == true, function()
			s.set(t.key, not s.get(t.key))
			Menu.refresh()
		end)
	end
end

function render.Controls(content: Instance)
	local s = controllers.SettingsController
	local o = 0
	local function nextOrder(): number
		o += 1
		return o
	end
	section(content, "CONTROLS (click a binding, then press the new key/button)", nextOrder())
	local kb = s.bindings("keyboard")
	local gp = s.bindings("gamepad")
	for _, act in InputConfig.Actions do
		local r = row(content, nextOrder(), 34)
		Theme.label(
			(InputConfig.Display :: any)[act] or act,
			14,
			{ Parent = r, LayoutOrder = 1, Size = UDim2.fromOffset(300, 28) }
		)
		local kbText = table.concat(kb[act] or {}, " / ")
		local b1 = Theme.button(
			if kbText ~= "" then kbText else "—",
			{ Parent = r, LayoutOrder = 2, Size = UDim2.fromOffset(170, 28), TextSize = 13 }
		)
		b1.Activated:Connect(function()
			rebinding = { action = act, button = b1 }
			b1.Text = "press a key..."
		end)
		Theme.label(
			table.concat(gp[act] or {}, " / "),
			13,
			{ Parent = r, LayoutOrder = 3, Size = UDim2.fromOffset(150, 28), TextColor3 = C.Muted }
		)
	end
	local rr = row(content, nextOrder(), 44)
	local reset = Theme.button("RESET TO DEFAULTS", { Parent = rr, Size = UDim2.fromOffset(200, 36) })
	reset.Activated:Connect(function()
		s.resetBindings()
		Menu.refresh()
	end)
	section(content, "TECHNIQUE GUIDE", nextOrder())
	for _, line in TECH_GUIDE do
		Theme.label(line, 13, {
			Parent = content,
			LayoutOrder = nextOrder(),
			TextWrapped = true,
			Size = UDim2.new(1, -10, 0, 36),
			TextColor3 = C.Muted,
			Font = Theme.Fonts.Medium,
		})
	end
end

---------------------------------------------------------------------------

function Menu.refresh()
	if not isOpen then
		return
	end
	local content = refs.content :: ScrollingFrame
	clear(content)
	content.CanvasPosition = Vector2.zero
	local fn = render[currentTab]
	if fn then
		fn(content)
	end
	for name, b in refs.tabButtons do
		b.BackgroundColor3 = if name == currentTab then C.Accent else C.PanelLight
		b.TextColor3 = if name == currentTab then Color3.new(0, 0, 0) else C.Text
	end
end

function Menu.toggle(open: boolean?)
	local target = if open == nil then not isOpen else open
	isOpen = target
	refs.dim.Visible = target
	controllers.InputController.setMenuOpen(target)
	rebinding = nil
	if target then
		Menu.refresh()
		if controllers.InputController.scheme() == "Gamepad" then
			GuiService.SelectedObject = refs.tabButtons[currentTab]
		end
	else
		GuiService.SelectedObject = nil
	end
end

function Menu.isOpen(): boolean
	return isOpen
end

function Menu.setProfile(p: any)
	profile = p
	if isOpen and (currentTab == "Profile" or currentTab == "Locker" or currentTab == "Training") then
		Menu.refresh()
	end
end

function Menu.build(parent: ScreenGui, c: any)
	controllers = c
	local dim = make("Frame", {
		Name = "MenuDim",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 20,
		Parent = parent,
	})
	refs.dim = dim
	local window = Theme.panel({
		Name = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.8, 0, 0.82, 0),
		ZIndex = 21,
		Parent = dim,
	})
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(980, 640)
	constraint.Parent = window
	Theme.label("ULTIMATE: BREAKPOINT", 24, {
		Parent = window,
		Position = UDim2.fromOffset(18, 12),
		Size = UDim2.fromOffset(400, 30),
		Font = Theme.Fonts.Heavy,
		ZIndex = 22,
	})
	local close = Theme.button("CLOSE (M)", {
		Parent = window,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 12),
		Size = UDim2.fromOffset(120, 32),
		ZIndex = 22,
	})
	close.Activated:Connect(function()
		Menu.toggle(false)
	end)
	local tabs = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 54),
		Size = UDim2.new(0, 160, 1, -68),
		Parent = window,
		Theme.list(6),
	})
	refs.tabButtons = {}
	for i, name in TABS do
		local b = Theme.button(string.upper(name), {
			Parent = tabs,
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, 40),
			ZIndex = 22,
		})
		b.Activated:Connect(function()
			currentTab = name
			Menu.refresh()
		end)
		refs.tabButtons[name] = b
	end
	local content = make("ScrollingFrame", {
		Name = "Content",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(190, 54),
		Size = UDim2.new(1, -204, 1, -68),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ZIndex = 22,
		Parent = window,
		Theme.list(8),
	})
	refs.content = content

	-- capture the next key press while rebinding
	UserInputService.InputBegan:Connect(function(input)
		local rb = rebinding
		if not rb or not isOpen then
			return
		end
		local t = input.UserInputType
		local name: string? = nil
		local scheme = "keyboard"
		if t == Enum.UserInputType.Keyboard then
			if input.KeyCode == Enum.KeyCode.Escape then
				rebinding = nil
				Menu.refresh()
				return
			end
			name = input.KeyCode.Name
		elseif t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 then
			return -- clicks are for the UI itself
		elseif t == Enum.UserInputType.Gamepad1 then
			name = input.KeyCode.Name
			scheme = "gamepad"
		end
		if name then
			rebinding = nil
			controllers.SettingsController.setBinding(scheme, rb.action, { name })
			task.defer(Menu.refresh)
		end
	end)
end

return Menu
