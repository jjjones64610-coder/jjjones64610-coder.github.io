--!strict
--[[
	PoseController — procedural body language for every character.

	Base locomotion comes from animations (src/character/Animate, BotService).
	On top, each client offsets Motor6D.C0 of the root, waist, neck, shoulders
	and (R15) hips, knees and ankles so that what you see matches what the
	movement engine is doing: leaning into acceleration and turns, the dip of a
	Snap Cut, the sit-back of a Momentum Cancel, the forward sell of a Fake
	Commit or Burst, the feet-first Slide, the horizontal Layout, the pivot
	lunge while holding the disc, mark stances (wide-low or high hands) with a
	side-shuffle, the reach toward the disc, the throw windup / follow-through
	(identical for real throws and fakes) and celebrations. Heads track the
	disc.

	Feet stay on the ground: whenever the body is lowered the legs bend to
	absorb the drop. Running poses (animation owns the legs) bend hips, knees
	and ankles symmetrically by the angle that shortens the leg by exactly the
	drop; standing poses (pivot lunge, mark stance) solve a two-bone IK per leg
	to a foot target on the ground (for the holder the pivot foot toward P and
	the stepping foot toward P + step, as far as the leg reaches; the stepping
	leg is the one on the step's side so legs never cross). R6 rigs, which have
	no knees, are not lowered.

	Leans come from clean signals: the local character's sim acceleration, and
	for everyone else a velocity measured from replicated positions over
	~0.1 s, low-passed before it is differentiated (roll clamped to 0.18 rad),
	so network jitter never shakes a torso. Speed scales come from
	Config/Movement.

	The rest pose of every joint is cached per Motor6D the first time it is
	seen and only re-read when something other than this controller rewrites
	C0 (avatar scaling), so a rebuilt rig never bakes in an old offset; on an
	error the joints are restored before the rig is dropped.

	C0 edits are local to each client and never replicate, so every client
	poses every character from replicated attributes (the local character from
	its own controllers, with zero latency).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Actors = require(Shared.Actors)
local Net = require(Shared.Net)
local MovementConfig = require(Shared.Config.Movement)

local PoseController = {}

local controllers: any
local player = Players.LocalPlayer

local HD = MovementConfig.Holding
local SPRINT = MovementConfig.SprintSpeed

type Joint = { motor: Motor6D, current: CFrame }

type Leg = {
	hip: Joint,
	knee: Joint,
	ankle: Joint?,
	side: number, -- -1 left, +1 right
	thigh: number, -- hip -> knee length
	shin: number, -- knee -> ankle length
	ankleHeight: number, -- ankle joint above the sole
	hipPos: Vector3, -- hip joint in LowerTorso space
	thighRest: Vector3, -- thigh direction in LowerTorso space at rest
	shinRest: Vector3, -- shin direction in UpperLeg space at rest
	hipRestRot: CFrame, -- UpperLeg rotation relative to LowerTorso at rest
	kneeRestRot: CFrame, -- LowerLeg rotation relative to UpperLeg at rest
	restFoot: Vector3, -- sole under the ankle at rest, HRP space
	foot: Vector3?, -- smoothed foot target (stance poses), HRP space
}

type Rig = {
	model: Model,
	root: BasePart,
	humanoid: Humanoid,
	joints: { [string]: Joint }, -- Root, Waist, Neck, RShoulder, LShoulder
	legs: { Leg }, -- empty for R6
	rootC1: CFrame,
	isLocal: boolean,
	r15: boolean,
	-- smoothed body parameters
	drop: number,
	pitch: number,
	roll: number,
	-- lean signal
	lastVel: Vector3,
	accel: Vector3,
	history: { { t: number, p: Vector3 } },
	smoothVel: Vector3,
	shufflePhase: number,
	freeSide: number, -- the leg that steps out in the pivot lunge (-1 left, +1 right)
	legMode: string, -- last Pose.legs (a change blends the legs briefly)
	legSwitchAt: number,
	seenAt: number,
}

local rigs: { [Model]: Rig } = {}
local firstSeen: { [Model]: number } = {}
local warned: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local localTech = { name = "", t = -math.huge, dir = Vector3.zero }

-- Rest C0 per motor, and what we last wrote (to tell our offsets from a
-- genuine new rest pose written by avatar scaling).
type BaseEntry = { base: CFrame, written: CFrame? }
local bases: { [Motor6D]: BaseEntry } = setmetatable({}, { __mode = "k" }) :: any

local R15_UPPER = {
	Root = { "LowerTorso", "Root" },
	Waist = { "UpperTorso", "Waist" },
	Neck = { "Head", "Neck" },
	RShoulder = { "RightUpperArm", "RightShoulder" },
	LShoulder = { "LeftUpperArm", "LeftShoulder" },
}

local R15_LEGS = {
	{ side = -1, prefix = "Left" },
	{ side = 1, prefix = "Right" },
}

local R6_JOINTS = {
	Root = { "HumanoidRootPart", "RootJoint" },
	Neck = { "Torso", "Neck" },
	RShoulder = { "Torso", "Right Shoulder" },
	LShoulder = { "Torso", "Left Shoulder" },
}

local IDENTITY = CFrame.identity
local DOWN = Vector3.new(0, -1, 0)
local LEG_RATE = 26 -- blend speed when the legs switch between pose kinds
local LEG_BLEND_TIME = 0.2
local SHUFFLE_AMPLITUDE = 0.45
local SHUFFLE_LIFT = 0.3

local function now(): number
	return Net.now()
end

local function near(a: CFrame, b: CFrame): boolean
	return (a.Position - b.Position).Magnitude < 1e-3
		and a.LookVector:Dot(b.LookVector) > 0.9999
		and a.UpVector:Dot(b.UpVector) > 0.9999
end

-- The rest C0 of a motor. Re-captured only when C0 is not what we wrote.
local function baseOf(motor: Motor6D): CFrame
	local e = bases[motor]
	local c0 = motor.C0
	if e == nil then
		e = { base = c0, written = nil }
		bases[motor] = e
	elseif e.written == nil or not near(c0, e.written :: CFrame) then
		e.base = c0
		e.written = nil
	end
	return (e :: BaseEntry).base
end

-- true when someone else rewrote this joint since our last write
local function externallyChanged(motor: Motor6D): boolean
	local e = bases[motor]
	return e ~= nil and e.written ~= nil and not near(motor.C0, e.written :: CFrame)
end

local function write(joint: Joint)
	local e = bases[joint.motor]
	if not e then
		return
	end
	local base = e.base
	local c0 = CFrame.new(base.Position) * joint.current * base.Rotation
	joint.motor.C0 = c0
	e.written = c0
end

local function restoreRig(rig: Rig)
	local all: { Joint } = {}
	for _, j in rig.joints do
		table.insert(all, j)
	end
	for _, leg in rig.legs do
		table.insert(all, leg.hip)
		table.insert(all, leg.knee)
		if leg.ankle then
			table.insert(all, leg.ankle)
		end
	end
	for _, j in all do
		local e = bases[j.motor]
		if e and j.motor.Parent then
			j.motor.C0 = e.base
			e.written = e.base
		end
	end
end

local function motorAt(model: Model, part: string, name: string): Motor6D?
	local p = model:FindFirstChild(part)
	local m = p and p:FindFirstChild(name)
	if m and m:IsA("Motor6D") then
		return m
	end
	return nil
end

local function buildLeg(model: Model, side: number, prefix: string, ltRest: CFrame): Leg?
	local hip = motorAt(model, prefix .. "UpperLeg", prefix .. "Hip")
	local knee = motorAt(model, prefix .. "LowerLeg", prefix .. "Knee")
	if not hip or not knee then
		return nil
	end
	local ankle = motorAt(model, prefix .. "Foot", prefix .. "Ankle")
	local hipBase, kneeBase = baseOf(hip), baseOf(knee)
	local thighVec = kneeBase.Position - hip.C1.Position -- UpperLeg space
	local shinVec: Vector3
	local ankleHeight = 0.2
	if ankle then
		local ankleBase = baseOf(ankle)
		shinVec = ankleBase.Position - knee.C1.Position -- LowerLeg space
		local foot = model:FindFirstChild(prefix .. "Foot")
		if foot and foot:IsA("BasePart") then
			ankleHeight = math.max(0.05, ankle.C1.Position.Y + foot.Size.Y / 2)
		end
	else
		local lower = model:FindFirstChild(prefix .. "LowerLeg")
		local h = if lower and lower:IsA("BasePart") then lower.Size.Y else 1.2
		shinVec = Vector3.new(0, -h, 0)
	end
	local a, b = thighVec.Magnitude, shinVec.Magnitude
	if a < 0.1 or b < 0.1 then
		return nil
	end
	local hipRestRot = (hipBase * hip.C1:Inverse()).Rotation
	local kneeRestRot = (kneeBase * knee.C1:Inverse()).Rotation
	local thighRest = hipRestRot:VectorToWorldSpace(thighVec.Unit)
	local shinRest = kneeRestRot:VectorToWorldSpace(shinVec.Unit)
	-- rest foot (sole under the ankle) in HRP space
	local hipHrp = ltRest:PointToWorldSpace(hipBase.Position)
	local kneeHrp = hipHrp + ltRest:VectorToWorldSpace(thighRest) * a
	local shinHrp = (ltRest.Rotation * hipRestRot):VectorToWorldSpace(shinRest)
	local ankleHrp = kneeHrp + shinHrp * b
	return {
		hip = { motor = hip, current = IDENTITY },
		knee = { motor = knee, current = IDENTITY },
		ankle = if ankle then { motor = ankle, current = IDENTITY } else nil,
		side = side,
		thigh = a,
		shin = b,
		ankleHeight = ankleHeight,
		hipPos = hipBase.Position,
		thighRest = thighRest,
		shinRest = shinRest,
		hipRestRot = hipRestRot,
		kneeRestRot = kneeRestRot,
		restFoot = ankleHrp - Vector3.new(0, ankleHeight, 0),
		foot = nil,
	}
end

local function buildRig(model: Model): Rig?
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return nil
	end
	local r15 = humanoid.RigType == Enum.HumanoidRigType.R15
	local map: { [string]: { string } } = if r15 then R15_UPPER else R6_JOINTS
	local joints: { [string]: Joint } = {}
	for key, path in map do
		local motor = motorAt(model, path[1], path[2])
		if motor then
			baseOf(motor)
			joints[key] = { motor = motor, current = IDENTITY }
		end
	end
	local rootJoint = joints.Root
	if not rootJoint then
		return nil
	end
	local legs: { Leg } = {}
	local rootC1 = rootJoint.motor.C1
	if r15 then
		local ltRest = baseOf(rootJoint.motor) * rootC1:Inverse()
		for _, def in R15_LEGS do
			local leg = buildLeg(model, def.side, def.prefix, ltRest)
			if leg then
				table.insert(legs, leg)
			end
		end
		if #legs ~= 2 then
			legs = {}
		end
	end
	local vel = root.AssemblyLinearVelocity
	return {
		model = model,
		root = root,
		humanoid = humanoid,
		joints = joints,
		legs = legs,
		rootC1 = rootC1,
		isLocal = model == player.Character,
		r15 = r15,
		drop = 0,
		pitch = 0,
		roll = 0,
		lastVel = vel,
		accel = Vector3.zero,
		history = {},
		smoothVel = Vector3.new(vel.X, 0, vel.Z),
		shufflePhase = 0,
		freeSide = 1,
		legMode = "free",
		legSwitchAt = -math.huge,
		seenAt = os.clock(),
	}
end

-- rotation taking unit vector a onto unit vector b
local function arc(a: Vector3, b: Vector3): CFrame
	local d = math.clamp(a:Dot(b), -1, 1)
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-6 then
		if d > 0 then
			return IDENTITY
		end
		local perp = if math.abs(a.X) < 0.9 then Vector3.xAxis:Cross(a) else Vector3.yAxis:Cross(a)
		return CFrame.fromAxisAngle(perp.Unit, math.pi)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(d))
end

-- rotation taking the hanging arm (0,-1,0) to point along local direction d
local function aimArm(d: Vector3): CFrame
	local dir = if d.Magnitude > 0.01 then d.Unit else DOWN
	return arc(DOWN, dir)
end

local function attrNumber(model: Model, key: string): number
	local v = model:GetAttribute(key)
	return if type(v) == "number" then v else -math.huge
end

type Ctx = {
	mode: string,
	grounded: boolean,
	speed: number,
	fwdAccel: number,
	latAccel: number,
	rollLimit: number,
	leanLimit: number,
	localVel: Vector3, -- body-space horizontal velocity
	tech: string,
	techAge: number,
	techDir: Vector3, -- local space
	reachAge: number,
	reachDir: Vector3, -- local space
	windup: boolean,
	windupType: string,
	fakeAge: number,
	releaseAge: number,
	releaseType: string,
	mark: string,
	holding: boolean,
	step: Vector3, -- body-space step of the free foot (zero unless pivoting)
	celebrate: string,
	celebrateAge: number,
	leftHanded: boolean,
	lookAt: Vector3?, -- local space
}

local GROUNDED_MODES: { [string]: boolean } = {
	Ground = true,
	Landing = true,
	Pivot = true,
	Mark = true,
	Recover = true,
	Frozen = true,
}

local function toLocal(root: BasePart, v: Vector3): Vector3
	return root.CFrame:VectorToObjectSpace(v)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Remote characters: velocity from replicated positions over ~0.1 s, low-passed.
local function remoteVelocity(rig: Rig, dt: number): Vector3
	local t = os.clock()
	local h = rig.history
	table.insert(h, { t = t, p = rig.root.Position })
	while #h > 2 and t - h[2].t >= 0.1 do
		table.remove(h, 1)
	end
	local oldest = h[1]
	local span = t - oldest.t
	local raw = if span > 1e-3 then flat(rig.root.Position - oldest.p) / span else rig.smoothVel
	if raw.Magnitude > MovementConfig.HardCap * 1.5 then
		raw = rig.smoothVel -- a teleport, not running
	end
	rig.smoothVel = rig.smoothVel:Lerp(raw, 1 - math.exp(-8 * dt))
	return rig.smoothVel
end

local function gather(rig: Rig, dt: number): Ctx
	local m = rig.model
	local root = rig.root
	local t = now()

	local ctx: Ctx = {
		mode = "Ground",
		grounded = true,
		speed = 0,
		fwdAccel = 0,
		latAccel = 0,
		rollLimit = 0.32,
		leanLimit = 0.22,
		localVel = Vector3.zero,
		tech = "",
		techAge = math.huge,
		techDir = Vector3.zero,
		reachAge = math.huge,
		reachDir = Vector3.new(0, 0, -1),
		windup = false,
		windupType = "Backhand",
		fakeAge = math.huge,
		releaseAge = math.huge,
		releaseType = "Backhand",
		mark = "",
		holding = m:GetAttribute("HasDisc") == true,
		step = Vector3.zero,
		celebrate = "",
		celebrateAge = math.huge,
		leftHanded = m:GetAttribute("LeftHanded") == true,
		lookAt = nil,
	}

	local vel: Vector3
	if rig.isLocal then
		local mc = controllers.MovementController
		local sim = mc.sim()
		vel = flat(sim.vel)
		local raw = (vel - rig.lastVel) / math.max(dt, 1 / 240)
		rig.lastVel = vel
		if raw.Magnitude > 400 then
			raw = raw.Unit * 400
		end
		rig.accel = rig.accel:Lerp(raw, 1 - math.exp(-10 * dt))
		local lm = m:GetAttribute("UB_LocalMode")
		ctx.mode = if type(lm) == "string" and lm ~= "" then lm else sim.mode
		ctx.tech = localTech.name
		ctx.techAge = t - localTech.t
		ctx.techDir = toLocal(root, localTech.dir)
		local reachAt, reachDir = controllers.CatchController.reachState()
		ctx.reachAge = t - reachAt
		ctx.reachDir = toLocal(root, reachDir)
		ctx.windup = controllers.ThrowController.isCharging()
		ctx.windupType = controllers.ThrowController.hud().throwType
		ctx.fakeAge = t - attrNumber(m, "UB_LocalFake")
		ctx.releaseAge = t - attrNumber(m, "UB_LocalRelease")
		ctx.releaseType = ctx.windupType
		ctx.mark = if controllers.CatchController.isMarking() then controllers.CatchController.markStance() else ""
		ctx.holding = controllers.ThrowController.isHolding() or mc.holdingDisc()
		if ctx.mode == "Pivot" then
			ctx.step = toLocal(root, mc.step())
		end
	else
		vel = remoteVelocity(rig, dt)
		local raw = (vel - rig.lastVel) / math.max(dt, 1 / 240)
		rig.lastVel = vel
		if raw.Magnitude > 150 then
			raw = raw.Unit * 150
		end
		rig.accel = rig.accel:Lerp(raw, 1 - math.exp(-4 * dt))
		ctx.rollLimit = 0.18
		ctx.leanLimit = 0.12
		local ms = m:GetAttribute("MS")
		ctx.mode = if type(ms) == "string" then ms else "Ground"
		local tech = m:GetAttribute("Tech")
		ctx.tech = if type(tech) == "string" then tech else ""
		ctx.techAge = t - attrNumber(m, "TechT")
		local td = m:GetAttribute("TechDir")
		ctx.techDir = if typeof(td) == "Vector3" then toLocal(root, td) else Vector3.zero
		ctx.reachAge = t - attrNumber(m, "Reach")
		local rd = m:GetAttribute("ReachDir")
		ctx.reachDir = if typeof(rd) == "Vector3" then toLocal(root, rd) else Vector3.new(0, 0, -1)
		local windupT = attrNumber(m, "Windup")
		local releaseT = attrNumber(m, "Release")
		local fakeT = attrNumber(m, "Fake")
		ctx.windup = ctx.holding and windupT > releaseT and windupT > fakeT and t - windupT < 3
		local wt = m:GetAttribute("WindupType")
		ctx.windupType = if type(wt) == "string" then wt else "Backhand"
		ctx.fakeAge = t - fakeT
		ctx.releaseAge = t - releaseT
		local rt = m:GetAttribute("ReleaseType")
		ctx.releaseType = if type(rt) == "string" then rt else "Backhand"
		local mark = m:GetAttribute("Mark")
		ctx.mark = if type(mark) == "string" then mark else ""
		local pv = m:GetAttribute("UBPivot")
		if ctx.mode == "Pivot" and typeof(pv) == "Vector3" then
			local s = flat(root.Position - pv) / HD.BodyShare
			if s.Magnitude > HD.StepRadius then
				s = s.Unit * HD.StepRadius
			end
			ctx.step = toLocal(root, s)
		end
	end
	ctx.grounded = GROUNDED_MODES[ctx.mode] == true
	ctx.speed = vel.Magnitude
	local localVel = toLocal(root, vel)
	ctx.localVel = Vector3.new(localVel.X, 0, localVel.Z)
	local localAccel = toLocal(root, rig.accel)
	ctx.fwdAccel = -localAccel.Z
	ctx.latAccel = localAccel.X

	local cel = m:GetAttribute("Celebrate")
	ctx.celebrate = if type(cel) == "string" then cel else ""
	ctx.celebrateAge = t - attrNumber(m, "CelebrateT")

	-- heads follow the nearest flying disc
	local head = root.Position + Vector3.new(0, 2.5, 0)
	local best, bestD = nil, 120
	for _, f in controllers.DiscRenderer.folders() do
		if f:GetAttribute("Mode") == "Flight" then
			local p = controllers.DiscRenderer.positionOf(f:GetAttribute("Id"))
			if p then
				local d = (p - head).Magnitude
				if d < bestD then
					best, bestD = p, d
				end
			end
		end
	end
	if best then
		ctx.lookAt = toLocal(root, (best :: Vector3) - head)
	end
	return ctx
end

-- legs: "free" = animation owns the legs, bend to absorb the drop;
-- "stance" = IK feet on the ground; "slide" = feet-first slide; "none".
type Pose = {
	drop: number,
	pitch: number,
	roll: number,
	yaw: number, -- applied unsmoothed (spins)
	legs: string,
	stance: string, -- "lunge" | "wide" | "high" (with legs == "stance")
	step: Vector3, -- body-space step for the lunge
	Waist: CFrame,
	Neck: CFrame,
	RShoulder: CFrame,
	LShoulder: CFrame,
	rate: number,
}

local function windupArm(kind: string): CFrame
	if kind == "Forehand" then
		return CFrame.Angles(0.35, 0, 1.25)
	elseif kind == "Hammer" or kind == "Scoober" then
		return CFrame.Angles(2.9, 0, 0.25)
	end
	return CFrame.Angles(1.3, 0, -1.0) -- backhand: arm across the body
end

local function windupWaist(kind: string): CFrame
	if kind == "Forehand" then
		return CFrame.Angles(0, -0.55, 0)
	elseif kind == "Hammer" or kind == "Scoober" then
		return CFrame.Angles(0.3, 0, 0)
	end
	return CFrame.Angles(0, 0.75, 0)
end

local function compute(ctx: Ctx): Pose
	local pose: Pose = {
		drop = 0,
		pitch = 0,
		roll = 0,
		yaw = 0,
		legs = "free",
		stance = "",
		step = Vector3.zero,
		Waist = IDENTITY,
		Neck = IDENTITY,
		RShoulder = IDENTITY,
		LShoulder = IDENTITY,
		rate = 12,
	}
	-- base lean from speed, acceleration and turning
	pose.pitch = -math.clamp(ctx.speed / SPRINT, 0, 1) * 0.12
		- math.clamp(ctx.fwdAccel / 90, -ctx.leanLimit * 0.7, ctx.leanLimit)
	pose.roll = -math.clamp(ctx.latAccel / 130, -ctx.rollLimit, ctx.rollLimit)

	local age = ctx.techAge
	local tech = ctx.tech
	local dx = ctx.techDir.X
	if tech == "SnapCut" and age < 0.22 then
		pose.drop, pose.pitch, pose.roll = 0.3, pose.pitch - 0.1, -math.sign(dx) * 0.45
		pose.rate = 26
	elseif tech == "SlideCut" and age < 0.22 then
		pose.drop, pose.pitch, pose.roll = 0.5, -0.2, -math.sign(dx) * 0.5
		pose.rate = 26
	elseif tech == "MomentumCancel" and age < 0.3 then
		pose.drop, pose.pitch, pose.roll = 0.6, 0.38, 0
		pose.rate = 26
	elseif (tech == "Lean" or tech == "FakeCommit" or tech == "BurstStep") and age < 0.25 then
		pose.drop, pose.pitch, pose.roll = 0.2, -0.45, -math.clamp(dx, -1, 1) * 0.3
		pose.rate = 28
	elseif tech == "AirRedirect" and age < 0.3 then
		pose.pitch, pose.roll = -0.2, -math.sign(dx) * 0.4
		pose.rate = 22
	elseif tech == "PrecisionLanding" and age < 0.16 then
		pose.drop, pose.pitch = 0.8, -0.15
		pose.rate = 30
	elseif tech == "WallRebound" and age < 0.3 then
		pose.pitch, pose.roll = 0.2, -math.sign(dx) * 0.5
		pose.rate = 24
	end

	local mode = ctx.mode
	local airUp = false
	if mode == "Slide" then
		pose.drop, pose.pitch, pose.roll = 1.7, 0.95, 0
		pose.legs = "slide"
		pose.LShoulder = CFrame.Angles(0.9, 0, -0.7)
		pose.rate = 20
	elseif mode == "Dive" then
		pose.drop, pose.pitch, pose.roll = 0.5, -1.35, 0
		pose.legs = "none"
		pose.RShoulder = CFrame.Angles(2.95, 0, 0.12)
		pose.LShoulder = CFrame.Angles(2.95, 0, -0.12)
		pose.rate = 18
	elseif mode == "DiveSlide" then
		pose.drop, pose.pitch, pose.roll = 2.1, -1.47, 0
		pose.legs = "none"
		pose.RShoulder = CFrame.Angles(2.95, 0, 0.12)
		pose.LShoulder = CFrame.Angles(2.95, 0, -0.12)
		pose.rate = 22
	elseif mode == "Recover" then
		pose.drop, pose.pitch, pose.roll = 1.2, -0.6, 0
		pose.rate = 16
	elseif mode == "Air" then
		airUp = true
	elseif mode == "Pivot" then
		-- the lunge: lower and lean into the step, feet at P and P + step
		local s = ctx.step
		local R = HD.StepRadius
		local reach = math.clamp(s.Magnitude / R, 0, 1)
		pose.drop = 0.2 + 0.5 * reach
		pose.pitch = -0.18 * math.clamp(-s.Z / R, 0, 1) + 0.08 * math.clamp(s.Z / R, 0, 1)
		pose.roll = -math.clamp(s.X / R, -1, 1) * 0.3
		pose.legs = "stance"
		pose.stance = "lunge"
		pose.step = s
		pose.rate = 22
	end

	-- mark stance (on the ground)
	if ctx.mark == "Low" and ctx.grounded then
		pose.drop, pose.pitch = 0.55, -0.25
		pose.legs = "stance"
		pose.stance = "wide"
		pose.RShoulder = CFrame.Angles(0.1, 0, 1.4)
		pose.LShoulder = CFrame.Angles(0.1, 0, -1.4)
		pose.rate = 18
	elseif ctx.mark == "High" then
		if ctx.grounded then
			pose.drop, pose.pitch = 0.2, -0.05
			pose.legs = "stance"
			pose.stance = "high"
		end
		pose.RShoulder = CFrame.Angles(2.85, 0, 0.25)
		pose.LShoulder = CFrame.Angles(2.85, 0, -0.25)
		pose.rate = 18
	elseif mode == "Mark" then
		-- shuffling without a stance yet: athletic stance, the feet still step
		pose.drop, pose.pitch = 0.25, -0.1
		pose.legs = "stance"
		pose.stance = "high"
	elseif airUp then
		pose.RShoulder = CFrame.Angles(0.7, 0, 0.35)
		pose.LShoulder = CFrame.Angles(0.7, 0, -0.35)
	end

	-- the disc arm
	local throwArm = IDENTITY
	local throwSet = false
	if ctx.holding then
		throwArm = CFrame.Angles(0.55, 0, 0.1)
		throwSet = true
	end
	if ctx.windup or ctx.fakeAge < 0.22 then
		throwArm = windupArm(ctx.windupType)
		pose.Waist = windupWaist(ctx.windupType)
		throwSet = true
		pose.rate = math.max(pose.rate, 22)
	elseif ctx.releaseAge < 0.25 then
		throwArm = if ctx.releaseType == "Hammer" or ctx.releaseType == "Scoober"
			then CFrame.Angles(2.2, 0, 0.1)
			else CFrame.Angles(1.6, 0, 0.25)
		pose.Waist = if ctx.releaseType == "Forehand" then CFrame.Angles(0, 0.35, 0) else CFrame.Angles(0, -0.45, 0)
		throwSet = true
		pose.rate = 30
	end
	if throwSet then
		if ctx.leftHanded then
			local rx, ry, rz = throwArm:ToEulerAnglesXYZ()
			pose.LShoulder = CFrame.Angles(rx, -ry, -rz)
		else
			pose.RShoulder = throwArm
		end
	end

	-- reach: turn the chest toward the disc and point the near arm at it
	if ctx.reachAge < 0.35 and not ctx.holding then
		local d = ctx.reachDir
		local arm = aimArm(d)
		local flatD = Vector3.new(d.X, 0, d.Z)
		if flatD.Magnitude > 0.05 then
			pose.Waist = CFrame.Angles(0, math.clamp(math.atan2(-flatD.X, -flatD.Z), -0.6, 0.6), 0)
		end
		if d.X >= 0 then
			pose.RShoulder = arm
		else
			pose.LShoulder = arm
		end
		pose.rate = 30
	end

	-- celebrations
	if ctx.celebrate ~= "" and ctx.celebrateAge < 3 then
		local a = ctx.celebrateAge
		if ctx.celebrate == "Point" then
			pose.RShoulder = CFrame.Angles(2.9, 0, 0.3)
		elseif ctx.celebrate == "Flex" then
			pose.RShoulder = CFrame.Angles(0, 0, 1.6)
			pose.LShoulder = CFrame.Angles(0, 0, -1.6)
		elseif ctx.celebrate == "Bow" then
			pose.drop, pose.pitch, pose.roll = 0, -0.8, 0
			pose.RShoulder = CFrame.Angles(0.4, 0, 0)
		elseif ctx.celebrate == "Spin" then
			pose.drop, pose.pitch, pose.roll = 0, 0, 0
			pose.yaw = a * 12
			pose.RShoulder = CFrame.Angles(2.9, 0, 0.2)
		elseif ctx.celebrate == "Slide" then
			pose.drop, pose.pitch, pose.roll = 1.5, 0.5, 0
			pose.legs = "slide"
			pose.RShoulder = CFrame.Angles(2.6, 0, 0.6)
			pose.LShoulder = CFrame.Angles(2.6, 0, -0.6)
		end
		pose.rate = 14
	end

	-- head tracks the disc
	local look = ctx.lookAt
	if look and look.Magnitude > 0.1 then
		local yaw = math.clamp(math.atan2(-look.X, -look.Z), -1.1, 1.1)
		local pitch = math.clamp(math.atan2(look.Y, Vector3.new(look.X, 0, look.Z).Magnitude), -0.6, 0.7)
		pose.Neck = CFrame.Angles(pitch, yaw, 0)
	end
	return pose
end

---------------------------------------------------------------------------
-- legs
---------------------------------------------------------------------------

-- Symmetric bend that shortens a straight leg by `drop` while countering the
-- pelvis pitch (and half its roll: the legs still lean into a cut), so the
-- animated legs keep their feet on the ground under the body. Without a drop
-- (a plain running lean) the whole body tilts instead, which only lifts the
-- feet a little; the counter fades in over the first 0.2 studs of drop.
local function freeLeg(leg: Leg, drop: number, pitch: number, roll: number): (CFrame, CFrame, CFrame)
	local reach = leg.thigh + leg.shin
	local d = math.max(drop, 0)
	local theta = math.acos(math.clamp(1 - d / reach, -1, 1))
	local counter = math.clamp(d / 0.2, 0, 1)
	local hip = CFrame.Angles(pitch * counter, 0, roll * 0.5 * counter):Inverse() * CFrame.Angles(theta, 0, 0)
	return hip, CFrame.Angles(-2 * theta, 0, 0), CFrame.Angles(theta, 0, 0)
end

-- Two-bone IK: hip / knee / ankle rotations that put the sole at `foot`
-- (HRP space) with the knee bending forward and the foot kept flat.
local function solveLeg(leg: Leg, lt: CFrame, ltRest: CFrame, foot: Vector3): (CFrame, CFrame, CFrame)
	local a, b = leg.thigh, leg.shin
	local hipP = lt:PointToWorldSpace(leg.hipPos)
	local ankleP = foot + Vector3.new(0, leg.ankleHeight, 0)
	local toAnkle = ankleP - hipP
	local dist = math.clamp(toAnkle.Magnitude, math.abs(a - b) + 0.01, a + b - 0.001)
	local dir = if toAnkle.Magnitude > 1e-4 then toAnkle.Unit else DOWN
	local pole = Vector3.new(0, 0, -1)
	local perp = pole - dir * pole:Dot(dir)
	perp = if perp.Magnitude > 1e-3 then perp.Unit else Vector3.new(0, 0, -1)
	local cosA = math.clamp((a * a + dist * dist - b * b) / (2 * a * dist), -1, 1)
	local alpha = math.acos(cosA)
	local thighDir = dir * math.cos(alpha) + perp * math.sin(alpha)
	local kneeP = hipP + thighDir * a
	local shinDir = (hipP + dir * dist) - kneeP
	shinDir = if shinDir.Magnitude > 1e-4 then shinDir.Unit else thighDir

	local ltRot = lt.Rotation
	local hipRot = arc(leg.thighRest, ltRot:VectorToObjectSpace(thighDir))
	local ulRot = ltRot * hipRot * leg.hipRestRot
	local kneeRot = arc(leg.shinRest, ulRot:VectorToObjectSpace(shinDir))
	local llRot = ulRot * kneeRot * leg.kneeRestRot
	local llRest = ltRest.Rotation * leg.hipRestRot * leg.kneeRestRot
	return hipRot, kneeRot, llRot:Inverse() * llRest
end

-- Foot target (HRP space) for the standing poses, plus the side-shuffle
-- offset (applied after smoothing so it is not damped away).
local function stanceFoot(rig: Rig, leg: Leg, pose: Pose, ctx: Ctx, groundY: number): (Vector3, Vector3)
	local base = Vector3.new(leg.restFoot.X, groundY, leg.restFoot.Z)
	if pose.stance == "lunge" then
		-- the pivot foot stays at P, the stepping foot goes to P + step (the
		-- root sits BodyShare of the way). The stepping leg is the one on the
		-- step's side so the legs never cross; squared up it is the throwing
		-- side's leg.
		local share = if leg.side == rig.freeSide then 1 - HD.BodyShare else -HD.BodyShare
		return base + Vector3.new(pose.step.X, 0, pose.step.Z) * share, Vector3.zero
	end
	local wide = if pose.stance == "wide" then 0.8 else 0.35
	local target = base + Vector3.new(leg.side * wide, 0, 0)
	-- side-shuffle: each foot swings with the travel and lifts while it does
	local v = ctx.localVel
	local speed = v.Magnitude
	if speed <= 1 then
		return target, Vector3.zero
	end
	local k = math.clamp(speed / 4, 0, 1)
	local phase = rig.shufflePhase + (if leg.side > 0 then 0 else math.pi)
	local swing = v.Unit * (SHUFFLE_AMPLITUDE * k * math.sin(phase))
	return target, Vector3.new(swing.X, SHUFFLE_LIFT * k * math.max(0, math.cos(phase)), swing.Z)
end

-- Keeps a foot target inside what the leg can reach from its hip at the
-- current drop, so the IK always plants it (a wide step shortens the visual
-- stance a little instead of leaving a foot hovering).
local function withinReach(leg: Leg, lt: CFrame, foot: Vector3, groundY: number): Vector3
	local hip = lt:PointToWorldSpace(leg.hipPos)
	local vertical = hip.Y - (groundY + leg.ankleHeight)
	local reach = leg.thigh + leg.shin
	local maxFlat = math.sqrt(math.max(0, reach * reach - vertical * vertical)) * 0.96
	local rel = Vector3.new(foot.X - hip.X, 0, foot.Z - hip.Z)
	if rel.Magnitude <= maxFlat then
		return foot
	end
	local clamped = if rel.Magnitude > 1e-4 then rel.Unit * maxFlat else Vector3.zero
	return Vector3.new(hip.X + clamped.X, foot.Y, hip.Z + clamped.Z)
end

local function poseLegs(rig: Rig, pose: Pose, ctx: Ctx, rootCur: CFrame, dt: number)
	if #rig.legs == 0 then
		return
	end
	local rootBase = (bases[rig.joints.Root.motor] :: BaseEntry).base
	local c1Inv = rig.rootC1:Inverse()
	local lt = CFrame.new(rootBase.Position) * rootCur * rootBase.Rotation * c1Inv
	local ltRest = rootBase * c1Inv
	local groundY = -(rig.humanoid.HipHeight + rig.root.Size.Y / 2)
	-- the inputs (drop, pitch, foot targets) are already smoothed, so legs are
	-- exact in a steady pose and only blend right after switching pose kind
	local clock = os.clock()
	if pose.legs ~= rig.legMode then
		rig.legMode = pose.legs
		rig.legSwitchAt = clock
	end
	local alpha = if clock - rig.legSwitchAt < LEG_BLEND_TIME then 1 - math.exp(-LEG_RATE * dt) else 1
	local footAlpha = 1 - math.exp(-pose.rate * dt)
	if pose.stance == "wide" or pose.stance == "high" then
		local speed = ctx.localVel.Magnitude
		rig.shufflePhase = (rig.shufflePhase + speed / SHUFFLE_AMPLITUDE * dt) % (2 * math.pi)
	elseif pose.stance == "lunge" then
		-- which leg steps out, with hysteresis around the front
		local sx = pose.step.X
		if pose.step.Magnitude < 0.25 * HD.StepRadius then
			rig.freeSide = if ctx.leftHanded then -1 else 1
		elseif sx > 0.3 then
			rig.freeSide = 1
		elseif sx < -0.3 then
			rig.freeSide = -1
		end
	end
	for _, leg in rig.legs do
		local hip, knee, ankle = IDENTITY, IDENTITY, IDENTITY
		if pose.legs == "stance" then
			local target, shuffle = stanceFoot(rig, leg, pose, ctx, groundY)
			local prev = leg.foot
			local foot = if prev then prev:Lerp(target, footAlpha) else target
			leg.foot = foot
			hip, knee, ankle = solveLeg(leg, lt, ltRest, withinReach(leg, lt, foot + shuffle, groundY))
		else
			leg.foot = nil
			if pose.legs == "free" then
				hip, knee, ankle = freeLeg(leg, rig.drop, rig.pitch, rig.roll)
			elseif pose.legs == "slide" then
				hip = CFrame.Angles(1.35 - rig.pitch, 0, 0)
				knee = CFrame.Angles(-0.25, 0, 0)
			end
		end
		leg.hip.current = leg.hip.current:Lerp(hip, alpha)
		leg.knee.current = leg.knee.current:Lerp(knee, alpha)
		write(leg.hip)
		write(leg.knee)
		local aj = leg.ankle
		if aj then
			aj.current = aj.current:Lerp(ankle, alpha)
			write(aj)
		end
	end
end

local function apply(rig: Rig, pose: Pose, ctx: Ctx, dt: number)
	local alpha = 1 - math.exp(-pose.rate * dt)
	-- R6 has no knees: never lower it while it stands
	local drop = pose.drop
	if (not rig.r15 or #rig.legs == 0) and (pose.legs == "free" or pose.legs == "stance") then
		drop = 0
	end
	rig.drop += (drop - rig.drop) * alpha
	rig.pitch += (pose.pitch - rig.pitch) * alpha
	rig.roll += (pose.roll - rig.roll) * alpha
	local rootCur = CFrame.new(0, -rig.drop, 0) * CFrame.Angles(rig.pitch, pose.yaw, rig.roll)

	for key, joint in rig.joints do
		if key == "Root" then
			joint.current = rootCur
		else
			local target: CFrame = (pose :: any)[key] or IDENTITY
			joint.current = joint.current:Lerp(target, alpha)
		end
		write(joint)
	end
	poseLegs(rig, pose, ctx, rootCur, dt)
end

local function changed(rig: Rig): boolean
	for _, j in rig.joints do
		if externallyChanged(j.motor) then
			return true
		end
	end
	for _, leg in rig.legs do
		if externallyChanged(leg.hip.motor) or externallyChanged(leg.knee.motor) then
			return true
		end
	end
	return false
end

local function step(dt: number)
	local camPos = workspace.CurrentCamera.CFrame.Position
	local seen: { [Model]: boolean } = {}
	for _, model in Actors.characters() do
		seen[model] = true
		local rig: Rig? = rigs[model]
		if rig and (rig.root.Parent ~= model or changed(rig)) then
			-- avatar rescaled / rebuilt: the new C0s are the rest pose now
			rigs[model] = nil
			rig = nil
		end
		if not rig then
			-- wait for avatars to finish loading (scaling rewrites joint C0s)
			local seenAt = firstSeen[model]
			if not seenAt then
				firstSeen[model] = os.clock()
				continue
			end
			local owner = Players:GetPlayerFromCharacter(model)
			if os.clock() - seenAt < 1.0 or (owner and not owner:HasAppearanceLoaded() and os.clock() - seenAt < 6) then
				continue
			end
			local built = buildRig(model)
			if not built then
				continue
			end
			rigs[model] = built
			rig = built
		end
		local r = rig :: Rig
		r.seenAt = os.clock()
		if (r.root.Position - camPos).Magnitude > 300 then
			continue
		end
		local ok, err = pcall(function()
			local ctx = gather(r, dt)
			apply(r, compute(ctx), ctx, dt)
		end)
		if not ok then
			if not warned[model] then
				warned[model] = true
				warn("[PoseController] " .. tostring(err))
			end
			pcall(restoreRig, r)
			rigs[model] = nil
			firstSeen[model] = os.clock() -- retry after the usual short wait
		end
	end
	-- a model missing for a moment keeps its rig; gone for good, it is restored
	local clock = os.clock()
	for model, rig in rigs do
		if not seen[model] and (model.Parent == nil or clock - rig.seenAt > 1) then
			pcall(restoreRig, rig)
			rigs[model] = nil
		end
	end
	for model in firstSeen do
		if not seen[model] and rigs[model] == nil then
			firstSeen[model] = nil
		end
	end
end

function PoseController.Init(c: any)
	controllers = c
end

function PoseController.Start()
	controllers.MovementController.Tech:Connect(function(e)
		local name = if e.tech == "FakeCommit" then "Lean" else e.tech
		localTech = { name = name, t = now(), dir = e.dir }
	end)
	player.CharacterAdded:Connect(function()
		localTech = { name = "", t = -math.huge, dir = Vector3.zero }
	end)
	RunService:BindToRenderStep("UBPose", Enum.RenderPriority.Character.Value + 1, step)
end

return PoseController
