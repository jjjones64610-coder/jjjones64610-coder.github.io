local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local MovementSim = H.require("Movement/MovementSim")
local Config = H.require("Config/Movement")
local VecMath = H.require("Util/VecMath")
local Rng = H.require("Util/Rng")

local test, expect, near = H.test, H.expect, H.near

local DT = 1 / 60
local G = 160
local HD = Config.Holding
local R = HD.StepRadius

-- A tiny stand-in for Roblox physics: perfect horizontal tracking of the sim's
-- requested velocity plus a vertical body under gravity with a flat floor.
-- (In the game the Humanoid is driven with WalkSpeed = |vel| and Move(vel.Unit),
-- which tracks the sim velocity almost exactly.)
local function newBody()
	return { y = 0, vy = 0, pos = Vector3.zero, aimYaw = 0 }
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
		facing = VecMath.fromYaw(body.aimYaw),
		pos = Vector3.new(body.pos.X, body.y, body.pos.Z),
		aimYaw = body.aimYaw,
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

local function frame(s, body, input, dt)
	local out = MovementSim.step(s, input, envFor(body, s), dt or DT)
	physics(body, out, dt or DT)
	return out
end

local function run(s, body, input, seconds, onStep)
	local steps = math.floor(seconds / DT + 0.5)
	local events = {}
	for _ = 1, steps do
		local out = frame(s, body, input)
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

local function find(events, tech)
	for _, e in events do
		if e.tech == tech then
			return e
		end
	end
	return nil
end

local FWD = Vector3.new(0, 0, -1)
local RIGHT = Vector3.new(1, 0, 0)
local LEFT = Vector3.new(-1, 0, 0)
local BACK = Vector3.new(0, 0, 1)
local NONE = Vector3.zero

local QUALITY_RANK = { Gassed = 0, Sloppy = 1, Clean = 2, Perfect = 3 }

local function sprintFwd()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 1.5)
	return s, body
end

print("movement")

---------------------------------------------------------------------------
-- locomotion
---------------------------------------------------------------------------

test("reaches 95% of sprint quickly (~0.32 s), not instantly", function()
	local s, body = MovementSim.new(), newBody()
	local t = 0
	run(s, body, { move = FWD, sprint = true }, 2, function()
		if s.vel.Magnitude < Config.SprintSpeed * 0.95 then
			t += DT
		end
	end)
	expect(t > 0.2 and t <= 0.38, "time to 95% sprint = " .. t)
	near(s.vel.Magnitude, Config.SprintSpeed, 0.01, "top speed")
end)

test("lets go of the keys and stops from sprint in ~0.3 s", function()
	local s, body = sprintFwd()
	local t = 0
	while s.vel.Magnitude > 0.5 and t < 2 do
		run(s, body, { move = NONE, sprint = false }, DT)
		t += DT
	end
	expect(t > 0.15 and t <= 0.32, "stop time = " .. t)
end)

test("jogging turns sharper than sprinting (speed-dependent lateral accel)", function()
	local function turned(sprint)
		local s, body = MovementSim.new(), newBody()
		run(s, body, { move = FWD, sprint = sprint }, 1.5)
		local yaw0 = VecMath.yaw(s.vel)
		run(s, body, { move = RIGHT, sprint = sprint }, 0.05)
		return math.deg(math.abs(VecMath.yaw(s.vel) - yaw0))
	end
	local jog, sprint = turned(false), turned(true)
	expect(jog > sprint * 1.3, string.format("jog turned %.1f, sprint %.1f deg in 0.05 s", jog, sprint))
	-- the sprint turn rate starts near LateralAccel / SprintSpeed
	local model = math.deg(Config.LateralAccel / Config.SprintSpeed * 0.05)
	expect(sprint > model * 0.8 and sprint < model * 2, string.format("sprint %.1f vs model %.1f", sprint, model))
end)

test("a plain reversal takes > 0.4 s; a Perfect plant-restart < 0.2 s", function()
	local function reversal(useTech)
		local s, body = sprintFwd()
		local t = 0
		if useTech then
			expect(press(s, body, "Cut", { move = BACK, sprint = true }), "plant accepted")
			run(s, body, { move = NONE, sprint = true }, 0.1)
			t += 0.1
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
	expect(plain > 0.4, "plain reversal " .. plain)
	expect(tech < 0.2, "tech reversal " .. tech)
end)

test("sprint is read from input only (AutoSprint lives in InputController)", function()
	local s, body = MovementSim.new(), newBody()
	local top = 0
	run(s, body, { move = FWD, sprint = false }, 3, function(out)
		top = math.max(top, out.vel.Magnitude)
	end)
	expect(top <= Config.JogSpeed + 1e-3, "jog top " .. top)
end)

test("landing keeps most speed and coyote time still allows a jump", function()
	local s, body = sprintFwd()
	press(s, body, "Jump", { move = FWD, sprint = true })
	local before = s.vel.Magnitude
	local landedSpeed
	for _ = 1, 120 do
		local out = frame(s, body, { move = FWD, sprint = true })
		if out.landed then
			landedSpeed = s.vel.Magnitude
			break
		end
	end
	expect(landedSpeed and landedSpeed >= before * 0.95, "landing speed " .. tostring(landedSpeed))

	-- run off a ledge: still on the ground for CoyoteTime
	local s2 = MovementSim.new()
	local env = { grounded = true, actualVel = Vector3.zero, facing = FWD }
	MovementSim.step(s2, { move = FWD, sprint = true }, env, DT)
	env.grounded = false
	MovementSim.step(s2, { move = FWD, sprint = true }, env, Config.CoyoteTime * 0.7)
	expect(s2.mode ~= "Air", "still grounded inside coyote time")
	expect(MovementSim.press(s2, "Jump", { move = FWD, sprint = true }, env), "coyote jump")
end)

test("collision reconciliation only trusts the body when env.blocked", function()
	local function stuck(blocked)
		local s, body = sprintFwd()
		for _ = 1, 20 do
			local env = envFor(body, s)
			env.actualVel = Vector3.zero -- the body is not moving at all
			env.blocked = blocked
			MovementSim.step(s, { move = FWD, sprint = true }, env, DT)
		end
		return s.vel.Magnitude
	end
	expect(stuck(nil) > Config.SprintSpeed - 1, "unblocked lag is ignored (Humanoid catches up)")
	expect(stuck(true) < Config.SprintSpeed * 0.5, "a real wall resets the sim velocity")
end)

test("impulse marks technique frames and velocity jumps only", function()
	local s, body = sprintFwd()
	local steady = frame(s, body, { move = FWD, sprint = true })
	expect(not steady.impulse, "steady running is not an impulse")
	press(s, body, "Cut", { move = RIGHT, sprint = true })
	expect(frame(s, body, { move = RIGHT, sprint = true }).impulse, "cut frame is an impulse")
	run(s, body, { move = RIGHT, sprint = true }, 0.5)
	press(s, body, "Jump", { move = RIGHT, sprint = true })
	local j = frame(s, body, { move = RIGHT, sprint = true })
	expect(j.impulse and j.jump, "jump frame is an impulse")
end)

---------------------------------------------------------------------------
-- the press contract
---------------------------------------------------------------------------

local REASONS = { Cooldown = true, Speed = true, Used = true, Context = true, Exertion = true }

