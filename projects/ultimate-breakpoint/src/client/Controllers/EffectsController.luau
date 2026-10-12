--!strict
--[[
	EffectsController — feedback you can read at a glance.

	Every technique has its own colour and shape (Theme.TechColors) so
	experienced players recognise what an opponent just did; nothing hides the
	disc or the players. Also: catch / block / bobble bursts, goal confetti,
	crowd idle and cheering, wind flags, the moving training target, stadium
	scoreboards, cosmetic movement trails and end-zone glow.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Actors = require(Shared.Actors)
local ProgressionConfig = require(Shared.Config.Progression)
local TeamsConfig = require(Shared.Config.Teams)
local Theme = require(script.Parent.Parent.UI.Theme)

local EffectsController = {}

local controllers: any
local player = Players.LocalPlayer
local fx: Folder

local SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

local function now(): number
	return Net.now()
end

local function anchorAt(pos: Vector3): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.CFrame = CFrame.new(pos)
	p.Parent = fx
	return p
end

function EffectsController.burst(
	pos: Vector3,
	color: Color3,
	count: number,
	speed: number,
	texture: string?,
	gravity: number?
)
	local holder = anchorAt(pos)
	local e = Instance.new("ParticleEmitter")
	e.Texture = texture or SPARK
	e.Color = ColorSequence.new(color)
	e.LightEmission = 0.7
	e.Lifetime = NumberRange.new(0.25, 0.6)
	e.Speed = NumberRange.new(speed * 0.5, speed)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	e.Acceleration = Vector3.new(0, -(gravity or 0), 0)
	e.Rate = 0
	e.Parent = holder
	e:Emit(count)
	task.delay(1.5, function()
		holder:Destroy()
	end)
end

function EffectsController.dust(pos: Vector3, count: number)
	local holder = anchorAt(pos)
	local e = Instance.new("ParticleEmitter")
	e.Texture = SMOKE
	e.Color = ColorSequence.new(Color3.fromRGB(200, 190, 170))
	e.Lifetime = NumberRange.new(0.4, 0.8)
	e.Speed = NumberRange.new(3, 7)
	e.SpreadAngle = Vector2.new(70, 70)
	e.EmissionDirection = Enum.NormalId.Top
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 2.4) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	e.Rate = 0
	e.Parent = holder
	e:Emit(count)
	task.delay(1.5, function()
		holder:Destroy()
	end)
end

function EffectsController.ring(pos: Vector3, color: Color3, radius: number, duration: number, vertical: Vector3?)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = 0.2
	p.Size = Vector3.new(0.12, 1, 1)
	local axis = vertical or Vector3.new(0, 1, 0)
	local ref = if math.abs(axis.Y) < 0.9 then Vector3.new(0, 1, 0) else Vector3.new(1, 0, 0)
	p.CFrame = CFrame.fromMatrix(pos, axis.Unit, axis.Unit:Cross(ref).Unit)
	p.Parent = fx
	local tween = TweenService:Create(p, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.05, radius * 2, radius * 2),
		Transparency = 1,
	})
	tween:Play()
	task.delay(duration + 0.1, function()
		p:Destroy()
	end)
end

local function skid(pos: Vector3, dir: Vector3)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Color = Color3.fromRGB(40, 32, 26)
	p.Transparency = 0.45
	p.Size = Vector3.new(0.9, 0.04, 3.2)
	p.CFrame = CFrame.lookAt(pos, pos + dir) + Vector3.new(0, 0.06, 0)
	p.Parent = fx
	TweenService:Create(p, TweenInfo.new(1.4), { Transparency = 1 }):Play()
	task.delay(1.5, function()
		p:Destroy()
	end)
end

-- short coloured streak on a character's root (per-technique colour)
local function streak(model: Model, color: Color3, duration: number)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local trail = root:FindFirstChild("UBTechTrail") :: Trail?
	if not trail then
		local a0 = Instance.new("Attachment")
		a0.Name = "UBTechA0"
		a0.Position = Vector3.new(0, 0.9, 0)
		a0.Parent = root
		local a1 = Instance.new("Attachment")
		a1.Name = "UBTechA1"
		a1.Position = Vector3.new(0, -1.4, 0)
		a1.Parent = root
		local t = Instance.new("Trail")
		t.Name = "UBTechTrail"
		t.Attachment0 = a0
		t.Attachment1 = a1
		t.Lifetime = 0.22
		t.LightEmission = 0.8
		t.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		t.Enabled = false
		t.Parent = root
		trail = t
	end
	local tr = trail :: Trail
	tr.Color = ColorSequence.new(color)
	tr.Enabled = true
	local token = os.clock()
	tr:SetAttribute("Token", token)
	task.delay(duration, function()
		if tr.Parent and tr:GetAttribute("Token") == token then
			tr.Enabled = false
		end
	end)
