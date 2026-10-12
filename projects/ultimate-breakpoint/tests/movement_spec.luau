local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local MovementSim = H.require("Movement/MovementSim")
local Config = H.require("Config/Movement")
local VecMath = H.require("Util/VecMath")
local Rng = H.require("Util/Rng")

local test, expect, near = H.test, H.expect, H.near

local DT = 1 / 60
local G = 160

-- A tiny stand-in for Roblox physics: perfect horizontal tracking of the sim's
-- requested velocity plus a vertical body under gravity with a flat floor.
local function newBody()
	return { y = 0, vy = 0, pos = Vector3.zero }
end

local function envFor(body, s)
	local grounded = body.y <= 0.001 and body.vy <= 0.001
	local ttl = nil
	if not grounded then
		local disc = body.vy * body.vy + 2 * G * body.y
		ttl = (body.vy + math.sqrt(math.max(disc, 0))) / G
	end
	return {
		grounded = grounded,
		actualVel = Vector3.new(s.vel.X, body.vy, s.vel.Z),
		timeToLand = ttl,
		facing = Vector3.new(0, 0, -1),
	}
end

local function physics(body, out, dt)
	if out.setVertical then
		body.vy = out.setVertical
	end
	body.vy -= G * dt
	body.y += body.vy * dt
	if body.y <= 0 then
		body.y = 0
		if body.vy < 0 then
			body.vy = 0
		end
	end
	body.pos += out.vel * dt
end

local function run(s, body, input, seconds, onStep)
	local steps = math.floor(seconds / DT + 0.5)
	local events = {}
	for _ = 1, steps do
		local out = MovementSim.step(s, input, envFor(body, s), DT)
		physics(body, out, DT)
		for _, e in out.events do
			table.insert(events, e)
		end
		if onStep then
			onStep(out)
		end
	end
	return events
end

local function press(s, body, action, input)
	return MovementSim.press(s, action, input, envFor(body, s))
end

local FWD = Vector3.new(0, 0, -1)
local RIGHT = Vector3.new(1, 0, 0)
local BACK = Vector3.new(0, 0, 1)

print("movement")

test("accelerates from rest to sprint in about half a second", function()
	local s, body = MovementSim.new(), newBody()
	local t = 0
	run(s, body, { move = FWD, sprint = true }, 2, function()
		if s.vel.Magnitude < Config.SprintSpeed * 0.95 then
			t += DT
		end
	end)
	expect(t > 0.3 and t < 0.65, "time to 95% sprint = " .. t)
	near(s.vel.Magnitude, Config.SprintSpeed, 0.01, "top speed")
end)

test("sprinting turns are wide (turn radius ~ v^2 / lateral accel)", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	local yaw0 = VecMath.yaw(s.vel)
	run(s, body, { move = RIGHT, sprint = true }, 0.1)
	local turned = math.deg(math.abs(VecMath.yaw(s.vel) - yaw0))
	local expected = math.deg(Config.LateralAccel / Config.SprintSpeed * 0.1)
	expect(
		turned < expected * 1.6 and turned > expected * 0.5,
		string.format("turned %.1f deg in 0.1 s (model %.1f)", turned, expected)
	)
end)

test("a plain reversal is slow; Momentum Cancel + Perfect restart is fast", function()
	local function reversal(useTech)
		local s, body = MovementSim.new(), newBody()
		run(s, body, { move = FWD, sprint = true }, 1.5)
		local t = 0
		if useTech then
			expect(press(s, body, "Cut", { move = BACK, sprint = true }), "cancel accepted")
			run(s, body, { move = BACK, sprint = true }, 0.15)
			t += 0.15
			expect(press(s, body, "Cut", { move = BACK, sprint = true }), "restart accepted")
		end
		while s.vel:Dot(BACK) < Config.SprintSpeed * 0.75 and t < 3 do
			run(s, body, { move = BACK, sprint = true }, DT)
			t += DT
		end
		return t
	end
	local plain = reversal(false)
	local tech = reversal(true)
	expect(plain > 0.5, "plain reversal " .. plain)
	expect(tech < 0.25, "tech reversal " .. tech)
end)

test("restart pressed too early is locked out (no mashing)", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	press(s, body, "Cut", { move = BACK, sprint = true })
	run(s, body, { move = BACK, sprint = true }, 0.03)
	expect(not press(s, body, "Cut", { move = BACK, sprint = true }), "too-early restart rejected")
	run(s, body, { move = BACK, sprint = true }, 0.09)
	expect(not press(s, body, "Cut", { move = BACK, sprint = true }), "still locked out")
end)

