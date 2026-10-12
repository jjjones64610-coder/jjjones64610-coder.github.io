--!strict
-- MOVEMENT TUNING
-- Every number that shapes how a player moves lives here. Units are studs and
-- seconds. See docs/DESIGN.md ("Movement model") for the reasoning behind each
-- value and the intended counterplay of every technique.
--
-- The Humanoid moves the body; MovementSim decides the velocity. These numbers
-- are therefore the real feel of the game: the client feeds the sim's output
-- straight into Humanoid:Move / WalkSpeed (and writes AssemblyLinearVelocity on
-- technique impulses), so nothing downstream softens them.
--
-- Philosophy: every press does something visible; timing only changes the
-- bonus. Technique speed thresholds are scaled x1.08 from the original tuning
-- to keep their relation to the faster sprint (26 -> 28).

local Movement = {
	-- Locomotion -----------------------------------------------------------
	JogSpeed = 18,
	SprintSpeed = 28,
	ExhaustedSprintSpeed = 23, -- sprint top speed while exertion is (nearly) empty
	HardCap = 36, -- absolute horizontal speed limit, enforced client + server
	Gravity = 160, -- workspace gravity for characters (the disc uses its own, see Config/Disc)

	Accel = 70, -- speeding up along the current direction (95% of sprint in ~0.32 s)
	AccelFromRest = 140, -- isotropic acceleration below RestSpeed (fast starts)
	RestSpeed = 9,
	Brake = 130, -- input opposes motion
	Coast = 100, -- no input (stop from sprint in ~0.28 s)
	-- Sideways (turning) acceleration depends on speed: nimble at jog, committed
	-- at sprint. Turn radius ~1.2 studs at jog, ~6 studs at full sprint.
	LateralAccelLow = 260, -- at or below JogSpeed
	LateralAccel = 130, -- at SprintSpeed and above
	OverspeedDecay = 45, -- bleeds speed above the current top speed (after bursts)

	AirAccel = 30,
	AirMinControlSpeed = 12,
	AirGainAllowance = 4, -- air control can never add more than this over takeoff speed

	JumpVelocity = 46,
	JumpSpeedBonus = 4, -- extra jump velocity at full sprint (momentum-sensitive jump)
	CoyoteTime = 0.12,

	LandingRecovery = 0.08,
	LandingSteer = 0.7,
	LandingRetention = 0.96,

	-- Collision reconciliation: the sim adopts the body's real velocity only when
	-- something solid is really in the way (the client's ray says env.blocked)
	-- and the body has lagged behind the sim for a moment.
	ReconcileFraction = 0.6, -- real speed along the sim direction below this x sim speed ...
	ReconcileTime = 0.08, -- ... for longer than this

	-- A frame whose output velocity jumps by more than this (studs/s) is an
	-- impulse: the client writes AssemblyLinearVelocity directly on it.
	ImpulseThreshold = 4,

	-- Presses that are a little early / in a short cooldown / about to become
	-- valid are kept this long inside the sim and retried every step.
	InputBuffer = 0.15,

	-- Exertion -------------------------------------------------------------
	ExertionMax = 100,
	ExertionRegen = 25, -- per second when not sprinting
	SprintRegen = 8, -- per second while sprinting (still offsets SprintDrain)
	SprintDrain = 2.0, -- per second while sprinting above jog speed
	ExertionRegenDelay = 0.5, -- pause before regen, only after a technique spend
	ExhaustedBelow = 15, -- sprint top speed fades toward ExhaustedSprintSpeed below this
	GassedFraction = 0.5, -- a technique is Gassed only when exertion < cost x this

	ChainWindow = 1.5, -- techniques within this gap count as one combo chain

	-- Running line ("commitment") that grades Snap Cuts and Plants.
	CommitAngle = 30, -- velocity within this many degrees stays on "the same line"
	CommitMinSpeed = 10.8, -- below this you are not committed to any line
	LineMemory = 0.2, -- after the line breaks, cuts are still judged against the old line this long
	LineSpeedDecay = 40, -- the remembered line speed fades this fast (studs/s per s)

	Quality = {
		Perfect = "Perfect",
		Clean = "Clean",
		Sloppy = "Sloppy",
		Gassed = "Gassed",
	},

	-- Techniques -----------------------------------------------------------
	SnapCut = {
		Cost = 10,
		MinInterval = 0.15, -- cuts closer than this are buffered, not dropped
		MinSpeed = 5.4, -- below this, Q with a direction is a quick side step
		MaxAngle = 120, -- beyond this (from the running line) Q plants instead
		CommitClean = 0.2, -- seconds on one line before a cut is "clean"
		CommitPerfect = 0.45,
		PerfectSpeedFraction = 0.75, -- must also be near full speed for Perfect
		SpamWindow = 0.3, -- a cut this soon after another cut is always Sloppy
		AnglePenalty = 0.08, -- extra retention lost as the cut approaches MaxAngle
		PerfectBoost = 2,
		Retention = { Perfect = 0.98, Clean = 0.92, Sloppy = 0.80, Gassed = 0.72 },
		ExitFloor = 0.7, -- non-Gassed cuts leave at >= this x SprintSpeed (JogSpeed if slower): beats plain steering
		SoldMinSpeedFraction = 0.8, -- a cut out of a Fake Commit leaves at >= this x sprint
	},

	MomentumCancel = {
		Cost = 10,
		Cooldown = 0.45,
		MinSpeed = 10.8,
		PlantTime = 0.12,
		BrakeDecel = 330,
		WindowOpen = 0.06, -- restart presses before this are buffered until it opens
		PerfectUntil = 0.22,
		WindowClose = 0.40,
		RestartRetention = { Perfect = 0.95, Clean = 0.85 }, -- x SprintSpeed (pressed restart)
		AutoRestart = 0.8, -- x SprintSpeed when a direction is simply held as the plant ends
	},

	FakeCommit = {
		Cost = 6,
		Cooldown = 0.5,
		MaxAngle = 25, -- Cut pressed within this angle of the line = look-ahead, then jab
		LookAhead = 0.1, -- a steer >= MaxAngle this soon after the press becomes a Snap Cut
		JabTime = 0.08,
		JabSlow = 0.92,
		JabSteer = 0.5, -- lateral steering kept during the jab
		SideStepSpeed = 14, -- Q below SnapCut.MinSpeed: quick side step
		SideStepTime = 0.15,
		SoldWindow = 0.6,
		SoldMinAngle = 30,
	},

	BurstStep = {
		Cost = 22,
		Cooldown = 1.2,
		Duration = 0.2,
		SpeedMult = 1.2,
		MinSpeed = 31,
		MaxSpeed = 35,
		GassedMult = 1.12,
		CutChainWindow = 0.25, -- Perfect within this of a Snap Cut / Slide Cut / pop / plant
	},

	Slide = {
		Cost = 8,
		Cooldown = 0.5,
		MinSpeed = 10.8,
		Boost = 3,
		BoostCeiling = 31, -- slide boost can never push speed past this
		Friction = 13,
		SteerRate = 50, -- degrees per second
		MaxTime = 0.9,
		ExitSpeed = 9.7,
	},

	SlideCut = {
		Cost = 8,
		MinSlideTime = 0.05, -- earlier presses are buffered
		PerfectFrom = 0.2,
		PerfectTo = 0.6,
		MaxAngle = 160,
		Retention = { Perfect = 0.94, Clean = 0.84, Gassed = 0.7 },
	},

	Dive = {
		Cost = 18,
		Cooldown = 0.9,
		GroundBonus = 4,
		GroundMin = 26,
		GroundMax = 34,
		GassedMin = 23,
		GassedMax = 28,
		GroundVertical = 22,
		AirBoost = 9,
		AirMax = 33,
		AirVertical = 4,
		MaxVertical = 24,
		ChainWindow = 0.4, -- Perfect layout within this of a Snap Cut, Burst, Slide, ...
	},

	DiveSlide = {
		Friction = 60,
		StopSpeed = 5.4,
		MaxTime = 0.5,
	},

	Recover = {
		Time = 0.3,
		Steer = 0.35, -- lateral steering while getting up
		PopFrom = 0.15, -- the pop-up is accepted from this long after the dive touches down ...
		PopPerfect = 0.10, -- ... and is Perfect within this of the slide stopping
		Retention = { Perfect = 0.75, Clean = 0.55 }, -- x SprintSpeed (never below current speed)
		PopJumpFraction = 0.8,
	},

	RollOut = {
		RecoverTime = 0.16,
		Retention = { Perfect = 0.72, Clean = 0.58 },
	},

	AirRedirect = {
		Cost = 8,
		MaxAngle = 80,
		MinAngle = 20, -- input closer than this to travel: no-op, not consumed
		ApexWindow = 15, -- |vertical velocity| below this = Perfect
		MinVertical = -6, -- redirect briefly arrests a fall to at most this
		MinSpeed = 4,
		StillSpeed = 8.6, -- redirecting a near-vertical jump gives this much drift
		Retention = { Perfect = 0.97, Clean = 0.9, Gassed = 0.7 },
	},

	PrecisionLanding = {
		ArmWindow = 0.35, -- Slide in the air arms it once time-to-land is at most this
		PerfectWindow = 0.08, -- armed this close to touchdown = Perfect
		CleanWindow = 0.22, -- = Clean; armed earlier = soft landing (no label)
		LateWindow = 0.12, -- pressed this soon after touchdown = Clean (late)
		Retention = { Perfect = 1.0, Clean = 0.98, Soft = 0.96 },
	},

	WallRebound = {
		Cost = 10,
		MaxPerAir = 2,
		Retention = 0.9,
		PushOff = 6,
		Vertical = 36,
		PerfectDistance = 1.2,
		DetectDistance = 3.5, -- client ray length (along velocity, look, and both sides)
	},

	-- Holding the disc: the pivot. A planted pivot foot P and a free-foot step
	-- vector s in the throw frame (forward = aim yaw). The root follows
	-- P + BodyShare * s.
	Holding = {
		DecelRate = 70, -- slow-down after the (predicted) catch
		DecelMaxTime = 0.45,
		PlantSpeed = 4, -- the pivot foot plants as soon as speed drops below this
		StepRadius = 3.6, -- R: the free foot reaches this far from P
		ForwardMax = 0.75, -- forward part of the step <= this x R (lunge)
		BackMax = 0.9, -- backward part <= this x R (drop step)
		StepSpring = 22, -- critically damped spring on the step length (1/s)
		StepAngular = 720, -- deg/s the step turns around the pivot (through the front)
		BodyShare = 0.55, -- the root sits at P + BodyShare * s
		DriveGain = 14, -- root velocity = gain x distance to its target ...
		DriveMax = 18, -- ... capped here (Humanoid WalkSpeed while pivoting)
		SwingLateral = 0.95, -- Quick Swing target = (side x 0.95R, +0.25R)
		SwingForward = 0.25,
		SwingAngular = 1100,
		SwingSpring = 30,
		SwingTime = 0.18,
		SwingCooldown = 0.4,
		SwingCost = 4,
		SwingSoldWindow = 0.35, -- a swing this soon after a fake is Perfect ("Sold")
		FakeStep = 0.6, -- the fake lunges the step 0.6R toward the held side ...
		FakeStepOut = 0.12, -- ... in this long ...
		FakeStepBack = 0.15, -- ... and springs back in about this long
		HopVertical = 30, -- one hop per possession (2.8-stud peak, ~0.375 s airtime)
		PivotRadius = 0, -- derived below: the furthest the root may be from P
	},

	-- Marking: hold RMB within Range of the holder to mark-shuffle.
	Marking = {
		ShuffleSpeed = 15,
		Accel = 140,
		Brake = 160,
		Range = 8,
	},

	-- Combo base points per technique (see ComboEvaluator).
	ComboPoints = {
		SnapCut = 100,
		MomentumCancel = 120,
		AirRedirect = 140,
		SlideCut = 120,
		WallRebound = 150,
		PrecisionLanding = 130,
		BurstStep = 90,
		FakeCommit = 110,
		Dive = 160,
		RecoveryChain = 150,
		AerialReach = 120,
		Slide = 60,
		Jump = 20,
		PivotSwing = 120,
		Break = 250,
	},

	-- Display names for UI / feedback.
	TechNames = {
		SnapCut = "Snap Cut",
		MomentumCancel = "Momentum Cancel",
		AirRedirect = "Air Redirect",
		SlideCut = "Slide Cut",
		WallRebound = "Wall Rebound",
		PrecisionLanding = "Precision Landing",
		BurstStep = "Burst Step",
		FakeCommit = "Fake Commit",
		Dive = "Layout",
		RecoveryChain = "Recovery Chain",
		AerialReach = "Aerial Reach",
		Slide = "Slide",
		Jump = "Jump",
		PivotSwing = "Pivot Swing",
		Break = "Break",
	},
}

-- The root never strays further than this from the pivot foot (server travel
-- checks add their latency slack on top).
Movement.Holding.PivotRadius = Movement.Holding.StepRadius * Movement.Holding.BodyShare

-- Techniques the server validates (cost + cooldown mirror). Cooldown 0 means
-- rate-limited only.
Movement.TechCosts = {
	SnapCut = Movement.SnapCut.Cost,
	MomentumCancel = Movement.MomentumCancel.Cost,
	FakeCommit = Movement.FakeCommit.Cost,
	BurstStep = Movement.BurstStep.Cost,
	Slide = Movement.Slide.Cost,
	SlideCut = Movement.SlideCut.Cost,
	Dive = Movement.Dive.Cost,
	AirRedirect = Movement.AirRedirect.Cost,
	WallRebound = Movement.WallRebound.Cost,
	PivotSwing = Movement.Holding.SwingCost,
	PrecisionLanding = 0,
	RecoveryChain = 0,
	AerialReach = 0,
	Jump = 0,
	Break = 0,
}

Movement.TechCooldowns = {
	SnapCut = Movement.SnapCut.MinInterval,
	MomentumCancel = Movement.MomentumCancel.Cooldown,
	FakeCommit = Movement.FakeCommit.Cooldown,
	BurstStep = Movement.BurstStep.Cooldown,
	Slide = Movement.Slide.Cooldown,
	SlideCut = 0,
	Dive = Movement.Dive.Cooldown,
	AirRedirect = 0,
	WallRebound = 0,
	PivotSwing = Movement.Holding.SwingCooldown,
	PrecisionLanding = 0,
	RecoveryChain = 0,
	AerialReach = 0,
	Jump = 0,
	Break = 0,
}

return Movement
