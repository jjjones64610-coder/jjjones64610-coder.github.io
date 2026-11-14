--!strict
--[[
	Tuning — THE ONE PLACE TO TWEAK FEEL (docs/CORE_DESIGN.md).

	Every number that decides how the game feels lives here: speeds,
	acceleration, turn rates, cuts, skids, jumps, gravity, timing windows.
	Logic never hard-codes these. Change a value, press Play, feel it.
	`lune run tests/run.luau tech` re-checks the movement rules offline.

	Units: studs, seconds, studs/s, studs/s². Timing windows are in ms
	unless the name or comment says s. Sections marked (stage N) belong to a
	build stage that hasn't been reworked to the core design yet.

	Movement numbers are the flat Tech.NAME values; the disc, throwing and
	catching numbers are in Tech.Disc at the bottom. Config/Tech and
	Config/Disc are aliases of this module (older code requires them by
	those names).
]]

local Tech = {}

-- engine
Tech.PHYSICS_RATE = 120 -- Hz, fixed timestep
Tech.MAX_FRAME = 0.25 -- s of frame time the accumulator will catch up on at most
Tech.INPUT_BUFFER = 100 -- ms a press stays buffered

-- bots run on this engine too (off the disc; BotService)
Tech.BOTS_USE_TECH = true

-- running
Tech.RUN_TOP_SPEED = 30 -- FEEL: full jogging speed (no Shift)
Tech.RUN_ACCEL = 105 -- FEEL: how fast you reach it (studs/s²); lower = heavier
Tech.GROUND_FRICTION = 85 -- FEEL: stopping when you let go (after the plant window)
Tech.OVERSPEED_DECAY_GROUND = 15
Tech.OVERSPEED_DECAY_AIR = 4
Tech.HARD_SPEED_CAP = 60 -- total speed, nothing exceeds it

-- TURNING (the heart of the feel): instant below TURN_FREE_SPEED, then at
-- most this many °/s at each speed (linear between points, flat past the
-- last one). Faster = wider turns.
Tech.TURN_FREE_SPEED = 12
Tech.TURN_RATE = {
	{ speed = 12, rate = 380 },
	{ speed = 30, rate = 250 },
	{ speed = 50, rate = 140 },
}
-- FEEL: steering harder than the turn rate drifts: every 90° turned while
-- the stick asks for more than you can turn costs this share of your speed.
Tech.TURN_DRIFT_LOSS = 0.12
Tech.DRIFT_ACCEL_SHARE = 0 -- accel while a turn is rate-limited (0: a fast turn always costs)

