--!strict
--[[
	AbilityController — your ability (Config/Abilities) on the client.

	  * The Ability key asks the server to fire the ability chosen in
	    Settings (AbilityService checks the FLOW meter).
	  * When the server stamps UBAbilityT on your character, the effect
	    starts: Flash Step blinks the body up to 18 studs (stopping short of
	    walls) and surges your speed; The Zone, Sky Walk and Overdrive start
	    in the tech core; Magnet Hands and Tempest Throw are read from the
	    attributes by the catch and throw code (both checked on the server).
	    Every cast is an anime power-up: impact frame, camera punch, rings
	    of light, an aura flare and a cast pose (PoseController).
	  * Everyone with an active ability glows in its colour (a Highlight);
	    a Flash Step leaves afterimages for everyone.
	  * A small FLOW bar over the Burst bar, with the ability's name lit when
	    the meter is full. It names your ability, never what to combo.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Config.Abilities)
local TechCore = require(Shared.Movement.TechCore)
local VecMath = require(Shared.Util.VecMath)
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

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

function AbilityController.selected(): Abilities.Def
	local id = controllers.SettingsController.get("Ability")
	return Abilities.get(id) or Abilities.List[Abilities.Order[1]]
end

local function flow(): number
	local c = player.Character
	local v = c and c:GetAttribute("UBFlow")
	return if type(v) == "number" then v else 0
end

local function flashStep(c: Model, def: Abilities.Def)
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local tech = controllers.MovementController.techState()
	local dir = TechCore.flashDirection(tech, controllers.InputController.moveVector())
	if controllers.MovementController.engine() ~= "Tech" then
		local v = VecMath.flat(root.AssemblyLinearVelocity)
		dir = if v.Magnitude > 1 then v.Unit else VecMath.flatUnit(root.CFrame.LookVector)
	end
	rayParams.FilterDescendantsInstances = { c, workspace:FindFirstChild("UBVisuals") :: Instance }
	local dist = Abilities.FlashDistance
	for _, h in { 0, -1.5 } do
		local hit = workspace:Raycast(root.Position + Vector3.new(0, h, 0), dir * (dist + 1.5), rayParams)
		if hit then
			dist = math.min(dist, math.max(0, hit.Distance - 1.5))
		end
	end
	controllers.AnimeFX.afterimage(c, def.color, 5)
	local from = root.Position
	root.CFrame += dir * dist
	controllers.AnimeFX.slash(from:Lerp(root.Position, 0.5), dir, def.color)
	if controllers.MovementController.engine() == "Tech" then
		TechCore.surge(controllers.MovementController.techState(), Abilities.FlashSurge)
	end
end

-- The tech-core numbers each ability starts with.
local function techArgs(id: string): (number?, number?)
	if id == "Zone" then
		return Abilities.ZoneScale, nil
	elseif id == "SkyWalk" then
		return Abilities.SkyWalkGravity, Abilities.SkyWalkDodges
	elseif id == "Overdrive" then
		return Abilities.OverdriveTop, nil
	end
	return nil, nil
end

-- The anime power-up: a beat of hit-stop on the camera, a ring of light
-- rising off the ground, a flare of aura and the pose (PoseController
-- reads UBAbilityT for the cast pose).
local function castFx(c: Model, def: Abilities.Def, own: boolean)
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local pos = root.Position
	controllers.AnimeFX.impactBurst(pos, def.color, if own then 11 else 7)
	controllers.AnimeFX.shockwave(pos - Vector3.new(0, 2.8, 0), def.color, if own then 12 else 8)
	controllers.AnimeFX.auraFlare(c, 1.2)
	task.delay(0.12, function()
		if root.Parent then
			controllers.AnimeFX.shockwave(root.Position - Vector3.new(0, 2.8, 0), Color3.new(1, 1, 1), 6)
		end
	end)
	if own then
		controllers.AnimeFX.impactFrame(def.color)
		controllers.CameraController.kick(0.6)
		controllers.CameraController.shake(0.35, 0.3)
	end
end

local function onStamp(c: Model)
	local id = c:GetAttribute("UBAbility")
	local def = Abilities.get(id)
	if not def then
		return
	end
	if c ~= player.Character then
		if def.id == "FlashStep" then
			controllers.AnimeFX.afterimage(c, def.color, 5)
		end
		castFx(c, def, false)
		return
	end
	castFx(c, def, true)
	if def.id == "FlashStep" then
		flashStep(c, def)
	elseif controllers.MovementController.engine() == "Tech" then
		local tech = controllers.MovementController.techState()
		local scale, dodges = techArgs(def.id)
		TechCore.startAbility(tech, def.id, def.duration, scale, dodges)
	end
	controllers.TechFeedback.play(def.name, "Perfect")
	controllers.AudioController.play("Ability")
	if def.id == "FlashStep" then
		controllers.AudioController.play("Dash")
	end
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
		local active = def ~= nil and type(untilT) == "number" and t < untilT
		local aura = m:FindFirstChild("UBAura") :: Highlight?
		if active and def then
			if not aura then
				local h = Instance.new("Highlight")
				h.Name = "UBAura"
				h.FillTransparency = 0.75
				h.OutlineTransparency = 0
				h.DepthMode = Enum.HighlightDepthMode.Occluded
				h.Parent = m
				aura = h
			end
			local a = aura :: Highlight
			a.FillColor = def.color
			a.OutlineColor = def.color
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
		elseif aura then
			aura:Destroy()
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

local function updateBar()
	local b, f, l = bar, fill, label
	if not b or not f or not l then
		return
	end
	local def = AbilityController.selected()
	local k = math.clamp(flow() / Abilities.MeterMax, 0, 1)
	f.Size = UDim2.fromScale(k, 1)
	f.BackgroundColor3 = def.color
	local ready = k >= 1
	local key = controllers.InputController.keyLabel("Ability")
	l.Text = if ready
		then string.format("%s  %s", Theme.keyText(key, def.name), "READY")
		else string.format('<font color="#96A0B4">FLOW · %s</font>', def.name)
	l.TextTransparency = if ready then 0.5 - 0.5 * math.sin(os.clock() * 8) else 0.2
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
		if r then
			r:FireServer(AbilityController.selected().id)
		end
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
