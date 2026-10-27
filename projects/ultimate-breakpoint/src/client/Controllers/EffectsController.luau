--!strict
--[[
	EffectsController — feedback you can read at a glance.

	Every technique has its own colour and shape (Theme.TechColors) so
	experienced players recognise what an opponent just did; nothing hides the
	disc or the players. To keep the screen calm, only Clean and Perfect
	techniques get particles, and your own techniques make a sound only when
	it says something (Burst / Layout body sounds, Perfect stingers; the combo
	tick in the Hud covers the rest). There is no FOV pulse per technique: a
	Burst asks the camera for at most a 2 degree kick (CameraController caps
	kicks there anyway).

	Pivot readability. While you hold the disc: a team-coloured disc under your
	planted pivot foot (MovementController.pivot(), which follows the server's
	UBPivot), the step range around it (radius StepRadius over the front 270
	degrees, flattened where the lunge limit ForwardMax cuts it, turned with
	your aim) and a ghost of your free foot at P + step. Opponents who hold the
	disc show a small pivot dot (their UBPivot) so a marker can read the foot.

	Also: catch / block / bobble bursts (your own catch already played its
	sound and burst on the claim in CatchController, so the server's copy is
	skipped), goal confetti, crowd idle and cheering, wind flags, the moving
	training target, stadium scoreboards, cosmetic movement trails and
	end-zone glow.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Actors = require(Shared.Actors)
local MovementConfig = require(Shared.Config.Movement)
local ProgressionConfig = require(Shared.Config.Progression)
local TeamsConfig = require(Shared.Config.Teams)
local Hitbox = require(Shared.Config.Hitbox)
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

-- Visual for a technique performed by `model` (local or remote). Sloppy and
-- Gassed techniques get none: the movement itself and the combo widget
-- already show them, and the effects stay meaningful.
-- A reset (Tip Reset, Wall Rebound): a cyan pulse round the body so you
-- and everyone else can see the air moves came back.
local RESET_COLOR = Color3.fromRGB(90, 230, 255)
local function resetFlash(root: BasePart, isLocal: boolean)
	EffectsController.ring(root.Position, RESET_COLOR, 3.6, 0.35)
	EffectsController.burst(root.Position + Vector3.new(0, 1.5, 0), RESET_COLOR, 12, 10)
	if isLocal then
		controllers.AudioController.play("Reset")
	end
end

function EffectsController.tech(model: Model, tech: string, quality: string, dir: Vector3)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	if quality ~= "Perfect" and quality ~= "Clean" then
		return
	end
	local color = (Theme.TechColors :: any)[tech] or Color3.new(1, 1, 1)
	local feet = root.Position - Vector3.new(0, 2.9, 0)
	local isLocal = model == player.Character
	local perfect = quality == "Perfect"
	if tech == "SnapCut" or tech == "SlideCut" then
		EffectsController.dust(feet, 6)
		streak(model, color, 0.25)
		if perfect then
			EffectsController.ring(feet + Vector3.new(0, 0.1, 0), color, 3, 0.25)
		end
	elseif tech == "MomentumCancel" then
		EffectsController.dust(feet, 12)
		skid(feet, dir)
	elseif tech == "BurstStep" then
		EffectsController.ring(feet + Vector3.new(0, 0.1, 0), color, 4.5, 0.3)
		streak(model, color, 0.35)
		if isLocal then
			controllers.CameraController.kick(2)
		end
	elseif tech == "Slide" then
		EffectsController.dust(feet, 12)
	elseif tech == "Dive" then
		streak(model, color, 0.45)
	elseif tech == "AirRedirect" then
		EffectsController.ring(root.Position, color, 3.2, 0.3, dir)
	elseif tech == "PrecisionLanding" then
		EffectsController.ring(feet + Vector3.new(0, 0.1, 0), if perfect then Theme.Colors.Perfect else color, 5, 0.35)
		EffectsController.dust(feet, 6)
	elseif tech == "WallRebound" then
		EffectsController.burst(root.Position - dir * 1.5, color, 16, 14)
		resetFlash(root, isLocal)
	elseif tech == "TipReset" then
		resetFlash(root, isLocal)
	elseif tech == "RecoveryChain" then
		EffectsController.burst(feet + Vector3.new(0, 1, 0), color, 10, 8)
	elseif tech == "PivotSwing" then
		EffectsController.dust(feet + dir * 1.5, 3)
		if perfect then
			EffectsController.ring(feet + Vector3.new(0, 0.1, 0), color, 2.4, 0.2)
		end
	elseif tech == "Break" then
		EffectsController.burst(root.Position + Vector3.new(0, 1, 0), color, 14, 10)
	end
	-- (FakeCommit / "Lean" deliberately has no visual: a fake must look real)
	if isLocal then
		if tech == "BurstStep" or tech == "Dive" then
			controllers.AudioController.play("Burst", 0.1)
		elseif perfect and tech ~= "Jump" and tech ~= "FakeCommit" then
			controllers.AudioController.play("TechPerfect", 0.15)
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
-- pivot: your planted foot, step range and free foot; opponents' pivot dots
---------------------------------------------------------------------------

local HD = MovementConfig.Holding
local FLAT = CFrame.Angles(0, 0, math.pi / 2) -- a Cylinder part's axis is X: lay it on the ground
local GROUND_LIFT = 0.06
local ARC_SEGMENTS = 20
local ARC_HALF = math.rad(135) -- the step range is drawn over the front 270 degrees
local GHOST_MIN_STEP = 0.35 -- the free-foot ghost shows once the step is this long
local DOT_EVERY = 0.1

type PivotFx = {
	foot: BasePart,
	ghost: BasePart,
	arc: { BasePart },
	shown: boolean,
	color: Color3?,
}

local pivotFx: PivotFx? = nil
local arcLocal: { CFrame } = {}
local remoteDots: { [Model]: BasePart } = {}

local function flatDisc(name: string, diameter: number, color: Color3, transparency: number): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency
	p.Size = Vector3.new(0.06, diameter, diameter)
	p.Parent = fx
	return p
end

-- Edge of the reachable step region at angle `a` from the aim (0 = forward,
-- + = right): the StepRadius circle cut by the lunge / drop-step limits.
local function stepEdge(a: number): Vector3
	local R = HD.StepRadius
	local fwd = math.cos(a)
	local d = R
	if fwd > 1e-3 then
		d = math.min(d, HD.ForwardMax * R / fwd)
	elseif fwd < -1e-3 then
		d = math.min(d, HD.BackMax * R / -fwd)
	end
	-- local frame: +X right, -Z forward (CFrame.Angles(0, yaw, 0) convention)
	return Vector3.new(math.sin(a) * d, 0, -fwd * d)
end

local function buildPivotFx(): PivotFx
	local arc: { BasePart } = {}
	table.clear(arcLocal)
	for i = 0, ARC_SEGMENTS - 1 do
		local a0 = -ARC_HALF + 2 * ARC_HALF * i / ARC_SEGMENTS
		local a1 = -ARC_HALF + 2 * ARC_HALF * (i + 1) / ARC_SEGMENTS
		local p0, p1 = stepEdge(a0), stepEdge(a1)
		local seg = Instance.new("Part")
		seg.Name = "UBStepArc"
		seg.Anchored = true
		seg.CanCollide = false
		seg.CanQuery = false
		seg.CanTouch = false
		seg.CastShadow = false
		seg.Material = Enum.Material.Neon
		seg.Transparency = 1
		seg.Size = Vector3.new(0.12, 0.04, (p1 - p0).Magnitude + 0.04)
		seg.Parent = fx
		table.insert(arc, seg)
		table.insert(arcLocal, CFrame.lookAt((p0 + p1) / 2, p1))
	end
	return {
		foot = flatDisc("UBPivotFoot", 1.1, Theme.Colors.Accent, 1),
		ghost = flatDisc("UBFreeFoot", 0.9, Color3.new(1, 1, 1), 1),
		arc = arc,
		shown = false,
		color = nil,
	}
end

local function setPivotShown(p: PivotFx, shown: boolean, ghost: boolean)
	p.ghost.Transparency = if shown and ghost then 0.5 else 1
	if p.shown == shown then
		return
	end
	p.shown = shown
	p.foot.Transparency = if shown then 0.15 else 1
	for _, seg in p.arc do
		seg.Transparency = if shown then 0.55 else 1
	end
end

local function standHeightOf(model: Model): number
	local h = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if h and root and h.RigType == Enum.HumanoidRigType.R15 then
		return h.HipHeight + root.Size.Y / 2
	end
	return 3
end

-- Every frame after the camera: your pivot foot, step range and free foot.
local function updateLocalPivot()
	local p = pivotFx
	if not p then
		return
	end
	local mc = controllers.MovementController
	local pivot: Vector3? = if mc.holdingDisc() then mc.pivot() else nil
	local character = player.Character
	if not pivot or not character or not mc.root() then
		setPivotShown(p, false, false)
		return
	end
	local team = character:GetAttribute("UBTeam")
	local color = Theme.teamColor(if type(team) == "string" then team else nil)
	if team ~= "A" and team ~= "B" then
		color = Theme.Colors.Accent
	end
	if p.color ~= color then
		p.color = color
		p.foot.Color = color
		local edge = color:Lerp(Color3.new(1, 1, 1), 0.35)
		for _, seg in p.arc do
			seg.Color = edge
		end
	end
	local base = Vector3.new(pivot.X, pivot.Y - mc.standHeight() + GROUND_LIFT, pivot.Z)
	local step: Vector3 = mc.step()
	local flatStep = Vector3.new(step.X, 0, step.Z)
	local showGhost = flatStep.Magnitude >= GHOST_MIN_STEP
	setPivotShown(p, true, showGhost)
	local parts: { BasePart } = { p.foot, p.ghost }
	local cfs: { CFrame } = {
		CFrame.new(base) * FLAT,
		CFrame.new(base + flatStep + Vector3.new(0, 0.01, 0)) * FLAT,
	}
	local frame = CFrame.new(base) * CFrame.Angles(0, controllers.CameraController.getYaw(), 0)
	for i, seg in p.arc do
		table.insert(parts, seg)
		table.insert(cfs, frame * arcLocal[i])
	end
	workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

-- A small pivot dot under every opponent who holds the disc (their UBPivot).
local function updateRemoteDots()
	local mine = player.Character
	local myTeam = if mine then mine:GetAttribute("UBTeam") else nil
	local onTeam = myTeam == "A" or myTeam == "B"
	local seen: { [Model]: boolean } = {}
	for _, m in Actors.characters() do
		if m ~= mine then
			local pv = m:GetAttribute("UBPivot")
			local team = m:GetAttribute("UBTeam")
			if typeof(pv) == "Vector3" and (not onTeam or team ~= myTeam) then
				seen[m] = true
				local color = Theme.teamColor(if type(team) == "string" then team else nil)
				local dot = remoteDots[m]
				if not dot then
					dot = flatDisc("UBPivotDot", 0.8, color, 0.3)
					remoteDots[m] = dot
				end
				local d = dot :: BasePart
				d.Color = color
				d.CFrame = CFrame.new(pv.X, pv.Y - standHeightOf(m) + GROUND_LIFT, pv.Z) * FLAT
			end
		end
	end
	for m, dot in remoteDots do
		if not seen[m] then
			dot:Destroy()
			remoteDots[m] = nil
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

---------------------------------------------------------------------------
-- hitbox overlay (Settings: Show hitboxes)
---------------------------------------------------------------------------

-- The fixed gameplay body of every character as a see-through capsule from
-- the feet (Config/Hitbox), so players can check that everyone's body is the
-- same whatever their avatar. Client-only adornments, refreshed at 10 Hz.
type HitboxDraw = { parts: { HandleAdornment }, root: BasePart }
local hitboxDraws: { [Model]: HitboxDraw } = {}
local hitboxNextRefresh = 0

local function clearHitboxes()
	for model, d in hitboxDraws do
		for _, a in d.parts do
			a:Destroy()
		end
		hitboxDraws[model] = nil
	end
end

local function hitboxColor(model: Model): Color3
	local team = model:GetAttribute("UBTeam")
	if team == "A" then
		return TeamsConfig.A.Color
	elseif team == "B" then
		return TeamsConfig.B.Color
	end
	return TeamsConfig.Neutral.Color
end

local function drawHitbox(model: Model, root: BasePart): HitboxDraw
	local r, h = Hitbox.Radius, Hitbox.Height
	local function adorn(a: HandleAdornment)
		a.Adornee = root
		a.AlwaysOnTop = false
		a.ZIndex = 0
		a.Transparency = 0.75
		a.Color3 = hitboxColor(model)
		a.Parent = fx
	end
	local body = Instance.new("CylinderHandleAdornment")
	body.Radius = r
	body.Height = math.max(h - 2 * r, 0.1)
	adorn(body)
	local top = Instance.new("SphereHandleAdornment")
	top.Radius = r
	adorn(top)
	local bottom = Instance.new("SphereHandleAdornment")
	bottom.Radius = r
	adorn(bottom)
	return { parts = { body, top, bottom }, root = root }
end

local function placeHitbox(model: Model, d: HitboxDraw)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local feet = -Hitbox.standHeightOf(humanoid, d.root)
	local r, h = Hitbox.Radius, Hitbox.Height
	local mid = feet + h / 2
	-- adornment offsets are in the root's space; keep the capsule upright
	-- (CylinderHandleAdornment's axis is its local Z)
	local upright = CFrame.Angles(math.rad(90), 0, 0)
	d.parts[1].CFrame = CFrame.new(0, mid, 0) * upright
	d.parts[2].CFrame = CFrame.new(0, feet + h - r, 0)
	d.parts[3].CFrame = CFrame.new(0, feet + r, 0)
	local color = hitboxColor(model)
	for _, a in d.parts do
		a.Color3 = color
	end
end

local function updateHitboxes()
	if controllers.SettingsController.get("ShowHitboxes") ~= true then
		if next(hitboxDraws) ~= nil then
			clearHitboxes()
		end
		return
	end
	local seen: { [Model]: boolean } = {}
	for _, model in Actors.characters() do
		local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			seen[model] = true
			local d: HitboxDraw? = hitboxDraws[model]
			if d and d.root ~= root then
				for _, a in d.parts do
					a:Destroy()
				end
				d = nil
			end
			if not d then
				d = drawHitbox(model, root)
				hitboxDraws[model] = d
			end
			placeHitbox(model, d :: HitboxDraw)
		end
	end
	for model, d in hitboxDraws do
		if not seen[model] then
			for _, a in d.parts do
				a:Destroy()
			end
			hitboxDraws[model] = nil
		end
	end
end

function EffectsController.Start()
	RunService.Heartbeat:Connect(function()
		local t = os.clock()
		if t >= hitboxNextRefresh then
			hitboxNextRefresh = t + 0.1
			updateHitboxes()
		end
	end)

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
			-- your own claim already played the sound and a burst (CatchController)
			if not (mine and controllers.CatchController.recentLocalCatch()) then
				local color = if quality == "Clean" then Theme.Colors.Clean else Theme.Colors.Gold
				EffectsController.burst(pos, color, if zone == "Dive" then 26 else 12, 10)
				controllers.AudioController.playAt(if quality == "Clean" then "CleanCatch" else "Catch", pos)
			end
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
		elseif kind == "Tip" then
			-- your own tip already played its burst and sound (CatchController)
			if not mine then
				EffectsController.burst(pos, RESET_COLOR, 10, 12)
				controllers.AudioController.playAt("Tip", pos)
			end
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

	pivotFx = buildPivotFx()
	-- after the camera (its yaw turns the step range) and the movement step
	RunService:BindToRenderStep("UBPivotFx", Enum.RenderPriority.Camera.Value + 6, updateLocalPivot)

	local lastScan = 0
	local lastDots = 0
	RunService.Heartbeat:Connect(function()
		animateCrowd()
		animateMovers()
		updateScoreboards()
		local clock = os.clock()
		if clock - lastDots >= DOT_EVERY then
			lastDots = clock
			updateRemoteDots()
		end
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
