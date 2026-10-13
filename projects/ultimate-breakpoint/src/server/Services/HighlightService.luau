--!strict
--[[
	HighlightService — recognises plays worth celebrating.

	Highlights come only from validated server facts: the zone that made a
	catch, whether the catcher was airborne, distances, defenders nearby,
	technique chains the server accepted and converted into the play (at the
	claim time, so a catch that ended a chain on the catcher's screen counts).
	A highlight never pauses play: clients show a short banner, the crowd
	reacts.

	  LAYOUT        catch made with the dive zone
	  SKY           airborne catch with a defender within 4.5 studs
	  HUCK          completion longer than HuckFraction (55 %) of the playing
	                field (Mini ~88 studs, Normal ~132)
	  CONTESTED     clean catch that won a contest
	  FLOW xN       N consecutive quick releases (catch-and-go passing)
	  COMBO         movement chain converted into the catch (tiered)
	  LAYOUT D / HAND BLOCK / BLOCK / INTERCEPTION
	  CALLAHAN, GREATEST, HAMMER / BLADE GOAL, CLUTCH, UNIVERSE, FLOW STATE
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Actors = require(Shared.Actors)
local ProgressionConfig = require(Shared.Config.Progression)

local HighlightService = {}

-- A completion at least this share of the playing field's length is a HUCK.
HighlightService.HuckFraction = 0.55

local services: any

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function HighlightService.broadcast(kind: string, actorId: number, score: number, text: string, tags: { string }?)
	local actor = services.PlayerService.get(actorId)
	local root = actor and services.PlayerService.root(actor)
	Net.event("Highlight"):FireAllClients({
		kind = kind,
		id = actorId,
		name = if actor then actor.name else "",
		team = if actor then actor.team else "",
		text = text,
		score = score,
		tags = tags or {},
		pos = if root then root.Position else nil,
	})
	if services.MatchService.phase() ~= "Intermission" then
		services.MatchService.stat(actorId, "highlights")
	end
end

local function defenderNear(actorId: number, team: string, radius: number): boolean
	local root = Actors.rootOf(actorId)
	if not root then
		return false
	end
	for _, a in services.PlayerService.all() do
		if a.role == "Match" and a.team ~= team and a.team ~= "N" then
			local r = services.PlayerService.root(a)
			if r and (r.Position - root.Position).Magnitude <= radius then
				return true
			end
		end
	end
	return false
end

local function has(outcomes: { any }, kind: string): any
	for _, o in outcomes do
		if o.kind == kind then
			return o
		end
	end
	return nil
end

-- Converts the actor's movement chain into this play (x2 score and XP).
local function convertCombo(actorId: number, payoff: string, at: number?): any
	local summary = services.MovementService.convertCombo(actorId, payoff, at)
	if not summary then
		return nil
	end
	local player = Actors.playerOf(actorId)
	if player then
		Net.event("Combo"):FireClient(player, summary)
		services.ProgressionService.combo(player, summary)
	end
	return summary
end

function HighlightService.onCatch(info: any, lastPass: any, outcomes: { any })
	local tags: { string } = {}
	local score = 0
	local completion = has(outcomes, "Completion")
	local interception = has(outcomes, "Interception")
	if info.zone == "Dive" then
		table.insert(tags, if interception then "LAYOUT D" else "LAYOUT")
		score += 500
		services.MatchService.stat(info.id, "layouts")
	end
	if not info.grounded and info.zone ~= "Dive" and defenderNear(info.id, info.team, 4.5) then
		table.insert(tags, "SKY")
		score += 450
	end
	if completion and lastPass and lastPass.releasePos then
		local dist = flat(info.pos - lastPass.releasePos).Magnitude
		if dist >= HighlightService.HuckFraction * services.ArenaService.field().length then
			table.insert(tags, "HUCK")
			score += 300
			services.MatchService.stat(info.id, "hucks")
			if lastPass.thrower then
				services.MatchService.stat(lastPass.thrower, "hucks")
			end
		end
		if (lastPass.flow or 0) >= 3 then
			table.insert(tags, "FLOW x" .. lastPass.flow)
			score += 120 * lastPass.flow
		end
	end
	if info.contested and info.quality == "Clean" then
		table.insert(tags, "CONTESTED")
		score += 250
	end
	if interception then
		table.insert(tags, "INTERCEPTION")
		score += 300
	end
	local payoff = if info.zone == "Dive" then "Layout Catch" elseif interception then "Interception" else "Catch"
	local combo = convertCombo(info.id, payoff, if type(info.t) == "number" then info.t else nil)
	if combo and combo.tier then
		table.insert(tags, combo.tier .. " COMBO")
		score += math.floor(combo.score / 4)
	end
	if #tags > 0 and score >= 250 then
		HighlightService.broadcast("Catch", info.id, score, table.concat(tags, "  ·  "), tags)
	end
end

function HighlightService.onTouched(info: any, _lastPass: any)
	if info.kind == "Bobble" then
		return
	end
	local tags: { string } = {}
	local score = 250
	if info.kind == "HandBlock" then
		table.insert(tags, "HAND BLOCK")
		score = 600
	elseif info.zone == "Dive" then
		table.insert(tags, "LAYOUT D")
		score = 650
		services.MatchService.stat(info.id, "layouts")
	else
		table.insert(tags, "BLOCK")
	end
	local combo = convertCombo(info.id, "Block")
	if combo and combo.tier then
		table.insert(tags, combo.tier .. " COMBO")
		score += math.floor(combo.score / 4)
	end
	HighlightService.broadcast("Block", info.id, score, table.concat(tags, "  ·  "), tags)
end

function HighlightService.onGoal(o: any, lastPass: any, clutch: boolean)
	local tags: { string } = {}
	local score = 400
	if o.callahan then
		table.insert(tags, "CALLAHAN")
		score += 1200
	end
	if lastPass and not o.callahan then
		if lastPass.throwType == "Hammer" then
			table.insert(tags, "HAMMER")
			score += 250
		elseif lastPass.throwType == "Blade" then
			table.insert(tags, "BLADE")
			score += 200
		elseif lastPass.throwType == "Scoober" then
			table.insert(tags, "SCOOBER")
			score += 250
		end
	end
	if (o.passes or 0) >= 10 then
		table.insert(tags, "FLOW STATE")
		score += 300
	end
	if o.universe then
		table.insert(tags, "UNIVERSE")
		score += 500
	elseif clutch then
		table.insert(tags, "CLUTCH")
		score += 300
	end
	local name = Actors.nameOf(o.scorer)
	local text = if #tags > 0 then table.concat(tags, "  ·  ") else "GOAL"
	HighlightService.broadcast("Goal", o.scorer, score, text, tags)
	local _ = name
	local _ = ProgressionConfig
end

function HighlightService.Init(s: any)
	services = s
end

function HighlightService.Start() end

return HighlightService
