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

	ONE ENGINE. The tech core (Movement/TechCore) drives the body: the
	Humanoid is for animation only (EvaluateStateMachine = false, no
	WalkSpeed, no jumping); TechCore steps at 120 Hz and its velocity is
	written straight to the root every frame, with a VectorForce cancelling
	workspace gravity so only the core's own gravity acts. On the ground the
	root is held at its stand height by a spring on a down ray; walls ahead
	(a ray along the velocity, at root and knee height) are slid along.
	Presses go into the core's input buffer; the tech that uses them comes
	in later build steps. The character attribute UB_Air tells the Animate
	script when you are airborne (the Humanoid state no longer says).
	MovementSim is still used for the holding / pivot state (stage 3 moves
	it into the throwing module); it no longer moves the body.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MovementSim = require(Shared.Movement.MovementSim)
local TechCore = require(Shared.Movement.TechCore)
local TechConfig = require(Shared.Config.Tech)
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

-- the tech engine
local tech: TechCore.State = TechCore.new(os.clock())
local engineOn = false -- the tech engine drives the current character
local antiGravity: VectorForce? = nil
local techPivotSent = false
local lastAirAttr: boolean? = nil

local techRemote: RemoteEvent? = nil
local pivotRemote: RemoteEvent? = nil

local MOVEMENT_ACTIONS = { Jump = true, Cut = true, Slide = true, Dive = true, Burst = true }
local WALL_RAY = MovementConfig.WallRebound.DetectDistance
local BLOCK_RAY = 2.5
local GROUND_RAY_GROUND = 1.2 -- studs past the feet that still count as grounded (ground modes)
local GROUND_RAY_AIR = 0.3 -- ... while in Air / Dive
local FILTER_REFRESH = 0.25
local TECH_WALL_RAY = 1.6 -- studs ahead of the root centre (the root is 2 wide)
local TECH_PIVOT_SPEED = 1 -- plant the pivot once a holder is this slow
local PIVOT_ADOPT = 3 -- studs: a server pivot this far from ours means it moved us
local localPivot: Vector3? = nil
local lastTTL: number? = nil -- time to land last frame (airborne)
-- the tech-engine pivot
local pivotStickMag = 0
local pivotTapAt = -math.huge
local pivotTapDir = Vector3.zero
local pivotLungeUntil = -math.huge
local pivotRecoverUntil = -math.huge

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
	if engineOn then
		return tech.grounded
	end
	return not MovementSim.isAirborne(sim)
end

function MovementController.isMarking(): boolean
	if engineOn then
		return tech.marking
	end
	return MovementSim.isMarking(sim)
end

-- Mark shuffle on/off (CatchController). A Cut / Dive / Burst ends it inside
-- the sim; poll isMarking() for the live state.
function MovementController.setMarking(on: boolean)
	MovementSim.setMarking(sim, on)
	TechCore.setMarking(tech, on)
end

-- "Tech" (TechCore drives the body) or "Classic" (MovementSim).
function MovementController.engine(): string
	return if engineOn then "Tech" else "Classic"
end

-- The tech core's state (debug HUD, later tech).
function MovementController.techState(): TechCore.State
	return tech
end

-- A throw is leaving your hand: is it a Pinch (within PINCH_WINDOW of your
-- feet touching down)? Returns its quality or nil; the core records the
-- timing and the event.
function MovementController.pinch(): string?
	if not engineOn then
		return nil
	end
	return TechCore.pinch(tech, lastTTL)
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

---------------------------------------------------------------------------
-- character setup
---------------------------------------------------------------------------

