local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local Abilities = H.require("Abilities")
local TechCore = H.require("Movement/TechCore")
local ThrowModel = H.require("Disc/ThrowModel")
local DiscPhysics = H.require("Disc/DiscPhysics")
local Config = H.require("Config/Tech")
local DiscConfig = H.require("Config/Disc")
local Shop = H.require("Config/Shop")
local Art = H.require("Config/Art")

local test, expect = H.test, H.expect
local T = DiscConfig.Throw
local FWD = Vector3.new(0, 0, -1)
local RIGHT = Vector3.new(1, 0, 0)
local GROUND = { grounded = true }
local AIR = { grounded = false }

print("abilities")

local function run(s, move, env, seconds)
	for _ = 1, math.floor(seconds * Config.PHYSICS_RATE + 0.5) do
		TechCore.step(s, { move = move }, env, TechCore.STEP)
	end
end

-- a fake character: just the attributes AbilityService stamps
local function stamped(id: string?, untilT: number)
	local attrs = { UBAbility = id, UBAbilityUntil = untilT }
	return {
		GetAttribute = function(_self, key: string)
			return attrs[key]
		end,
	} :: any
end

test("the framework finds every module in the folder; each is a complete Def", function()
	expect(#Abilities.Order >= 5, "at least the five starting abilities")
	local seenOrder = {}
	for _, id in Abilities.Order do
		local def = Abilities.List[id]
		expect(def.id == id and def.name ~= "" and def.desc ~= "", id .. ": id, name, desc")
		expect(def.cooldown >= 8, id .. ": a real cooldown")
		expect(def.duration >= 0 and def.duration < def.cooldown, id .. ": it ends before it is ready again")
		expect(def.price >= 0 and not seenOrder[def.order], id .. ": price and a unique order")
		seenOrder[def.order] = true
		expect(Art.ui(def.icon) ~= nil, id .. ": its icon exists in Config/Art")
		expect(def.start ~= nil or def.throw ~= nil or def.catchReach ~= nil, id .. ": it does something")
	end
	expect(Abilities.List[Abilities.Default].price == 0, "the default ability is free")
	expect(Abilities.get("Nope") == nil and Abilities.get(42) == nil, "unknown ids")
end)

test("the shop lists exactly the ability modules, at their own prices", function()
	expect(#Shop.Abilities == #Abilities.Order, "one entry each")
	for i, id in Abilities.Order do
		expect(Shop.Abilities[i].id == id and Shop.Abilities[i].price == Abilities.List[id].price, id)
	end
end)

test("active(): only while the stamp says so", function()
	expect(Abilities.active(stamped("Surge", 10), 9.9) == Abilities.List.Surge, "running")
	expect(Abilities.active(stamped("Surge", 10), 10) == nil, "over")
	expect(Abilities.active(stamped("Nope", 10), 5) == nil, "unknown id")
	expect(Abilities.active(nil, 5) == nil, "no character")
	expect(Abilities.catchReach(stamped("MagnetHands", 10), 5) == Abilities.List.MagnetHands.catchReach, "reach")
	expect(Abilities.catchReach(stamped("Surge", 10), 5) == 0, "no reach from another ability")
end)

test("Air Burst: only in the air; a shove toward the stick and the air action back", function()
	local def = Abilities.List.AirBurst
	expect(not def.canUse({ grounded = true, holding = false }), "not on the ground")
	expect(not def.canUse({ grounded = false, holding = true }), "not with the disc")
	expect(def.canUse({ grounded = false, holding = false }), "in the air")
	expect(def.canUse({ grounded = nil, holding = false }), "the server's unknown counts as fine")

	local s = TechCore.new(0)
	s.vel = FWD * Config.RUN_TOP_SPEED
	run(s, FWD, GROUND, 0.05)
	def.start(s, RIGHT)
	expect(#s.events == 0, "nothing on the ground")
	TechCore.press(s, "Jump", s.now)
	run(s, FWD, GROUND, 0.02)
	run(s, FWD, AIR, 0.1)
	TechCore.press(s, "Jump", s.now) -- spend the air action (a Sky Reach)
	run(s, Vector3.zero, AIR, 0.02)
	expect(not s.dodgeAvailable, "air action spent")
	local before = s.vel
	def.start(s, RIGHT)
	expect(s.dodgeAvailable, "air action back")
	expect((s.vel - before):Dot(RIGHT) > 8 and s.vel.Y > before.Y, "a burst to the right and up")
end)

test("Surge: faster for its duration, then back to normal", function()
	local def = Abilities.List.Surge
	local s = TechCore.new(0)
	s.vel = FWD * Config.RUN_TOP_SPEED
	def.start(s, FWD)
	run(s, FWD, GROUND, 1.5)
	expect(TechCore.flatSpeed(s) > Config.RUN_TOP_SPEED + 5, "surging: " .. TechCore.flatSpeed(s))
	run(s, FWD, GROUND, def.duration + 1.5)
	expect(TechCore.flatSpeed(s) < Config.RUN_TOP_SPEED + 0.5, "back to run speed")
	expect(not def.canUse({ grounded = true, holding = true }), "not with the disc")
end)

local P = Vector3.new(0, 3, 0)
local function land(p)
	local l = ThrowModel.launch(p, P, Vector3.zero)
	local r = DiscPhysics.simulate(l.state, 9, nil, 0, 1)
	return r.samples[#r.samples].x, l
end
local function params(side: number, hold: number)
	local kind, bank = ThrowModel.shape(side, math.rad(8), hold)
	return { throwType = kind, yaw = 0, pitch = math.rad(8), holdTime = hold, bank = bank, height = "Mid", pivot = P }
end

test("Curveball: a bent throw bends about twice as far; a flat one is unchanged", function()
	local snap = T.SnapPoint * T.ChargeTime
	local plain = land(params(-1, snap))
	local p = params(-1, snap)
	local used = Abilities.applyThrow(stamped("Curveball", 10), 5, p)
	expect(used == Abilities.List.Curveball and used.spendOnThrow, "the hook ran, and the throw spends it")
	local curved = land(p)
	expect(curved < plain * 1.5, string.format("more curve: %.1f vs %.1f", curved, plain))
	local flat = params(0, snap)
	Abilities.applyThrow(stamped("Curveball", 10), 5, flat)
	expect(flat.bank == 0, "a flat throw stays flat")
	expect(Abilities.applyThrow(stamped("Curveball", 10), 11, params(-1, snap)) == nil, "not after it ran out")
end)

test("Focus: a near-miss release leaves as a Perfect; a bad one does not; you hang in the air", function()
	local def = Abilities.List.Focus
	local snap = T.SnapPoint * T.ChargeTime
	local off = params(0, snap + 0.06) -- outside the normal Perfect window
	local _, before = land(off)
	expect(before.quality ~= "Perfect", "normally not Perfect")
	Abilities.applyThrow(stamped("Focus", 10), 5, off)
	local _, after = land(off)
	expect(after.quality == "Perfect", "with Focus it is")
	local bad = params(0, snap + 0.25)
	Abilities.applyThrow(stamped("Focus", 10), 5, bad)
	local _, still = land(bad)
	expect(still.quality ~= "Perfect", "a bad release is still bad")

	local function airtime(focus: boolean): number
		local s = TechCore.new(0)
		if focus then
			def.start(s, Vector3.zero)
		end
		TechCore.press(s, "Jump", s.now)
		run(s, Vector3.zero, GROUND, 0.02)
		local y, t = 0.1, 0
		while y > 0 and t < 5 do
			TechCore.step(s, { move = Vector3.zero }, AIR, TechCore.STEP)
			y += s.vel.Y * TechCore.STEP
			t += TechCore.STEP
		end
		return t
	end
	expect(airtime(true) > airtime(false) * 1.4, "a longer hang")
end)

test("the server cannot be told to assist a release: sanitize drops snapAssist", function()
	local p =
		ThrowModel.sanitize({ throwType = "Backhand", yaw = 0, pitch = 0, holdTime = 0.5, bank = 0, snapAssist = 5 })
	expect(p ~= nil and (p :: any).snapAssist == nil, "client-sent snapAssist is ignored")
end)

return nil
