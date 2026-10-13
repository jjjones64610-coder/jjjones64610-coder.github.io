--!strict
--[[
	ProgressionService — XP, levels, stats, technique mastery, achievements,
	cosmetics and ranked rating. Everything it grants is cosmetic or a record;
	nothing affects movement, throwing or catching.

	  * Match XP is x XP.PvPMultiplier when both teams had human players.
	  * Combos pay from Summary.xpScore: a chain converted into a play pays its
	    doubled score (capped at ComboCap) and counts as converted; a chain
	    that was not converted pays its 25 % share (capped per chain and per
	    match, match play only) once MovementService settles it.
	  * Ranked: rated against the roster's average ratings at the start. A
	    roster player who abandons the match is rated as a loss right away
	    (rankedLoss); the result is then void for everyone else.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local ProgressionConfig = require(Shared.Config.Progression)
local InputConfig = require(Shared.Config.Input)
local MovementConfig = require(Shared.Config.Movement)
local Rating = require(Shared.Rules.Rating)

local ProgressionService = {}

local services: any
local pushQueued: { [Player]: boolean } = {}
local unconvertedPaid: { [number]: number } = {} -- UserId -> unconverted combo XP this match

local XP = ProgressionConfig.XP

local function data(player: Player): { [string]: any }?
	return services.DataService.get(player)
end

local function levelOf(d: { [string]: any }): number
	local level = Rating.levelFromXp(d.xp)
	return level
end

local function unlockedList(d: { [string]: any }, list: { any }): { string }
	local level = levelOf(d)
	local out = {}
	for _, item in list do
		if (item.level and level >= item.level) or (item.achievement and d.achievements[item.achievement]) then
			table.insert(out, item.id)
		end
	end
	return out
end

local SLOTS: { [string]: { any } } = {
	disc = ProgressionConfig.DiscSkins,
	trail = ProgressionConfig.Trails,
	celebration = ProgressionConfig.Celebrations,
	banner = ProgressionConfig.Banners,
	title = ProgressionConfig.Titles,
}

local function isUnlocked(d: { [string]: any }, slot: string, id: string): boolean
	local list = (SLOTS :: any)[slot]
	if not list then
		return false
	end
	return table.find(unlockedList(d, list), id) ~= nil
end

function ProgressionService.equipped(player: Player, slot: string): string
	local d = data(player)
	local fallback = (
		{ disc = "Classic", trail = "None", celebration = "Point", banner = "Slate", title = "Rookie" } :: any
	)[slot] or ""
	if not d then
		return fallback
	end
	local id = d.cosmetics[slot]
	if type(id) == "string" and isUnlocked(d, slot, id) then
		return id
	end
	return fallback
end

local function stampCharacter(player: Player)
	local c = player.Character
	local d = data(player)
	if not c or not d then
		return
	end
	local titleId = ProgressionService.equipped(player, "title")
	local title = titleId
	for _, t in ProgressionConfig.Titles do
		if t.id == titleId then
			title = t.name
		end
	end
	c:SetAttribute("UBTitle", title)
	c:SetAttribute("UBBanner", ProgressionService.equipped(player, "banner"))
	c:SetAttribute("UBTrail", ProgressionService.equipped(player, "trail"))
	c:SetAttribute("UBLevel", levelOf(d))
	c:SetAttribute("LeftHanded", d.settings.values.LeftHanded == true)
	c:SetAttribute("UBDivision", ProgressionConfig.division(d.rating).name)
end

local function snapshot(player: Player): { [string]: any }?
	local d = data(player)
	if not d then
		return nil
	end
	local level, into, need = Rating.levelFromXp(d.xp)
	local achievements = {}
	for _, a in ProgressionConfig.Achievements do
		table.insert(achievements, {
			id = a.id,
			name = a.name,
			description = a.description,
			progress = math.min(d.stats[a.stat] or 0, a.goal),
			goal = a.goal,
			done = d.achievements[a.id] == true,
		})
	end
	local unlocked = {}
	for slot, list in SLOTS do
		unlocked[slot] = unlockedList(d, list)
	end
	local division = ProgressionConfig.division(d.rating)
	return {
		level = level,
		xpInto = into,
		xpNeed = need,
		xp = d.xp,
		rating = d.rating,
		peakRating = d.peakRating,
		division = division.name,
		ratedGames = d.ratedGames,
		stats = d.stats,
		techMastery = d.techMastery,
		achievements = achievements,
		unlocked = unlocked,
		equipped = d.cosmetics,
		personalBests = d.personalBests,
		drillsDone = d.drillsDone,
		settings = d.settings,
		persistent = services.DataService.isPersistent(player),
	}
end

ProgressionService.snapshot = snapshot

local function push(player: Player)
	if pushQueued[player] then
		return
	end
	pushQueued[player] = true
	task.delay(0.5, function()
		pushQueued[player] = nil
		if player.Parent then
			local snap = snapshot(player)
			if snap then
				Net.event("Profile"):FireClient(player, snap)
			end
		end
	end)
end

ProgressionService.push = push

local function checkAchievements(player: Player)
	local d = data(player)
	if not d then
		return
	end
	for _, a in ProgressionConfig.Achievements do
		if not d.achievements[a.id] and (d.stats[a.stat] or 0) >= a.goal then
			d.achievements[a.id] = true
			Net.event("Notify"):FireClient(player, "Achievement", a.name, { description = a.description })
			stampCharacter(player)
		end
	end
end

function ProgressionService.xp(player: Player, amount: number, reason: string?)
	local d = data(player)
	if not d or amount <= 0 then
		return
	end
	local before = levelOf(d)
	services.DataService.update(player, function(dd: { [string]: any })
		dd.xp += math.floor(amount)
	end)
	local after = levelOf(d)
	if after > before then
		local unlocks = {}
		for slot, list in SLOTS do
			for _, item in list do
				if item.level and item.level > before and item.level <= after then
					table.insert(unlocks, { slot = slot, name = item.name })
				end
			end
		end
		Net.event("Notify"):FireClient(player, "LevelUp", "LEVEL " .. after, { unlocks = unlocks })
		stampCharacter(player)
	end
	local _ = reason
	push(player)
end

function ProgressionService.stat(actor: any, key: string, n: number)
	local player = actor.player
	if not player then
		return
	end
	services.DataService.update(player, function(d: { [string]: any })
		d.stats[key] = (d.stats[key] or 0) + n
	end)
	local reward = (XP :: any)[({
		goals = "Goal",
		assists = "Assist",
		callahans = "Callahan",
		catches = "Catch",
		completions = "Completion",
		interceptions = "Interception",
		blocks = "Block",
		layouts = "Layout",
		greatests = "Greatest",
		highlights = "Highlight",
	} :: any)[key] or ""]
	if reward then
		ProgressionService.xp(player, reward * n, key)
	end
	checkAchievements(player)
	push(player)
end

local function comboXp(summary: any, cap: number): number
	local points = if type(summary.xpScore) == "number" then summary.xpScore else (summary.score or 0)
	return math.clamp(math.floor(points / 100 * XP.ComboPerHundred), 0, cap)
end

-- A chain converted into a play (catch, interception, block).
function ProgressionService.combo(player: Player, summary: any)
	local amount = comboXp(summary, XP.ComboCap)
	if amount > 0 then
		ProgressionService.xp(player, amount, "combo")
	end
	services.DataService.update(player, function(d: { [string]: any })
		d.stats.combosConverted = (d.stats.combosConverted or 0) + 1
		if summary.tier == "BREAKPOINT" then
			d.stats.breakpointCombos = (d.stats.breakpointCombos or 0) + 1
		end
	end)
	checkAchievements(player)
end

-- A chain that was not converted: its 25 % share, during match play only.
function ProgressionService.comboUnconverted(player: Player, summary: any)
	local actor = services.PlayerService.fromPlayer(player)
	local phase = services.MatchService.phase()
	if not actor or actor.role ~= "Match" or (phase ~= "Live" and phase ~= "Pull") then
		return
	end
	local paid = unconvertedPaid[player.UserId] or 0
	local amount = math.min(comboXp(summary, XP.UnconvertedComboCap), XP.UnconvertedMatchCap - paid)
	if amount > 0 then
		unconvertedPaid[player.UserId] = paid + amount
		ProgressionService.xp(player, amount, "combo")
	end
end

local function onTech(actorId: number, tech: string, quality: string)
	local actor = services.PlayerService.get(actorId)
	if not actor or not actor.player then
		return
	end
	services.DataService.update(actor.player, function(d: { [string]: any })
		local m = d.techMastery[tech]
		if type(m) ~= "table" then
			m = { count = 0, perfect = 0 }
			d.techMastery[tech] = m
		end
		m.count += 1
		if quality == "Perfect" then
			m.perfect += 1
		end
		if (MovementConfig.ComboPoints :: any)[tech] and (MovementConfig.ComboPoints :: any)[tech] > 0 then
			d.stats.techs = (d.stats.techs or 0) + 1
		end
	end)
end

export type MatchResult = {
	ranked: boolean, -- the match counts for rating (ranked and nobody on the roster left)
	roster: { [number]: string }, -- ranked roster: actor id -> team
	ratings: { [string]: number }, -- average roster rating per team at the start
	margin: number,
	pvp: boolean, -- both teams had human players
}

function ProgressionService.matchStarted()
	unconvertedPaid = {}
end

local function rate(player: Player, mine: number, theirs: number, won: boolean, margin: number): { [string]: number }?
	local d = data(player)
	if not d then
		return nil
	end
	local old = d.rating
	local new = Rating.update(old, d.ratedGames, mine, theirs, won, margin)
	services.DataService.update(player, function(dd: { [string]: any })
		dd.rating = new
		dd.ratedGames += 1
		dd.peakRating = math.max(dd.peakRating, new)
	end)
	services.LeaderboardService.submit(player, new)
	return { old = old, new = new }
end

-- A ranked roster player abandoned the match: rated as a loss now. (No
-- immediate save: when they are leaving, DataService's release save follows
-- right after and a second concurrent save could re-take the session lock.)
function ProgressionService.rankedLoss(player: Player, mine: number, theirs: number)
	if rate(player, mine, theirs, false, 0) then
		ProgressionService.stat({ player = player }, "matches", 1)
		stampCharacter(player)
	end
end

-- Called once per finished match. Returns rating changes for the summary.
function ProgressionService.matchEnded(winner: string?, rows: { any }, result: MatchResult): { [string]: any }
	local changes = {}
	local mult = if result.pvp then XP.PvPMultiplier else 1
	for _, row in rows do
		local player = services.Actors.playerOf(row.id)
		if player then
			local won = winner == row.team
			ProgressionService.stat({ player = player }, "matches", 1)
			if won then
				ProgressionService.stat({ player = player }, "wins", 1)
			end
			ProgressionService.xp(player, (XP.MatchPlayed + (if won then XP.MatchWon else 0)) * mult, "match")
			local rosterTeam = result.roster[row.id]
			if result.ranked and rosterTeam then
				local mine = if rosterTeam == "A" then result.ratings.A else result.ratings.B
				local theirs = if rosterTeam == "A" then result.ratings.B else result.ratings.A
				local change = rate(player, mine, theirs, winner == rosterTeam, result.margin)
				if change then
					changes[tostring(row.id)] = change
				end
			end
			stampCharacter(player)
			services.DataService.saveNow(player)
			push(player)
		end
	end
	return changes
end

function ProgressionService.recordPersonalBest(
	player: Player,
	drill: string,
	value: number,
	lowerIsBetter: boolean
): boolean
	local d = data(player)
	if not d then
		return false
	end
	local prev = d.personalBests[drill]
	local better = prev == nil or (if lowerIsBetter then value < prev else value > prev)
	services.DataService.update(player, function(dd: { [string]: any })
		if better then
			dd.personalBests[drill] = value
		end
		if not dd.drillsDone[drill] then
			dd.drillsDone[drill] = true
			local count = 0
			for _ in dd.drillsDone do
				count += 1
			end
			dd.stats.drillsCompleted = count
		end
	end)
	ProgressionService.xp(player, XP.TrainingDrill + (if better and prev ~= nil then XP.PersonalBest else 0), "drill")
	checkAchievements(player)
	push(player)
	return better
end

local function sanitizeSettings(raw: any): any
	if type(raw) ~= "table" then
		return nil
	end
	local out = { values = {}, keyboard = {}, gamepad = {} }
	if type(raw.values) == "table" then
		for k, default in InputConfig.DefaultSettings do
			local v = raw.values[k]
			if type(v) == type(default) then
				if type(v) == "number" then
					v = math.clamp(v, 0, 200)
				end
				out.values[k] = v
			else
				out.values[k] = default
			end
		end
	end
	for _, scheme in { "keyboard", "gamepad" } do
		local src = raw[scheme]
		if type(src) == "table" then
			for _, action in InputConfig.Actions do
				local keys = src[action]
				if type(keys) == "table" then
					local clean = {}
					for i, k in keys do
						if i <= 3 and type(k) == "string" and #k <= 32 then
							table.insert(clean, k)
						end
					end
					out[scheme][action] = clean
				end
			end
		end
	end
	return out
end

function ProgressionService.action(player: Player, kind: string, payload: any)
	if
		kind == "Equip"
		and type(payload) == "table"
		and type(payload.slot) == "string"
		and type(payload.id) == "string"
	then
		local d = data(player)
		if d and isUnlocked(d, payload.slot, payload.id) then
			services.DataService.update(player, function(dd: { [string]: any })
				dd.cosmetics[payload.slot] = payload.id
			end)
			stampCharacter(player)
			push(player)
		end
	elseif kind == "SaveSettings" then
		local clean = sanitizeSettings(payload)
		if clean then
			services.DataService.update(player, function(dd: { [string]: any })
				dd.settings = clean
			end)
			stampCharacter(player)
		end
	end
end

function ProgressionService.Init(s: any)
	services = s
end

function ProgressionService.Start()
	services.DataService.Loaded:Connect(function(player)
		stampCharacter(player)
		push(player)
	end)
	services.PlayerService.CharacterSpawned:Connect(function(actor)
		if actor.player then
			task.defer(stampCharacter, actor.player)
		end
	end)
	services.MovementService.TechAccepted:Connect(onTech)
	Net.func("GetProfile").OnServerInvoke = function(player)
		return snapshot(player)
	end
	Players.PlayerRemoving:Connect(function(p)
		pushQueued[p] = nil
		unconvertedPaid[p.UserId] = nil
	end)
end

return ProgressionService