-- Puts the current character on the tech engine (the only engine; the
-- classic Humanoid-style sim no longer drives players).
local function applyEngine()
	local h, r, c = humanoid, root, character
	local want = true
	if not h or not r or not c then
		engineOn = false
		return
	end
	if want == engineOn and (not want or (antiGravity ~= nil and antiGravity.Parent == r)) then
		return
	end
	engineOn = want
	if want then
		h:Move(Vector3.zero, false)
		h.WalkSpeed = 0
		h.JumpPower = 0
		h.EvaluateStateMachine = false
		local att = r:FindFirstChild("UBFaceAttachment") :: Attachment?
		local force = Instance.new("VectorForce")
		force.Name = "UBAntiGravity"
		force.RelativeTo = Enum.ActuatorRelativeTo.World
		force.ApplyAtCenterOfMass = true
		force.Attachment0 = att
		force.Force = Vector3.new(0, r.AssemblyMass * workspace.Gravity, 0)
		force.Parent = r
		antiGravity = force
		tech = TechCore.new(os.clock())
		tech.vel = VecMath.flat(r.AssemblyLinearVelocity)
		TechCore.setHolding(tech, holding)
		TechCore.setMarking(tech, MovementSim.isMarking(sim))
		TechCore.setFrozen(tech, c:GetAttribute("UBFrozen") == true)
		techPivotSent = false
		lastAirAttr = nil
	else
		local force = antiGravity
		antiGravity = nil
		if force then
			force:Destroy()
		end
		h.EvaluateStateMachine = true
		c:SetAttribute("UB_Air", nil)
		lastAirAttr = nil
		MovementSim.reset(sim)
		sim.pos = r.Position
	end
