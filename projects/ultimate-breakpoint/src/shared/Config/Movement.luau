--!strict
-- MOVEMENT TUNING
-- Every number that shapes how a player moves lives here. Units are studs and
-- seconds. See docs/DESIGN.md ("Movement model") for the reasoning behind each
-- value and the intended counterplay of every technique.

local Movement = {
	-- Locomotion -----------------------------------------------------------
	JogSpeed = 17,
	SprintSpeed = 26,
	ExhaustedSprintSpeed = 21, -- sprint top speed while exertion is empty
	HardCap = 34, -- absolute horizontal speed limit, enforced client + server
	Gravity = 160, -- workspace gravity for characters (the disc uses its own, see Config/Disc)

	Accel = 58, -- speeding up along the current direction
	AccelFromRest = 95, -- isotropic acceleration below RestSpeed (fast starts)
	RestSpeed = 7,
	Brake = 80, -- input opposes motion
	Coast = 50, -- no input
	LateralAccel = 92, -- max sideways acceleration => sprint turn radius ~7.3 studs
	OverspeedDecay = 38, -- bleeds speed above the current top speed (after bursts)

	AirAccel = 20,
	AirMinControlSpeed = 10,
	AirGainAllowance = 3, -- air control can never add more than this over takeoff speed

	JumpVelocity = 44,
	JumpSpeedBonus = 5, -- extra jump velocity at full sprint (momentum-sensitive jump)
	CoyoteTime = 0.1,

	LandingRecovery = 0.12,
	LandingSteer = 0.35,
	LandingRetention = 0.88,

	-- Exertion -------------------------------------------------------------
	ExertionMax = 100,
	ExertionRegen = 20, -- per second, when not sprinting
	ExertionRegenDelay = 0.6,
	SprintDrain = 4.5, -- per second while sprinting above jog speed

	ChainWindow = 1.0, -- techniques within this gap count as one combo chain
	CommitAngle = 12, -- running line considered "the same line" within this many degrees

	Quality = {
		Perfect = "Perfect",
		Clean = "Clean",
		Sloppy = "Sloppy",
		Gassed = "Gassed",
	},

	-- Techniques -----------------------------------------------------------
	SnapCut = {
		Cost = 10,
		MinInterval = 0.2,
		MinSpeed = 9,
		MinAngle = 25,
		MaxAngle = 115,
		CommitClean = 0.32, -- seconds on one line before a cut is "clean"
		CommitPerfect = 0.6,
		PerfectSpeedFraction = 0.85, -- must also be near full speed for Perfect
		SpamWindow = 0.4, -- a cut this soon after another cut is always Sloppy
		AnglePenalty = 0.15, -- extra retention lost as the cut approaches MaxAngle
		PerfectBoost = 2,
		Retention = { Perfect = 0.96, Clean = 0.86, Sloppy = 0.62, Gassed = 0.55 },
		SoldMinSpeedFraction = 0.8, -- a cut out of a Fake Commit leaves at >= this x sprint
	},

	MomentumCancel = {
		Cost = 10,
		Cooldown = 0.45,
		MinSpeed = 12,
		MinAngle = 115,
		PlantTime = 0.12,
		BrakeDecel = 330,
		WindowOpen = 0.10, -- restart inputs before this are "too early" (lockout)
		PerfectUntil = 0.21,
		WindowClose = 0.32,
		EarlyLockout = 0.15,
		RestartRetention = { Perfect = 0.92, Clean = 0.76 }, -- x SprintSpeed
	},

	FakeCommit = {
		Cost = 6,
		Cooldown = 0.7,
		MaxAngle = 25, -- Cut pressed within this angle of travel (or standing) = jab
		JabTime = 0.14,
		JabSlow = 0.8,
		JabSpeed = 9,
		SoldWindow = 0.45,
		SoldMinAngle = 30,
	},

	BurstStep = {
		Cost = 22,
		Cooldown = 1.6,
		Duration = 0.2,
		SpeedMult = 1.2,
		MinSpeed = 29,
		MaxSpeed = 32.5,
		GassedMult = 1.05,
		CutChainWindow = 0.15,
	},

	Slide = {
		Cost = 8,
		Cooldown = 0.7,
		MinSpeed = 14,
		Boost = 3,
		BoostCeiling = 29, -- slide boost can never push speed past this
		Friction = 13,
		SteerRate = 50, -- degrees per second
		MaxTime = 0.9,
		ExitSpeed = 9,
	},

	SlideCut = {
		Cost = 8,
		MinSlideTime = 0.15,
		PerfectFrom = 0.3,
		PerfectTo = 0.6,
		MaxAngle = 120,
		Retention = { Perfect = 0.94, Clean = 0.84, Gassed = 0.6 },
	},

	Dive = {
		Cost = 18,
		Cooldown = 1.1,
		GroundBonus = 4,
		GroundMin = 24,
		GroundMax = 32,
		GassedMin = 18,
		GassedMax = 24,
		GroundVertical = 20,
		AirBoost = 9,
		AirMax = 31,
		AirVertical = 4,
		MaxVertical = 24,
		ChainWindow = 0.25,
	},

	DiveSlide = {
		Friction = 42,
		StopSpeed = 5,
		MaxTime = 0.8,
	},

	Recover = {
		Time = 0.5,
		Decel = 60,
		PopWindow = 0.2,
		PopPerfect = 0.09,
		EarlyLockout = 0.25,
		Retention = { Perfect = 0.75, Clean = 0.55 }, -- x SprintSpeed
		PopJumpFraction = 0.8,
	},

	RollOut = {
		RecoverTime = 0.16,
		Retention = { Perfect = 0.72, Clean = 0.58 },
	},

	AirRedirect = {
		Cost = 12,
		MaxAngle = 80,
		ApexWindow = 9, -- |vertical velocity| below this = Perfect
		MinVertical = -6, -- redirect briefly arrests a fall to at most this
		MinSpeed = 4,
		StillSpeed = 8, -- redirecting a near-vertical jump gives this much drift
		Retention = { Perfect = 0.92, Clean = 0.82, Gassed = 0.6 },
	},

	PrecisionLanding = {
		EarlyWindow = 0.15,
		PerfectWindow = 0.05,
		LateWindow = 0.06,
		Lockout = 0.3,
		Retention = { Perfect = 1.0, Clean = 0.96 },
	},

	WallRebound = {
		Cost = 10,
		MaxPerAir = 2,
		Retention = 0.9,
		PushOff = 6,
		Vertical = 36,
		PerfectDistance = 1.2,
		DetectDistance = 3,
	},

	Holding = {
		DecelRate = 52,
		DecelMaxTime = 0.65,
		PivotRadius = 3.2,
		PivotSpeed = 10,
		PivotAccel = 120,
		HopVertical = 20,
		StopSpeed = 1.5,
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
		Jump = 0,
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
	},
}

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
	PrecisionLanding = 0,
	RecoveryChain = 0,
	AerialReach = 0,
	Jump = 0,
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
	PrecisionLanding = 0,
	RecoveryChain = 0,
	AerialReach = 0,
	Jump = 0,
}

return Movement
