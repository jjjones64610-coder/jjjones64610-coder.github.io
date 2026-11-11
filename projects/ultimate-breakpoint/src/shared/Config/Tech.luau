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

-- bots run on this engine too (off the disc; BotService)
Tech.BOTS_USE_TECH = true

-- running
Tech.RUN_TOP_SPEED = 24 -- (spec 22; faster after playtest)
Tech.RUN_ACCEL = 72
Tech.GROUND_FRICTION = 70 -- no input (and HoldingDisc / Downed)
Tech.OVERSPEED_DECAY_GROUND = 15
Tech.OVERSPEED_DECAY_AIR = 4
Tech.HARD_SPEED_CAP = 60 -- total speed, nothing exceeds it

-- turning: instant below TURN_FREE_SPEED, then this many °/s at each speed
-- (linear between points, flat past the last one)
Tech.TURN_FREE_SPEED = 12
Tech.TURN_RATE = {
	{ speed = 12, rate = 380 },
	{ speed = 30, rate = 250 },
	{ speed = 50, rate = 140 },
}
-- Steering harder than the turn rate drifts: every 90° turned while the
-- stick asks for more than you can turn costs this fraction of your speed.
Tech.TURN_DRIFT_LOSS = 0.12
Tech.DRIFT_ACCEL_SHARE = 0 -- accel while a turn is rate-limited (0: a fast turn always costs)

-- gravity (the player's own; the disc has DISC_GRAVITY)
Tech.PLAYER_GRAVITY = 140
Tech.FALL_GRAVITY_MULT = 1.3

-- ground contact (controller, not in the spec table)
Tech.GROUND_SNAP = 0.6 -- studs below the feet that still count as standing (step-downs)
Tech.GROUND_SNAP_AIR = 0.15 -- ... while airborne, so a fall lands on touchdown
Tech.GROUND_SPRING = 30 -- 1/s, how fast the body settles to its stand height
Tech.GROUND_SPRING_MAX = 40 -- studs/s, the fastest step-up / step-down

-- burst
Tech.BURST_TOP_SPEED = 32
Tech.BURST_ACCEL = 90
Tech.BURST_DRAIN = 30
Tech.BURST_REFILL = 15
Tech.BURST_LOCK_UNTIL = 20
Tech.PERFECT_BURST_REFUND = 10
Tech.BURST_KICK = 6
Tech.BURST_KICK_COST = 15
Tech.BURST_KICK_TAP = 120 -- ms
Tech.BURST_KICK_COOLDOWN = 0.5

-- ground tech
Tech.CUT_MIN_SPEED = 12
Tech.CUT_ANGLE = 45 -- ° the stick must turn from your line
Tech.CUT_RESET_ANGLE = 30 -- ° below which the crossing is forgotten
Tech.CUT_PLANT_TIME = 0.12
Tech.CUT_COOLDOWN = 0.35
Tech.PERFECT_CUT_BONUS = 3
Tech.JUKE_KEEP = 0.90
Tech.JUKE_RETURN_ANGLE = 30 -- ° from the old line that counts as "back"
Tech.PLANT_STOP_TIME = 0.15
Tech.PLANT_BOOST_TIME = 0.3
Tech.PLANT_BOOST = 2.0
Tech.PLANT_BOOST_PERFECT = 2.5
Tech.PLANT_PERFECT = 100 -- ms
Tech.SLIDE_TURN = 60 -- °/s
Tech.CARVE_TURN = 220
Tech.CARVE_FRICTION = 40
Tech.LANDING_SLIDE_MIN_SPEED = 12
Tech.SLIDE_HOP_HEIGHT = 0.6 -- of a tap jump's height
Tech.SLIDE_HOP_OFF_WINDOW = 2 -- studs/s outside the window
Tech.HOP_CHAIN_RESET = 1.0 -- s on the ground (not sliding)
Tech.CATCH_RUNOUT_FRICTION = 50
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

-- air tech
Tech.JUMP_TAP = 34
Tech.JUMP_FULL = 46
Tech.JUMP_HOLD = 0.2 -- s of hold that adds up to a full jump
Tech.AIR_ACCEL = 20
Tech.AIR_TURN = 90 -- °/s
Tech.AIR_DODGE_NEUTRAL = 20
Tech.FAST_FALL_MULT = 2.2
Tech.REVERSE_SNAP_ANGLE = 120 -- ° from your line that counts as a backward dodge
Tech.REVERSE_SNAP_KEEP = 0.9
Tech.STUMBLE_TIME = 0.3
Tech.BURST_DIVE_START_SPEED = 4 -- "from a standstill"
Tech.BURST_DIVE_DODGE_WINDOW = 80 -- ms after the jump
Tech.BURST_DIVE_CUT = { 50, 120 } -- ms into the dodge
Tech.BURST_DIVE_CUT_PERFECT = { 70, 100 }
Tech.BURST_DIVE_ANGLE = { 15, 75 } -- ° from forward that counts as forward-diagonal
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

-- world-class tech (TechCore header)
Tech.STALL_WINDOW = 30 -- ms after the dodge
Tech.STALL_PERFECT = 15
Tech.STALL_HANG = 0.25
Tech.ZAP_WINDOW = 60 -- ms after the wavedash lands
Tech.ZAP_PERFECT = 25
Tech.ZAP_BURST = 8
Tech.ZAP_BURST_PERFECT = 11
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

-- layout, tech roll, sky
Tech.LAYOUT_MIN_SPEED = 15
Tech.LAYOUT_BOOST = 8
Tech.LAYOUT_UP = 10
Tech.LAYOUT_CONE = 45
Tech.TECH_ROLL_RECOVER = 0.25
Tech.TECH_ROLL_KEEP = 0.5
Tech.TECH_ROLL_KEEP_PERFECT = 0.75
Tech.GETUP_TIME = 0.35 -- Recovering after a full Downed
Tech.SKY_MAX_SPEED = 10 -- slower than this, Jump charges a Sky instead of jumping
Tech.SKY_MIN_HOLD = 0.2
Tech.SKY_SLOW = 0.6
Tech.SKY_HEIGHT = 1.6
Tech.SKY_HEIGHT_PERFECT = 1.7
Tech.SKY_REACH = 1 -- studs of extra reach on a Perfect Sky

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
Tech.LAUNCH_ANGLE = { -5, 35 } -- degrees, the mouse sets it while charging
Tech.RUN_THROUGH_CONE = 10 -- studs/s of speed per degree of aim cone (spec 29: 5)
Tech.FAKE_RECOVERY = 0.2 -- s after a pump fake before the next throw
Tech.FAKE_SWITCH_WINDOW = 0.15 -- s: the other throw this soon skips the recovery

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
Tech.MARK_SPEED = 15 -- studs/s: the mark shuffle (spec 30: 14)
Tech.MARK_ACCEL = 140 -- studs/s²: it starts and stops on a dime
Tech.MIRROR_RANGE = 8 -- studs: only the opponent you're closest to within this
Tech.MIRROR_BONUS = 2
Tech.JUKED_LOSS = 0.30
Tech.CONTACT_LOSS = 0.30 -- speed lost running through a player
Tech.CONTACT_RADIUS = 2 -- studs between roots that counts as overlapping
Tech.FOUL_WINDOW = 0.3 -- s: a defender's touch this close to the receiver's claim, overlapping, is a foul

return Tech