end

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
	engineOn = false
	antiGravity = nil
	applyEngine()
	h.Died:Connect(function()
		h:Move(Vector3.zero, false)
		h.WalkSpeed = 0
		align.Enabled = false
		local force = antiGravity
		if force and force.Parent == r then
			force.Enabled = false
		end
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
	TechCore.reset(tech)
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
		TechCore.setHolding(tech, want)
		pivotResent = false
		techPivotSent = false
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

-- The pose mode the tech core's state replicates as (PoseController,
-- Animate and the server's VALID_MODES know these names).
local function techPoseMode(): string
	if tech.frozen then
		return "Frozen"
	end
	local st = tech.state
	if st == "HoldingDisc" then
		return if TechCore.flatSpeed(tech) < TECH_PIVOT_SPEED then "Pivot" else "Ground"
	elseif st == "Marking" then
		return "Mark"
	elseif st == "Airborne" or st == "AirDodging" then
		return "Air"
	elseif st == "Diving" then
		return "Dive"
	elseif st == "Sliding" then
		return "Slide"
	elseif st == "Downed" then
		return "DiveSlide"
	elseif st == "Recovering" then
		return "Recover"
	end
	return "Ground"
end

-- Facing on the tech engine: the camera while holding / charging / marking
-- (blended from travel while a catch is still sliding), travel otherwise.
local function techFace(v: Vector3): (Vector3?, boolean)
	local catch = controllers.CatchController
	local travel = if v.Magnitude > 2 then VecMath.flatUnit(v) else nil
	local aiming = tech.holding or tech.marking or controllers.ThrowController.isCharging() or catch.isMarking()
	if aiming then
		local cam = controllers.CameraController.forward()
		-- only the catch run-out turns with travel; planted, you face the
		-- camera (stepping around the pivot never spins the body)
		if travel and tech.holding and localPivot == nil then
			local k = math.clamp(1 - v.Magnitude / 10, 0, 1)
			local blend = VecMath.flatUnit(travel * (1 - k) + cam * k)
			return if blend.Magnitude > 0.5 then blend else travel, true
		end
		return cam, true
	end
	return travel, false
end

-- Techs that only get a sound (a pop for every jump would be noise).
local QUIET_TECH = { Jump = true, AirDodge = true, Plant = true }
local checkMirror: () -> () -- defined with the presses
local checkContact: (Vector3) -> () -- defined with the tech frame

-- A tech the core reports: feedback at once, and (unless it was a miss) the
-- combo chain and the server, like any technique.
local function techEvent(e: TechCore.TechEvent)
	local name = (MovementConfig.TechNames :: any)[e.tech] or e.tech
	if e.quality == "Perfect" or not QUIET_TECH[e.tech] then
		local label = if e.quality == "Perfect" then "Perfect " .. name else name
		controllers.TechFeedback.play(label, e.quality)
	end
	if e.quality == "Miss" then
		return
	end
	local t = now()
	if e.tech == "Plant" then
		-- the start of a cut or a juke: posed everywhere, scores nothing
		table.insert(pending, { tech = e.tech, quality = e.quality, dir = e.dir, t = t })
		MovementController.Tech:Fire({ tech = e.tech, quality = e.quality, t = t, dir = e.dir, chain = false })
		return
	end
	queueEvent({
		tech = e.tech,
		quality = e.quality,
		t = t,
		dir = e.dir,
		chain = ComboEvaluator.active(combo, t) ~= nil,
		info = e.info,
	})
end

-- Contact rule: entering another body's space costs speed once per overlap.
local overlapping: { [Model]: boolean } = {}
local contactScan = 0

checkContact = function(pos: Vector3)
	contactScan += 1
	if contactScan % 2 ~= 0 then
		return
	end
	local seen: { [Model]: boolean } = {}
	local function test(m: Model)
		if m == character then
			return
		end
		local mr = m:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not mr then
			return
		end
		local d = VecMath.flat(mr.Position - pos).Magnitude
		if d < TechConfig.CONTACT_RADIUS and math.abs(mr.Position.Y - pos.Y) < 4 then
			seen[m] = true
			if not overlapping[m] and TechCore.flatSpeed(tech) > 6 then
				TechCore.contact(tech)
			end
		end
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			test(p.Character)
		end
	end
	local bots = workspace:FindFirstChild("UBBots")
	if bots then
		for _, m in bots:GetChildren() do
			if m:IsA("Model") then
				test(m)
			end
		end
	end
	overlapping = seen
end

-- One frame on the tech engine.
local function techFrame(c: Model, h: Humanoid, r: BasePart, dt: number)
	refreshFilter()
	standHeight = computeStandHeight(h, r)
	local pos = r.Position

	-- ground: a ray from the root to just past the feet (further when
	-- falling fast, so a landing is caught on the frame of touchdown)
	local vy = tech.vel.Y
	local groundY: number? = nil
	if vy <= 0.01 then
		local snap = if tech.grounded
			then TechConfig.GROUND_SNAP
			else TechConfig.GROUND_SNAP_AIR + math.max(0, -vy) * dt
		local hit = workspace:Raycast(pos, Vector3.new(0, -(standHeight + snap), 0), rayParams)
		if hit and hit.Normal.Y > 0.5 then
			groundY = hit.Position.Y
		end
	end

	-- walls: along the velocity, at root and knee height
	local wallNormal: Vector3? = nil
	-- walls: along the velocity (and, in the air, along the stick too, for
	-- the Wall Kick), at root and knee height
	local flatVel = VecMath.flat(tech.vel)
	local probes: { Vector3 } = {}
	if flatVel.Magnitude > 0.5 then
		table.insert(probes, flatVel.Unit)
	end
	if not tech.grounded then
		local stick = VecMath.flat(controllers.InputController.moveVector())
		if stick.Magnitude > 0.3 then
			table.insert(probes, stick.Unit)
		end
	end
	for _, dir in probes do
		if wallNormal then
			break
		end
		for _, origin in { pos, pos - Vector3.new(0, standHeight * 0.6, 0) } do
			local w = workspace:Raycast(origin, dir * TECH_WALL_RAY, rayParams)
			if w and math.abs(w.Normal.Y) < 0.7 then
				wallNormal = VecMath.flatUnit(w.Normal)
				break
			end
		end
	end

	-- Flip Reset: falling onto a disc in flight with your feet
	if not tech.grounded and vy <= 0 and tech.storedFlips == 0 then
		local feet = pos - Vector3.new(0, standHeight, 0)
		for _, f in controllers.DiscRenderer.folders() do
			local id = f:GetAttribute("Id")
			if type(id) == "string" and f:GetAttribute("Mode") == "Flight" then
				local dp = controllers.DiscRenderer.positionOf(id)
				if dp and (dp - feet).Magnitude <= TechConfig.FLIP_RESET_RADIUS and dp.Y <= feet.Y + 1.2 then
					TechCore.footContact(tech)
					break
				end
			end
		end
	end

	-- time to land (wavedash), from a long ray when airborne
	local ttl: number? = nil
	lastTTL = nil
	if groundY == nil then
		local far = workspace:Raycast(pos, Vector3.new(0, -120, 0), rayParams)
		if far then
			local height = math.max(0, pos.Y - standHeight - far.Position.Y)
			lastAirHeight = height
			local g = TechConfig.PLAYER_GRAVITY * TechConfig.FALL_GRAVITY_MULT
			ttl = (vy + math.sqrt(math.max(vy * vy + 2 * g * height, 0))) / g
			lastTTL = ttl
		end
	end

	updateHolding(groundY ~= nil)
	if sim.holding then
		syncPivot(c)
	end

	local inputs = controllers.InputController
	local menu = inputs.menuOpen()
	local report = TechCore.advance(tech, {
		move = if menu then Vector3.zero else inputs.moveVector(),
		held = if menu
			then {}
			else {
				Burst = inputs.isHeld("Burst"),
				Slide = inputs.isHeld("Slide"),
				Jump = inputs.isHeld("Jump"),
				Cut = inputs.isHeld("Cut"),
			},
		aim = VecMath.flatUnit(controllers.CameraController.forward()),
	}, { grounded = groundY ~= nil, wallNormal = wallNormal, timeToLand = ttl }, dt)
	for _, e in TechCore.drainEvents(tech) do
		techEvent(e)
	end
	checkContact(pos)

	-- the pivot (docs/tech-spec.md 23): planted, the free foot steps up to
	-- PIVOT_REACH around P; a double-tap lunges PIVOT_LUNGE, then recovers
	-- the pivot is where YOUR run-out stopped (what you see); it is proposed
	-- to the server, and the server's P is only taken over when it really
	-- moved you (a pickup, a travel call), so lag never yanks you back
	if not tech.holding then
		localPivot = nil
	elseif localPivot == nil and tech.grounded and TechCore.flatSpeed(tech) < TECH_PIVOT_SPEED then
		localPivot = pos
	end
	local serverP = MovementSim.getPivot(sim)
	if
		serverP
		and (
			(localPivot and VecMath.flat(serverP - localPivot).Magnitude > PIVOT_ADOPT)
			or (localPivot == nil and tech.grounded)
		)
	then
		localPivot = serverP
	end
	local planted = localPivot
	if tech.holding and tech.grounded and planted then
		local stick = if menu then Vector3.zero else VecMath.flat(inputs.moveVector())
		local clock = os.clock()
		local tapped = stick.Magnitude > 0.5 and pivotStickMag <= 0.5
		pivotStickMag = stick.Magnitude
		if tapped and clock >= pivotRecoverUntil then
			local dir = stick.Unit
			if clock - pivotTapAt <= 0.3 and dir:Dot(pivotTapDir) > 0.8 then
				pivotLungeUntil = clock + TechConfig.PIVOT_LUNGE_TIME
				pivotRecoverUntil = pivotLungeUntil + TechConfig.PIVOT_LUNGE_RECOVER
				pivotTapAt = -math.huge
				controllers.TechFeedback.play("Lunge", "Clean")
			else
				pivotTapAt, pivotTapDir = clock, dir
			end
		end
		local reach = if clock < pivotLungeUntil then TechConfig.PIVOT_LUNGE else TechConfig.PIVOT_REACH
		if clock >= pivotLungeUntil and clock < pivotRecoverUntil then
			stick *= 0.3 -- the lunge's recovery: barely any footwork
		end
		local want = Vector3.new(planted.X, pos.Y, planted.Z) + VecMath.clampMagnitude(stick, 1) * reach
		local toward = VecMath.flat(want - pos)
		local v = if toward.Magnitude < 0.04 then Vector3.zero else VecMath.clampMagnitude(toward * 12, 16)
		tech.vel = Vector3.new(v.X, tech.vel.Y, v.Z)
		-- the step the throw model and the server use is the free FOOT: the
		-- body sits at P + BodyShare x step
		local body = VecMath.flat(pos - planted)
		lastStep = VecMath.clampMagnitude(body / MovementConfig.Holding.BodyShare, MovementConfig.Holding.StepRadius)
	elseif not tech.holding then
		lastStep = Vector3.zero
	end

	local flat = VecMath.flat(tech.vel)
	local lined = applyLine(c, pos, flat)
	if lined ~= flat then
		flat = lined
		tech.vel = Vector3.new(lined.X, tech.vel.Y, lined.Z)
	end
	local outY = tech.vel.Y
	if tech.grounded and groundY then
		local err = groundY + standHeight - pos.Y
		outY = math.clamp(err * TechConfig.GROUND_SPRING, -TechConfig.GROUND_SPRING_MAX, TechConfig.GROUND_SPRING_MAX)
	end
	r.AssemblyLinearVelocity = Vector3.new(flat.X, outY, flat.Z)
	local force = antiGravity
	if force then
		force.Force = Vector3.new(0, r.AssemblyMass * workspace.Gravity, 0)
	end

	-- the pivot: propose where we stopped once the catch has settled
	if confirmedHold and not techPivotSent and localPivot then
		local remote = pivotRemote
		local sp = c:GetAttribute("UBPivot")
		-- propose ours; also once over a server guess that landed elsewhere
		-- (the server lets a client replace its own auto plant for 1.5 s)
		local differs = typeof(sp) == "Vector3" and VecMath.flat(sp - localPivot).Magnitude > 0.4
		if remote and (sp == nil or differs) then
			techPivotSent = true
			remote:FireServer(localPivot)
		end
	end

	-- facing
	local face, aiming = techFace(flat)
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

	local air = not tech.grounded
	if air ~= lastAirAttr then
		lastAirAttr = air
		c:SetAttribute("UB_Air", air)
	end
	if report.landed then
		MovementController.Landed:Fire(false, report.landingSpeed)
		feedSignatures({ kind = "Land", t = now() })
	end

	local mode = techPoseMode()
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
	if frozen ~= tech.frozen then
		TechCore.setFrozen(tech, frozen)
	end
	if engineOn then
		techFrame(c, h, r, dt)
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
	local r = root
	if r and engineOn then
		pcall(function()
			r.AssemblyLinearVelocity = Vector3.zero
		end)
		tech.vel = Vector3.zero
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

-- Mirror Step: a Cut within MIRROR_WINDOW of the plant of the opponent you're
-- closest to (within MIRROR_RANGE) mirrors it. If their plant turns out to be
-- a Juke, you bit on the fake.
checkMirror = function()
	local r = root
	local me = character
	if not r or not me then
		return
	end
	local myTeam = me:GetAttribute("UBTeam")
	local best: Model? = nil
	local bestD = TechConfig.MIRROR_RANGE
	local candidates: { Model } = {}
	for _, p in Players:GetPlayers() do
		if p ~= player and p.Character then
			table.insert(candidates, p.Character)
		end
	end
	local bots = workspace:FindFirstChild("UBBots")
	if bots then
		for _, m in bots:GetChildren() do
			if m:IsA("Model") then
				table.insert(candidates, m)
			end
		end
	end
	for _, m in candidates do
		local team = m:GetAttribute("UBTeam")
		local mr = m:FindFirstChild("HumanoidRootPart") :: BasePart?
		if mr and team ~= nil and team ~= myTeam then
			local d = (mr.Position - r.Position).Magnitude
			if d < bestD then
				best, bestD = m, d
			end
		end
	end
	local opp = best
	if not opp then
		return
	end
	local plantT = opp:GetAttribute("TechT")
	if opp:GetAttribute("Tech") ~= "Plant" or type(plantT) ~= "number" then
		return
	end
	local okPing, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	local lag = if okPing and type(ping) == "number" then math.clamp(ping, 0, 0.3) else 0.1
	if now() - plantT > TechConfig.MIRROR_WINDOW / 1000 + lag then
		return
	end
	TechCore.armMirror(tech)
	-- their plant resolves after it ends: a Juke means you bit
	task.delay(TechConfig.CUT_RELEASE_MAX + TechConfig.JUKE_WINDOW / 1000 + lag + 0.05, function()
		if opp.Parent and opp:GetAttribute("Tech") == "Juke" and engineOn then
			TechCore.juked(tech)
		end
	end)
end

local function onAction(action: string)
	if not MOVEMENT_ACTIONS[action] or not root or not character then
		return
	end
	if controllers.InputController.menuOpen() then
		return
	end
	if engineOn then
		if action == "Cut" then
			checkMirror()
		end
		TechCore.press(tech, action)
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

	controllers.InputController.ActionBegan:Connect(function(action)
		local ok, err = pcall(function()
			onAction(action)
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
		if engineOn then
			TechCore.discContact(tech) -- Disc Reset
		end
		feedSignatures({ kind = "Tip", t = now(), discId = discId, defender = defender })
	end)
	catch.Caught:Connect(function(discId: string, interception: boolean)
		if engineOn then
			TechCore.discContact(tech) -- a catch in the air is a Disc Reset too
		end
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

	controllers.SettingsController.Changed:Connect(function(key)
		if key == "All" then
			applyEngine()
		end
	end)

	player.CharacterAdded:Connect(setupCharacter)
	if player.Character then
		task.spawn(setupCharacter, player.Character)
	end
	RunService:BindToRenderStep("UBMovement", Enum.RenderPriority.Input.Value + 1, guardedFrame)
end

return MovementController
