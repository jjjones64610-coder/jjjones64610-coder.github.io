--!strict
--[[
	BotService — server-driven teammates and opponents, so every match is a
	full 3v3 / 7v7 (TeamService adds bots to empty line slots when the mode
	has FillWithBots) and Studio solo testing works.

	BODY. Every bot runs the same MovementSim a player runs, on the server,
	and drives its Humanoid exactly the way the client MovementController
	drives a player's: each Heartbeat WalkSpeed = |v| and Move(v.Unit) from
	the sim's velocity; on impulse frames (technique starts, jumps) it also
	writes AssemblyLinearVelocity; a jump sets JumpPower + ChangeState(Jumping)
	for one frame. Facing is an AlignOrientation (AutoRotate off; the root
	CFrame is never written), so bots turn smoothly and never snap. Bots
	therefore accelerate, turn, plant, cut, burst, slide, lay out, slide out
	of the dive and pop up with a player's momentum. Their technique events
	go to MovementService.botTech with their timestamps (pose attributes,
	combos) and the sim's pose mode is their MS attribute. A server teleport
	(UBTeleport) resets the sim like a client's (keeping the possession and
	the pivot), the pre-pull line (UBLineX / UBLineSide) clamps them like a
	player, UBFrozen freezes the sim.

	BRAIN. Brains think ~10 times a second and only output intent: a target
	and speed (the motor turns it into sim input with a smooth arrival and a
	stop radius with hysteresis, so bots never jitter on a spot; a moving
	target such as a guard's man also gives its velocity, which is matched
	so a guard never stop-starts behind him), a facing, the holder's aim and
	step, the mark-shuffle flag, and presses (Cut / Burst / Dive / Jump /
	Slide / Swing / Fake, optionally a few frames later). Techniques are
	used the way players use them, at most every ~0.6-1.2 s per bot: a Snap
	Cut (sometimes with a Perfect Burst out of it) when a cutter changes
	direction at speed, a plant plus an explosive restart to reverse, a jab
	(Fake Commit) before a cut when a defender is tight, a layout for a disc
	just out of reach, a pop-up out of the dive slide, Air Redirects toward
	a moving catch point and Precision Landings out of jumps.

	Positioning is field-relative (FieldGeometry; speeds from Config):
	  offense 7v7     a vertical stack ~18 studs downfield of the disc in a
	                  central lane, two handlers (a dump behind on the break
	                  side, one wide on the open side); stack cutters take
	                  turns cutting under or deep to the open side (set-up
	                  step away, cut, burst), then clear to the back
	  offense 3v3     one handler (the dump) and lane cutters who pick open
	                  space 10-38 % of the field ahead of the disc
	  defense         the defender closest to the holder marks (a human
	                  who steps up with the mark stance takes it over from a
	                  bot); everyone else guards one attacker per possession,
	                  goal side, from a reaction-lagged read of their position
	  disc in flight  the best-placed bot of each team chases the earliest
	                  reachable point (one shared prediction per flight;
	                  a human teammate who gets there as fast has priority)
	                  and jumps, reaches or lays out; the rest keep shape
	  pull            the pulling team runs down onto its marks, the
	                  receivers spread around the landing spot
	  ground          the nearest attacker picks the disc up
	The open / break side comes from the defenders' force (UBState ForceA/B,
	FH or BH relative to the thrower).

	MARKER (diag 3 §5). Stands MarkDistance upfield of the pivot P, shaded
	toward the break side, and mirrors the thrower's step from a reaction-
	lagged position (MovementService.positionAt, lag 0.30 - 0.15 x skill)
	with gain 0.55 + 0.35 x skill, clamped to MirrorMax; it shuffles with the
	sim's mark overlay, facing P. Low stance by default, High only while an
	overhead windup is really live (after the reaction delay). Bites on
	fakes (FakeT / FakeSide; 0.6 - 0.4 x skill, never twice in 1.2 s) and
	jump-blocks hops (0.35 x skill), reacting on the Heartbeat the hop is
	seen, since the rewound hand-block test only counts a jump that had
	started where the thrower could see it.

	THROWER (diag 3 §6). Lets the sim plant the pivot, reads the receivers,
	then picks the release side away from the marker's shade in the throw
	frame and steps out (0.6 + 0.4 x skill) R (Low against a High mark, a
	hammer over a closed lane). With probability 0.35 x skill it fakes toward
	the mark and Quick Swings away (a Sold swing; the release right after is
	a Break). Before releasing it solves the pass from its real pivot + step
	and tests 2-4 candidate releases with ThrowService.previewBlock (weaker
	bots sometimes skip the test); when every release would be blocked it
	swings to the other side and looks again.

	Bots only play while they are on their team's line (TeamService.lineFor);
	a bot that is not (about to be replaced) stands still. Training drills
	drive bots with custom brains (spawn(team, brain, role), run every frame)
	and the helpers at the end (setGoal, mark, unmark, chase, press, setSkill,
	stand). At most one pass solve (Solver) runs per frame across all bots.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Actors = require(Shared.Actors)
local Rng = require(Shared.Util.Rng)
local VecMath = require(Shared.Util.VecMath)
local TeamsConfig = require(Shared.Config.Teams)
local DiscConfig = require(Shared.Config.Disc)
local MovementConfig = require(Shared.Config.Movement)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local Solver = require(Shared.Disc.Solver)
local FieldGeometry = require(Shared.Rules.FieldGeometry)
local RulesEngine = require(Shared.Rules.RulesEngine)
local MovementSim = require(Shared.Movement.MovementSim)
local Locomotion = require(Shared.Animation.Locomotion)

local BotService = {}

local services: any
local folder: Folder

local MC = MovementConfig
local HD = MC.Holding
local MK = MC.Marking
local DM = DiscConfig.Mark
local R = HD.StepRadius
local JOG = MC.JogSpeed
local SPRINT = MC.SprintSpeed

local THINK_EVERY = 0.1
local ARRIVE_DECEL = 45 -- studs/s^2: the approach to a spot ramps speed down like this
local ARRIVE_RADIUS = 0.8 -- stop inside this ...
local RESUME_RADIUS = 1.6 -- ... and only move again beyond this (no jitter on a spot)
local MARK_GAIN = 7 -- mark shuffle: studs/s of velocity per stud from the mark spot
local FOLLOW_GAIN = 2.5 -- moving target: studs/s of correction per stud of error
local BLOCK_RAY = 2.5
local AIR_GRACE = 0.12
local SPEED_SMOOTH = 20
local FLIGHT_DT = 1 / 60
local CATCH_HEIGHT = 9 -- disc centre height (above the ground) a jumping bot can reach
local HAND_CHECK_SKIP = 0.3 -- weaker bots skip the hand-block test this often
local OVERHEAD = { Hammer = true, Scoober = true }
local POSE_MODES = { Slide = true, Dive = true, DiveSlide = true, Recover = true, Pivot = true, Mark = true }

export type Press = { action: string, dir: Vector3?, side: number, at: number }

-- A cutter's run: a set-up step away, optionally a jab, then the cut.
type CutPlan = {
	kind: string, -- "Under" | "Deep" | "Spot" | "Dump"
	phase: string, -- "Set" | "Jab" | "Go"
	target: Vector3,
	setFrom: Vector3,
	setDir: Vector3,
	setLen: number,
	phaseAt: number,
	untilT: number,
	juke: boolean,
}

type MarkState = {
	holder: number,
	lastFakeT: number,
	lastBite: number,
	biteStart: number,
	biteUntil: number,
	biteLateral: number,
	biteHigh: boolean,
	hopKey: number,
}

type HoldPlan = {
	phase: string, -- "Settle" | "Look" | "Setup" | "Swing"
	at: number,
	since: number,
	waitUntil: number,
	receiver: number?,
	throwType: string,
	height: string,
	side: number, -- release side in the throw frame (-1 left, +1 right)
	charged: number,
	swingEnd: number,
	attempts: number,
}

