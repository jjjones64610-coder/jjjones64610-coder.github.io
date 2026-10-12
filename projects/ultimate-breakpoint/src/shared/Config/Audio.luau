--!strict
-- AUDIO CUES
-- Built-in engine sounds (rbxasset://) are used so the place works out of the
-- box. Swap any SoundId for your own uploaded audio (rbxassetid://...) to get
-- custom crowd beds, whistles and commentary stingers. Empty ids are skipped.

local Audio = {}

Audio.Cues = {
	Throw = { id = "rbxasset://sounds/swoosh.wav", volume = 0.5, pitch = 1.1 },
	PerfectRelease = { id = "rbxasset://sounds/swoosh.wav", volume = 0.7, pitch = 1.35 },
	Catch = { id = "rbxasset://sounds/clickfast.wav", volume = 0.7, pitch = 0.8 },
	CleanCatch = { id = "rbxasset://sounds/clickfast.wav", volume = 0.9, pitch = 0.65 },
	Layout = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.9, pitch = 0.85 },
	Block = { id = "rbxasset://sounds/snap.mp3", volume = 0.9, pitch = 0.9 },
	Bobble = { id = "rbxasset://sounds/snap.mp3", volume = 0.6, pitch = 1.4 },
	Turnover = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.5, pitch = 0.6 },
	Goal = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.9, pitch = 1.2 },
	Stall = { id = "rbxasset://sounds/button.wav", volume = 0.25, pitch = 1.0 },
	StallOut = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.7, pitch = 0.5 },
	Whistle = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.6, pitch = 1.6 },
	Tech = { id = "rbxasset://sounds/swoosh.wav", volume = 0.25, pitch = 1.6 },
	TechPerfect = { id = "rbxasset://sounds/swoosh.wav", volume = 0.35, pitch = 1.9 },
	Burst = { id = "rbxasset://sounds/swoosh.wav", volume = 0.45, pitch = 0.75 },
	Land = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.35, pitch = 1.0 },
	PrecisionLand = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.5, pitch = 1.4 },
	Rebound = { id = "rbxasset://sounds/snap.mp3", volume = 0.5, pitch = 1.2 },
	UiClick = { id = "rbxasset://sounds/button.wav", volume = 0.4, pitch = 1.0 },
	Highlight = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.6, pitch = 1.45 },
	-- Supply your own looping crowd ambience and cheer to enable these.
	CrowdLoop = { id = "", volume = 0.35, pitch = 1.0, looped = true },
	CrowdCheer = { id = "", volume = 0.7, pitch = 1.0 },
}

return Audio
