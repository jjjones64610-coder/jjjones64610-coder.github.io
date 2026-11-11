--!strict
--[[
	MusicController — plays the soundtrack (Config/Music) by game state:

	  in the Training hall        Lobby
	  warm-up / intermission      MainTheme
	  a point (setup, pull, live, point over)   Match, or Universe on
	                              universe point
	  match over                  Victory once, then MainTheme

	Tracks crossfade over Music.Fade. Volume: Settings → Music volume
	(MusicVolume) times each track's own volume.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Music = require(Shared.Config.Music)
local Net = require(Shared.Net)

local MusicController = {}

local controllers: any
local player = Players.LocalPlayer
local current: Sound? = nil
local currentName = ""
local lastPhase: any = nil
local victoryUntil = -math.huge
local VICTORY_HOLD = 14 -- s the fanfare holds the music before the theme returns

local POINT_PHASES = { PointSetup = true, Pull = true, Live = true, PointOver = true }

local function volumeOf(track: Music.Track): number
	local s = controllers.SettingsController.get("MusicVolume")
	local master = controllers.SettingsController.get("MasterVolume")
	local mv = if type(s) == "number" then s else 0.5
	local m = if type(master) == "number" then master else 1
	return track.volume * mv * m
end

-- Which track the current state wants.
local function wanted(): string
	local c = player.Character
	if c and c:GetAttribute("UBRole") == "Training" then
		return "Lobby"
	end
	local state = ReplicatedStorage:FindFirstChild(Net.StateName)
	local phase = state and state:GetAttribute("Phase")
	if phase ~= lastPhase then
		lastPhase = phase
		if phase == "MatchOver" then
			victoryUntil = os.clock() + VICTORY_HOLD -- the fanfare, once per match end
		end
	end
	if os.clock() < victoryUntil then
		return "Victory"
	end
	if type(phase) == "string" and POINT_PHASES[phase] then
		if state and state:GetAttribute("Universe") == true and Music.Tracks.Universe.id ~= "" then
			return "Universe"
		end
		return "Match"
	end
	return "MainTheme"
end

local function play(name: string)
	if name == currentName then
		return
	end
	local old = current
	currentName = name
	current = nil
	local info = TweenInfo.new(Music.Fade)
	if old then
		TweenService:Create(old, info, { Volume = 0 }):Play()
		task.delay(Music.Fade + 0.1, function()
			old:Destroy()
		end)
	end
	local track = Music.Tracks[name]
	if not track or track.id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.Name = "UBMusic_" .. name
	s.SoundId = "rbxassetid://" .. track.id
	s.Looped = track.looped
	s.Volume = 0
	s.Parent = SoundService
	s:Play()
	TweenService:Create(s, info, { Volume = volumeOf(track) }):Play()
	current = s
end

function MusicController.Init(c: any)
	controllers = c
end

function MusicController.Start()
	controllers.SettingsController.Changed:Connect(function()
		local s = current
		local track = Music.Tracks[currentName]
		if s and track then
			s.Volume = volumeOf(track)
		end
	end)
	task.spawn(function()
		while true do
			local ok, err = pcall(function()
				play(wanted())
			end)
			if not ok then
				warn("[MusicController] " .. tostring(err))
			end
			task.wait(0.5)
		end
	end)
end

return MusicController