end

-- Visual for a technique performed by `model` (local or remote).
function EffectsController.tech(model: Model, tech: string, quality: string, dir: Vector3)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local color = (Theme.TechColors :: any)[tech] or Color3.new(1, 1, 1)
	local feet = root.Position - Vector3.new(0, 2.9, 0)
	local isLocal = model == player.Character
	local perfect = quality == "Perfect"
	if tech == "SnapCut" or tech == "SlideCut" then
		EffectsController.dust(feet, 8)
		streak(model, color, 0.25)
		if perfect then
			EffectsController.ring(feet + Vector3.new(0, 0.1, 0), color, 3, 0.25)
		end
	elseif tech == "MomentumCancel" then
		EffectsController.dust(feet, 14)
		skid(feet, dir)
	elseif tech == "BurstStep" then
		EffectsController.ring(feet + Vector3.new(0, 0.1, 0), color, 4.5, 0.3)
		streak(model, color, 0.35)
		if isLocal then
			controllers.CameraController.kick(5)
		end
	elseif tech == "Slide" then
		EffectsController.dust(feet, 16)
	elseif tech == "Dive" then
		streak(model, color, 0.45)
	elseif tech == "AirRedirect" then
		EffectsController.ring(root.Position, color, 3.2, 0.3, dir)
	elseif tech == "PrecisionLanding" then
		EffectsController.ring(feet + Vector3.new(0, 0.1, 0), if perfect then Theme.Colors.Perfect else color, 5, 0.35)
		EffectsController.dust(feet, 6)
	elseif tech == "WallRebound" then
		EffectsController.burst(root.Position - dir * 1.5, color, 16, 14)
	elseif tech == "RecoveryChain" then
		EffectsController.burst(feet + Vector3.new(0, 1, 0), color, 10, 8)
	end
	-- (FakeCommit / "Lean" deliberately has no visual: a fake must look real)
	if isLocal then
		if tech == "BurstStep" or tech == "Dive" then
			controllers.AudioController.play("Burst", 0.1)
		elseif tech ~= "Jump" and tech ~= "FakeCommit" then
			controllers.AudioController.play(if perfect then "TechPerfect" else "Tech", 0.15)
		end
	end
end

---------------------------------------------------------------------------
-- remote technique watcher
---------------------------------------------------------------------------

local watched: { [Model]: RBXScriptConnection } = {}

local function watch(model: Model)
	if watched[model] or model == player.Character then
		return
	end
	watched[model] = model:GetAttributeChangedSignal("TechT"):Connect(function()
		local tech = model:GetAttribute("Tech")
		local q = model:GetAttribute("TechQ")
		local dir = model:GetAttribute("TechDir")
		if type(tech) == "string" and tech ~= "Lean" then
			EffectsController.tech(
				model,
				tech,
				if type(q) == "string" then q else "Clean",
				if typeof(dir) == "Vector3" then dir else Vector3.zero
			)
		end
	end)
end

---------------------------------------------------------------------------
-- crowd, flags, mover, trails, scoreboards
---------------------------------------------------------------------------

type Fan = { model: Model, parts: { BasePart }, base: { CFrame }, phase: number }
local fans: { Fan } = {}
local cheerUntil = 0
local flags: { { part: BasePart, base: CFrame, strength: number } } = {}

local function collectFans()
	fans = {}
	for _, m in CollectionService:GetTagged("UBCrowd") do
		if m:IsA("Model") then
			local parts: { BasePart } = {}
			local base: { CFrame } = {}
			for _, p in m:GetChildren() do
				if p:IsA("BasePart") then
					table.insert(parts, p)
					table.insert(base, p.CFrame)
				end
			end
			local ph = m:GetAttribute("Phase")
			table.insert(
				fans,
				{ model = m, parts = parts, base = base, phase = if type(ph) == "number" then ph else 0 }
			)
		end
	end
	flags = {}
	for _, f in CollectionService:GetTagged("UBFlag") do
		if f:IsA("BasePart") then
			local s = f:GetAttribute("Strength")
			table.insert(flags, { part = f, base = f.CFrame, strength = if type(s) == "number" then s else 2 })
		end
	end
end

function EffectsController.cheer(duration: number)
	cheerUntil = math.max(cheerUntil, os.clock() + duration)
	controllers.AudioController.play("CrowdCheer")
end

