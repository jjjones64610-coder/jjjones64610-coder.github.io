--!strict
-- DISC + THROW + CATCH TUNING
-- Scale: 1 metre ~= 3 studs (a 5.3-stud avatar is ~1.77 m). The flight model
-- uses real-world frisbee coefficients (Hummel 2003) converted to studs, then
-- lightly tuned so throws read clearly on a Roblox field. See docs/DESIGN.md.
--
-- Field fit (Config/Modes.Fields): a full-power Perfect backhand flies
-- ~160-170 studs aimed flat and ~185 at its best aim, so a Normal pull from
-- the goal line lands around the receivers' brick, a Mini pull can reach the
-- end zone, and light touches (~0.1-0.2 s holds) stay short. tests/disc_spec
-- encodes this; tests/flight_table prints the numbers.

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
		MovingSpinPenaltySpeed = 12, -- throwing on the run faster than this costs spin (no pivot yet)
		MovingSpinPenalty = 0.85,
		ThrowerVelocityCarry = 0.45, -- share of the run-up added to the disc (no pivot yet)
		SwingSpinPenalty = 0.9, -- releasing mid Quick Swing costs 10% spin (no power cap)
		MinSpeed = 28,
		MaxSpeed = 88, -- sized for the Normal field (see the header)
		PowerCurve = 0.85,
		BankRange = 35, -- degrees of player-controlled bank either side
		BankSteps = 7, -- discrete bank positions for keyboard/gamepad (-3..3)
		FakeCooldown = 0.45,
		FakeDuration = 0.22,
		MinPitch = -12,
		MaxPitch = 60,
		QuickReleaseWindow = 0.6, -- release within this long after a catch = Quick Release
		HandBlockCheckTime = 0.3, -- seconds of early flight checked against markers' hands
		NoCatchTime = 0.15, -- nobody can catch in the first moments (hand blocks cover that)

		-- Release from the pivot (ThrowModel.releasePosition with params.pivot):
		-- P + step + right * (Side * PivotSideScale, +-LowReach for Low)
		--   + forward * ReleaseForward + up * (height + hop).
		PivotSideScale = 0.5, -- squared up: BH -0.3, FH +0.7 from the pivot
		LowReach = 0.9, -- a Low release extends this much further to the throw's side
		ReleaseForward = 0.8,
		MaxHopLift = 3.2, -- cap on the hop height added to a pivot release (peak ~2.8)
		-- Server check of the client's step (ThrowModel.resolveStep): accepted if
		-- the server root is within Base + Ping * min(ping, MaxPing) of P + share * step.
		StepCheckBase = 1.5,
		StepCheckPing = 12,
		StepCheckMaxPing = 0.35,
	},

	-- Per-throw definition. Side/LowSide are release offsets from the root part
	-- when no pivot is planted (right-handed thrower; mirrored for left-handed);
	-- from a pivot the release uses Side * Throw.PivotSideScale plus the step.
	-- bank/alpha/pitch are degrees. spin is the sign of rotation about the
	-- disc's top-face normal.
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

	-- Release heights relative to the root part centre (from a pivot: relative
	-- to P, plus the hop height). High without a pivot is the hop itself.
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
		CleanFraction = 0.8, -- min depth (over QualityWindow) inside this fraction = clean catch
		QualityWindow = 0.1, -- a claim's quality is its minimum depth over this long after first contact
		QualitySamples = 12, -- ... sampled every 1/120 s: first contact + this many steps
		ReachLength = 3.6,
		ReachRadius = 1.15,
		ReachWindow = 0.28,
		ReachCooldown = 0.4,
		DiveLength = 5.2,
		DiveRadius = 1.4,
		SlideDrop = 1.4, -- slide lowers the secure zone this much
		ShoulderHeight = 1.5,
		ShoulderWidth = 1.0,
		BobbleSpeed = 95, -- fingertip catch of a disc faster than this bobbles (disc speed only)
		BlockDepth = 0.9, -- a defender's touch is a Block only this deep at the rim; else an interception
		ContestWindow = 0.04, -- claims this close in time are contested
		ResolveDelay = 0.04, -- server waits this long to collect competing claims
		MaxRewind = 0.3, -- max seconds a claim can be backdated (lag compensation)
		ClaimThrottle = 0.03, -- client: min seconds between claims for one disc (a Denied clears it)
		ClaimTrackTime = 0.08, -- client: keeps tracking after first contact up to this long before claiming
		ClaimRateLimit = 0.02, -- server: min seconds between claims per actor (replies Denied)
		-- Claim slack (CatchGeometry.slack): Base + ping * PingSlackPerSecond
		-- + body speed * SpeedSlack, capped at MaxSlack.
		BaseSlack = 1.0, -- positional tolerance for claims (studs)
		PingSlackPerSecond = 26, -- extra tolerance per second of ping (≈ sprint speed)
		SpeedSlack = 0.06, -- extra tolerance per stud/s of body speed
		MaxSlack = 5,
		-- Client-sent body position (CatchGeometry.claimRoot): accepted within
		-- Base + speed * SpeedTime + ping * speed of the server root (cap Max);
		-- otherwise the server root is led by its velocity * Lead.
		ClientRootBase = 2,
		ClientRootSpeedTime = 0.25,
		ClientRootMax = 8,
		ClientRootLead = 0.08,
		PickupRadius = 3.5,
		BobbleUp = 16,
		BobbleCarry = 0.25,
		BlockCarry = 0.18,
		BlockDown = -6,
	},

	-- Marker hand zones (for hand blocks on release). The box is centred on the
	-- marker and faces the marker's facing blended FacingBlend toward the
	-- thrower's pivot P, never more than MaxFacingOff degrees off P, so a
	-- marker aims the hands but cannot turn them away from the thrower.
	-- Distances (StallRange, DiscSpace) are measured from P, not the thrower's
	-- root, so a lunge cannot cause a disc-space call.
	Mark = {
		StallRange = 9, -- studs from P: ~10 ft
		DiscSpace = 2.4, -- a marker closer than this to P is a disc-space call
		MarkDistance = 3.2, -- where a marker stands upfield of P ...
		Shade = 1.6, -- ... shaded this far toward the break side
		MirrorMax = 2.4, -- bots mirror the thrower's step by at most this much
		FacingBlend = 0.5,
		MaxFacingOff = 35, -- degrees
		LowY = { 0.8, 4.6 }, -- above the ground: low/wide stance, knees to chest
		HighY = { 4.4, 8.2 }, -- hands up: shoulders to well above the head
		LowHalfWidth = 2.8,
		HighHalfWidth = 2.2,
		JumpBonus = 1, -- jumping lifts the box by the jump height plus up to this (arms stretch)
		DepthMin = -0.8, -- along the box forward (toward the thrower)
		DepthMax = 2.0,
		RelaxedRadius = 1.6, -- hands-down marker: small zone at the chest
		RewindBase = 0.05, -- hand blocks rewind markers by min(ping / 2 + RewindBase, RewindMax)
		RewindMax = 0.25,
	},
}

return Disc
