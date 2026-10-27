--!strict
--[[
	Menu — Play, Training, Profile, Locker, Leaderboard, Settings, Controls.

	Play: join (mid-match only: everyone in the warm-up is already in the
	next match) / training, then during warm-up the mode choice. On a public
	server only the modes the head count allows are offered (UBState
	VoteModes; Mini up to 9 players, Normal from 7), each other mode says how
	many players it needs, and a single eligible mode is shown as decided
	rather than as a vote. The ranked line comes from RankedNext /
	RankedStatus / RankedReady ("4/6"). In a private server or Studio the
	host picks the mode (PrivateConfig Mode), edits the rules in
	Modes.EditableOrder (labels from Modes.Editable, values from the chosen
	mode's preset) and can START MATCH NOW; ranked is always off there. The
	page refreshes itself while open when the vote state changes.

	Controls: rebinding, sprint options (AutoSprint, ToggleSprint) and a
	technique guide written with the keys you have bound.
]]

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
local SignaturesConfig = require(Shared.Config.Signatures)
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

-- UBState attributes the Play tab shows (it refreshes when they change).
local PLAY_STATE = {
	"Phase",
	"VoteModes",
	"VoteCounts",
	"VoteDefault",
	"VoteArenas",
	"RankedReady",
	"RankedStatus",
	"RankedNext",
	"PrivateConfig",
	"HostId",
	"Ranked",
	"ModeName",
}

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
	{
		id = "BreakMark",
		name = "Break the Mark",
		desc = "Beat a bot marker from your pivot: step out, fake, swing, release.",
		pb = "score",
	},
	{
		id = "ResetLab",
		name = "Reset Lab",
		desc = "High lobs to tip and chase, rebound walls. Land the signature moves.",
		pb = "score",
	},
}

-- The technique guide, written with the keys currently bound (keyboard).
local function techGuide(): { string }
	local function k(action: string): string
		local label = controllers.SettingsController.keyLabel(action, "keyboard")
		return if label ~= "" then label else "(unbound)"
	end
	local cut, burst, slide, dive, jump = k("Cut"), k("Burst"), k("Slide"), k("Dive"), k("Jump")
	return {
		string.format(
			"RUN — move to run; sprint starts by itself when you push one way (AutoSprint), or hold %s.",
			k("Sprint")
		),
		string.format(
			"SNAP CUT — while running, steer to the new direction and tap %s (hold A or D, then %s). A longer straight line before it = Perfect.",
			cut,
			cut
		),
		string.format(
			"PLANT — tap %s with S held (or no direction) at speed: you stop dead. Hold a direction to restart; %s, %s or %s just after = a faster restart.",
			cut,
			cut,
			burst,
			jump
		),
		string.format(
			"FAKE COMMIT — %s along your line without steering: a jab. Cut away within 0.6 s for a Sold cut (always Perfect).",
			cut
		),
		string.format(
			"BURST — %s. A short explosive push (1.2 s cooldown). Perfect right after a cut, slide cut or pop-up; free out of a plant.",
			burst
		),
		string.format(
			"SLIDE / SLIDE CUT — %s while running. %s mid-slide leaves at a new angle; %s bursts out.",
			slide,
			cut,
			burst
		),
		string.format(
			"AIR REDIRECT — %s in the air with a direction held: bend your path once per jump. Near the apex = Perfect.",
			cut
		),
		string.format(
			"PRECISION LANDING — %s just before touchdown keeps your speed. After a dive it is a Roll-out.",
			slide
		),
		string.format(
			"LAYOUT — %s. A huge reach. Pop up with %s, %s or %s as the slide stops.",
			dive,
			jump,
			cut,
			burst
		),
		string.format(
			"WALL REBOUND — %s beside a glowing Rebound wall while airborne (special arenas and the Combo Lab).",
			jump
		),
		string.format(
			"TIP RESET — in the air, press %s as the disc reaches your hands: it pops up and your air cut and air layout come back (Charged). Wall Rebounds reset too; a Perfect landing or pop-up refunds Burst / Layout.",
			k("Secondary")
		),
		"SIGNATURE MOVES — Reset Grab, Double Tip, Wall Tip, Double Layout, Reset Loop, Self-D, Skyball, The Greatest: hard, and worth thousands (Training lists how).",
		"CHAINS — techniques within 1.5 s of each other chain. A catch, block or interception within 2 s converts the chain: x2 points and a highlight.",
		string.format(
			"WITH THE DISC — WASD steps your free foot around the pivot (the coloured disc under you). %s / %s swing left / right, RMB fakes, %s hops for a high release, hold %s to release low. Fake, swing, release fast = BREAK.",
			cut,
			dive,
			jump,
			slide
		),
		string.format(
			"MARK — hold RMB near the thrower: shuffle and keep your hands in the lane. %s switches Low / High hands; jump to block a hop.",
			slide
		),
		"REACH — LMB without the disc: extend toward your aim for a moment. Airborne reaches are Aerial Catch Adjustments.",
	}