-- gravity (the player's own; the disc has DISC_GRAVITY)
Tech.PLAYER_GRAVITY = 175
Tech.FALL_GRAVITY_MULT = 1.3

-- ground contact (controller, not in the spec table)
Tech.GROUND_SNAP = 0.6 -- studs below the feet that still count as standing (step-downs)
Tech.GROUND_SNAP_AIR = 0.15 -- ... while airborne, so a fall lands on touchdown
Tech.GROUND_SPRING = 30 -- 1/s, how fast the body settles to its stand height
Tech.GROUND_SPRING_MAX = 40 -- studs/s, the fastest step-up / step-down

-- burst (hold Shift: the sprint; it drains a meter and refills when released)
Tech.BURST_TOP_SPEED = 40 -- FEEL: sprint top speed
Tech.BURST_ACCEL = 135
Tech.BURST_DRAIN = 30
Tech.BURST_REFILL = 20
Tech.BURST_LOCK_UNTIL = 20
Tech.PERFECT_BURST_REFUND = 10
Tech.BURST_KICK = 6
Tech.BURST_KICK_COST = 15
Tech.BURST_KICK_TAP = 120 -- ms
Tech.BURST_KICK_COOLDOWN = 0.5

-- CUTS (from the stick, no button): let go of WASD while running, then snap
-- a new direction. The length of the let-go is the timing.
Tech.CUT_MIN_SPEED = 12 -- below this there is nothing to cut (turns are free)
Tech.CUT_ANGLE = 45 -- ° the new direction must be off your line to count as a cut
Tech.CUT_RELEASE_MAX = 0.22 -- s: the longest let-go that is still a plant (longer = you stop)
Tech.CUT_RELEASE_PERFECT = { 0.04, 0.12 } -- s: a let-go this long is a Perfect cut
Tech.PLANT_HOLD_FRICTION = 20 -- studs/s² lost while planted (vs GROUND_FRICTION when stopping)
Tech.PERFECT_KEEP = 1.00 -- FEEL: share of speed a Perfect cut keeps ...
Tech.PERFECT_CUT_BONUS = 3 -- ... plus this, out of the cut
Tech.CUT_KEEP = 0.80 -- FEEL: share a Clean (mistimed) cut keeps
Tech.CUT_SHARP_FROM = 90 -- ° past which a cut keeps less ...
Tech.CUT_REVERSE_KEEP = 0.65 -- ... down to this share of the keep at a full 180° reversal
Tech.CUT_COOLDOWN = 0.35 -- s before the next plant can start
Tech.CUT_REPEAT_TIME = 0.6 -- s: a cut this soon after the last ...
Tech.CUT_REPEAT_CAP = 0.85 -- ... keeps at most this (no free zigzags)
Tech.JUKE_WINDOW = 120 -- ms after a cut: the stick back to the old line is a Juke ...
Tech.JUKE_KEEP = 0.90 -- ... which puts you back on it at this share of the speed
Tech.JUKE_RETURN_ANGLE = 30 -- ° from the old line that counts as "back"

-- SKID (the sloppy cut): yank the stick hard round at speed with no plant
Tech.SKID_MIN_SPEED = 20 -- only this fast or faster
Tech.SKID_ANGLE = 110 -- ° between your line and the stick
Tech.SKID_FRICTION = 45 -- FEEL: speed lost per second while skidding
Tech.SKID_TURN = 120 -- °/s you can steer the skid
Tech.SKID_MAX_TIME = 0.5 -- s at most, then you run again
Tech.SKID_EXIT_SPEED = 8 -- ... or as soon as you are this slow
Tech.SKID_COOLDOWN = 1.0 -- s before another skid can start (one mistake, one skid)

-- slides (stage 2: from dive landings; Shift in a slide carves, Space hops)
Tech.SLIDE_TURN = 60 -- °/s
Tech.CARVE_TURN = 220
Tech.CARVE_FRICTION = 40
Tech.LANDING_SLIDE_MIN_SPEED = 12
Tech.SLIDE_HOP_HEIGHT = 0.6 -- of a tap jump's height
Tech.SLIDE_HOP_OFF_WINDOW = 2 -- studs/s outside the window
Tech.HOP_CHAIN_RESET = 1.0 -- s on the ground (not sliding)
Tech.CATCH_RUNOUT_FRICTION = 50 -- FEEL: the skid to a stop after a catch (stage 3/4)
Tech.SLIDE_MIN_SPEED = 18
Tech.SLIDE_FRICTION = 15
Tech.SLIDE_MAX_TIME = 1.2
Tech.LANDING_SLIDE_WINDOW = 100 -- ms
Tech.LANDING_SLIDE_PERFECT = 40 -- ms
Tech.SLIDE_HOP_WINDOW = { 0.15, 0.30 } -- s
Tech.SLIDE_HOP_BONUS = { 6, 4, 2, 0 }

-- JUMP (Space on the ground): fires at once, keeps your run speed
Tech.JUMP_TAP = 40 -- FEEL: jump speed of a tap ...
Tech.JUMP_FULL = 54 -- ... and of Space held for JUMP_HOLD (higher)
Tech.JUMP_HOLD = 0.2 -- s of hold that adds up to a full jump
-- FEEL: air control is real but limited, so a jump is a commitment: push
-- at AIR_ACCEL, turn at most AIR_TURN °/s, never faster than your takeoff
Tech.AIR_ACCEL = 26
Tech.AIR_TURN = 90 -- °/s

-- THE AIR ACTION (Space again in the air; one per airtime)
--   with a direction: the DIVE (layout) that way
Tech.DIVE_BOOST = 9 -- FEEL: studs/s the dive adds along its direction (distance)
Tech.DIVE_UP = 9 -- FEEL: lift at the start of the dive (higher = longer, floatier arc)
Tech.DIVE_VY_KEEP = 0.4 -- share of your upward speed the dive keeps
Tech.DIVE_TURN_KEEP = 0.35 -- share of your speed carried into a dive straight backwards (100 % straight ahead)
Tech.DIVE_MIN_SPEED = 18 -- a dive from a standstill still travels at this
Tech.DIVE_MAX_SPEED = 46
Tech.DIVE_GRAVITY_MULT = 0.9 -- gravity x this while diving
--   ... close to the ground: the WAVEDASH (no layout, land in a fast slide)
Tech.WAVEDASH_WINDOW = 80 -- ms before landing
Tech.WAVEDASH_PERFECT = 40
Tech.WAVEDASH_BURST = 10 -- studs/s added
Tech.WAVEDASH_BURST_PERFECT = 14
Tech.WAVEDASH_TURN_KEEP = 0.4 -- share of your speed kept wavedashing straight backwards (100 % straight ahead)
Tech.WAVE_SLIDE_TIME = 0.45 -- s of slide before you run again (Space hops, Shift carves)
--   with no direction: the SKY REACH (hands up at the top of a jump)
Tech.SKY_REACH_HANG = 0.12 -- s you hang
Tech.SKY_REACH_TIME = 0.4 -- s the extra reach lasts
Tech.SKY_REACH = 1 -- studs of extra catch reach

-- LANDING OUT OF A DIVE
Tech.DIVE_SLIDE_FRICTION = 35 -- FEEL: the belly slide (lower = slides further)
Tech.LAYOUT_DOWN_TIME = 0.55 -- FEEL: s face down before getting up ...
Tech.GETUP_TIME = 0.3 -- ... then s getting up (no control)
Tech.TECH_ROLL_WINDOW = 100 -- ms either side of the touchdown: Space is a Tech Roll ...
Tech.TECH_ROLL_PERFECT = 40 -- ... Perfect within this either side
Tech.TECH_ROLL_RECOVER = 0.25 -- s of roll before you run again
Tech.TECH_ROLL_KEEP = 0.5 -- share of the dive's speed a Clean roll keeps
Tech.TECH_ROLL_KEEP_PERFECT = 0.75 -- ... and a Perfect one
Tech.SCRAMBLE_DOWN = 0.15 -- s: Space after the roll window cuts the rest of the face-down time to this

-- world-class tech
Tech.WALL_KICK_WINDOW = 80 -- ms after touching the wall
Tech.WALL_KICK_PERFECT = 30
Tech.WALL_KICK_PUSH = 10
Tech.WALL_KICK_PERFECT_BONUS = 4
Tech.WALL_KICK_KEEP = 0.9
Tech.WALL_KICK_UP = 30
Tech.FLIP_RESET_RADIUS = 1.8 -- studs from the soles to the disc
Tech.PINCH_WINDOW = 40 -- ms either side of touchdown
Tech.PINCH_PERFECT = 15
Tech.PINCH_SPEED = 1.3 -- disc speed x this
Tech.PINCH_SPEED_PERFECT = 1.4

-- catching
Tech.TIMED_CATCH = true -- humans press Catch on time (bots catch on contact)
-- strict: a touch with no timed press bobbles (the spec). Off: it is still a
-- catch, and a timed press earns the Perfect Catch / Hot Hands bonus.
Tech.TIMED_CATCH_STRICT = false
-- against a human thrower a bot defender gets its hands on a throw only this
-- often (rolled once per throw): bots read flights perfectly
Tech.BOT_INTERCEPT_CHANCE = 0.55
Tech.CATCH_LAG_ALLOWANCE = 100 -- ms the server adds (plus ping)
Tech.UNTIMED_RETRY = 1.0 -- s: a second untimed touch inside this drops the disc
Tech.HOT_HANDS_TIME = 0.4 -- s after a Perfect Catch
Tech.HOT_HANDS_POWER = 0.7
Tech.CATCH_RADIUS = 2.5
Tech.CATCH_WINDOW = 180 -- ± ms
Tech.CATCH_PERFECT = 50 -- ± ms

-- disc (later step: 5)
Tech.DISC_GRAVITY = 60
Tech.DISC_DRAG = 0.0035
Tech.DISC_LIFT = 0.0028
Tech.SPIN_DECAY = 0.15
Tech.SNAP_ZONE = { 0.75, 0.85 }
Tech.SNAP_POINT = 0.80
Tech.SNAP_PERFECT = 20 -- ± ms

-- the pivot (holding the disc)
Tech.PIVOT_REACH = 1.2 -- studs the free foot steps from the pivot
Tech.PIVOT_LUNGE = 1.8 -- a double-tap lunge
Tech.PIVOT_LUNGE_TIME = 0.2
Tech.PIVOT_LUNGE_RECOVER = 0.25

-- defense and rules
Tech.STALL_COUNT = 10
Tech.HAND_BLOCK_ACTIVE = 0.2
Tech.POINT_BLOCK_WINDOW = 80 -- ms of the release
Tech.POINT_BLOCK_FLOW = 20
Tech.MIRROR_WINDOW = 120 -- ms
Tech.MARK_SPEED = 20 -- studs/s: the mark shuffle (spec 30: 14)
Tech.MARK_ACCEL = 160 -- studs/s²: it starts and stops on a dime
Tech.MIRROR_RANGE = 8 -- studs: only the opponent you're closest to within this
Tech.MIRROR_BONUS = 2
Tech.JUKED_LOSS = 0.30
Tech.CONTACT_LOSS = 0.30 -- speed lost running through a player
Tech.CONTACT_RADIUS = 2 -- studs between roots that counts as overlapping
Tech.FOUL_WINDOW = 0.3 -- s: a defender's touch this close to the receiver's claim, overlapping, is a foul

---------------------------------------------------------------------------
-- THE DISC, THROWING AND CATCHING (Config/Disc is an alias of Tech.Disc)
---------------------------------------------------------------------------

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
--
-- Tempo: the real-world model above flies a mid-range throw at about a
-- sprinter's speed, which reads as a floaty balloon. Every flight therefore
-- runs TEMPO times faster: the same shapes and ranges in studs, flight times
-- divided by TEMPO (speeds and spin x TEMPO, accelerations x TEMPO^2). Wind,
-- deflection and bobble velocities scale the same way, so nothing changes
-- shape - a 110-stud backhand just arrives in ~2.7 s instead of ~4.1 s.
local TEMPO = 1.8

local Disc = {
	Tempo = TEMPO,
	Physics = {
		Dt = 1 / 120, -- fixed simulation step, identical on client and server
		Gravity = 29.4 * TEMPO * TEMPO, -- studs/s^2 (9.81 m/s^2 * 3, at TEMPO)
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
		SpinDecay = 0.1 * TEMPO, -- per second (docs/tech-spec.md SPIN_DECAY 0.15 at tempo 1.5)
		-- fade drift (spec): the tilt rolls toward the fade side at
		-- (1 - spin share) x FadeDrift, where spin share is |spin| / Throw.SpinBase,
		-- so a low-spin (overcharged) disc fades early and a Snap holds its edge
		FadeDrift = math.rad(40) * TEMPO / 1.5, -- radians per second at zero spin (40 deg/s at tempo 1.5)
		MinSpin = 8 * TEMPO,
		Radius = 1.1, -- visual/catch radius in studs (~0.27 m disc)
		GroundContact = 0.14, -- disc centre height that counts as touching the ground
		MaxFlightTime = 9,
		HistorySeconds = 0.6, -- server keeps this much flight history for lag compensation
	},

	Throw = {
		-- THROW SHAPE (stage 3, docs/CORE_DESIGN.md): what you are doing at
		-- the release picks the throw (ThrowModel.shape). No throw keys.
		--   nothing held   a flat backhand
		--   A held         a backhand that bends left
		--   D held         a forehand (released from the other side) that bends right
		--   aiming up hard with a strong charge: a Hammer over the defence
		BendInput = 0.3, -- sideways input (A / D) past this bends the throw
		BendBank = 0.35, -- FEEL: how hard a bent throw curves (share of BankRange; 0.35 ~ 30 studs over 130)
		HammerPitch = 28, -- degrees the camera aims above flat ...
		HammerFill = 0.6, -- ... with the charge at least this full: a Hammer
		AimFov = 0.82, -- holding RMB to aim narrows the view to this share
		AimSensitivity = 0.6, -- ... and slows the mouse to this share
		FakeRecovery = 0.2, -- s after a fake (RMB during a charge) before you can charge again
		SpinBase = 50 * TEMPO, -- rad/s (~8 rev/s at real tempo)
		-- Charge and Snap Release (docs/tech-spec.md 25): the ring fills over
		-- ChargeTime; the snap zone is SnapZone of the fill and the Snap
		-- Release is SnapPoint ± SnapPerfect. Model power 1 is a snap.
		ChargeTime = 0.7, -- seconds for the ring to fill (spec 1.0; quicker after playtest)
		SnapZone = { 0.75, 0.85 }, -- of the fill: a clean, stable release
		SnapPoint = 0.80,
		SnapPerfect = 0.025, -- s either side of the snap point = Snap Release
		MinPowerFill = 0, -- the spec floors power at 0.3; 0 keeps the short no-charge dump (the speed floor is Throw.MinSpeed)
		SnapSpin = 1.2,
		OverSpin = 0.6, -- above the zone: full power, wobbly
		LongHold = 1.2, -- of ChargeTime: held this long, spin drops to LongSpin
		LongSpin = 0.4,
		PerfectWindow = 0.05, -- (meter) the Snap band height: 2 x SnapPerfect
		PerfectSpeedMult = 1.05,
		PerfectSpinMult = 1.2,
		OffBalancePowerCap = 0.75,
		OffBalanceSpin = 0.8,
		GroundThrowPowerCap = 0.6,
		MovingSpinPenaltySpeed = 12, -- throwing on the run faster than this costs spin (no pivot yet)
		MovingSpinPenalty = 0.85,
		ThrowerVelocityCarry = 0.45, -- share of the run-up added to the disc (no pivot yet)
		SwingSpinPenalty = 0.9, -- releasing mid Quick Swing costs 10% spin (no power cap)
		MinSpeed = 28 * TEMPO,
		MaxSpeed = 88 * TEMPO, -- sized for the Normal field (see the header)
		PowerCurve = 0.85,
		BankRange = 40, -- degrees of player-controlled bank (edge) either side (spec: ±40)
		BankSteps = 7, -- discrete bank positions for keyboard/gamepad (-3..3)
		FakeCooldown = 0.45,
		FakeDuration = 0.22,
		MinPitch = -12,
		MaxPitch = 60,
		QuickReleaseWindow = 0.6, -- release within this long after a catch = Quick Release
		PassChainWindow = 2.0, -- ... within this long keeps the team's pass chain going
		HandBlockCheckTime = 0.3 * 1.5 / TEMPO, -- seconds of early flight checked against markers' hands (the same distance at any tempo)
		NoCatchTime = 0.15 * 1.5 / TEMPO, -- nobody can catch in the first moments (hand blocks cover that)

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
			ChargeMult = 1.0, -- every player throw charges on the same rhythm
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
	-- what a player's inputs can produce (ThrowModel.shape); the others are
	-- for bots and the training launcher
	PlayerTypes = { "Backhand", "Forehand", "Hammer" },

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
		BobbleSpeed = 95 * TEMPO, -- fingertip catch of a disc faster than this bobbles (disc speed only)
		BlockDepth = 0.9, -- a defender's touch is a Block only this deep at the rim; else an interception
		ContestWindow = 0.04, -- claims this close in time are contested
		ResolveDelay = 0.04, -- server waits this long to collect competing claims
		MaxRewind = 0.3, -- max seconds a claim can be backdated (lag compensation)
		ClaimThrottle = 0.03, -- client: min seconds between claims for one disc (a Denied clears it)
		ClaimTrackTime = 0.08, -- client: keeps tracking after first contact up to this long before claiming
		ClaimRateLimit = 0.02, -- server: min seconds between claims per actor (replies Denied)
		-- Claim slack (CatchGeometry.slack): Base + ping * PingSlackPerSecond
		-- + body speed * SpeedSlack, capped at MaxSlack.
		BaseSlack = 1.3, -- positional tolerance for claims (studs; humans only, bots are judged exactly)
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
		BobbleUp = 16 * TEMPO,
		BobbleCarry = 0.25,
		BlockCarry = 0.18,
		BlockDown = -6 * TEMPO,
		-- Tip (the Tip Reset): an airborne player taps the disc up through
		-- their hands. The Tip zone is a hands-up sphere over the head, on top
		-- of the normal zones. The disc pops ~1.5 studs and comes back down in
		-- ~0.4 s - about as long as the tipper's reset lift keeps them up.
		TipHeight = 3.1, -- Tip sphere centre above the hitbox root
		TipRadius = 1.9,
		TipUp = 14, -- vertical speed of the popped disc
		TipCarry = 0.25, -- share of the disc's velocity it keeps
		TipPush = 4, -- plus this much along the tipper's facing
		TipSpin = 10 * TEMPO,
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
		LowHalfWidth = 2.5, -- (2.8 before hand blocks were sub-stepped; fast discs no longer tunnel)
		HighHalfWidth = 2.0,
		JumpBonus = 1, -- jumping lifts the box by the jump height plus up to this (arms stretch)
		DepthMin = -0.8, -- along the box forward (toward the thrower)
		DepthMax = 2.0,
		RelaxedRadius = 1.6, -- hands-down marker: small zone at the chest
		RewindBase = 0.05, -- hand blocks rewind markers by min(ping / 2 + RewindBase, RewindMax)
		RewindMax = 0.25,
	},
}

Tech.Disc = Disc

return Tech
