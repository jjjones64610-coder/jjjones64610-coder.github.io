--!strict
--[[
	AbilityController — your one ability on the client (src/shared/Abilities).

	  * The Ability chord (Config/Input.AbilityChord: Jump + Sprint pressed
	    together) asks the server to fire the ability you picked in the
	    Locker, if it is off cooldown and its own canUse agrees (the reason
	    is shown when it doesn't).
	  * When the server stamps UBAbilityT on your character the module's
	    start() runs on your own movement (TechCore). Throw and catch parts
	    are applied by ThrowController / CatchController through the same
	    framework hooks the server uses.
	  * Every cast is an anime power-up for everyone who sees it: rings of
	    light, an aura flare and a cast pose (PoseController); for you, an
	    impact frame and a camera punch too.
	  * Everyone with an active ability glows in its colour (GameFeel tints
	    their outline) with flames rising off them.
	  * A small bar over the sprint meter: it fills as the cooldown runs
	    down and shows the chord when the ability is ready.

	This file knows nothing about any single ability.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Abilities)
local InputConfig = require(Shared.Config.Input)
local Net = require(Shared.Net)
local Theme = require(script.Parent.Parent.UI.Theme)
local Art = require(Shared.Config.Art)

local AbilityController = {}

local controllers: any
local player = Players.LocalPlayer
local remote: RemoteEvent? = nil
local lastStamp: { [Model]: number } = {}
local bar: Frame? = nil
local fill: Frame? = nil
local label: TextLabel? = nil

local AURA_REFRESH = 0.2

function AbilityController.selected(): Abilities.Def
	local id = controllers.SettingsController.get("Ability")
	return Abilities.get(id) or Abilities.List[Abilities.Default]
end

-- Seconds until your ability is ready, and the cooldown's length.
local function cooldown(): (number, number)
	local c = player.Character
	local ready = c and c:GetAttribute("UBAbilityReadyAt")
	local length = c and c:GetAttribute("UBAbilityCooldown")
	if type(ready) ~= "number" or type(length) ~= "number" or length <= 0 then
		return 0, 1
	end
	return math.max(0, ready - Net.now()), length
end

-- What the ability's canUse is told about you right now.
local function context(): Abilities.Context
	local mc = controllers.MovementController
	return { grounded = mc.isGrounded(), holding = mc.holdingDisc() }
end

-- The anime power-up: a beat of hit-stop on the camera, a ring of light
-- rising off the ground, a flare of aura and the pose (PoseController
-- reads UBAbilityT for the cast pose).
local function castFx(c: Model, def: Abilities.Def, own: boolean)
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	controllers.GameFeel.play("AbilityCast", { pos = root.Position, color = def.color, model = c, own = own })
	controllers.AnimeFX.auraFlare(c, 1.2)
end

local function onStamp(c: Model)
	local def = Abilities.get(c:GetAttribute("UBAbility"))
	if not def then
		return
	end
	local own = c == player.Character
	castFx(c, def, own)
	if not own then
		return
	end
	if def.start then
		def.start(controllers.MovementController.techState(), controllers.InputController.moveVector())
	end
	controllers.TechFeedback.play(def.name, "Perfect")
	controllers.AudioController.play("Ability")
end

-- Every character with an active ability glows in its colour.
local function refreshAuras()
	local t = Net.now()
	local models: { Model } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(models, p.Character)
		end
	end
	local bots = workspace:FindFirstChild("UBBots")
	if bots then
		for _, m in bots:GetChildren() do
			if m:IsA("Model") then
				table.insert(models, m)
			end
		end
	end
	for _, m in models do
		local stamp = m:GetAttribute("UBAbilityT")
		if type(stamp) == "number" and stamp ~= lastStamp[m] then
			local first = lastStamp[m] == nil and t - stamp > 1
			lastStamp[m] = stamp
			if not first then
				onStamp(m)
			end
		end
		local untilT = m:GetAttribute("UBAbilityUntil")
		local def = Abilities.get(m:GetAttribute("UBAbility"))
		local active = def ~= nil and type(untilT) == "number" and t < untilT and def.duration > 0
		-- (the glow itself is GameFeel's outline; here only the flames)
		if active and def then
			-- anime aura flames rising off the body (ForgeGUI texture)
			local root = m:FindFirstChild("HumanoidRootPart")
			local tex = Art.vfx("Aura")
			if root and tex and not root:FindFirstChild("UBAuraFlames") then
				local e = Instance.new("ParticleEmitter")
				e.Name = "UBAuraFlames"
				e.Texture = tex
				e.Color = ColorSequence.new(def.color)
				e.LightEmission = 0.8
				e.Rate = 26
				e.Lifetime = NumberRange.new(0.35, 0.6)
				e.Speed = NumberRange.new(4, 7)
				e.SpreadAngle = Vector2.new(25, 25)
				e.EmissionDirection = Enum.NormalId.Top
				e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.8), NumberSequenceKeypoint.new(1, 0.4) })
				e.Transparency =
					NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
				e.Parent = root
			end
		else
			local root = m:FindFirstChild("HumanoidRootPart")
			local flames = root and root:FindFirstChild("UBAuraFlames")
			if flames then
				flames:Destroy()
			end
		end
	end
	for m in lastStamp do
		if not m.Parent then
			lastStamp[m] = nil
		end
	end
