local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local RulesEngine = H.require("Rules/RulesEngine")
local FieldGeometry = H.require("Rules/FieldGeometry")
local Modes = H.require("Config/Modes")

local test, expect = H.test, H.expect

print("rules")

-- Explicit fixture with the Normal field's numbers; every position below is
-- derived from it so the rules are checked relative to the lines.
local field = FieldGeometry.new({ center = Vector3.new(0, 0, 0), width = 136, length = 240, endZone = 60, brick = 64 })
local HL, HW, EZ = field.halfLength, field.halfWidth, field.endZone

local function kinds(outcomes)
	local k = {}
	for _, o in outcomes do
		table.insert(k, o.kind)
	end
	return table.concat(k, ",")
end

local function has(outcomes, kind)
	for _, o in outcomes do
		if o.kind == kind then
			return o
		end
	end
	return nil
end

local function liveMatch(points)
	local e = RulesEngine.new(field, { pointsToWin = points or 5, usePull = false })
	RulesEngine.startMatch(e, "A", "East")
	RulesEngine.setupPoint(e)
	RulesEngine.beginLive(e, 1)
	return e
end

local MID = Vector3.new(0, 0, 0)
local EAST_EZ = Vector3.new(HL + EZ / 2, 0, 0)
local WEST_EZ = Vector3.new(-HL - EZ / 2, 0, 0)
local OUT = Vector3.new(0, 0, HW + 10)

test("field regions and spots", function()
	expect(FieldGeometry.region(field, EAST_EZ) == "East", "east end zone")
	expect(FieldGeometry.region(field, WEST_EZ) == "West", "west end zone")
	expect(FieldGeometry.region(field, MID) == "Field", "midfield")
	expect(FieldGeometry.region(field, OUT) == "Out", "out of bounds")
	expect(FieldGeometry.region(field, Vector3.new(HL + EZ + 1, 0, 0)) == "Out", "past the back line")
	local spot = FieldGeometry.turnoverSpot(field, Vector3.new(HL + EZ * 0.6, 0, 10))
	expect(spot.X == HL, "turnover in end zone moves to goal line: " .. spot.X)
	local exit = FieldGeometry.exitPoint(field, Vector3.new(0, 0, 0), Vector3.new(0, 0, HW + 30))
	expect(math.abs(exit.Z - (HW - 1)) < 0.6, "exit point on sideline: " .. exit.Z)
end)

test("both configured fields have the same regions relative to their lines", function()
	for name, spec in Modes.Fields do
		local f = FieldGeometry.new({
			center = Vector3.new(0, 0, 0),
			width = spec.width,
			length = spec.length,
			endZone = spec.endZone,
			brick = spec.brick,
		})
		local hl, hw = f.halfLength, f.halfWidth
		expect(FieldGeometry.region(f, Vector3.new(hl - 1, 0, 0)) == "Field", name .. " field side of the line")
		expect(FieldGeometry.region(f, Vector3.new(hl + 1, 0, 0)) == "East", name .. " end zone side")
		expect(FieldGeometry.region(f, Vector3.new(0, 0, hw + 1)) == "Out", name .. " sideline")
		local brick = FieldGeometry.brickPoint(f, "West")
		expect(brick.X == -hl + spec.brick and FieldGeometry.region(f, brick) == "Field", name .. " brick")
	end
end)