local lastCrowd = 0
local function animateCrowd()
	local clock = os.clock()
	if clock - lastCrowd < 0.05 then
		return
	end
	lastCrowd = clock
	local cheering = clock < cheerUntil
	local parts: { BasePart } = {}
	local cfs: { CFrame } = {}
	for _, fan in fans do
		if fan.model.Parent then
			local amp = if cheering then 0.9 else 0.12
			local freq = if cheering then 9 else 1.6
			local y = math.max(0, math.sin(clock * freq + fan.phase)) * amp
			for i, p in fan.parts do
				table.insert(parts, p)
				table.insert(cfs, fan.base[i] + Vector3.new(0, y, 0))
			end
		end
	end
	if #parts > 0 then
		workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
	for _, f in flags do
		if f.part.Parent then
			local wobble = math.sin(clock * (4 + f.strength) + f.base.Position.X) * 0.12 * math.min(f.strength, 6) / 3
			f.part.CFrame = f.base * CFrame.Angles(0, wobble, 0)
		end
	end
end

local function animateMovers()
	local t = now()
	for _, m in CollectionService:GetTagged("UBMover") do
		if m:IsA("BasePart") then
			local center = m:GetAttribute("Center")
			local amp = m:GetAttribute("Amplitude")
			local period = m:GetAttribute("Period")
			if typeof(center) == "Vector3" and type(amp) == "number" and type(period) == "number" then
				local pos = center + Vector3.new(math.sin(t * 2 * math.pi / period) * amp, 0, 0)
				m.CFrame = m.CFrame.Rotation + pos
			end
		end
	end
end

local TRAILS: { [string]: any } = {}
for _, t in ProgressionConfig.Trails do
	TRAILS[t.id] = t
end

local function cosmeticTrail(model: Model)
	local id = model:GetAttribute("UBTrail")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local trail = root:FindFirstChild("UBCosmeticTrail") :: Trail?
	local def = if type(id) == "string" then TRAILS[id] else nil
	if not def or not def.a then
		if trail then
			trail.Enabled = false
		end
		return
	end
	if not trail then
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, -0.6, 0.4)
		a0.Parent = root
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -1.6, 0.4)
		a1.Parent = root
		local t = Instance.new("Trail")
		t.Name = "UBCosmeticTrail"
		t.Attachment0 = a0
		t.Attachment1 = a1
		t.Lifetime = 0.3
		t.LightEmission = 0.4
		t.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) })
		t.Parent = root
		trail = t
	end
	local tr = trail :: Trail
	tr.Color = ColorSequence.new(def.a, def.b)
	local v = root.AssemblyLinearVelocity
	tr.Enabled = Vector3.new(v.X, 0, v.Z).Magnitude > 18
end

local lastBoard = 0
local function updateScoreboards()
	local clock = os.clock()
	if clock - lastBoard < 0.25 then
		return
	end
	lastBoard = clock
	local state = Net.state()
	local phase: string = (state:GetAttribute("Phase") or "") :: string
	local matchEnd = state:GetAttribute("MatchEnd")
	local remaining = if type(matchEnd) == "number" then matchEnd - now() else 0
	local phaseEnd = state:GetAttribute("PhaseEnd")
	local clockText = if phase == "Intermission"
			and type(phaseEnd) == "number"
			and phaseEnd > 0
		then Theme.formatTime(phaseEnd - now())
		else Theme.formatTime(remaining)
	for _, board in CollectionService:GetTagged("UBScoreboard") do
		local gui = board:FindFirstChild("Display")
		if gui then
			local function set(name: string, text: string)
				local l = gui:FindFirstChild(name)
				if l and l:IsA("TextLabel") then
					l.Text = text
				end
			end
			set("ScoreA", tostring(state:GetAttribute("ScoreA") or 0))
			set("ScoreB", tostring(state:GetAttribute("ScoreB") or 0))
			set("Clock", clockText)
			set(
				"Phase",
				string.upper(
					if phase == "PointOver" then "GOAL" elseif phase == "Intermission" then "WARMUP" else phase
				)
			)
			set(
				"Info",
				if state:GetAttribute("Universe")
					then "UNIVERSE POINT"
					else (state:GetAttribute("ModeName") or "") :: string
			)
		end
	end
	-- the end zone being attacked by your team pulses
	local myTeam = if player.Character then player.Character:GetAttribute("UBTeam") else nil
	for _, ez in CollectionService:GetTagged("UBEndZone") do
		if ez:IsA("BasePart") then
			local side = ez:GetAttribute("Side")
			local attacking = (myTeam == "A" and state:GetAttribute("AttackA") == side)
				or (myTeam == "B" and state:GetAttribute("AttackB") == side)
			ez.Transparency = if attacking and phase == "Live" then 0.78 + math.sin(clock * 3) * 0.05 else 0.86
		end
	end
end