end

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

local function attrString(inst: Instance, name: string): string
	local v = inst:GetAttribute(name)
	return if type(v) == "string" then v else ""
end

local function decodeJson(text: string): { [string]: any }
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(if text ~= "" then text else "{}")
	end)
	return if ok and type(decoded) == "table" then decoded else {}
end

local function modeName(id: string?): string
	local m = if id then ModesConfig.List[id] else nil
	return if m then m.Display else tostring(id or "")
end

-- Head counts each mode is offered for (from Modes.eligible), for the
-- "needs N players" hints.
local ELIGIBLE: { [string]: { min: number, max: number } } = {}
for n = 1, 32 do
	local options = ModesConfig.eligible(n)
	for _, id in options do
		local r = ELIGIBLE[id]
		if r then
			r.max = n
		else
			ELIGIBLE[id] = { min = n, max = n }
		end
	end
end

local function needsText(id: string): string
	local r = ELIGIBLE[id]
	if not r then
		return "not available"
	elseif r.min > 1 then
		return string.format("needs %d+ players", r.min)
	elseif r.max < 32 then
		return string.format("up to %d players", r.max)
	end
	return ""
end

local function formatRule(key: string, value: any): string
	if type(value) ~= "number" then
		return tostring(value)
	elseif key == "TimeCap" then
		return Theme.formatTime(value)
	elseif key == "PreviewFraction" then
		return string.format("%d%%", math.floor(value * 100 + 0.5))
	elseif key == "StallInterval" then
		return string.format("%.1f s", value)
	end
	return tostring(value)
end

local myVote: string? = nil

local function modeButton(parent: Instance, order: number, text: string, selected: boolean, onPick: () -> ())
	local b = Theme.button(text, {
		Parent = parent,
		LayoutOrder = order,
		Size = UDim2.fromOffset(190, 38),
		BackgroundColor3 = if selected then C.Accent else C.PanelLight,
		TextColor3 = if selected then Color3.new(0, 0, 0) else C.Text,
	})
	b.Activated:Connect(onPick)
end

