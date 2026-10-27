--!strict
--[[
	UIController — builds the interface and routes everything to it.

	  Movement feedback (MovementController.Feedback): the sim's ready-made
	  texts ("NEED SPEED", "ONE PER JUMP", "PRECISION LANDING -40 ms", ...)
	  become chips above the crosshair for 0.6 s. A press refused for a
	  cooldown flashes that technique's pip instead (Feedback.tech names it;
	  only techniques without a pip show the cooldown text).
	  Combos: ComboChanged / ChainEnded drive the Hud chain widget and end
	  card. The server's Combo event (a chain converted by a catch, block or
	  interception) shows the x2 card and converts the same chain in the local
	  tracker, so it is never also shown as unconverted.
	  Techniques: optional labels; a Sold Pivot Swing says "release now" and a
	  Break says so.
	  Catching: a claim the server denies, and that is neither claimed again
	  nor turned into a catch shortly after, gets a subtle "NO CATCH" chip.
	  Throws (server Release feedback): text only when it says something —
	  Perfect, over-held, hand-blocked, a High release the server saw as Mid
	  (the hop was not seen in the air), off balance, from the ground.
	  Travel: the server's travel reset is a chip, not a toast.
	  Hint line (bottom left): the bound keys while playing, plus the bench,
	  warm-up and training lines.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local TeamsConfig = require(Shared.Config.Teams)
local ComboEvaluator = require(Shared.Rules.ComboEvaluator)
local SignaturesConfig = require(Shared.Config.Signatures)
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

local DENIED_DELAY = 0.3 -- a denied claim must stay unanswered this long before it is shown ...
local DENIED_GAP = 1.5 -- ... and at most once per this long
local TRAVEL_TEXT = "TRAVEL — RESET TO YOUR PIVOT"

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

local function key(action: string, label: string): string
	return Theme.keyText(controllers.InputController.keyLabel(action), label)
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
	elseif kind == "Travel" then
		Hud.chip(if type(text) == "string" and text ~= "" then string.upper(text) else TRAVEL_TEXT, C.Bad, 1.4)
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

-- Release text only when it matters (Clean releases speak for themselves).
local function onRelease(payload: any)
	if payload.blocked then
		Hud.feedback("HAND BLOCKED — fake, step out or change your release height", C.Bad, 2.2)
		return
	end
	local parts: { string } = {}
	local color = C.Clean
	if payload.quality == "Perfect" then
		table.insert(parts, "PERFECT RELEASE")
		color = C.Perfect
	elseif payload.quality == "Over" then
		table.insert(
			parts,
			string.format("OVER-HELD — let go sooner  ·  spin %d%%", math.floor((tonumber(payload.spin) or 0) * 100))
		)
		color = C.Sloppy
	end
	if payload.heightAsked == "High" and payload.heightUsed ~= "High" and not payload.groundThrow then
		table.insert(parts, "RELEASED MID (HOP NOT SEEN) — release while still in the air")
		color = C.Sloppy
	end
	if payload.groundThrow then
		table.insert(parts, "FROM THE GROUND")
	elseif payload.offBalance then
		table.insert(parts, "OFF BALANCE")
	end
	if #parts > 0 then
		Hud.feedback(table.concat(parts, "  ·  "), color, 2)
	end
end

local function onFeedback(kind: string, payload: any)
	if kind == "Release" and type(payload) == "table" then
		onRelease(payload)
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
	if type(fb) ~= "table" then
		return
	end
	local kind = fb.kind
	local text: string? = if type(fb.text) == "string" and fb.text ~= "" then fb.text else nil
	if kind == "Cooldown" then
		-- the pips show readiness: flash the one that refused instead of printing
		-- it; a technique without a pip (fake, swing) gets its text as a chip
		local tech = fb.tech
		if type(tech) == "string" and Hud.flashPip(tech) then
			return
		end
		if text then
			Hud.chip(text, C.Sloppy)
		end
		return
	elseif kind == "Error" then
		Hud.feedback(text or "MOVEMENT ERROR", C.Bad, 5)
		return
	end
	if not text then
		return
	end
	if kind == "LandingOffset" then
		Hud.chip(text, if string.find(text, "^PRECISION") then C.Perfect else C.Sloppy, 0.8)
	elseif kind == "HopLanded" then
		-- only worth a word when it cost a charge (ThrowController.ChargeLost)
		return
	elseif kind == "Context" then
		Hud.chip(text, C.Text)
	else
		Hud.chip(text, C.Sloppy)
	end
end

local function onTech(e: any)
	Hud.techLabel(e.tech, e.quality, e.info)
	if e.tech == "PivotSwing" and e.quality == "Perfect" then
		Hud.chip("SOLD SWING — RELEASE NOW", C.Perfect, 0.5)
	elseif e.tech == "Break" then
		Hud.chip(if e.quality == "Perfect" then "BREAK  ·  PERFECT" else "BREAK", C.Perfect, 1)
	end
end

