--!strict
--[[
	MovementController — runs MovementSim for the local character.

	Each frame it builds an environment snapshot with raycasts (grounded,
	time-to-land, a Rebound wall beside you, offset from your pivot), steps the
	sim and applies the result:
	  * horizontal velocity via a LinearVelocity constraint in Plane mode
	    (exact, frame-responsive control; vertical is left to physics)
	  * jumps / dives / air-redirect hangs by setting vertical velocity
	  * facing via AlignOrientation (camera while aiming/holding/marking,
	    travel direction otherwise)
	Technique events go to the server in one small batch per frame (only when
	something happened) and to the local effects/combo UI immediately.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MovementSim = require(Shared.Movement.MovementSim)
local ComboEvaluator = require(Shared.Rules.ComboEvaluator)
local VecMath = require(Shared.Util.VecMath)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local MovementController = {}

MovementController.Tech = Signal.new() -- (event)
MovementController.Feedback = Signal.new() -- (feedback)
MovementController.Landed = Signal.new() -- (fromDive: boolean, speed: number)
MovementController.ComboChanged = Signal.new() -- (chain total, last points, event)

local controllers: any
local player = Players.LocalPlayer

local sim: MovementSim.State = MovementSim.new(0)
local character: Model? = nil
local humanoid: Humanoid? = nil
local root: BasePart? = nil
local lv: LinearVelocity? = nil
local ao: AlignOrientation? = nil
local standHeight = 3
local pivot: Vector3? = nil
local holding = false
local lastMode = ""
local lastTeleport: any = nil
local pending: { any } = {}
local combo = ComboEvaluator.newTracker()
local lastFacing = Vector3.new(0, 0, -1)

local MOVEMENT_ACTIONS = { Jump = true, Cut = true, Slide = true, Dive = true, Burst = true }

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function now(): number
	return Net.now()
end

function MovementController.sim(): MovementSim.State
	return sim
end

function MovementController.pivot(): Vector3?
	return pivot
end

function MovementController.root(): BasePart?
	return root
end

function MovementController.standHeight(): number
	return standHeight
end

function MovementController.combo(): ComboEvaluator.Tracker
	return combo
end

function MovementController.isGrounded(): boolean
	return not MovementSim.isAirborne(sim)
end

local function filter()
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	for _, name in { "UBBots", "UBVisuals" } do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	rayParams.FilterDescendantsInstances = list
end

local function buildEnv(): MovementSim.Env
	local r = root :: BasePart
	local pos = r.Position
	local vel = r.AssemblyLinearVelocity
	local hit = workspace:Raycast(pos, Vector3.new(0, -(standHeight + 0.6), 0), rayParams)
	local grounded = hit ~= nil and vel.Y <= 2.5
	local ttl: number? = nil
	if not grounded then
		local far = workspace:Raycast(pos, Vector3.new(0, -120, 0), rayParams)
		if far then
			local h = math.max(0, pos.Y - standHeight - far.Position.Y)
			local g = workspace.Gravity
			ttl = (vel.Y + math.sqrt(math.max(vel.Y * vel.Y + 2 * g * h, 0))) / g
		end
	end
	local wallNormal: Vector3? = nil
	local wallDistance: number? = nil
	local wallId: string? = nil
	if not grounded then
		local dirs = { VecMath.flatUnit(vel), VecMath.flatUnit(r.CFrame.LookVector) }
		for _, d in dirs do
			if d.Magnitude > 0.5 then
				local w = workspace:Raycast(pos, d * 3, rayParams)
				if w and CollectionService:HasTag(w.Instance, "Rebound") then
					wallNormal = VecMath.flatUnit(w.Normal)
					wallDistance = w.Distance
					wallId = w.Instance:GetFullName()
					break
				end
			end
		end
	end
	return {
		grounded = grounded,
		actualVel = vel,
		timeToLand = ttl,
		wallNormal = wallNormal,
		wallDistance = wallDistance,
		wallId = wallId,
		pivotOffset = if pivot then pos - (pivot :: Vector3) else nil,
		facing = r.CFrame.LookVector,
	}
end

local function currentInput(): MovementSim.Input
	return {
		move = controllers.InputController.moveVector(),
		sprint = controllers.InputController.sprinting(),
	}
end

local function queueEvent(e: MovementSim.TechEvent)
	table.insert(pending, { tech = e.tech, quality = e.quality, dir = e.dir, info = e.info })
	local points, total = ComboEvaluator.add(combo, e.tech, e.quality, now())
	MovementController.Tech:Fire(e)
	MovementController.ComboChanged:Fire(total, points, e)
end

function MovementController.noteAerialReach(dir: Vector3)
	MovementSim.noteAerialReach(sim, dir)
end

local function setupCharacter(c: Model)
	character = c
	local h = c:WaitForChild("Humanoid", 10) :: Humanoid?
	local r = c:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not h or not r then
		return
	end
	humanoid = h
	root = r
	h.AutoRotate = false
	h.WalkSpeed = 0
	h.UseJumpPower = true
	h.JumpPower = 0
	-- states that would fight the movement engine
	for _, st in
		{
			Enum.HumanoidStateType.Climbing,
			Enum.HumanoidStateType.Seated,
			Enum.HumanoidStateType.Ragdoll,
			Enum.HumanoidStateType.FallingDown,
		}
	do
		h:SetStateEnabled(st, false)
	end
	standHeight = if h.RigType == Enum.HumanoidRigType.R15 then h.HipHeight + r.Size.Y / 2 else 3

	local att = Instance.new("Attachment")
	att.Name = "UBMoveAttachment"
	att.Parent = r

	local linear = Instance.new("LinearVelocity")
	linear.Name = "UBMove"
	linear.Attachment0 = att
	linear.RelativeTo = Enum.ActuatorRelativeTo.World
	linear.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	linear.PrimaryTangentAxis = Vector3.new(1, 0, 0)
	linear.SecondaryTangentAxis = Vector3.new(0, 0, 1)
	linear.PlaneVelocity = Vector2.zero
	linear.MaxForce = math.max(r.AssemblyMass, 8) * 900
	linear.Parent = r
	lv = linear

	local align = Instance.new("AlignOrientation")
	align.Name = "UBFace"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = false
	align.Responsiveness = 45
	align.MaxTorque = 1e7
	align.MaxAngularVelocity = 40
	align.CFrame = r.CFrame.Rotation
	align.Parent = r
	ao = align
	lastFacing = VecMath.flatUnit(r.CFrame.LookVector)

	sim = MovementSim.new(now())
	pivot = nil
	holding = false
	lastMode = ""
	lastTeleport = c:GetAttribute("UBTeleport")
	h.Died:Connect(function()
		if lv then
			lv.Enabled = false
		end
		if ao then
			ao.Enabled = false
		end
	end)
end

local function step(dtRaw: number)
	local c, h, r = character, humanoid, root
	if not c or not h or not r or not r.Parent or h.Health <= 0 or not lv or not ao then
		return
	end
	local dt = math.min(dtRaw, 1 / 15)
	sim.now = now() - dt -- keep the sim clock on server time

	local frozen = c:GetAttribute("UBFrozen") == true
	if frozen ~= sim.frozen then
		MovementSim.setFrozen(sim, frozen)
	end
	local tp = c:GetAttribute("UBTeleport")
	if tp ~= lastTeleport then
		lastTeleport = tp
		MovementSim.reset(sim)
		pivot = nil
		local lvv = VecMath.flatUnit(r.CFrame.LookVector)
		if lvv.Magnitude > 0.5 then
			controllers.CameraController.setYaw(math.atan2(-lvv.X, -lvv.Z))
			lastFacing = lvv
		end
	end

	filter()
	local env = buildEnv()
	local nowHolding = controllers.ThrowController.isHolding()
	if nowHolding ~= holding then
		holding = nowHolding
		MovementSim.setHolding(sim, holding, env.grounded)
		if not holding then
			pivot = nil
		end
	end

	local out = MovementSim.step(sim, currentInput(), env, dt)

	local linear = lv :: LinearVelocity
	linear.MaxForce = math.max(r.AssemblyMass, 8) * 900
	linear.PlaneVelocity = Vector2.new(out.vel.X, out.vel.Z)
	if out.jump and out.setVertical then
		h.JumpPower = out.setVertical
		h:ChangeState(Enum.HumanoidStateType.Jumping)
		local v = r.AssemblyLinearVelocity
		r.AssemblyLinearVelocity = Vector3.new(v.X, out.setVertical, v.Z)
	elseif out.setVertical then
		local v = r.AssemblyLinearVelocity
		r.AssemblyLinearVelocity = Vector3.new(v.X, out.setVertical, v.Z)
	end

	-- facing
	local face: Vector3? = nil
	local aiming = holding
		or controllers.ThrowController.isCharging()
		or controllers.CatchController.isMarking()
		or controllers.CatchController.reachActive()
	if aiming then
		face = controllers.CameraController.forward()
	elseif sim.mode == "Dive" or sim.mode == "DiveSlide" then
		face = sim.diveDir
	elseif out.vel.Magnitude > 2 then
		face = VecMath.flatUnit(out.vel)
	end
	if face and face.Magnitude > 0.5 then
		lastFacing = face
	end
	(ao :: AlignOrientation).CFrame = CFrame.lookAt(Vector3.zero, lastFacing)

	for _, e in out.events do
		queueEvent(e)
	end
	for _, fb in out.feedback do
		if fb.kind == "HopLanded" and holding then
			MovementController.Feedback:Fire({ kind = "Travel" })
		else
			MovementController.Feedback:Fire(fb)
		end
	end
	if out.pivotEstablished then
		pivot = r.Position
	end
	if out.landed then
		MovementController.Landed:Fire(sim.landedFromDive, sim.landingVel.Magnitude)
	end
	local modeChanged = sim.mode ~= lastMode
	if modeChanged then
		lastMode = sim.mode
		c:SetAttribute("UB_LocalMode", sim.mode)
	end
	if #pending > 0 or modeChanged then
		Net.event("Tech"):FireServer(pending, sim.mode)
		pending = {}
	end
	ComboEvaluator.expire(combo, now())
end

function MovementController.Init(c: any)
	controllers = c
end

function MovementController.Start()
	controllers.InputController.ActionBegan:Connect(function(action)
		if not MOVEMENT_ACTIONS[action] or not root or not character then
			return
		end
		if controllers.InputController.menuOpen() then
			return
		end
		filter()
		MovementSim.press(sim, action :: any, currentInput(), buildEnv())
	end)
	player.CharacterAdded:Connect(setupCharacter)
	if player.Character then
		task.spawn(setupCharacter, player.Character)
	end
	RunService:BindToRenderStep("UBMovement", Enum.RenderPriority.Input.Value + 1, step)
end

return MovementController