test("line-ups: 7 fit behind the Normal goal line, spaced and inside the sidelines", function()
	for _, side in { "East", "West" } do
		local spots = FieldGeometry.lineup(field, side, 7)
		local lineX, lineSide = FieldGeometry.lineRestriction(field, side)
		expect(lineX == FieldGeometry.goalLineX(field, side), "restriction is the goal line")
		local sumZ = 0
		for i, p in spots do
			sumZ += p.Z
			expect((p.X - lineX) * lineSide > 0, side .. ": behind the goal line")
			expect(FieldGeometry.region(field, p) == side, side .. ": in the end zone")
			expect(math.abs(p.Z) <= HW - FieldGeometry.LineupSidelineGap + 1e-6, side .. ": room at the sideline")
			expect(FieldGeometry.offsideBy(field, p, side) == 0, side .. ": not offside")
			if i > 1 then
				expect(p.Z - spots[i - 1].Z >= FieldGeometry.LineupPitch, side .. ": spaced")
			end
		end
		expect(math.abs(sumZ) < 1e-6, side .. ": centred")
	end
	expect(FieldGeometry.lineup(field, "East", 1)[1].Z == 0, "one player stands in the middle")
	local spot = FieldGeometry.lineupSpot(field, "West", 99, 3)
	local last = FieldGeometry.lineup(field, "West", 3)[3]
	expect(spot == last, "index clamps to the line")
	-- a narrow field squeezes the line instead of spilling past the sidelines
	local narrow = FieldGeometry.new({ center = Vector3.new(0, 0, 0), width = 40, length = 100, endZone = 20 })
	for _, p in FieldGeometry.lineup(narrow, "East", 7) do
		expect(math.abs(p.Z) <= narrow.halfWidth - FieldGeometry.LineupSidelineGap + 1e-6, "squeezed")
	end
end)

test("goal line restriction: offside distance and pull-back behind the line", function()
	local f = FieldGeometry.new({ center = Vector3.new(10, 2, -5), width = 90, length = 160, endZone = 40 })
	expect(FieldGeometry.goalLineX(f, "East") == 10 + 80 and FieldGeometry.goalLineX(f, "West") == 10 - 80, "world x")
	local lx, ls = FieldGeometry.lineRestriction(f, "West")
	expect(lx == -70 and ls == -1, "west restriction")
	local into = Vector3.new(-70 + 5, 3.2, 20)
	expect(math.abs(FieldGeometry.offsideBy(f, into, "West") - 5) < 1e-9, "5 studs offside")
	local back = FieldGeometry.behindLine(f, into, "West", 2)
	expect((back.X - lx) * ls >= 2 - 1e-9, "pulled 2 studs behind the line")
	expect(back.Y == into.Y and back.Z == into.Z, "only X changes")
	local fine = Vector3.new(-70 - 10, 3.2, 0)
	expect(FieldGeometry.behindLine(f, fine, "West", 2) == fine, "already behind: unchanged")
	local wide = FieldGeometry.behindLine(f, Vector3.new(-60, 0, 200), "West")
	expect(math.abs(wide.Z - f.center.Z) <= f.halfWidth, "kept inside the sidelines")
	local deep = FieldGeometry.behindLine(f, Vector3.new(-500, 0, 0), "West")
	expect(deep.X >= -70 - 40, "kept inside the end zone")
end)

test("benches: off the field on the -Z sideline, A west of midfield and B east", function()
	local a = FieldGeometry.benchSpots(field, -1, 3)
	local b = FieldGeometry.benchSpots(field, 1, 3)
	for _, p in a do
		expect(FieldGeometry.region(field, p) == "Out" and p.Z < -HW, "A bench off the field")
		expect(p.X < 0, "A bench on the west half")
	end
	for _, p in b do
		expect(FieldGeometry.region(field, p) == "Out" and p.Z < -HW, "B bench off the field")
		expect(p.X > 0, "B bench on the east half")
	end
	expect(a[1] ~= a[2] and a[2] ~= a[3], "distinct seats")
end)

test("setup lines teams up in the end zones they defend", function()
	local e = RulesEngine.new(field, { pointsToWin = 5, usePull = true })
	RulesEngine.startMatch(e, "A", "East")
	local s = RulesEngine.setupPoint(e)
	expect(
		s.offense == "A" and s.offenseLine == "West" and s.defenseLine == "East",
		kinds({ s }) .. " " .. s.offenseLine
	)
end)

test("completion, then a grounded catch in the attacking end zone scores", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	local c = RulesEngine.catch(e, 2, "A", Vector3.new(HL / 2, 0, 0), true)
	expect(has(c, "Completion"), kinds(c))
	RulesEngine.throw(e, 2, Vector3.new(HL / 2, 0, 0))
	local g = RulesEngine.catch(e, 3, "A", EAST_EZ, true)
	local goal = has(g, "Goal")
	expect(goal and goal.team == "A" and goal.assist == 2 and goal.scorer == 3, kinds(g))
	expect(
		e.offense == "B" and e.attack.A == "West" and e.attack.B == "East",
		"teams switch direction, scored-on team receives"
	)
end)