function render.Play(content: Instance)
	local state = Net.state()
	local phase = attrString(state, "Phase")
	local o = 0
	local function nextOrder(): number
		o += 1
		return o
	end
	local function note(text: string, color: Color3?)
		Theme.label(text, 14, {
			Parent = content,
			LayoutOrder = nextOrder(),
			TextColor3 = color or C.Muted,
			TextWrapped = true,
			Size = UDim2.new(1, -10, 0, 20),
		})
	end
	section(content, "PLAY", nextOrder())
	note(
		string.format(
			"%s  ·  %s  ·  %s",
			if phase ~= "" then phase else "Warmup",
			if attrString(state, "ModeName") ~= "" then attrString(state, "ModeName") else "Warm-up",
			attrString(state, "ArenaName")
		)
	)
	local role = if player.Character then player.Character:GetAttribute("UBRole") else nil
	local inTraining = role == "Training"
	local r = row(content, nextOrder(), 44)
	if role == "Bench" then
		Theme.label("ON THE BENCH — you play next point", 15, {
			Parent = r,
			LayoutOrder = 1,
			Size = UDim2.fromOffset(330, 30),
			TextColor3 = C.Gold,
			Font = Theme.Fonts.Heavy,
		})
	elseif phase == "Intermission" and not inTraining then
		-- everyone in the warm-up plays the next match: nothing to join
		Theme.label("YOU'RE IN THE NEXT MATCH — warm up meanwhile", 15, {
			Parent = r,
			LayoutOrder = 1,
			Size = UDim2.fromOffset(330, 30),
			TextColor3 = C.Accent,
			Font = Theme.Fonts.Heavy,
		})
	elseif role ~= "Match" then
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

	local hostId = state:GetAttribute("HostId")
	local hosted = type(hostId) == "number" and hostId ~= 0
	local isHost = hosted and hostId == player.UserId
	local private = decodeJson(attrString(state, "PrivateConfig"))
	local default = attrString(state, "VoteDefault")
	if not ModesConfig.has(default) then
		default = ModesConfig.Default
	end
	local nextMode: string = if ModesConfig.has(private.Mode) then private.Mode else default

	if phase == "Intermission" then
		local counts = decodeJson(attrString(state, "VoteCounts"))
		local modeCounts = if type(counts.mode) == "table" then counts.mode else {}
		local options: { string } = {}
		for _, id in string.split(attrString(state, "VoteModes"), ",") do
			if ModesConfig.has(id) then
				table.insert(options, id)
			end
		end
		section(content, "NEXT MATCH: MODE", nextOrder())
		if isHost then
			local mr = row(content, nextOrder(), 44)
			for i, id in ModesConfig.Order do
				modeButton(mr, i, modeName(id), id == nextMode, function()
					action("PrivateConfig", { key = "Mode", value = id })
					task.delay(0.3, Menu.refresh, true)
				end)
			end
			note(
				"You are the host: you pick the mode and the rules below. Ranked is off in private servers and Studio."
			)
		elseif hosted and ModesConfig.has(private.Mode) then
			note("The host picked " .. modeName(nextMode) .. ".", C.Text)
		else
			if #options > 1 then
				note(
					if hosted
						then "Vote for a mode (the host has the final say)."
						else "This many players can play either mode: vote."
				)
				local mr = row(content, nextOrder(), 44)
				for i, id in options do
					local n = tonumber(modeCounts[id]) or 0
					modeButton(mr, i, string.format("%s (%d)", modeName(id), n), id == myVote, function()
						myVote = id
						action("Vote", { mode = id })
						task.delay(0.3, Menu.refresh, true)
					end)
				end
			else
				note(modeName(options[1] or default) .. " — set by the number of players", C.Text)
			end
			for _, id in ModesConfig.Order do
				if not table.find(options, id) then
					note(modeName(id) .. " — " .. needsText(id))
				end
			end
		end
		if not hosted then
			local ready = attrString(state, "RankedReady")
			if state:GetAttribute("RankedNext") == true then
				note("RANKED — every spot is a player" .. (if ready ~= "" then " (" .. ready .. ")" else ""), C.Gold)
			else
				local status = attrString(state, "RankedStatus")
				note("UNRANKED — " .. (if status ~= "" then status else "ranked needs every spot filled by a player"))
			end
		end

		section(content, "NEXT MATCH: ARENA", nextOrder())
		local arenaCounts = if type(counts.arena) == "table" then counts.arena else {}
		local ar = row(content, nextOrder(), 44)
		for i, id in string.split(attrString(state, "VoteArenas"), ",") do
			local a = (ArenasConfig.List :: any)[id]
			if a then
				local n = tonumber(arenaCounts[id]) or 0
				local b = Theme.button(
					string.format("%s (%d)", a.Display, n),
					{ Parent = ar, LayoutOrder = i, Size = UDim2.fromOffset(200, 38), TextSize = 13 }
				)
				b.Activated:Connect(function()
					action("Vote", { arena = id })
					task.delay(0.3, Menu.refresh, true)
				end)
			end
		end
	elseif state:GetAttribute("Ranked") == true then
		note("This match is RANKED. Leaving counts as a loss.", C.Gold)
	end

	if isHost then
		section(content, "HOST RULES (private server / Studio)", nextOrder())
		if phase ~= "Intermission" then
			note("Changes apply from the next match.")
		end
		local base = ModesConfig.editableDefaults(nextMode)
		for _, key in ModesConfig.EditableOrder do
			local spec = ModesConfig.Editable[key]
			if key ~= "Mode" and spec then
				local value = if private[key] ~= nil then private[key] else base[key]
				local function send(v: any)
					action("PrivateConfig", { key = key, value = v })
					task.delay(0.3, Menu.refresh, true)
				end
				local options = spec.options
				if spec.bool then
					toggleRow(content, nextOrder(), spec.label, value == true, function()
						send(not (value == true))
					end)
				elseif options then
					local idx = table.find(options, value) or 1
					stepper(content, nextOrder(), spec.label, tostring(value), function()
						send(options[((idx - 2) % #options) + 1])
					end, function()
						send(options[(idx % #options) + 1])
					end)
				else
					local v = tonumber(value) or 0
					local step = spec.step or 1
					stepper(content, nextOrder(), spec.label, formatRule(key, v), function()
						send(v - step)
					end, function()
						send(v + step)
					end)
				end
			end
		end
		if phase == "Intermission" then
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
	end

	section(content, "QUICK CONTROLS", nextOrder())
	local function k(a: string): string
		return controllers.SettingsController.keyLabel(a, "keyboard")
	end
	Theme.label(
		string.format(
			"WASD move · %s sprint (or automatic) · %s jump · %s cut · %s burst · %s slide · %s dive · LMB reach / throw · RMB mark / fake · with the disc: WASD step, %s / %s swing, %s hop · %s celebrate",
			k("Sprint"),
			k("Jump"),
			k("Cut"),
			k("Burst"),
			k("Slide"),
			k("Dive"),
			k("Cut"),
			k("Dive"),
			k("Jump"),
			k("Celebrate")
		),
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

	-- the signature moves: what they are and how many you have landed
	section(content, "SIGNATURE MOVES (hard, worth a lot)", nextOrder())
	local intro = row(content, nextOrder(), 34)
	Theme.label(
		string.format(
			"In the air, press %s as the disc reaches your hands to TIP it: your air moves come back (a reset). Chain resets into the moves below.",
			controllers.SettingsController.keyLabel("Secondary", "keyboard")
		),
		13,
		{ Parent = intro, Size = UDim2.new(1, -10, 1, 0), TextColor3 = C.Muted, TextWrapped = true }
	)
	for _, id in SignaturesConfig.Order do
		local def = SignaturesConfig.List[id]
		local sr = row(content, nextOrder(), 40)
		local count = if profile and profile.stats then profile.stats["sig" .. id] or 0 else 0
		local color = if def.tier >= 3 then C.Perfect elseif def.tier >= 2 then C.Gold else C.Accent
		Theme.label(def.name, 15, {
			Parent = sr,
			LayoutOrder = 1,
			Size = UDim2.fromOffset(150, 30),
			Font = Theme.Fonts.Heavy,
			TextColor3 = color,
		})
		Theme.label(def.how, 12, {
			Parent = sr,
			LayoutOrder = 2,
			Size = UDim2.fromOffset(400, 34),
			TextColor3 = C.Muted,
			TextWrapped = true,
		})
		Theme.label(
			string.format("+%d  ·  x%d", def.points, count),
			13,
			{ Parent = sr, LayoutOrder = 3, Size = UDim2.fromOffset(110, 30), TextColor3 = C.Gold }
		)
	end

	section(content, "FREE LAUNCHER (advanced practice)", nextOrder())
	stepper(content, nextOrder(), "Throw type", launcher.throwType, function()
		local i = table.find(DiscConfig.TypeOrder, launcher.throwType) or 1
		launcher.throwType = DiscConfig.TypeOrder[((i - 2) % #DiscConfig.TypeOrder) + 1]
		Menu.refresh(true)
	end, function()
		local i = table.find(DiscConfig.TypeOrder, launcher.throwType) or 1
		launcher.throwType = DiscConfig.TypeOrder[(i % #DiscConfig.TypeOrder) + 1]
		Menu.refresh(true)
	end)
	stepper(content, nextOrder(), "Power", string.format("%d%%", launcher.power * 100), function()
		launcher.power = math.clamp(launcher.power - 0.1, 0.1, 1)
		Menu.refresh(true)
	end, function()
		launcher.power = math.clamp(launcher.power + 0.1, 0.1, 1)
		Menu.refresh(true)
	end)
	stepper(content, nextOrder(), "Launch angle", launcher.pitch .. " deg", function()
		launcher.pitch = math.clamp(launcher.pitch - 4, -10, 40)
		Menu.refresh(true)
	end, function()
		launcher.pitch = math.clamp(launcher.pitch + 4, -10, 40)
		Menu.refresh(true)
	end)
	stepper(content, nextOrder(), "Curve (bank)", string.format("%+.1f", launcher.bank), function()
		launcher.bank = math.clamp(launcher.bank - 0.25, -1, 1)
		Menu.refresh(true)
	end, function()
		launcher.bank = math.clamp(launcher.bank + 0.25, -1, 1)
		Menu.refresh(true)
	end)
	stepper(content, nextOrder(), "Aim offset", launcher.offset .. " deg", function()
		launcher.offset = math.clamp(launcher.offset - 5, -30, 30)
		Menu.refresh(true)
	end, function()
		launcher.offset = math.clamp(launcher.offset + 5, -30, 30)
		Menu.refresh(true)
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
			Menu.refresh(true)
		end, function()
			s.set(n.key, math.clamp(math.floor((v + n.step) * 10 + 0.5) / 10, n.min, n.max))
			Menu.refresh(true)
		end)
	end
	local toggles = {
		{ key = "InvertY", label = "Invert camera Y" },
		{ key = "CameraShake", label = "Camera shake (subtle)" },
		{ key = "ShowComboFeed", label = "Combo chain (counter and end card)" },
		{ key = "ShowTechLabels", label = "Technique labels" },
		{ key = "ShowHitboxes", label = "Show hitboxes (everyone has the same fixed body)" },
		{ key = "TrajectoryPreview", label = "Throw preview arc" },
		{ key = "LeftHanded", label = "Left-handed thrower" },
	}
	for _, t in toggles do
		toggleRow(content, nextOrder(), t.label, s.get(t.key) == true, function()
			s.set(t.key, not s.get(t.key))
			Menu.refresh(true)
		end)
	end
	Theme.label("Sprint options are under Controls.", 13, {
		Parent = content,
		LayoutOrder = nextOrder(),
		TextColor3 = C.Muted,
	})
end

local function keyNames(keys: { string }?): string
	local out: { string } = {}
	if keys then
		for _, k in keys do
			table.insert(out, InputConfig.keyLabel(k))
		end
	end
	return table.concat(out, " / ")
end

function render.Controls(content: Instance)
	local s = controllers.SettingsController
	local o = 0
	local function nextOrder(): number
		o += 1
		return o
	end
	section(content, "SPRINT", nextOrder())
	for _, t in
		{
			{ key = "AutoSprint", label = "Auto-sprint (push one way to sprint)" },
			{ key = "ToggleSprint", label = "Sprint key toggles (instead of hold)" },
			{ key = "AutoSprintTouch", label = "Auto-sprint on touch (push the stick fully)" },
		}
	do
		toggleRow(content, nextOrder(), t.label, s.get(t.key) == true, function()
			s.set(t.key, not s.get(t.key))
			Menu.refresh(true)
		end)
	end
	section(content, "CONTROLS (click a binding, then press the new key/button)", nextOrder())
	local kb = s.bindings("keyboard")
	local gp = s.bindings("gamepad")
	for _, act in InputConfig.Actions do
		local r = row(content, nextOrder(), 34)
		Theme.label((InputConfig.Display :: any)[act] or act, 13, {
			Parent = r,
			LayoutOrder = 1,
			Size = UDim2.fromOffset(300, 32),
			TextWrapped = true,
		})
		local kbText = keyNames(kb[act])
		local b1 = Theme.button(
			if kbText ~= "" then kbText else "—",
			{ Parent = r, LayoutOrder = 2, Size = UDim2.fromOffset(170, 28), TextSize = 13 }
		)
		b1.Activated:Connect(function()
			rebinding = { action = act, button = b1 }
			b1.Text = "press a key..."
		end)
		Theme.label(
			keyNames(gp[act]),
			13,
			{ Parent = r, LayoutOrder = 3, Size = UDim2.fromOffset(150, 28), TextColor3 = C.Muted }
		)
	end
	local rr = row(content, nextOrder(), 44)
	local reset = Theme.button("RESET TO DEFAULTS", { Parent = rr, Size = UDim2.fromOffset(200, 36) })
	reset.Activated:Connect(function()
		s.resetBindings()
		Menu.refresh(true)
	end)
	section(content, "TECHNIQUE GUIDE", nextOrder())
	for _, line in techGuide() do
		Theme.label(line, 13, {
			Parent = content,
			LayoutOrder = nextOrder(),
			TextWrapped = true,
			Size = UDim2.new(1, -10, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextColor3 = C.Muted,
			Font = Theme.Fonts.Medium,
		})
	end
end

---------------------------------------------------------------------------

-- Rebuilds the open tab. keepScroll: a refresh of the same tab after a change
-- (keeps where you were scrolled to); otherwise the tab opens at the top.
function Menu.refresh(keepScroll: boolean?)
	if not isOpen then
		return
	end
	local content = refs.content :: ScrollingFrame
	local scroll = content.CanvasPosition
	local selected = GuiService.SelectedObject
	local hadSelection = selected ~= nil and selected:IsDescendantOf(content)
	clear(content)
	local fn = render[currentTab]
	if fn then
		fn(content)
	end
	content.CanvasPosition = if keepScroll then scroll else Vector2.zero
	if hadSelection then
		-- the selected button was rebuilt: keep gamepad navigation alive
		GuiService.SelectedObject = refs.tabButtons[currentTab]
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
		Menu.refresh(true)
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

	-- the Play tab follows the vote / ranked / host state while it is open
	local refreshQueued = false
	local function queuePlayRefresh()
		if refreshQueued or not isOpen or currentTab ~= "Play" then
			return
		end
		refreshQueued = true
		task.delay(0.15, function()
			refreshQueued = false
			if isOpen and currentTab == "Play" then
				Menu.refresh(true)
			end
		end)
	end
	local state = Net.state()
	for _, name in PLAY_STATE do
		state:GetAttributeChangedSignal(name):Connect(queuePlayRefresh)
	end
	state:GetAttributeChangedSignal("Phase"):Connect(function()
		if state:GetAttribute("Phase") == "Intermission" then
			myVote = nil
		end
	end)

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
				Menu.refresh(true)
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
			task.defer(Menu.refresh, true)
		end
	end)
end

return Menu
