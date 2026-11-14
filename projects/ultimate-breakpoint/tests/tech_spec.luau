local roblox = require("@lune/roblox")
local Vector3 = roblox.Vector3
local H = require("./harness")
local TechCore = H.require("Movement/TechCore")
local Config = H.require("Config/Tech")

local test, expect = H.test, H.expect

print("tech core (build step 1)")

local GROUND = { grounded = true }
local AIR = { grounded = false }
local FWD = Vector3.new(0, 0, -1)
local RIGHT = Vector3.new(1, 0, 0)

local function near(a: number, b: number, tol: number): boolean
	return math.abs(a - b) <= tol
end

-- Runs fixed steps for `seconds` with a constant input.
local function run(s, move: Vector3, env, seconds: number)
	local n = math.floor(seconds * Config.PHYSICS_RATE + 0.5)
	for _ = 1, n do
		TechCore.step(s, { move = move }, env, TechCore.STEP)
	end
end

-- Seconds until `pred` holds (or nil within `limit`).
local function timeUntil(s, move: Vector3, env, pred, limit: number): number?
	local t = 0
	while t < limit do
		if pred(s) then
			return t
		end
		TechCore.step(s, { move = move }, env, TechCore.STEP)
		t += TechCore.STEP
	end
	return nil
end

local function moving(speed: number, dir: Vector3?)
	local s = TechCore.new(0)
	s.vel = (dir or FWD) * speed
	s.heading = dir or FWD
	return s
end

test("acceleration: rest to run speed at RUN_ACCEL, never past it", function()
	local s = TechCore.new(0)
	local t = timeUntil(s, FWD, GROUND, function(st)
		return TechCore.flatSpeed(st) >= Config.RUN_TOP_SPEED - 1e-6
	end, 3)
	local ideal = Config.RUN_TOP_SPEED / Config.RUN_ACCEL
	expect(t ~= nil and near(t, ideal, 0.02), string.format("reached run speed in %s s, want %.3f", tostring(t), ideal))
	run(s, FWD, GROUND, 2)
	expect(near(TechCore.flatSpeed(s), Config.RUN_TOP_SPEED, 1e-6), "holds run speed")
end)

test("friction: no input holds the plant, then stops you at GROUND_FRICTION", function()
	local s = moving(Config.RUN_TOP_SPEED)
	local t = timeUntil(s, Vector3.zero, GROUND, function(st)
		return TechCore.flatSpeed(st) <= 1e-6
	end, 2)
	local held = Config.CUT_RELEASE_MAX
	local ideal = held + (Config.RUN_TOP_SPEED - Config.PLANT_HOLD_FRICTION * held) / Config.GROUND_FRICTION
	expect(t ~= nil and near(t, ideal, 0.03), string.format("stopped in %s s, want %.3f", tostring(t), ideal))
end)

test("a part-pushed stick runs slower", function()
	local s = TechCore.new(0)
	run(s, FWD * 0.5, GROUND, 1)
	expect(near(TechCore.flatSpeed(s), Config.RUN_TOP_SPEED * 0.5, 1e-6), "half stick, half speed")
end)

test("overspeed decays: fast on the ground, slow in the air", function()
	local g = moving(40)
	run(g, FWD, GROUND, 0.5)
	expect(near(TechCore.flatSpeed(g), 40 - Config.OVERSPEED_DECAY_GROUND * 0.5, 0.05), "ground decay")
	local a = moving(40)
	a.grounded = false
	run(a, FWD, AIR, 0.5)
	expect(near(TechCore.flatSpeed(a), 40 - Config.OVERSPEED_DECAY_AIR * 0.5, 0.05), "air decay")
	local long = moving(40)
	run(long, FWD, GROUND, 5)
	expect(near(TechCore.flatSpeed(long), Config.RUN_TOP_SPEED, 1e-3), "settles at run speed, not below")
end)

test("hard cap: flat and fall speed never pass HARD_SPEED_CAP", function()
	local s = moving(200)
	s.grounded = false
	s.vel = Vector3.new(0, -200, -200)
	TechCore.step(s, { move = FWD }, AIR, TechCore.STEP)
	expect(TechCore.flatSpeed(s) <= Config.HARD_SPEED_CAP + 1e-3, "flat capped, got " .. TechCore.flatSpeed(s))
	expect(-s.vel.Y <= Config.HARD_SPEED_CAP + 1e-3, "fall capped")
	local fall = moving(20)
	fall.grounded = false
	run(fall, Vector3.zero, AIR, 3)
	expect(-fall.vel.Y <= Config.HARD_SPEED_CAP + 1e-3, "a long fall is capped too")
	expect(near(TechCore.flatSpeed(fall), 20, 1e-3), "and doesn't eat the run")
end)

test("turn rate curve matches the spec points", function()
	expect(TechCore.turnRate(11.9) == math.huge, "instant under 12")
	local R = Config.TURN_RATE
	expect(near(TechCore.turnRate(12), R[1].rate, 1e-6), "first point")
	expect(near(TechCore.turnRate(30), R[2].rate, 1e-6), "second point")
	expect(near(TechCore.turnRate(50), R[3].rate, 1e-6), "third point")
	expect(near(TechCore.turnRate(21), (R[1].rate + R[2].rate) / 2, 1e-6), "linear between")
	expect(near(TechCore.turnRate(60), R[3].rate, 1e-6), "flat past the last")
	expect(R[1].rate > R[2].rate and R[2].rate > R[3].rate, "faster turns slower")
end)

test("turning is instant when slow", function()
	local s = moving(10)
	TechCore.step(s, { move = RIGHT }, GROUND, TechCore.STEP)
	local dir = s.vel.Unit
	expect(dir:Dot(RIGHT) > 0.999, "a jog turns on the spot")
end)

