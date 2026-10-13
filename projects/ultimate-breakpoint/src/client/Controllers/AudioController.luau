--!strict
-- AudioController — plays cues from Config/Audio, 2D or positioned in the world.
-- comboTick(link, perfect) is the combo chain's tick: the same short cue
-- climbing ComboTickStep semitones per link, so a chain is heard building.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AudioConfig = require(Shared.Config.Audio)

local AudioController = {}

local controllers: any
local templates: { [string]: Sound } = {}
local loops: { [string]: Sound } = {}

local function volumeFor(cue: string): number
	local settings = controllers.SettingsController
	local master = settings.get("MasterVolume") or 1
	local group = if string.find(cue, "Crowd") then settings.get("CrowdVolume") else settings.get("SfxVolume")
	return master * (group or 1)
end

local function template(cue: string): Sound?
	local cfg = (AudioConfig.Cues :: any)[cue]
	if not cfg or cfg.id == "" then
		return nil
	end
	local s = templates[cue]
	if not s then
		local snd = Instance.new("Sound")
		snd.Name = cue
		snd.SoundId = cfg.id
		snd.Volume = cfg.volume
		snd.PlaybackSpeed = cfg.pitch or 1
		snd.Looped = cfg.looped == true
		snd.Parent = SoundService
		templates[cue] = snd
		s = snd
	end
	return s
end

-- 2D cue (UI, your own actions). `pitchMult` scales the cue's pitch.
function AudioController.play(cue: string, pitchJitter: number?, pitchMult: number?)
	local t = template(cue)
	if not t then
		return
	end
	local s = t:Clone()
	local cfg = (AudioConfig.Cues :: any)[cue]
	s.Volume = cfg.volume * volumeFor(cue)
	local pitch = (cfg.pitch or 1) * (pitchMult or 1)
	if pitchJitter then
		pitch *= 1 + (math.random() - 0.5) * pitchJitter
	end
	s.PlaybackSpeed = pitch
	s.Parent = SoundService
	s:Play()
	s.Ended:Connect(function()
		s:Destroy()
	end)
	task.delay(6, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

-- The combo tick for the `link`-th technique of a chain (1 = first).
function AudioController.comboTick(link: number, perfect: boolean?)
	local steps = math.clamp(math.floor(link) - 1, 0, AudioConfig.ComboTickMaxSteps)
	local mult = 2 ^ (steps * AudioConfig.ComboTickStep / 12)
	if perfect then
		mult *= AudioConfig.ComboTickPerfect
	end
	AudioController.play("ComboTick", nil, mult)
end

-- Positional cue in the world.
function AudioController.playAt(cue: string, position: Vector3)
	local t = template(cue)
	if not t then
		return
	end
	local att = Instance.new("Attachment")
	att.WorldPosition = position
	att.Parent = workspace.Terrain
	local s = t:Clone()
	local cfg = (AudioConfig.Cues :: any)[cue]
	s.Volume = cfg.volume * volumeFor(cue)
	s.RollOffMaxDistance = 260
	s.RollOffMinDistance = 20
	s.Parent = att
	s:Play()
	task.delay(4, function()
		att:Destroy()
	end)
end

function AudioController.loop(cue: string, on: boolean)
	local t = template(cue)
	if not t then
		return
	end
	local s = loops[cue]
	if on and not s then
		local snd = t:Clone()
		snd.Looped = true
		snd.Volume = (AudioConfig.Cues :: any)[cue].volume * volumeFor(cue)
		snd.Parent = SoundService
		snd:Play()
		loops[cue] = snd
	elseif not on and s then
		s:Destroy()
		loops[cue] = nil
	end
end

function AudioController.Init(c: any)
	controllers = c
end

function AudioController.Start()
	AudioController.loop("CrowdLoop", true)
	controllers.SettingsController.Changed:Connect(function()
		for cue, s in loops do
			s.Volume = (AudioConfig.Cues :: any)[cue].volume * volumeFor(cue)
		end
	end)
end

return AudioController
