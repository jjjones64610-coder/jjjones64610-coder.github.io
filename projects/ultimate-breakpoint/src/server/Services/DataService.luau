--!strict
--[[
	DataService — player profiles with DataStoreService.

	  * UpdateAsync everywhere (no blind SetAsync), with retries + backoff.
	  * Session lock: a profile records the JobId that owns it; another server
	    must wait for the lock to expire (or the owner to release it) before
	    taking over, which prevents two servers overwriting each other.
	  * Template merge + validation on load, so old or damaged data upgrades.
	  * Autosave every 90 s, save on leave, save-all in BindToClose.
	  * No API access (e.g. Studio without "Enable Studio Access to API
	    Services") -> profiles live in memory and are marked non-persistent.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)
local InputConfig = require(Shared.Config.Input)
local ProgressionConfig = require(Shared.Config.Progression)

local DataService = {}

DataService.Loaded = Signal.new()

local STORE_NAME = "UB_Profiles_v1"
local LOCK_TIMEOUT = 180 -- seconds before a crashed server's lock is considered stale
local AUTOSAVE = 90
local VERSION = 1

local store: DataStore? = nil
local persistentAvailable = false
local jobId = if game.JobId ~= "" then game.JobId else ("studio-" .. HttpService:GenerateGUID(false))

export type Profile = {
	data: { [string]: any },
	persistent: boolean,
	dirty: boolean,
	loadedAt: number,
	released: boolean,
}

local profiles: { [Player]: Profile } = {}

local function template(): { [string]: any }
	return {
		version = VERSION,
		xp = 0,
		stats = {},
		techMastery = {},
		rating = ProgressionConfig.Rating.Start,
		ratedGames = 0,
		peakRating = ProgressionConfig.Rating.Start,
		personalBests = {},
		drillsDone = {},
		achievements = {},
		cosmetics = { disc = "Classic", trail = "None", celebration = "Point", banner = "Slate", title = "Rookie" },
		settings = { values = table.clone(InputConfig.DefaultSettings), keyboard = {}, gamepad = {} },
		firstJoin = os.time(),
		lastJoin = os.time(),
	}
end

-- Fills missing keys from the template and drops values of the wrong type.
local function reconcile(data: any): { [string]: any }
	local base = template()
	if type(data) ~= "table" then
		return base
	end
	for k, v in base do
		local cur = data[k]
		if cur == nil or type(cur) ~= type(v) then
			data[k] = v
		elseif type(v) == "table" and k ~= "stats" and k ~= "techMastery" and k ~= "personalBests" then
			for k2, v2 in v do
				if cur[k2] == nil or type(cur[k2]) ~= type(v2) then
					cur[k2] = v2
				end
			end
		end
	end
	for k, v in data.stats do
		if type(v) ~= "number" then
			data.stats[k] = nil
		end
	end
	data.version = VERSION
	return data
end

local function withRetries<T>(label: string, fn: () -> T): (boolean, T?)
	local delay = 1
	for attempt = 1, 4 do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		warn(string.format("[DataService] %s failed (attempt %d): %s", label, attempt, tostring(result)))
		if attempt < 4 then
			task.wait(delay)
			delay *= 2
		end
	end
	return false, nil
end

local function key(player: Player): string
	return "u_" .. player.UserId
end

local function load(player: Player): Profile
	if not persistentAvailable or not store then
		return { data = template(), persistent = false, dirty = false, loadedAt = os.clock(), released = false }
	end
	local ds = store :: DataStore
	local loaded: any = nil
	for _ = 1, 5 do
		local stolen = false
		local ok = withRetries("load " .. player.UserId, function()
			ds:UpdateAsync(key(player), function(old: any)
				local now = os.time()
				if type(old) == "table" and type(old.lock) == "table" then
					local lock = old.lock
					if lock.job ~= jobId and type(lock.at) == "number" and now - lock.at < LOCK_TIMEOUT then
						loaded = nil
						return nil -- someone else owns it; don't write
					end
					stolen = lock.job ~= jobId
				end
				local data = reconcile(if type(old) == "table" then old.data else nil)
				data.lastJoin = now
				loaded = data
				return { data = data, lock = { job = jobId, at = now } }
			end)
			return true
		end)
		if not ok then
			break
		end
		if loaded then
			if stolen then
				warn("[DataService] took over a stale session lock for " .. player.UserId)
			end
			return { data = loaded, persistent = true, dirty = false, loadedAt = os.clock(), released = false }
		end
		task.wait(6) -- another server is releasing it
		if not player.Parent then
			break
		end
	end
	warn("[DataService] could not lock profile for " .. player.UserId .. "; using a temporary profile")
	return { data = template(), persistent = false, dirty = false, loadedAt = os.clock(), released = false }
end

local function save(player: Player, release: boolean)
	local profile = profiles[player]
	if not profile or not profile.persistent or profile.released or not store then
		return
	end
	local ds = store :: DataStore
	local data = profile.data
	withRetries("save " .. player.UserId, function()
		ds:UpdateAsync(key(player), function(old: any)
			if type(old) == "table" and type(old.lock) == "table" and old.lock.job ~= jobId then
				-- we lost the lock (another server took over after a timeout)
				return nil
			end
			return { data = data, lock = if release then nil else { job = jobId, at = os.time() } }
		end)
		return true
	end)
	profile.dirty = false
	if release then
		profile.released = true
	end
end

function DataService.get(player: Player): { [string]: any }?
	local p = profiles[player]
	return if p then p.data else nil
end

function DataService.isPersistent(player: Player): boolean
	local p = profiles[player]
	return p ~= nil and p.persistent
end

-- Applies fn(data) and marks the profile dirty.
function DataService.update(player: Player, fn: ({ [string]: any }) -> ())
	local p = profiles[player]
	if not p then
		return
	end
	fn(p.data)
	p.dirty = true
end

function DataService.saveNow(player: Player)
	task.spawn(save, player, false)
end

function DataService.Init(_services: any)
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok and result then
		store = result
		-- probe once: Studio without API access throws here
		local probeOk = pcall(function()
			(result :: DataStore):GetAsync("__probe")
		end)
		persistentAvailable = probeOk
	end
	if not persistentAvailable then
		warn(
			"[DataService] DataStores unavailable — profiles will not be saved this session."
				.. (
					if RunService:IsStudio()
						then " (Enable 'Studio Access to API Services' in Game Settings > Security.)"
						else ""
				)
		)
	end
end

function DataService.Start()
	local function onJoin(player: Player)
		local profile = load(player)
		if not player.Parent then
			if profile.persistent then
				profiles[player] = profile
				save(player, true)
				profiles[player] = nil
			end
			return
		end
		profiles[player] = profile
		DataService.Loaded:Fire(player, profile.data)
	end
	Players.PlayerAdded:Connect(onJoin)
	for _, p in Players:GetPlayers() do
		task.spawn(onJoin, p)
	end
	Players.PlayerRemoving:Connect(function(player)
		save(player, true)
		profiles[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE)
			for player, profile in profiles do
				if profile.dirty then
					task.spawn(save, player, false)
				end
			end
		end
	end)
	game:BindToClose(function()
		local pending = 0
		for player in profiles do
			pending += 1
			task.spawn(function()
				save(player, true)
				pending -= 1
			end)
		end
		local started = os.clock()
		while pending > 0 and os.clock() - started < 25 do
			task.wait(0.2)
		end
	end)
end

return DataService