test("fast turns are rate-limited and drifting costs speed", function()
	local s = moving(Config.RUN_TOP_SPEED)
	TechCore.step(s, { move = RIGHT }, GROUND, TechCore.STEP)
	local turned = math.deg(math.acos(math.clamp(s.vel.Unit:Dot(FWD), -1, 1)))
	local limit = TechCore.turnRate(Config.RUN_TOP_SPEED) * TechCore.STEP
	expect(near(turned, limit, 0.01), string.format("turned %.3f°, limit %.3f°", turned, limit))
	expect(s.drifting, "drifting")
	expect(TechCore.flatSpeed(s) < Config.RUN_TOP_SPEED, "lost speed")

	-- a 90° drift at speed costs about TURN_DRIFT_LOSS
	local d = moving(Config.RUN_TOP_SPEED)
	local t = timeUntil(d, RIGHT, GROUND, function(st)
		return st.vel.Magnitude > 0 and st.vel.Unit:Dot(RIGHT) > 0.999
	end, 2)
	expect(t ~= nil, "finishes the turn")
	local kept = TechCore.flatSpeed(d) / Config.RUN_TOP_SPEED
	expect(
		kept < 1 - Config.TURN_DRIFT_LOSS * 0.5 and kept > 1 - Config.TURN_DRIFT_LOSS * 1.6,
		string.format("kept %.2f of the speed through 90°", kept)
	)

	-- a gentle curve inside the limit costs nothing
	local c = moving(Config.RUN_TOP_SPEED)
	local slight = (FWD + RIGHT * 0.01).Unit
	TechCore.step(c, { move = slight }, GROUND, TechCore.STEP)
	expect(not c.drifting and near(TechCore.flatSpeed(c), Config.RUN_TOP_SPEED, 1e-3), "no loss on a gentle curve")
end)

test("reversing at speed is slow without tech", function()
	local s = moving(Config.RUN_TOP_SPEED)
	local t = timeUntil(s, -FWD, GROUND, function(st)
		return st.vel.Magnitude > 0 and st.vel.Unit:Dot(-FWD) > 0.999 and TechCore.flatSpeed(st) > 15
	end, 3)
	expect(t ~= nil and t > 0.3, "a plain reversal takes time, got " .. tostring(t))
end)

test("gravity: PLAYER_GRAVITY up, x FALL_GRAVITY_MULT down", function()
	local up = TechCore.new(0)
	up.grounded = false
	up.state = "Airborne"
	up.vel = Vector3.new(0, 30, 0)
	run(up, Vector3.zero, AIR, 0.1)
	expect(near(up.vel.Y, 30 - Config.PLAYER_GRAVITY * 0.1, 0.01), "rising: " .. up.vel.Y)
	local down = TechCore.new(0)
	down.grounded = false
	down.state = "Airborne"
	run(down, Vector3.zero, AIR, 0.1)
	-- the first step starts at rest (not yet moving down), the rest fall faster
	local want = -Config.PLAYER_GRAVITY * TechCore.STEP * (1 + Config.FALL_GRAVITY_MULT * 11)
	expect(near(down.vel.Y, want, 0.01), "falling: " .. down.vel.Y)
	local g = TechCore.new(0)
	run(g, FWD, GROUND, 0.5)
	expect(g.vel.Y == 0, "no vertical speed on the ground")
end)

test("air steer: weak, rate-limited, never above takeoff speed", function()
	local s = moving(Config.RUN_TOP_SPEED)
	s.grounded = false
	s.state = "Airborne"
	s.takeoffSpeed = Config.RUN_TOP_SPEED
	run(s, RIGHT, AIR, 0.3)
	local flat = Vector3.new(s.vel.X, 0, s.vel.Z)
	local turned = math.deg(math.acos(math.clamp(flat.Unit:Dot(FWD), -1, 1)))
	expect(turned <= Config.AIR_TURN * 0.3 + 1, "turned " .. turned)
	expect(turned > 5, "but it does steer")
	expect(flat.Magnitude <= Config.RUN_TOP_SPEED + 1e-3, "no speed past takeoff")
end)

test("fixed timestep: the same result at any frame rate", function()
	local results = {}
	for _, fps in { 20, 60, 144, 240 } do
		local s = TechCore.new(0)
		local dt = 1 / fps
		for i = 1, fps do -- one second
			local move = if i <= fps / 2 then FWD else RIGHT
			TechCore.advance(s, { move = move }, GROUND, dt)
		end
		table.insert(results, s.vel)
	end
	for i = 2, #results do
		expect((results[i] - results[1]).Magnitude < 1.5, "frame rates agree: " .. tostring(results[i]))
	end
	local big = TechCore.new(0)
	local r = TechCore.advance(big, { move = FWD }, GROUND, 10)
	expect(r.steps <= Config.MAX_FRAME * Config.PHYSICS_RATE + 1, "a hitch catches up at most MAX_FRAME")
end)

test("state machine: ground, air, holding and marking follow the world", function()
	local s = TechCore.new(0)
	expect(s.state == "Grounded", "starts grounded")
	TechCore.step(s, { move = FWD }, AIR, TechCore.STEP)
	expect(s.state == "Airborne" and s.frame.leftGround, "walking off a ledge is Airborne")
	s.frame = { steps = 0, landed = false, leftGround = false, landingSpeed = 0 }
	run(s, Vector3.zero, AIR, 0.2)
	TechCore.step(s, { move = FWD }, GROUND, TechCore.STEP)
	expect(s.state == "Grounded" and s.frame.landed and s.frame.landingSpeed > 0, "landing")
	TechCore.setMarking(s, true)
	expect(s.state == "Marking", "marking")
	TechCore.setMarking(s, false)
	TechCore.setHolding(s, true)
	expect(s.state == "HoldingDisc", "holding")
	TechCore.setHolding(s, false)
	expect(s.state == "Grounded", "released")
end)

