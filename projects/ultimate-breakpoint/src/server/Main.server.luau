--!strict
-- ULTIMATE: BREAKPOINT — server bootstrap.
-- Services are initialised in dependency order, then started. Each service
-- receives the shared `services` table in Init so modules never need
-- circular requires.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Actors = require(Shared.Actors)
local MovementConfig = require(Shared.Config.Movement)

Net.init()
workspace.Gravity = MovementConfig.Gravity
Players.CharacterAutoLoads = true

local Services = script.Parent.Services

local ORDER = {
	"PlayerService",
	"DataService",
	"ArenaService",
	"MovementService",
	"DiscService",
	"CatchingService",
	"DefenseService",
	"ThrowService",
	"LeaderboardService",
	"ProgressionService",
	"HighlightService",
	"TeamService",
	"BotService",
	"TrainingService",
	"MatchService",
}

local services: { [string]: any } = { Actors = Actors }
for _, name in ORDER do
	services[name] = require(Services:WaitForChild(name)) :: any
end

for _, name in ORDER do
	local ok, err = pcall(services[name].Init, services)
	if not ok then
		warn(string.format("[Breakpoint] %s.Init failed: %s", name, tostring(err)))
	end
end

for _, name in ORDER do
	local ok, err = pcall(services[name].Start)
	if not ok then
		warn(string.format("[Breakpoint] %s.Start failed: %s", name, tostring(err)))
	end
end

print("[Breakpoint] server ready")