test("you cannot score by catching outside and running in (catch counts where you land)", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	local c = RulesEngine.catch(e, 2, "A", Vector3.new(HL - 5, 0, 0), true)
	expect(not has(c, "Goal"), "no goal outside")
end)

test("airborne catch resolves on landing: in end zone = goal, out = turnover", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	RulesEngine.catch(e, 2, "A", Vector3.new(HL + 1, 5, 0), false, Vector3.new(HL - 5, 0, 0))
	local g = RulesEngine.land(e, 2, Vector3.new(HL + 5, 0, 0))
	expect(has(g, "Goal"), "landed in the end zone: " .. kinds(g))

	local e2 = liveMatch()
	RulesEngine.throw(e2, 1, MID)
	RulesEngine.catch(e2, 2, "A", Vector3.new(10, 5, HW - 2), false, Vector3.new(10, 0, HW - 5))
	local t = RulesEngine.land(e2, 2, Vector3.new(10, 0, HW + 3))
	local to = has(t, "Turnover")
	expect(to and to.reason == "OutOfBounds" and to.team == "B", kinds(t))
end)

test("the Greatest: airborne past the line, release before landing", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	RulesEngine.catch(e, 2, "A", Vector3.new(10, 5, HW - 0.5), false, Vector3.new(10, 0, HW - 3))
	local t = RulesEngine.throw(e, 2, Vector3.new(10, 5, HW + 2))
	expect(has(t, "Greatest"), kinds(t))
	local c = RulesEngine.catch(e, 3, "A", Vector3.new(10, 0, HW - 20), true)
	expect(has(c, "Completion"), "possession kept")
end)

test("jumping from out of bounds makes the catch out", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	local c = RulesEngine.catch(e, 2, "A", Vector3.new(10, 5, HW - 1), false, Vector3.new(10, 0, HW + 2))
	expect(has(c, "Turnover"), kinds(c))
end)

