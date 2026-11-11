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

test("friction: no input stops you at GROUND_FRICTION", function()
	local s = moving(Config.RUN_TOP_SPEED)
	local t = timeUntil(s, Vector3.zero, GROUND, function(st)
		return TechCore.flatSpeed(st) <= 1e-6
	end, 2)
	local ideal = Config.RUN_TOP_SPEED / Config.GROUND_FRICTION
	expect(t ~= nil and near(t, ideal, 0.02), string.format("stopped in %s s, want %.3f", tostring(t), ideal))
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
	worldRun(w, 1)
	expect(w.s.burstLocked, "still locked under 20")
	worldRun(w, 0.5)
	expect(not w.s.burstLocked and near(w.s.burst, Config.BURST_REFILL * 1.5, 1), "unlocked: " .. w.s.burst)
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

test("cut: Perfect keeps 100 % + 3, a late one keeps 70 %", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.move = RIGHT
	worldStep(w) -- the stick crosses 45° here
	tap(w, "Cut")
	worldRun(w, Config.CUT_PLANT_TIME + 0.02)
	local cuts = events(w.s, "Cut")
	expect(#cuts == 1 and cuts[1].quality == "Perfect", "a Perfect cut")
	expect(w.s.vel.Unit:Dot(RIGHT) > 0.99, "goes the new way")
	expect(
		near(TechCore.flatSpeed(w.s), Config.RUN_TOP_SPEED + Config.PERFECT_CUT_BONUS, 0.6),
		"keeps it all + 3: " .. TechCore.flatSpeed(w.s)
	)

	local late = newWorld(Config.RUN_TOP_SPEED)
	late.move = RIGHT
	worldRun(late, 0.12) -- the stick turned 120 ms before the press
	tap(late, "Cut")
	local before = TechCore.flatSpeed(late.s)
	worldRun(late, Config.CUT_PLANT_TIME + 0.01)
	local c = events(late.s, "Cut")
	expect(#c == 1 and c[1].quality == "Clean", "a late cut is a normal one")
	expect(near(TechCore.flatSpeed(late.s), before * Config.CUT_KEEP, 1), "keeps 70 %")
	expect(late.s.lastTiming and late.s.lastTiming.offsetMs > Config.CUT_PERFECT_WINDOW, "timing says late")
end)

test("cut: an early press is buffered to the crossing; repeats are capped", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	tap(w, "Cut") -- before the stick moves
	worldRun(w, 0.05)
	w.move = RIGHT
	worldRun(w, Config.CUT_PLANT_TIME + 0.05)
	local cuts = events(w.s, "Cut")
	expect(#cuts == 1 and cuts[1].quality == "Perfect", "buffered press is Perfect")
	-- a second cut back inside 0.6 s keeps at most 85 %
	worldRun(w, Config.CUT_COOLDOWN)
	w.move = FWD
	worldStep(w)
	tap(w, "Cut")
	local before = TechCore.flatSpeed(w.s)
	worldUntil(w, function(x)
		return #events(x.s, "Cut") >= 2
	end, 0.3)
	expect(#events(w.s, "Cut") == 2, "second cut")
	expect(
		TechCore.flatSpeed(w.s) <= before * Config.CUT_REPEAT_CAP + Config.RUN_ACCEL * TechCore.STEP + 0.05,
		"capped at 85 %"
	)
end)

test("juke: the stick back to the line in the plant keeps it at 90 %", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.move = RIGHT
	worldStep(w)
	tap(w, "Cut")
	worldRun(w, 0.05)
	w.move = FWD
	local before = TechCore.flatSpeed(w.s)
	worldUntil(w, function(x)
		return #events(x.s, "Juke") > 0
	end, 0.3)
	expect(#events(w.s, "Juke") == 1 and #events(w.s, "Cut") == 0, "a juke, no cut")
	expect(near(before, Config.RUN_TOP_SPEED, 0.5), "the plant keeps the line")
	expect(w.s.vel.Unit:Dot(FWD) > 0.99, "same line")
	expect(near(TechCore.flatSpeed(w.s), before * Config.JUKE_KEEP, Config.RUN_ACCEL * TechCore.STEP + 0.05), "90 %")
end)

test("plant stop: stop in 0.15 s, then a 2x (Perfect 2.5x) start", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.move = Vector3.zero
	tap(w, "Cut")
	worldRun(w, Config.PLANT_STOP_TIME + 0.01)
	expect(TechCore.flatSpeed(w.s) < 0.5, "stopped dead")
	w.move = -FWD
	worldRun(w, 0.1)
	local e = events(w.s, "PlantStop")
	expect(#e == 1 and e[1].quality == "Perfect", "went at once: Perfect")
	expect(TechCore.flatSpeed(w.s) > Config.RUN_ACCEL * 0.1 * 2.2, "explosive: " .. TechCore.flatSpeed(w.s))
end)

test("slide: needs 18, holds speed, 60°/s turns, stands after 1.2 s", function()
	local slow = newWorld(15)
	slow.held.Slide = true
	tap(slow, "Slide")
	worldStep(slow)
	expect(slow.s.state ~= "Sliding", "too slow")
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.held.Slide = true
	tap(w, "Slide")
	worldStep(w)
	expect(w.s.state == "Sliding", "sliding")
	worldRun(w, 0.5)
	expect(near(TechCore.flatSpeed(w.s), Config.RUN_TOP_SPEED - Config.SLIDE_FRICTION * 0.5, 0.5), "low friction")
	w.move = RIGHT
	worldRun(w, 0.5)
	local turned = math.deg(math.acos(math.clamp(w.s.vel.Unit:Dot(FWD), -1, 1)))
	expect(near(turned, Config.SLIDE_TURN * 0.5, 2), "60°/s: " .. turned)
	worldRun(w, 0.3)
	expect(w.s.state ~= "Sliding", "stood up after 1.2 s")
end)

test("slide carve: Burst in a slide turns at 220°/s for more friction", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.held.Slide = true
	tap(w, "Slide")
	worldStep(w)
	w.held.Burst = true
	w.move = RIGHT
	worldRun(w, 0.3)
	local turned = math.deg(math.acos(math.clamp(w.s.vel.Unit:Dot(FWD), -1, 1)))
	expect(turned > 60, "tight turn: " .. turned)
	expect(w.s.burst < 100, "drains burst")
end)

test("jump: tap is 34 up, hold is 46; landing slide keeps the air speed", function()
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

	-- landing slide: Slide pressed right at touchdown
	local l = newWorld(Config.RUN_TOP_SPEED)
	tap(l, "Jump")
	worldStep(l)
	worldUntil(l, function(x)
		return x.s.grounded
	end, 2)
	l.held.Slide = true
	tap(l, "Slide")
	worldStep(l)
	local e = events(l.s, "LandingSlide")
	expect(#e == 1 and e[1].quality == "Perfect" and l.s.state == "Sliding", "Perfect landing slide")
end)

test("fast fall: Slide held in the air falls faster and lands in a Perfect slide", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	tap(w, "Jump")
	worldRun(w, 0.15)
	local up = newWorld(Config.RUN_TOP_SPEED)
	tap(up, "Jump")
	worldRun(up, 0.15)
	w.held.Slide = true
	worldRun(w, 0.1)
	worldRun(up, 0.1)
	expect(w.s.vel.Y < up.s.vel.Y - 3, "falls faster")
	worldUntil(w, function(x)
		return x.s.grounded
	end, 2)
	worldStep(w)
	local e = events(w.s, "LandingSlide")
	expect(#e == 1 and e[1].quality == "Perfect" and e[1].info == "Held", "held through the landing")
end)

test("slide hop: in the window +6, then +4, +2, 0", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	local gains = {}
	for i = 1, 4 do
		w.held.Slide = true
		if i == 1 then
			tap(w, "Slide")
			worldStep(w)
		end
		expect(w.s.state == "Sliding", "sliding before hop " .. i)
		worldRun(w, 0.2)
		local before = TechCore.flatSpeed(w.s)
		tap(w, "Jump")
		worldStep(w)
		table.insert(gains, TechCore.flatSpeed(w.s) - before)
		worldUntil(w, function(x)
			return x.s.grounded
		end, 2)
		worldStep(w) -- held Slide lands into the next slide
	end
	expect(
		gains[1] > 5 and gains[2] > 3 and gains[2] < 5 and gains[3] > 1 and gains[3] < 3 and gains[4] < 0.6,
		string.format("gains %.1f %.1f %.1f %.1f", gains[1], gains[2], gains[3], gains[4])
	)
end)

test("air dodge: +12 the held way with a hang; one per airtime; neutral goes up", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	tap(w, "Jump")
	worldRun(w, 0.2)
	w.move = RIGHT
	local flat0 = Vector3.new(w.s.vel.X, 0, w.s.vel.Z)
	tap(w, "Jump")
	worldStep(w)
	expect(w.s.state == "AirDodging" and w.s.vel.Y == 0, "dodging, hanging")
	local flat1 = Vector3.new(w.s.vel.X, 0, w.s.vel.Z)
	expect(near((flat1 - flat0):Dot(RIGHT), Config.AIR_DODGE_BURST, 1.5), "+12 sideways")
	worldRun(w, Config.AIR_DODGE_HANG)
	expect(w.s.state == "Airborne", "hang over")
	tap(w, "Jump")
	worldStep(w)
	expect(#events(w.s, "AirDodge") == 1, "only one")

	local n = newWorld(0)
	n.move = Vector3.zero
	tap(n, "Jump")
	n.held.Jump = false
	worldRun(n, 0.02)
	worldRun(n, 0.1)
	local vy = n.s.vel.Y
	tap(n, "Jump")
	worldStep(n)
	expect(n.s.vel.Y > vy + Config.AIR_DODGE_NEUTRAL * 0.8, "neutral dodge goes up")
end)

test("disc reset: touching the disc in the air gives the dodge back once", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	tap(w, "Jump")
	worldRun(w, 0.1)
	w.move = RIGHT
	tap(w, "Jump")
	worldStep(w)
	expect(not w.s.dodgeAvailable, "spent")
	expect(TechCore.discContact(w.s), "reset")
	expect(w.s.dodgeAvailable, "dodge back")
	expect(not TechCore.discContact(w.s), "once per airtime")
end)

test("wavedash: a dodge just before landing is a ground burst", function()
	local w = newWorld(8)
	tap(w, "Jump")
	worldStep(w)
	worldUntil(w, function(x)
		return x.s.vel.Y < 0 and x.y < 0.6
	end, 2)
	w.move = RIGHT
	local before = Vector3.new(w.s.vel.X, 0, w.s.vel.Z)
	tap(w, "Jump")
	worldUntil(w, function(x)
		return x.s.grounded
	end, 1)
	worldStep(w)
	local e = events(w.s, "Wavedash")
	expect(#e == 1, "wavedash")
	local gained = (Vector3.new(w.s.vel.X, 0, w.s.vel.Z) - before):Dot(RIGHT)
	expect(gained > Config.WAVEDASH_BURST - 2, "ground burst: " .. gained)
	expect(w.s.dodgeAvailable, "dodge ready again")
end)

test("reverse snap: backward dodge + Cut in the window keeps the speed", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	tap(w, "Jump")
	worldRun(w, 0.1)
	w.move = -FWD
	tap(w, "Jump")
	worldStep(w)
	worldRun(w, 0.09)
	tap(w, "Cut")
	worldStep(w)
	local e = events(w.s, "ReverseSnap")
	expect(#e == 1 and e[1].quality == "Perfect", "Perfect reverse snap")
	expect(w.s.vel.Unit:Dot(-FWD) > 0.9, "now going back")

	local miss = newWorld(Config.RUN_TOP_SPEED)
	tap(miss, "Jump")
	worldRun(miss, 0.1)
	miss.move = -FWD
	tap(miss, "Jump")
	worldStep(miss)
	worldRun(miss, 0.25)
	tap(miss, "Cut")
	worldUntil(miss, function(x)
		return x.s.grounded
	end, 2)
	worldStep(miss)
	expect(#events(miss.s, "Stumble") == 1, "late: stumble on landing")
end)

test("burst dive: standstill jump, diagonal dodge, Cut: run at 28-32", function()
	local w = newWorld(0)
	w.move = Vector3.zero
	w.aim = FWD
	w.held.Jump = true
	tap(w, "Jump")
	worldRun(w, 0.03)
	w.held.Jump = false
	worldStep(w) -- (the jump fired on the press)
	expect(not w.s.grounded, "jumped")
	w.move = (FWD + RIGHT).Unit
	tap(w, "Jump")
	worldStep(w)
	worldRun(w, 0.085)
	tap(w, "Cut")
	worldStep(w)
	local e = events(w.s, "BurstDive")
	expect(#e == 1 and e[1].quality == "Perfect", "Perfect burst dive")
	expect(near(TechCore.flatSpeed(w.s), Config.BURST_DIVE_SPEED_PERFECT, 1), "32: " .. TechCore.flatSpeed(w.s))
end)

test("layout: needs 15, +8 toward the aim, Downed 0.9 s; tech roll gets up fast", function()
	local slow = newWorld(10)
	tap(slow, "Dive")
	worldStep(slow)
	expect(slow.s.state ~= "Diving", "too slow")
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.aim = (FWD + RIGHT * 0.3).Unit
	tap(w, "Dive")
	worldStep(w)
	expect(
		w.s.state == "Diving" and near(TechCore.flatSpeed(w.s), Config.RUN_TOP_SPEED + Config.LAYOUT_BOOST, 0.5),
		"launch"
	)
	worldUntil(w, function(x)
		return x.s.grounded
	end, 2)
	worldStep(w)
	expect(w.s.state == "Downed", "downed")
	worldRun(w, Config.LAYOUT_DOWN_TIME - 0.05)
	expect(w.s.state == "Downed", "still down")

	local r = newWorld(Config.RUN_TOP_SPEED)
	tap(r, "Dive")
	worldStep(r)
	worldUntil(r, function(x)
		return x.s.grounded
	end, 2)
	worldStep(r)
	tap(r, "Jump")
	worldStep(r)
	local e = events(r.s, "TechRoll")
	expect(#e == 1 and e[1].quality == "Perfect", "Perfect tech roll")
	worldRun(r, Config.TECH_ROLL_RECOVER + 0.02)
	expect(r.s.state == "Grounded", "up in 0.25 s")
end)

test("air layout spends the dodge", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	tap(w, "Jump")
	worldRun(w, 0.1)
	tap(w, "Dive")
	worldStep(w)
	expect(w.s.state == "Diving" and not w.s.dodgeAvailable, "air layout")
end)

test("sky: crouch (hold Slide) while slow, then Jump, for a higher leap; Perfect at 0.35-0.40 s", function()
	local function peak(crouch: number): (number, any)
		local w = newWorld(0)
		w.move = Vector3.zero
		w.held.Slide = true
		worldRun(w, crouch)
		tap(w, "Jump")
		local top = 0
		worldStep(w)
		w.held.Slide = false
		worldUntil(w, function(x)
			top = math.max(top, x.y)
			return x.s.grounded
		end, 3)
		return top, events(w.s, "Sky")[1]
	end
	local plain = peak(0)
	local sky, e = peak(0.37)
	expect(e and e.quality == "Perfect", "Perfect sky")
	expect(sky > plain * 1.3, string.format("sky %.2f vs jump %.2f", sky, plain))
	-- no crouch: Jump fires on the press, even standing still
	local w = newWorld(0)
	w.move = Vector3.zero
	tap(w, "Jump")
	worldStep(w)
	expect(not w.s.grounded, "jumps at once")
end)

test("abilities: The Zone widens Perfect windows, Sky Walk adds dodges, Overdrive never drains", function()
	-- a cut 120 ms after the crossing is Clean, but Perfect in The Zone
	local function cutAfter(zone: boolean): string
		local w = newWorld(Config.RUN_TOP_SPEED)
		if zone then
			TechCore.startAbility(w.s, "Zone", 5, 2)
		end
		w.move = RIGHT
		worldRun(w, 0.12)
		tap(w, "Cut")
		worldRun(w, Config.CUT_PLANT_TIME + 0.02)
		local c = events(w.s, "Cut")
		return if c[1] then c[1].quality else "none"
	end
	expect(cutAfter(false) == "Clean", "late without the zone")
	expect(cutAfter(true) == "Perfect", "Perfect in the zone")

	local sky = newWorld(Config.RUN_TOP_SPEED)
	TechCore.startAbility(sky.s, "SkyWalk", 5, nil, 2)
	tap(sky, "Jump")
	worldRun(sky, 0.1)
	sky.move = RIGHT
	for _ = 1, 4 do
		tap(sky, "Jump")
		worldRun(sky, 0.2)
	end
	expect(#events(sky.s, "AirDodge") == 3, "one dodge + two extra, got " .. #events(sky.s, "AirDodge"))

	local od = newWorld(Config.RUN_TOP_SPEED)
	TechCore.startAbility(od.s, "Overdrive", 4)
	od.held.Burst = true
	worldRun(od, 2)
	expect(od.s.burst == 100 and TechCore.flatSpeed(od.s) > Config.RUN_TOP_SPEED + 5, "full burst, faster")
	worldRun(od, 2.5)
	expect(od.s.burst < 100, "drains again after it ends")
end)

test("mirror step: an armed cut is Perfect + 2; biting on a juke costs 30 %", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.move = RIGHT
	worldRun(w, 0.15) -- late: a plain cut would be Clean
	TechCore.armMirror(w.s)
	tap(w, "Cut")
	local before = TechCore.flatSpeed(w.s)
	worldUntil(w, function(x)
		return #events(x.s, "Cut") > 0
	end, 0.3)
	local c = events(w.s, "Cut")[1]
	expect(c and c.quality == "Perfect" and c.info == "Mirror", "mirrored cut")
	expect(TechCore.flatSpeed(w.s) > before + Config.PERFECT_CUT_BONUS + Config.MIRROR_BONUS - 0.5, "+3 +2")
	local sp = TechCore.flatSpeed(w.s)
	TechCore.juked(w.s)
	expect(near(TechCore.flatSpeed(w.s), sp * (1 - Config.JUKED_LOSS), 0.01), "juked")
end)

test("flip reset: feet on the disc store a dodge with no time limit, kept until landing", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	w.held.Jump = true
	tap(w, "Jump")
	worldRun(w, 0.15)
	w.move = RIGHT
	tap(w, "Jump")
	worldRun(w, 0.05) -- the normal dodge is spent
	expect(not w.s.dodgeAvailable, "spent")
	-- well past the 1.25 s window would be impossible to reach here, so
	-- check the store survives time instead: touch, wait, then dodge
	expect(TechCore.footContact(w.s), "flip reset")
	expect(not TechCore.footContact(w.s), "one in store at a time")
	worldRun(w, 0.1)
	tap(w, "Jump")
	worldStep(w)
	expect(#events(w.s, "ResetFlip") == 1 and #events(w.s, "AirDodge") == 2, "spent the stored flip")
	expect(TechCore.footContact(w.s), "a second reset in one airtime")
	worldUntil(w, function(x)
		return x.s.grounded
	end, 3)
	worldStep(w)
	expect(w.s.storedFlips == 0, "landing clears the store")
end)

test("stall: Dive within 30 ms of a dodge cancels it into a hang and gives it back", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	tap(w, "Jump")
	worldRun(w, 0.15)
	w.move = RIGHT
	local before = Vector3.new(w.s.vel.X, 0, w.s.vel.Z)
	tap(w, "Jump")
	worldStep(w)
	tap(w, "Dive")
	worldStep(w)
	local e = events(w.s, "Stall")
	expect(#e == 1, "stalled")
	expect(w.s.dodgeAvailable and w.s.state ~= "Diving", "dodge back, no layout")
	expect((Vector3.new(w.s.vel.X, 0, w.s.vel.Z) - before).Magnitude < 1, "the dodge's burst is cancelled")
	local y0 = w.y
	worldRun(w, 0.2)
	expect(math.abs(w.y - y0) < 0.05, "hangs")
	local late = newWorld(Config.RUN_TOP_SPEED)
	tap(late, "Jump")
	worldRun(late, 0.15)
	late.move = RIGHT
	tap(late, "Jump")
	worldRun(late, 0.06)
	tap(late, "Dive")
	worldStep(late)
	expect(#events(late.s, "Stall") == 0, "too late: no stall")
end)

test("zap dash: a Cut right out of a wavedash bursts again", function()
	local w = newWorld(8)
	tap(w, "Jump")
	worldStep(w)
	worldUntil(w, function(x)
		return x.s.vel.Y < 0 and x.y < 0.6
	end, 2)
	w.move = RIGHT
	tap(w, "Jump")
	worldUntil(w, function(x)
		return #events(x.s, "Wavedash") > 0
	end, 1)
	local before = TechCore.flatSpeed(w.s)
	tap(w, "Cut")
	worldStep(w)
	local e = events(w.s, "ZapDash")
	expect(#e == 1 and e[1].quality == "Perfect", "zap dash")
	expect(TechCore.flatSpeed(w.s) > before + Config.ZAP_BURST, "second burst")
end)

test("wall kick: jump right after touching a wall kicks off it with the dodge back", function()
	local w = newWorld(Config.RUN_TOP_SPEED)
	tap(w, "Jump")
	worldRun(w, 0.1)
	w.move = RIGHT
	tap(w, "Jump")
	worldRun(w, 0.2) -- dodge spent
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
	expect(w.s.dodgeAvailable, "dodge back")
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
	local actions = { "Cut", "Jump", "Dive", "Slide" }
	for i = 1, 40000 do
		if Rng.next(rng) < 0.03 then
			tap(w, actions[Rng.int(rng, 1, 4)])
		end
		if i % 37 == 0 then
			for _, a in { "Burst", "Slide", "Jump" } do
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