test("every action in every mode fires or gives a reason (never a bare false)", function()
	local scenarios = {
		standing = function()
			return MovementSim.new(), newBody()
		end,
		jog = function()
			local s, b = MovementSim.new(), newBody()
			run(s, b, { move = FWD, sprint = false }, 1)
			return s, b
		end,
		sprint = sprintFwd,
		air = function()
			local s, b = sprintFwd()
			press(s, b, "Jump", { move = FWD, sprint = true })
			run(s, b, { move = FWD, sprint = true }, 0.1)
			return s, b
		end,
		airLow = function()
			local s, b = sprintFwd()
			press(s, b, "Jump", { move = FWD, sprint = true })
			for _ = 1, 120 do
				frame(s, b, { move = FWD, sprint = true })
				local ttl = envFor(b, s).timeToLand
				if s.mode == "Air" and ttl and ttl < 0.1 and b.vy < 0 then
					break
				end
			end
			return s, b
		end,
		slide = function()
			local s, b = sprintFwd()
			press(s, b, "Slide", { move = FWD, sprint = true })
			run(s, b, { move = FWD, sprint = true }, 0.1)
			return s, b
		end,
		dive = function()
			local s, b = sprintFwd()
			press(s, b, "Dive", { move = FWD, sprint = true })
			run(s, b, { move = FWD, sprint = true }, 0.05)
			return s, b
		end,
		diveSlide = function()
			local s, b = sprintFwd()
			press(s, b, "Dive", { move = FWD, sprint = true })
			for _ = 1, 120 do
				frame(s, b, { move = FWD, sprint = true })
				if s.mode == "DiveSlide" then
					break
				end
			end
			return s, b
		end,
		recover = function()
			local s, b = sprintFwd()
			press(s, b, "Dive", { move = FWD, sprint = true })
			for _ = 1, 200 do
				frame(s, b, { move = FWD, sprint = true })
				if s.mode == "Recover" then
					break
				end
			end
			return s, b
		end,
		plant = function()
			local s, b = sprintFwd()
			press(s, b, "Cut", { move = NONE, sprint = true })
			run(s, b, { move = NONE, sprint = true }, 0.02)
			return s, b
		end,
		cooldowns = function()
			local s, b = sprintFwd()
			press(s, b, "Burst", { move = FWD, sprint = true })
			run(s, b, { move = FWD, sprint = true }, 0.3)
			press(s, b, "Dive", { move = FWD, sprint = true })
			run(s, b, { move = FWD, sprint = true }, 1.2)
			return s, b
		end,
		holdingDecel = function()
			local s, b = sprintFwd()
			MovementSim.setHolding(s, true, true)
			run(s, b, { move = FWD, sprint = true }, 0.05)
			return s, b
		end,
		holdingPivot = function()
			local s, b = sprintFwd()
			MovementSim.setHolding(s, true, true)
			run(s, b, { move = NONE, sprint = false }, 0.8)
			return s, b
		end,
		holdingHop = function()
			local s, b = sprintFwd()
			MovementSim.setHolding(s, true, true)
			run(s, b, { move = NONE, sprint = false }, 0.8)
			press(s, b, "Jump", { move = NONE, sprint = false })
			run(s, b, { move = NONE, sprint = false }, 0.1)
			return s, b
		end,
		marking = function()
			local s, b = MovementSim.new(), newBody()
			MovementSim.setMarking(s, true)
			run(s, b, { move = RIGHT, sprint = true }, 0.5)
			return s, b
		end,
		frozen = function()
			local s, b = sprintFwd()
			MovementSim.setFrozen(s, true)
			return s, b
		end,
	}
	local inputs = { FWD, NONE, BACK, RIGHT, (FWD + RIGHT).Unit }
	local count = 0
	for name, build in scenarios do
		for _, action in { "Jump", "Cut", "Slide", "Dive", "Burst", "Swing" } do
			for _, mv in inputs do
				local s, b = build()
				local input = { move = mv, sprint = true }
				local ok, reason
				if action == "Swing" then
					ok, reason = MovementSim.swing(s, 1, envFor(b, s))
				else
					ok, reason = MovementSim.press(s, action, input, envFor(b, s))
				end
				count += 1
				expect(
					ok == true or (ok == false and reason ~= nil and REASONS[reason]),
					string.format("%s/%s: ok=%s reason=%s", name, action, tostring(ok), tostring(reason))
				)
				if not ok and (reason == "Speed" or reason == "Used" or reason == "Cooldown") then
					local out = frame(s, b, input)
					local explained = false
					for _, fb in out.feedback do
						if fb.text and #fb.text > 0 then
							explained = true
						end
					end
					expect(explained, string.format("%s/%s refused (%s) without text", name, action, reason))
				end
			end
		end
	end
	expect(count > 300, "covered " .. count)
end)

test("refusals carry ready-to-show text", function()
	local s, body = MovementSim.new(), newBody()
	local ok, reason = press(s, body, "Slide", { move = FWD, sprint = false })
	expect(not ok and reason == "Speed", "slow slide refused for speed: " .. tostring(reason))
	local out = frame(s, body, { move = FWD, sprint = false })
	expect(out.feedback[1] and out.feedback[1].text == "NEED SPEED", "NEED SPEED shown")

	local s2, b2 = sprintFwd()
	press(s2, b2, "Jump", { move = FWD, sprint = true })
	run(s2, b2, { move = FWD, sprint = true }, 0.1)
	expect(press(s2, b2, "Cut", { move = RIGHT, sprint = true }), "air redirect")
	local ok2, reason2 = press(s2, b2, "Cut", { move = LEFT, sprint = true })
	expect(not ok2 and reason2 == "Used", "second redirect is Used")
	local out2 = frame(s2, b2, { move = LEFT, sprint = true })
	local saw = false
	for _, fb in out2.feedback do
		if fb.text == "ONE PER JUMP" then
			saw = true
		end
	end
	expect(saw, "ONE PER JUMP shown")
end)

test("presses a little early are buffered and fire when valid (no lockouts)", function()
	-- plant restart pressed too early fires as Perfect when the window opens
	local s, body = sprintFwd()
	press(s, body, "Cut", { move = BACK, sprint = true })
	run(s, body, { move = BACK, sprint = true }, 0.02)
	local ok = press(s, body, "Cut", { move = BACK, sprint = true })
	expect(ok, "early restart buffered")
	expect(press(s, body, "Cut", { move = BACK, sprint = true }), "mashing it again changes nothing")
	local events = run(s, body, { move = BACK, sprint = true }, 0.1)
	local restart
	for _, e in events do
		if e.tech == "SnapCut" and e.info == "Restart" then
			restart = e
		end
	end
	expect(restart and restart.quality == "Perfect", "buffered restart fired Perfect")

	-- burst pressed just before touchdown fires on landing
	local s2, b2 = sprintFwd()
	press(s2, b2, "Jump", { move = FWD, sprint = true })
	local pressed = false
	local burst
	for _ = 1, 120 do
		local env = envFor(b2, s2)
		if not pressed and env.timeToLand and env.timeToLand < 0.1 and b2.vy < 0 then
			pressed = MovementSim.press(s2, "Burst", { move = FWD, sprint = true }, env)
		end
		local out = frame(s2, b2, { move = FWD, sprint = true })
		burst = burst or find(out.events, "BurstStep")
		if burst then
			break
		end
	end
	expect(pressed and burst ~= nil, "air burst buffered into the landing")
	expect(s2.mode == "Ground" or s2.mode == "Landing", "fired on the ground")
end)

