--!strict
-- ThrowHud — the thrower's panel: type, bank, release height, the power
-- meter with its Perfect band (and the Lead assist's ideal-power mark).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local Theme = require(script.Parent.Theme)

local make = Theme.make
local C = Theme.Colors

local ThrowHud = {}

local controllers: any
local refs: { [string]: any } = {}

function ThrowHud.build(parent: ScreenGui, c: any)
	controllers = c
	local panel = Theme.panel({
		Name = "ThrowHud",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -18),
		Size = UDim2.fromOffset(300, 196),
		Parent = parent,
	})
	panel.Visible = false
	refs.panel = panel

	refs.type = Theme.label("BACKHAND", 26, {
		Parent = panel,
		Position = UDim2.fromOffset(14, 10),
		Size = UDim2.fromOffset(220, 30),
		Font = Theme.Fonts.Heavy,
	})
	refs.desc = Theme.label("", 12, {
		Parent = panel,
		Position = UDim2.fromOffset(14, 40),
		Size = UDim2.fromOffset(220, 30),
		TextColor3 = C.Muted,
		TextWrapped = true,
		Font = Theme.Fonts.Medium,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	local types = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 74),
		Size = UDim2.fromOffset(230, 22),
		Parent = panel,
		Theme.list(4, true),
	})
	refs.typeChips = {}
	for i, id in DiscConfig.TypeOrder do
		local info = (DiscConfig.Types :: any)[id]
		local chip = make("TextLabel", {
			BackgroundColor3 = C.PanelLight,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(42, 22),
			Text = i .. " " .. info.Short,
			TextSize = 11,
			Font = Theme.Fonts.Bold,
			TextColor3 = C.Muted,
			LayoutOrder = i,
			Parent = types,
			Theme.corner(6),
		})
		refs.typeChips[id] = chip
	end

	-- bank indicator: a tilting disc
	local bankHolder = make("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 106),
		Size = UDim2.fromOffset(120, 40),
		Parent = panel,
	})
	refs.bankDisc = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(30, 20),
		Size = UDim2.fromOffset(48, 8),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = bankHolder,
		Theme.corner(4),
	})
	refs.bankText = Theme.label("FLAT", 14, {
		Parent = bankHolder,
		Position = UDim2.fromOffset(62, 11),
		Size = UDim2.fromOffset(70, 18),
	})
	refs.height = Theme.label("MID", 14, {
		Parent = panel,
		Position = UDim2.fromOffset(150, 117),
		Size = UDim2.fromOffset(100, 18),
		TextColor3 = C.Accent,
	})
	refs.lead = Theme.label("", 13, {
		Parent = panel,
		Position = UDim2.fromOffset(14, 148),
		Size = UDim2.fromOffset(240, 16),
		TextColor3 = C.Good,
	})
	refs.keys = Theme.label("", 11, {
		Parent = panel,
		Position = UDim2.fromOffset(14, 168),
		Size = UDim2.fromOffset(240, 22),
		TextColor3 = C.Muted,
		TextWrapped = true,
		Font = Theme.Fonts.Medium,
	})

	-- power meter (vertical, right edge). Full = 100%; the gold band is the
	-- Perfect window; red above it is overcharge.
	local meter = make("Frame", {
		Name = "Meter",
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
		Position = UDim2.new(1, -40, 0, 14),
		Size = UDim2.fromOffset(22, 168),
		Parent = panel,
		Theme.corner(6),
	})
	local scale = 1.4 -- meter shows up to 140% of the charge time
	local fullY = 1 - 1 / scale
	local perfectH = (DiscConfig.Throw.PerfectWindow / DiscConfig.Throw.ChargeTime) / scale
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
	refs.scale = scale
end

function ThrowHud.update()
	local h = controllers.ThrowController.hud()
	local panel = refs.panel :: Frame
	panel.Visible = h.holding
	if not h.holding then
		return
	end
	local info = (DiscConfig.Types :: any)[h.throwType]
	refs.type.Text = string.upper(info.Display)
	refs.desc.Text = info.Description
	for id, chip in refs.typeChips do
		local selected = id == h.throwType
		chip.BackgroundColor3 = if selected then C.Accent else C.PanelLight
		chip.TextColor3 = if selected then Color3.new(0, 0, 0) else C.Muted
	end
	local bankDeg = h.bank / h.bankSteps * DiscConfig.Throw.BankRange
	refs.bankDisc.Rotation = bankDeg
	refs.bankText.Text = if h.bank == 0 then "FLAT" elseif h.bank > 0 then ("RIGHT " .. h.bank) else ("LEFT " .. -h.bank)
	refs.height.Text = h.height .. " RELEASE"
	refs.lead.Text = if h.leadLock then ("LEAD: " .. (h.leadName or "aim at a teammate")) else ""
	local scheme = controllers.InputController.scheme()
	refs.keys.Text = if scheme == "Gamepad"
		then "RT throw · LT fake · D-pad bank/type · B low · A hop · R3 lead"
		elseif scheme == "Touch" then "Hold THROW · FAKE · bank and type buttons"
		else "Hold LMB · RMB fake · Q/E bank · 1-5 type · Ctrl low · Space hop · R lead"
	local frac = math.clamp(h.charge / refs.scale, 0, 1)
	refs.fill.Size = UDim2.fromScale(1, frac)
	refs.fill.BackgroundColor3 = if h.phase == "Perfect"
		then C.Perfect
		elseif h.phase == "Over" then C.Bad
		else Color3.new(1, 1, 1)
	if h.idealPower then
		refs.ideal.Visible = true
		refs.ideal.Position = UDim2.new(0, -4, 1 - h.idealPower / refs.scale, 0)
	else
		refs.ideal.Visible = false
	end
end

return ThrowHud
