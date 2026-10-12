--!strict
--[[
	PoseController — procedural body language for every character.

	Base locomotion comes from animations (src/character/Animate, BotService).
	On top, each client rotates Motor6D.C0 offsets of the root, waist, neck and
	shoulders so that what you see matches what the movement engine is doing:
	  leaning into acceleration and turns, the dip of a Snap Cut, the sit-back
	  of a Momentum Cancel, the forward sell of a Fake Commit or Burst, the
	  feet-first Slide, the horizontal Layout, the reach toward the disc, the
	  throw windup / follow-through (identical for real throws and fakes), mark
	  stances (wide-low or high hands) and celebrations. Heads track the disc.

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

local PoseController = {}

local controllers: any
local player = Players.LocalPlayer

type Joint = { motor: Motor6D, base: CFrame, current: CFrame }
type Rig = {
	model: Model,
	root: BasePart,
	joints: { [string]: Joint },
	lastVel: Vector3,
	accel: Vector3,
	isLocal: boolean,
}

local rigs: { [Model]: Rig } = {}
local firstSeen: { [Model]: number } = {}
local localTech = { name = "", t = -math.huge, dir = Vector3.zero }

local R15_JOINTS = {
	Root = { "LowerTorso", "Root" },
	Waist = { "UpperTorso", "Waist" },
	Neck = { "Head", "Neck" },
	RShoulder = { "RightUpperArm", "RightShoulder" },
	LShoulder = { "LeftUpperArm", "LeftShoulder" },
}

local R6_JOINTS = {
	Root = { "HumanoidRootPart", "RootJoint" },
	Neck = { "Torso", "Neck" },
	RShoulder = { "Torso", "Right Shoulder" },
	LShoulder = { "Torso", "Left Shoulder" },
}

local IDENTITY = CFrame.identity
local DOWN = Vector3.new(0, -1, 0)

local function now(): number
	return Net.now()
end

local function buildRig(model: Model): Rig?
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return nil
	end
	local map: { [string]: { string } } = if humanoid.RigType == Enum.HumanoidRigType.R15 then R15_JOINTS else R6_JOINTS
	local joints: { [string]: Joint } = {}
	for key, path in map do
		local partInst = model:FindFirstChild(path[1])
		local motor = partInst and partInst:FindFirstChild(path[2])
		if motor and motor:IsA("Motor6D") then
			joints[key] = { motor = motor, base = motor.C0, current = IDENTITY }
		end
	end
	if not joints.Root then
		return nil
	end
	return {
		model = model,
		root = root,
		joints = joints,
		lastVel = root.AssemblyLinearVelocity,
		accel = Vector3.zero,
		isLocal = model == player.Character,
	}
end

-- rotation taking the hanging arm (0,-1,0) to point along local direction d
local function aimArm(d: Vector3): CFrame
	local dir = if d.Magnitude > 0.01 then d.Unit else DOWN
	local axis = DOWN:Cross(dir)
	local dot = math.clamp(DOWN:Dot(dir), -1, 1)
	if axis.Magnitude < 1e-4 then
		return if dot > 0 then IDENTITY else CFrame.Angles(math.pi, 0, 0)
	end
	return CFrame.fromAxisAngle(axis.Unit, math.acos(dot))
end

local function attrNumber(model: Model, key: string): number
	local v = model:GetAttribute(key)
	return if type(v) == "number" then v else -math.huge
end

type Ctx = {
	mode: string,
	speed: number,
	fwdAccel: number,
	latAccel: number,
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
	celebrate: string,
	celebrateAge: number,
	leftHanded: boolean,
	lookAt: Vector3?, -- local space
}

local function toLocal(root: BasePart, v: Vector3): Vector3
	return root.CFrame:VectorToObjectSpace(v)
end

local function gather(rig: Rig, dt: number): Ctx
	local m = rig.model
	local root = rig.root
	local t = now()
	local vel = root.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local rawAccel = (vel - rig.lastVel) / math.max(dt, 1 / 240)
	rig.lastVel = vel
	rig.accel = rig.accel:Lerp(Vector3.new(rawAccel.X, 0, rawAccel.Z), math.min(1, dt * 10))
	local localAccel = toLocal(root, rig.accel)

	local ctx: Ctx = {
		mode = "Ground",
		speed = flat.Magnitude,
		fwdAccel = -localAccel.Z,
		latAccel = localAccel.X,
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
		celebrate = "",
		celebrateAge = math.huge,
		leftHanded = m:GetAttribute("LeftHanded") == true,
		lookAt = nil,
	}

	if rig.isLocal then
		local sim = controllers.MovementController.sim()
		ctx.mode = sim.mode
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
		ctx.holding = controllers.ThrowController.isHolding()
	else
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
	end
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

type Pose = { Root: CFrame, Waist: CFrame, Neck: CFrame, RShoulder: CFrame, LShoulder: CFrame, rate: number }

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
		Root = IDENTITY,
		Waist = IDENTITY,
		Neck = IDENTITY,
		RShoulder = IDENTITY,
		LShoulder = IDENTITY,
		rate = 12,
	}
	-- base lean from speed, acceleration and turning
	local lean = -math.clamp(ctx.speed / 26, 0, 1) * 0.12 - math.clamp(ctx.fwdAccel / 90, -0.15, 0.22)
	local roll = -math.clamp(ctx.latAccel / 130, -0.32, 0.32)
	local rootCF = CFrame.Angles(lean, 0, roll)

	local age = ctx.techAge
	local tech = ctx.tech
	local dx = ctx.techDir.X
	if tech == "SnapCut" and age < 0.22 then
		rootCF = CFrame.new(0, -0.3, 0) * CFrame.Angles(lean - 0.1, 0, -math.sign(dx) * 0.45)
		pose.rate = 26
	elseif tech == "SlideCut" and age < 0.22 then
		rootCF = CFrame.new(0, -0.5, 0) * CFrame.Angles(-0.2, 0, -math.sign(dx) * 0.5)
		pose.rate = 26
	elseif tech == "MomentumCancel" and age < 0.3 then
		rootCF = CFrame.new(0, -0.6, 0) * CFrame.Angles(0.38, 0, 0)
		pose.rate = 26
	elseif (tech == "Lean" or tech == "FakeCommit" or tech == "BurstStep") and age < 0.25 then
		rootCF = CFrame.new(0, -0.2, 0) * CFrame.Angles(-0.45, 0, -math.clamp(dx, -1, 1) * 0.3)
		pose.rate = 28
	elseif tech == "AirRedirect" and age < 0.3 then
		rootCF = CFrame.Angles(-0.2, 0, -math.sign(dx) * 0.4)
		pose.rate = 22
	elseif tech == "PrecisionLanding" and age < 0.16 then
		rootCF = CFrame.new(0, -0.8, 0) * CFrame.Angles(-0.15, 0, 0)
		pose.rate = 30
	elseif tech == "WallRebound" and age < 0.3 then
		rootCF = CFrame.Angles(0.2, 0, -math.sign(dx) * 0.5)
		pose.rate = 24
	end

	local mode = ctx.mode
	local airUp = false
	if mode == "Slide" then
		rootCF = CFrame.new(0, -1.7, 0) * CFrame.Angles(0.95, 0, 0)
		pose.LShoulder = CFrame.Angles(0.9, 0, -0.7)
		pose.rate = 20
	elseif mode == "Dive" then
		rootCF = CFrame.new(0, -0.5, 0) * CFrame.Angles(-1.35, 0, 0)
		pose.RShoulder = CFrame.Angles(2.95, 0, 0.12)
		pose.LShoulder = CFrame.Angles(2.95, 0, -0.12)
		pose.rate = 18
	elseif mode == "DiveSlide" then
		rootCF = CFrame.new(0, -2.1, 0) * CFrame.Angles(-1.47, 0, 0)
		pose.RShoulder = CFrame.Angles(2.95, 0, 0.12)
		pose.LShoulder = CFrame.Angles(2.95, 0, -0.12)
		pose.rate = 22
	elseif mode == "Recover" then
		rootCF = CFrame.new(0, -1.2, 0) * CFrame.Angles(-0.6, 0, 0)
		pose.rate = 16
	elseif mode == "Air" then
		airUp = true
	end

	-- mark stance
	if ctx.mark == "Low" then
		rootCF = CFrame.new(0, -0.45, 0) * CFrame.Angles(-0.12, 0, 0)
		pose.RShoulder = CFrame.Angles(0.1, 0, 1.4)
		pose.LShoulder = CFrame.Angles(0.1, 0, -1.4)
		pose.rate = 18
	elseif ctx.mark == "High" then
		pose.RShoulder = CFrame.Angles(2.85, 0, 0.25)
		pose.LShoulder = CFrame.Angles(2.85, 0, -0.25)
		pose.rate = 18
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
		pose.rate = 22
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
			local m = throwArm
			local rx, ry, rz = m:ToEulerAnglesXYZ()
			pose.LShoulder = CFrame.Angles(rx, -ry, -rz)
		else
			pose.RShoulder = throwArm
		end
	end

	-- reach: point the near arm at the disc
	if ctx.reachAge < 0.35 and not ctx.holding then
		local d = ctx.reachDir
		local arm = aimArm(d)
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
			rootCF = CFrame.Angles(-0.8, 0, 0)
			pose.RShoulder = CFrame.Angles(0.4, 0, 0)
		elseif ctx.celebrate == "Spin" then
			rootCF = CFrame.Angles(0, a * 12, 0)
			pose.RShoulder = CFrame.Angles(2.9, 0, 0.2)
		elseif ctx.celebrate == "Slide" then
			rootCF = CFrame.new(0, -1.5, 0) * CFrame.Angles(0.5, 0, 0)
			pose.RShoulder = CFrame.Angles(2.6, 0, 0.6)
			pose.LShoulder = CFrame.Angles(2.6, 0, -0.6)
		end
		pose.rate = 14
	end
	pose.Root = rootCF

	-- head tracks the disc
	local look = ctx.lookAt
	if look and look.Magnitude > 0.1 then
		local yaw = math.clamp(math.atan2(-look.X, -look.Z), -1.1, 1.1)
		local pitch = math.clamp(math.atan2(look.Y, Vector3.new(look.X, 0, look.Z).Magnitude), -0.6, 0.7)
		pose.Neck = CFrame.Angles(pitch, yaw, 0)
	end
	return pose
end

local function apply(rig: Rig, pose: Pose, dt: number)
	local alpha = 1 - math.exp(-pose.rate * dt)
	for key, joint in rig.joints do
		local target: CFrame = (pose :: any)[key] or IDENTITY
		joint.current = joint.current:Lerp(target, alpha)
		local base = joint.base
		joint.motor.C0 = CFrame.new(base.Position) * joint.current * base.Rotation
	end
end

local function step(dt: number)
	local camPos = workspace.CurrentCamera.CFrame.Position
	local seen: { [Model]: boolean } = {}
	for _, model in Actors.characters() do
		seen[model] = true
		local rig = rigs[model]
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
		if (r.root.Position - camPos).Magnitude > 300 then
			continue
		end
		local ok, err = pcall(function()
			apply(r, compute(gather(r, dt)), dt)
		end)
		if not ok then
			warn("[PoseController] " .. tostring(err))
			rigs[model] = nil
		end
	end
	for model in rigs do
		if not seen[model] then
			rigs[model] = nil
		end
	end
	for model in firstSeen do
		if not seen[model] then
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
