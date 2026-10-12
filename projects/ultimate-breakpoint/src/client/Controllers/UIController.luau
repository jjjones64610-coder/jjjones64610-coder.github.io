--!strict
-- UIController — builds the interface and routes server messages to it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local TeamsConfig = require(Shared.Config.Teams)
local UI = script.Parent.Parent.UI
local Theme = require(UI.Theme)
local Hud = require(UI.Hud)
local ThrowHud = require(UI.ThrowHud)
local Menu = require(UI.Menu)
local Panels = require(UI.Panels)
local Mobile = require(UI.Mobile)

local C = Theme.Colors

local UIController = {}

local controllers: any
local player = Players.LocalPlayer
local lastLevel: number? = nil
local hintedVote = false

local REASONS: { [string]: string } = {
	Incomplete = "Incomplete pass",
	Drop = "Dropped",
	Block = "Blocked",
	OutOfBounds = "Out of bounds",
	Stall = "Stalled out",
	Interception = "Intercepted",
}

function UIController.toggleMenu()
	Menu.toggle()
end

local function teamName(t: string?): string
	return if t == "A" then TeamsConfig.A.Name elseif t == "B" then TeamsConfig.B.Name else ""
end

local function onNotify(kind: string, text: string, data: any)
	local d = if type(data) == "table" then data else {}
	if kind == "Banner" then
		Hud.banner(text, d.sub, nil, 1.8)
	elseif kind == "Goal" then
		local scorer = if type(d.scorer) == "number" then (require(Shared.Actors) :: any).nameOf(d.scorer) else ""
		local sub = if d.callahan
			then ("CALLAHAN by " .. scorer)
			else scorer .. (if d.assist
				then "  ·  assist " .. (require(Shared.Actors) :: any).nameOf(d.assist)
				else "")
		Hud.banner(text, sub, Theme.teamColor(d.team), 3)
	elseif kind == "Turnover" then
		local sub = REASONS[d.reason or ""] or ""
		Hud.banner(text, sub .. (if d.team then ("  ·  " .. teamName(d.team) .. " ball") else ""), C.Bad, 1.6)
	elseif kind == "Point" then
		local myTeam = if player.Character then player.Character:GetAttribute("UBTeam") else nil
		local sub = if d.offense == myTeam then "You receive" else "You pull and defend"
		if d.pull == false then
			sub = if d.offense == myTeam then "Your disc" else "Defend"
		end
		Hud.banner(text, sub, nil, 2.2)
	elseif kind == "Toast" then
		Hud.toast(text, nil, 3.5)
	elseif kind == "Achievement" then
		Hud.toast("ACHIEVEMENT: " .. text .. " — " .. tostring(d.description or ""), C.Gold, 6)
		controllers.AudioController.play("Highlight")
	elseif kind == "LevelUp" then
		Hud.banner(text, "Level up!", C.Gold, 2.5)
		for _, u in d.unlocks or {} do
			Hud.toast("Unlocked " .. u.slot .. ": " .. u.name, C.Accent, 6)
		end
	end
end

local function onFeedback(kind: string, payload: any)
	if kind == "Release" and type(payload) == "table" then
		local color = if payload.quality == "Perfect"
			then C.Perfect
			elseif payload.quality == "Over" then C.Sloppy
			else C.Clean
		local text = string.format(
			"%s RELEASE  ·  power %d%%  ·  spin %d%%",
			string.upper(payload.quality),
			math.floor(payload.power * 100),
			math.floor(payload.spin * 100)
		)
		if payload.blocked then
			text = "HAND BLOCKED — fake, pivot or change your release height"
			color = C.Bad
		elseif payload.offBalance then
			text ..= "  ·  off balance"
		elseif payload.groundThrow then
			text ..= "  ·  from the ground"
		end
		Hud.feedback(text, color, 2.2)
	elseif kind == "DrillHud" then
		Panels.drillHud(payload)
	elseif kind == "Drill" then
		Panels.drillReport(payload)
		controllers.AudioController.play("Highlight")
	elseif kind == "DrillTick" and type(payload) == "table" then
		Hud.feedback(payload.text or "", C.Text, 4)
	elseif kind == "OpenLauncher" then
		Hud.toast("Free launcher: press M > Training to set up and fire launches.", C.Accent, 6)
	end
end

