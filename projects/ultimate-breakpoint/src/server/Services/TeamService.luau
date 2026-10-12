--!strict
-- TeamService — fair team assignment, late joiners, bot fill.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rating = require(Shared.Rules.Rating)
local ProgressionConfig = require(Shared.Config.Progression)

local TeamService = {}

local services: any
local currentMode: any = nil

local function humansAvailable(): { any }
	local list = {}
	for _, a in services.PlayerService.humans() do
		if a.role ~= "Training" then
			table.insert(list, a)
		end
	end
	return list
end

function TeamService.counts(): (number, number)
	return #services.PlayerService.onTeam("A"), #services.PlayerService.onTeam("B")
end

local function fillBots()
	local mode = currentMode
	if not mode then
		return
	end
	local humans: { [string]: number } = { A = 0, B = 0 }
	local bots: { [string]: { any } } = { A = {}, B = {} }
	for _, team in { "A", "B" } do
		for _, a in services.PlayerService.onTeam(team) do
			if a.isBot then
				table.insert(bots[team], a)
			else
				humans[team] += 1
			end
		end
	end
	-- bots top both teams up to the same size (never beyond TeamSize)
	local target = 0
	if mode.BotsFillTo > 0 then
		target = math.min(mode.TeamSize, math.max(mode.BotsFillTo, humans.A, humans.B))
	end
	for _, team in { "A", "B" } do
		local want = math.max(0, target - humans[team])
		local have = #bots[team]
		if have > want then
			for i = 1, have - want do
				services.BotService.remove(bots[team][i].id)
			end
		elseif have < want then
			for _ = 1, want - have do
				services.BotService.spawn(team)
			end
		end
	end
end

-- Splits every non-training human into teams for a new match.
function TeamService.assignForMatch(mode: any)
	currentMode = mode
	local humans = humansAvailable()
	if mode.Ranked then
		local entries = {}
		for _, a in humans do
			local data = a.player and services.DataService.get(a.player)
			table.insert(entries, { id = a.id, rating = if data then data.rating else ProgressionConfig.Rating.Start })
		end
		local teamA, teamB = Rating.balance(entries)
		for _, id in teamA do
			services.PlayerService.setTeam(services.PlayerService.get(id), "A", "Match")
		end
		for _, id in teamB do
			services.PlayerService.setTeam(services.PlayerService.get(id), "B", "Match")
		end
	else
		-- shuffle deterministically by a per-match seed, then alternate
		local seed = os.time() % 1000
		table.sort(humans, function(x, y)
			return ((x.id * 7919 + seed) % 1009) < ((y.id * 7919 + seed) % 1009)
		end)
		for i, a in humans do
			services.PlayerService.setTeam(a, if i % 2 == 1 then "A" else "B", "Match")
		end
	end
	fillBots()
end

-- A player arriving (or leaving training) during a match.
function TeamService.placeLateJoiner(actor: any)
	if not currentMode then
		services.PlayerService.setTeam(actor, "N", "Spectate")
		return
	end
	local a, b = TeamService.counts()
	local team = if a <= b then "A" else "B"
	-- replace a bot if that team has one
	for _, m in services.PlayerService.onTeam(team) do
		if m.isBot then
			services.BotService.remove(m.id)
			break
		end
	end
	services.PlayerService.setTeam(actor, team, "Match")
	fillBots()
end

function TeamService.rebalance()
	fillBots()
end

function TeamService.setTraining(actor: any, training: boolean)
	if training then
		services.PlayerService.setTeam(actor, "N", "Training")
		fillBots()
	elseif currentMode then
		TeamService.placeLateJoiner(actor)
	else
		services.PlayerService.setTeam(actor, "N", "Spectate")
	end
end

function TeamService.clearMatch()
	currentMode = nil
	for _, a in services.PlayerService.all() do
		if a.isBot then
			services.BotService.remove(a.id)
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