test("holding the disc: no running, friction brings you to a stop", function()
	local s = moving(Config.RUN_TOP_SPEED)
	TechCore.setHolding(s, true)
	run(s, FWD, GROUND, 0.2)
	expect(TechCore.flatSpeed(s) < Config.RUN_TOP_SPEED, "slowing")
	run(s, FWD, GROUND, 0.5)
	expect(TechCore.flatSpeed(s) == 0, "stopped, the stick does nothing")
	-- caught in the air: still airborne until touchdown, then HoldingDisc
	local a = moving(10)
	a.grounded = false
	a.state = "Airborne"
	TechCore.setHolding(a, true)
	expect(a.state == "Airborne", "a catch in the air stays Airborne")
	TechCore.step(a, { move = FWD }, GROUND, TechCore.STEP)
	expect(a.state == "HoldingDisc", "lands holding")
end)

test("tech transitions follow the table", function()
	local s = TechCore.new(0)
	expect(TechCore.enter(s, "Sliding"), "Grounded -> Sliding")
	expect(not TechCore.enter(s, "Downed"), "Sliding -> Downed is refused")
	expect(TechCore.enter(s, "Downed", true) and s.state == "Downed", "forced")
	expect(not TechCore.canEnter(s, "Grounded"), "Downed only recovers")
	expect(TechCore.enter(s, "Recovering"), "Downed -> Recovering")
	for from, tos in TechCore.Transitions do
		for to in tos do
			expect(TechCore.Transitions[to] ~= nil, from .. " -> unknown state " .. to)
		end
	end
	local d = moving(20)
	TechCore.enter(d, "Diving", true)
	TechCore.enter(d, "Downed")
	d.downedUntil = d.now + 5
	run(d, FWD, GROUND, 1)
	expect(TechCore.flatSpeed(d) == 0, "Downed can't move")
end)

test("input buffer: a press lives INPUT_BUFFER ms and fires once", function()
	local s = TechCore.new(0)
	TechCore.press(s, "Cut", 10)
	local w = Config.INPUT_BUFFER / 1000
	expect(TechCore.buffered(s, "Cut", 10 + w * 0.9) == 10, "still buffered")
	expect(TechCore.buffered(s, "Cut", 10 + w * 1.1) == nil, "expired")
	expect(TechCore.consume(s, "Cut", 10 + w * 0.5) == 10, "consumed")
	expect(TechCore.consume(s, "Cut", 10 + w * 0.6) == nil, "only once")
	TechCore.press(s, "Jump", 20)
	TechCore.reset(s)
	expect(TechCore.buffered(s, "Jump", 20) == nil, "reset clears the buffer")
end)

test("timing readout: early / late, Perfect / Clean / Miss", function()
	local s = TechCore.new(0)
	local t = TechCore.noteTiming(s, "Cut", -34.2, 120, 80)
	expect(t.quality == "Perfect" and TechCore.describeTiming(t) == "Cut: 34 ms early", TechCore.describeTiming(t))
	t = TechCore.noteTiming(s, "Cut", 95, 120, 80)
	expect(t.quality == "Clean" and TechCore.describeTiming(t) == "Cut: 95 ms late", "late clean")
	t = TechCore.noteTiming(s, "Catch", 200, 150, 40)
	expect(t.quality == "Miss" and s.lastTiming == t, "miss recorded")
	expect(TechCore.describeTiming(TechCore.noteTiming(s, "Snap", 0.2, 20)) == "Snap: on time", "on time")
end)

test("walls: you slide along, never into them", function()
	local s = moving(Config.RUN_TOP_SPEED, (FWD + RIGHT).Unit)
	TechCore.step(s, { move = (FWD + RIGHT).Unit }, { grounded = true, wallNormal = -RIGHT }, TechCore.STEP)
	expect(s.vel:Dot(RIGHT) <= 1e-6 and s.vel:Dot(FWD) > 0, "slides along the wall")
end)

test("frozen: no flat movement, gravity still pulls", function()
	local s = moving(Config.RUN_TOP_SPEED)
	TechCore.setFrozen(s, true)
	run(s, FWD, GROUND, 0.2)
	expect(TechCore.flatSpeed(s) == 0, "frozen in place")
end)