-- A denied claim gets a subtle chip, unless it was claimed again (or caught)
-- right after: the server retries are normal and should stay invisible. A
-- claim that became your block or bobble is not "denied" either (the server
-- answers those with accepted = false too).
local lastClaim: { [string]: number } = {}
local lastResult: { [string]: string } = {}
local lastNoCatch = -math.huge
local NOT_A_MISS: { [string]: boolean } = { Catch = true, Block = true, Bobble = true }
local function onDenied(discId: any)
	local at = os.clock()
	task.delay(DENIED_DELAY, function()
		if controllers.ThrowController.isHolding() then
			return
		end
		if type(discId) == "string" then
			if (lastClaim[discId] or -math.huge) > at or NOT_A_MISS[lastResult[discId] or ""] then
				return
			end
		end
		local clock = os.clock()
		if clock - lastNoCatch < DENIED_GAP then
			return
		end
		lastNoCatch = clock
		Hud.chip("NO CATCH", C.Muted, 0.5)
	end)
end

local function movementKeys(): string
	if controllers.InputController.scheme() == "Touch" then
		return ""
	end
	return table.concat({
		key("Cut", "cut"),
		key("Burst", "burst"),
		key("Slide", "slide"),
		key("Dive", "dive"),
		key("Jump", "jump"),
		key("Menu", "menu"),
	}, "  ·  ")
end

local function updateHint()
	local c = player.Character
	local role = if c then c:GetAttribute("UBRole") else nil
	local phase = Net.state():GetAttribute("Phase")
	if controllers.ThrowController.isHolding() then
		Hud.setHint("")
	elseif role == "Training" then
		Hud.setHint("Walk to a terminal and press G to start a drill  ·  " .. key("Menu", "menu"))
	elseif phase == "Intermission" then
		Hud.setHint("Warm-up: grab the disc and throw it around  ·  " .. key("Menu", "vote / train / settings"))
		if not hintedVote then
			hintedVote = true
			Hud.toast("Press M to vote for the next mode and arena, or to train.", C.Accent, 6)
		end
	elseif role == "Bench" then
		Hud.setHint("On the bench: you play next point  ·  " .. key("Menu", "menu"))
	elseif phase == "PointOver" or phase == "MatchOver" then
		Hud.setHint(key("Celebrate", "celebrate") .. "  ·  " .. key("Menu", "menu"))
	else
		Hud.setHint(movementKeys())
	end
end

function UIController.Init(c: any)
	controllers = c
end

function UIController.Start()
	controllers.ThrowController.ChargeLost:Connect(function()
		Hud.chip("CHARGE LOST — RELEASE BEFORE YOU LAND", C.Bad, 1.2)
	end)
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
	local movement = controllers.MovementController
	movement.Tech:Connect(onTech)
	movement.Feedback:Connect(onMovementFeedback)
	movement.ComboChanged:Connect(Hud.comboChanged)
	movement.ChainEnded:Connect(Hud.chainEnded)

	controllers.CatchController.Claimed:Connect(function(discId)
		if type(discId) == "string" then
			lastClaim[discId] = os.clock()
		end
	end)
	controllers.CatchController.Denied:Connect(onDenied)
	Net.event("CatchResult").OnClientEvent:Connect(function(discId, _accepted, result)
		if type(discId) == "string" and type(result) == "string" then
			lastResult[discId] = result
		end
	end)

	Net.event("Notify").OnClientEvent:Connect(onNotify)
	Net.event("Feedback").OnClientEvent:Connect(onFeedback)
	-- signature moves: yours show the moment you land them; the server's
	-- announcement of the same move is skipped (others see its banner)
	local mySignatures: { [string]: number } = {}
	controllers.MovementController.SignatureHit:Connect(function(hit: any)
		mySignatures[hit.name] = os.clock()
		Hud.signature(hit.name, hit.points, hit.tier, nil)
		controllers.AudioController.play("Signature")
	end)
	Net.event("Highlight").OnClientEvent:Connect(function(h)
		if type(h) ~= "table" then
			return
		end
		if h.kind == "Signature" then
			local mine = h.id == player.UserId
			local shownAt = mySignatures[tostring(h.text)]
			if mine and shownAt and os.clock() - shownAt < 4 then
				return
			end
			local def = nil
			for _, d in SignaturesConfig.List do
				if d.name == h.text then
					def = d
				end
			end
			Hud.signature(
				tostring(h.text or ""),
				tonumber(h.score) or 0,
				if def then def.tier else 1,
				if mine then nil else h.name
			)
			controllers.AudioController.play("Signature")
			return
		end
		Hud.highlight(h.name or "", h.text or "", h.team)
	end)
	Net.event("Combo").OnClientEvent:Connect(function(summary)
		if type(summary) == "table" and summary.converted then
			-- the same chain in the local tracker is converted too (no
			-- "unconverted" end card for it later)
			ComboEvaluator.convert(
				controllers.MovementController.combo(),
				Net.now(),
				tostring(summary.payoff or "Play")
			)
			Hud.comboConverted(summary)
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