end

local function buildBar()
	local gui = Instance.new("ScreenGui")
	gui.Name = "UBAbility"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")
	local b = Theme.panel({
		Name = "Flow",
		Parent = gui,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -86),
		Size = UDim2.fromOffset(220, 8),
		BackgroundTransparency = 0.4,
	})
	local f = Instance.new("Frame")
	f.Name = "Fill"
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(0, 1)
	f.BackgroundColor3 = Theme.Colors.Accent
	f.Parent = b
	local l = Theme.label("", 13, {
		Name = "Name",
		Parent = gui,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -96),
		Size = UDim2.fromOffset(300, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.Fonts.Heavy,
		RichText = true,
	})
	bar = b
	fill = f
	label = l
end

-- The chord as the player would press it ("SPACE + SHIFT").
local function chordLabel(): string
	local parts = {}
	for _, action in InputConfig.AbilityChord.actions do
		local key = controllers.InputController.keyLabel(action)
		table.insert(parts, if key ~= "" then key else string.upper(action))
	end
	return table.concat(parts, " + ")
end

local function updateBar()
	local b, f, l = bar, fill, label
	if not b or not f or not l then
		return
	end
	local def = AbilityController.selected()
	local left, length = cooldown()
	local k = math.clamp(1 - left / length, 0, 1)
	f.Size = UDim2.fromScale(k, 1)
	f.BackgroundColor3 = def.color
	local ready = left <= 0
	l.Text = if ready
		then string.format("%s  READY", Theme.keyText(chordLabel(), def.name))
		else string.format('<font color="#96A0B4">%s · %.0f s</font>', def.name, math.ceil(left))
	l.TextTransparency = if ready then 0.25 - 0.25 * math.sin(os.clock() * 6) else 0.2
end

function AbilityController.Init(c: any)
	controllers = c
end

function AbilityController.Start()
	task.spawn(function()
		remote = Net.event("Ability")
	end)
	controllers.InputController.ActionBegan:Connect(function(action)
		if action ~= "Ability" or controllers.InputController.menuOpen() then
			return
		end
		local r = remote
		local def = AbilityController.selected()
		if not r or cooldown() > 0 then
			return -- not ready: the chord's own keys already did their thing
		end
		if def.canUse then
			local ok, why = def.canUse(context())
			if not ok then
				controllers.MovementController.Feedback:Fire({ kind = "Context", text = why or "NOT NOW" })
				return
			end
		end
		r:FireServer(def.id)
	end)
	buildBar()
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		updateBar()
		acc += dt
		if acc >= AURA_REFRESH then
			acc = 0
			refreshAuras()
		end
	end)
end

return AbilityController
