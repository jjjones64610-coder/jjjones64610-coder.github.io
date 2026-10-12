--!strict
--[[
	TrainingService — drills with actionable feedback.

	Every drill reports WHY something worked or failed in plain terms:
	gate splits and where speed was lost, reversal times with the technique
	that would shorten them, how far a missed catch was and in which
	direction, a throw's release quality, spin, bank and miss vector, and the
	defender's distance from the passing lane at release.

	Drills: Tutorial (Movement School), Cutting, Shuttle, Aerial, Range,
	Interception, Combo (lab challenges), Launcher (free, custom launches).
	Each session owns its own training disc; drills never touch the match.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local ArenasConfig = require(Shared.Config.Arenas)
local DiscConfig = require(Shared.Config.Disc)
local MovementConfig = require(Shared.Config.Movement)
local ThrowModel = require(Shared.Disc.ThrowModel)
local Solver = require(Shared.Disc.Solver)
local VecMath = require(Shared.Util.VecMath)
local TrainingBuilder = require(script.Parent.Parent.Arena.TrainingBuilder)

local TrainingService = {}

local services: any
local layout: TrainingBuilder.Layout

export type Session = {
	actor: any,
	player: Player?,
	drill: string,
	phase: string,
	t0: number,
	data: { [string]: any },
	disc: any?,
	bots: { number },
	ended: boolean,
}

local sessions: { [number]: Session } = {}
local stopDrill: (actor: any) -> ()

local function now(): number
	return Net.now()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function send(s: Session, kind: string, payload: any)
	if s.player then
		Net.event("Feedback"):FireClient(s.player, kind, payload)
	end
end

local function hud(s: Session, title: string, text: string, extra: { [string]: any }?)
	local payload: { [string]: any } = { drill = s.drill, title = title, text = text }
	if extra then
		for k, v in extra do
			payload[k] = v
		end
	end
	send(s, "DrillHud", payload)
end

local function report(s: Session, title: string, lines: { string }, extra: { [string]: any }?)
	local payload: { [string]: any } = { drill = s.drill, title = title, lines = lines }
	if extra then
		for k, v in extra do
			payload[k] = v
		end
	end
	send(s, "Drill", payload)
end

local function root(s: Session): BasePart?
	return services.PlayerService.root(s.actor)
end

local function teleport(s: Session, pos: Vector3, facing: Vector3?)
	local f = facing or Vector3.new(0, 0, 1)
	services.PlayerService.teleport(s.actor, CFrame.lookAt(pos, pos + f))
end

---------------------------------------------------------------------------
-- session disc
---------------------------------------------------------------------------

local DRILLS: { [string]: any } = {}

local function discFor(s: Session): any
	if s.disc then
		return s.disc
	end
	local handler = {} :: any
	function handler.canClaim(_d: any, id: number, _team: string): boolean
		return id == s.actor.id or table.find(s.bots, id) ~= nil
	end
	function handler.canThrow(_d: any, id: number): boolean
		return id == s.actor.id or table.find(s.bots, id) ~= nil
	end
	function handler.onCaught(d: any, info: any)
		local drill = DRILLS[s.drill]
		if drill and drill.onCaught then
			drill.onCaught(s, d, info)
		end
	end
	function handler.onTouched(d: any, info: any)
		local drill = DRILLS[s.drill]
		if drill and drill.onTouched then
			drill.onTouched(s, d, info)
		end
	end
	function handler.onThrown(d: any, info: any)
		local drill = DRILLS[s.drill]
		if drill and drill.onThrown then
			drill.onThrown(s, d, info)
		end
	end
	function handler.onGrounded(d: any, land: Vector3, samples: any)
		local drill = DRILLS[s.drill]
		if drill and drill.onGrounded then
			drill.onGrounded(s, d, land, samples)
		else
			services.DiscService.placeOnGround(d, land)
		end
	end
	local d = services.DiscService.create("Training", s.actor.id, handler)
	if s.player then
		services.DiscService.setSkin(d, services.ProgressionService.equipped(s.player, "disc"))
	end
	s.disc = d
	return d
end

local function launchAt(s: Session, origin: Vector3, target: Vector3, throwType: string, bank: number?, floaty: boolean?): any
	local d = discFor(s)
	local sol = Solver.solve({
		rootPos = origin,
		throwType = throwType,
		bank = bank or 0,
		target = target,
		groundY = layout.origin.Y,
		flightTimeWeight = if floaty then 0.05 else 0.6,
		coarse = true,
	})
	if not sol then
		return nil
	end
	services.ThrowService.launchFrom(d, sol.params, origin, { noCatch = 0.1 })
	return sol
end

local function finish(s: Session, title: string, lines: { string }, pbKey: string?, value: number?, lowerIsBetter: boolean?)
	if s.ended then
		return
	end
	s.ended = true
	local isPB = false
	if pbKey and value and s.player then
		local prev = nil
		local data = services.DataService.get(s.player)
		if data then
			prev = data.personalBests[pbKey]
		end
		isPB = services.ProgressionService.recordPersonalBest(s.player, pbKey, value, lowerIsBetter == true)
		if prev ~= nil then
			table.insert(lines, if isPB then "NEW PERSONAL BEST!" else string.format("Personal best: %s", tostring(prev)))
		else
			table.insert(lines, "First completion recorded.")
		end
	end
	report(s, title, lines, { done = true, pb = isPB })
	stopDrill(s.actor)
end

---------------------------------------------------------------------------
-- Movement School
---------------------------------------------------------------------------

local TUTORIAL: { any } = {
	{ text = "Hold SHIFT and run (WASD) to sprint.", kind = "speed" },
	{ text = "SNAP CUT: while sprinting press Q and steer 45-90 degrees to the side.", tech = "SnapCut" },
	{ text = "MOMENTUM CANCEL: sprint, then press Q while steering BACKWARD to plant.", tech = "MomentumCancel" },
	{ text = "RESTART: plant again, then press Q with a direction 0.1-0.3 s later.", tech = "SnapCut", info = "Restart" },
	{ text = "BURST STEP: press F to explode into space (it has a cooldown).", tech = "BurstStep" },
	{ text = "FAKE COMMIT: press Q while running straight (jab), then Q again to cut away.", tech = "SnapCut", info = "Sold" },
	{ text = "SLIDE: sprint and press CTRL (or C).", tech = "Slide" },
	{ text = "SLIDE CUT: during a slide, press Q with a new direction.", tech = "SlideCut" },
	{ text = "AIR REDIRECT: jump (SPACE), then press Q with a direction in the air.", tech = "AirRedirect" },
	{ text = "PRECISION LANDING: press CTRL just before you touch down.", tech = "PrecisionLanding" },
	{ text = "LAYOUT: press E to dive.", tech = "Dive" },
	{ text = "RECOVERY CHAIN: as your dive slide stops, press Q, F or SPACE.", tech = "RecoveryChain" },
	{ text = "CATCH: run to the disc. Click (Reach) for ones outside your body.", kind = "catch" },
	{ text = "THROW: hold LEFT MOUSE and release at the peak of the meter (PERFECT).", kind = "throw" },
}

local function tutorialShow(s: Session)
	local step = TUTORIAL[s.data.step]
	hud(s, string.format("MOVEMENT SCHOOL  %d/%d", s.data.step, #TUTORIAL), step.text, { progress = (s.data.step - 1) / #TUTORIAL })
	if step.kind == "catch" then
		local r = root(s)
		if r then
			local origin = r.Position + VecMath.flatUnit(r.CFrame.LookVector) * 40 + Vector3.new(0, 0, 0)
			task.delay(1.0, function()
				if sessions[s.actor.id] == s and TUTORIAL[s.data.step].kind == "catch" then
					launchAt(s, origin, r.Position + Vector3.new(0, 1.5, 0), "Backhand", 0, true)
				end
			end)
		end
	elseif step.kind == "throw" then
		services.DiscService.giveTo(discFor(s), s.actor.id)
	end
end

local function tutorialAdvance(s: Session)
	s.data.step += 1
	send(s, "DrillTick", { text = "Nice!" })
	if s.data.step > #TUTORIAL then
		finish(s, "MOVEMENT SCHOOL COMPLETE", {
			"You know the whole vocabulary.",
			"Next: Combo Lab to chain them, Cutting Course to use them at speed.",
		}, "Tutorial", 1, false)
		return
	end
	tutorialShow(s)
end

DRILLS.Tutorial = {
	start = function(s: Session)
		s.data.step = 1
		tutorialShow(s)
	end,
	step = function(s: Session)
		local step = TUTORIAL[s.data.step]
		if step and step.kind == "speed" then
			local t = services.MovementService.track(s.actor.id)
			if t and flat(t.vel).Magnitude >= MovementConfig.SprintSpeed - 4 then
				tutorialAdvance(s)
			end
		end
	end,
	onTech = function(s: Session, tech: string, _quality: string, info: string?)
		local step = TUTORIAL[s.data.step]
		if step and step.tech == tech and (step.info == nil or step.info == info) then
			tutorialAdvance(s)
		end
	end,
	onCaught = function(s: Session, _d: any, _info: any)
		local step = TUTORIAL[s.data.step]
		if step and step.kind == "catch" then
			tutorialAdvance(s)
		end
	end,
	onGrounded = function(s: Session, d: any, land: Vector3)
		services.DiscService.placeOnGround(d, land)
		local step = TUTORIAL[s.data.step]
		if step and step.kind == "catch" then
			send(s, "DrillTick", { text = "Missed — here comes another." })
			tutorialShow(s)
		elseif step and step.kind == "throw" then
			task.delay(0.8, function()
				if sessions[s.actor.id] == s then
					services.DiscService.giveTo(d, s.actor.id)
				end
			end)
		end
	end,
	onThrown = function(s: Session, d: any, info: any)
		local step = TUTORIAL[s.data.step]
		if step and step.kind == "throw" then
			if info.launch.quality == "Perfect" then
				tutorialAdvance(s)
			else
				send(s, "DrillTick", {
					text = if info.launch.quality == "Over"
						then "Held too long (spin lost). Release right as the meter peaks."
						else "Released early. Hold until the meter fills, then let go.",
				})
			end
		end
		local _ = d
	end,
}

---------------------------------------------------------------------------
-- Cutting course
---------------------------------------------------------------------------

DRILLS.Cutting = {
	start = function(s: Session)
		local st = layout.stations.Cutting
		teleport(s, st.start + Vector3.new(0, 3, 0), st.facing)
		s.data.gate = 1
		s.data.splits = {}
		s.data.minSpeed = {}
		s.data.penalty = 0
		s.data.techs = 0
		s.data.lastZ = nil
		hud(s, "CUTTING COURSE", "Cross the green gate to start. Weave through every gate.", { progress = 0 })
	end,
	step = function(s: Session)
		local r = root(s)
		if not r then
			return
		end
		local pos = r.Position
		local gates = layout.gates
		local g = gates[s.data.gate]
		if not g then
			return
		end
		local lastZ = s.data.lastZ or pos.Z
		s.data.lastZ = pos.Z
		if s.data.startAt then
			local sp = flat(r.AssemblyLinearVelocity).Magnitude
			local i = s.data.gate
			s.data.minSpeed[i] = math.min(s.data.minSpeed[i] or math.huge, sp)
			if now() - s.data.startAt > 60 then
				finish(s, "CUTTING COURSE", { "Timed out after 60 s." })
				return
			end
		end
		if lastZ < g.a.Z and pos.Z >= g.a.Z then
			local inside = pos.X >= g.a.X - 0.8 and pos.X <= g.b.X + 0.8
			if not inside then
				s.data.penalty += 2
				send(s, "DrillTick", { text = "Missed gate " .. s.data.gate .. " (+2 s)" })
			end
			if s.data.gate == 1 then
				s.data.startAt = now()
			else
				table.insert(s.data.splits, { gate = s.data.gate, t = now() - s.data.startAt, speed = flat(r.AssemblyLinearVelocity).Magnitude })
			end
			s.data.gate += 1
			hud(s, "CUTTING COURSE", string.format("Gate %d / %d", math.min(s.data.gate, #gates), #gates), {
				timerStart = s.data.startAt,
				progress = (s.data.gate - 1) / #gates,
			})
			if s.data.gate > #gates then
				local total = now() - s.data.startAt + s.data.penalty
				local lines = { string.format("Time: %.2f s (penalties %d s)", total, s.data.penalty) }
				local worst, worstGate = math.huge, 0
				for i = 2, #gates do
					local m = s.data.minSpeed[i]
					if m and m < worst then
						worst, worstGate = m, i
					end
				end
				if worstGate > 0 then
					table.insert(lines, string.format("Slowest section: before gate %d (dropped to %.0f studs/s).", worstGate, worst))
					if worst < 12 then
						table.insert(lines, "Tip: cut earlier and cleaner — a committed line before a Snap Cut keeps up to 96% of your speed.")
					elseif worst < 18 then
						table.insert(lines, "Tip: chain Snap Cut -> Burst Step within 0.15 s for a Perfect burst out of the turn.")
					else
						table.insert(lines, "You held speed all the way. Try Slide Cuts on the tight gates.")
					end
				end
				table.insert(lines, string.format("Techniques used: %d", s.data.techs))
				finish(s, "CUTTING COURSE", lines, "Cutting", math.floor(total * 100) / 100, true)
			end
		end
	end,
	onTech = function(s: Session)
		if s.data.startAt then
			s.data.techs += 1
		end
	end,
}

---------------------------------------------------------------------------
-- Momentum shuttle
---------------------------------------------------------------------------

DRILLS.Shuttle = {
	start = function(s: Session)
		local st = layout.stations.Shuttle
		teleport(s, st.start + Vector3.new(0, 3, 0), st.facing)
		s.data.leg = 0
		s.data.reversals = {}
		s.data.lastZ = nil
		s.data.crossedAt = nil
		hud(s, "MOMENTUM SHUTTLE", "Run north across the green line to start: A -> B -> A -> B -> A", { progress = 0 })
	end,
	step = function(s: Session)
		local r = root(s)
		if not r then
			return
		end
		local z = r.Position.Z
		local lastZ = s.data.lastZ or z
		s.data.lastZ = z
		local A, B = layout.shuttleA, layout.shuttleB
		local leg = s.data.leg
		local function crossed(line: number, north: boolean): boolean
			if north then
				return lastZ < line and z >= line
			end
			return lastZ > line and z <= line
		end
		if leg == 0 and crossed(A, true) then
			s.data.startAt = now()
			s.data.leg = 1
		elseif leg == 1 and crossed(B, true) then
			s.data.turnAt = now()
			s.data.leg = 2
		elseif leg == 2 and crossed(B, false) then
			table.insert(s.data.reversals, { line = "B", t = now() - s.data.turnAt })
			s.data.leg = 3
		elseif leg == 3 and crossed(A, false) then
			s.data.turnAt = now()
			s.data.leg = 4
		elseif leg == 4 and crossed(A, true) then
			table.insert(s.data.reversals, { line = "A", t = now() - s.data.turnAt })
			s.data.leg = 5
		elseif leg == 5 and crossed(B, true) then
			s.data.turnAt = now()
			s.data.leg = 6
		elseif leg == 6 and crossed(B, false) then
			table.insert(s.data.reversals, { line = "B", t = now() - s.data.turnAt })
			s.data.leg = 7
		elseif leg == 7 and crossed(A, false) then
			local total = now() - s.data.startAt
			local lines = { string.format("Time: %.2f s", total) }
			local best = math.huge
			for i, rv in s.data.reversals do
				best = math.min(best, rv.t)
				local verdict = if rv.t < 0.3
					then "elite"
					elseif rv.t < 0.5 then "good"
					else "slow — plant with Momentum Cancel (Q backward) and restart 0.1-0.3 s later"
				table.insert(lines, string.format("Reversal %d at %s: %.2f s (%s)", i, rv.line, rv.t, verdict))
			end
			finish(s, "MOMENTUM SHUTTLE", lines, "Shuttle", math.floor(total * 100) / 100, true)
			return
		end
		if s.data.startAt then
			hud(s, "MOMENTUM SHUTTLE", string.format("Leg %d / 4", math.clamp(math.ceil(s.data.leg / 2), 1, 4)), {
				timerStart = s.data.startAt,
				progress = s.data.leg / 7,
			})
			if now() - s.data.startAt > 40 then
				finish(s, "MOMENTUM SHUTTLE", { "Timed out." })
			end
		end
	end,
}

---------------------------------------------------------------------------
-- Aerial catch
---------------------------------------------------------------------------

local AERIAL: { any } = {
	{ x = 0, z = 0, h = 4.5, type = "Backhand", label = "Chest-high floater", floaty = true },
	{ x = -10, z = 4, h = 8.5, type = "Backhand", label = "High floater: jump", floaty = true },
	{ x = 10, z = -4, h = 1.6, type = "Forehand", label = "Low skimmer: slide or dive" },
	{ x = 16, z = 2, h = 2.6, type = "Backhand", label = "Wide: lay out" },
	{ x = -6, z = -22, h = 4, type = "Hammer", label = "Hammer over the top: get back" },
	{ x = -14, z = 6, h = 3.5, type = "Forehand", bank = 0.8, label = "Curving away" },
	{ x = 12, z = 10, h = 2.2, type = "Blade", label = "Fast blade: read it early" },
	{ x = -12, z = -2, h = 8.0, type = "Backhand", bank = -0.6, label = "Jump + Air Redirect", floaty = true },
	{ x = 4, z = -34, h = 4, type = "Backhand", label = "Deep floater: sprint", floaty = true },
	{ x = -18, z = -8, h = 2.2, type = "Forehand", label = "Full layout" },
}

local function aerialNext(s: Session)
	s.data.index += 1
	local p = AERIAL[s.data.index]
	if not p then
		local lines = { string.format("Score: %d (%d / %d caught)", s.data.score, s.data.caught, #AERIAL) }
		for _, line in s.data.notes do
			table.insert(lines, line)
		end
		finish(s, "AERIAL CATCH", lines, "Aerial", s.data.score, false)
		return
	end
	s.data.closest = math.huge
	s.data.closestRel = Vector3.zero
	s.data.closestAt = 0
	s.data.inFlight = false
	hud(s, string.format("AERIAL CATCH  %d/%d", s.data.index, #AERIAL), p.label, { progress = (s.data.index - 1) / #AERIAL })
	task.delay(1.4, function()
		if sessions[s.actor.id] ~= s then
			return
		end
		local mark = layout.catchMark
		local target = mark + Vector3.new(p.x, p.h, p.z)
		launchAt(s, layout.launcher, target, p.type, p.bank, p.floaty)
		s.data.inFlight = true
	end)
end

local function aerialResult(s: Session, caught: boolean, info: any?)
	if not s.data.inFlight then
		return
	end
	s.data.inFlight = false
	local p = AERIAL[s.data.index]
	if caught then
		local pts = 100
		if info and info.quality == "Clean" then
			pts += 50
		end
		if info and info.zone == "Dive" then
			pts += 100
		end
		s.data.score += pts
		s.data.caught += 1
		send(s, "DrillTick", { text = string.format("Caught! +%d", pts) })
	else
		local rel: Vector3 = s.data.closestRel
		local lines = { string.format("%s — missed by %.1f studs.", p.label, s.data.closest) }
		if rel.Y > 2 then
			table.insert(lines, "It was above you: jump (SPACE) and Reach (CLICK).")
		elseif rel.Y < -1.5 then
			table.insert(lines, "It was low: slide (CTRL) or dive (E) to get under it.")
		end
		if flat(rel).Magnitude > 3 then
			table.insert(lines, "Too far away: move on the launch, or lay out (E) toward it.")
		end
		local reach = services.CatchingService.reachState(s.actor.id)
		if reach and math.abs(reach.at - s.data.closestAt) < 1.5 then
			local diff = reach.at - s.data.closestAt
			if diff < -0.3 then
				table.insert(lines, string.format("You reached %.2f s too early.", -diff))
			elseif diff > 0.05 then
				table.insert(lines, string.format("You reached %.2f s late.", diff))
			end
		end
		send(s, "DrillTick", { text = table.concat(lines, "  ") })
		table.insert(s.data.notes, lines[1])
	end
	task.delay(1.0, function()
		if sessions[s.actor.id] == s then
			if s.disc and s.disc.mode == "Held" then
				services.DiscService.hide(s.disc)
			end
			teleport(s, layout.catchMark + Vector3.new(0, 3, 0), Vector3.new(0, 0, 1))
			aerialNext(s)
		end
	end)
end

DRILLS.Aerial = {
	start = function(s: Session)
		teleport(s, layout.catchMark + Vector3.new(0, 3, 0), Vector3.new(0, 0, 1))
		s.data.index = 0
		s.data.score = 0
		s.data.caught = 0
		s.data.notes = {}
		aerialNext(s)
	end,
	step = function(s: Session)
		local d = s.disc
		if not d or not s.data.inFlight or d.mode ~= "Flight" then
			return
		end
		local r = root(s)
		local p = services.DiscService.currentPosition(d)
		if r and p then
			local chest = r.Position + Vector3.new(0, DiscConfig.Catch.ChestHeight, 0)
			local dist = (p - chest).Magnitude
			if dist < s.data.closest then
				s.data.closest = dist
				s.data.closestRel = p - chest
				s.data.closestAt = now()
			end
		end
	end,
	onCaught = function(s: Session, _d: any, info: any)
		aerialResult(s, true, info)
	end,
	onGrounded = function(s: Session, d: any, land: Vector3)
		services.DiscService.placeOnGround(d, land)
		aerialResult(s, false, nil)
	end,
}

---------------------------------------------------------------------------
-- Free launcher
---------------------------------------------------------------------------

DRILLS.Launcher = {
	start = function(s: Session)
		teleport(s, layout.catchMark + Vector3.new(0, 3, 0), Vector3.new(0, 0, 1))
		send(s, "OpenLauncher", {})
		hud(s, "FREE LAUNCHER", "Set type, power, angle and curve in the panel, then Launch.", {})
	end,
	launch = function(s: Session, payload: any)
		local r = root(s)
		if not r or type(payload) ~= "table" then
			return
		end
		local params = ThrowModel.sanitize({
			throwType = payload.throwType,
			yaw = 0,
			pitch = math.rad(if type(payload.pitch) == "number" then payload.pitch else 8),
			holdTime = (if type(payload.power) == "number" then math.clamp(payload.power, 0.05, 1) else 0.5) * DiscConfig.Throw.ChargeTime,
			bank = payload.bank,
			height = "Mid",
		})
		if not params then
			return
		end
		local p = params :: ThrowModel.Params
		local d = flat(r.Position - layout.launcher)
		p.yaw = math.atan2(-d.X, -d.Z) + math.rad(if type(payload.offset) == "number" then math.clamp(payload.offset, -30, 30) else 0)
		services.ThrowService.launchFrom(discFor(s), p, layout.launcher, { noCatch = 0.1 })
	end,
	onCaught = function(s: Session, _d: any, info: any)
		send(s, "DrillTick", { text = string.format("Caught (%s, %s zone)", info.quality, info.zone) })
		task.delay(0.6, function()
			if s.disc and s.disc.mode == "Held" then
				services.DiscService.hide(s.disc)
			end
		end)
	end,
}

---------------------------------------------------------------------------
-- Throwing range
---------------------------------------------------------------------------

local RANGE_THROWS = 10

local function moverPos(t: number): Vector3
	local m = layout.mover
	return TrainingBuilder.moverPosition(m.center, m.amplitude, m.period, t)
end

local function rangeGive(s: Session)
	if sessions[s.actor.id] ~= s then
		return
	end
	teleport(s, layout.throwMark + Vector3.new(0, 3, 0), Vector3.new(0, 0, 1))
	services.DiscService.giveTo(discFor(s), s.actor.id)
	hud(s, string.format("THROWING RANGE  %d/%d", s.data.throws + 1, RANGE_THROWS), "Hit the rings. The yellow one moves.", {
		progress = s.data.throws / RANGE_THROWS,
	})
end

local function rangeResult(s: Session)
	if not s.data.inFlight then
		return
	end
	s.data.inFlight = false
	local info = s.data.throwInfo
	local launch = info.launch
	local lines = {}
	local hit = s.data.hit
	if hit then
		s.data.score += hit.points
		table.insert(lines, string.format("HIT %s! +%d", hit.name, hit.points))
	else
		local near = s.data.nearest
		if near then
			local forward = VecMath.flatUnit(near.target - launch.releasePos)
			local right = Vector3.new(-forward.Z, 0, forward.X)
			local miss = near.discPos - near.target
			local lateral = miss:Dot(right)
			local long = miss:Dot(forward)
			table.insert(lines, string.format("Missed %s by %.1f studs.", near.name, near.dist))
			if math.abs(lateral) > 2 then
				table.insert(lines, string.format("%.0f studs %s: aim %s or bank %s.", math.abs(lateral),
					if lateral > 0 then "right" else "left",
					if lateral > 0 then "left" else "right",
					if lateral > 0 then "left (Q)" else "right (E)"))
			end
			if miss.Y < -2.5 or long < -3 then
				table.insert(lines, "Short / low: hold longer or raise your aim.")
			elseif miss.Y > 2.5 or long > 3 then
				table.insert(lines, "Long / high: release earlier or lower your aim.")
			end
		end
	end
	table.insert(lines, string.format("Release: %s  power %d%%  spin %d%%  bank %+d deg", launch.quality,
		math.floor(launch.power * 100), math.floor(launch.spinFactor * 100), math.floor(launch.bankDeg)))
	if launch.quality == "Over" then
		table.insert(lines, "Overcharged: low spin makes the disc roll (turn/fade) more. Release at the peak.")
	end
	send(s, "DrillTick", { text = table.concat(lines, "  ") })
	s.data.throws += 1
	if s.data.throws >= RANGE_THROWS then
		task.delay(1.0, function()
			finish(s, "THROWING RANGE", { string.format("Score: %d", s.data.score), string.format("Rings hit: %d / %d", s.data.hits, RANGE_THROWS) }, "Range", s.data.score, false)
		end)
	else
		task.delay(1.2, function()
			rangeGive(s)
		end)
	end
end

DRILLS.Range = {
	start = function(s: Session)
		s.data.throws = 0
		s.data.score = 0
		s.data.hits = 0
		rangeGive(s)
	end,
	onThrown = function(s: Session, _d: any, info: any)
		s.data.inFlight = true
		s.data.throwInfo = info
		s.data.hit = nil
		s.data.nearest = nil
	end,
	step = function(s: Session)
		local d = s.disc
		if not d or not s.data.inFlight or d.mode ~= "Flight" then
			return
		end
		local p = services.DiscService.currentPosition(d)
		if not p then
			return
		end
		local t = now()
		local candidates = {}
		for _, tg in layout.targets do
			table.insert(candidates, { name = tg.name, pos = tg.pos, radius = tg.radius, points = tg.points })
		end
		table.insert(candidates, { name = "MOVER", pos = moverPos(t), radius = layout.mover.radius, points = layout.mover.points })
		for _, c in candidates do
			local dist = (p - c.pos).Magnitude
			if dist <= c.radius + 0.6 then
				s.data.hit = c
				s.data.hits += 1
				Net.event("Effect"):FireAllClients("TargetHit", p, s.actor.id, "Clean", c.name)
				services.DiscService.placeOnGround(d, Vector3.new(c.pos.X, layout.origin.Y, c.pos.Z))
				rangeResult(s)
				return
			end
			if s.data.nearest == nil or dist < s.data.nearest.dist then
				s.data.nearest = { name = c.name, dist = dist, target = c.pos, discPos = p }
			end
		end
	end,
	onGrounded = function(s: Session, d: any, land: Vector3)
		services.DiscService.placeOnGround(d, land)
		rangeResult(s)
	end,
	onCaught = function(_s: Session) end,
}

---------------------------------------------------------------------------
-- Interception drill
---------------------------------------------------------------------------

local ROUTES = {
	{ Vector3.new(0, 0, 34) },
	{ Vector3.new(-14, 0, 10), Vector3.new(-30, 0, 30) },
	{ Vector3.new(0, 0, 18), Vector3.new(-24, 0, 4) },
	{ Vector3.new(-30, 0, 0) },
	{ Vector3.new(0, 0, 50) },
	{ Vector3.new(-10, 0, 30), Vector3.new(10, 0, 10) },
	{ Vector3.new(-26, 0, 24) },
	{ Vector3.new(6, 0, 40), Vector3.new(-20, 0, 50) },
}

local function interceptionRep(s: Session)
	if sessions[s.actor.id] ~= s then
		return
	end
	s.data.rep += 1
	if s.data.rep > #ROUTES then
		finish(s, "INTERCEPTION DRILL", {
			string.format("Score: %d", s.data.score),
			string.format("Interceptions %d  Blocks %d  Completions allowed %d", s.data.ints, s.data.blocks, s.data.allowed),
		}, "Interception", s.data.score, false)
		return
	end
	local L = layout.interception
	local thrower = services.PlayerService.get(s.bots[1])
	local receiver = services.PlayerService.get(s.bots[2])
	if not thrower or not receiver then
		return
	end
	services.PlayerService.teleport(thrower, CFrame.lookAt(L.thrower, L.receiverStart))
	services.PlayerService.teleport(receiver, CFrame.lookAt(L.receiverStart, L.receiverStart + Vector3.new(0, 0, 1)))
	teleport(s, L.playerStart, Vector3.new(1, 0, 0))
	local d = discFor(s)
	services.DiscService.giveTo(d, thrower.id)
	s.data.route = ROUTES[s.data.rep]
	s.data.leg = 0
	s.data.resolved = false
	hud(s, string.format("INTERCEPTION  %d/%d", s.data.rep, #ROUTES), "The receiver cuts, the thrower leads them. Get the D.", {
		progress = (s.data.rep - 1) / #ROUTES,
	})
	task.delay(1.2, function()
		if sessions[s.actor.id] == s then
			s.data.leg = 1
			s.data.routeStart = now()
		end
	end)
	task.delay(1.95, function()
		if sessions[s.actor.id] ~= s or d.mode ~= "Held" or d.holder ~= thrower.id then
			return
		end
		local rroot = services.PlayerService.root(receiver)
		local troot = services.PlayerService.root(thrower)
		if not rroot or not troot then
			return
		end
		local sol = Solver.solve({
			rootPos = troot.Position,
			throwType = "Backhand",
			target = rroot.Position + Vector3.new(0, 1, 0),
			targetVel = flat(rroot.AssemblyLinearVelocity),
			groundY = layout.origin.Y,
			coarse = true,
		})
		if sol then
			local pr = root(s)
			if pr then
				local lane = VecMath.closestOnSegment(flat(troot.Position), flat(sol.catchPoint), flat(pr.Position))
				s.data.laneDist = (lane - flat(pr.Position)).Magnitude
			end
			services.ThrowService.throw(thrower.id, sol.params, true)
		end
	end)
end

local function interceptionResolve(s: Session, text: string, pts: number)
	if s.data.resolved then
		return
	end
	s.data.resolved = true
	s.data.score += pts
	local extra = if s.data.laneDist then string.format("  (you were %.1f studs from the lane at release)", s.data.laneDist) else ""
	send(s, "DrillTick", { text = text .. extra })
	task.delay(1.6, function()
		interceptionRep(s)
	end)
end

DRILLS.Interception = {
	start = function(s: Session)
		s.data.rep = 0
		s.data.score = 0
		s.data.ints = 0
		s.data.blocks = 0
		s.data.allowed = 0
		local function receiverBrain(b: any, _dt: number)
			local route = s.data.route
			if not route or s.data.leg == 0 then
				b.target = nil
				return
			end
			local wp = route[s.data.leg]
			if not wp then
				b.target = nil
				return
			end
			local goal = layout.interception.receiverStart + wp
			b.target = goal
			b.speed = 23
			if flat(goal - b.root.Position).Magnitude < 2.5 then
				s.data.leg += 1
			end
		end
		local function throwerBrain(b: any, _dt: number)
			b.target = nil
		end
		local t = services.BotService.spawn("N", throwerBrain, "Training")
		local r = services.BotService.spawn("N", receiverBrain, "Training")
		s.bots = { t, r }
		task.delay(0.5, function()
			interceptionRep(s)
		end)
	end,
	onCaught = function(s: Session, d: any, info: any)
		if info.id == s.actor.id then
			s.data.ints += 1
			interceptionResolve(s, "INTERCEPTION! +200", 200)
		else
			s.data.allowed += 1
			interceptionResolve(s, "Completed.", 0)
		end
		task.delay(0.5, function()
			if d.mode == "Held" then
				services.DiscService.hide(d)
			end
		end)
	end,
	onTouched = function(s: Session, _d: any, info: any)
		if info.id == s.actor.id and info.kind ~= "Bobble" then
			s.data.blocks += 1
			interceptionResolve(s, "BLOCK! +150", 150)
		end
	end,
	onGrounded = function(s: Session, d: any, land: Vector3)
		services.DiscService.placeOnGround(d, land)
		interceptionResolve(s, "Incomplete.", 50)
	end,
}

---------------------------------------------------------------------------
-- Combo lab
---------------------------------------------------------------------------

local CHALLENGES = {
	{ name = "Sold!", hint = "Fake Commit, then Snap Cut away", seq = { { tech = "FakeCommit" }, { tech = "SnapCut", info = "Sold" } } },
	{ name = "Plant and Go", hint = "Momentum Cancel, then a PERFECT restart", seq = { { tech = "MomentumCancel" }, { tech = "SnapCut", info = "Restart", quality = "Perfect" } } },
	{ name = "Cut-Burst", hint = "Snap Cut, then Burst within 0.15 s (Perfect)", seq = { { tech = "SnapCut" }, { tech = "BurstStep", quality = "Perfect" } } },
	{ name = "Stick the Landing", hint = "Jump, Air Redirect, Precision Landing", seq = { { tech = "Jump" }, { tech = "AirRedirect" }, { tech = "PrecisionLanding" } } },
	{ name = "Slide Cut", hint = "Slide, then cut out of it", seq = { { tech = "Slide" }, { tech = "SlideCut" } } },
	{ name = "Get Up!", hint = "Dive, then Recovery Chain", seq = { { tech = "Dive" }, { tech = "RecoveryChain" } } },
	{ name = "Off the Wall", hint = "Wall Rebound (jump at a pink wall), then Air Redirect", seq = { { tech = "WallRebound" }, { tech = "AirRedirect" } } },
	{ name = "Full Send", hint = "Snap Cut, Burst Step, Layout", seq = { { tech = "SnapCut" }, { tech = "BurstStep" }, { tech = "Dive" } } },
}

local function comboStatus(s: Session)
	local lines = {}
	local done = 0
	for i, c in CHALLENGES do
		local ok = s.data.done[i] == true
		if ok then
			done += 1
		end
		table.insert(lines, (if ok then "[x] " else "[ ] ") .. c.name .. " — " .. c.hint)
	end
	hud(s, string.format("COMBO LAB  %d/%d", done, #CHALLENGES), table.concat(lines, "\n"), { progress = done / #CHALLENGES, list = true })
	return done
end

local function matches(recent: { any }, seq: { any }): boolean
	local n = #seq
	if #recent < n then
		return false
	end
	-- the last n techniques must match in order, each within the chain window
	for k = 1, n do
		local e = recent[#recent - n + k]
		local want = seq[k]
		if e.tech ~= want.tech then
			return false
		end
		if want.info and e.info ~= want.info then
			return false
		end
		if want.quality and e.quality ~= want.quality then
			return false
		end
		if k > 1 and e.t - recent[#recent - n + k - 1].t > MovementConfig.ChainWindow + 0.2 then
			return false
		end
	end
	return true
end

DRILLS.Combo = {
	start = function(s: Session)
		local st = layout.stations.Combo
		teleport(s, st.start, st.facing)
		s.data.done = {}
		s.data.recent = {}
		comboStatus(s)
	end,
	onTech = function(s: Session, tech: string, quality: string, info: string?)
		table.insert(s.data.recent, { tech = tech, quality = quality, info = info, t = now() })
		while #s.data.recent > 8 do
			table.remove(s.data.recent, 1)
		end
		for i, c in CHALLENGES do
			if not s.data.done[i] and matches(s.data.recent, c.seq) then
				s.data.done[i] = true
				send(s, "DrillTick", { text = "Challenge complete: " .. c.name })
				if comboStatus(s) >= #CHALLENGES then
					finish(s, "COMBO LAB COMPLETE", { "Every chain landed. Now do it with a disc in the air." }, "Combo", 1, false)
				end
			end
		end
	end,
}

---------------------------------------------------------------------------
-- session lifecycle
---------------------------------------------------------------------------

function stopDrill(actor: any)
	local s = sessions[actor.id]
	if not s then
		return
	end
	sessions[actor.id] = nil
	s.ended = true
	for _, id in s.bots do
		services.BotService.remove(id)
	end
	if s.disc then
		services.DiscService.destroy(s.disc)
		s.disc = nil
	end
	send(s, "DrillHud", { drill = "", title = "", text = "", clear = true })
end

TrainingService.stopDrill = stopDrill

function TrainingService.startDrill(actor: any, drill: string)
	if not DRILLS[drill] then
		return
	end
	TrainingService.stopDrill(actor)
	local s: Session = {
		actor = actor,
		player = actor.player,
		drill = drill,
		phase = "Running",
		t0 = now(),
		data = {},
		disc = nil,
		bots = {},
		ended = false,
	}
	sessions[actor.id] = s
	DRILLS[drill].start(s)
end

function TrainingService.enter(actor: any)
	if actor.role ~= "Training" then
		services.TeamService.setTraining(actor, true)
	end
	services.PlayerService.setFrozen(actor, false)
	services.PlayerService.teleport(actor, layout.entry)
end

function TrainingService.leave(actor: any)
	TrainingService.stopDrill(actor)
	if actor.role == "Training" then
		services.PlayerService.setTeam(actor, "N", "Spectate")
		services.MatchService.onLeftTraining(actor)
	end
end

function TrainingService.respawned(actor: any)
	TrainingService.stopDrill(actor)
	services.PlayerService.teleport(actor, layout.entry)
end

function TrainingService.action(player: Player, kind: string, payload: any)
	local actor = services.PlayerService.fromPlayer(player)
	if not actor then
		return
	end
	if kind == "EnterTraining" then
		TrainingService.enter(actor)
	elseif kind == "LeaveTraining" then
		TrainingService.leave(actor)
	elseif kind == "CancelDrill" then
		TrainingService.stopDrill(actor)
	elseif kind == "StartDrill" and type(payload) == "string" and DRILLS[payload] then
		if actor.role ~= "Training" then
			TrainingService.enter(actor)
		end
		TrainingService.startDrill(actor, payload)
	elseif kind == "LaunchCustom" then
		local s = sessions[actor.id]
		if s and s.drill == "Launcher" then
			DRILLS.Launcher.launch(s, payload)
		end
	end
end

function TrainingService.layout(): TrainingBuilder.Layout
	return layout
end

function TrainingService.Init(s: any)
	services = s
	layout = TrainingBuilder.build(ArenasConfig.TrainingOrigin, workspace)
end

function TrainingService.Start()
	for id, prompt in layout.prompts do
		prompt.Triggered:Connect(function(player)
			local actor = services.PlayerService.fromPlayer(player)
			if not actor then
				return
			end
			if actor.role ~= "Training" then
				services.TeamService.setTraining(actor, true)
			end
			TrainingService.startDrill(actor, id)
		end)
	end
	services.MovementService.TechAccepted:Connect(function(actorId, tech, quality, info)
		local s = sessions[actorId]
		if s then
			local drill = DRILLS[s.drill]
			if drill and drill.onTech then
				drill.onTech(s, tech, quality, info)
			end
		end
	end)
	services.PlayerService.ActorRemoving:Connect(function(actor)
		if sessions[actor.id] then
			TrainingService.stopDrill(actor)
		end
	end)
	RunService.Heartbeat:Connect(function(dt)
		for _, s in sessions do
			local drill = DRILLS[s.drill]
			if drill and drill.step and not s.ended then
				local ok, err = pcall(drill.step, s, dt)
				if not ok then
					warn("[TrainingService] " .. tostring(err))
				end
			end
		end
	end)
	Net.state():SetAttribute("TrainingOrigin", ArenasConfig.TrainingOrigin)
end

return TrainingService
