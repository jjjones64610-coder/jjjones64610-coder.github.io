--!strict
--[[
	TrainingService — drills with actionable feedback.

	Every drill reports WHY something worked or failed in plain terms:
	gate splits and where speed was lost, reversal times with the technique
	that would shorten them, how far a missed catch was and in which
	direction, a throw's release quality, spin, bank and miss vector, the
	defender's distance from the passing lane at release, and which side of
	a mark was open.

	Drills: Tutorial (Movement School), Cutting, Shuttle, Aerial, Range,
	Interception, Combo (lab challenges), BreakMark (Break the Mark),
	Launcher (free, custom launches). Each session owns its own training
	disc; drills never touch the match.

	Movement School teaches the current keys and the forgiving press rules
	(every step can be completed with the MovementSim as it is): running and
	auto-sprint, Snap Cut (hold A or D, then tap Q), plant and restart, burst,
	the jab and the Sold cut, slide and slide cut, air redirect, precision
	landing, layout and pop-up, catching, throwing, then the pivot with the
	disc: stepping, the Quick Swing and the Break (fake, swing, release).

	Break the Mark: the player holds the disc on a pivot mark against a
	scripted bot marker (BotService.mark: shades the force's break side,
	mirrors the step with a reaction lag, bites on fakes, jump-blocks hops;
	its skill ramps 0.5 -> 0.85 over the reps) with two receivers downfield.
	A rep is a success when a throw gets past the mark and is caught; a
	throw on the marker's side scores extra and so does a Break. The drill
	runs its own hand-block test (training discs are not match discs) on the
	marker rewound to where the player saw it, and every rep says which side
	was open and how to beat the side that was not.

	Drills move players with PlayerService.teleport(actor, cf, { face = true })
	so the client turns its camera with them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local ArenasConfig = require(Shared.Config.Arenas)
local DiscConfig = require(Shared.Config.Disc)
local SignaturesConfig = require(Shared.Config.Signatures)
local MovementConfig = require(Shared.Config.Movement)
local ThrowModel = require(Shared.Disc.ThrowModel)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local Solver = require(Shared.Disc.Solver)
local CatchGeometry = require(Shared.Rules.CatchGeometry)
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

local HD = MovementConfig.Holding
local GROUND_RETURN = 5 -- a training disc left on the ground comes back to the hand after this

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

-- Moves any actor (player or drill bot) and turns them (and a player's
-- camera) toward `facing`.
local function place(actor: any, pos: Vector3, facing: Vector3?)
	local f = VecMath.flatUnit(facing or Vector3.new(0, 0, 1))
	if f.Magnitude < 0.5 then
		f = Vector3.new(0, 0, 1)
	end
	services.PlayerService.teleport(actor, CFrame.lookAt(pos, pos + f), { face = true })
end

local function teleport(s: Session, pos: Vector3, facing: Vector3?)
	place(s.actor, pos, facing)
end

-- Root position for an actor standing on a ground point of the hall.
local function standingAt(actorId: number, ground: Vector3): Vector3
	return Vector3.new(ground.X, layout.origin.Y + services.MovementService.standHeight(actorId) + 0.1, ground.Z)
end

local function bot(id: number?): any
	return if id then services.BotService.brain(id) else nil
end

-- Bot models load one at a time (spawning yields): a drill cancelled
-- meanwhile must not leave its bots behind.
local function dropIfStopped(s: Session): boolean
	if sessions[s.actor.id] == s then
		return false
	end
	for _, id in s.bots do
		services.BotService.remove(id)
	end
	s.bots = {}
	return true
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
		local drill = DRILLS[s.drill]
		if drill and drill.canClaim then
			return drill.canClaim(s, id)
		end
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

local function launchAt(
	s: Session,
	origin: Vector3,
	target: Vector3,
	throwType: string,
	bank: number?,
	floaty: boolean?
): any
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

local function finish(
	s: Session,
	title: string,
	lines: { string },
	pbKey: string?,
	value: number?,
	lowerIsBetter: boolean?
)
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
			table.insert(
				lines,
				if isPB then "NEW PERSONAL BEST!" else string.format("Personal best: %s", tostring(prev))
			)
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

-- `any` lists the techniques (and info) that complete a step; `disc` steps
-- are done holding the session disc.
local TUTORIAL: { any } = {
	{ text = "RUN: hold W. You start sprinting by yourself after a moment (or hold SHIFT).", kind = "speed" },
	{
		text = "SNAP CUT: while running, hold A or D, then tap Q. The longer your straight line, the better the cut.",
		any = { { tech = "SnapCut" } },
	},
	{
		text = "PLANT: while running, tap Q with no direction held (or while holding S).",
		any = { { tech = "MomentumCancel" } },
	},
	{
		text = "RESTART: plant (Q), then as you stop hold a direction and press Q, F or SPACE.",
		any = {
			{ tech = "SnapCut", info = "Restart" },
			{ tech = "BurstStep", info = "Explosive" },
			{ tech = "Jump", info = "PlantJump" },
		},
	},
	{ text = "BURST: press F to explode into space (it has a short cooldown).", any = { { tech = "BurstStep" } } },
	{ text = "JAB: run straight and tap Q without steering: a Fake Commit.", any = { { tech = "FakeCommit" } } },
	{
		text = "SOLD CUT: jab (Q), then within half a second hold A or D and tap Q again.",
		any = { { tech = "SnapCut", info = "Sold" } },
	},
	{ text = "SLIDE: while running, press C (or LEFT CTRL).", any = { { tech = "Slide" } } },
	{ text = "SLIDE CUT: during a slide, hold a new direction and tap Q.", any = { { tech = "SlideCut" } } },
	{
		text = "AIR REDIRECT: jump (SPACE), then hold a NEW direction and tap Q in the air.",
		any = { { tech = "AirRedirect" } },
	},
	{
		text = "PRECISION LANDING: jump, then press C just before you touch down.",
		any = { { tech = "PrecisionLanding" } },
	},
	{ text = "LAYOUT: while running, press E to dive.", any = { { tech = "Dive" } } },
	{
		text = "RECOVERY CHAIN: as your dive slide stops, press SPACE, Q or F to pop up.",
		any = { { tech = "RecoveryChain" } },
	},
	{ text = "CATCH: run to the disc. CLICK to reach for ones outside your body.", kind = "catch" },
	{ text = "THROW: hold LEFT MOUSE and release at the peak of the meter (PERFECT).", kind = "throw", disc = true },
	{
		text = "PIVOT: with the disc your pivot foot stays planted. Step out with WASD: the free foot reaches past a marker.",
		kind = "pivot",
		disc = true,
	},
	{
		text = "QUICK SWING: holding the disc, tap Q to swing to the left or E to swing to the right.",
		any = { { tech = "PivotSwing" } },
		disc = true,
	},
	{
		text = "BREAK: fake (RIGHT MOUSE), swing (Q or E) and throw within 0.3 s of the swing.",
		any = { { tech = "Break" } },
		kind = "break",
		disc = true,
	},
}

-- Hands the session disc to the player for a disc step (a disc still in
-- flight comes back when it lands).
local function tutorialGive(s: Session)
	local d = discFor(s)
	if d.mode == "Flight" or (d.mode == "Held" and d.holder == s.actor.id) then
		return
	end
	services.DiscService.giveTo(d, s.actor.id)
end

local function tutorialShow(s: Session)
	local step = TUTORIAL[s.data.step]
	hud(
		s,
		string.format("MOVEMENT SCHOOL  %d/%d", s.data.step, #TUTORIAL),
		step.text,
		{ progress = (s.data.step - 1) / #TUTORIAL }
	)
	s.data.tries = 0
	if step.kind == "catch" then
		local r = root(s)
		if r then
			local d = s.disc
			if d and d.mode == "Held" then
				services.DiscService.hide(d)
			end
			local origin = r.Position + VecMath.flatUnit(r.CFrame.LookVector) * 40
			task.delay(1.0, function()
				if sessions[s.actor.id] == s and TUTORIAL[s.data.step].kind == "catch" then
					launchAt(s, origin, r.Position + Vector3.new(0, 1.5, 0), "Backhand", 0, true)
				end
			end)
		end
	elseif step.disc then
		tutorialGive(s)
	end
end

local function tutorialAdvance(s: Session, note: string?)
	s.data.step += 1
	send(s, "DrillTick", { text = note or "Nice!" })
	if s.data.step > #TUTORIAL then
		finish(s, "MOVEMENT SCHOOL COMPLETE", {
			"You know the whole vocabulary, with and without the disc.",
			"Next: Combo Lab to chain it, Cutting Course to use it at speed, Break the Mark to beat a marker.",
		}, "Tutorial", 1, false)
		return
	end
	tutorialShow(s)
end

local function stepWants(step: any, tech: string, info: string?): boolean
	for _, want in step.any or {} do
		if want.tech == tech and (want.info == nil or want.info == info) then
			return true
		end
	end
	return false
end

DRILLS.Tutorial = {
	start = function(s: Session)
		s.data.step = 1
		s.data.soldSwingAt = -math.huge
		s.data.groundAt = nil
		tutorialShow(s)
	end,
	step = function(s: Session)
		local step = TUTORIAL[s.data.step]
		if not step then
			return
		end
		if step.kind == "speed" then
			local t = services.MovementService.track(s.actor.id)
			if t and flat(t.vel).Magnitude >= MovementConfig.SprintSpeed - 4 then
				tutorialAdvance(s)
			end
		elseif step.kind == "pivot" then
			local r = root(s)
			local P = services.MovementService.pivotOf(s.actor.id)
			if r and P and services.DiscService.heldBy(s.actor.id) then
				-- the root sits at P + BodyShare x step: a real step-out
				if flat(r.Position - P).Magnitude >= 0.66 * HD.StepRadius * HD.BodyShare then
					tutorialAdvance(s, "That's a step-out. The pivot foot never moved.")
				end
			end
		end
		-- a disc on the ground: walk to it, or it comes back after a moment
		local d = s.disc
		if step.disc and d and d.mode == "Ground" then
			local r = root(s)
			local spot = d.folder:GetAttribute("GroundPos")
			local at = s.data.groundAt or now()
			s.data.groundAt = at
			local near = r
				and typeof(spot) == "Vector3"
				and flat(spot - r.Position).Magnitude <= DiscConfig.Catch.PickupRadius
			if near or now() - at > GROUND_RETURN then
				s.data.groundAt = nil
				services.DiscService.giveTo(d, s.actor.id)
			end
		end
	end,
	onTech = function(s: Session, tech: string, quality: string, info: string?)
		local step = TUTORIAL[s.data.step]
		if tech == "PivotSwing" and quality == "Perfect" then
			s.data.soldSwingAt = now()
		end
		if step and stepWants(step, tech, info) then
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
		s.data.groundAt = now()
		local step = TUTORIAL[s.data.step]
		if step and step.kind == "catch" then
			send(s, "DrillTick", { text = "Missed — here comes another." })
			tutorialShow(s)
		elseif step and step.disc then
			send(s, "DrillTick", { text = "Walk over to the disc to pick it up (it comes back by itself too)." })
		end
	end,
	onThrown = function(s: Session, _d: any, info: any)
		local step = TUTORIAL[s.data.step]
		if not step then
			return
		end
		s.data.tries += 1
		if step.kind == "throw" then
			local q = info.launch.quality
			if q == "Perfect" then
				tutorialAdvance(s)
			elseif s.data.tries >= 4 then
				tutorialAdvance(s, "Good enough for now: chase PERFECT releases in the Throwing Range.")
			else
				send(s, "DrillTick", {
					text = if q == "Over"
						then "Held too long (spin lost). Release right as the meter peaks."
						else "Released early. Hold until the meter fills, then let go.",
				})
			end
		elseif step.kind == "break" then
			-- the Break itself arrives as a technique (onTech); a Sold swing
			-- followed by a throw a little late still counts here
			task.defer(function()
				if sessions[s.actor.id] ~= s or TUTORIAL[s.data.step] ~= step then
					return
				end
				if now() - s.data.soldSwingAt <= 1.2 then
					tutorialAdvance(s, "Close! Release a little sooner after the swing for the Break bonus.")
				elseif s.data.tries >= 2 then
					send(s, "DrillTick", {
						text = "Fake first (RIGHT MOUSE), swing straight after (Q or E), then throw at once.",
					})
				end
			end)
		end
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
				table.insert(
					s.data.splits,
					{ gate = s.data.gate, t = now() - s.data.startAt, speed = flat(r.AssemblyLinearVelocity).Magnitude }
				)
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
					table.insert(
						lines,
						string.format("Slowest section: before gate %d (dropped to %.0f studs/s).", worstGate, worst)
					)
					if worst < 12 then
						table.insert(
							lines,
							string.format(
								"Tip: hold A or D, then tap Q at each gate — a Snap Cut off a straight line keeps %d%% of your speed.",
								math.floor(MovementConfig.SnapCut.Retention.Perfect * 100)
							)
						)
					elseif worst < 18 then
						table.insert(
							lines,
							string.format(
								"Tip: press F within %.2f s of a Snap Cut for a Perfect Burst out of the turn.",
								MovementConfig.BurstStep.CutChainWindow
							)
						)
					else
						table.insert(
							lines,
							"You held speed all the way. Try Slide Cuts (C, then Q) on the tight gates."
						)
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
			for i, rv in s.data.reversals do
				local verdict = if rv.t < 0.3
					then "elite"
					elseif rv.t < 0.5 then "good"
					else "slow — plant (tap Q with no direction), then hold the way back and press Q, F or SPACE as you stop"
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
	hud(
		s,
		string.format("AERIAL CATCH  %d/%d", s.data.index, #AERIAL),
		p.label,
		{ progress = (s.data.index - 1) / #AERIAL }
	)
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
			table.insert(lines, "It was above you: jump (SPACE) and reach (CLICK).")
		elseif rel.Y < -1.5 then
			table.insert(lines, "It was low: slide (C) or lay out (E) to get under it.")
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
			holdTime = (if type(payload.power) == "number" then math.clamp(payload.power, 0.05, 1) else 0.5)
				* DiscConfig.Throw.ChargeTime,
			bank = payload.bank,
			height = "Mid",
		})
		if not params then
			return
		end
		local p = params :: ThrowModel.Params
		local d = flat(r.Position - layout.launcher)
		p.yaw = math.atan2(-d.X, -d.Z)
			+ math.rad(if type(payload.offset) == "number" then math.clamp(payload.offset, -30, 30) else 0)
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
	hud(
		s,
		string.format("THROWING RANGE  %d/%d", s.data.throws + 1, RANGE_THROWS),
		"Hit the rings. The yellow one moves.",
		{
			progress = s.data.throws / RANGE_THROWS,
		}
	)
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
				table.insert(
					lines,
					string.format(
						"%.0f studs %s: aim %s or bank %s.",
						math.abs(lateral),
						if lateral > 0 then "right" else "left",
						if lateral > 0 then "left" else "right",
						if lateral > 0 then "left (Z)" else "right (X)"
					)
				)
			end
			if miss.Y < -2.5 or long < -3 then
				table.insert(lines, "Short / low: hold longer or raise your aim.")
			elseif miss.Y > 2.5 or long > 3 then
				table.insert(lines, "Long / high: release earlier or lower your aim.")
			end
		end
	end
	table.insert(
		lines,
		string.format(
			"Release: %s  power %d%%  spin %d%%  bank %+d deg",
			launch.quality,
			math.floor(launch.power * 100),
			math.floor(launch.spinFactor * 100),
			math.floor(launch.bankDeg)
		)
	)
	if launch.quality == "Over" then
		table.insert(lines, "Overcharged: low spin makes the disc roll (turn/fade) more. Release at the peak.")
	end
	send(s, "DrillTick", { text = table.concat(lines, "  ") })
	s.data.throws += 1
	if s.data.throws >= RANGE_THROWS then
		task.delay(1.0, function()
			finish(s, "THROWING RANGE", {
				string.format("Score: %d", s.data.score),
				string.format("Rings hit: %d / %d", s.data.hits, RANGE_THROWS),
			}, "Range", s.data.score, false)
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
		table.insert(
			candidates,
			{ name = "MOVER", pos = moverPos(t), radius = layout.mover.radius, points = layout.mover.points }
		)
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
			string.format(
				"Interceptions %d  Blocks %d  Completions allowed %d",
				s.data.ints,
				s.data.blocks,
				s.data.allowed
			),
		}, "Interception", s.data.score, false)
		return
	end
	local L = layout.interception
	local thrower = services.PlayerService.get(s.bots[1])
	local receiver = services.PlayerService.get(s.bots[2])
	if not thrower or not receiver then
		return
	end
	place(thrower, L.thrower, L.receiverStart - L.thrower)
	place(receiver, L.receiverStart, Vector3.new(0, 0, 1))
	teleport(s, L.playerStart, Vector3.new(1, 0, 0))
	local d = discFor(s)
	services.DiscService.giveTo(d, thrower.id)
	s.data.route = ROUTES[s.data.rep]
	s.data.leg = 0
	s.data.resolved = false
	hud(
		s,
		string.format("INTERCEPTION  %d/%d", s.data.rep, #ROUTES),
		"The receiver cuts, the thrower leads them. Get the D.",
		{
			progress = (s.data.rep - 1) / #ROUTES,
		}
	)
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
		local tb = bot(thrower.id)
		local sol = Solver.solve({
			rootPos = troot.Position,
			pivot = services.MovementService.pivotOf(thrower.id),
			step = if tb then tb.sim.step else nil,
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
	local extra = if s.data.laneDist
		then string.format("  (you were %.1f studs from the lane at release)", s.data.laneDist)
		else ""
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
			local wp = if route and s.data.leg > 0 then route[s.data.leg] else nil
			if not wp then
				services.BotService.setGoal(b, nil)
				return
			end
			local goal = layout.interception.receiverStart + wp
			local first = b.target == nil
			-- each new leg of the route is a real cut (Snap Cut at speed)
			services.BotService.setGoal(b, goal, 23, not first)
			if flat(goal - b.root.Position).Magnitude < 4 then
				s.data.leg += 1
			end
		end
		local function throwerBrain(b: any, _dt: number)
			services.BotService.setGoal(b, nil)
		end
		local t = services.BotService.spawn("N", throwerBrain, "Training")
		local r = services.BotService.spawn("N", receiverBrain, "Training")
		s.bots = { t, r }
		if dropIfStopped(s) then
			return
		end
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
-- Break the Mark
---------------------------------------------------------------------------

local BREAK_REPS = 8
local BREAK_CLOCK = 8 -- seconds to get the throw off (the drill's stall count)
local BREAK_FLIGHT = 7 -- a flight nobody resolves in this long is incomplete
local BREAK_SKILL_FROM, BREAK_SKILL_TO = 0.5, 0.85
local BREAK_POINTS = { complete = 100, breakSide = 150, breakTech = 50 }

local function sideName(lateral: number): string
	return if lateral >= 0 then "forehand" else "backhand"
end

-- The drill's own hand-block test (training discs are not match discs):
-- the first HandBlockCheckTime of the flight against the marker's hand box,
-- with the marker rewound to where the player saw it.
local function markBlock(s: Session, d: any, info: any, pivot: Vector3): (number?, Vector3?)
	local markerId = s.data.marker
	if not markerId or not services.PlayerService.get(markerId) then
		return nil, nil
	end
	-- the same rewind as match hand blocks (DefenseService)
	local rewind = services.DefenseService.markerRewind(services.MovementService.ping(s.actor.id))
	local pos, facing = services.MovementService.positionAt(markerId, now() - rewind)
	local raw = services.DefenseService.stanceOf(markerId)
	local stance: CatchGeometry.MarkStance = if raw == "High" then "High" elseif raw == "Low" then "Low" else "Relaxed"
	local track = services.MovementService.track(markerId)
	local rise = if track then track.jumpHeight else 0
	local box = CatchGeometry.markBox(pos, facing, pivot, stance, layout.origin.Y, rise)
	local sim = DiscPhysics.copy(info.launch.state)
	while sim.t < DiscConfig.Throw.HandBlockCheckTime do
		DiscPhysics.step(sim, DiscConfig.Physics.Dt, d.wind)
		local p = Vector3.new(sim.px, sim.py, sim.pz)
		if CatchGeometry.inMarkBox(box, p) then
			return sim.t, p
		end
	end
	return nil, nil
end

local breakRep: (s: Session) -> ()

local function breakResult(s: Session, kind: string)
	local D = s.data
	if D.resolved then
		return
	end
	D.resolved = true
	D.phase = "Result"
	local rel = D.release
	local lines: { string } = {}
	local pts = 0
	if kind == "Complete" and rel then
		D.completed += 1
		pts = BREAK_POINTS.complete
		if rel.broke then
			D.breaks += 1
			pts += BREAK_POINTS.breakSide
			table.insert(lines, string.format("BREAK! Past the mark on your %s side.", rel.throwSide))
		else
			table.insert(
				lines,
				string.format(
					"Completed on the open %s side. The mark covered your %s: beat it there next.",
					rel.throwSide,
					rel.markSide
				)
			)
		end
		if rel.breakTech then
			pts += BREAK_POINTS.breakTech
			table.insert(lines, "Fake, swing, release: a Break link.")
		end
		table.insert(lines, string.format("+%d", pts))
	elseif kind == "Blocked" and rel then
		D.blocked += 1
		local open = if rel.markSide == "forehand" then "backhand" else "forehand"
		table.insert(
			lines,
			string.format(
				"BLOCKED on your %s side — the mark was covering it. Your %s side was open.",
				rel.throwSide,
				open
			)
		)
		if rel.step < 0.6 * HD.StepRadius then
			table.insert(lines, "Step out further (WASD): a full step-out reaches past the hands.")
		elseif rel.height ~= "Low" and rel.stance ~= "High" then
			table.insert(lines, "Go Low (hold C) with the step-out, or fake (RIGHT MOUSE) and swing (Q / E) away.")
		else
			table.insert(lines, "Fake first (RIGHT MOUSE): when the mark bites, swing (Q / E) to the other side.")
		end
	elseif kind == "Stalled" then
		table.insert(lines, string.format("STALLED — get the throw off within %d s.", BREAK_CLOCK))
	else
		table.insert(lines, "Past the mark, but nobody caught it: lead your receiver.")
	end
	D.score += pts
	table.insert(D.notes, string.format("Rep %d: %s", D.rep, lines[1]))
	send(s, "DrillTick", { text = table.concat(lines, "  ") })
	task.delay(1.8, function()
		breakRep(s)
	end)
end

breakRep = function(s: Session)
	if sessions[s.actor.id] ~= s then
		return
	end
	local D = s.data
	D.rep += 1
	if D.rep > BREAK_REPS then
		local lines = {
			string.format("Score: %d", D.score),
			string.format(
				"Completed %d / %d  ·  breaks %d  ·  blocked %d",
				D.completed,
				BREAK_REPS,
				D.breaks,
				D.blocked
			),
		}
		for _, n in D.notes do
			table.insert(lines, n)
		end
		if D.breaks == 0 then
			table.insert(
				lines,
				"Next time beat the mark on its side: a full step-out Low (hold C), or fake then swing (Q / E) and release."
			)
		end
		finish(s, "BREAK THE MARK", lines, "BreakMark", D.score, false)
		return
	end
	local rep = D.rep
	local B = layout.breakMark
	local f = VecMath.flatUnit(B.facing)
	local skill = BREAK_SKILL_FROM + (BREAK_SKILL_TO - BREAK_SKILL_FROM) * (rep - 1) / math.max(BREAK_REPS - 1, 1)
	D.force = if rep % 2 == 1 then "FH" else "BH"
	D.phase = "Setup"
	D.resolved = false
	D.release = nil
	D.breakTech = false
	local d = discFor(s)
	if d.mode ~= "None" then
		services.DiscService.hide(d)
	end
	local marker = bot(D.marker)
	if marker then
		services.BotService.setSkill(marker, skill)
		services.BotService.unmark(marker)
	end
	teleport(s, standingAt(s.actor.id, B.mark), f)
	local mActor = services.PlayerService.get(D.marker)
	if mActor then
		place(mActor, standingAt(D.marker, B.mark + f * DiscConfig.Mark.MarkDistance), -f)
	end
	for i, id in D.receivers do
		local a = services.PlayerService.get(id)
		if a then
			place(a, standingAt(id, B.receivers[i]), -f)
		end
	end
	local closed = if D.force == "FH" then "BACKHAND" else "FOREHAND"
	local text = string.format(
		"The mark forces %s: your %s side is covered. Complete a pass past it — step out (WASD), go Low (hold C), or fake (RIGHT MOUSE) + swing (Q / E).",
		if D.force == "FH" then "FOREHAND" else "BACKHAND",
		closed
	)
	hud(s, string.format("BREAK THE MARK  %d/%d", rep, BREAK_REPS), text, {
		progress = (rep - 1) / BREAK_REPS,
	})
	task.delay(0.6, function()
		if sessions[s.actor.id] ~= s or D.rep ~= rep then
			return
		end
		services.DiscService.giveTo(d, s.actor.id)
		services.MovementService.setPivot(s.actor.id, standingAt(s.actor.id, B.mark))
		D.phase = "Hold"
		D.holdStart = now()
		hud(s, string.format("BREAK THE MARK  %d/%d", rep, BREAK_REPS), text, {
			progress = (rep - 1) / BREAK_REPS,
			timerStart = D.holdStart,
		})
	end)
end

DRILLS.BreakMark = {
	start = function(s: Session)
		local D = s.data
		D.rep = 0
		D.score = 0
		D.completed = 0
		D.breaks = 0
		D.blocked = 0
		D.notes = {}
		D.phase = "Setup"
		D.force = "FH"
		D.resolved = true
		local function markerBrain(b: any, _dt: number)
			if D.phase == "Setup" or D.phase == "Hold" or D.phase == "Flight" then
				services.BotService.mark(b, s.actor.id, layout.breakMark.facing, D.force)
			else
				services.BotService.stand(b)
			end
		end
		local function receiverBrain(b: any, _dt: number)
			-- (bot models load one by one: D.receivers is set once all exist)
			local i = table.find(D.receivers or {}, b.id) or 1
			local d = s.disc
			if D.phase == "Flight" and d and d.mode == "Flight" and services.BotService.chase(b, d) then
				return
			end
			-- show open: drift around the pad
			local t = now()
			local home = layout.breakMark.receivers[i]
			local drift = Vector3.new(math.sin(t * 1.3 + i * 2) * 3, 0, math.cos(t * 0.9 + i) * 2)
			services.BotService.setGoal(b, home + drift, MovementConfig.JogSpeed * 0.6)
		end
		local m = services.BotService.spawn("N", markerBrain, "Training")
		local r1 = services.BotService.spawn("N", receiverBrain, "Training")
		local r2 = services.BotService.spawn("N", receiverBrain, "Training")
		s.bots = { m, r1, r2 }
		D.marker = m
		D.receivers = { r1, r2 }
		if dropIfStopped(s) then
			return
		end
		hud(s, "BREAK THE MARK", "Get ready: the mark sets up in front of your pivot.", { progress = 0 })
		task.delay(0.5, function()
			breakRep(s)
		end)
	end,
	canClaim = function(s: Session, id: number): boolean
		-- only the receivers catch; a throw into the marker is resolved as a block
		return table.find(s.data.receivers or {}, id) ~= nil
	end,
	step = function(s: Session)
		local D = s.data
		if D.phase == "Hold" and now() - D.holdStart > BREAK_CLOCK then
			if s.disc then
				services.DiscService.hide(s.disc)
			end
			breakResult(s, "Stalled")
		elseif D.phase == "Flight" and now() - D.flightAt > BREAK_FLIGHT then
			breakResult(s, "Incomplete")
		end
	end,
	onTech = function(s: Session, tech: string, _quality: string, _info: string?)
		local D = s.data
		if tech == "Break" and (D.phase == "Hold" or D.phase == "Flight") then
			D.breakTech = true
			if D.release then
				D.release.breakTech = true
			end
		end
	end,
	onThrown = function(s: Session, d: any, info: any)
		local D = s.data
		if D.phase ~= "Hold" or info.id ~= s.actor.id then
			return
		end
		D.phase = "Flight"
		D.flightAt = now()
		local p = info.params
		local _, right = ThrowModel.basis(p.yaw)
		local mirror = if p.leftHanded then -1 else 1
		local pivot = p.pivot or services.MovementService.pivotOf(s.actor.id) or info.pos
		local releaseLat = (info.launch.releasePos - pivot):Dot(right) * mirror
		local mActor = services.PlayerService.get(D.marker)
		local mroot = if mActor then services.PlayerService.root(mActor) else nil
		local markLat = if mroot then (mroot.Position - pivot):Dot(right) * mirror else -releaseLat
		D.release = {
			throwSide = sideName(releaseLat),
			markSide = sideName(markLat),
			broke = (releaseLat >= 0) == (markLat >= 0),
			breakTech = D.breakTech == true,
			step = flat(p.step or Vector3.zero).Magnitude,
			height = p.height,
			stance = services.DefenseService.stanceOf(D.marker),
		}
		local bt, bp = markBlock(s, d, info, pivot)
		if bt and bp then
			-- deflect the disc at the hands, when it gets there
			local contactT = (d.launchTime :: number) + bt
			local at = DiscPhysics.copy(info.launch.state)
			DiscPhysics.advanceTo(at, bt, d.wind, layout.origin.Y - 100)
			local discVel = DiscPhysics.velocity(at)
			local flightId = d.flightId
			local markerId = D.marker
			local C = DiscConfig.Catch
			task.delay(math.max(0, contactT - now()), function()
				if d.mode ~= "Flight" or d.flightId ~= flightId then
					return
				end
				local away = flat(bp - pivot)
				local push = if away.Magnitude > 0.1 then away.Unit * (3 * DiscConfig.Tempo) else Vector3.zero
				local newVel = discVel * C.BlockCarry + Vector3.new(0, C.BlockDown, 0) + push
				services.DiscService.deflect(d, bp, newVel, nil, nil, contactT, markerId)
				Net.event("Effect"):FireAllClients("HandBlock", bp, markerId, "Clean", "Mark")
			end)
			breakResult(s, "Blocked")
		end
	end,
	onCaught = function(s: Session, d: any, info: any)
		local D = s.data
		if D.phase == "Flight" and table.find(D.receivers or {}, info.id) then
			breakResult(s, "Complete")
		end
		task.delay(0.5, function()
			if sessions[s.actor.id] == s and d.mode == "Held" and d.holder ~= s.actor.id then
				services.DiscService.hide(d)
			end
		end)
	end,
	onGrounded = function(s: Session, d: any, land: Vector3)
		services.DiscService.placeOnGround(d, land)
		if s.data.phase == "Flight" then
			breakResult(s, "Incomplete")
		end
	end,
}

---------------------------------------------------------------------------
-- Combo lab
---------------------------------------------------------------------------

local CHALLENGES = {
	{
		name = "Sold!",
		hint = "Jab (Q, no steer), then hold A or D and Q again",
		seq = { { tech = "FakeCommit" }, { tech = "SnapCut", info = "Sold" } },
	},
	{
		name = "Plant and Go",
		hint = "Plant (Q, no direction), then a PERFECT restart (Q / F / SPACE as you stop)",
		seq = { { tech = "MomentumCancel" }, { tech = "SnapCut", info = "Restart", quality = "Perfect" } },
	},
	{
		name = "Cut-Burst",
		hint = string.format(
			"Snap Cut, then Burst (F) within %.2f s (Perfect)",
			MovementConfig.BurstStep.CutChainWindow
		),
		seq = { { tech = "SnapCut" }, { tech = "BurstStep", quality = "Perfect" } },
	},
	{
		name = "Stick the Landing",
		hint = "Jump, Air Redirect (Q), Precision Landing (C)",
		seq = { { tech = "Jump" }, { tech = "AirRedirect" }, { tech = "PrecisionLanding" } },
	},
	{
		name = "Slide Cut",
		hint = "Slide (C), then cut out of it (Q)",
		seq = { { tech = "Slide" }, { tech = "SlideCut" } },
	},
	{
		name = "Get Up!",
		hint = "Dive (E), then pop up (SPACE / Q / F)",
		seq = { { tech = "Dive" }, { tech = "RecoveryChain" } },
	},
	{
		name = "Off the Wall",
		hint = "Wall Rebound (SPACE beside a pink wall in the air), then Air Redirect",
		seq = { { tech = "WallRebound" }, { tech = "AirRedirect" } },
	},
	{
		name = "Full Send",
		hint = "Snap Cut, Burst Step, Layout",
		seq = { { tech = "SnapCut" }, { tech = "BurstStep" }, { tech = "Dive" } },
	},
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
	hud(
		s,
		string.format("COMBO LAB  %d/%d", done, #CHALLENGES),
		table.concat(lines, "\n"),
		{ progress = done / #CHALLENGES, list = true }
	)
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
					finish(
						s,
						"COMBO LAB COMPLETE",
						{ "Every chain landed. Now do it with a disc in the air." },
						"Combo",
						1,
						false
					)
				end
			end
		end
	end,
}

---------------------------------------------------------------------------
-- Reset Lab: the signature moves
---------------------------------------------------------------------------

-- High floaters keep arriving a few studs over your head at the Combo Lab
-- (it has rebound walls). Tip them in the air (Secondary as they reach your
-- hands) to reset your air moves, then chase and catch. Every signature move
-- you land is ticked off and scores its points; the drill ends when the
-- list is done or after RESET_LAUNCHES discs.
local RESET_GOALS = { "TipReset", "ResetGrab", "Skyball", "DoubleLayout", "WallTip", "DoubleTip" }
local RESET_LAUNCHES = 40
local RESET_LOB_HEIGHT = 7.5 -- the disc arrives this far above your feet
local RESET_LAUNCH_DISTANCE = 34

local function resetStatus(s: Session): number
	local lines = {}
	local done = 0
	for _, id in RESET_GOALS do
		local def = SignaturesConfig.List[id]
		local ok = s.data.done[id] == true
		if ok then
			done += 1
		end
		table.insert(lines, (if ok then "[x] " else "[ ] ") .. def.name .. " — " .. def.how)
	end
	table.insert(lines, string.format("Disc %d / %d · score %d", s.data.launches, RESET_LAUNCHES, s.data.score))
	hud(
		s,
		string.format("RESET LAB  %d/%d", done, #RESET_GOALS),
		table.concat(lines, "\n"),
		{ progress = done / #RESET_GOALS, list = true }
	)
	return done
end

local function resetFinish(s: Session, title: string)
	local lines = { string.format("Signature points: %d", s.data.score) }
	for _, id in RESET_GOALS do
		if not s.data.done[id] then
			table.insert(lines, "Still to land: " .. SignaturesConfig.List[id].name)
		end
	end
	finish(s, title, lines, "ResetLab", s.data.score, false)
end

local function resetLaunch(s: Session)
	if s.data.waiting then
		return
	end
	s.data.waiting = true
	task.delay(1.1, function()
		if sessions[s.actor.id] ~= s or s.ended then
			return
		end
		s.data.waiting = false
		if s.data.launches >= RESET_LAUNCHES then
			resetFinish(s, "RESET LAB")
			return
		end
		local r = root(s)
		if not r then
			return
		end
		if s.disc and s.disc.mode == "Held" then
			services.DiscService.hide(s.disc)
		end
		s.data.launches += 1
		local st = layout.stations.Combo
		local feet = r.Position - Vector3.new(0, services.MovementService.standHeight(s.actor.id), 0)
		-- lead a moving player a little; launch from in front of them
		local lead = flat(r.AssemblyLinearVelocity) * 0.9
		local target = feet + lead + Vector3.new(0, RESET_LOB_HEIGHT, 0)
		local origin = feet + st.facing * RESET_LAUNCH_DISTANCE + Vector3.new(0, 3, 0)
		launchAt(s, origin, target, "Backhand", 0, true)
		resetStatus(s)
	end)
end

DRILLS.ResetLab = {
	start = function(s: Session)
		local st = layout.stations.Combo
		teleport(s, st.start, st.facing)
		s.data.done = {}
		s.data.score = 0
		s.data.launches = 0
		s.data.waiting = false
		send(s, "DrillTick", {
			text = "Jump at the disc and press RIGHT MOUSE as it reaches your hands: a TIP gives your air moves back.",
		})
		resetStatus(s)
		resetLaunch(s)
	end,
	onCaught = function(s: Session, _d: any, _info: any)
		resetLaunch(s)
	end,
	onGrounded = function(s: Session, d: any, land: Vector3)
		services.DiscService.placeOnGround(d, land)
		resetLaunch(s)
	end,
	onSignature = function(s: Session, hit: any)
		s.data.score += hit.points
		local fresh = s.data.done[hit.id] ~= true and table.find(RESET_GOALS, hit.id) ~= nil
		s.data.done[hit.id] = true
		send(s, "DrillTick", { text = string.format("%s +%d%s", hit.name, hit.points, if fresh then "  ✓" else "") })
		if resetStatus(s) >= #RESET_GOALS then
			resetFinish(s, "RESET LAB COMPLETE")
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
	services.PlayerService.setLine(actor, nil, nil)
	services.PlayerService.teleport(actor, layout.entry, { face = true })
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
	services.PlayerService.teleport(actor, layout.entry, { face = true })
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
	services.MovementService.SignatureHit:Connect(function(actorId: number, hit: any)
		local s = sessions[actorId]
		if s and not s.ended then
			local drill = DRILLS[s.drill]
			if drill and drill.onSignature then
				drill.onSignature(s, hit)
			end
		end
	end)
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
