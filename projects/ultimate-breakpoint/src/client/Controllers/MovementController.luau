--!strict
--[[
	MovementController — runs MovementSim for the local character.

	THE SIM DECIDES, THE HUMANOID MOVES. Each frame it builds an environment
	snapshot (grounded from Humanoid.FloorMaterial plus a ray sized from the
	current HipHeight, 1.2 studs past the feet on the ground but only 0.3 in
	the air so dives and hops land on touchdown, time-to-land, Rebound walls along / beside you, a short
	"blocked" ray along the sim velocity, root position and camera yaw), steps
	the sim and drives the body with the Humanoid's own controller:
	  * Humanoid.WalkSpeed = |v| and Humanoid:Move(v.Unit) every frame, so the
	    engine never brakes against us and steps, seams and slopes just work
	  * on impulse frames (technique starts, plant restarts, jumps ...) it also
	    writes AssemblyLinearVelocity so the change lands on the frame pressed
	  * jumps set JumpPower = vy + ChangeState(Jumping) + a direct Y write;
	    JumpPower goes back to 0 the next frame (no engine jumps otherwise)
	  * facing via AlignOrientation (AutoRotate off): camera forward while
	    holding / aiming / marking (snappy), travel direction otherwise
	    (smoother), the reach direction while reaching for the disc

	Holding the disc: the slow-down starts as soon as CatchController claims a
	catch (predicted; cancelled on Denied, when the claimed disc leaves Flight
	without becoming ours, e.g. a scoring catch, or when the server never
	confirms).
	While holding, Cut swings to the screen-left side, Dive to the right
	(gamepad X: the mirror of the current step), Jump hops. The sim plants the
	pivot foot and Output.pivotPos goes to the server (Pivot remote; proposed
	once more after the server confirms a predicted catch); the server's
	authoritative UBPivot attribute is adopted every frame.

	Server protocols handled here: teleports (UBTeleport counter with
	UBTeleportPos / Yaw / Face: the root is placed if it is still > 1 stud
	away, momentum reset but frozen / holding / exertion / pivot kept, camera
	yaw only when Face), lineups (UBLineX / UBLineSide: the body never crosses
	its own goal line, and eases back if it is beyond), UBFrozen.

	Technique events go to the server in one small batch per frame (only when
	something happened, each with its timestamp) and to the local effects /
	combo UI immediately. The replicated pose mode (UB_LocalMode locally, MS on
	the server) is MovementSim.poseMode: the sim mode, or Pivot / Mark.

	If the per-frame step ever errors, the body is stopped (no runaway
	character) and the error is reported once.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MovementSim = require(Shared.Movement.MovementSim)
local MovementConfig = require(Shared.Config.Movement)
local ComboEvaluator = require(Shared.Rules.ComboEvaluator)
local Signatures = require(Shared.Rules.Signatures)
local VecMath = require(Shared.Util.VecMath)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local MovementController = {}

MovementController.Tech = Signal.new() -- (event)
MovementController.Feedback = Signal.new() -- ({ kind, value?, text? })
MovementController.Landed = Signal.new() -- (fromDive: boolean, speed: number)
MovementController.ComboChanged = Signal.new() -- (chain total, last points, event)
MovementController.ChainEnded = Signal.new() -- (ComboEvaluator.Summary)
MovementController.SignatureHit = Signal.new() -- (Signatures.Hit) a signature move, recognised locally

local controllers: any
local player = Players.LocalPlayer

local sim: MovementSim.State = MovementSim.new(0)
local character: Model? = nil
local humanoid: Humanoid? = nil
local root: BasePart? = nil
local ao: AlignOrientation? = nil
local aoAiming: boolean? = nil
local standHeight = 3
local holding = false
local confirmedHold = false -- the server has given us the disc (not just predicted)
local pivotResent = false -- re-proposed our pivot after the confirmation
local predicted: { disc: any, untilT: number }? = nil
local lastMode = ""
local modeDirty = false
local lastTeleport: any = nil
local pending: { any } = {}
local combo = ComboEvaluator.newTracker()
-- signature moves, recognised locally for instant feedback (the server
-- recognises them again on validated events and pays out)
local signatures = Signatures.new()
local lastAirHeight = 0 -- feet above the ground below, while airborne
-- whether you were in the air at each catch claim (the confirmation comes a
-- round trip later, often after landing)
local claimAir: { [string]: { airborne: boolean, height: number, t: number } } = {}
local lastFacing = Vector3.new(0, 0, -1)
local lastStep = Vector3.zero
local lastEnv: MovementSim.Env? = nil
local jumpPowerArmed = false
local errorReported = false
local filterAt = -math.huge

local techRemote: RemoteEvent? = nil
local pivotRemote: RemoteEvent? = nil

local MOVEMENT_ACTIONS = { Jump = true, Cut = true, Slide = true, Dive = true, Burst = true }
local WALL_RAY = MovementConfig.WallRebound.DetectDistance
local BLOCK_RAY = 2.5
local GROUND_RAY_GROUND = 1.2 -- studs past the feet that still count as grounded (ground modes)
local GROUND_RAY_AIR = 0.3 -- ... while in Air / Dive
local FILTER_REFRESH = 0.25

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function now(): number
	return Net.now()
end

---------------------------------------------------------------------------
-- public API
---------------------------------------------------------------------------

function MovementController.sim(): MovementSim.State
	return sim
end

-- The planted pivot foot P (nil when not holding / not yet planted).
function MovementController.pivot(): Vector3?
	return MovementSim.getPivot(sim)
end

-- The world flat step vector s of the free foot (zero when not holding).
function MovementController.step(): Vector3
	return lastStep
end

-- True while the movement side treats you as holding the disc (includes the
-- predicted catch before the server confirms it).
function MovementController.holdingDisc(): boolean
	return sim.holding
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

function MovementController.isMarking(): boolean
	return MovementSim.isMarking(sim)
end

-- Mark shuffle on/off (CatchController). A Cut / Dive / Burst ends it inside
-- the sim; poll isMarking() for the live state.
function MovementController.setMarking(on: boolean)
	MovementSim.setMarking(sim, on)
end

local function refreshFilter(force: boolean?)
	local t = os.clock()
	if not force and t - filterAt < FILTER_REFRESH then
		return
	end
	filterAt = t
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

local function computeStandHeight(h: Humanoid, r: BasePart): number
	if h.RigType == Enum.HumanoidRigType.R15 then
		return h.HipHeight + r.Size.Y / 2
	end
	return 3
end

local function hitsSolid(origin: Vector3, dir: Vector3): boolean
	return workspace:Raycast(origin, dir, rayParams) ~= nil
end

local function buildEnv(): MovementSim.Env
	local r = root :: BasePart
	local h = humanoid :: Humanoid
	standHeight = computeStandHeight(h, r)
	local pos = r.Position
	local vel = r.AssemblyLinearVelocity

	-- grounded: the Humanoid's own floor detection, or a ray just past the feet.
	-- On the ground the ray reaches 1.2 studs below the feet (bridges step-downs
	-- and coyote flicker); in the air (jumps, hops, dives) only 0.3, less than a
	-- frame of fall, so a low arc never lands before the feet touch.
	local state = h:GetState()
	local humGrounded = h.FloorMaterial ~= Enum.Material.Air
		and state ~= Enum.HumanoidStateType.Jumping
		and state ~= Enum.HumanoidStateType.Freefall
	local grounded = humGrounded
	if not grounded and vel.Y <= 6 then
		local airborne = sim.mode == "Air" or sim.mode == "Dive"
		local reach = if airborne then GROUND_RAY_AIR else GROUND_RAY_GROUND
		grounded = workspace:Raycast(pos, Vector3.new(0, -(standHeight + reach), 0), rayParams) ~= nil
	end

	local ttl: number? = nil
	if not grounded then
		local far = workspace:Raycast(pos, Vector3.new(0, -120, 0), rayParams)
		if far then
			local height = math.max(0, pos.Y - standHeight - far.Position.Y)
			lastAirHeight = height
			local g = workspace.Gravity
			ttl = (vel.Y + math.sqrt(math.max(vel.Y * vel.Y + 2 * g * height, 0))) / g
		end
	end

	-- Rebound walls: along travel, along the look, and to both sides
	local wallNormal: Vector3? = nil
	local wallDistance: number? = nil
	local wallId: string? = nil
	if not grounded then
		local travel = VecMath.flatUnit(vel)
		local side = Vector3.new(-travel.Z, 0, travel.X)
		for _, d in { travel, VecMath.flatUnit(r.CFrame.LookVector), side, -side } do
			if d.Magnitude > 0.5 then
				local w = workspace:Raycast(pos, d * WALL_RAY, rayParams)
				if w and CollectionService:HasTag(w.Instance, "Rebound") then
					wallNormal = VecMath.flatUnit(w.Normal)
					wallDistance = w.Distance
					wallId = w.Instance:GetFullName()
					break
				end
			end
		end
	end

	-- blocked: something solid right ahead along where the sim wants to go
	-- (root height and knee height, so low walls count too)
	local blocked = false
	local simVel = VecMath.flat(sim.vel)
	if simVel.Magnitude > 6 then
		local ahead = simVel.Unit * BLOCK_RAY
		blocked = hitsSolid(pos, ahead) or hitsSolid(pos - Vector3.new(0, standHeight * 0.6, 0), ahead)
	end

	local env: MovementSim.Env = {
		grounded = grounded,
		actualVel = vel,
		timeToLand = ttl,
		wallNormal = wallNormal,
		wallDistance = wallDistance,
		wallId = wallId,
		facing = r.CFrame.LookVector,
		pos = pos,
		aimYaw = controllers.CameraController.getYaw(),
		blocked = blocked,
	}
	lastEnv = env
	return env
end

local function currentInput(): MovementSim.Input
	return {
		move = controllers.InputController.moveVector(),
		sprint = controllers.InputController.sprinting(),
	}
end

-- Feeds the local signature tracker; a completed move pays into the local
-- chain and is announced at once (the server pays the real points).
local function feedSignatures(ev: Signatures.Event)
	for _, hit in Signatures.feed(signatures, ev) do
		local points, total = ComboEvaluator.signature(combo, hit.name, hit.points, hit.t)
		MovementController.SignatureHit:Fire(hit)
		MovementController.ComboChanged:Fire(
			total,
			points,
			{ tech = "Signature", quality = "Perfect", t = hit.t, dir = Vector3.zero, chain = true, info = hit.name }
		)
	end
end

local function queueEvent(e: MovementSim.TechEvent)
	table.insert(pending, { tech = e.tech, quality = e.quality, dir = e.dir, t = e.t, info = e.info })
	-- close a timed-out chain first so its end card is never swallowed
	local ended = ComboEvaluator.expire(combo, e.t)
	if ended then
		MovementController.ChainEnded:Fire(ended)
	end
	local points, total = ComboEvaluator.add(combo, e.tech, e.quality, e.t)
	MovementController.Tech:Fire(e)
	MovementController.ComboChanged:Fire(total, points, e)
	feedSignatures({ kind = "Tech", t = e.t, tech = e.tech, quality = e.quality, info = e.info })
end

-- Queues a technique that another controller detected (ThrowController's
-- "Break") through the normal pipeline: local combo + Tech remote.
function MovementController.addTech(tech: string, quality: string, dir: Vector3, info: string?)
	local t = now()
	queueEvent({
		tech = tech,
		quality = quality,
		t = t,
		dir = dir,
		chain = ComboEvaluator.active(combo, t) ~= nil,
		info = info,
	})
end

-- CatchController saw you tip a disc in the air: the Tip Reset. Returns
-- false when the sim refuses it (it already said why).
function MovementController.tipReset(quality: string, dir: Vector3): boolean
	local env = lastEnv
	if not env or not root then
		return false
	end
	local ok = MovementSim.tipReset(sim, env, quality, dir)
	return ok
end

function MovementController.noteAerialReach(dir: Vector3)
	MovementSim.noteAerialReach(sim, dir)
end

local function freshEnv(): MovementSim.Env?
	if not root or not humanoid or not root.Parent then
		return nil
	end
	refreshFilter()
	return buildEnv()
end

-- Quick Swing while holding: -1 screen-left, +1 screen-right, 0 = mirror of
-- the current step. Returns MovementSim.swing's (ok, reason).
function MovementController.swing(side: number): (boolean, string?)
	local env = freshEnv()
	if not env then
		return false, "Context"
	end
	return MovementSim.swing(sim, side, env)
end

-- The fake's lunge toward `side` (-1 / 0 / +1); also opens the Sold window.
function MovementController.fakeStep(side: number)
	MovementSim.fakeStep(sim, side)
end

-- What each movement action would do right now ({ Cut = "SNAP CUT", ... }).
function MovementController.contextHint(): { [string]: string }
	local env = lastEnv
	if not env or not root then
		return {}
	end
	local hint = MovementSim.contextHint(sim, currentInput(), env)
	-- a disc about to pass your hands in the air: the Tip Reset
	if MovementSim.isAirborne(sim) and not sim.holding and controllers.CatchController.tipReady() then
		hint.Secondary = "TIP RESET"
	end
	-- gamepad X swings to the mirror of the current step, not to the left
	if sim.holding and hint.Cut and controllers.InputController.scheme() == "Gamepad" then
		hint.Cut = "SWING OTHER SIDE"
	end
	return hint
end

---------------------------------------------------------------------------
-- character setup
---------------------------------------------------------------------------

local function setupCharacter(c: Model)
	character = c
	humanoid = nil
	root = nil
	ao = nil
	local h = c:WaitForChild("Humanoid", 10) :: Humanoid?
	local r = c:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not h or not r or character ~= c then
		return
	end
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
	standHeight = computeStandHeight(h, r)

	local att = Instance.new("Attachment")
	att.Name = "UBFaceAttachment"
	att.Parent = r

	local align = Instance.new("AlignOrientation")
	align.Name = "UBFace"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = false
	align.Responsiveness = 30
	align.MaxTorque = 1e7
	align.MaxAngularVelocity = 20
	align.CFrame = r.CFrame.Rotation
	align.Parent = r
	ao = align
	aoAiming = nil
	local look = VecMath.flatUnit(r.CFrame.LookVector)
	lastFacing = if look.Magnitude > 0.5 then look else Vector3.new(0, 0, -1)

	sim = MovementSim.new(now())
	holding = false
	confirmedHold = false
	pivotResent = false
	predicted = nil
	lastMode = ""
	lastStep = Vector3.zero
	lastEnv = nil
	jumpPowerArmed = false
	errorReported = false
	lastTeleport = c:GetAttribute("UBTeleport")
	refreshFilter(true)
	humanoid = h
	root = r
	h.Died:Connect(function()
		h:Move(Vector3.zero, false)
		h.WalkSpeed = 0
		align.Enabled = false
	end)
end

---------------------------------------------------------------------------
-- per-frame
---------------------------------------------------------------------------

-- Server teleport: UBTeleportPos / Yaw / Face are written before the counter.
local function handleTeleport(c: Model, r: BasePart)
	local pos = c:GetAttribute("UBTeleportPos")
	local yaw = c:GetAttribute("UBTeleportYaw")
	local face = c:GetAttribute("UBTeleportFace") == true
	if typeof(pos) == "Vector3" and (r.Position - pos).Magnitude > 1 then
		-- a facing teleport turns you; any other keeps the way you face now
		local rot = if face and type(yaw) == "number"
			then CFrame.Angles(0, yaw, 0)
			else CFrame.lookAt(Vector3.zero, lastFacing).Rotation
		r.CFrame = CFrame.new(pos) * rot
	end
	r.AssemblyLinearVelocity = Vector3.zero
	r.AssemblyAngularVelocity = Vector3.zero
	MovementSim.reset(sim) -- keeps frozen, holding, exertion, cooldowns and the pivot
	sim.pos = r.Position
	if face and type(yaw) == "number" then
		controllers.CameraController.setYaw(yaw)
		lastFacing = VecMath.fromYaw(yaw)
		local align = ao
		if align then
			align.CFrame = CFrame.lookAt(Vector3.zero, lastFacing)
		end
	end
end

-- Predicted catch (CatchController.Claimed) until the server confirms it;
-- Denied, no confirmation in time, or the claimed disc ending up anywhere but
-- in our hand cancels it. (A catch that scores, or lands out of bounds, ends
-- the possession in the same server frame: the disc goes straight from
-- Flight to Ground and Held-by-us is never seen.)
local function updateHolding(grounded: boolean)
	local confirmed = controllers.ThrowController.isHolding()
	local p = predicted
	if confirmed or (p and os.clock() > p.untilT) then
		predicted = nil
	elseif p then
		local f = controllers.DiscRenderer.folderOf(p.disc)
		local mode = f and f:GetAttribute("Mode")
		if f and mode ~= "Flight" and not (mode == "Held" and f:GetAttribute("HolderId") == player.UserId) then
			predicted = nil
		end
	end
	local want = confirmed or predicted ~= nil
	if want ~= holding then
		holding = want
		MovementSim.setHolding(sim, want, grounded)
		pivotResent = false
	end
	if confirmed ~= confirmedHold then
		confirmedHold = confirmed
		pivotResent = false
	end
end

-- The authoritative pivot: adopt UBPivot every frame; if the sim planted its
-- own foot while the catch was still only predicted (the server may have
-- ignored that proposal), propose it once more now that the disc is ours.
local function syncPivot(c: Model)
	local pv = c:GetAttribute("UBPivot")
	local server = if typeof(pv) == "Vector3" then pv else nil
	MovementSim.setPivot(sim, server)
	if server == nil and confirmedHold and not pivotResent then
		local own = MovementSim.getPivot(sim)
		local remote = pivotRemote
		if own and remote then
			pivotResent = true
			remote:FireServer(own)
		end
	end
end

-- Lineup restriction: (x - UBLineX) * UBLineSide >= 0. The approach slows
-- smoothly to the line; a body already beyond it eases back.
local function applyLine(c: Model, pos: Vector3, v: Vector3): Vector3
	local lx = c:GetAttribute("UBLineX")
	local ls = c:GetAttribute("UBLineSide")
	if type(lx) ~= "number" or type(ls) ~= "number" or ls == 0 then
		return v
	end
	local side = if ls > 0 then 1 else -1
	local inside = (pos.X - lx) * side -- studs on the allowed side
	local along = v.X * side -- + = away from the line
	if inside < 0 then
		local back = math.clamp(-inside * 6, 3, 14)
		return Vector3.new(side * math.max(back, along), 0, v.Z)
	end
	if along < 0 then
		local allowed = math.min(-along, inside * 10)
		return Vector3.new(-side * allowed, 0, v.Z)
	end
	return v
end

-- Where the body should face. Aiming (pivoting, charging, marking) faces
-- the camera, but never while the body is still sliding: during the catch
-- slow-down the body keeps facing its travel and turns toward the camera as
-- it stops, so a deep catch never runs backwards. A reach at speed twists
-- the body at most REACH_TWIST from travel (PoseController turns the waist
-- and arm the rest of the way).
local REACH_TWIST = 75

local function faceTarget(v: Vector3): (Vector3?, boolean)
	local catch = controllers.CatchController
	local travel = if v.Magnitude > 2 then VecMath.flatUnit(v) else nil
	local speed = v.Magnitude
	local aiming = sim.holding
		or controllers.ThrowController.isCharging()
		or MovementSim.isMarking(sim)
		or catch.isMarking()
	if aiming then
		local cam = controllers.CameraController.forward()
		local settling = sim.holding and sim.holdPhase ~= "Pivot"
		if travel and (settling or sim.mode == "DiveSlide" or sim.mode == "Recover") then
			-- blend toward the camera as the slide runs out of speed
			local k = math.clamp(1 - speed / 10, 0, 1)
			local blend = VecMath.flatUnit(travel * (1 - k) + cam * k)
			return if blend.Magnitude > 0.5 then blend else travel, true
		end
		return cam, true
	end
	if sim.mode == "Dive" or sim.mode == "DiveSlide" then
		return sim.diveDir, false
	end
	if catch.reachActive() then
		local _, reachDir = catch.reachState()
		local r = VecMath.flatUnit(reachDir)
		if r.Magnitude > 0.5 then
			if travel and speed > MovementConfig.JogSpeed then
				return VecMath.rotateToward(travel, r, REACH_TWIST), true
			end
			local blend = if travel then VecMath.flatUnit(r + travel) else r
			return if blend.Magnitude > 0.5 then blend else r, true
		end
	end
	return travel, false
end

local function drive(h: Humanoid, r: BasePart, out: MovementSim.Output, v: Vector3)
	local sp = v.Magnitude
	h.WalkSpeed = sp
	h:Move(if sp > 0.05 then v / sp else Vector3.zero, false)
	local vy = out.setVertical
	if out.jump and vy then
		h.JumpPower = vy
		h:ChangeState(Enum.HumanoidStateType.Jumping)
		jumpPowerArmed = true
	end
	if out.impulse or vy then
		local cur = r.AssemblyLinearVelocity
		r.AssemblyLinearVelocity = Vector3.new(v.X, vy or cur.Y, v.Z)
	end
end

local function flushTech(mode: string)
	local remote = techRemote
	if remote and (#pending > 0 or modeDirty) then
		remote:FireServer(pending, mode)
		pending = {}
		modeDirty = false
	elseif #pending > 64 then
		table.remove(pending, 1) -- remote not ready yet: keep the newest
	end
end

local function frame(dtRaw: number)
	local c, h, r = character, humanoid, root
	if not c or not h or not r or not r.Parent or h.Health <= 0 then
		return
	end
	local dt = math.min(dtRaw, 1 / 15)
	sim.now = now() - dt -- keep the sim clock on server time

	if jumpPowerArmed then
		jumpPowerArmed = false
		h.JumpPower = 0
	end

	local tp = c:GetAttribute("UBTeleport")
	if tp ~= lastTeleport then
		lastTeleport = tp
		handleTeleport(c, r)
	end
	local frozen = c:GetAttribute("UBFrozen") == true
	if frozen ~= sim.frozen then
		MovementSim.setFrozen(sim, frozen)
	end

	refreshFilter()
	local env = buildEnv()
	updateHolding(env.grounded)
	if sim.holding then
		syncPivot(c)
	end

	local out = MovementSim.step(sim, currentInput(), env, dt)
	lastStep = out.step

	local v = applyLine(c, r.Position, VecMath.flat(out.vel))
	if v ~= out.vel then
		sim.vel = v
		sim.lastOutVel = v
	end
	drive(h, r, out, v)

	-- facing
	local face, aiming = faceTarget(v)
	if face and face.Magnitude > 0.5 then
		lastFacing = face
	end
	local align = ao
	if align then
		if aiming ~= aoAiming then
			aoAiming = aiming
			align.Responsiveness = if aiming then 45 else 30
			align.MaxAngularVelocity = if aiming then 40 else 20
		end
		align.CFrame = CFrame.lookAt(Vector3.zero, lastFacing)
	end

	for _, e in out.events do
		queueEvent(e)
	end
	for _, fb in out.feedback do
		MovementController.Feedback:Fire(fb)
	end
	local pp = out.pivotPos
	local remote = pivotRemote
	if pp and remote then
		remote:FireServer(pp)
		pivotResent = confirmedHold
	end
	if out.landed then
		MovementController.Landed:Fire(sim.landedFromDive, sim.landingVel.Magnitude)
		feedSignatures({ kind = "Land", t = now() })
	end

	local mode = MovementSim.poseMode(sim)
	if mode ~= lastMode then
		lastMode = mode
		modeDirty = true
		c:SetAttribute("UB_LocalMode", mode)
	end
	flushTech(mode)

	local ended = ComboEvaluator.expire(combo, now())
	if ended then
		MovementController.ChainEnded:Fire(ended)
	end
end

-- Never leave the body running on an error: stop it and say so once.
local function guardedFrame(dt: number)
	local failure: string? = nil
	local ok = xpcall(function()
		frame(dt)
	end, function(e: any)
		failure = debug.traceback(tostring(e), 2)
	end)
	if ok then
		return
	end
	local h = humanoid
	if h then
		pcall(function()
			h:Move(Vector3.zero, false)
			h.WalkSpeed = 0
			h.JumpPower = 0
		end)
	end
	if not errorReported then
		errorReported = true
		warn("[MovementController] frame failed, movement stopped: " .. tostring(failure))
		MovementController.Feedback:Fire({ kind = "Error", text = "MOVEMENT ERROR — see the F9 console" })
	end
end

---------------------------------------------------------------------------
-- presses
---------------------------------------------------------------------------

local function onAction(action: string, scheme: string?)
	if not MOVEMENT_ACTIONS[action] or not root or not character then
		return
	end
	if controllers.InputController.menuOpen() then
		return
	end
	if sim.holding then
		-- with the disc: Q / E swing, Space hops, C is the low release (ThrowController)
		if action == "Cut" then
			local pad = (scheme or controllers.InputController.scheme()) == "Gamepad"
			MovementController.swing(if pad then 0 else -1)
		elseif action == "Dive" then
			MovementController.swing(1)
		elseif action == "Jump" then
			local env = freshEnv()
			if env then
				MovementSim.press(sim, "Jump", currentInput(), env)
			end
		end
		return
	end
	local env = freshEnv()
	if env then
		MovementSim.press(sim, action :: any, currentInput(), env)
	end
end

---------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------

function MovementController.Init(c: any)
	controllers = c
end

function MovementController.Start()
	task.spawn(function()
		techRemote = Net.event("Tech")
	end)
	task.spawn(function()
		pivotRemote = Net.event("Pivot")
	end)

	controllers.InputController.ActionBegan:Connect(function(action, scheme)
		local ok, err = pcall(function()
			onAction(action, scheme)
		end)
		if not ok then
			warn("[MovementController] press failed: " .. tostring(err))
		end
	end)

	-- predicted hold: the slow-down starts with the claim, not a round trip later
	local catch = controllers.CatchController
	catch.Claimed:Connect(function(discId)
		local airborne = MovementSim.isAirborne(sim)
		claimAir[discId] = { airborne = airborne, height = if airborne then lastAirHeight else 0, t = now() }
		if controllers.ThrowController.isHolding() then
			return
		end
		local okPing, ping = pcall(function()
			return player:GetNetworkPing()
		end)
		local rtt = if okPing and type(ping) == "number" then math.clamp(ping, 0, 0.5) else 0.2
		predicted = { disc = discId, untilT = os.clock() + 0.5 + 2 * rtt }
	end)
	local denied = catch.Denied
	if denied then
		denied:Connect(function(discId)
			local p = predicted
			if p and (discId == nil or p.disc == discId) then
				predicted = nil
			end
		end)
	else
		warn("[MovementController] CatchController.Denied missing; predicted holds expire on a timer")
	end

	-- signature move inputs from the catch path
	catch.Tipped:Connect(function(discId: string, defender: boolean)
		feedSignatures({ kind = "Tip", t = now(), discId = discId, defender = defender })
	end)
	catch.Caught:Connect(function(discId: string, interception: boolean)
		local at = claimAir[discId]
		claimAir[discId] = nil
		local airborne = if at then at.airborne else MovementSim.isAirborne(sim)
		feedSignatures({
			kind = "Catch",
			t = if at then at.t else now(),
			discId = discId,
			airborne = airborne,
			height = if at then at.height elseif airborne then lastAirHeight else 0,
			interception = interception,
		})
	end)

	player.CharacterAdded:Connect(setupCharacter)
	if player.Character then
		task.spawn(setupCharacter, player.Character)
	end
	RunService:BindToRenderStep("UBMovement", Enum.RenderPriority.Input.Value + 1, guardedFrame)
end

return MovementController
