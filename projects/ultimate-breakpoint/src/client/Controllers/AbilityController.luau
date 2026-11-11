--!strict
--[[
	AbilityController — your ability (Config/Abilities) on the client.

	  * The Ability key asks the server to fire the ability chosen in
	    Settings (AbilityService checks the FLOW meter).
	  * When the server stamps UBAbilityT on your character, the effect
	    starts: Flash Step blinks the body up to 10 studs (stopping short of
	    walls) and keeps your speed; The Zone, Sky Walk and Overdrive start in
	    the tech core. Each plays an impact frame and a pop.
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
	controllers.AnimeFX.afterimage(c, def.color, 3)
	root.CFrame += dir * dist
end

local function onStamp(c: Model)
	local id = c:GetAttribute("UBAbility")
	local def = Abilities.get(id)
	if not def then
		return
	end
	if c ~= player.Character then
		if def.id == "FlashStep" then
			controllers.AnimeFX.afterimage(c, def.color, 3)
		end
		return
	end
	if def.id == "FlashStep" then
		flashStep(c, def)
	elseif controllers.MovementController.engine() == "Tech" then
		local tech = controllers.MovementController.techState()
		TechCore.startAbility(tech, def.id, def.duration, Abilities.ZoneScale, Abilities.SkyWalkDodges)
	end
	controllers.TechFeedback.play(def.name, "Perfect")
	controllers.AnimeFX.impactFrame(def.color)
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
		elseif aura then
			aura:Destroy()
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