test("committed full-speed snap cut is Perfect and keeps most speed", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	press(s, body, "Cut", { move = RIGHT, sprint = true })
	local events = run(s, body, { move = RIGHT, sprint = true }, DT)
	expect(#events == 1 and events[1].tech == "SnapCut", "snap cut emitted")
	expect(events[1].quality == "Perfect", "quality " .. events[1].quality)
	expect(s.vel:Dot(RIGHT) > Config.SprintSpeed * 0.8, "redirected speed " .. s.vel:Dot(RIGHT))
end)

test("zig-zag spam degrades to Sloppy and bleeds speed", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	local dirs = { (FWD + RIGHT).Unit, (FWD - RIGHT).Unit }
	local qualities = {}
	for i = 1, 6 do
		local d = dirs[(i % 2) + 1]
		press(s, body, "Cut", { move = d, sprint = true })
		for _, e in run(s, body, { move = d, sprint = true }, 0.25) do
			if e.tech == "SnapCut" then
				table.insert(qualities, e.quality)
			end
		end
	end
	local sloppy = 0
	for _, q in qualities do
		if q == "Sloppy" or q == "Gassed" then
			sloppy += 1
		end
	end
	expect(sloppy >= 3, "spammed cuts were not penalised: " .. table.concat(qualities, ","))
end)

test("fake commit sells, then the cut away is Perfect (Sold)", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.0)
	expect(press(s, body, "Cut", { move = FWD, sprint = true }), "jab accepted")
	run(s, body, { move = FWD, sprint = true }, 0.18)
	press(s, body, "Cut", { move = RIGHT, sprint = true })
	local events = run(s, body, { move = RIGHT, sprint = true }, DT)
	expect(events[1] and events[1].tech == "SnapCut" and events[1].info == "Sold", "sold cut")
	expect(events[1].quality == "Perfect", "quality " .. tostring(events[1].quality))
end)

test("burst step has a cooldown and respects its speed ceiling", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	expect(press(s, body, "Burst", { move = FWD, sprint = true }), "burst accepted")
	run(s, body, { move = FWD, sprint = true }, DT)
	expect(s.vel.Magnitude <= Config.BurstStep.MaxSpeed + 1e-3, "burst speed " .. s.vel.Magnitude)
	expect(not press(s, body, "Burst", { move = FWD, sprint = true }), "burst on cooldown")
	run(s, body, { move = FWD, sprint = true }, 1.0)
	expect(s.vel.Magnitude < Config.SprintSpeed + 1, "overspeed decays back toward sprint")
end)

test("precision landing: perfect timing keeps speed; early press locks out", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	press(s, body, "Jump", { move = FWD, sprint = true })
	local pressed = false
	local events = {}
	for _ = 1, 120 do
		local env = envFor(body, s)
		if not pressed and env.timeToLand and env.timeToLand <= 0.04 and not env.grounded then
			pressed = MovementSim.press(s, "Slide", { move = FWD, sprint = true }, env)
		end
		local out = MovementSim.step(s, { move = FWD, sprint = true }, envFor(body, s), DT)
		physics(body, out, DT)
		for _, e in out.events do
			table.insert(events, e)
		end
	end
	local pl
	for _, e in events do
		if e.tech == "PrecisionLanding" then
			pl = e
		end
	end
	expect(pl ~= nil and pl.quality == "Perfect", "perfect precision landing")

	local s2, body2 = MovementSim.new(), newBody()
	run(s2, body2, { move = FWD, sprint = true }, 1.5)
	press(s2, body2, "Jump", { move = FWD, sprint = true })
	run(s2, body2, { move = FWD, sprint = true }, 0.1)
	expect(not press(s2, body2, "Slide", { move = FWD, sprint = true }), "far-too-early press rejected")
	expect(s2.precisionLockUntil > s2.now, "lockout armed")
end)

test("dive -> slide -> recovery pop window -> Recovery Chain", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	expect(press(s, body, "Dive", { move = FWD, sprint = true }), "dive accepted")
	local sawSlide, sawRecover = false, false
	for _ = 1, 240 do
		run(s, body, { move = FWD, sprint = true }, DT)
		if s.mode == "DiveSlide" then
			sawSlide = true
		end
		if s.mode == "Recover" then
			sawRecover = true
			break
		end
	end
	expect(sawSlide and sawRecover, "went through DiveSlide into Recover")
	expect(press(s, body, "Cut", { move = RIGHT, sprint = true }), "pop accepted")
	local events = run(s, body, { move = RIGHT, sprint = true }, DT)
	expect(events[1] and events[1].tech == "RecoveryChain" and events[1].quality == "Perfect", "perfect pop")
	expect(s.mode == "Ground", "back on feet")
end)

