--!strict
-- Panels — end-of-match summary (sized for a full 7v7 plus subs: 14 rows show
-- without scrolling; bots and subs are tagged, ranked / void / PvP noted),
-- drill HUD and drill reports, nameplates (readable to 360 studs, the length
-- of the Normal field).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Actors = require(Shared.Actors)
local ProgressionConfig = require(Shared.Config.Progression)
local TeamsConfig = require(Shared.Config.Teams)
local Theme = require(script.Parent.Theme)

local make = Theme.make
local C = Theme.Colors

local Panels = {}

local controllers: any
local player = Players.LocalPlayer
local refs: { [string]: any } = {}

local BANNERS: { [string]: Color3 } = {}
for _, b in ProgressionConfig.Banners do
	BANNERS[b.id] = b.color
end

local function now(): number
	return Net.now()
end

---------------------------------------------------------------------------
-- match summary
---------------------------------------------------------------------------

function Panels.showSummary(sum: any)
	local old = refs.summary
	if old then
		old:Destroy()
	end
	local panel = Theme.panel({
		Name = "Summary",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(760, 486),
		Parent = refs.root,
	})
	refs.summary = panel
	local winnerName = if sum.winner == "A"
		then TeamsConfig.A.Name
		elseif sum.winner == "B" then TeamsConfig.B.Name
		else "DRAW"
	Theme.label(winnerName .. " WIN", 34, {
		Parent = panel,
		Position = UDim2.fromOffset(20, 12),
		Size = UDim2.new(1, -40, 0, 40),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.Fonts.Heavy,
		TextColor3 = Theme.teamColor(sum.winner),
	})
	local tag = if sum.ranked
		then "  ·  RANKED"
		elseif sum.rankedVoid then "  ·  RANKED (VOID: a player left)"
		elseif sum.pvp then "  ·  PvP"
		else ""
	Theme.label(string.format("%d  -  %d   ·   %s%s", sum.score.A, sum.score.B, sum.mode or "", tag), 16, {
		Parent = panel,
		Position = UDim2.fromOffset(20, 54),
		Size = UDim2.new(1, -40, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Muted,
	})
	local list = make("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(20, 86),
		Size = UDim2.new(1, -40, 1, -130),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 4,
		Parent = panel,
		Theme.list(3),
	})
	Theme.label("PLAYER                          G    A    BLK  CAT  CMP  TO   HL", 12, {
		Parent = list,
		LayoutOrder = 0,
		TextColor3 = C.Muted,
		Font = Enum.Font.Code,
	})
	table.sort(sum.rows, function(a, b)
		if a.team ~= b.team then
			return a.team < b.team
		end
		return (a.goals + a.assists) > (b.goals + b.assists)
	end)
	for i, r in sum.rows do
		local suffix = if r.bot then " (bot)" elseif r.bench then " (sub)" else ""
		local name = string.sub(string.sub(tostring(r.name), 1, 30 - #suffix) .. suffix .. string.rep(" ", 30), 1, 30)
		local mvp = if r.id == sum.mvp then " MVP" else ""
		local change = sum.ratingChanges and sum.ratingChanges[tostring(r.id)]
		local rating = if change then string.format("  %d (%+d)", change.new, change.new - change.old) else ""
		Theme.label(
			string.format(
				"%s  %-4d %-4d %-4d %-4d %-4d %-4d %-3d%s%s",
				name,
				r.goals,
				r.assists,
				r.blocks,
				r.catches,
				r.completions,
				r.turnovers,
				r.highlights,
				mvp,
				rating
			),
			12,
			{
				Parent = list,
				LayoutOrder = i,
				Size = UDim2.new(1, -6, 0, 18),
				Font = Enum.Font.Code,
				TextColor3 = if r.id == player.UserId then C.Gold else Theme.teamColor(r.team),
			}
		)
	end
	Theme.label("Next match starts shortly · press M to vote", 13, {
		Parent = panel,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -12),
		Size = UDim2.new(1, -40, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Muted,
	})
	task.delay(12, function()
		if refs.summary == panel then
			panel:Destroy()
			refs.summary = nil
		end
	end)
end

---------------------------------------------------------------------------
-- drills
---------------------------------------------------------------------------

function Panels.drillHud(payload: any)
	local hud = refs.drillHud :: Frame
	if payload.clear then
		hud.Visible = false
		refs.drillTimer = nil
		return
	end
	hud.Visible = true
	refs.drillTitle.Text = payload.title or ""
	refs.drillText.Text = payload.text or ""
	refs.drillProgress.Size = UDim2.fromScale(math.clamp(payload.progress or 0, 0, 1), 1)
	refs.drillTimer = payload.timerStart
	local lines = 1
	for _ in string.gmatch(payload.text or "", "\n") do
		lines += 1
	end
	hud.Size = UDim2.fromOffset(420, 70 + lines * 18)
end

function Panels.drillReport(payload: any)
	local old = refs.report
	if old then
		old:Destroy()
	end
	local lines: { string } = payload.lines or {}
	local panel = Theme.panel({
		Name = "DrillReport",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 190),
		Size = UDim2.fromOffset(560, 70 + #lines * 22),
		Parent = refs.root,
	})
	refs.report = panel
	Theme.label(payload.title or "DRILL", 22, {
		Parent = panel,
		Position = UDim2.fromOffset(16, 10),
		Size = UDim2.new(1, -32, 0, 28),
		Font = Theme.Fonts.Heavy,
		TextColor3 = if payload.pb then C.Gold else C.Text,
	})
	for i, line in lines do
		Theme.label(line, 15, {
			Parent = panel,
			Position = UDim2.fromOffset(16, 40 + (i - 1) * 22),
			Size = UDim2.new(1, -32, 0, 20),
			TextWrapped = true,
			TextColor3 = if string.find(line, "BEST") then C.Gold else C.Text,
		})
	end
	task.delay(10, function()
		if refs.report == panel then
			panel:Destroy()
			refs.report = nil
		end
	end)
end

---------------------------------------------------------------------------
-- nameplates
---------------------------------------------------------------------------

local plates: { [Model]: BillboardGui } = {}

local function plateFor(model: Model): BillboardGui?
	local existing = plates[model]
	if existing and existing.Parent then
		return existing
	end
	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then
		return nil
	end
	local gui = make("BillboardGui", {
		Name = "UBPlate",
		Size = UDim2.fromOffset(180, 54),
		StudsOffset = Vector3.new(0, 2.6, 0),
		AlwaysOnTop = false,
		MaxDistance = 360,
		LightInfluence = 0,
		Adornee = head,
		Parent = refs.root,
	}) :: BillboardGui
	Theme.label("", 15, {
		Name = "Name",
		Parent = gui,
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.fromOffset(0, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.Fonts.Heavy,
		TextStrokeTransparency = 0.4,
	})
	Theme.label("", 11, {
		Name = "Title",
		Parent = gui,
		Size = UDim2.new(1, 0, 0, 14),
		Position = UDim2.fromOffset(0, 36),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Muted,
		TextStrokeTransparency = 0.6,
	})
	Theme.label("", 18, {
		Name = "Stall",
		Parent = gui,
		Size = UDim2.new(1, 0, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.Fonts.Heavy,
		TextColor3 = C.Gold,
		TextStrokeTransparency = 0.3,
	})
	plates[model] = gui
	return gui
end

local lastPlates = 0
function Panels.updateNameplates()
	local clock = os.clock()
	if clock - lastPlates < 0.2 then
		return
	end
	lastPlates = clock
	local state = Net.state()
	local holder = state:GetAttribute("HolderId")
	local stall = state:GetAttribute("Stall") or 0
	local live = state:GetAttribute("Phase") == "Live"
	local seen: { [Model]: boolean } = {}
	for _, model in Actors.characters() do
		if model ~= player.Character then
			seen[model] = true
			local gui = plateFor(model)
			if gui then
				local team = model:GetAttribute("UBTeam")
				local nameLabel = gui:FindFirstChild("Name") :: TextLabel
				local titleLabel = gui:FindFirstChild("Title") :: TextLabel
				local stallLabel = gui:FindFirstChild("Stall") :: TextLabel
				nameLabel.Text = tostring(model:GetAttribute("UBName") or model.Name)
				nameLabel.TextColor3 = Theme.teamColor(if type(team) == "string" then team else nil)
				local title = model:GetAttribute("UBTitle")
				local level = model:GetAttribute("UBLevel")
				titleLabel.Text = string.format(
					"%s%s",
					if type(title) == "string" then title else "",
					if type(level) == "number" then ("  ·  Lv " .. level) else ""
				)
				local banner = model:GetAttribute("UBBanner")
				titleLabel.TextColor3 = if type(banner) == "string" and BANNERS[banner]
					then BANNERS[banner]:Lerp(Color3.new(1, 1, 1), 0.5)
					else C.Muted
				local id = model:GetAttribute("UBId")
				stallLabel.Text = if live and id == holder then ("STALL " .. tostring(stall)) else ""
			end
		end
	end
	for model, gui in plates do
		if not seen[model] then
			gui:Destroy()
			plates[model] = nil
		end
	end
end

function Panels.update()
	local timer = refs.drillTimer
	if type(timer) == "number" then
		refs.drillClock.Text = string.format("%.2f s", now() - timer)
	else
		refs.drillClock.Text = ""
	end
	Panels.updateNameplates()
end

function Panels.build(parent: ScreenGui, c: any)
	controllers = c
	refs.root = parent
	local hud = Theme.panel({
		Name = "DrillHud",
		Position = UDim2.fromOffset(16, 66),
		Size = UDim2.fromOffset(420, 90),
		Parent = parent,
	})
	hud.Visible = false
	refs.drillHud = hud
	refs.drillTitle = Theme.label("", 18, {
		Parent = hud,
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -120, 0, 22),
		Font = Theme.Fonts.Heavy,
		TextColor3 = C.Accent,
	})
	refs.drillClock = Theme.label("", 18, {
		Parent = hud,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 8),
		Size = UDim2.fromOffset(100, 22),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.Gold,
		Font = Theme.Fonts.Heavy,
	})
	refs.drillText = Theme.label("", 14, {
		Parent = hud,
		Position = UDim2.fromOffset(14, 34),
		Size = UDim2.new(1, -28, 1, -50),
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = Theme.Fonts.Medium,
	})
	local bar = make("Frame", {
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -8),
		Size = UDim2.new(1, -28, 0, 5),
		Parent = hud,
		Theme.corner(3),
	})
	refs.drillProgress = make("Frame", {
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
		Parent = bar,
		Theme.corner(3),
	})
	local _ = controllers
end

return Panels
