--!strict
--[[
	TechConfig — every number of the movement tech (docs/tech-spec.md,
	"Tuning constants"). Logic never hard-codes these; tune here and re-run
	`lune run tests/run.luau tech`.

	Units: studs, seconds, studs/s, studs/s². Timing windows are in ms, as in
	the spec. Values marked "later step" are listed now so the whole table
	lives in one place; nothing reads them until that build step exists.
]]

local Tech = {}

-- engine
Tech.PHYSICS_RATE = 120 -- Hz, fixed timestep
Tech.MAX_FRAME = 0.25 -- s of frame time the accumulator will catch up on at most
Tech.INPUT_BUFFER = 100 -- ms a press stays buffered

-- running
Tech.RUN_TOP_SPEED = 22
Tech.RUN_ACCEL = 60
Tech.GROUND_FRICTION = 80 -- no input (and HoldingDisc / Downed)
Tech.OVERSPEED_DECAY_GROUND = 15
Tech.OVERSPEED_DECAY_AIR = 4
Tech.HARD_SPEED_CAP = 60 -- total speed, nothing exceeds it

-- turning: instant below TURN_FREE_SPEED, then this many °/s at each speed
-- (linear between points, flat past the last one)
Tech.TURN_FREE_SPEED = 12
Tech.TURN_RATE = {
	{ speed = 12, rate = 300 },
	{ speed = 30, rate = 180 },
	{ speed = 50, rate = 90 },
}
-- Steering harder than the turn rate drifts: every 90° turned while the
-- stick asks for more than you can turn costs this fraction of your speed.
Tech.TURN_DRIFT_LOSS = 0.25

-- gravity (the player's own; the disc has DISC_GRAVITY)
Tech.PLAYER_GRAVITY = 140
Tech.FALL_GRAVITY_MULT = 1.3

-- ground contact (controller, not in the spec table)
Tech.GROUND_SNAP = 0.6 -- studs below the feet that still count as standing (step-downs)
Tech.GROUND_SNAP_AIR = 0.15 -- ... while airborne, so a fall lands on touchdown
Tech.GROUND_SPRING = 30 -- 1/s, how fast the body settles to its stand height
Tech.GROUND_SPRING_MAX = 40 -- studs/s, the fastest step-up / step-down

-- burst (later step: 3)
Tech.BURST_TOP_SPEED = 30
Tech.BURST_ACCEL = 90
Tech.BURST_DRAIN = 30
Tech.BURST_REFILL = 15
Tech.BURST_LOCK_UNTIL = 20
Tech.PERFECT_BURST_REFUND = 10
Tech.BURST_KICK = 6
Tech.BURST_KICK_COST = 15
Tech.BURST_KICK_TAP = 120 -- ms
Tech.BURST_KICK_COOLDOWN = 0.5

-- ground tech (later step: 3)
Tech.CUT_KEEP = 0.70
Tech.PERFECT_KEEP = 1.00
Tech.CUT_PERFECT_WINDOW = 80 -- ms
Tech.CUT_REPEAT_CAP = 0.85
Tech.CUT_REPEAT_TIME = 0.6
Tech.JUKE_WINDOW = 120 -- ms
Tech.SLIDE_MIN_SPEED = 18
Tech.SLIDE_FRICTION = 15
Tech.SLIDE_MAX_TIME = 1.2
Tech.LANDING_SLIDE_WINDOW = 100 -- ms
Tech.LANDING_SLIDE_PERFECT = 40 -- ms
Tech.SLIDE_HOP_WINDOW = { 0.15, 0.30 } -- s
Tech.SLIDE_HOP_BONUS = { 6, 4, 2, 0 }

-- air tech (later step: 4)
Tech.JUMP_TAP = 34
Tech.JUMP_FULL = 46
Tech.AIR_DODGE_WINDOW = 1.25
Tech.AIR_DODGE_BURST = 12
Tech.AIR_DODGE_HANG = 0.18
Tech.WAVEDASH_WINDOW = 80 -- ms before landing
Tech.WAVEDASH_PERFECT = 40
Tech.WAVEDASH_BURST = 10
Tech.WAVEDASH_BURST_PERFECT = 14
Tech.REVERSE_SNAP_WINDOW = { 60, 140 } -- ms
Tech.REVERSE_SNAP_PERFECT = { 80, 110 } -- ms
Tech.BURST_DIVE_SPEED = 28
Tech.BURST_DIVE_SPEED_PERFECT = 32

-- catching (later step: 6)
Tech.CATCH_RADIUS = 2.5
Tech.CATCH_WINDOW = 150 -- ± ms
Tech.CATCH_PERFECT = 40 -- ± ms
Tech.LAYOUT_DOWN_TIME = 0.9
Tech.TECH_ROLL_WINDOW = 100 -- ms
Tech.TECH_ROLL_PERFECT = 40
Tech.SKY_CHARGE = 0.4
Tech.SKY_PERFECT = { 0.35, 0.40 }

-- disc (later step: 5)
Tech.DISC_GRAVITY = 60
Tech.DISC_DRAG = 0.0035
Tech.DISC_LIFT = 0.0028
Tech.SPIN_DECAY = 0.15
Tech.SNAP_ZONE = { 0.75, 0.85 }
Tech.SNAP_POINT = 0.80
Tech.SNAP_PERFECT = 20 -- ± ms

-- defense and rules (later step: 8)
Tech.STALL_COUNT = 10
Tech.HAND_BLOCK_ACTIVE = 0.2
Tech.MIRROR_WINDOW = 120 -- ms

return Tech