---------------------------------------------------------------------------
-- cuts
---------------------------------------------------------------------------

test("committed full-speed snap cut is Perfect and keeps most speed", function()
	local s, body = sprintFwd()
	press(s, body, "Cut", { move = RIGHT, sprint = true })
	local events = run(s, body, { move = RIGHT, sprint = true }, DT)
	expect(#events == 1 and events[1].tech == "SnapCut", "snap cut emitted")
	expect(events[1].quality == "Perfect", "quality " .. events[1].quality)
	expect(s.vel:Dot(RIGHT) > Config.SprintSpeed * 0.8, "redirected speed " .. s.vel:Dot(RIGHT))
end)

test("keyboard pre-steer (D held 4/8/12 frames before Q) still gives a good Snap Cut", function()
	for _, k in { 4, 8, 12 } do
		local s, body = sprintFwd()
		run(s, body, { move = RIGHT, sprint = true }, k * DT)
		expect(press(s, body, "Cut", { move = RIGHT, sprint = true }), "cut accepted")
		local events = run(s, body, { move = RIGHT, sprint = true }, 0.15)
		local e = find(events, "SnapCut")
		expect(e ~= nil, k .. " frames: snap cut (got " .. tostring(events[1] and events[1].tech) .. ")")
		expect(QUALITY_RANK[e.quality] >= QUALITY_RANK.Clean, k .. " frames: quality " .. e.quality)
		expect(s.vel:Dot(RIGHT) >= 18, k .. " frames: exit speed " .. s.vel:Dot(RIGHT))
	end
end)

test("camera wobble while running keeps cuts Clean or better", function()
	local rng = Rng.new(77)
	for trial = 1, 12 do
		local s, body = MovementSim.new(), newBody()
		local phase = rng:range(0, 2 * math.pi)
		local t = 0
		local function wobble()
			return math.rad(15) * math.sin(2 * math.pi * 0.8 * t + phase)
		end
		for _ = 1, math.floor(rng:range(1.5, 2.5) / DT) do
			t += DT
			local yaw = wobble()
			frame(s, body, { move = VecMath.fromYaw(yaw), sprint = true })
		end
		local cutDir = VecMath.fromYaw(wobble() - math.pi / 2) -- camera-relative "D"
		expect(press(s, body, "Cut", { move = cutDir, sprint = true }), "cut accepted")
		local e = find(run(s, body, { move = cutDir, sprint = true }, 0.15), "SnapCut")
		expect(
			e ~= nil and QUALITY_RANK[e.quality] >= QUALITY_RANK.Clean,
			"trial " .. trial .. ": " .. tostring(e and e.quality)
		)
	end
end)

test("Q then a steer within 100 ms is a Snap Cut; Q alone is a Fake Commit", function()
	local s, body = sprintFwd()
	expect(press(s, body, "Cut", { move = FWD, sprint = true }), "look-ahead accepted")
	run(s, body, { move = FWD, sprint = true }, 0.05)
	local e = find(run(s, body, { move = RIGHT, sprint = true }, 0.1), "SnapCut")
	expect(e ~= nil and QUALITY_RANK[e.quality] >= QUALITY_RANK.Clean, "late steer became a cut")

	local s2, b2 = sprintFwd()
	press(s2, b2, "Cut", { move = FWD, sprint = true })
	local events = run(s2, b2, { move = FWD, sprint = true }, 0.2)
	local fake = find(events, "FakeCommit")
	expect(fake ~= nil and find(events, "SnapCut") == nil, "no steer: fake commit")
	expect(s2.vel.Magnitude > Config.SprintSpeed * 0.8, "the jab barely slows you")
end)

test("a Burst during the Cut look-ahead spends it: no phantom Fake Commit, no cancelled burst", function()
	local s, body = sprintFwd()
	expect(press(s, body, "Cut", { move = FWD, sprint = true }), "look-ahead accepted")
	run(s, body, { move = FWD, sprint = true }, 2 * DT)
	expect(press(s, body, "Burst", { move = FWD, sprint = true }), "burst accepted")
	local events = run(s, body, { move = FWD, sprint = true }, 0.2)
	expect(find(events, "BurstStep") ~= nil, "burst fired")
	expect(find(events, "FakeCommit") == nil, "no phantom fake commit")

	local s2, b2 = sprintFwd()
	press(s2, b2, "Cut", { move = FWD, sprint = true })
	run(s2, b2, { move = FWD, sprint = true }, 2 * DT)
	press(s2, b2, "Burst", { move = FWD, sprint = true })
	run(s2, b2, { move = FWD, sprint = true }, DT)
	local steered = run(s2, b2, { move = RIGHT, sprint = true }, 0.05)
	expect(find(steered, "SnapCut") == nil, "a steer after the burst is not a look-ahead cut")
	expect(s2.burstUntil > s2.now, "the burst is still running")
end)

test("plant is recognised even with S held before Q (judged on the old line)", function()
	for _, k in { 3, 6, 12 } do
		local s, body = sprintFwd()
		run(s, body, { move = BACK, sprint = true }, k * DT)
		press(s, body, "Cut", { move = BACK, sprint = true })
		local events = run(s, body, { move = BACK, sprint = true }, DT)
		local e = events[1]
		expect(e and e.tech == "MomentumCancel", k .. " frames: " .. tostring(e and e.tech))
	end
end)

test("a plant restarts automatically when a direction is held; pressing pays more", function()
	local function after(pressAgain)
		local s, body = sprintFwd()
		press(s, body, "Cut", { move = NONE, sprint = true })
		run(s, body, { move = NONE, sprint = true }, 0.08)
		if pressAgain then
			press(s, body, "Cut", { move = RIGHT, sprint = true })
		end
		run(s, body, { move = RIGHT, sprint = true }, 0.1)
		return s.vel:Dot(RIGHT)
	end
	local auto, pressed = after(false), after(true)
	expect(auto >= Config.SprintSpeed * 0.75, "auto restart speed " .. auto)
	expect(pressed > auto, string.format("pressed %.1f vs auto %.1f", pressed, auto))
end)

test("Q at low speed is a quick side step", function()
	local s, body = MovementSim.new(), newBody()
	expect(press(s, body, "Cut", { move = RIGHT, sprint = false }), "side step accepted")
	local events = run(s, body, { move = RIGHT, sprint = false }, DT)
	expect(events[1] and events[1].tech == "FakeCommit" and events[1].info == "SideStep", "side step")
	near(s.vel.Magnitude, Config.FakeCommit.SideStepSpeed, 0.5, "side step speed")
end)

test("zig-zag spam degrades to Sloppy and bleeds speed", function()
	local s, body = sprintFwd()
	local dirs = { (FWD + RIGHT).Unit, (FWD - RIGHT).Unit }
	local qualities, exits = {}, {}
	for i = 1, 6 do
		local d = dirs[(i % 2) + 1]
		press(s, body, "Cut", { move = d, sprint = true })
		run(s, body, { move = d, sprint = true }, 0.25, function(out)
			for _, e in out.events do
				if e.tech == "SnapCut" then
					table.insert(qualities, e.quality)
					table.insert(exits, out.vel.Magnitude)
				end
			end
		end)
	end
	local sloppy = 0
	for _, q in qualities do
		if q == "Sloppy" or q == "Gassed" then
			sloppy += 1
		end
	end
	expect(sloppy >= 3, "spammed cuts were not penalised: " .. table.concat(qualities, ","))
	-- the first (committed) cut keeps the most speed; spammed ones leave slower
	expect(exits[#exits] < exits[1] - 2, string.format("exit speeds first %.1f last %.1f", exits[1], exits[#exits]))
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

---------------------------------------------------------------------------
-- burst, slide, landing, dive, air
---------------------------------------------------------------------------

test("burst step has a cooldown and respects its speed ceiling", function()
	local s, body = sprintFwd()
	expect(press(s, body, "Burst", { move = FWD, sprint = true }), "burst accepted")
	run(s, body, { move = FWD, sprint = true }, DT)
	expect(s.vel.Magnitude <= Config.BurstStep.MaxSpeed + 1e-3, "burst speed " .. s.vel.Magnitude)
	local ok, reason = press(s, body, "Burst", { move = FWD, sprint = true })
	expect(not ok and reason == "Cooldown", "burst on cooldown: " .. tostring(reason))
	-- the refusal names the technique (the HUD flashes that pip) and says when
	local out = frame(s, body, { move = FWD, sprint = true })
	local fb = out.feedback[1]
	expect(fb ~= nil and fb.kind == "Cooldown" and fb.tech == "BurstStep", "cooldown feedback names the tech")
	expect(fb ~= nil and type(fb.text) == "string" and type(fb.value) == "number", "cooldown text and time left")
	run(s, body, { move = FWD, sprint = true }, 1.0)
	expect(s.vel.Magnitude < Config.SprintSpeed + 1, "overspeed decays back toward sprint")
end)

test("burst works out of a slide; a jump in between does not void a Perfect chain", function()
	local s, body = sprintFwd()
	press(s, body, "Slide", { move = FWD, sprint = true })
	run(s, body, { move = FWD, sprint = true }, 0.2)
	expect(press(s, body, "Burst", { move = RIGHT, sprint = true }), "burst from slide")
	local e = find(run(s, body, { move = RIGHT, sprint = true }, DT), "BurstStep")
	expect(e ~= nil and s.mode == "Ground", "slide ended into the burst")

	-- Snap Cut -> Jump -> air Layout: the jump used to overwrite the chain
	local s2, b2 = sprintFwd()
	press(s2, b2, "Cut", { move = RIGHT, sprint = true })
	run(s2, b2, { move = RIGHT, sprint = true }, 0.05)
	expect(press(s2, b2, "Jump", { move = RIGHT, sprint = true }), "jump")
	run(s2, b2, { move = RIGHT, sprint = true }, 0.15)
	expect(press(s2, b2, "Dive", { move = RIGHT, sprint = true }), "air layout")
	local d = find(run(s2, b2, { move = RIGHT, sprint = true }, DT), "Dive")
	expect(d and d.quality == "Perfect" and d.chain, "cut -> jump -> layout Perfect: " .. tostring(d and d.quality))
end)

test("precision landing: timing sets the bonus; early presses are not punished", function()
	local function jumpAndPressAt(threshold)
		local s, body = sprintFwd()
		press(s, body, "Jump", { move = FWD, sprint = true })
		local before = s.vel.Magnitude
		local pressed = false
		local events, fbs = {}, {}
		for _ = 1, 120 do
			local env = envFor(body, s)
			if not pressed and env.timeToLand and env.timeToLand <= threshold and body.vy < 0 then
				pressed = MovementSim.press(s, "Slide", { move = FWD, sprint = true }, env)
			end
			local out = frame(s, body, { move = FWD, sprint = true })
			for _, e in out.events do
				table.insert(events, e)
			end
			for _, f in out.feedback do
				table.insert(fbs, f)
			end
		end
		return find(events, "PrecisionLanding"), s, before, fbs
	end
	local perfect = jumpAndPressAt(0.04)
	expect(perfect ~= nil and perfect.quality == "Perfect", "perfect precision landing")
	local clean = jumpAndPressAt(0.15)
	expect(clean ~= nil and clean.quality == "Clean", "clean precision landing")
	local soft, s3, before3, fbs = jumpAndPressAt(0.32)
	expect(soft == nil, "armed early = unlabelled soft landing")
	expect(s3.vel.Magnitude >= before3 * Config.LandingRetention - 0.5, "soft landing keeps speed")
	expect(fbs[1] and fbs[1].kind == "LandingOffset" and fbs[1].text ~= nil, "soft landing explained")

	-- far too early: refused, but a later press in the same jump still arms
	local s4, b4 = sprintFwd()
	press(s4, b4, "Jump", { move = FWD, sprint = true })
	run(s4, b4, { move = FWD, sprint = true }, 0.05)
	local ok, reason = press(s4, b4, "Slide", { move = FWD, sprint = true })
	expect(not ok and reason == "Context", "far-too-early press refused: " .. tostring(reason))
	local armed = false
	for _ = 1, 120 do
		local env = envFor(b4, s4)
		if not armed and env.timeToLand and env.timeToLand <= 0.05 and b4.vy < 0 then
			armed = MovementSim.press(s4, "Slide", { move = FWD, sprint = true }, env)
		end
		frame(s4, b4, { move = FWD, sprint = true })
	end
	expect(armed, "no lockout after an early press")
end)

test("dive -> slide -> recovery pop: Perfect at the stop, and always chained", function()
	local s, body = sprintFwd()
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

	-- pops at every point of the window (and from slow and fast dives) chain
	for _, startSpeed in { false, true } do
		for _, waitFrames in { 0, 10, 20, 30, 45 } do
			local s2, b2 = MovementSim.new(), newBody()
			run(s2, b2, { move = FWD, sprint = startSpeed }, 1.5)
			press(s2, b2, "Dive", { move = FWD, sprint = true })
			for _ = 1, 120 do
				frame(s2, b2, { move = FWD, sprint = true })
				if s2.mode == "DiveSlide" then
					break
				end
			end
			run(s2, b2, { move = FWD, sprint = true }, waitFrames * DT)
			local popped
			for _ = 1, 60 do
				MovementSim.press(s2, "Jump", { move = FWD, sprint = true }, envFor(b2, s2))
				local out = frame(s2, b2, { move = FWD, sprint = true })
				popped = popped or find(out.events, "RecoveryChain")
				if popped or s2.mode == "Ground" then
					break
				end
			end
			if popped then
				expect(popped.chain, "pop after " .. waitFrames .. " frames is chained")
			end
		end
	end
end)

test("air redirect: aligned input is a free no-op; then one per airtime", function()
	local s, body = sprintFwd()
	press(s, body, "Jump", { move = FWD, sprint = true })
	run(s, body, { move = FWD, sprint = true }, 0.1)
	local speed = s.vel.Magnitude
	local ok, reason = press(s, body, "Cut", { move = FWD, sprint = true })
	expect(not ok and reason == "Context", "aligned redirect refused")
	expect(not s.airRedirectUsed and math.abs(s.vel.Magnitude - speed) < 1e-3, "not consumed, no speed lost")
	expect(press(s, body, "Cut", { move = BACK, sprint = true }), "redirect accepted")
	run(s, body, { move = BACK, sprint = true }, DT)
	local angle = VecMath.flatAngle(FWD, s.vel)
	expect(angle <= Config.AirRedirect.MaxAngle + 1, "redirect angle " .. angle)
	local ok2, reason2 = press(s, body, "Cut", { move = RIGHT, sprint = true })
	expect(not ok2 and reason2 == "Used", "second redirect rejected")
end)

test("slide hop chains cannot build speed beyond the slide ceiling", function()
	local s, body = sprintFwd()
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
			local out = frame(s, body, { move = FWD, sprint = true })
			maxSpeed = math.max(maxSpeed, out.vel.Magnitude)
			if s.mode == "Ground" then
				break
			end
		end
	end
	expect(maxSpeed <= Config.Slide.BoostCeiling + 0.01, "slide-hop max speed " .. maxSpeed)
end)

test("holding sprint for 30 s keeps plenty of exertion; Gassed only below half cost", function()
	local s, body = MovementSim.new(), newBody()
	run(s, body, { move = FWD, sprint = true }, 30)
	expect(s.exertion > 30, "exertion after 30 s sprint " .. s.exertion)
	expect(s.vel.Magnitude > Config.SprintSpeed - 0.5, "still at full sprint")

	local s2, b2 = sprintFwd()
	s2.exertion = Config.SnapCut.Cost * 0.7 -- below cost, above half cost
	press(s2, b2, "Cut", { move = RIGHT, sprint = true })
	local e = find(run(s2, b2, { move = RIGHT, sprint = true }, DT), "SnapCut")
	expect(e and e.quality ~= "Gassed", "not Gassed above half cost: " .. tostring(e and e.quality))
end)

---------------------------------------------------------------------------
-- holding the disc: pivot foot + step
---------------------------------------------------------------------------

local function catchAndPlant(aimYaw)
	local s, body = sprintFwd()
	body.aimYaw = aimYaw or 0
	MovementSim.setHolding(s, true, true)
	local pivot, reports = nil, 0
	for _ = 1, 60 do
		local out = frame(s, body, { move = NONE, sprint = false })
		if out.pivotPos then
			reports += 1
			pivot = out.pivotPos
		end
	end
	return s, body, pivot, reports
end

test("after a catch the holder slows down and plants one pivot foot", function()
	local s, body = sprintFwd()
	MovementSim.setHolding(s, true, true)
	local t, plantedAt, reports = 0, nil, 0
	for _ = 1, 60 do
		local out = frame(s, body, { move = FWD, sprint = true })
		t += DT
		if out.pivotPos then
			reports += 1
			plantedAt = plantedAt or t
			expect(out.pivotEstablished, "pivotEstablished on the plant frame")
		end
	end
	expect(reports == 1, "pivot reported exactly once: " .. reports)
	expect(plantedAt and plantedAt <= HD.DecelMaxTime + DT, "planted by DecelMaxTime: " .. tostring(plantedAt))
	MovementSim.setHolding(s, true, true) -- server confirms the predicted catch
	expect(s.holdPhase == "Pivot", "a second setHolding(true) does not restart the slow-down")
	local ok, reason = press(s, body, "Burst", { move = FWD, sprint = true })
	expect(not ok and reason == "Context", "no running techniques while holding")
end)

test("the root stays within BodyShare*R of the pivot while stepping everywhere", function()
	local s, body, pivot = catchAndPlant()
	expect(pivot ~= nil, "planted")
	local worst, farthest = 0, 0
	local dirs = { RIGHT, LEFT, FWD, BACK, (FWD + RIGHT).Unit, (BACK + LEFT).Unit, NONE }
	for i = 1, 40 do
		local d = dirs[(i % #dirs) + 1]
		for _ = 1, 12 do
			local out = frame(s, body, { move = d, sprint = false })
			local off = VecMath.flat(body.pos - pivot).Magnitude
			worst = math.max(worst, off)
			farthest = math.max(farthest, out.step.Magnitude)
			local target = MovementSim.rootTarget(s)
			expect(VecMath.flat(target - pivot).Magnitude <= HD.BodyShare * R + 0.05, "root target in range")
		end
	end
	expect(worst <= HD.BodyShare * R + 0.05, "root strayed " .. worst)
	expect(farthest > R * 0.9, "full lateral steps reach R: " .. farthest)
end)

test("step limits: lunge <= 0.75R forward, drop step <= 0.9R back, side ~R", function()
	local s, body = catchAndPlant()
	run(s, body, { move = FWD, sprint = false }, 0.5)
	local fwd = s.step:Dot(FWD)
	expect(fwd <= HD.ForwardMax * R + 1e-3 and fwd > HD.ForwardMax * R * 0.9, "forward " .. fwd)
	run(s, body, { move = BACK, sprint = false }, 0.6)
	local back = -s.step:Dot(FWD)
	expect(back <= HD.BackMax * R + 1e-3 and back > HD.BackMax * R * 0.9, "back " .. back)
	run(s, body, { move = RIGHT, sprint = false }, 0.6)
	expect(s.step:Dot(RIGHT) > R * 0.95, "side " .. s.step:Dot(RIGHT))
	run(s, body, { move = NONE, sprint = false }, 0.5)
	expect(s.step.Magnitude < 0.05, "no input returns to squared up")
end)

test("steps are relative to the aim (camera) yaw", function()
	local yaw = math.rad(70)
	local s, body = catchAndPlant(yaw)
	-- camera-relative "D" in world space
	local camRight = Vector3.new(math.cos(yaw), 0, -math.sin(yaw))
	run(s, body, { move = camRight, sprint = false }, 0.5)
	expect(VecMath.flatUnit(s.step):Dot(camRight) > 0.99, "step follows the aim frame")
	-- turning the camera with the key held rotates the step smoothly
	body.aimYaw = yaw + math.rad(40)
	local out = frame(s, body, { move = camRight, sprint = false })
	expect(out.step.Magnitude > R * 0.9, "length kept while turning")
end)

test("quick swing reaches the far side in <= 0.2 s and stays there", function()
	local s, body = catchAndPlant()
	run(s, body, { move = LEFT, sprint = false }, 0.4)
	expect(s.step:Dot(RIGHT) < -R * 0.9, "stepped left")
	expect(MovementSim.swing(s, 1, envFor(body, s)), "swing accepted")
	local t, reached = 0, nil
	local target = Vector3.new(HD.SwingLateral * R, 0, -HD.SwingForward * R)
	local events = {}
	for _ = 1, 30 do
		local out = frame(s, body, { move = LEFT, sprint = false })
		t += DT
		for _, e in out.events do
			table.insert(events, e)
		end
		if not reached and (s.step - target).Magnitude < 0.15 * R then
			reached = t
		end
	end
	expect(reached and reached <= 0.2, "swing time " .. tostring(reached))
	expect(find(events, "PivotSwing"), "PivotSwing emitted")
	expect(s.step:Dot(RIGHT) > R * 0.8, "holding the old key does not pull you back")
	local ok, reason = MovementSim.swing(s, -1, envFor(body, s))
	expect(ok or reason == "Cooldown", "cooldown or buffered")
end)

test("a swing right after a fake is Sold (Perfect); a plain one is Clean", function()
	local s, body = catchAndPlant()
	MovementSim.fakeStep(s, 1)
	run(s, body, { move = NONE, sprint = false }, 0.15)
	expect(s.step:Dot(RIGHT) > 0.3 * R, "the fake lunges toward its side")
	MovementSim.swing(s, -1, envFor(body, s))
	local e = find(run(s, body, { move = NONE, sprint = false }, DT), "PivotSwing")
	expect(e and e.quality == "Perfect" and e.info == "Sold", "sold swing")

	run(s, body, { move = NONE, sprint = false }, 1)
	MovementSim.swing(s, 1, envFor(body, s))
	local e2 = find(run(s, body, { move = NONE, sprint = false }, DT), "PivotSwing")
	expect(e2 and e2.quality == "Clean", "plain swing is Clean")
end)

test("a fake with the side key held (foot at full reach) still lunges the body", function()
	local s, body, pivot = catchAndPlant()
	run(s, body, { move = RIGHT, sprint = false }, 0.6)
	expect(s.step:Dot(RIGHT) > 0.95 * R, "stepped out fully")
	local before = (body.pos - pivot):Dot(RIGHT)
	MovementSim.fakeStep(s, 1)
	local most = before
	run(s, body, { move = RIGHT, sprint = false }, HD.FakeStepOut, function()
		most = math.max(most, (body.pos - pivot):Dot(RIGHT))
	end)
	expect(most - before > 0.15 * R, string.format("body lunged %.2f studs", most - before))
	expect(s.step.Magnitude <= R + 1e-6, "the step itself stays within reach")
	run(s, body, { move = RIGHT, sprint = false }, 0.5)
	near((body.pos - pivot):Dot(RIGHT), before, 0.1, "and comes back")
end)

test("the pivot survives a teleport reset and adopts the server's UBPivot", function()
	local s, body, pivot = catchAndPlant()
	run(s, body, { move = RIGHT, sprint = false }, 0.3)
	MovementSim.reset(s)
	expect(s.holding and s.holdPhase == "Pivot", "still pivoting")
	expect(MovementSim.getPivot(s) == pivot, "pivot kept")
	expect(s.step.Magnitude == 0, "step squared up")
	MovementSim.setPivot(s, nil)
	expect(MovementSim.getPivot(s) == pivot, "nil never clears the sim's own plant")

	local server = pivot + Vector3.new(0.4, 0, 0)
	MovementSim.setPivot(s, server)
	local reported = false
	for _ = 1, 30 do
		local out = frame(s, body, { move = NONE, sprint = false })
		reported = reported or out.pivotPos ~= nil
	end
	expect(not reported, "an adopted pivot is not re-reported")
	expect(VecMath.flat(body.pos - server).Magnitude < 0.05, "the root settles on the adopted pivot")

	-- teleported far away without a new pivot: plant a fresh one there
	body.pos += Vector3.new(30, 0, 0)
	local out = frame(s, body, { move = NONE, sprint = false })
	expect(out.pivotPos ~= nil, "re-planted after a big jump")
	local fresh = out.pivotPos
	-- the driver keeps passing the old attribute: it is not re-adopted (no loop)
	MovementSim.setPivot(s, server)
	expect(MovementSim.getPivot(s) == fresh, "stale pivot ignored")
	expect(frame(s, body, { move = NONE, sprint = false }).pivotPos == nil, "no re-plant loop")
	MovementSim.setPivot(s, fresh)
	expect(MovementSim.getPivot(s) == fresh and s.pivotAdopted, "the server's echo is adopted")
end)

test("hop: airtime >= 0.35 s, no horizontal drift, frozen step, one per possession", function()
	local s, body = catchAndPlant()
	run(s, body, { move = RIGHT, sprint = false }, 0.4)
	local step = s.step
	expect(press(s, body, "Jump", { move = RIGHT, sprint = false }), "hop accepted")
	local air, start, landedAt = 0, body.pos, nil
	for _ = 1, 60 do
		local out = frame(s, body, { move = LEFT, sprint = false })
		if out.landed then
			landedAt = landedAt or body.pos
		end
		if MovementSim.isAirborne(s) then
			air += DT
			expect(out.vel.Magnitude < 1e-6, "no horizontal velocity mid-hop")
			expect((out.step - step).Magnitude < 1e-6, "step frozen mid-hop")
		end
	end
	expect(air >= 0.35, "hop airtime " .. air)
	expect(landedAt and VecMath.flat(landedAt - start).Magnitude < 0.1, "no drift during the hop")
	local ok, reason = press(s, body, "Jump", { move = NONE, sprint = false })
	expect(not ok and reason == "Used", "second hop refused")
end)

---------------------------------------------------------------------------
-- marking
---------------------------------------------------------------------------

test("mark shuffle: tight, capped at ShuffleSpeed, no drain; techniques end it", function()
	local s, body = MovementSim.new(), newBody()
	MovementSim.setMarking(s, true)
	s.exertion = 50
	local top = 0
	run(s, body, { move = RIGHT, sprint = true }, 1, function(out)
		top = math.max(top, out.vel.Magnitude)
	end)
	expect(top <= Config.Marking.ShuffleSpeed + 1e-3, "shuffle top " .. top)
	expect(MovementSim.poseMode(s) == "Mark", "MS pose mode while marking")
	expect(s.exertion >= 50, "no sprint drain while marking")
	-- reverse direction: no turn radius, back to full shuffle fast
	local t = 0
	while s.vel:Dot(LEFT) < Config.Marking.ShuffleSpeed * 0.9 and t < 1 do
		run(s, body, { move = LEFT, sprint = true }, DT)
		t += DT
	end
	expect(t < 0.25, "shuffle reversal " .. t)
	expect(press(s, body, "Jump", { move = LEFT, sprint = true }), "jump while marking")
	expect(MovementSim.isMarking(s), "jump keeps the mark")
	run(s, body, { move = LEFT, sprint = true }, 1)
	local ok, reason = press(s, body, "Slide", { move = LEFT, sprint = true })
	expect(not ok and reason == "Context", "Slide is the stance toggle, not a slide")
	expect(press(s, body, "Dive", { move = LEFT, sprint = true }), "dive fires")
	expect(not MovementSim.isMarking(s), "dive ended the mark")
end)

---------------------------------------------------------------------------
-- context line
---------------------------------------------------------------------------

test("contextHint names what each key would do right now", function()
	local s, body = sprintFwd()
	local h = MovementSim.contextHint(s, { move = FWD, sprint = true }, envFor(body, s))
	expect(h.Cut == "FAKE COMMIT", "running straight: " .. tostring(h.Cut))
	h = MovementSim.contextHint(s, { move = RIGHT, sprint = true }, envFor(body, s))
	expect(h.Cut == "SNAP CUT" and h.Jump == "JUMP" and h.Slide == "SLIDE", "cut: " .. tostring(h.Cut))
	h = MovementSim.contextHint(s, { move = NONE, sprint = true }, envFor(body, s))
	expect(h.Cut == "PLANT", "no input: " .. tostring(h.Cut))

	press(s, body, "Jump", { move = FWD, sprint = true })
	local sawPL = false
	for _ = 1, 120 do
		frame(s, body, { move = FWD, sprint = true })
		local hh = MovementSim.contextHint(s, { move = FWD, sprint = true }, envFor(body, s))
		if hh.Slide == "PRECISION LANDING" then
			sawPL = true
		end
	end
	expect(sawPL, "PRECISION LANDING offered near touchdown")

	local s2, b2 = catchAndPlant()
	expect(MovementSim.poseMode(s2) == "Pivot", "MS pose mode while pivoting")
	local hh = MovementSim.contextHint(s2, { move = NONE, sprint = false }, envFor(b2, s2))
	expect(hh.Cut == "SWING LEFT" and hh.Dive == "SWING RIGHT" and hh.Jump == "HOP", "holding hints")
	local before = s2.vel
	MovementSim.contextHint(s2, { move = RIGHT, sprint = false }, envFor(b2, s2))
	expect(s2.vel == before, "contextHint is pure")
end)

test("contextHint never offers a press the cooldown would refuse", function()
	-- Burst, then plant inside the Burst cooldown: no EXPLOSIVE RESTART
	local s, body = sprintFwd()
	expect(press(s, body, "Burst", { move = FWD, sprint = true }), "burst accepted")
	run(s, body, { move = FWD, sprint = true }, 0.4)
	expect(press(s, body, "Cut", { move = NONE, sprint = true }), "plant accepted")
	run(s, body, { move = NONE, sprint = true }, 0.1)
	expect(s.plantAt > 0, "in the plant")
	local h = MovementSim.contextHint(s, { move = NONE, sprint = true }, envFor(body, s))
	expect(h.Burst == nil, "burst on cooldown: " .. tostring(h.Burst))
	local ok = press(s, body, "Burst", { move = RIGHT, sprint = true })
	expect(not ok, "and the press is indeed refused")

	-- ground layout, then a pop-up jump: no AIR LAYOUT while Dive cools down
	local s2, b2 = sprintFwd()
	expect(press(s2, b2, "Dive", { move = FWD, sprint = true }), "dive accepted")
	local cooling, offered = 0, 0
	for _ = 1, 120 do
		frame(s2, b2, { move = FWD, sprint = true })
		if s2.mode == "DiveSlide" or s2.mode == "Recover" then
			press(s2, b2, "Jump", { move = FWD, sprint = true })
		elseif s2.mode == "Air" and (s2.ready.Dive or -math.huge) > s2.now then
			cooling += 1
			local hh = MovementSim.contextHint(s2, { move = FWD, sprint = true }, envFor(b2, s2))
			if hh.Dive ~= nil then
				offered += 1
			end
		end
	end
	expect(cooling > 0, "popped up while the Dive cooldown ran")
	expect(offered == 0, "AIR LAYOUT offered on cooldown " .. offered .. " frames")
end)

---------------------------------------------------------------------------
-- fuzz
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- momentum limits on explosive techniques
---------------------------------------------------------------------------

test("burst and layout cannot reverse a full sprint in one frame", function()
	local s, body = sprintFwd()
	local before = VecMath.flatUnit(s.vel)
	press(s, body, "Burst", { move = BACK, sprint = true })
	local out = frame(s, body, { move = BACK, sprint = true })
	local bent = VecMath.flatAngle(before, VecMath.flatUnit(out.vel))
	expect(bent <= Config.BurstStep.MaxTurn + 1, "burst bends at most MaxTurn, got " .. bent)

	local s2, body2 = sprintFwd()
	local before2 = VecMath.flatUnit(s2.vel)
	press(s2, body2, "Dive", { move = BACK, sprint = true })
	local out2 = frame(s2, body2, { move = BACK, sprint = true })
	local bent2 = VecMath.flatAngle(before2, VecMath.flatUnit(out2.vel))
	expect(bent2 <= Config.Dive.MaxTurn + 1, "ground layout leaves at most MaxTurn off the line, got " .. bent2)
end)

test("a burst out of a plant still goes any direction", function()
	local s, body = sprintFwd()
	press(s, body, "Cut", { move = NONE, sprint = true }) -- plant
	run(s, body, { move = NONE, sprint = true }, 0.14)
	press(s, body, "Burst", { move = BACK, sprint = true })
	local out = frame(s, body, { move = BACK, sprint = true })
	expect(out.vel:Dot(BACK) > 20, "explosive restart reverses")
end)

---------------------------------------------------------------------------
-- resets (the flip-reset family)
---------------------------------------------------------------------------

local function jumpTo(s, body, input, seconds)
	press(s, body, "Jump", input)
	return run(s, body, input, seconds)
end

test("tip reset: both air moves come back, the next one is Charged, with a lift", function()
	local s, body = sprintFwd()
	local input = { move = FWD, sprint = true }
	jumpTo(s, body, input, 0.1)
	-- spend the air redirect
	local okRedirect = press(s, body, "Cut", { move = RIGHT, sprint = true })
	run(s, body, { move = RIGHT, sprint = true }, 0.05)
	expect(okRedirect and s.airRedirectUsed, "air redirect spent")
	local ok2 = press(s, body, "Cut", { move = LEFT, sprint = true })
	expect(not ok2, "only one air redirect per jump without a reset")

	local tipped = MovementSim.tipReset(s, envFor(body, s), "Perfect", FWD)
	local out = frame(s, body, { move = LEFT, sprint = true })
	expect(tipped, "tip reset accepted in the air")
	expect(not s.airRedirectUsed and not s.airDiveUsed and s.charged, "air moves back and Charged")
	expect(out.setVertical ~= nil and out.setVertical >= Config.Reset.TipLiftPerfect - 1e-6, "Perfect tip lifts you")
	expect(find(out.events, "TipReset") ~= nil, "emits TipReset")

	local speed = s.vel.Magnitude
	local ok3 = press(s, body, "Cut", { move = LEFT, sprint = true })
	local out3 = frame(s, body, { move = LEFT, sprint = true })
	local ev = find(out3.events, "AirRedirect")
	expect(ok3 and ev ~= nil and ev.info == "Charged", "second air redirect after the reset is Charged")
	expect(s.vel.Magnitude >= speed * Config.Reset.ChargedRetention - 0.5, "a Charged redirect keeps its speed")
end)

test("tip resets: on the ground no, two per jump at most, a cooldown between", function()
	local s, body = sprintFwd()
	local ok = MovementSim.tipReset(s, envFor(body, s), "Clean", FWD)
	expect(not ok, "no tip reset on the ground")
	jumpTo(s, body, { move = FWD, sprint = true }, 0.05)
	expect(MovementSim.tipReset(s, envFor(body, s), "Clean", FWD), "first tip")
	expect(not MovementSim.tipReset(s, envFor(body, s), "Clean", FWD), "cooldown between tips")
	run(s, body, { move = FWD, sprint = true }, Config.Reset.TipCooldown + 0.02)
	expect(MovementSim.tipReset(s, envFor(body, s), "Clean", FWD), "second tip after the cooldown")
	run(s, body, { move = FWD, sprint = true }, Config.Reset.TipCooldown + 0.02)
	if s.mode == "Air" or s.mode == "Dive" then
		expect(not MovementSim.tipReset(s, envFor(body, s), "Clean", FWD), "never a third in one jump")
	end
	run(s, body, { move = FWD, sprint = true }, 1.5)
	expect(s.tipsThisAir == 0 and not s.charged, "landing clears the tips and the charge")
end)

test("a ground layout needs a reset before an air layout in the same airtime", function()
	local s, body = sprintFwd()
	press(s, body, "Dive", { move = FWD, sprint = true })
	run(s, body, { move = FWD, sprint = true }, 0.05)
	expect(s.mode == "Dive", "diving")
	local again = press(s, body, "Dive", { move = FWD, sprint = true })
	expect(not again, "no second layout without a reset")
	expect(MovementSim.tipReset(s, envFor(body, s), "Clean", FWD), "tip reset mid-dive")
	local out = frame(s, body, { move = FWD, sprint = true })
	local ok = press(s, body, "Dive", { move = FWD, sprint = true })
	local out2 = frame(s, body, { move = FWD, sprint = true })
	local ev = find(out2.events, "Dive") or find(out.events, "Dive")
	expect(ok and ev ~= nil and ev.info == "Air", "the reset gives an air layout")
	expect(s.vel.Magnitude <= Config.HardCap + 1e-6, "under the hard cap")
end)

test("wall rebound is a reset too: air layout and air cut come back", function()
	local s, body = sprintFwd()
	jumpTo(s, body, { move = FWD, sprint = true }, 0.05)
	press(s, body, "Dive", { move = FWD, sprint = true })
	run(s, body, { move = FWD, sprint = true }, 0.03)
	expect(s.airDiveUsed, "air layout spent")
	local env = envFor(body, s)
	env.wallNormal = BACK
	env.wallDistance = 1
	env.wallId = "W1"
	local ok = MovementSim.press(s, "Jump", { move = FWD, sprint = true }, env)
	expect(ok and not s.airDiveUsed and not s.airRedirectUsed and s.charged, "wall reset")
end)

test("landing reset: a Perfect precision landing refunds Burst and Layout", function()
	local s, body = sprintFwd()
	press(s, body, "Burst", { move = FWD, sprint = true })
	run(s, body, { move = FWD, sprint = true }, 0.25)
	expect(s.ready.BurstStep > s.now, "burst on cooldown")
	press(s, body, "Jump", { move = FWD, sprint = true })
	local pressed = false
	local events, fbs = {}, {}
	for _ = 1, 120 do
		local env = envFor(body, s)
		if not pressed and env.timeToLand and env.timeToLand <= 0.03 and body.vy < 0 then
			pressed = MovementSim.press(s, "Slide", { move = FWD, sprint = true }, env)
		end
		local out = frame(s, body, { move = FWD, sprint = true })
		for _, e in out.events do
			table.insert(events, e)
		end
		for _, f in out.feedback do
			table.insert(fbs, f)
		end
		if find(events, "PrecisionLanding") then
			break
		end
	end
	local pl = find(events, "PrecisionLanding")
	expect(pl ~= nil and pl.quality == "Perfect" and pl.info == "Reset", "Perfect landing is a Landing Reset")
	expect(s.ready.BurstStep <= s.now + 1e-6, "burst refunded")
	local said = false
	for _, f in fbs do
		if f.kind == "Reset" then
			said = true
		end
	end
	expect(said, "the reset is announced")
	local ok = press(s, body, "Burst", { move = FWD, sprint = true })
	expect(ok, "burst again at once")
end)

test("fuzz (120k frames, with resets): never past HardCap, no NaN, exertion in range, root target near P", function()
	local rng = Rng.new(1234)
	local actions = { "Jump", "Cut", "Slide", "Dive", "Burst" }
	local worst = 0
	local frames = 0
	for trial = 1, 40 do
		local s, body = MovementSim.new(), newBody()
		local walls = trial % 2 == 0
		for _ = 1, 3000 do
			frames += 1
			local yaw = rng:range(-math.pi, math.pi)
			local mag = if rng:next() < 0.15 then 0 else rng:range(0.2, 1)
			local input = { move = VecMath.fromYaw(yaw) * mag, sprint = rng:next() < 0.7 }
			if rng:next() < 0.01 then
				body.aimYaw = rng:range(-math.pi, math.pi)
			end
			local env = envFor(body, s)
			if walls and not env.grounded and rng:next() < 0.3 then
				env.wallNormal = VecMath.fromYaw(rng:range(-math.pi, math.pi))
				env.wallDistance = rng:range(0.2, 3)
				env.wallId = "w" .. rng:int(1, 4)
			end
			if rng:next() < 0.02 then
				env.blocked = true
				env.actualVel = env.actualVel * rng:range(0, 0.5)
			end
			local r = rng:next()
			if r < 0.2 then
				local ok, reason = MovementSim.press(s, actions[rng:int(1, #actions)], input, env)
				expect(ok or REASONS[reason], "bad press result")
			elseif r < 0.23 then
				MovementSim.swing(s, rng:int(-1, 1), env)
			elseif r < 0.24 then
				MovementSim.fakeStep(s, rng:int(-1, 1))
			elseif r < 0.245 then
				MovementSim.setMarking(s, not MovementSim.isMarking(s))
			elseif r < 0.248 then
				MovementSim.setHolding(s, not s.holding, env.grounded)
			elseif r < 0.249 then
				MovementSim.reset(s)
			elseif r < 0.27 then
				-- tip resets whenever the fuzz feels like it (the client only
				-- offers them in the air, near a disc)
				MovementSim.tipReset(s, env, if rng:next() < 0.5 then "Perfect" else "Clean", input.move)
			end
			local dt = DT * rng:range(0.5, 2)
			local out = MovementSim.step(s, input, env, dt)
			physics(body, out, dt)
			if out.pivotPos then
				-- the server validates and echoes it back as UBPivot
				MovementSim.setPivot(s, out.pivotPos + VecMath.fromYaw(rng:range(-3, 3)) * rng:range(0, 0.4))
			end
			local sp = out.vel.Magnitude
			expect(sp == sp and out.step.Magnitude == out.step.Magnitude, "NaN velocity / step")
			worst = math.max(worst, sp)
			expect(s.exertion >= 0 and s.exertion <= Config.ExertionMax, "exertion out of range")
			if out.setVertical then
				expect(out.setVertical <= 60, "vertical impulse too large: " .. out.setVertical)
			end
			local p, target = MovementSim.getPivot(s), MovementSim.rootTarget(s)
			if p and target then
				-- P + BodyShare * s; only a fake's lunge (FakeStepOut long) may
				-- lean the body past that, by at most its FakeStep share, which
				-- still sits inside the server's travel tolerance (0.55R + 1.5)
				local reach = HD.BodyShare * R
				if s.now < s.fakeUntil then
					reach = HD.BodyShare * R * (1 + HD.FakeStep)
				end
				local off = VecMath.flat(target - p).Magnitude
				expect(off <= reach + 0.05, "root target strayed from P")
				expect(off < HD.BodyShare * R + 1.5, "root target past the server travel tolerance")
			end
			expect(out.step.Magnitude <= R + 1e-3, "step longer than R")
		end
	end
	expect(frames >= 120000, "frames " .. frames)
	expect(worst <= Config.HardCap + 1e-4, "hard cap exceeded: " .. worst)
	print(string.format("       (fuzz %d frames, max horizontal speed %.2f / cap %d)", frames, worst, Config.HardCap))
end)

return nil
