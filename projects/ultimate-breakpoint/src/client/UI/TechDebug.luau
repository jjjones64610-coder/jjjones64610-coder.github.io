--!strict
--[[
	TechDebug — the tech debug HUD (docs/tech-spec.md build step 2). Only
	numbers you need to tune, top right, monospace:

	  SPEED  21.4 / 22   fall 0.0      flat speed / current top speed
	  STATE  Grounded  1.24 s          + DRIFT while a turn is rate-limited
	  BURST  [##########] 100          the meter (spent from step 3)
	  LAST   Cut: 34 ms early  CLEAN   the last timed press and its grade
	  BUFFER Jump 42 ms                presses still waiting in the buffer
	  CORE   120 Hz · 2 steps · 60 fps

	Shown on the tech engine when the TechDebug setting is on, and always in
	Studio. It reports what happened, never what to press next.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TechCore = require(Shared.Movement.TechCore)
local TechConfig = require(Shared.Config.Tech)
local Theme = require(script.Parent.Theme)

local TechDebug = {}

local controllers: any
local panel: Frame? = nil
local text: TextLabel? = nil
local fps = 60
local BAR = 10
local GRADE_COLOR = { Perfect = "#FFD750", Clean = "#D2F0FF", Miss = "#FF5A64" }

local function visible(): boolean
	if controllers.MovementController.engine() ~= "Tech" then
		return false
	end
	return RunService:IsStudio() or controllers.SettingsController.get("TechDebug") == true
end

local function bar(value: number): string
	local n = math.clamp(math.floor(value / 100 * BAR + 0.5), 0, BAR)
	return "[" .. string.rep("#", n) .. string.rep(".", BAR - n) .. "]"
end

local function render(): string
	local s: TechCore.State = controllers.MovementController.techState()
	local lines = {}
	table.insert(
		lines,
		string.format(
			"SPEED  %5.1f / %d   fall %5.1f",
			TechCore.flatSpeed(s),
			math.floor(s.topSpeed + 0.5),
			math.max(0, -s.vel.Y)
		)
	)
	local st = string.format("STATE  %s  %.2f s", s.state, TechCore.timeInState(s))
	if s.drifting then
		st ..= '  <font color="#FF9650">DRIFT</font>'
	end
	table.insert(lines, st)
	table.insert(lines, string.format("BURST  %s %3d", bar(s.burst), math.floor(s.burst + 0.5)))
	local timing = s.lastTiming
	if timing then
		table.insert(
			lines,
			string.format(
				'LAST   %s  <font color="%s">%s</font>',
				TechCore.describeTiming(timing),
				GRADE_COLOR[timing.quality] or "#FFFFFF",
				string.upper(timing.quality)
			)
		)
	else
		table.insert(lines, "LAST   -")
	end
	local clock = os.clock()
	local buffered = {}
	for action, at in s.buffer do
		if TechCore.buffered(s, action, clock) then
			table.insert(buffered, string.format("%s %d ms", action, math.floor((clock - at) * 1000)))
		end
	end
	table.sort(buffered)
	table.insert(lines, "BUFFER " .. (if #buffered > 0 then table.concat(buffered, "  ") else "-"))
	table.insert(
		lines,
		string.format(
			"CORE   %d Hz · %d steps · %d fps",
			TechConfig.PHYSICS_RATE,
			s.frame.steps,
			math.floor(fps + 0.5)
		)
	)
	return table.concat(lines, "\n")
end

function TechDebug.build(parent: ScreenGui, c: any)
	controllers = c
	local p = Theme.panel({
		Name = "TechDebug",
		Parent = parent,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 72),
		Size = UDim2.fromOffset(330, 112),
		BackgroundTransparency = 0.35,
		Visible = false,
	})
	local t = Theme.label("", 13, {
		Name = "Text",
		Parent = p,
		Position = UDim2.fromOffset(10, 6),
		Size = UDim2.new(1, -20, 1, -12),
		Font = Enum.Font.Code,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		RichText = true,
	})
	panel = p
	text = t
	RunService.RenderStepped:Connect(function(dt)
		if dt > 0 then
			fps += (1 / dt - fps) * 0.1
		end
		local show = visible()
		p.Visible = show
		if show then
			t.Text = render()
		end
	end)
end

-- Whether the HUD is showing (tests / other UI).
function TechDebug.isShown(): boolean
	local p = panel
	return p ~= nil and p.Visible and text ~= nil
end

return TechDebug