test("incomplete pass is a turnover at the landing spot", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	local t = RulesEngine.ground(e, Vector3.new(40, 0, 10))
	local to = has(t, "Turnover")
	expect(to and to.reason == "Incomplete" and to.team == "B" and to.spot.X == 40, kinds(t))
	expect(#RulesEngine.pickup(e, 7, "A") == 0, "old offense cannot pick up")
	expect(has(RulesEngine.pickup(e, 8, "B"), "Pickup"), "new offense picks up")
end)

test("blocked disc is a Block turnover; a dropped disc is a Drop", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	expect(has(RulesEngine.touch(e, 9, "B"), "Block"), "block recorded")
	local t = RulesEngine.ground(e, Vector3.new(20, 0, 0))
	expect(has(t, "Turnover").reason == "Block", kinds(t))

	local e2 = liveMatch()
	RulesEngine.throw(e2, 1, MID)
	RulesEngine.touch(e2, 2, "A")
	expect(has(RulesEngine.ground(e2, Vector3.new(20, 0, 0)), "Turnover").reason == "Drop", "drop")
end)

test("out-of-bounds disc comes back in where it crossed", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	local t = RulesEngine.ground(e, Vector3.new(30, 0, HW + 20), Vector3.new(25, 0, HW))
	local to = has(t, "Turnover")
	expect(to.reason == "OutOfBounds" and math.abs(to.spot.Z) <= HW - 1 + 0.01 and to.spot.X == 25, kinds(t))
end)

test("interception switches possession; Callahan scores for the defense", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	local i = RulesEngine.catch(e, 9, "B", Vector3.new(20, 0, 0), true)
	expect(has(i, "Interception") and e.offense == "B", kinds(i))

	local e2 = liveMatch()
	RulesEngine.throw(e2, 1, Vector3.new(HL - 15, 0, 0))
	local c = RulesEngine.catch(e2, 9, "B", EAST_EZ, true)
	local goal = has(c, "Goal")
	expect(goal and goal.callahan and goal.team == "B", "callahan: " .. kinds(c))
end)

test("stall out gives the disc to the defense at the thrower's feet", function()
	local e = liveMatch()
	local t = RulesEngine.stall(e, Vector3.new(-30, 0, 5))
	local to = has(t, "Turnover")
	expect(to and to.reason == "Stall" and to.team == "B" and to.spot.X == -30, kinds(t))
end)

test("pull: lands in -> receiving team takes it there; lands out -> brick", function()
	local e = RulesEngine.new(field, { pointsToWin = 5, usePull = true })
	RulesEngine.startMatch(e, "A", "East")
	RulesEngine.setupPoint(e)
	RulesEngine.beginPull(e, 20)
	local r = RulesEngine.throw(e, 20, Vector3.new(HL + 2, 0, 0))
	expect(has(r, "PullReleased") and e.offense == "A", kinds(r))
	local l = RulesEngine.ground(e, Vector3.new(-HL / 2, 0, 10))
	expect(has(l, "PullLanded") and e.disc == "Ground" and e.offense == "A", kinds(l))

	local e2 = RulesEngine.new(field, { pointsToWin = 5, usePull = true })
	RulesEngine.startMatch(e2, "A", "East")
	RulesEngine.setupPoint(e2)
	RulesEngine.beginPull(e2, 20)
	RulesEngine.throw(e2, 20, Vector3.new(HL + 2, 0, 0))
	local o = RulesEngine.ground(e2, Vector3.new(-(HL + EZ + 25), 0, 0))
	local pl = has(o, "PullLanded")
	-- receivers (A) defend West: the brick is `brick` studs in from the West goal line
	expect(pl and pl.brick and pl.spot.X == -HL + field.brick, "brick at " .. tostring(pl and pl.spot))
end)

test("pull touched and dropped by the receivers is a turnover", function()
	local e = RulesEngine.new(field, { pointsToWin = 5, usePull = true })
	RulesEngine.startMatch(e, "A", "East")
	RulesEngine.setupPoint(e)
	RulesEngine.beginPull(e, 20)
	RulesEngine.throw(e, 20, Vector3.new(HL + 2, 0, 0))
	RulesEngine.touch(e, 1, "A")
	local t = RulesEngine.ground(e, Vector3.new(-HL * 0.7, 0, 0))
	local to = has(t, "Turnover")
	expect(to and to.team == "B", kinds(t))
end)

test("match ends at the target score; game point at 4-4 is universe", function()
	local e = liveMatch(5)
	e.score = { A = 4, B = 4 }
	RulesEngine.throw(e, 1, MID)
	local o = RulesEngine.catch(e, 2, "A", EAST_EZ, true)
	local over = has(o, "MatchOver")
	expect(over and over.winner == "A", kinds(o))

	local e2 = liveMatch(5)
	e2.score = { A = 4, B = 3 }
	RulesEngine.throw(e2, 1, MID)
	RulesEngine.catch(e2, 9, "B", Vector3.new(-50, 0, 0), true)
	RulesEngine.throw(e2, 9, Vector3.new(-50, 0, 0))
	local u = RulesEngine.catch(e2, 10, "B", WEST_EZ, true)
	expect(has(u, "UniversePoint") and not has(u, "MatchOver"), kinds(u))
end)

test("time cap: leader wins between points; tie becomes universe point", function()
	local e = liveMatch(7)
	e.score = { A = 3, B = 2 }
	e.phase = "PointOver"
	local o = RulesEngine.reachCap(e)
	expect(has(o, "MatchOver"), kinds(o))

	local e2 = liveMatch(7)
	e2.score = { A = 2, B = 2 }
	e2.phase = "PointOver"
	local u = RulesEngine.reachCap(e2)
	expect(has(u, "UniversePoint") and e2.universe, kinds(u))
	-- during a live point the cap only flags; the point finishes first
	local e3 = liveMatch(7)
	e3.score = { A = 3, B = 2 }
	local f = RulesEngine.reachCap(e3)
	expect(not has(f, "MatchOver") and e3.capReached, kinds(f))
	RulesEngine.throw(e3, 1, MID)
	local g = RulesEngine.catch(e3, 2, "A", EAST_EZ, true)
	expect(has(g, "MatchOver"), "point after cap decides it: " .. kinds(g))
end)

return nil
