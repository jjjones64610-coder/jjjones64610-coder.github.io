--!strict
--[[
	TechDrills — one drill per tech (docs/tech-spec.md build step 9), picked
	in Menu → Training → TECH DRILLS. A drill asks for Goal Perfect reps of
	one tech; every attempt shows on the tech debug HUD's timing bar (always
	on in Training), and this panel counts Perfect / Clean / missed reps
	until the goal is met. Client-only practice: nothing is scored.

	It names the tech you chose to practise and how to do it, nothing about
	what chains off what.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(script.Parent.Parent.UI.Theme)
local MovementConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.Movement)

local TechDrills = {}

export type Drill = { tech: string, how: string }

-- In the order a player learns them.
TechDrills.List = {
	{ tech = "Cut", how = "Run, snap the stick 45°+ away and press Cut in the same motion." },
	{ tech = "PlantStop", how = "Running, let go of the stick, press Cut, then go at once." },
	{ tech = "BurstKick", how = "Tap Burst (under 120 ms)." },
	{ tech = "LandingSlide", how = "Jump, and start a slide right as you land." },
	{ tech = "SlideHop", how = "Slide, then Jump 0.15–0.30 s into it." },
	{ tech = "Wavedash", how = "Short hop, then an air dodge with a direction just before landing." },
	{ tech = "ZapDash", how = "Wavedash, then Cut right as it lands." },
	{ tech = "ReverseSnap", how = "Jump, air dodge backward, Cut 80–110 ms into it." },
	{ tech = "BurstDive", how = "Standing: tap Jump, dodge forward-diagonal at once, Cut 70–100 ms in." },
	{ tech = "Stall", how = "Air dodge, then Dive within 30 ms." },
	{ tech = "WallKick", how = "In the air, Jump the moment you touch a wall." },
	{ tech = "TechRoll", how = "Lay out (E), then Jump the moment you hit the ground." },
	{ tech = "Sky", how = "Standing, hold Jump and release at 0.35–0.40 s." },
	{ tech = "PerfectCatch", how = "Press Catch as the ring closes on the disc." },
	{ tech = "FlipReset", how = "Fall onto a disc in flight with your feet." },
	{ tech = "Pinch", how = "Release a throw as your feet touch down." },
} :: { Drill }

TechDrills.Goal = 3 -- Perfect reps

local controllers: any
local player = Players.LocalPlayer
local active: Drill? = nil
local perfect, clean, missed = 0, 0, 0
local panel: Frame? = nil
local label: TextLabel? = nil

local function nameOf(tech: string): string
	return (MovementConfig.TechNames :: any)[tech] or tech
end

local function refresh()
	local p, l = panel, label
	if not p or not l then
		return
	end
	local d = active
	p.Visible = d ~= nil
	if not d then
		return
	end
	l.Text = string.format(
		'<b>DRILL · %s</b>\n%s\n<font color="#FFD750">PERFECT %d/%d</font>   CLEAN %d   MISSED %d',
		string.upper(nameOf(d.tech)),
		d.how,
		perfect,
		TechDrills.Goal,
		clean,
		missed
	)
end

function TechDrills.start(tech: string)
	for _, d in TechDrills.List do
		if d.tech == tech then
			active = d
			perfect, clean, missed = 0, 0, 0
			refresh()
			return
		end
	end
end

function TechDrills.stop()
	active = nil
	refresh()
end

function TechDrills.current(): string?
	local d = active
	return if d then d.tech else nil
end

local function onTech(e: any)
	local d = active
	if not d or e.tech ~= d.tech then
		return
	end
	if e.quality == "Perfect" then
		perfect += 1
	elseif e.quality == "Miss" then
		missed += 1
	else
		clean += 1
	end
	refresh()
	if perfect >= TechDrills.Goal then
		controllers.TechFeedback.play(nameOf(d.tech) .. " drill done", "Perfect")
		controllers.AudioController.play("Highlight")
		active = nil
		task.delay(1.5, refresh)
	end
end

function TechDrills.Init(c: any)
	controllers = c
end

function TechDrills.Start()
	local gui = Instance.new("ScreenGui")
	gui.Name = "UBTechDrill"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")
	local p = Theme.panel({
		Name = "Drill",
		Parent = gui,
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, 12, 0, 150),
		Size = UDim2.fromOffset(340, 78),
		Visible = false,
	})
	label = Theme.label("", 13, {
		Parent = p,
		Position = UDim2.fromOffset(10, 6),
		Size = UDim2.new(1, -20, 1, -12),
		TextWrapped = true,
		RichText = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	panel = p
	-- every tech the core reports, misses included (the Miss events never
	-- reach the Tech signal, so the core's timing readout feeds them)
	controllers.MovementController.Tech:Connect(onTech)
	controllers.TechFeedback.Played:Connect(function(name: string, quality: string)
		local d = active
		if d and quality == "Miss" and string.find(string.lower(name), string.lower(nameOf(d.tech)), 1, true) then
			onTech({ tech = d.tech, quality = "Miss" })
		end
	end)
	-- leaving the Training hall ends a drill
	task.spawn(function()
		while true do
			task.wait(1)
			local c = player.Character
			if active and c and c:GetAttribute("UBRole") ~= "Training" then
				TechDrills.stop()
			end
		end
	end)
end

return TechDrills