test("air redirect: one per airtime, limited angle", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	press(s, body, "Jump", { move = FWD, sprint = true })
	run(s, body, { move = FWD, sprint = true }, 0.1)
	expect(press(s, body, "Cut", { move = BACK, sprint = true }), "redirect accepted")
	run(s, body, { move = BACK, sprint = true }, DT)
	local angle = VecMath.flatAngle(FWD, s.vel)
	expect(angle <= Config.AirRedirect.MaxAngle + 1, "redirect angle " .. angle)
	expect(not press(s, body, "Cut", { move = RIGHT, sprint = true }), "second redirect rejected")
end)

test("holding the disc: decelerate, then pivot within radius", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	MovementSim.setHolding(s, true, true)
	local established = false
	local pivot
	for _ = 1, 120 do
		local env = envFor(body, s)
		if pivot then
			env.pivotOffset = body.pos - pivot
		end
		local out = MovementSim.step(s, { move = FWD, sprint = true }, env, DT)
		physics(body, out, DT)
		if out.pivotEstablished then
			established = true
			pivot = body.pos
		end
	end
	expect(established, "pivot established")
	expect(
		(body.pos - pivot).Magnitude <= Config.Holding.PivotRadius + 0.3,
		"stayed inside pivot radius: " .. (body.pos - pivot).Magnitude
	)
	expect(not press(s, body, "Burst", { move = FWD, sprint = true }), "no techniques while holding")
end)

test("slide hop chains cannot build speed beyond the slide ceiling", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	local maxSpeed = 0
	for _ = 1, 40 do
		press(s, body, "Slide", { move = FWD, sprint = true })
		run(s, body, { move = FWD, sprint = true }, 0.1)
		press(s, body, "Jump", { move = FWD, sprint = true })
		for _ = 1, 90 do
			local env = envFor(body, s)
			if env.timeToLand and env.timeToLand < 0.04 then
				MovementSim.press(s, "Slide", { move = FWD, sprint = true }, env)
			end
			local out = MovementSim.step(s, { move = FWD, sprint = true }, envFor(body, s), DT)
			physics(body, out, DT)
			maxSpeed = math.max(maxSpeed, s.vel.Magnitude)
			if s.mode == "Ground" then
				break
			end
		end
	end
	expect(maxSpeed <= Config.Slide.BoostCeiling + 0.01, "slide-hop max speed " .. maxSpeed)
end)

test("fuzz: no input sequence breaks the hard speed cap or produces NaN", function()
	local rng = Rng.new(1234)
	local actions = { "Jump", "Cut", "Slide", "Dive", "Burst" }
	local worst = 0
	for trial = 1, 40 do
		local s, body = MovementSim.new(), newBody()
		local walls = trial % 2 == 0
		for _ = 1, 3000 do
			local yaw = rng:range(-math.pi, math.pi)
			local mag = if rng:next() < 0.15 then 0 else rng:range(0.2, 1)
			local input = { move = VecMath.fromYaw(yaw) * mag, sprint = rng:next() < 0.7 }
			local env = envFor(body, s)
			if walls and not env.grounded and rng:next() < 0.3 then
				env.wallNormal = VecMath.fromYaw(rng:range(-math.pi, math.pi))
				env.wallDistance = rng:range(0.2, 3)
				env.wallId = "w" .. rng:int(1, 4)
			end
			if rng:next() < 0.25 then
				MovementSim.press(s, actions[rng:int(1, #actions)], input, env)
			end
			if rng:next() < 0.002 then
				MovementSim.setHolding(s, not s.holding, env.grounded)
			end
			local out = MovementSim.step(s, input, env, DT * rng:range(0.5, 2))
			physics(body, out, DT)
			local sp = out.vel.Magnitude
			expect(sp == sp, "NaN velocity")
			worst = math.max(worst, sp)
			expect(s.exertion >= 0 and s.exertion <= Config.ExertionMax, "exertion out of range")
			if out.setVertical then
				expect(out.setVertical <= 60, "vertical impulse too large: " .. out.setVertical)
			end
		end
	end
	expect(worst <= Config.HardCap + 1e-4, "hard cap exceeded: " .. worst)
	print(string.format("       (fuzz max horizontal speed %.2f / cap %d)", worst, Config.HardCap))
end)

return nil
