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
	expect(near(TechCore.turnRate(12), 300, 1e-6), "300 at 12")
	expect(near(TechCore.turnRate(30), 180, 1e-6), "180 at 30")
	expect(near(TechCore.turnRate(50), 90, 1e-6), "90 at 50")
	expect(near(TechCore.turnRate(21), 240, 1e-6), "linear between")
	expect(near(TechCore.turnRate(60), 90, 1e-6), "flat past 50")
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
	expect(kept < 0.85 and kept > 0.6, string.format("kept %.2f of the speed through 90°", kept))

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

test("air keeps momentum and the stick does not steer (air steer is step 4)", function()
	local s = moving(Config.RUN_TOP_SPEED)
	run(s, RIGHT, AIR, 0.3)
	local flat = Vector3.new(s.vel.X, 0, s.vel.Z)
	expect(flat.Unit:Dot(FWD) > 0.999 and near(flat.Magnitude, Config.RUN_TOP_SPEED, 1e-6), "ballistic")
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

return nil