local function onMovementFeedback(fb: any)
	local kind = fb.kind
	if kind == "LandingOffset" then
		local v = fb.value or 0
		Hud.feedback(
			string.format("PRECISION LANDING  %s%d ms", if v >= 0 then "-" else "+", math.floor(math.abs(v) * 1000)),
			C.Perfect,
			1.2
		)
	elseif kind == "LandingEarly" then
		Hud.feedback("TOO EARLY — press Slide just before touchdown", C.Sloppy, 1.3)
	elseif kind == "PlantEarly" then
		Hud.feedback("TOO EARLY — let the plant land (0.1 s), then restart", C.Sloppy, 1.3)
	elseif kind == "PopEarly" then
		Hud.feedback("TOO EARLY — wait until your slide stops", C.Sloppy, 1.3)
	elseif kind == "PopLate" then
		Hud.feedback("MISSED THE POP-UP WINDOW", C.Sloppy, 1.3)
	elseif kind == "Cooldown" then
		Hud.feedback(string.format("COOLDOWN %.1f s", math.max(0, fb.value or 0)), C.Muted, 0.8)
	elseif kind == "Travel" then
		Hud.feedback("TRAVEL — release before you land from a hop", C.Bad, 1.6)
	end
end

local function updateHint()
	local c = player.Character
	local role = if c then c:GetAttribute("UBRole") else nil
	local phase = Net.state():GetAttribute("Phase")
	if controllers.ThrowController.isHolding() then
		Hud.setHint("")
	elseif role == "Training" then
		Hud.setHint("Walk to a terminal and press G to start a drill  ·  M: menu")
	elseif phase == "Intermission" then
		Hud.setHint("Warm-up: grab the disc and throw it around  ·  M: vote / train / settings")
		if not hintedVote then
			hintedVote = true
			Hud.toast("Press M to vote for the next mode and arena, or to train.", C.Accent, 6)
		end
	else
		Hud.setHint("M: menu  ·  B: celebrate after a goal")
	end
end

function UIController.Init(c: any)
	controllers = c
end

function UIController.Start()
	task.spawn(function()
		for _ = 1, 10 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
				StarterGui:SetCore("ResetButtonCallback", false)
			end)
			if ok then
				break
			end
			task.wait(1)
		end
	end)

	local gui = Instance.new("ScreenGui")
	gui.Name = "UBInterface"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	Hud.build(gui, controllers)
	ThrowHud.build(gui, controllers)
	Panels.build(gui, controllers)
	Mobile.build(gui, controllers)
	Menu.build(gui, controllers)

	controllers.InputController.ActionBegan:Connect(function(action)
		if action == "Menu" then
			Menu.toggle()
		end
	end)
	controllers.MovementController.Tech:Connect(function(e)
		Hud.techLabel(e.tech, e.quality, e.info)
	end)
	controllers.MovementController.Feedback:Connect(onMovementFeedback)

	Net.event("Notify").OnClientEvent:Connect(onNotify)
	Net.event("Feedback").OnClientEvent:Connect(onFeedback)
	Net.event("Highlight").OnClientEvent:Connect(function(h)
		if type(h) == "table" then
			Hud.highlight(h.name or "", h.text or "", h.team)
		end
	end)
	Net.event("Combo").OnClientEvent:Connect(function(summary)
		if type(summary) == "table" and summary.converted then
			Hud.feedback(
				string.format(
					"%s  ·  COMBO %d%s",
					string.upper(summary.payoff or "PLAY"),
					summary.score,
					if summary.tier then "  · " .. summary.tier else ""
				),
				C.Gold,
				2.6
			)
		end
	end)
	Net.event("Summary").OnClientEvent:Connect(function(sum)
		if type(sum) == "table" then
			Panels.showSummary(sum)
		end
	end)
	Net.event("Profile").OnClientEvent:Connect(function(p)
		if type(p) ~= "table" then
			return
		end
		Menu.setProfile(p)
		lastLevel = p.level
	end)
	task.spawn(function()
		local ok, p = pcall(function()
			return Net.func("GetProfile"):InvokeServer()
		end)
		if ok and type(p) == "table" then
			Menu.setProfile(p)
			lastLevel = p.level
			if not p.persistent then
				Hud.toast("Progress is not being saved this session (DataStores unavailable).", C.Sloppy, 8)
			end
		end
	end)

	local lastHint = 0
	RunService.RenderStepped:Connect(function(dt)
		Hud.update(dt)
		ThrowHud.update()
		Panels.update()
		Mobile.update()
		local clock = os.clock()
		if clock - lastHint > 0.5 then
			lastHint = clock
			updateHint()
		end
	end)
	local _ = lastLevel
end

return UIController
