--!strict
-- AUDIO CUES
-- Built-in engine sounds (rbxasset://) are used so the place works out of the
-- box. Swap any SoundId for your own uploaded audio (rbxassetid://...) to get
-- custom crowd beds, whistles and commentary stingers. Empty ids are skipped.
--
-- Combo feedback: ComboTick plays once per technique in a chain, pitched up
-- ComboTickStep semitones per link (capped at ComboTickMaxSteps links), so a
-- long chain audibly climbs; ComboEnd closes a chain that reached a tier and
-- ComboConvert plays when a catch / block converts it. Your own catch plays
-- Catch / CleanCatch the moment you claim it (CatchController), not a round
-- trip later.

local Audio = {}

Audio.Cues = {
	Throw = { id = "rbxassetid://104805615068791", volume = 0.6, pitch = 1.0 }, -- ForgeGUI
	PerfectRelease = { id = "rbxassetid://104805615068791", volume = 0.8, pitch = 1.2 },
	Catch = { id = "rbxassetid://111413366524280", volume = 0.7, pitch = 1.0 }, -- ForgeGUI
	CleanCatch = { id = "rbxassetid://111413366524280", volume = 0.9, pitch = 0.9 },
	Layout = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.9, pitch = 0.85 },
	Block = { id = "rbxasset://sounds/snap.mp3", volume = 0.9, pitch = 0.9 },
	Bobble = { id = "rbxasset://sounds/snap.mp3", volume = 0.6, pitch = 1.4 },
	Turnover = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.5, pitch = 0.6 },
	Goal = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.9, pitch = 1.2 },
	Stall = { id = "rbxasset://sounds/button.wav", volume = 0.25, pitch = 1.0 },
	StallOut = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.7, pitch = 0.5 },
	Whistle = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.6, pitch = 1.6 },
	Tech = { id = "rbxasset://sounds/swoosh.wav", volume = 0.25, pitch = 1.6 },
	TechPerfect = { id = "rbxassetid://86078047585706", volume = 0.55, pitch = 1.0 }, -- ForgeGUI anime impact
	Burst = { id = "rbxassetid://97962321370622", volume = 0.5, pitch = 1.0 }, -- ForgeGUI anime dash
	Land = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.35, pitch = 1.0 },
	PrecisionLand = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.5, pitch = 1.4 },
	-- stage 1 movement (ForgeGUI): the cut you hear tells you how it went
	CutPerfect = { id = "rbxassetid://138365407787910", volume = 0.7, pitch = 1.0 }, -- squeak + sparkle (ForgeGUI)
	CutClean = { id = "", volume = 0.5, pitch = 1.0 }, -- cleat plant
	Skid = { id = "", volume = 0.6, pitch = 1.0 }, -- shoes tearing turf
	Rebound = { id = "rbxasset://sounds/snap.mp3", volume = 0.5, pitch = 1.2 },
	UiClick = { id = "rbxassetid://136877996742041", volume = 0.5, pitch = 1.0 }, -- ForgeGUI
	Highlight = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.6, pitch = 1.45 },
	ComboTick = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.2, pitch = 1.25 },
	ComboEnd = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.3, pitch = 1.05 },
	ComboConvert = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.55, pitch = 1.7 },
	Tip = { id = "rbxasset://sounds/clickfast.wav", volume = 0.8, pitch = 1.5 },
	Reset = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.45, pitch = 2.0 },
	Signature = { id = "rbxassetid://102977794641930", volume = 0.8, pitch = 1.0 }, -- ForgeGUI power-up
	Dash = { id = "rbxassetid://97962321370622", volume = 0.45, pitch = 1.1 }, -- dodges, zap dashes, flash step
	Purchase = { id = "rbxassetid://138762609430193", volume = 0.7, pitch = 1.0 }, -- ForgeGUI coin chime
	MenuWhoosh = { id = "rbxassetid://103770482539981", volume = 0.6, pitch = 1.0 }, -- ForgeGUI
	Impact = { id = "rbxassetid://86078047585706", volume = 0.6, pitch = 1.0 }, -- impact frames
	Ability = { id = "rbxassetid://102977794641930", volume = 0.85, pitch = 1.0 }, -- ability activation
	-- Supply your own looping crowd ambience and cheer to enable these.
	CrowdLoop = { id = "", volume = 0.35, pitch = 1.0, looped = true },
	CrowdCheer = { id = "", volume = 0.7, pitch = 1.0 },
}

Audio.ComboTickStep = 2 -- semitones per chain link
Audio.ComboTickMaxSteps = 7 -- links after which the tick stops climbing
Audio.ComboTickPerfect = 1.06 -- extra pitch for a Perfect link

return Audio