export type Bot = {
	id: number,
	name: string,
	team: string,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	align: AlignOrientation,
	loco: Locomotion.Controller?,
	rng: Rng.Rng,
	skill: number,
	reaction: number,
	sim: MovementSim.State,
	-- intent (brain output)
	target: Vector3?,
	targetVel: Vector3?, -- the target moves (a guard's man): match it, no stop radius
	speed: number,
	face: Vector3?,
	aim: Vector3?,
	step: Vector3?,
	marking: boolean,
	presses: { Press },
	custom: ((Bot, number) -> ())?,
	nextThink: number,
	-- motor
	arrived: boolean,
	holding: boolean,
	lastTeleport: any,
	jumpArmed: boolean,
	speedSmooth: number,
	facing: Vector3,
	alignFacing: Vector3,
	aiming: boolean,
	poseMode: string,
	airSince: number?,
	precisionArmed: boolean,
	armedAt: number,
	popPending: boolean,
	diveRoll: string,
	nextTechAt: number, -- brain-initiated cuts at most this often (no spam)
	squared: boolean, -- a guard on his man faces the play (with hysteresis)
	-- brain memory
	cut: CutPlan?,
	mark: MarkState?,
	hold: HoldPlan?,
	nextSpotAt: number,
	stanceOn: boolean,
	stanceName: string,
}

type Body = { id: number, team: string, isBot: boolean, pos: Vector3, vel: Vector3 }

type FlightSample = { t: number, pos: Vector3 }

type Flight = {
	key: string,
	samples: { FlightSample },
	land: Vector3,
	landT: number,
}

type World = {
	frame: number,
	t: number,
	e: RulesEngine.State,
	phase: string,
	d: any,
	f: FieldGeometry.Field,
	bodies: { [number]: Body },
	team: { [string]: { Body } },
	lines: { [string]: { number } },
	flight: Flight?,
	chasers: { [string]: number },
	markerChecked: { [string]: boolean },
	teamSize: number,
	stall: number,
	stallMax: number,
}

type TeamPlan = {
	point: number,
	offense: boolean,
	holder: number?,
	roles: { [number]: string }, -- "Handler" | "Cutter"
	handlers: { number },
	cutters: { number }, -- stack order, front first
	nextCutAt: number,
	guards: { [number]: number }, -- defending bot -> attacker
	marker: number?,
	markerAwaySince: number?,
}

local brains: { [number]: Bot } = {}
local plans: { [string]: TeamPlan } = {}
local flights: { [string]: Flight } = {}
local nextId = Actors.BotIdBase
local seedCounter = 0
local frameNo = 0
local world: World? = nil
local lastSolveFrame = -1
local planRng = Random.new()
local lastWarn: { [number]: number } = {}

local NAMES = {
	"Huck Norris",
	"Flick Jagger",
	"Layla Out",
	"Hammer Time",
	"Scoober Doo",
	"Stall Ten",
	"Pivot Pete",
	"Blade Runner",
	"Callahan Kid",
	"Greatest Gwen",
	"Bricky",
	"Swing Lowe",
	"Dump Truck",
	"Deep Dana",
	"Break Mark",
	"Zone Defense",
	"Spin Doctor",
	"Pancake",
	"Hospital Hal",
	"Sky Walker",
}

local SKIN = {
	Color3.fromRGB(255, 220, 190),
	Color3.fromRGB(234, 184, 146),
	Color3.fromRGB(198, 140, 100),
	Color3.fromRGB(141, 92, 62),
	Color3.fromRGB(96, 62, 42),
}

local NO_INPUT: MovementSim.Input = { move = Vector3.zero, sprint = false }

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function now(): number
	return Net.now()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function rightOf(forward: Vector3): Vector3
	return Vector3.new(-forward.Z, 0, forward.X)
end

local function teamColor(team: string): (Color3, Color3)
	if team == "A" then
		return TeamsConfig.A.Color, TeamsConfig.A.Dark
	elseif team == "B" then
		return TeamsConfig.B.Color, TeamsConfig.B.Dark
	end
	return TeamsConfig.Neutral.Color, Color3.fromRGB(80, 80, 90)
end

---------------------------------------------------------------------------
-- spawning
---------------------------------------------------------------------------

function BotService.spawn(team: string, custom: ((any, number) -> ())?, role: string?): number
	nextId -= 1
	seedCounter += 1
	local id = nextId
	local rng = Rng.new(seedCounter * 2654435761 + 97)
	local name = NAMES[((seedCounter - 1) % #NAMES) + 1]
	local shirt, shorts = teamColor(team)
	local desc = Instance.new("HumanoidDescription")
	local skin = SKIN[rng:int(1, #SKIN)]
	desc.HeadColor = skin
	desc.LeftArmColor = skin
	desc.RightArmColor = skin
	desc.TorsoColor = shirt
	desc.LeftLegColor = shorts
	desc.RightLegColor = shorts
	-- the same standard body as every player (fixed hitbox)
	services.PlayerService.standardize(desc)

	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not model then
		warn("[BotService] could not create bot model: " .. tostring(model))
		return id
	end
	local m = model :: Model
	m.Name = "Bot_" .. name
	local humanoid = m:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart
	if not humanoid or not root then
		m:Destroy()
		return id
	end
	m:PivotTo(services.ArenaService.spawnCFrame() + Vector3.new(rng:range(-6, 6), 0, rng:range(-3, 3)))
	m.Parent = folder
	root:SetNetworkOwner(nil)
	local actor = services.PlayerService.registerBot(id, name .. " [BOT]", team, m)
	if role then
		services.PlayerService.setTeam(actor, team, role)
	end

	-- the sim drives the body: no engine walking, jumping or turning
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = 0
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0
	for _, st in
		{
			Enum.HumanoidStateType.Climbing,
			Enum.HumanoidStateType.Seated,
			Enum.HumanoidStateType.Ragdoll,
			Enum.HumanoidStateType.FallingDown,
		}
	do
		humanoid:SetStateEnabled(st, false)
	end
	local att = Instance.new("Attachment")
	att.Name = "UBFaceAttachment"
	att.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "UBFace"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = false
	align.Responsiveness = 30
	align.MaxTorque = 1e7
	align.MaxAngularVelocity = 20
	align.CFrame = root.CFrame.Rotation
	align.Parent = root

	local look = VecMath.flatUnit(root.CFrame.LookVector)
	if look.Magnitude < 0.5 then
		look = Vector3.new(0, 0, -1)
	end
	local brain: Bot = {
		id = id,
		name = name,
		team = team,
		model = m,
		humanoid = humanoid,
		root = root,
		align = align,
		loco = nil,
		rng = rng,
		skill = rng:range(0.6, 0.85),
		reaction = rng:range(0.18, 0.32),
		sim = MovementSim.new(now()),
		target = nil,
		targetVel = nil,
		speed = JOG,
		face = nil,
		aim = nil,
		step = nil,
		marking = false,
		presses = {},
		custom = custom,
		nextThink = now() + rng:range(0, THINK_EVERY),
		arrived = true,
		holding = false,
		lastTeleport = m:GetAttribute("UBTeleport"),
		jumpArmed = false,
		speedSmooth = 0,
		facing = look,
		alignFacing = look,
		aiming = false,
		poseMode = "Ground",
		airSince = nil,
		precisionArmed = false,
		armedAt = 0,
		popPending = false,
		diveRoll = "",
		nextTechAt = 0,
		squared = false,
		cut = nil,
		mark = nil,
		hold = nil,
		nextSpotAt = 0,
		stanceOn = false,
		stanceName = "",
	}
	brain.sim.pos = root.Position
	brains[id] = brain
	task.spawn(function()
		local okLoco, loco = pcall(Locomotion.new, humanoid)
		if okLoco and brains[id] == brain then
			brain.loco = loco
		end
	end)
	return id
end

function BotService.remove(id: number)
	local b = brains[id]
	brains[id] = nil
	lastWarn[id] = nil
	if b and b.loco then
		Locomotion.destroy(b.loco)
	end
	services.PlayerService.unregisterBot(id)
end

function BotService.brain(id: number): Bot?
	return brains[id]
end

---------------------------------------------------------------------------
-- intent helpers
---------------------------------------------------------------------------

-- Queues a press for the motor (`delay` seconds from now).
local function press(b: Bot, action: string, dir: Vector3?, delay: number?, side: number?)
	table.insert(b.presses, { action = action, dir = dir, side = side or 0, at = now() + (delay or 0) })
end

local function canSpend(b: Bot, cost: number): boolean
	return b.sim.exertion >= cost + 15
end

local function ready(b: Bot, tech: string): boolean
	return MovementSim.readiness(b.sim, tech) >= 1
end

local function setStance(b: Bot, on: boolean, stance: string)
	if b.stanceOn ~= on or (on and b.stanceName ~= stance) then
		b.stanceOn = on
		b.stanceName = stance
		services.DefenseService.setStance(b.id, on, stance)
	end
end

local function clearMark(b: Bot)
	b.marking = false
	b.mark = nil
	if b.stanceOn then
		setStance(b, false, "Low")
	end
end

local function stand(b: Bot)
	b.target = nil
	b.targetVel = nil
	b.cut = nil
	b.face = nil
end

-- Sets where to go. With `tech`, a big change of direction at speed uses
-- the technique a player would: a Snap Cut (25-115 deg, sometimes chained
-- into a Perfect Burst) or a plant with an explosive restart (a reversal).
-- `force` presses the Cut whatever the angle (a cut out of a jab).
local function steerTo(b: Bot, target: Vector3, speed: number, tech: boolean?, force: boolean?)
	b.target = target
	b.targetVel = nil
	b.speed = speed
	if not tech then
		return
	end
	local sim = b.sim
	local t = now()
	if sim.mode ~= "Ground" or sim.holding or #b.presses > 0 or (t < b.nextTechAt and not force) then
		return
	end
	local pos = b.root.Position
	local toT = flat(target - pos)
	local dist = toT.Magnitude
	local sp = sim.vel.Magnitude
	if dist < 7 or sp < 8 then
		return
	end
	local d = toT / dist
	local angle = VecMath.flatAngle(sim.vel, d)
	if force or (angle >= 35 and angle <= 115) then
		if not canSpend(b, MC.SnapCut.Cost) then
			return
		end
		b.nextTechAt = t + b.rng:range(0.6, 1.2)
		press(b, "Cut", d)
		if
			dist > 16
			and ready(b, "BurstStep")
			and canSpend(b, MC.SnapCut.Cost + MC.BurstStep.Cost)
			and b.rng:next() < b.skill * 0.6
		then
			press(b, "Burst", d, 0.1)
		end
	elseif angle > 125 and sp >= 12 and ready(b, "MomentumCancel") and canSpend(b, MC.MomentumCancel.Cost) then
		-- plant; the sim restarts toward the held direction, a Burst in the
		-- window makes it explosive
		b.nextTechAt = t + b.rng:range(0.8, 1.4)
		press(b, "Cut", d)
		if b.rng:next() < b.skill * 0.7 then
			press(b, "Burst", d, 0.12)
		end
	end
end

---------------------------------------------------------------------------
-- motor (every Heartbeat)
---------------------------------------------------------------------------

local function refreshFilter()
	local list: { Instance } = {}
	for _, c in Actors.characters() do
		table.insert(list, c)
	end
	if folder then
		table.insert(list, folder)
	end
	local visuals = workspace:FindFirstChild("UBVisuals")
	if visuals then
		table.insert(list, visuals)
	end
	rayParams.FilterDescendantsInstances = list
end

local function standHeight(b: Bot): number
	if b.humanoid.RigType == Enum.HumanoidRigType.R15 then
		return b.humanoid.HipHeight + b.root.Size.Y / 2
	end
	return 3
end

local function buildEnv(b: Bot): MovementSim.Env
	local h, r = b.humanoid, b.root
	local pos = r.Position
	local vel = r.AssemblyLinearVelocity
	local stand = standHeight(b)
	local state = h:GetState()
	local grounded = h.FloorMaterial ~= Enum.Material.Air
		and state ~= Enum.HumanoidStateType.Jumping
		and state ~= Enum.HumanoidStateType.Freefall
	if not grounded and vel.Y <= 6 then
		grounded = workspace:Raycast(pos, Vector3.new(0, -(stand + 1.2), 0), rayParams) ~= nil
	end
	local ttl: number? = nil
	if not grounded then
		local far = workspace:Raycast(pos, Vector3.new(0, -120, 0), rayParams)
		if far then
			local height = math.max(0, pos.Y - stand - far.Position.Y)
			local g = workspace.Gravity
			ttl = (vel.Y + math.sqrt(math.max(vel.Y * vel.Y + 2 * g * height, 0))) / g
		end
	end
	local blocked = false
	local sv = flat(b.sim.vel)
	if sv.Magnitude > 6 then
		blocked = workspace:Raycast(pos, sv.Unit * BLOCK_RAY, rayParams) ~= nil
	end
	local aim = b.aim
	return {
		grounded = grounded,
		actualVel = vel,
		timeToLand = ttl,
		facing = r.CFrame.LookVector,
		pos = pos,
		aimYaw = if b.sim.holding and aim then VecMath.yaw(aim) else nil,
		blocked = blocked,
	}
end

-- Pre-pull line: (x - UBLineX) * UBLineSide >= 0 (the client's rule).
local function lineOf(c: Model): (number?, number)
	local lx = c:GetAttribute("UBLineX")
	local ls = c:GetAttribute("UBLineSide")
	if type(lx) ~= "number" or type(ls) ~= "number" or ls == 0 then
		return nil, 0
	end
	return lx, if ls > 0 then 1 else -1
end

local function applyLine(c: Model, pos: Vector3, v: Vector3): Vector3
	local lx, side = lineOf(c)
	if lx == nil then
		return v
	end
	local inside = (pos.X - lx) * side
	local along = v.X * side
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

local function lineClamp(b: Bot, target: Vector3): Vector3
	local lx, side = lineOf(b.model)
	if lx == nil or (target.X - lx) * side >= 1 then
		return target
	end
	return Vector3.new(lx + side, target.Y, target.Z)
end

-- Turns the brain's intent into sim input.
local function inputFor(b: Bot): MovementSim.Input
	local sim = b.sim
	if sim.holding then
		local s = b.step
		if s then
			local m = flat(s) / R
			if m.Magnitude > 1 then
				m = m.Unit
			end
			if m.Magnitude > 0.05 then
				return { move = m, sprint = false }
			end
		end
		return NO_INPUT
	end
	local goal = b.target
	if not goal then
		b.arrived = true
		return NO_INPUT
	end
	local target = lineClamp(b, goal)
	local d = flat(target - b.root.Position)
	local dist = d.Magnitude
	if b.marking then
		if dist < 0.2 then
			return NO_INPUT
		end
		local want = math.min(MK.ShuffleSpeed, dist * MARK_GAIN)
		return { move = (d / dist) * (want / MK.ShuffleSpeed), sprint = false }
	end
	local tv = b.targetVel
	if tv then
		-- a moving spot: match its velocity and close the gap smoothly (no
		-- stop radius, so no stop-start stutter behind a moving man)
		local corr = if dist > 0.05 then (d / dist) * math.min(dist * FOLLOW_GAIN, b.speed) else Vector3.zero
		local want = flat(tv) + corr
		local sp = math.min(want.Magnitude, b.speed)
		if sp < 0.6 then
			b.arrived = true
			return NO_INPUT
		end
		b.arrived = false
		local sprint = sp > JOG + 0.5
		local top = if sprint then SPRINT else JOG
		return { move = want.Unit * math.clamp(sp / top, 0.1, 1), sprint = sprint }
	end
	if dist < (if b.arrived then RESUME_RADIUS else ARRIVE_RADIUS) then
		b.arrived = true
		return NO_INPUT
	end
	b.arrived = false
	local want = math.min(b.speed, math.sqrt(2 * ARRIVE_DECEL * math.max(dist - 0.5, 0)))
	local sprint = want > JOG + 0.5
	local top = if sprint then SPRINT else JOG
	return { move = (d / dist) * math.clamp(want / top, 0.15, 1), sprint = sprint }
end

-- Fires the presses that are due. A directional press also steers this frame.
local function runPresses(b: Bot, input: MovementSim.Input, env: MovementSim.Env): MovementSim.Input
	local sim = b.sim
	local t = now()
	local out = input
	local i = 1
	while i <= #b.presses do
		local p = b.presses[i]
		if t < p.at then
			i += 1
			continue
		end
		table.remove(b.presses, i)
		if t - p.at > 0.5 then
			continue -- stale (frozen, teleported, ...)
		end
		if p.action == "Swing" then
			MovementSim.swing(sim, p.side, env)
		elseif p.action == "Fake" then
			MovementSim.fakeStep(sim, p.side)
		else
			local inp = out
			local dir = p.dir
			if dir and dir.Magnitude > 0.1 and not sim.holding then
				inp = { move = VecMath.flatUnit(dir), sprint = true }
			end
			local ok = MovementSim.press(sim, p.action :: any, inp, env)
			if ok then
				if dir then
					out = inp
				end
				if p.action == "Jump" and not sim.holding then
					b.precisionArmed = b.rng:next() < 0.35 + 0.5 * b.skill
					b.armedAt = t
				elseif p.action == "Dive" then
					b.popPending = b.rng:next() < 0.5 + 0.5 * b.skill
				end
			end
		end
	end
	return out
end

-- Player habits the brain's 10 Hz can't time: a Precision Landing just
-- before touchdown and a pop-up the moment the dive slide stops.
-- Jump-block a hop the moment it is seen (one roll per possession: the
-- holder hops once). No think-rate wait and no reaction delay: the hand-block
-- test rewinds markers to where the thrower saw them, so any later jump
-- would only ever leave the ground after the disc had gone.
local function jumpBlock(b: Bot, env: MovementSim.Env)
	local mk = b.mark
	if not mk or not b.stanceOn or b.stanceName ~= "Low" then
		return
	end
	local hroot = Actors.rootOf(mk.holder)
	local hc = hroot and hroot.Parent
	if not hc or hc:GetAttribute("MS") ~= "Air" or services.MovementService.pivotOf(mk.holder) == nil then
		return
	end
	local held = hc:GetAttribute("HeldSince")
	local key = if type(held) == "number" then held else 1
	if mk.hopKey ~= key then
		mk.hopKey = key
		if b.rng:next() < 0.35 * b.skill then
			MovementSim.press(b.sim, "Jump", NO_INPUT, env)
		end
	end
end

local function reflexes(b: Bot, env: MovementSim.Env)
	local sim = b.sim
	jumpBlock(b, env)
	if b.precisionArmed then
		local ttl = env.timeToLand
		if sim.landedAt > b.armedAt + 0.05 then
			b.precisionArmed = false
		elseif sim.mode == "Air" and ttl ~= nil and ttl <= 0.07 then
			b.precisionArmed = false
			MovementSim.press(sim, "Slide", NO_INPUT, env)
		end
	end
	if b.popPending then
		if sim.mode == "Recover" then
			b.popPending = false
			local goal = b.target
			if goal then
				local d = flat(goal - b.root.Position)
				if d.Magnitude > 4 then
					MovementSim.press(sim, "Cut", { move = d.Unit, sprint = true }, env)
				end
			end
		elseif sim.mode == "Ground" or sim.mode == "Landing" or sim.holding then
			b.popPending = false
		end
	end
end

local function drive(b: Bot, out: MovementSim.Output, v: Vector3)
	local h, r = b.humanoid, b.root
	local sp = v.Magnitude
	h.WalkSpeed = sp
	h:Move(if sp > 0.05 then v / sp else Vector3.zero, false)
	local vy = out.setVertical
	if out.jump and vy then
		h.JumpPower = vy
		h:ChangeState(Enum.HumanoidStateType.Jumping)
		b.jumpArmed = true
	end
	if out.impulse or vy then
		local cur = r.AssemblyLinearVelocity
		r.AssemblyLinearVelocity = Vector3.new(v.X, vy or cur.Y, v.Z)
	end
end

local function facingFor(b: Bot, v: Vector3): (Vector3?, boolean)
	local sim = b.sim
	if sim.holding then
		return b.aim or b.face, true
	end
	if sim.mode == "Dive" or sim.mode == "DiveSlide" then
		return sim.diveDir, false
	end
	if b.face then
		return b.face, true
	end
	if v.Magnitude > 4 then
		return VecMath.flatUnit(v), false
	end
	return nil, false
end

local function onTeleport(b: Bot)
	local r = b.root
	r.AssemblyLinearVelocity = Vector3.zero
	r.AssemblyAngularVelocity = Vector3.zero
	MovementSim.reset(b.sim) -- keeps frozen, holding, exertion, cooldowns and the pivot
	b.sim.pos = r.Position
	table.clear(b.presses)
	b.arrived = false
	b.cut = nil
	b.precisionArmed = false
	b.popPending = false
	local yaw = b.model:GetAttribute("UBTeleportYaw")
	local look = if type(yaw) == "number" then VecMath.fromYaw(yaw) else VecMath.flatUnit(r.CFrame.LookVector)
	if look.Magnitude > 0.5 then
		b.facing = look
	end
end

local function motor(b: Bot, dt: number)
	local c, h, r = b.model, b.humanoid, b.root
	if h.Health <= 0 or not r.Parent then
		return
	end
	local sim = b.sim
	local step = math.min(dt, 1 / 15)
	sim.now = now() - step -- the sim clock is server time

	if b.jumpArmed then
		b.jumpArmed = false
		h.JumpPower = 0
	end
	local tp = c:GetAttribute("UBTeleport")
	if tp ~= b.lastTeleport then
		b.lastTeleport = tp
		onTeleport(b)
	end
	local frozen = c:GetAttribute("UBFrozen") == true
	if frozen ~= sim.frozen then
		MovementSim.setFrozen(sim, frozen)
		if frozen then
			table.clear(b.presses)
		end
	end

	local env = buildEnv(b)
	local hasDisc = c:GetAttribute("HasDisc") == true
	if hasDisc ~= b.holding then
		b.holding = hasDisc
		MovementSim.setHolding(sim, hasDisc, env.grounded)
		if not hasDisc then
			b.step = nil
			b.aim = nil
		end
	end
	if sim.holding then
		MovementSim.setPivot(sim, services.MovementService.pivotOf(b.id))
	end
	if b.marking ~= MovementSim.isMarking(sim) then
		MovementSim.setMarking(sim, b.marking)
	end

	local input = runPresses(b, inputFor(b), env)
	reflexes(b, env)
	local out = MovementSim.step(sim, input, env, step)
	if b.marking and not MovementSim.isMarking(sim) then
		b.marking = false -- a Cut / Dive / Burst ended the mark inside the sim
	end

	local v = applyLine(c, r.Position, flat(out.vel))
	if v ~= out.vel then
		sim.vel = v
		sim.lastOutVel = v
	end
	drive(b, out, v)

	local face, aiming = facingFor(b, v)
	if face and face.Magnitude > 0.5 then
		b.facing = VecMath.flatUnit(face)
	end
	local align = b.align
	if aiming ~= b.aiming then
		b.aiming = aiming
		align.Responsiveness = if aiming then 45 else 30
		align.MaxAngularVelocity = if aiming then 40 else 20
	end
	if b.facing:Dot(b.alignFacing) < 0.99995 then
		b.alignFacing = b.facing
		align.CFrame = CFrame.lookAt(Vector3.zero, b.facing)
	end

	local mode = MovementSim.poseMode(sim)
	if mode ~= b.poseMode then
		b.poseMode = mode
		services.MovementService.setBotMode(b.id, mode)
	end
	for _, e in out.events do
		services.MovementService.botTech(b.id, e.tech, e.dir, mode, e.quality, e.info, e.t)
	end
	local pp = out.pivotPos
	if pp then
		services.MovementService.setPivot(b.id, pp)
	end

	local loco = b.loco
	if loco then
		local vel = r.AssemblyLinearVelocity
		local raw = Vector3.new(vel.X, 0, vel.Z).Magnitude
		b.speedSmooth += (raw - b.speedSmooth) * (1 - math.exp(-SPEED_SMOOTH * step))
		local state = h:GetState()
		local airborne = state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping
		local clock = os.clock()
		if airborne then
			b.airSince = b.airSince or clock
		else
			b.airSince = nil
		end
		local lm: Locomotion.Mode = "Ground"
		if POSE_MODES[mode] then
			lm = "Pose"
		elseif airborne and (state == Enum.HumanoidStateType.Jumping or clock - (b.airSince :: number) > AIR_GRACE) then
			lm = if vel.Y > 2 then "Rising" else "Falling"
		end
		Locomotion.update(loco, step, b.speedSmooth, lm)
	end
end

---------------------------------------------------------------------------
-- reading the game (one snapshot per frame)
---------------------------------------------------------------------------

local function flightFor(d: any): Flight?
	local s = d and d.sim
	if not d or d.mode ~= "Flight" or not s then
		return nil
	end
	local key = tostring(d.id) .. ":" .. tostring(d.flightId)
	local cached = flights[d.id]
	if cached and cached.key == key then
		return cached
	end
	local copy = DiscPhysics.copy(s)
	local ground = d.groundY
	local base = d.launchTime
	local samples: { FlightSample } = {}
	local land = Vector3.new(copy.px, ground, copy.pz)
	local landT = base + copy.t
	while copy.t < DiscConfig.Physics.MaxFlightTime do
		DiscPhysics.step(copy, FLIGHT_DT, d.wind)
		local p = Vector3.new(copy.px, copy.py, copy.pz)
		table.insert(samples, { t = base + copy.t, pos = p })
		land = Vector3.new(copy.px, ground, copy.pz)
		landT = base + copy.t
		if copy.py - ground <= DiscConfig.Physics.GroundContact then
			break
		end
	end
	local fl: Flight = { key = key, samples = samples, land = land, landT = landT }
	flights[d.id] = fl
	return fl
end

local function getWorld(): World?
	local w = world
	if w and w.frame == frameNo then
		return w
	end
	local e = services.MatchService.engine()
	if not e then
		return nil
	end
	local bodies: { [number]: Body } = {}
	local team: { [string]: { Body } } = { A = {}, B = {} }
	local lines: { [string]: { number } } = {}
	for _, tm in { "A", "B" } do
		for _, a in services.PlayerService.onTeam(tm) do
			local root = services.PlayerService.root(a)
			if root then
				local body: Body = {
					id = a.id,
					team = tm,
					isBot = a.isBot,
					pos = root.Position,
					vel = root.AssemblyLinearVelocity,
				}
				bodies[a.id] = body
				table.insert(team[tm], body)
			end
		end
		lines[tm] = services.TeamService.lineFor(tm)
	end
	local d = services.MatchService.disc()
	local mode = services.MatchService.mode()
	local nw: World = {
		frame = frameNo,
		t = now(),
		e = e,
		phase = services.MatchService.phase(),
		d = d,
		f = e.field,
		bodies = bodies,
		team = team,
		lines = lines,
		flight = flightFor(d),
		chasers = {},
		markerChecked = {},
		teamSize = mode.TeamSize,
		stall = services.DefenseService.stallCount(),
		stallMax = mode.StallMax,
	}
	world = nw
	return nw
end

local function nearest(pos: Vector3, list: { Body }, except: number?): (Body?, number)
	local best, bestD = nil, math.huge
	for _, body in list do
		if body.id ~= except then
			local dd = flat(body.pos - pos).Magnitude
			if dd < bestD then
				best, bestD = body, dd
			end
		end
	end
	return best, bestD
end

-- Clearance of the lane from `from` to `to`, ignoring anyone within `ignore`
-- studs of the thrower (the marker: the step-out goes around them).
local function laneClearance(from: Vector3, to: Vector3, list: { Body }, ignore: number): number
	local best = math.huge
	for _, body in list do
		local p = flat(body.pos)
		if (p - flat(from)).Magnitude > ignore then
			local c = VecMath.closestOnSegment(flat(from), flat(to), p)
			best = math.min(best, (c - p).Magnitude)
		end
	end
	return best
end

local function inField(f: FieldGeometry.Field, p: Vector3, inset: number, y: number): Vector3
	local c = FieldGeometry.clampInBounds(f, p, inset)
	return Vector3.new(c.X, y, c.Z)
end

local function forceOf(defense: string): string
	local v = Net.state():GetAttribute("Force" .. defense)
	return if v == "BH" then "BH" else "FH"
end

local function leftHanded(id: number?): boolean
	if not id then
		return false
	end
	local c = Actors.characterOf(id)
	return c ~= nil and c:GetAttribute("LeftHanded") == true
end

-- The open side (world, flat unit) for `team`'s offense: the side the
-- defenders' force leaves open, for a thrower facing upfield (`r` = right).
local function openSide(team: string, holderId: number?, r: Vector3): Vector3
	local mirror = if leftHanded(holderId) then -1 else 1
	local fh = r * mirror
	return if forceOf(RulesEngine.other(team)) == "BH" then -fh else fh
end

-- The holder's possession that team plans are built around (the pull's
-- holder is the puller, not an attacker).
local function possessionHolder(e: RulesEngine.State): number?
	if e.disc == "Held" and e.holderTeam == e.offense then
		return e.holder
	end
	return nil
end

---------------------------------------------------------------------------
-- team plans (roles and marks, sticky for a possession)
---------------------------------------------------------------------------

local function buildOffense(p: TeamPlan, w: World, team: string, ref: Vector3, holder: number?)
	local f = FieldGeometry.attackDirection(w.e.attack[team])
	local mates: { Body } = {}
	for _, body in w.team[team] do
		if body.id ~= holder then
			table.insert(mates, body)
		end
	end
	table.sort(mates, function(a, b)
		return flat(a.pos - ref).Magnitude < flat(b.pos - ref).Magnitude
	end)
	local handlers = math.min(if w.teamSize >= 5 then 2 else 1, #mates)
	for i, body in mates do
		if i <= handlers then
			p.roles[body.id] = "Handler"
			table.insert(p.handlers, body.id)
		else
			p.roles[body.id] = "Cutter"
			table.insert(p.cutters, body.id)
		end
	end
	table.sort(p.cutters, function(a, b)
		local pa, pb = w.bodies[a], w.bodies[b]
		return (pa.pos - ref):Dot(f) < (pb.pos - ref):Dot(f)
	end)
end

local function buildDefense(p: TeamPlan, w: World, team: string, ref: Vector3, holder: number?)
	local attackers: { Body } = {}
	for _, body in w.team[RulesEngine.other(team)] do
		if body.id ~= holder then
			table.insert(attackers, body)
		end
	end
	local marker = nearest(ref, w.team[team], nil)
	p.marker = if marker then marker.id else nil
	-- greedy closest pairs: every bot defender (but the marker) guards one attacker
	local pairs: { { d: number, def: number, att: number } } = {}
	for _, def in w.team[team] do
		if def.isBot and def.id ~= p.marker then
			for _, att in attackers do
				table.insert(pairs, { d = flat(def.pos - att.pos).Magnitude, def = def.id, att = att.id })
			end
		end
	end
	table.sort(pairs, function(a, b)
		return a.d < b.d
	end)
	local taken: { [number]: boolean } = {}
	for _, pr in pairs do
		if p.guards[pr.def] == nil and not taken[pr.att] then
			p.guards[pr.def] = pr.att
			taken[pr.att] = true
		end
	end
end

local function teamPlan(w: World, team: string, ref: Vector3): TeamPlan
	local e = w.e
	local offense = e.offense == team
	local holder = possessionHolder(e)
	local p = plans[team]
	if p and p.point == e.pointNumber and p.offense == offense and (holder == nil or holder == p.holder) then
		return p
	end
	local np: TeamPlan = {
		point = e.pointNumber,
		offense = offense,
		holder = holder,
		roles = {},
		handlers = {},
		cutters = {},
		nextCutAt = w.t + planRng:NextNumber(0.5, 1.2),
		guards = {},
		marker = nil,
		markerAwaySince = nil,
	}
	plans[team] = np
	if offense then
		buildOffense(np, w, team, ref, holder)
	else
		buildDefense(np, w, team, ref, holder)
	end
	return np
end

-- The mark goes to a human defender who steps up (mark stance on within
-- Marking.Range of P): the bot marker drops back to guarding. A human marker
-- who never steps up, or drifts out of StallRange, loses the mark to the
-- nearest bot after 1.2 s.
local function checkMarker(p: TeamPlan, w: World, team: string, holder: number, pivot: Vector3)
	if w.markerChecked[team] then
		return
	end
	w.markerChecked[team] = true
	local m = if p.marker then w.bodies[p.marker] else nil
	if m == nil or m.isBot then
		local human, humanD = nil, MC.Marking.Range
		for _, body in w.team[team] do
			local actor = if body.isBot then nil else services.PlayerService.get(body.id)
			if actor and actor.role == "Match" and services.DefenseService.stanceOf(body.id) ~= "Relaxed" then
				local dd = flat(body.pos - pivot).Magnitude
				if dd <= humanD then
					human, humanD = body, dd
				end
			end
		end
		if human then
			p.marker = human.id
			p.guards[human.id] = nil
			p.markerAwaySince = nil
			return
		end
	end
	if m and (m.isBot or flat(m.pos - pivot).Magnitude <= DM.StallRange) then
		p.markerAwaySince = nil
		return
	end
	local since = p.markerAwaySince
	if since == nil then
		p.markerAwaySince = w.t
		if m ~= nil then
			return
		end
	elseif w.t - since < 1.2 then
		return
	end
	local best, bestD = nil, math.huge
	for _, body in w.team[team] do
		if body.isBot and body.id ~= holder then
			local dd = flat(body.pos - pivot).Magnitude
			if dd < bestD then
				best, bestD = body, dd
			end
		end
	end
	if best then
		p.marker = best.id
		p.guards[best.id] = nil
		p.markerAwaySince = nil
	end
end

---------------------------------------------------------------------------
-- flights: chasing, jumping, reaching, laying out
---------------------------------------------------------------------------

-- Earliest catchable point of the flight `pos` can reach in time (inside
-- `field` when given: a catch out of bounds is a turnover).
local function interceptFrom(
	pos: Vector3,
	fl: Flight,
	groundY: number,
	reaction: number,
	t: number,
	field: FieldGeometry.Field?
): FlightSample?
	for _, smp in fl.samples do
		local tLeft = smp.t - t
		if
			tLeft > 0
			and smp.pos.Y - groundY < CATCH_HEIGHT
			and (field == nil or FieldGeometry.inBounds(field, smp.pos))
		then
			if flat(smp.pos - pos).Magnitude / SPRINT + reaction <= tLeft + 0.05 then
				return smp
			end
		end
	end
	return nil
end

-- The bot of `team` that should chase the current flight (0 = none): the
-- earliest arrival, unless a human teammate gets there about as fast.
local function chaserOf(w: World, team: string): number
	local cached = w.chasers[team]
	if cached ~= nil then
		return cached
	end
	local fl = w.flight
	local bestBot, bestBotT = 0, math.huge
	local bestHumanT = math.huge
	if fl then
		local groundY = w.d.groundY
		for _, body in w.team[team] do
			local b = brains[body.id]
			local reaction = if b then b.reaction * (1.4 - b.skill) else 0.15
			local smp = interceptFrom(body.pos, fl, groundY, reaction, w.t, if w.d.pull then nil else w.f)
			if smp then
				if body.isBot then
					if smp.t < bestBotT then
						bestBot, bestBotT = body.id, smp.t
					end
				elseif smp.t < bestHumanT then
					bestHumanT = smp.t
				end
			end
		end
		if bestHumanT <= bestBotT + 0.1 then
			bestBot = 0
		end
		-- a pull nobody can catch: the nearest receiver goes to where it lands
		if bestBot == 0 and bestHumanT == math.huge and w.d.pull and team == w.e.offense then
			local n = nearest(fl.land, w.team[team], nil)
			if n and n.isBot then
				bestBot = n.id
			end
		end
	end
	w.chasers[team] = bestBot
	return bestBot
end

-- Closest approach of the flight to `pos` (chest height) within `horizon`.
local function closestApproach(fl: Flight, pos: Vector3, t: number, horizon: number): (number, FlightSample?)
	local best, bestS = math.huge, nil
	local chest = pos + Vector3.new(0, DiscConfig.Catch.ChestHeight, 0)
	for _, smp in fl.samples do
		if smp.t > t + horizon then
			break
		end
		if smp.t > t then
			local dd = (smp.pos - chest).Magnitude
			if dd < best then
				best, bestS = dd, smp
			end
		end
	end
	return best, bestS
end

local function reachFor(b: Bot, point: Vector3)
	local dir = point - (b.root.Position + Vector3.new(0, 1.5, 0))
	services.CatchingService.reach(b.id, dir)
	if MovementSim.isAirborne(b.sim) then
		MovementSim.noteAerialReach(b.sim, dir)
	end
end

-- Runs toward the earliest reachable point of disc `d`'s flight (inside
-- `field` when given); jumps, reaches and lays out like a player. Returns
-- false when it can't get there.
local function chase(b: Bot, d: any, field: FieldGeometry.Field?): boolean
	local fl = flightFor(d)
	if not fl then
		return false
	end
	local t = now()
	local sim = b.sim
	local pos = b.root.Position
	local groundY = d.groundY
	local smp = interceptFrom(pos, fl, groundY, b.reaction * (1.4 - b.skill), t, field)
	local point = if smp then smp.pos elseif d.pull then fl.land else nil
	if not point then
		return false
	end
	b.cut = nil
	b.face = nil
	clearMark(b)
	local goal = Vector3.new(point.X, pos.Y, point.Z)
	b.target = goal
	b.targetVel = nil
	b.speed = SPRINT

	local miss, near = closestApproach(fl, pos, t, 0.6)
	if near then
		local tc = near.t - t
		local height = near.pos.Y - groundY
		local flatDist = flat(near.pos - pos).Magnitude
		local grounded = sim.mode == "Ground" or sim.mode == "Landing"
		-- a high disc: jump so the apex meets it
		if grounded and height > 6 and flatDist < 4 and tc > 0.12 and tc < 0.4 then
			press(b, "Jump")
		end
		-- reach for anything passing just outside the body
		if flatDist < 5 and tc < 0.3 and miss > 1.6 then
			reachFor(b, near.pos)
		end
		-- lay out for a low disc that will pass just out of reach
		if b.diveRoll ~= fl.key and miss > 2.4 and miss < 7.5 and tc < 0.42 and height < 4.5 and flatDist > 2.5 then
			b.diveRoll = fl.key
			if b.rng:next() < b.skill and ready(b, "Dive") then
				press(b, "Dive", flat(near.pos - pos))
			end
		end
		-- in the air: redirect toward a catch point that moved
		if sim.mode == "Air" and not sim.airRedirectUsed and sim.vel.Magnitude > 6 then
			local toGoal = flat(goal - pos)
			if toGoal.Magnitude > 3 and VecMath.flatAngle(sim.vel, toGoal) > 35 then
				press(b, "Cut", toGoal)
			end
		end
	end
	return true
end

---------------------------------------------------------------------------
-- offense
---------------------------------------------------------------------------

-- Starts a cut to `target`: a short set-up step first, either across the
-- cut (it then fires as a Snap Cut) or away from it (a plant and an
-- explosive restart), optionally a jab when a defender is tight.
local function startCut(b: Bot, w: World, kind: string, target: Vector3)
	local pos = b.root.Position
	local goal = inField(w.f, target, 4, pos.Y)
	local cutDir = VecMath.flatUnit(goal - pos)
	if cutDir.Magnitude < 0.5 then
		cutDir = FieldGeometry.attackDirection(w.e.attack[b.team])
	end
	local turn = if b.rng:next() < 0.55
		then math.rad(b.rng:range(70, 100)) * (if b.rng:next() < 0.5 then -1 else 1)
		else math.pi + math.rad(b.rng:range(-20, 20))
	local setLen = b.rng:range(3, 5)
	local setDir = CFrame.Angles(0, turn, 0):VectorToWorldSpace(cutDir)
	if not FieldGeometry.inBounds(w.f, pos + setDir * (setLen + 3)) then
		setDir = CFrame.Angles(0, -turn, 0):VectorToWorldSpace(cutDir) -- step the other way
	end
	local opp = w.team[RulesEngine.other(b.team)]
	local _, defDist = nearest(pos, opp, nil)
	local t = now()
	b.cut = {
		kind = kind,
		phase = "Set",
		target = goal,
		setFrom = pos,
		setDir = VecMath.flatUnit(setDir),
		setLen = setLen,
		phaseAt = t,
		untilT = t + 3.2,
		juke = defDist < 5 and b.rng:next() < 0.4 * b.skill,
	}
end

-- Runs the current cut. Returns false once it is over.
local function runCut(b: Bot): boolean
	local c = b.cut
	if not c then
		return false
	end
	local t = now()
	local pos = b.root.Position
	local sim = b.sim
	if t > c.untilT then
		b.cut = nil
		return false
	end
	if c.phase == "Set" then
		-- the set-up step away from the cut, kept at speed
		steerTo(b, c.setFrom + c.setDir * (c.setLen + 10), JOG + 4, false)
		local done = (pos - c.setFrom):Dot(c.setDir) >= c.setLen or t - c.phaseAt > 0.55
		if done then
			c.phaseAt = t
			if c.juke and sim.vel.Magnitude > 8 and sim.mode == "Ground" and canSpend(b, 20) then
				-- jab along the line (Fake Commit), then cut away (Sold)
				local line = VecMath.flatUnit(sim.vel)
				press(b, "Cut", line)
				b.target = pos + line * 8
				c.phase = "Jab"
			else
				c.phase = "Go"
				steerTo(b, c.target, SPRINT, true)
			end
		end
		return true
	elseif c.phase == "Jab" then
		if t - c.phaseAt >= 0.28 then
			c.phase = "Go"
			c.phaseAt = t
			steerTo(b, c.target, SPRINT, true, true)
		end
		return true
	end
	steerTo(b, c.target, SPRINT, false)
	if flat(c.target - pos).Magnitude < 3 then
		b.cut = nil
		return false
	end
	return true
end

-- Stack slot k of n: a central lane ~18 studs downfield of the disc,
-- compressed near the back of the attacking end zone.
local function stackSlot(w: World, ref: Vector3, f: Vector3, r: Vector3, k: number, n: number, y: number): Vector3
	local field = w.f
	local center = field.center
	local lat = math.clamp((ref - center):Dot(r) * 0.35, -(field.halfWidth - 12), field.halfWidth - 12)
	local back = field.halfLength + field.endZone - 4
	local start = (ref - center):Dot(f) + 18
	local spacing = math.min(8, (back - start) / math.max(n, 1))
	if spacing < 3 then
		spacing = 3
		start = back - 3 * n
	end
	local along = math.min(start + (k - 1) * spacing, back)
	local p = center + f * along + r * lat
	return Vector3.new(p.X, y, p.Z)
end

local function handler(b: Bot, w: World, plan: TeamPlan, ref: Vector3, f: Vector3, open: Vector3, holder: number?)
	local pos = b.root.Position
	local idx = table.find(plan.handlers, b.id) or 1
	-- the dump comes back for the disc when the stall climbs
	if idx == 1 and holder and not b.cut and w.stall >= math.max(3, math.floor(w.stallMax * 0.5)) then
		local spot = ref - f * 3 - open * 11
		local d = flat(spot - pos)
		if d.Magnitude > 6 then
			startCut(b, w, "Dump", spot)
			runCut(b)
			return
		end
	end
	local spot = if idx == 1 then ref - f * 8 - open * 7 else ref + f * 3 + open * 14
	spot = inField(w.f, spot, 4, pos.Y)
	local dist = flat(spot - pos).Magnitude
	steerTo(b, spot, if dist > 10 then SPRINT else JOG, dist > 12)
end

local function stackCutter(
	b: Bot,
	w: World,
	plan: TeamPlan,
	ref: Vector3,
	f: Vector3,
	r: Vector3,
	open: Vector3,
	holder: number?
)
	local t = w.t
	local pos = b.root.Position
	-- the front-most bot cutter takes the next cut
	local nextUp: number? = nil
	for _, id in plan.cutters do
		if brains[id] and not brains[id].cut then
			nextUp = id
			break
		end
	end
	if holder and nextUp == b.id and t >= plan.nextCutAt then
		local i = table.find(plan.cutters, b.id)
		if i then
			table.remove(plan.cutters, i)
			table.insert(plan.cutters, b.id)
		end
		plan.nextCutAt = t + planRng:NextNumber(1.0, 1.9)
		if b.rng:next() < 0.6 then
			startCut(b, w, "Under", ref + f * b.rng:range(9, 20) + open * b.rng:range(8, 18))
		else
			local deep = math.max(40, b.rng:range(0.3, 0.48) * w.f.length)
			startCut(b, w, "Deep", ref + f * deep + open * b.rng:range(2, 12))
		end
		runCut(b)
		return
	end
	local k = table.find(plan.cutters, b.id) or #plan.cutters
	local slot = stackSlot(w, ref, f, r, k, #plan.cutters, pos.Y)
	local dist = flat(slot - pos).Magnitude
	steerTo(b, slot, if dist > 12 then SPRINT else JOG, dist > 14)
end

local function spreadCutter(b: Bot, w: World, plan: TeamPlan, ref: Vector3, f: Vector3, r: Vector3, open: Vector3)
	local t = w.t
	local pos = b.root.Position
	if t < b.nextSpotAt and b.target then
		return
	end
	b.nextSpotAt = t + b.rng:range(1.2, 2.6)
	local field = w.f
	local n = math.max(#plan.cutters, 1)
	local k = table.find(plan.cutters, b.id) or 1
	local laneW = (field.width - 16) / n
	local laneCenter = -field.halfWidth + 8 + (k - 0.5) * laneW
	local opp = w.team[RulesEngine.other(b.team)]
	local mates = w.team[b.team]
	local best, bestScore = nil, -math.huge
	for _ = 1, 10 do
		local along = (ref - field.center):Dot(f) + b.rng:range(0.10, 0.38) * field.length
		local lat = laneCenter + b.rng:range(-laneW / 2 + 2, laneW / 2 - 2)
		local spot = inField(field, field.center + f * along + r * lat, 6, pos.Y)
		local _, openD = nearest(spot, opp, nil)
		local _, crowd = nearest(spot, mates, b.id)
		local score = math.min(openD, 20) * 1.5
			+ math.min(crowd, 15)
			+ (spot - ref):Dot(f) * 0.05
			+ (if (spot - ref):Dot(open) > 0 then 3 else 0)
		if score > bestScore then
			best, bestScore = spot, score
		end
	end
	if not best then
		return
	end
	local away = flat(best - pos)
	if away.Magnitude > 10 then
		startCut(b, w, "Spot", best)
		runCut(b)
	else
		steerTo(b, best, JOG, false)
	end
end

local function thinkOffense(b: Bot, w: World, ref: Vector3, holder: number?)
	clearMark(b)
	b.face = nil
	local plan = teamPlan(w, b.team, ref)
	local f = FieldGeometry.attackDirection(w.e.attack[b.team])
	local r = rightOf(f)
	local open = openSide(b.team, holder, r)
	local role = plan.roles[b.id]
	if role == nil then
		role = "Cutter"
		plan.roles[b.id] = role
		table.insert(plan.cutters, b.id)
	end
	if b.cut and runCut(b) then
		return
	end
	if role == "Handler" then
		handler(b, w, plan, ref, f, open, holder)
	elseif w.teamSize >= 5 then
		stackCutter(b, w, plan, ref, f, r, open, holder)
	else
		spreadCutter(b, w, plan, ref, f, r, open)
	end
end

---------------------------------------------------------------------------
-- defense
---------------------------------------------------------------------------

local function windupLive(c: Model, t: number): (boolean, number)
	local windup = c:GetAttribute("Windup")
	if type(windup) ~= "number" or windup <= 0 or t - windup > 3 then
		return false, 0
	end
	local release = c:GetAttribute("Release")
	local fake = c:GetAttribute("Fake")
	if (type(release) == "number" and release >= windup) or (type(fake) == "number" and fake >= windup) then
		return false, 0
	end
	return true, windup
end

-- The marker (diag 3 §5): shade the break side of the pivot, mirror the
-- lagged step, bite on fakes, stance from the live windup, jump-block hops.
-- `up` points from the thrower toward the end zone they attack.
local function runMark(b: Bot, holderId: number, up: Vector3, force: string)
	local hroot = Actors.rootOf(holderId)
	local hc = hroot and hroot.Parent
	if not hroot or not hc or not hc:IsA("Model") then
		return
	end
	local t = now()
	local m = b.mark
	if not m or m.holder ~= holderId then
		local ft = hc:GetAttribute("FakeT")
		m = {
			holder = holderId,
			lastFakeT = if type(ft) == "number" then ft else 0,
			lastBite = -math.huge,
			biteStart = 0,
			biteUntil = 0,
			biteLateral = 0,
			biteHigh = false,
			hopKey = 0,
		}
		b.mark = m
	end
	local mk = m :: MarkState
	b.cut = nil
	local skill = b.skill
	local pos = b.root.Position
	local pivot = services.MovementService.pivotOf(holderId)
	local P = pivot or hroot.Position
	local upU = VecMath.flatUnit(up)
	local r = rightOf(upU)
	local mirrorSign = if hc:GetAttribute("LeftHanded") == true then -1 else 1
	-- FH force: take away the backhand side (the thrower's left)
	local shade = if force == "BH" then r * mirrorSign else -r * mirrorSign

	-- mirror the step the thrower had a reaction time ago
	local lag = 0.30 - 0.15 * skill
	local lagged = services.MovementService.positionAt(holderId, t - lag)
	local stepLat = flat(lagged - P):Dot(r) / HD.BodyShare
	local mirror = math.clamp(stepLat * (0.55 + 0.35 * skill), -DM.MirrorMax, DM.MirrorMax)

	-- bite on a fake
	local ft = hc:GetAttribute("FakeT")
	if type(ft) == "number" and ft > mk.lastFakeT then
		mk.lastFakeT = ft
		if t - mk.lastBite > 1.2 and b.rng:next() < 0.6 - 0.4 * skill then
			local side = hc:GetAttribute("FakeSide")
			local fs = if type(side) == "number" then side else 0
			local thrRight = VecMath.flatUnit(hroot.CFrame.RightVector)
			local lat = thrRight:Dot(r) * fs
			mk.lastBite = t
			mk.biteStart = t + b.reaction * (1.2 - skill)
			mk.biteUntil = mk.biteStart + 0.45
			mk.biteLateral = if math.abs(lat) > 0.2 then math.sign(lat) * 1.4 else 0
			mk.biteHigh = OVERHEAD[hc:GetAttribute("WindupType") :: any] == true
		end
	end
	local biting = t >= mk.biteStart and t < mk.biteUntil
	local lateral = mirror + (if biting then mk.biteLateral else 0)
	local spot = P + upU * DM.MarkDistance + shade * DM.Shade + r * lateral
	local target = Vector3.new(spot.X, pos.Y, spot.Z)

	-- stance: Low, High only for a live overhead windup (seen after the reaction)
	local stance = "Low"
	local live, windupAt = windupLive(hc, t)
	if live and OVERHEAD[hc:GetAttribute("WindupType") :: any] and t - windupAt >= b.reaction * (1.4 - skill) then
		stance = "High"
	end
	if biting and mk.biteHigh then
		stance = "High"
	end
	setStance(b, true, stance)

	-- (the hop itself is jump-blocked by reflexes(), every Heartbeat)

	local away = flat(target - pos).Magnitude
	if away > (if b.marking then 8 else 5) then
		-- still getting there: run (facing the way we run)
		b.face = nil
		b.marking = false
		steerTo(b, target, SPRINT, false)
	else
		b.face = VecMath.flatUnit(P - pos)
		b.marking = true
		b.target = target
		b.targetVel = nil
		b.speed = MK.ShuffleSpeed
	end
end

local function guard(b: Bot, w: World, plan: TeamPlan, ref: Vector3, holder: number?)
	clearMark(b)
	b.face = nil
	local offense = RulesEngine.other(b.team)
	local up = FieldGeometry.attackDirection(w.e.attack[offense])
	local pos = b.root.Position
	local attId = plan.guards[b.id]
	local att = if attId and attId ~= holder then w.bodies[attId] else nil
	if not att then
		-- pick up the nearest attacker nobody else guards
		local taken: { [number]: boolean } = {}
		for def, a in plan.guards do
			if def ~= b.id then
				taken[a] = true
			end
		end
		local best, bestD = nil, math.huge
		for _, body in w.team[offense] do
			if body.id ~= holder and not taken[body.id] then
				local dd = flat(body.pos - pos).Magnitude
				if dd < bestD then
					best, bestD = body, dd
				end
			end
		end
		att = best
		if best then
			plan.guards[b.id] = best.id
		else
			plan.guards[b.id] = nil
		end
	end
	if not att then
		-- nobody left: help deep
		local spot = inField(w.f, ref + up * (0.12 * w.f.length), 4, pos.Y)
		steerTo(b, spot, JOG, false)
		return
	end
	local lag = b.reaction * (1.5 - b.skill)
	local lagged = services.MovementService.positionAt(att.id, w.t - lag)
	local toDisc = VecMath.flatUnit(ref - lagged)
	local deep = (lagged - ref):Dot(up)
	local spot = lagged + up * (if deep > 25 then 4 else 3) + toDisc * 2 + flat(att.vel) * 0.3
	spot = inField(w.f, spot, 2, pos.Y)
	local dist = flat(spot - pos).Magnitude
	-- on the man: square up between him and the disc (shuffle, backpedal)
	b.squared = if b.squared then dist < 6 else dist < 3
	b.face = if b.squared then VecMath.flatUnit((att.pos + ref) / 2 - pos) else nil
	steerTo(b, spot, SPRINT, dist > 10)
	b.targetVel = flat(att.vel)
end

local function thinkDefense(b: Bot, w: World, ref: Vector3, holder: number?)
	local plan = teamPlan(w, b.team, ref)
	if holder then
		local hb = w.bodies[holder]
		local pivot = services.MovementService.pivotOf(holder) or (if hb then hb.pos else ref)
		checkMarker(plan, w, b.team, holder, pivot)
		if plan.marker == b.id then
			local up = FieldGeometry.attackDirection(w.e.attack[RulesEngine.other(b.team)])
			runMark(b, holder, up, forceOf(b.team))
			return
		end
	elseif plan.marker == b.id and w.e.disc == "Ground" then
		-- set up the mark on the disc before it is picked up
		clearMark(b)
		local up = FieldGeometry.attackDirection(w.e.attack[RulesEngine.other(b.team)])
		local pos = b.root.Position
		local spot = inField(w.f, ref + up * DM.MarkDistance, 2, pos.Y)
		b.face = if flat(spot - pos).Magnitude < 4 then VecMath.flatUnit(ref - pos) else nil
		steerTo(b, spot, SPRINT, false)
		return
	end
	guard(b, w, plan, ref, holder)
end

---------------------------------------------------------------------------
-- the holder
---------------------------------------------------------------------------

local function markerNear(w: World, team: string, P: Vector3): Body?
	local markerId = Net.state():GetAttribute("MarkerId")
	if type(markerId) == "number" and markerId ~= 0 then
		local m = w.bodies[markerId]
		if m and m.team ~= team and flat(m.pos - P).Magnitude < 7 then
			return m
		end
	end
	local m, dist = nearest(P, w.team[RulesEngine.other(team)], nil)
	if m and dist < 6 then
		return m
	end
	return nil
end

local function chooseReceiver(b: Bot, w: World, P: Vector3, urgent: boolean): (Body?, number)
	local field = w.f
	local side: FieldGeometry.Side = w.e.attack[b.team] :: any
	local up = FieldGeometry.attackDirection(side)
	local opp = w.team[RulesEngine.other(b.team)]
	local best, bestScore = nil, -math.huge
	for _, body in w.team[b.team] do
		if body.id ~= b.id then
			local lead = body.pos + flat(body.vel) * 0.9
			if FieldGeometry.inBounds(field, lead) then
				local _, openD = nearest(lead, opp, nil)
				local lane = math.min(laneClearance(P, lead, opp, 4.5), 10)
				local progress = (lead - P):Dot(up)
				local dist = flat(lead - P).Magnitude
				local score = math.min(openD, 18) * 1.2
					+ lane * 1.6
					+ progress * 0.08
					- math.max(0, dist - 0.45 * field.length) * 0.15
				if dist < 8 then
					score -= 20
				end
				if FieldGeometry.inEndZone(field, lead, side) then
					score += 12
				end
				if urgent then
					score += 30 - dist * 0.2 -- anyone close will do
				end
				if score > bestScore then
					best, bestScore = body, score
				end
			end
		end
	end
	return best, bestScore
end

-- Plans the release against the marker: side away from the shade in the
-- throw frame, step out (0.6 + 0.4 x skill) R, Low against a High mark,
-- a hammer over a closed lane.
local function planRelease(b: Bot, w: World, h: HoldPlan, rec: Body, P: Vector3, urgent: boolean)
	local lead = rec.pos + flat(rec.vel) * 0.6
	local aim = VecMath.flatUnit(lead - P)
	if aim.Magnitude < 0.5 then
		aim = FieldGeometry.attackDirection(w.e.attack[b.team])
	end
	b.aim = aim
	local ra = rightOf(aim)
	local m = markerNear(w, b.team, P)
	local mLat = if m then flat(m.pos - P):Dot(ra) else 0
	local side = if m and math.abs(mLat) > 0.3 then (if mLat > 0 then -1 else 1) elseif b.rng:next() < 0.6 then -1 else 1
	local height = "Mid"
	if m then
		local mc = Actors.characterOf(m.id)
		local stance = mc and mc:GetAttribute("Mark")
		local tight = flat(m.pos - P).Magnitude < 4.5 and b.rng:next() < 0.4
		if stance == "High" or tight then
			height = "Low" -- under High hands, or a wide step-out past a tight mark
		end
	end
	local throwType = if side < 0 then "Backhand" else "Forehand"
	local opp = w.team[RulesEngine.other(b.team)]
	local dist = flat(lead - P).Magnitude
	if laneClearance(P, lead, opp, 4.5) < 3 and dist > 30 and b.rng:next() < 0.5 then
		throwType = "Hammer"
		height = "Mid"
	end
	h.receiver = rec.id
	h.throwType = throwType
	h.height = height
	h.side = side
	h.attempts += 1
	local t = now()
	local fake = m ~= nil
		and not urgent
		and not OVERHEAD[throwType]
		and b.rng:next() < 0.35 * b.skill
		and ready(b, "PivotSwing")
		and canSpend(b, HD.SwingCost)
	if fake then
		-- fake toward the mark, then Quick Swing away inside the Sold window
		-- (timed here, not by the 10 Hz think); releasing right after the
		-- swing is a Break
		local delay = b.rng:range(0.15, 0.24)
		services.ThrowService.fake(b.id, throwType, -side)
		press(b, "Fake", nil, 0, -side)
		press(b, "Swing", nil, delay, side)
		b.step = nil
		task.delay(delay, function()
			if brains[b.id] == b and b.hold == h then
				services.ThrowService.beginCharge(b.id, throwType)
			end
		end)
		h.phase = "Swing"
		h.at = t
		h.charged = t + delay
		h.swingEnd = t + delay + HD.SwingTime
	else
		local stepLen = if OVERHEAD[throwType] then 0.25 * R else (0.6 + 0.4 * b.skill) * R
		b.step = ra * (side * stepLen) + aim * (0.1 * R)
		services.ThrowService.beginCharge(b.id, throwType)
		h.charged = t
		h.phase = "Setup"
		h.at = t
	end
end

local function variant(params: any, changes: { [string]: any }): any
	local c = table.clone(params)
	for k, v in changes do
		c[k] = v
	end
	return c
end

-- Solves the pass from the real pivot + step, tests the release against the
-- mark and throws. When it would be blocked, the first of 2-3 candidate
-- releases (Low, the other side, a hammer) that gets through is planned for
-- the next think (re-solved then); when none does, the bot Quick Swings to
-- the other side and looks again. At most one solve runs per frame.
local function release(b: Bot, w: World, h: HoldPlan, urgent: boolean)
	if lastSolveFrame == frameNo then
		return -- another bot solved this frame; try again next think
	end
	local t = now()
	local rec = if h.receiver then w.bodies[h.receiver] else nil
	if not rec then
		h.phase = "Look"
		h.waitUntil = t + 0.2
		b.step = nil
		return
	end
	local P = services.MovementService.pivotOf(b.id) or b.root.Position
	lastSolveFrame = frameNo
	local sol = Solver.solve({
		rootPos = b.root.Position,
		pivot = P,
		step = b.sim.step,
		throwType = h.throwType,
		height = h.height,
		target = rec.pos + Vector3.new(0, 1, 0),
		targetVel = flat(rec.vel),
		groundY = w.f.groundY,
		wind = services.ArenaService.wind(),
		coarse = true,
	})
	if not sol or (sol.miss > 3.5 and not urgent) then
		h.phase = "Look"
		h.waitUntil = t + 0.3
		b.step = nil
		return
	end
	local params: any = sol.params
	local noise = (1 - b.skill) * 0.07
	params.yaw += b.rng:range(-noise, noise)
	params.pitch += b.rng:range(-noise, noise) * 0.6
	params.swinging = t < h.swingEnd

	local preview = services.ThrowService.previewBlock
	local skip = urgent or h.attempts > 4 or (b.skill < 0.7 and b.rng:next() < HAND_CHECK_SKIP)
	if preview and not skip and preview(b.id, params) then
		h.attempts += 1
		local other = if h.throwType == "Backhand" then "Forehand" else "Backhand"
		local candidates: { any } = {}
		if not OVERHEAD[h.throwType] and h.height ~= "Low" then
			table.insert(candidates, variant(params, { height = "Low" }))
		end
		table.insert(candidates, variant(params, { throwType = other }))
		if flat(rec.pos - P).Magnitude > 20 and h.throwType ~= "Hammer" then
			table.insert(candidates, variant(params, { throwType = "Hammer", height = "Mid" }))
		end
		for _, c in candidates do
			if not preview(b.id, c) then
				-- this one gets through: release it next think (re-solved)
				h.throwType = c.throwType
				h.height = c.height
				h.phase = "Setup"
				h.at = t - 1
				h.charged = t - 1
				return
			end
		end
		-- every release is blocked: pivot to the other side and look again
		if ready(b, "PivotSwing") and canSpend(b, HD.SwingCost) then
			h.side = -h.side
			h.throwType = if h.side < 0 then "Backhand" else "Forehand"
			press(b, "Swing", nil, 0, h.side)
			b.step = nil
			services.ThrowService.beginCharge(b.id, h.throwType)
			h.charged = t
			h.swingEnd = t + HD.SwingTime
			h.phase = "Swing"
		else
			h.phase = "Look"
			h.waitUntil = t + 0.3
		end
		return
	end
	local result = services.ThrowService.throw(b.id, params, true)
	if result then
		b.hold = nil
		b.step = nil
	else
		h.phase = "Look"
		h.waitUntil = t + 0.25
	end
end

local function thinkHolder(b: Bot, w: World)
	local t = w.t
	local sim = b.sim
	local e = w.e
	clearMark(b)
	b.target = nil
	b.targetVel = nil
	b.cut = nil
	local h = b.hold
	if not h then
		h = {
			phase = "Settle",
			at = t,
			since = t,
			waitUntil = t + math.max(0.25, b.rng:range(0.35, 1.1) * (1.3 - b.skill)),
			receiver = nil,
			throwType = "Backhand",
			height = "Mid",
			side = -1,
			charged = 0,
			swingEnd = 0,
			attempts = 0,
		}
		b.hold = h
	end
	local hp = h :: HoldPlan
	if not b.aim then
		b.aim = FieldGeometry.attackDirection(e.attack[b.team])
	end
	if w.phase ~= "Live" then
		-- the puller faces the receivers; MatchService releases the pull
		b.aim = FieldGeometry.attackDirection(e.attack[b.team])
		b.step = nil
		return
	end
	if sim.holdPhase ~= "Pivot" and t - hp.since < 2.5 then
		return -- still slowing down onto the pivot
	end
	local urgent = w.stall >= w.stallMax - 2
	local P = services.MovementService.pivotOf(b.id) or b.root.Position
	if hp.phase == "Settle" then
		if t < hp.waitUntil and w.stall < w.stallMax - 3 then
			b.step = nil
			return
		end
		hp.phase = "Look"
	end
	if hp.phase == "Look" then
		if t < hp.waitUntil and not urgent then
			return
		end
		local rec, score = chooseReceiver(b, w, P, urgent)
		if not rec or (score < 10 and not urgent) then
			hp.waitUntil = t + 0.35
			b.step = nil
			-- keep the mark honest: an occasional swing to look the other way
			if b.rng:next() < 0.2 and ready(b, "PivotSwing") and canSpend(b, HD.SwingCost + 20) then
				press(b, "Swing", nil, 0, if b.rng:next() < 0.5 then -1 else 1)
			end
			return
		end
		planRelease(b, w, hp, rec, P, urgent)
		return
	end
	if hp.phase == "Swing" then
		if t >= hp.swingEnd + 0.06 or urgent then
			release(b, w, hp, urgent)
		end
		return
	end
	if hp.phase == "Setup" then
		local want = b.step or Vector3.zero
		local inPlace = (flat(sim.step) - flat(want)).Magnitude < 0.6
		if urgent or (t - hp.charged >= 0.28 and (inPlace or t - hp.at > 0.5)) then
			release(b, w, hp, urgent)
		end
	end
end

---------------------------------------------------------------------------
-- match brain
---------------------------------------------------------------------------

local function thinkFlight(b: Bot, w: World)
	local e, d = w.e, w.d
	local fl = w.flight
	if not fl then
		return
	end
	local offense = if d.pull then b.team == e.offense else b.team == d.throwerTeam
	-- the pulling team never chases its own pull: it runs down onto its marks
	local mayChase = not d.pull or offense
	if mayChase and chaserOf(w, b.team) == b.id and chase(b, d, if d.pull then nil else w.f) then
		return
	end
	local ref = inField(w.f, fl.land, 2, w.f.groundY)
	if offense then
		if d.pull then
			thinkOffense(b, w, ref, nil)
		elseif b.cut then
			runCut(b)
		elseif d.thrower == b.id and b.target == nil then
			-- the thrower follows the throw up the field
			local pos = b.root.Position
			local f = FieldGeometry.attackDirection(e.attack[b.team])
			steerTo(b, inField(w.f, pos + f * 8, 4, pos.Y), JOG, false)
		end
		-- otherwise keep running where we were going
	else
		thinkDefense(b, w, ref, nil)
	end
end

local function thinkGround(b: Bot, w: World)
	local e, d = w.e, w.d
	local spot = d and d.folder:GetAttribute("GroundPos")
	if typeof(spot) ~= "Vector3" then
		stand(b)
		return
	end
	if b.team == e.offense then
		local n = nearest(spot, w.team[b.team], nil)
		if n and n.id == b.id then
			clearMark(b)
			b.cut = nil
			b.face = nil
			steerTo(b, Vector3.new(spot.X, b.root.Position.Y, spot.Z), SPRINT, true)
			return
		end
		thinkOffense(b, w, spot, nil)
	else
		thinkDefense(b, w, spot, nil)
	end
end

local function thinkMatch(b: Bot)
	local w = getWorld()
	if not w then
		stand(b)
		clearMark(b)
		return
	end
	local e = w.e
	if not b.sim.holding then
		b.hold = nil
	end
	if b.sim.frozen or not table.find(w.lines[b.team] or {}, b.id) then
		stand(b)
		clearMark(b)
		return
	end
	local phase = w.phase
	if phase == "PointOver" then
		stand(b)
		clearMark(b)
		if b.rng:next() < 0.03 then
			press(b, "Jump")
		end
		return
	end
	if phase == "PointSetup" or phase == "Pull" then
		clearMark(b)
		b.target = nil
		b.targetVel = nil
		b.cut = nil
		b.face = FieldGeometry.attackDirection(e.attack[b.team])
		if b.sim.holding then
			thinkHolder(b, w)
		end
		return
	end
	if phase ~= "Live" then
		stand(b)
		clearMark(b)
		return
	end
	local d = w.d
	if e.disc == "Held" and e.holder then
		local holder = e.holder :: number
		local hb = w.bodies[holder]
		local ref = services.MovementService.pivotOf(holder) or (if hb then hb.pos else b.root.Position)
		if holder == b.id then
			thinkHolder(b, w)
		elseif e.holderTeam == b.team then
			thinkOffense(b, w, ref, holder)
		else
			thinkDefense(b, w, ref, holder)
		end
	elseif e.disc == "Flight" and d and d.mode == "Flight" then
		thinkFlight(b, w)
	elseif e.disc == "Ground" then
		thinkGround(b, w)
	end
end

function BotService.schedulePull(id: number)
	local b = brains[id]
	if not b then
		return
	end
	task.delay(b.rng:range(1.0, 2.2), function()
		if brains[id] and services.MatchService.phase() == "Pull" then
			services.MatchService.pullNow(id)
		end
	end)
end

local function update(dt: number)
	frameNo += 1
	refreshFilter()
	local t = now()
	for id, b in brains do
		if b.model.Parent == nil then
			brains[id] = nil
			if b.loco then
				Locomotion.destroy(b.loco)
			end
			continue
		end
		local ok, err = pcall(function()
			if b.custom then
				b.custom(b, dt)
			elseif t >= b.nextThink then
				b.nextThink = t + THINK_EVERY
				thinkMatch(b)
			end
			motor(b, dt)
		end)
		if not ok then
			local clock = os.clock()
			if clock - (lastWarn[id] or -math.huge) > 5 then
				lastWarn[id] = clock
				warn("[BotService] " .. b.name .. ": " .. tostring(err))
			end
			pcall(function()
				b.humanoid:Move(Vector3.zero, false)
				b.humanoid.WalkSpeed = 0
			end)
		end
	end
	-- forget flights of discs that no longer fly
	for key, fl in flights do
		if fl.landT < t - 1 then
			flights[key] = nil
		end
	end
end

---------------------------------------------------------------------------
-- helpers for scripted (training) bots
---------------------------------------------------------------------------

-- Walk / run to `target` (nil = stand) at up to `speed` studs/s. With
-- `tech`, a sharp change of direction at speed is a Snap Cut / plant.
function BotService.setGoal(b: Bot, target: Vector3?, speed: number?, tech: boolean?)
	b.marking = false
	if target then
		steerTo(b, target, speed or JOG, tech)
	else
		b.target = nil
		b.targetVel = nil
		b.speed = speed or JOG
	end
end

-- Marks `holderId` (diag 3 §5 marker). `up` points from the thrower toward
-- the end zone they attack; `force` is "FH" or "BH".
function BotService.mark(b: Bot, holderId: number, up: Vector3, force: string)
	runMark(b, holderId, up, force)
end

-- Stops marking (stance down).
function BotService.unmark(b: Bot)
	clearMark(b)
end

-- Chases disc `d`'s current flight like a match bot. False when out of reach.
function BotService.chase(b: Bot, d: any): boolean
	return chase(b, d)
end

function BotService.press(b: Bot, action: string, dir: Vector3?, side: number?)
	press(b, action, dir, 0, side)
end

function BotService.setSkill(b: Bot, skill: number)
	b.skill = math.clamp(skill, 0, 1)
end

function BotService.stand(b: Bot)
	stand(b)
	clearMark(b)
end

function BotService.Init(s: any)
	services = s
	local f = workspace:FindFirstChild(Actors.BotFolderName)
	if not f then
		local nf = Instance.new("Folder")
		nf.Name = Actors.BotFolderName
		nf.Parent = workspace
		f = nf
	end
	folder = f :: Folder
end

function BotService.Start()
	RunService.Heartbeat:Connect(update)
	services.PlayerService.ActorRemoving:Connect(function(actor)
		for _, p in plans do
			p.guards[actor.id] = nil
			for def, att in p.guards do
				if att == actor.id then
					p.guards[def] = nil
				end
			end
			if p.marker == actor.id then
				p.marker = nil
			end
		end
	end)
end

return BotService
