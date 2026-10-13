--!strict
--[[
	TeamService — makes the world match the match plan (Rules/MatchPlan).

	MatchPlan (pure, unit-tested) decides who plays for which team and who is
	on the field each point; this service applies it to real actors:

	  * match start   every non-training human is split by rating (counts
	                  within one); at most TeamSize per team play ("Match"),
	                  the rest sit on the bench ("Bench"). A ranked match
	                  records its roster (and the roster's ratings) here.
	  * each point    setupLine(point) picks the line (whoever sat out
	                  longest first) and tops it up with bots to exactly
	                  TeamSize when the mode has FillWithBots.
	  * late joiner   goes to the team with fewer humans, on the bench until
	                  the next point, then takes a bot's spot.
	  * leaver        removed at once; a bot takes their spot straight away
	                  (FillWithBots) so the point is not played short.

	Bots are spawned in the background (model creation yields), one pass at
	a time; LineChanged fires after every pass so MatchService can put new
	arrivals where they belong. Nothing here teleports.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchPlan = require(Shared.Rules.MatchPlan)
local Rating = require(Shared.Rules.Rating)
local Signal = require(Shared.Util.Signal)

local TeamService = {}

TeamService.LineChanged = Signal.new() -- () roles, lines or bots changed
TeamService.TrainingChanged = Signal.new() -- (actor, training)

local services: any
local plan: MatchPlan.Plan? = nil
local rosterRatings: { [string]: number } = { A = 0, B = 0 }

local working = false
local again = false

local function humansAvailable(): { any }
	local list = {}
	for _, a in services.PlayerService.humans() do
		if a.role ~= "Training" then
			table.insert(list, a)
		end
	end
	return list
end

local function entryFor(actor: any): MatchPlan.Entry
	local data = actor.player and services.DataService.get(actor.player)
	local rating = if data and type(data.rating) == "number" then data.rating else nil
	return { id = actor.id, rating = rating }
end

-- Every human's team and role as the plan says.
local function syncRoles(p: MatchPlan.Plan)
	for _, m in MatchPlan.members(p) do
		local actor = services.PlayerService.get(m.id)
		if actor and (actor.team ~= m.team or actor.role ~= m.role) then
			services.PlayerService.setTeam(actor, m.team, m.role)
		end
	end
end

-- One reconciliation of the registered bots with what the line needs.
-- Spawning yields; the plan may be replaced meanwhile.
local function botPass(p: MatchPlan.Plan)
	for _, team in { "A", "B" } do
		for _, id in table.clone(p.teams[team].bots) do
			if not services.PlayerService.get(id) then
				MatchPlan.removeBot(p, id)
			end
		end
	end
	local work = MatchPlan.botWork(p)
	for _, id in work.remove do
		MatchPlan.removeBot(p, id)
		services.BotService.remove(id)
	end
	for _, team in { "A", "B" } do
		for _ = 1, work.spawn[team] do
			local id = services.BotService.spawn(team)
			if plan ~= p then
				-- the match ended while the model was being built
				services.BotService.remove(id)
				return
			end
			if not services.PlayerService.get(id) then
				-- model creation failed; the next apply() tries again
				return
			end
			MatchPlan.addBot(p, team, id)
			-- place each bot as soon as it exists
			TeamService.LineChanged:Fire()
		end
	end
end

-- Serialised background bot work; a request during a pass schedules another.
local function runBots()
	if working then
		again = true
		return
	end
	working = true
	task.spawn(function()
		repeat
			again = false
			local p = plan
			if p then
				local ok, err = pcall(function()
					botPass(p)
				end)
				if not ok then
					warn("[TeamService] " .. tostring(err))
				end
			end
			TeamService.LineChanged:Fire()
		until not again
		working = false
	end)
end

local function apply()
	local p = plan
	if not p then
		return
	end
	syncRoles(p)
	TeamService.LineChanged:Fire()
	runBots()
end

-- Waits (up to `timeout` seconds) until no bot is being spawned.
function TeamService.waitForBots(timeout: number)
	local deadline = os.clock() + timeout
	while working and os.clock() < deadline do
		task.wait(0.05)
	end
end

-- Splits every non-training human into teams for a new match.
function TeamService.assignForMatch(mode: any)
	local entries: { MatchPlan.Entry } = {}
	for _, a in humansAvailable() do
		table.insert(entries, entryFor(a))
	end
	local p = MatchPlan.new(mode, entries, { ranked = mode.Ranked == true })
	plan = p
	-- the roster's average ratings at the start (ranked rating updates)
	local byTeam: { [string]: { number } } = { A = {}, B = {} }
	for _, e in entries do
		local team = MatchPlan.slot(p, e.id)
		if team then
			table.insert(byTeam[team], Rating.ratingOf(e))
		end
	end
	rosterRatings = { A = Rating.teamRating(byTeam.A), B = Rating.teamRating(byTeam.B) }
	apply()
end

-- Picks the line for a point (idempotent per point number) and applies it.
function TeamService.setupLine(point: number)
	local p = plan
	if not p then
		return
	end
	MatchPlan.line(p, point)
	apply()
end

local function existing(ids: { number }): { number }
	local out = {}
	for _, id in ids do
		if services.PlayerService.get(id) then
			table.insert(out, id)
		end
	end
	return out
end

-- Actor ids on the field for `team` (line humans first, then bots).
function TeamService.lineFor(team: string): { number }
	local p = plan
	if not p then
		return {}
	end
	return existing(MatchPlan.lineFor(p, team))
end

-- Benched humans of `team`.
function TeamService.benchFor(team: string): { number }
	local p = plan
	if not p then
		return {}
	end
	return existing(MatchPlan.benchFor(p, team))
end

-- (index, count) of an actor's line-up spot, or (nil, count) off the line.
function TeamService.lineIndex(id: number): (number?, number)
	local p = plan
	if not p then
		return nil, 0
	end
	return MatchPlan.lineIndex(p, id)
end

-- Per-team counts (humans incl. bench, line, bench, bots), or nil between matches.
function TeamService.counts(): { [string]: MatchPlan.TeamCounts }?
	local p = plan
	if not p then
		return nil
	end
	return MatchPlan.counts(p)
end

function TeamService.rankedResult(): MatchPlan.RankedResult?
	local p = plan
	if not p then
		return nil
	end
	return MatchPlan.rankedResult(p)
end

-- Average rating of each team's ranked roster at the start.
function TeamService.rosterRatings(): { [string]: number }
	return table.clone(rosterRatings)
end

-- The team an actor was on in this ranked match's roster, or nil.
function TeamService.rankedRosterTeam(id: number): string?
	local p = plan
	if not p or not p.ranked then
		return nil
	end
	return p.roster[id]
end

function TeamService.inMatch(): boolean
	return plan ~= nil
end

-- A player arriving (or leaving training) during a match. Returns their
-- team and role ("Bench" until the next point is picked).
function TeamService.placeLateJoiner(actor: any): (string, string)
	local p = plan
	if not p then
		services.PlayerService.setTeam(actor, "N", "Spectate")
		return "N", "Spectate"
	end
	local team, role = MatchPlan.join(p, entryFor(actor))
	services.PlayerService.setTeam(actor, team, role)
	apply()
	return team, role
end

-- A human leaving the match (left the game or went to training).
function TeamService.remove(actor: any): MatchPlan.LeaveResult?
	local p = plan
	if not p or actor.isBot then
		return nil
	end
	local result = MatchPlan.leave(p, actor.id)
	if result then
		apply()
	end
	return result
end

function TeamService.rebalance()
	apply()
end

function TeamService.setTraining(actor: any, training: boolean)
	if training then
		TeamService.remove(actor)
		services.PlayerService.setTeam(actor, "N", "Training")
	elseif plan then
		TeamService.placeLateJoiner(actor)
	else
		services.PlayerService.setTeam(actor, "N", "Spectate")
	end
	TeamService.TrainingChanged:Fire(actor, training)
end

function TeamService.clearMatch()
	local p = plan
	plan = nil
	rosterRatings = { A = 0, B = 0 }
	for _, a in services.PlayerService.all() do
		if a.isBot then
			local inPlan = p ~= nil and p.botTeam[a.id] ~= nil
			if inPlan or a.role == "Match" or a.role == "Bench" then
				services.BotService.remove(a.id)
			end
		elseif a.role ~= "Training" then
			services.PlayerService.setTeam(a, "N", "Spectate")
		end
	end
end

function TeamService.Init(s: any)
	services = s
end

function TeamService.Start() end

return TeamService