test("fuzz: random input and terrain never breaks the cap or makes NaN", function()
	local Rng = H.require("Util/Rng")
	local rng = Rng.new(7)
	local s = TechCore.new(0)
	for i = 1, 60000 do
		if i % 97 == 0 then
			s.vel += Vector3.new(Rng.range(rng, -80, 80), Rng.range(rng, -40, 60), Rng.range(rng, -80, 80))
		end
		if i % 501 == 0 then
			TechCore.setHolding(s, not s.holding)
		end
		local a = Rng.next(rng) * math.pi * 2
		local move = Vector3.new(math.cos(a), 0, math.sin(a)) * Rng.range(rng, 0, 1.2)
		local env = { grounded = (i // 200) % 3 ~= 0 }
		local r = TechCore.advance(s, { move = move }, env, Rng.range(rng, 0, 1 / 20))
		local v = s.vel
		expect(v.X == v.X and v.Y == v.Y and v.Z == v.Z, "NaN at " .. i)
		if r.steps > 0 then
			local over = TechCore.flatSpeed(s) > Config.HARD_SPEED_CAP + 1e-3
				or math.abs(v.Y) > Config.HARD_SPEED_CAP + 1e-3
			expect(not over, "over the cap at " .. i)
		end
		expect(TechCore.Transitions[s.state] ~= nil, "unknown state at " .. i)
	end
end)

---------------------------------------------------------------------------
-- tech (build steps 3-4, layout, tech roll, sky)
---------------------------------------------------------------------------

print("tech moves")

-- A flat floor at y = 0 and a body: steps the core with held buttons and
-- presses at given sim times, like the client does.
local function newWorld(speed: number?, dir: Vector3?)
	local s = moving(speed or 0, dir)
	return { s = s, y = 0, held = {} :: { [string]: boolean }, move = dir or FWD }
end

local function worldStep(w)
	local s = w.s
	local grounded = w.y <= 1e-6 and s.vel.Y <= 0.01
	local ttl = nil
	if not grounded then
		local vy, g = s.vel.Y, Config.PLAYER_GRAVITY * Config.FALL_GRAVITY_MULT
		ttl = (vy + math.sqrt(math.max(vy * vy + 2 * g * w.y, 0))) / g
	end
	TechCore.step(
		s,
		{ move = w.move, held = w.held, aim = w.aim },
		{ grounded = grounded, timeToLand = ttl },
		TechCore.STEP
	)
	w.y = math.max(0, w.y + s.vel.Y * TechCore.STEP)
end

local function worldRun(w, seconds: number)
	for _ = 1, math.floor(seconds * Config.PHYSICS_RATE + 0.5) do
		worldStep(w)
	end
end

local function worldUntil(w, pred, limit: number): boolean
	local t = 0
	while t < limit do
		if pred(w) then
			return true
		end
		worldStep(w)
		t += TechCore.STEP
	end
	return false
end

local function events(s, tech: string)
	local out = {}
	for _, e in s.events do
		if e.tech == tech then
			table.insert(out, e)
		end
	end
	return out
end

local function tap(w, action: string)
	TechCore.press(w.s, action, w.s.now)
end

test("burst: hold for 30 top speed, drains, refills, locks at 0", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.held.Burst = true
	worldRun(w, 0.5)
	expect(TechCore.flatSpeed(w.s) > Config.RUN_TOP_SPEED + 5, "faster with burst: " .. TechCore.flatSpeed(w.s))
	expect(near(w.s.burst, 100 - Config.BURST_DRAIN * 0.5, 1), "drains: " .. w.s.burst)
	worldRun(w, 4)
	expect(w.s.burst == 0 and w.s.burstLocked, "empty and locked")
	worldRun(w, 1)
	expect(TechCore.flatSpeed(w.s) <= Config.RUN_TOP_SPEED + 0.5, "locked: back to run speed")
	w.held.Burst = false
	local unlockAt = Config.BURST_LOCK_UNTIL / Config.BURST_REFILL
	worldRun(w, unlockAt - 0.15)
	expect(w.s.burstLocked, "still locked under 20")
	worldRun(w, 0.4)
	expect(
		not w.s.burstLocked and near(w.s.burst, Config.BURST_REFILL * (unlockAt + 0.25), 1),
		"unlocked: " .. w.s.burst
	)
end)

test("burst kick: a tap adds 6 now, costs 15, has a cooldown", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.held.Burst = true
	worldRun(w, 0.05)
	w.held.Burst = false
	worldStep(w)
	expect(#events(w.s, "BurstKick") == 1, "kicked")
	expect(TechCore.flatSpeed(w.s) > Config.RUN_TOP_SPEED + 5, "+6: " .. TechCore.flatSpeed(w.s))
	expect(near(w.s.burst, 100 - Config.BURST_KICK_COST, 0.5), "cost 15, the drain refunded: " .. w.s.burst)
	w.held.Burst = true
	worldRun(w, 0.05)
	w.held.Burst = false
	worldStep(w)
	expect(#events(w.s, "BurstKick") == 1, "cooldown")
	local hold = newWorld(Config.RUN_TOP_SPEED)
	hold.held.Burst = true
	worldRun(hold, 0.3)
	hold.held.Burst = false
	worldStep(hold)
	expect(#events(hold.s, "BurstKick") == 0, "a long hold is no kick")
end)

-- The cut gesture: let go of the stick for `gap` s, then push `dir`.
local function letGoThen(w, gap: number, dir: Vector3)
	w.move = Vector3.zero
	worldRun(w, gap)
	w.move = dir
	worldStep(w)
end

test("cut: a Perfect let-go keeps 100 % + 3, a mistimed one keeps CUT_KEEP", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(w, 0.08, RIGHT)
	local cuts = events(w.s, "Cut")
	expect(#cuts == 1 and cuts[1].quality == "Perfect", "a Perfect cut")
	expect(w.s.vel.Unit:Dot(RIGHT) > 0.99, "goes the new way at once")
	expect(
		near(TechCore.flatSpeed(w.s), Config.RUN_TOP_SPEED + Config.PERFECT_CUT_BONUS, 0.6),
		"keeps it all + 3: " .. TechCore.flatSpeed(w.s)
	)

	local late = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(late, 0.18, RIGHT)
	local c = events(late.s, "Cut")
	expect(#c == 1 and c[1].quality == "Clean", "a late let-go is a Clean cut")
	expect(near(TechCore.flatSpeed(late.s), Config.RUN_TOP_SPEED * Config.CUT_KEEP, 1), "keeps CUT_KEEP")
	expect(late.s.lastTiming and late.s.lastTiming.offsetMs > 0, "timing says late")

	local rushed = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(rushed, 0.016, RIGHT)
	local r = events(rushed.s, "Cut")
	expect(#r == 1 and r[1].quality == "Clean", "a rushed let-go is Clean")
	expect(rushed.s.lastTiming and rushed.s.lastTiming.offsetMs < 0, "timing says early")
end)

test("cut: sharp cuts keep less, repeats are capped, a long let-go is just a stop", function()
	local rev = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(rev, 0.08, -FWD)
	expect(#events(rev.s, "Cut") == 1, "a reversal is a cut")
	local want = (Config.RUN_TOP_SPEED * Config.PERFECT_KEEP * Config.CUT_REVERSE_KEEP) + Config.PERFECT_CUT_BONUS
	expect(near(TechCore.flatSpeed(rev.s), want, 0.6), "a reversal keeps less: " .. TechCore.flatSpeed(rev.s))

	local w = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(w, 0.08, RIGHT)
	worldRun(w, Config.CUT_COOLDOWN)
	local before = TechCore.flatSpeed(w.s)
	letGoThen(w, 0.08, FWD)
	expect(#events(w.s, "Cut") == 2, "second cut")
	expect(TechCore.flatSpeed(w.s) <= before * Config.CUT_REPEAT_CAP + 0.05, "capped at 85 %")

	local stop = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(stop, Config.CUT_RELEASE_MAX + 0.1, RIGHT)
	expect(#events(stop.s, "Cut") == 0, "no cut after a long let-go")
	expect(TechCore.flatSpeed(stop.s) < Config.RUN_TOP_SPEED * 0.7, "you slowed down")

	local stutter = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(stutter, 0.08, FWD)
	expect(#events(stutter.s, "Cut") == 0, "the same way again is a stutter, not a cut")
end)

test("juke: right after a cut, the stick back to the old line puts you on it at 90 %", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(w, 0.08, RIGHT)
	worldRun(w, 0.05)
	w.move = FWD
	worldStep(w)
	expect(#events(w.s, "Juke") == 1, "a juke")
	expect(w.s.vel.Unit:Dot(FWD) > 0.99, "back on the old line")
	expect(near(TechCore.flatSpeed(w.s), Config.RUN_TOP_SPEED * Config.JUKE_KEEP, 0.05), "90 %")
	local late = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(late, 0.08, RIGHT)
	worldRun(late, Config.JUKE_WINDOW / 1000 + 0.05)
	late.move = FWD
	worldStep(late)
	expect(#events(late.s, "Juke") == 0, "too late to juke")
end)

test("skid: a hard yank at speed with no plant skids and costs speed", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.move = -FWD
	worldStep(w)
	expect(w.s.state == "Sliding" and w.s.skid and #events(w.s, "Skid") == 1, "skidding")
	worldRun(w, 0.2)
	expect(
		near(TechCore.flatSpeed(w.s), Config.RUN_TOP_SPEED - Config.SKID_FRICTION * 0.2, 1),
		"skid friction: " .. TechCore.flatSpeed(w.s)
	)
	worldRun(w, Config.SKID_MAX_TIME)
	expect(w.s.state ~= "Sliding", "runs again after the skid")
	local slow = newWorld(Config.SKID_MIN_SPEED - 4)
	slow.move = -FWD
	worldStep(slow)
	expect(slow.s.state ~= "Sliding", "too slow to skid")
	-- the same turn with a Perfect plant keeps the speed instead
	local good = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(good, 0.08, (-FWD + RIGHT).Unit)
	expect(
		good.s.state ~= "Sliding" and TechCore.flatSpeed(good.s) > Config.RUN_TOP_SPEED * 0.85,
		"the plant beats the skid"
	)
end)

test("jump: a tap is JUMP_TAP up, a hold reaches JUMP_FULL", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	tap(w, "Jump")
	worldStep(w)
	expect(
		not w.s.grounded and near(w.s.vel.Y, Config.JUMP_TAP - Config.PLAYER_GRAVITY * TechCore.STEP, 0.5),
		"tap: " .. w.s.vel.Y
	)
	local peakTap = 0
	worldUntil(w, function(x)
		peakTap = math.max(peakTap, x.y)
		return x.s.grounded
	end, 2)
	local h = newWorld(Config.RUN_TOP_SPEED)
	h.held.Jump = true
	tap(h, "Jump")
	local peakFull = 0
	worldStep(h)
	worldUntil(h, function(x)
		peakFull = math.max(peakFull, x.y)
		return x.s.grounded
	end, 2)
	expect(peakFull > peakTap * 1.5, string.format("full %.2f vs tap %.2f", peakFull, peakTap))
end)

-- Jump, then the air action `seconds` later with the stick on `dir`.
local function jumpThen(w, seconds: number, dir: Vector3)
	tap(w, "Jump")
	worldRun(w, seconds)
	w.move = dir
	tap(w, "Jump")
	worldStep(w)
end

local function untilLanded(w)
	worldUntil(w, function(x)
		return x.s.grounded
	end, 3)
end

test("dive: Space again in the air with a direction lays out that way", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	jumpThen(w, 0.12, FWD)
	local e = events(w.s, "Layout")
	expect(#e == 1 and w.s.state == "Diving", "diving")
	expect(
		near(TechCore.flatSpeed(w.s), Config.RUN_TOP_SPEED + Config.DIVE_BOOST, 0.6),
		"speed + DIVE_BOOST: " .. TechCore.flatSpeed(w.s)
	)
	-- sideways: the speed swings into the new direction, a little lost
	local side = newWorld(Config.RUN_TOP_SPEED)
	jumpThen(side, 0.12, RIGHT)
	expect(Vector3.new(side.s.vel.X, 0, side.s.vel.Z).Unit:Dot(RIGHT) > 0.99, "dives where the stick points")
	local keep = 1 + (Config.DIVE_TURN_KEEP - 1) * 0.5
	expect(near(TechCore.flatSpeed(side.s), Config.RUN_TOP_SPEED * keep + Config.DIVE_BOOST, 0.6), "90° keeps less")
	-- one air action per airtime
	tap(w, "Jump")
	worldStep(w)
	expect(#events(w.s, "Layout") == 1, "only one dive")
	-- no Space on the ground ever dives (the old dive key is gone)
	local g = newWorld(Config.RUN_TOP_SPEED)
	TechCore.press(g.s, "Dive", g.s.now)
	worldStep(g)
	expect(#events(g.s, "Layout") == 0, "no ground dive")
end)

test("dive landing: belly slide, then get up; Space on the touchdown is a Tech Roll", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	jumpThen(w, 0.12, FWD)
	untilLanded(w)
	worldStep(w)
	expect(w.s.state == "Downed", "face down")
	local sp = TechCore.flatSpeed(w.s)
	worldRun(w, 0.2)
	expect(near(TechCore.flatSpeed(w.s), sp - Config.DIVE_SLIDE_FRICTION * 0.2, 1.5), "belly slide friction")
	worldRun(w, Config.LAYOUT_DOWN_TIME + Config.GETUP_TIME)
	expect(w.s.state ~= "Downed" and w.s.state ~= "Recovering", "up again")

	local roll = newWorld(Config.RUN_TOP_SPEED)
	jumpThen(roll, 0.12, FWD)
	worldUntil(roll, function(x)
		return x.s.vel.Y < 0 and x.y < 0.3
	end, 3)
	tap(roll, "Jump") -- a hair before the touchdown: buffered into the roll
	untilLanded(roll)
	worldStep(roll)
	local e = events(roll.s, "TechRoll")
	expect(#e == 1 and e[1].quality == "Perfect", "Perfect tech roll")
	expect(roll.s.state == "Recovering", "rolling")
	worldRun(roll, Config.TECH_ROLL_RECOVER + 0.02)
	expect(roll.s.state ~= "Recovering" and roll.s.state ~= "Downed", "running again fast")

	local late = newWorld(Config.RUN_TOP_SPEED)
	jumpThen(late, 0.12, FWD)
	untilLanded(late)
	worldRun(late, 0.2)
	tap(late, "Jump")
	worldStep(late)
	expect(#events(late.s, "Scramble") == 1, "a late press scrambles")
	worldRun(late, Config.SCRAMBLE_DOWN + Config.GETUP_TIME + 0.02)
	expect(late.s.state ~= "Downed" and late.s.state ~= "Recovering", "up sooner than a full down")
end)

test("plant rules: timed from the let-go, never during the cooldown, never stale", function()
	-- a let-go during the cut cooldown is a stop, not a late-starting plant
	local w = newWorld(Config.RUN_TOP_SPEED)
	letGoThen(w, 0.08, RIGHT)
	worldRun(w, 0.1) -- inside CUT_COOLDOWN
	letGoThen(w, Config.CUT_COOLDOWN, FWD) -- let go through the end of the cooldown
	expect(#events(w.s, "Cut") == 1, "no second cut from a let-go that began in the cooldown")
	-- the stick pushed again in the air ends the plant: a later let-go plants afresh
	local a = newWorld(Config.RUN_TOP_SPEED)
	a.move = Vector3.zero
	worldRun(a, 0.03)
	tap(a, "Jump")
	a.move = FWD
	worldUntil(a, function(x)
		return not x.s.grounded
	end, 0.1)
	untilLanded(a)
	worldRun(a, 0.3)
	local cuts = #events(a.s, "Cut")
	letGoThen(a, 0.08, RIGHT)
	expect(#events(a.s, "Cut") == cuts + 1, "a fresh plant after landing cuts")
	-- one mistake, one skid
	local k = newWorld(Config.BURST_TOP_SPEED)
	k.move = -FWD
	worldRun(k, Config.SKID_MAX_TIME + 0.1)
	expect(#events(k.s, "Skid") == 1, "no chain of skids: " .. #events(k.s, "Skid"))
	-- hopping out of a skid earns nothing
	local h = newWorld(Config.RUN_TOP_SPEED)
	h.move = -FWD
	worldRun(h, 0.2)
	local before = TechCore.flatSpeed(h.s)
	tap(h, "Jump")
	worldStep(h)
	expect(not h.s.grounded and TechCore.flatSpeed(h.s) <= before + 0.01, "no hop bonus from a skid")
end)

test(
	"air action rules: not with the disc; a standing dive still travels; a roll never adds speed to a holder",
	function()
		local w = newWorld(Config.RUN_TOP_SPEED)
		tap(w, "Jump")
		worldRun(w, 0.12)
		TechCore.setHolding(w.s, true) -- caught it in the air
		tap(w, "Jump")
		worldStep(w)
		expect(#events(w.s, "Layout") == 0 and #events(w.s, "SkyReach") == 0, "no air action with the disc")

		local st = newWorld(0)
		st.move = Vector3.zero
		tap(st, "Jump")
		worldRun(st, 0.12)
		st.move = RIGHT
		tap(st, "Jump")
		worldStep(st)
		expect(
			near(TechCore.flatSpeed(st.s), Config.DIVE_MIN_SPEED, 0.5),
			"standing dive: " .. TechCore.flatSpeed(st.s)
		)

		local c = newWorld(Config.RUN_TOP_SPEED)
		jumpThen(c, 0.12, FWD)
		TechCore.setHolding(c.s, true) -- a layout catch
		worldUntil(c, function(x)
			return x.s.vel.Y < 0 and x.y < 0.3
		end, 3)
		tap(c, "Jump")
		untilLanded(c)
		local landing = TechCore.flatSpeed(c.s)
		worldStep(c)
		expect(#events(c.s, "TechRoll") == 1, "rolls up with the disc")
		expect(TechCore.flatSpeed(c.s) <= landing + 0.01, "but the roll adds no speed")
	end
)

test("cuts read the same at 30, 60 and 144 fps", function()
	-- the client feeds whole frames (TechCore.advance); a let-go of ~83 ms
	-- must be a Perfect cut at any frame rate
	for _, fps in { 30, 60, 144 } do
		local s = moving(Config.RUN_TOP_SPEED)
		local dt = 1 / fps
		local function frames(n: number, move: Vector3)
			for _ = 1, n do
				TechCore.advance(s, { move = move }, GROUND, dt)
			end
		end
		frames(math.floor(fps * 0.3), FWD)
		frames(math.max(1, math.floor(0.083 * fps + 0.5)), Vector3.zero)
		frames(2, RIGHT)
		local cuts = events(s, "Cut")
		expect(#cuts == 1 and cuts[1].quality == "Perfect", "Perfect cut at " .. fps .. " fps")
	end
end)

test("sky reach: Space again with no direction hangs with the hands up", function()
	local w = newWorld(0)
	jumpThen(w, 0.18, Vector3.zero)
	expect(#events(w.s, "SkyReach") == 1, "sky reach")
	expect(TechCore.reachBonus(w.s) == Config.SKY_REACH, "more reach")
	local y0 = w.y
	worldRun(w, Config.SKY_REACH_HANG - 0.02)
	expect(math.abs(w.y - y0) < 0.05, "hangs")
	tap(w, "Jump")
	w.move = FWD
	worldStep(w)
	expect(#events(w.s, "Layout") == 0, "it was the air action: no dive after it")
end)

test("disc reset: touching the disc in the air gives the air action back once", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	jumpThen(w, 0.1, Vector3.zero)
	expect(not w.s.dodgeAvailable, "spent")
	expect(TechCore.discContact(w.s), "reset")
	expect(w.s.dodgeAvailable, "back")
	expect(not TechCore.discContact(w.s), "once per airtime")
end)

test("wavedash: a dive just before landing lands in a fast slide instead", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	tap(w, "Jump")
	worldStep(w)
	worldUntil(w, function(x)
		return x.s.vel.Y < 0 and x.y < 0.6
	end, 2)
	w.move = RIGHT
	tap(w, "Jump")
	untilLanded(w)
	worldStep(w)
	local e = events(w.s, "Wavedash")
	expect(#e == 1 and #events(w.s, "Layout") == 0, "wavedash, no layout")
	expect(w.s.state == "Sliding" and w.s.wave, "a fast slide")
	expect(Vector3.new(w.s.vel.X, 0, w.s.vel.Z).Unit:Dot(RIGHT) > 0.99, "toward the stick")
	local sideKeep = 1 + (Config.WAVEDASH_TURN_KEEP - 1) * 0.5
	expect(
		near(TechCore.flatSpeed(w.s), Config.RUN_TOP_SPEED * sideKeep + Config.WAVEDASH_BURST_PERFECT, 3.5),
		"a sideways wavedash keeps part of the speed + the boost: " .. TechCore.flatSpeed(w.s)
	)
	local f = newWorld(Config.RUN_TOP_SPEED)
	tap(f, "Jump")
	worldStep(f)
	worldUntil(f, function(x)
		return x.s.vel.Y < 0 and x.y < 0.6
	end, 2)
	tap(f, "Jump")
	untilLanded(f)
	worldStep(f)
	expect(TechCore.flatSpeed(f.s) > Config.RUN_TOP_SPEED + Config.WAVEDASH_BURST - 2, "straight ahead it is faster")
	expect(w.s.dodgeAvailable, "air action ready again")
	worldRun(w, Config.WAVE_SLIDE_TIME + 0.05)
	expect(w.s.state ~= "Sliding", "runs out of it")
	-- and a hop out of it chains
	local h = newWorld(Config.RUN_TOP_SPEED)
	tap(h, "Jump")
	worldStep(h)
	worldUntil(h, function(x)
		return x.s.vel.Y < 0 and x.y < 0.6
	end, 2)
	h.move = RIGHT
	tap(h, "Jump")
	untilLanded(h)
	worldRun(h, 0.2)
	tap(h, "Jump")
	worldStep(h)
	expect(#events(h.s, "SlideHop") == 1 and not h.s.grounded, "slide hop out of the wavedash")
end)

test("abilities: The Zone widens Perfect windows, Sky Walk adds air actions, Overdrive never drains", function()
	-- a cut 120 ms after the crossing is Clean, but Perfect in The Zone
	local function cutAfter(zone: boolean): string
		local w = newWorld(Config.RUN_TOP_SPEED)
		if zone then
			TechCore.startAbility(w.s, "Zone", 5, 2)
		end
		letGoThen(w, 0.15, RIGHT)
		local c = events(w.s, "Cut")
		return if c[1] then c[1].quality else "none"
	end
	expect(cutAfter(false) == "Clean", "late without the zone")
	expect(cutAfter(true) == "Perfect", "Perfect in the zone")

	local sky = newWorld(Config.RUN_TOP_SPEED)
	TechCore.startAbility(sky.s, "SkyWalk", 5, nil, 2)
	tap(sky, "Jump")
	worldRun(sky, 0.1)
	sky.move = Vector3.zero
	for _ = 1, 4 do
		tap(sky, "Jump")
		worldRun(sky, 0.15)
	end
	expect(#events(sky.s, "SkyReach") == 3, "one air action + two extra, got " .. #events(sky.s, "SkyReach"))

	local od = newWorld(Config.RUN_TOP_SPEED)
	TechCore.startAbility(od.s, "Overdrive", 4)
	od.held.Burst = true
	worldRun(od, 2)
	expect(od.s.burst == 100 and TechCore.flatSpeed(od.s) > Config.RUN_TOP_SPEED + 5, "full burst, faster")
	worldRun(od, 2.5)
	expect(od.s.burst < 100, "drains again after it ends")
end)

test("abilities: Sky Walk floats, Overdrive adds top speed, Flash Step surges", function()
	local function apex(gravity: number?): number
		local w = newWorld(0)
		if gravity then
			TechCore.startAbility(w.s, "SkyWalk", 5, gravity, 3)
		end
		tap(w, "Jump")
		local top = 0
		for _ = 1, 120 do
			worldRun(w, 1 / 120)
			top = math.max(top, w.y)
		end
		return top
	end
	expect(apex(0.75) > apex(nil) + 0.5, "a floatier jump in Sky Walk")

	local function topWith(extra: number): number
		local w = newWorld(Config.RUN_TOP_SPEED)
		TechCore.startAbility(w.s, "Overdrive", 5, extra)
		w.held.Burst = true
		worldRun(w, 2)
		return TechCore.flatSpeed(w.s)
	end
	expect(topWith(6) > topWith(0) + 4, "Overdrive's top-speed bonus")

	local f = newWorld(Config.RUN_TOP_SPEED)
	TechCore.surge(f.s, 8)
	expect(near(TechCore.flatSpeed(f.s), Config.RUN_TOP_SPEED + 8, 0.01), "the surge")
end)

test("mirror step: an armed cut is Perfect + 2; biting on a juke costs 30 %", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	TechCore.armMirror(w.s)
	local before = TechCore.flatSpeed(w.s)
	letGoThen(w, 0.18, RIGHT) -- late: a plain cut would be Clean
	local c = events(w.s, "Cut")[1]
	expect(c and c.quality == "Perfect" and c.info == "Mirror", "mirrored cut")
	expect(TechCore.flatSpeed(w.s) > before + Config.PERFECT_CUT_BONUS + Config.MIRROR_BONUS - 0.5, "+3 +2")
	local sp = TechCore.flatSpeed(w.s)
	TechCore.juked(w.s)
	expect(near(TechCore.flatSpeed(w.s), sp * (1 - Config.JUKED_LOSS), 0.01), "juked")
end)

test("flip reset: feet on the disc store an air action, kept until landing", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.held.Jump = true
	jumpThen(w, 0.15, Vector3.zero) -- the normal air action is spent
	expect(not w.s.dodgeAvailable, "spent")
	expect(TechCore.footContact(w.s), "flip reset")
	expect(not TechCore.footContact(w.s), "one in store at a time")
	worldRun(w, 0.1)
	w.move = FWD
	tap(w, "Jump")
	worldStep(w)
	expect(#events(w.s, "ResetFlip") == 1 and #events(w.s, "Layout") == 1, "spent the stored flip on a dive")
	untilLanded(w)
	worldStep(w)
	expect(w.s.storedFlips == 0, "landing clears the store")
end)

test("wall kick: jump right after touching a wall kicks off it with the dodge back", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	jumpThen(w, 0.1, Vector3.zero)
	worldRun(w, 0.15) -- the air action is spent
	w.move = RIGHT
	local wall = -FWD.Unit -- wall ahead, normal facing back at us
	local function wallStep()
		local s = w.s
		TechCore.step(s, { move = w.move, held = w.held }, { grounded = false, wallNormal = wall }, TechCore.STEP)
		w.y = math.max(0, w.y + s.vel.Y * TechCore.STEP)
	end
	wallStep()
	tap(w, "Jump")
	wallStep()
	local e = events(w.s, "WallKick")
	expect(#e == 1 and e[1].quality == "Perfect", "wall kick")
	expect(w.s.vel:Dot(-FWD) > 0 and w.s.vel.Y > 20, "kicked back and up")
	expect(w.s.dodgeAvailable, "air action back")
end)

test("pinch: a throw within 40 ms of touchdown", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	expect(TechCore.pinch(w.s, nil) == nil, "standing for ages: no pinch")
	tap(w, "Jump")
	worldStep(w)
	expect(TechCore.pinch(w.s, 0.5) == nil, "high in the air: no pinch")
	expect(TechCore.pinch(w.s, 0.01) == "Perfect", "10 ms before landing")
	worldUntil(w, function(x)
		return x.s.grounded
	end, 2)
	worldRun(w, 0.02)
	expect(TechCore.pinch(w.s, nil) == "Clean", "~30 ms after")
end)

test("mark shuffle: instant turns, capped at MARK_SPEED", function()
	local w = newWorld(0)
	TechCore.setMarking(w.s, true)
	expect(w.s.state == "Marking", "marking")
	w.move = RIGHT
	worldRun(w, 0.3)
	expect(near(TechCore.flatSpeed(w.s), Config.MARK_SPEED, 0.01), "shuffle speed")
	w.move = -RIGHT
	worldStep(w)
	expect(w.s.vel.Unit:Dot(-RIGHT) > 0.99 and not w.s.drifting, "turns on the spot")
end)

test("tech fuzz: random presses and holds never break the cap or the states", function()
	local Rng = H.require("Util/Rng")
	local rng = Rng.new(11)
	local w = newWorld(0)
	for i = 1, 40000 do
		if Rng.next(rng) < 0.03 then
			tap(w, "Jump")
		end
		if i % 37 == 0 then
			for _, a in { "Burst", "Jump" } do
				w.held[a] = Rng.next(rng) < 0.4
			end
			local a = Rng.next(rng) * math.pi * 2
			w.move = Vector3.new(math.cos(a), 0, math.sin(a)) * (if Rng.next(rng) < 0.2 then 0 else 1)
			w.aim = Vector3.new(math.cos(a + 0.4), 0, math.sin(a + 0.4))
		end
		if i % 1500 == 0 then
			TechCore.discContact(w.s)
		end
		if i % 1700 == 0 then
			TechCore.footContact(w.s)
		end
		worldStep(w)
		local v = w.s.vel
		expect(v.X == v.X and v.Y == v.Y and v.Z == v.Z, "NaN at " .. i)
		expect(TechCore.flatSpeed(w.s) <= Config.HARD_SPEED_CAP + 1e-3, "over the cap at " .. i)
		expect(TechCore.Transitions[w.s.state] ~= nil, "bad state at " .. i)
		expect(w.s.burst >= 0 and w.s.burst <= 100, "meter out of range at " .. i)
		if #w.s.events > 50 then
			TechCore.drainEvents(w.s)
		end
	end
end)

return nil