---------------------------------------------------------------------------

function EffectsController.Init(c: any)
	controllers = c
	local f = Instance.new("Folder")
	f.Name = "UBFx"
	f.Parent = workspace:WaitForChild("UBVisuals")
	fx = f
end

function EffectsController.Start()
	controllers.MovementController.Tech:Connect(function(e)
		local c = player.Character
		if c then
			EffectsController.tech(c, e.tech, e.quality, e.dir)
		end
	end)
	controllers.MovementController.Landed:Connect(function(fromDive, speed)
		local root = controllers.MovementController.root()
		if root then
			local feet = root.Position - Vector3.new(0, 2.9, 0)
			if fromDive then
				EffectsController.dust(feet, 22)
				controllers.CameraController.shake(0.12, 0.2)
				controllers.AudioController.play("Layout", 0.1)
			elseif speed > 8 then
				EffectsController.dust(feet, 5)
				controllers.AudioController.play("Land", 0.2)
			end
		end
	end)
	controllers.ThrowController.Released:Connect(function(launch)
		controllers.AudioController.play(if launch.quality == "Perfect" then "PerfectRelease" else "Throw", 0.08)
		if launch.quality == "Perfect" then
			EffectsController.burst(launch.releasePos, Theme.Colors.Perfect, 10, 10)
		end
	end)

	Net.event("Effect").OnClientEvent:Connect(function(kind, pos, actorId, quality, zone)
		if typeof(pos) ~= "Vector3" then
			return
		end
		local mine = actorId == player.UserId
		if kind == "Catch" then
			local color = if quality == "Clean" then Theme.Colors.Clean else Theme.Colors.Gold
			EffectsController.burst(pos, color, if zone == "Dive" then 26 else 12, 10)
			controllers.AudioController.playAt(if quality == "Clean" then "CleanCatch" else "Catch", pos)
			if mine and zone == "Dive" then
				controllers.CameraController.shake(0.15, 0.25)
			end
		elseif kind == "Block" or kind == "HandBlock" then
			EffectsController.burst(pos, Theme.Colors.Bad, 22, 16)
			controllers.AudioController.playAt("Block", pos)
			EffectsController.cheer(1.2)
		elseif kind == "Bobble" then
			EffectsController.burst(pos, Theme.Colors.Gold, 14, 9)
			controllers.AudioController.playAt("Bobble", pos)
		elseif kind == "TargetHit" then
			EffectsController.burst(pos, Theme.Colors.Good, 40, 18, nil, 20)
			EffectsController.ring(pos, Theme.Colors.Good, 6, 0.4, Vector3.new(0, 0, 1))
			controllers.AudioController.play("Highlight")
		end
	end)

	Net.event("Notify").OnClientEvent:Connect(function(kind, _text, data)
		if kind == "Goal" and type(data) == "table" then
			local team = data.team
			local color = if team == "A" then TeamsConfig.A.Color else TeamsConfig.B.Color
			local scorer = if type(data.scorer) == "number" then Actors.rootOf(data.scorer) else nil
			local pos = if scorer then scorer.Position else Vector3.zero
			for _ = 1, 3 do
				EffectsController.burst(
					pos + Vector3.new(math.random(-6, 6), 6, math.random(-6, 6)),
					color,
					40,
					22,
					nil,
					25
				)
			end
			EffectsController.cheer(3)
			controllers.AudioController.play("Goal")
		elseif kind == "Turnover" then
			controllers.AudioController.play("Turnover")
		end
	end)
	Net.event("Highlight").OnClientEvent:Connect(function(h)
		if type(h) ~= "table" then
			return
		end
		EffectsController.cheer(if (h.score or 0) > 700 then 2.5 else 1.4)
		if h.id == player.UserId then
			controllers.CameraController.kick(3)
		end
	end)

	local collectQueued = false
	local function queueCollect()
		if not collectQueued then
			collectQueued = true
			task.delay(0.5, function()
				collectQueued = false
				collectFans()
			end)
		end
	end
	CollectionService:GetInstanceAddedSignal("UBCrowd"):Connect(queueCollect)
	CollectionService:GetInstanceAddedSignal("UBFlag"):Connect(queueCollect)
	collectFans()

	local lastScan = 0
	RunService.Heartbeat:Connect(function()
		animateCrowd()
		animateMovers()
		updateScoreboards()
		local clock = os.clock()
		if clock - lastScan > 0.5 then
			lastScan = clock
			for _, m in Actors.characters() do
				watch(m)
				cosmeticTrail(m)
			end
			for model, conn in watched do
				if not model.Parent then
					conn:Disconnect()
					watched[model] = nil
				end
			end
		end
	end)
end

return EffectsController
