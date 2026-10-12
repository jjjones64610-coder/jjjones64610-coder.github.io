local Vector3 = require("@lune/roblox").Vector3
local H = require("./harness")
local RulesEngine = H.require("Rules/RulesEngine")
local FieldGeometry = H.require("Rules/FieldGeometry")

local test, expect = H.test, H.expect

print("rules")

local field = FieldGeometry.new({ center = Vector3.new(0, 0, 0), width = 100, length = 190, endZone = 40, brick = 40 })

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
local EAST_EZ = Vector3.new(110, 0, 0)
local WEST_EZ = Vector3.new(-110, 0, 0)
local OUT = Vector3.new(0, 0, 60)

test("field regions and spots", function()
	expect(FieldGeometry.region(field, EAST_EZ) == "East", "east end zone")
	expect(FieldGeometry.region(field, OUT) == "Out", "out of bounds")
	local spot = FieldGeometry.turnoverSpot(field, Vector3.new(120, 0, 10))
	expect(spot.X == 95, "turnover in end zone moves to goal line: " .. spot.X)
	local exit = FieldGeometry.exitPoint(field, Vector3.new(0, 0, 0), Vector3.new(0, 0, 80))
	expect(math.abs(exit.Z - 49) < 0.6, "exit point on sideline: " .. exit.Z)
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
	local c = RulesEngine.catch(e, 2, "A", Vector3.new(50, 0, 0), true)
	expect(has(c, "Completion"), kinds(c))
	RulesEngine.throw(e, 2, Vector3.new(50, 0, 0))
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
	local c = RulesEngine.catch(e, 2, "A", Vector3.new(90, 0, 0), true)
	expect(not has(c, "Goal"), "no goal outside")
end)

test("airborne catch resolves on landing: in end zone = goal, out = turnover", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	RulesEngine.catch(e, 2, "A", Vector3.new(96, 5, 0), false, Vector3.new(90, 0, 0))
	local g = RulesEngine.land(e, 2, Vector3.new(100, 0, 0))
	expect(has(g, "Goal"), "landed in the end zone: " .. kinds(g))

	local e2 = liveMatch()
	RulesEngine.throw(e2, 1, MID)
	RulesEngine.catch(e2, 2, "A", Vector3.new(10, 5, 48), false, Vector3.new(10, 0, 45))
	local t = RulesEngine.land(e2, 2, Vector3.new(10, 0, 53))
	local to = has(t, "Turnover")
	expect(to and to.reason == "OutOfBounds" and to.team == "B", kinds(t))
end)

test("the Greatest: airborne past the line, release before landing", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	RulesEngine.catch(e, 2, "A", Vector3.new(10, 5, 49.5), false, Vector3.new(10, 0, 47))
	local t = RulesEngine.throw(e, 2, Vector3.new(10, 5, 52))
	expect(has(t, "Greatest"), kinds(t))
	local c = RulesEngine.catch(e, 3, "A", Vector3.new(10, 0, 30), true)
	expect(has(c, "Completion"), "possession kept")
end)

test("jumping from out of bounds makes the catch out", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	local c = RulesEngine.catch(e, 2, "A", Vector3.new(10, 5, 49), false, Vector3.new(10, 0, 52))
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
	local t = RulesEngine.ground(e, Vector3.new(30, 0, 70), Vector3.new(25, 0, 50))
	local to = has(t, "Turnover")
	expect(to.reason == "OutOfBounds" and math.abs(to.spot.Z) <= 49.01 and to.spot.X == 25, kinds(t))
end)

test("interception switches possession; Callahan scores for the defense", function()
	local e = liveMatch()
	RulesEngine.throw(e, 1, MID)
	local i = RulesEngine.catch(e, 9, "B", Vector3.new(20, 0, 0), true)
	expect(has(i, "Interception") and e.offense == "B", kinds(i))

	local e2 = liveMatch()
	RulesEngine.throw(e2, 1, Vector3.new(80, 0, 0))
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
	local r = RulesEngine.throw(e, 20, Vector3.new(100, 0, 0))
	expect(has(r, "PullReleased") and e.offense == "A", kinds(r))
	local l = RulesEngine.ground(e, Vector3.new(-60, 0, 10))
	expect(has(l, "PullLanded") and e.disc == "Ground" and e.offense == "A", kinds(l))

	local e2 = RulesEngine.new(field, { pointsToWin = 5, usePull = true })
	RulesEngine.startMatch(e2, "A", "East")
	RulesEngine.setupPoint(e2)
	RulesEngine.beginPull(e2, 20)
	RulesEngine.throw(e2, 20, Vector3.new(100, 0, 0))
	local o = RulesEngine.ground(e2, Vector3.new(-160, 0, 0))
	local pl = has(o, "PullLanded")
	expect(pl and pl.brick and pl.spot.X == -55, "brick at " .. tostring(pl and pl.spot))
end)

test("pull touched and dropped by the receivers is a turnover", function()
	local e = RulesEngine.new(field, { pointsToWin = 5, usePull = true })
	RulesEngine.startMatch(e, "A", "East")
	RulesEngine.setupPoint(e)
	RulesEngine.beginPull(e, 20)
	RulesEngine.throw(e, 20, Vector3.new(100, 0, 0))
	RulesEngine.touch(e, 1, "A")
	local t = RulesEngine.ground(e, Vector3.new(-80, 0, 0))
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
