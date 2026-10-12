--!strict
-- DISC + THROW + CATCH TUNING
-- Scale: 1 metre ~= 3 studs (a 5.3-stud avatar is ~1.77 m). The flight model
-- uses real-world frisbee coefficients (Hummel 2003) converted to studs, then
-- lightly tuned so throws read clearly on a Roblox field. See docs/DESIGN.md.

local Disc = {
	Physics = {
		Dt = 1 / 120, -- fixed simulation step, identical on client and server
		Gravity = 29.4, -- studs/s^2 (9.81 m/s^2 * 3)
		AirK = 0.0665, -- 0.5 * rho * area / mass, per stud
		CL0 = 0.15,
		CLa = 1.4, -- per radian
		StallAlpha = 0.45, -- radians; lift collapses beyond this
		CD0 = 0.08,
		CDa = 2.72,
		CDMax = 1.2,
		Alpha0 = -0.0698, -- -4 degrees
		CM0 = -0.01, -- pitching moment at zero angle of attack (nose down => "turn")
		CMa = 1.0, -- grows with angle of attack (nose up => "fade")
		RollK = 0.07, -- gyroscopic precession gain (tuned, see tests/disc_spec)
		SpinDecay = 0.04, -- per second
		MinSpin = 8,
		Radius = 1.1, -- visual/catch radius in studs (~0.27 m disc)
		GroundContact = 0.14, -- disc centre height that counts as touching the ground
		MaxFlightTime = 9,
		HistorySeconds = 0.6, -- server keeps this much flight history for lag compensation
	},

	Throw = {
		SpinBase = 50, -- rad/s (~8 rev/s)
		ChargeTime = 0.55, -- seconds of holding to reach full power
		PerfectWindow = 0.10, -- release within [ChargeTime, ChargeTime + PerfectWindow] = Perfect
		OverchargeDecay = 0.8, -- spin factor lost per second held beyond the window
		MinOverSpin = 0.6,
		PerfectSpeedMult = 1.05,
		PerfectSpinMult = 1.15,
		OffBalancePowerCap = 0.75,
		OffBalanceSpin = 0.8,
		GroundThrowPowerCap = 0.6,
		MovingSpinPenaltySpeed = 12, -- throwing while still moving faster than this costs spin
		MovingSpinPenalty = 0.85,
		ThrowerVelocityCarry = 0.45,
		MinSpeed = 28,
		MaxSpeed = 78,
		PowerCurve = 0.85,
		BankRange = 35, -- degrees of player-controlled bank either side
		BankSteps = 7, -- discrete bank positions for keyboard/gamepad (-3..3)
		FakeCooldown = 0.3,
		FakeDuration = 0.22,
		MinPitch = -12,
		MaxPitch = 60,
		QuickReleaseWindow = 0.6, -- release within this long after a catch = Quick Release
		HandBlockCheckTime = 0.3, -- seconds of early flight checked against markers' hands
		NoCatchTime = 0.15, -- nobody can catch in the first moments (hand blocks cover that)
	},

	-- Per-throw definition. side/height are release offsets from the root part
	-- (right-handed thrower; mirrored for left-handed). bank/alpha/pitch are
	-- degrees. spin is the sign of rotation about the disc's top-face normal.
	Types = {
		Backhand = {
			Display = "Backhand",
			Short = "BH",
			Order = 1,
			SpeedMult = 1.0,
			Spin = -1,
			Bank = 0,
			Alpha = 6,
			PitchOffset = 4,
			Side = -0.6,
			LowSide = -2.2,
			ChargeMult = 1.0,
			Description = "Reliable baseline. Fades left (right-handed).",
		},
		Forehand = {
			Display = "Forehand",
			Short = "FH",
			Order = 2,
			SpeedMult = 0.95,
			Spin = 1,
			Bank = 0,
			Alpha = 6,
			PitchOffset = 3,
			Side = 1.4,
			LowSide = 2.4,
			ChargeMult = 1.2, -- quicker release
			Description = "Fast flick release from the other side. Fades right.",
		},
		Hammer = {
			Display = "Hammer",
			Short = "HAM",
			Order = 3,
			SpeedMult = 0.85,
			Spin = 1,
			Bank = -100,
			Alpha = 6,
			PitchOffset = 30,
			Side = 0.8,
			LowSide = 0.8,
			Overhead = true,
			ChargeMult = 1.0,
			Description = "Overhead. Inverts mid-flight and drops steeply over defenders.",
		},
		Scoober = {
			Display = "Scoober",
			Short = "SCB",
			Order = 4,
			SpeedMult = 0.6,
			Spin = -1,
			Bank = 100,
			Alpha = 6,
			PitchOffset = 22,
			Side = -0.4,
			LowSide = -0.4,
			Overhead = true,
			ChargeMult = 1.3,
			Description = "Short upside-down flip over a close mark. Breaks right.",
		},
		Blade = {
			Display = "Blade",
			Short = "BLD",
			Order = 5,
			SpeedMult = 0.95,
			Spin = -1,
			Bank = -55,
			Alpha = -4,
			PitchOffset = 6,
			Side = -0.6,
			LowSide = -2.2,
			ChargeMult = 1.0,
			Description = "Steep edge, fast dive. Short hang time: hard to intercept.",
		},
	},

	TypeOrder = { "Backhand", "Forehand", "Hammer", "Scoober", "Blade" },

	-- Release heights relative to the root part centre.
	Heights = {
		High = 2.6,
		Mid = 0.5,
		Low = -1.6,
	},
	OverheadHeight = 2.6,

	-- Catch geometry (studs, relative to the root part centre).
	Catch = {
		ChestHeight = 1.0,
		SecureRadius = 2.4, -- passive catch zone around the chest
		CleanFraction = 0.6, -- inside this fraction of a zone radius = clean catch
		ReachLength = 3.6,
		ReachRadius = 1.15,
		ReachWindow = 0.28,
		ReachCooldown = 0.4,
		DiveLength = 5.2,
		DiveRadius = 1.4,
		SlideDrop = 1.4, -- slide lowers the secure zone this much
		ShoulderHeight = 1.5,
		ShoulderWidth = 1.0,
		BobbleSpeed = 70, -- fingertip catch of a disc faster than this bobbles
		ContestWindow = 0.06, -- claims this close in time are contested
		ResolveDelay = 0.1, -- server waits this long to collect competing claims
		MaxRewind = 0.3, -- max seconds a claim can be backdated (lag compensation)
		BaseSlack = 1.0, -- positional tolerance for claims (studs)
		PingSlackPerSecond = 26, -- extra tolerance per second of ping (≈ sprint speed)
		MaxSlack = 3.5,
		PickupRadius = 3.5,
		BobbleUp = 16,
		BobbleCarry = 0.25,
		BlockCarry = 0.18,
		BlockDown = -6,
	},

	-- Marker hand zones (for hand blocks on release).
	Mark = {
		StallRange = 9, -- studs: ~10 ft
		DiscSpace = 2.6, -- defenders closer than this to the thrower trigger a disc-space call
		LowY = { 0.6, 4.4 }, -- above the ground: low/wide stance, knees to chest
		HighY = { 4.6, 8.6 }, -- hands up: shoulders to well above the head
		LowHalfWidth = 3.2,
		HighHalfWidth = 2.6,
		JumpBonus = 5,
		DepthMin = -1.0,
		DepthMax = 2.2,
		RelaxedRadius = 1.8, -- hands-down marker: small zone at the chest
	},
}

return Disc
