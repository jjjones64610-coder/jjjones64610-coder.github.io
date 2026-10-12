--!strict
-- LeaderboardService — seasonal ranked leaderboard on an OrderedDataStore.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local ProgressionConfig = require(Shared.Config.Progression)

local LeaderboardService = {}

local store: OrderedDataStore? = nil
local cache: { any } = {}
local cachedAt = -math.huge
local lastSubmit: { [number]: number } = {}
local names: { [number]: string } = {}

function LeaderboardService.submit(player: Player, rating: number)
	local ods = store
	if not ods then
		return
	end
	local clock = os.clock()
	if (lastSubmit[player.UserId] or -math.huge) > clock - 30 then
		return
	end
	lastSubmit[player.UserId] = clock
	task.spawn(function()
		pcall(function()
			(ods :: OrderedDataStore):SetAsync(tostring(player.UserId), math.floor(rating))
		end)
	end)
end

local function refresh()
	local ods = store
	if not ods then
		return
	end
	local ok, pages = pcall(function()
		return (ods :: OrderedDataStore):GetSortedAsync(false, 50)
	end)
	if not ok or not pages then
		return
	end
	local list = {}
	for rank, entry in (pages :: DataStorePages):GetCurrentPage() do
		local userId = tonumber(entry.key) or 0
		local name = names[userId]
		if not name then
			local okName, result = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			name = if okName and type(result) == "string" then result else ("Player " .. entry.key)
			names[userId] = name
		end
		table.insert(list, {
			rank = rank,
			userId = userId,
			name = name,
			rating = entry.value,
			division = ProgressionConfig.division(entry.value).name,
		})
	end
	cache = list
	cachedAt = os.clock()
end

function LeaderboardService.Init(_s: any)
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore("UB_Rating_" .. ProgressionConfig.Rating.Season)
	end)
	if ok then
		store = result
	end
end

function LeaderboardService.Start()
	Net.func("GetLeaderboard").OnServerInvoke = function(_player)
		return { season = ProgressionConfig.Rating.Season, entries = cache, age = os.clock() - cachedAt }
	end
	-- refresh in the background so the remote never yields on DataStore calls
	task.spawn(function()
		while true do
			refresh()
			task.wait(90)
		end
	end)
end

return LeaderboardService
