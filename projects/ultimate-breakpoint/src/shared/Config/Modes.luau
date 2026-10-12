--!strict
-- MATCH RULE PRESETS
-- Private servers start from Casual and may edit any field marked Editable.

local Modes = {}

Modes.Fields = {
	Standard = { width = 100, length = 190, endZone = 40, brick = 40 },
	Small = { width = 76, length = 124, endZone = 28, brick = 26 },
}

export type ModeRules = {
	id: string,
	Display: string,
	Description: string,
	PointsToWin: number,
	TimeCap: number, -- seconds; when reached the current point finishes
	StallMax: number,
	StallInterval: number,
	UsePull: boolean,
	Field: string,
	BotsFillTo: number, -- per team (0 = no bots)
	TeamSize: number,
	PreviewFraction: number, -- how much of the throw arc the thrower sees (0..1)
	LandingShadow: boolean, -- show the disc's ground shadow
	Ranked: boolean,
	SpecialArenas: boolean,
	StartUniverse: boolean,
	PointSetupTime: number,
	PullTimeout: number,
	CelebrationTime: number,
	Selectable: boolean,
}

local function mode(t: ModeRules): ModeRules
	return t
end

Modes.List = {
	Casual = mode({
		id = "Casual",
		Display = "Casual",
		Description = "Full field, first to 5, bots fill empty spots.",
		PointsToWin = 5,
		TimeCap = 480,
		StallMax = 10,
		StallInterval = 1.0,
		UsePull = true,
		Field = "Standard",
		BotsFillTo = 3,
		TeamSize = 7,
		PreviewFraction = 0.5,
		LandingShadow = true,
		Ranked = false,
		SpecialArenas = true,
		StartUniverse = false,
		PointSetupTime = 4,
		PullTimeout = 10,
		CelebrationTime = 4,
		Selectable = true,
	}),
	Ranked = mode({
		id = "Ranked",
		Display = "Ranked",
		Description = "First to 7, no bots, short throw preview, rating on the line.",
		PointsToWin = 7,
		TimeCap = 720,
		StallMax = 10,
		StallInterval = 1.0,
		UsePull = true,
		Field = "Standard",
		BotsFillTo = 0,
		TeamSize = 7,
		PreviewFraction = 0.2,
		LandingShadow = true,
		Ranked = true,
		SpecialArenas = false,
		StartUniverse = false,
		PointSetupTime = 4,
		PullTimeout = 10,
		CelebrationTime = 3.5,
		Selectable = true,
	}),
	Rush = mode({
		id = "Rush",
		Display = "Rush",
		Description = "Small field, 7-count stall, no pulls, 5 minutes.",
		PointsToWin = 5,
		TimeCap = 300,
		StallMax = 7,
		StallInterval = 0.9,
		UsePull = false,
		Field = "Small",
		BotsFillTo = 2,
		TeamSize = 5,
		PreviewFraction = 0.5,
		LandingShadow = true,
		Ranked = false,
		SpecialArenas = true,
		StartUniverse = false,
		PointSetupTime = 3,
		PullTimeout = 8,
		CelebrationTime = 3,
		Selectable = true,
	}),
	Clutch = mode({
		id = "Clutch",
		Display = "Clutch Point",
		Description = "One point. Universe from the start. 90 seconds.",
		PointsToWin = 1,
		TimeCap = 90,
		StallMax = 8,
		StallInterval = 1.0,
		UsePull = false,
		Field = "Small",
		BotsFillTo = 2,
		TeamSize = 5,
		PreviewFraction = 0.35,
		LandingShadow = true,
		Ranked = false,
		SpecialArenas = true,
		StartUniverse = true,
		PointSetupTime = 4,
		PullTimeout = 8,
		CelebrationTime = 5,
		Selectable = true,
	}),
}

Modes.Order = { "Casual", "Rush", "Clutch", "Ranked" }

-- Keys a private-server host can change, with legal ranges.
Modes.Editable = {
	PointsToWin = { min = 1, max = 15, step = 1 },
	TimeCap = { min = 60, max = 1800, step = 30 },
	StallMax = { min = 5, max = 10, step = 1 },
	StallInterval = { min = 0.7, max = 1.2, step = 0.1 },
	UsePull = { bool = true },
	BotsFillTo = { min = 0, max = 7, step = 1 },
	PreviewFraction = { min = 0, max = 1, step = 0.1 },
	LandingShadow = { bool = true },
	Field = { options = { "Standard", "Small" } },
}

function Modes.copy(id: string): ModeRules
	local base = (Modes.List :: any)[id] or Modes.List.Casual
	return table.clone(base)
end

return Modes
