--!strict
-- PROGRESSION, COSMETICS, ACHIEVEMENTS
-- Nothing here changes how a player moves, throws or catches. Every unlock is
-- visual. There are no purchases that affect competition.

local Progression = {}

Progression.XP = {
	MatchPlayed = 100,
	MatchWon = 60,
	PvPMultiplier = 1.5, -- match XP when both teams had human players (vs bots: x1)
	Goal = 25,
	Assist = 20,
	Callahan = 80,
	Catch = 4,
	Completion = 3,
	Interception = 20,
	Block = 18,
	Layout = 15,
	Greatest = 60,
	Highlight = 20,
	-- Combos pay from Summary.xpScore (converted: x2 score; not converted:
	-- 25 % of it, settled once the chain can no longer be converted).
	ComboPerHundred = 1, -- 1 XP per 100 xpScore points
	ComboCap = 60, -- per converted chain
	UnconvertedComboCap = 30, -- per unconverted chain
	UnconvertedMatchCap = 120, -- unconverted chains, per player per match (match play only)
	TrainingDrill = 15,
	PersonalBest = 25,
	SignatureTier = { 40, 90, 160 }, -- per signature move, by Config/Signatures tier
}

function Progression.xpForLevel(level: number): number
	return 300 + 75 * level
end

Progression.MaxLevel = 100

Progression.Divisions = {
	{ name = "Bronze", min = -math.huge, color = Color3.fromRGB(176, 120, 72) },
	{ name = "Silver", min = 900, color = Color3.fromRGB(190, 196, 206) },
	{ name = "Gold", min = 1100, color = Color3.fromRGB(242, 196, 64) },
	{ name = "Platinum", min = 1300, color = Color3.fromRGB(96, 220, 210) },
	{ name = "Diamond", min = 1500, color = Color3.fromRGB(120, 160, 255) },
	{ name = "Breakpoint", min = 1700, color = Color3.fromRGB(255, 92, 160) },
} :: { any }

Progression.Rating = {
	Start = 1000,
	KNew = 40, -- first PlacementGames
	K = 24,
	PlacementGames = 10,
	Season = "S1",
}

-- Disc skins: purely visual (colour, material, rim, stripe).
Progression.DiscSkins = {
	{
		id = "Classic",
		name = "Classic White",
		level = 1,
		color = Color3.fromRGB(245, 245, 240),
		rim = Color3.fromRGB(210, 210, 205),
		stripe = Color3.fromRGB(30, 140, 255),
	},
	{
		id = "Sunset",
		name = "Sunset",
		level = 2,
		color = Color3.fromRGB(255, 140, 60),
		rim = Color3.fromRGB(255, 80, 90),
		stripe = Color3.fromRGB(255, 230, 120),
	},
	{
		id = "Glacier",
		name = "Glacier",
		level = 4,
		color = Color3.fromRGB(170, 230, 255),
		rim = Color3.fromRGB(90, 170, 230),
		stripe = Color3.fromRGB(255, 255, 255),
	},
	{
		id = "Volt",
		name = "Volt",
		level = 6,
		color = Color3.fromRGB(230, 255, 60),
		rim = Color3.fromRGB(40, 40, 40),
		stripe = Color3.fromRGB(40, 40, 40),
		neon = true,
	},
	{
		id = "Ember",
		name = "Ember",
		level = 9,
		color = Color3.fromRGB(60, 20, 20),
		rim = Color3.fromRGB(255, 90, 30),
		stripe = Color3.fromRGB(255, 160, 40),
		neon = true,
	},
	{
		id = "Nebula",
		name = "Nebula",
		level = 13,
		color = Color3.fromRGB(70, 40, 140),
		rim = Color3.fromRGB(255, 120, 220),
		stripe = Color3.fromRGB(120, 230, 255),
		neon = true,
	},
	{
		id = "Gold",
		name = "Gilded",
		level = 20,
		color = Color3.fromRGB(240, 200, 80),
		rim = Color3.fromRGB(190, 140, 40),
		stripe = Color3.fromRGB(255, 250, 220),
	},
	{
		id = "Callahan",
		name = "Callahan Crest",
		achievement = "Callahan",
		color = Color3.fromRGB(20, 20, 30),
		rim = Color3.fromRGB(255, 215, 0),
		stripe = Color3.fromRGB(255, 215, 0),
		neon = true,
	},
	{
		id = "Layout",
		name = "Grass Stain",
		achievement = "LayoutArtist",
		color = Color3.fromRGB(90, 170, 80),
		rim = Color3.fromRGB(60, 120, 50),
		stripe = Color3.fromRGB(240, 240, 230),
	},
} :: { any }

-- Movement trails: thin, translucent, never obscuring the disc.
Progression.Trails = {
	{ id = "None", name = "None", level = 1 },
	{ id = "Wisp", name = "Wisp", level = 3, a = Color3.fromRGB(255, 255, 255), b = Color3.fromRGB(150, 200, 255) },
	{ id = "Heat", name = "Heat", level = 7, a = Color3.fromRGB(255, 200, 60), b = Color3.fromRGB(255, 60, 60) },
	{ id = "Aurora", name = "Aurora", level = 11, a = Color3.fromRGB(80, 255, 180), b = Color3.fromRGB(140, 80, 255) },
	{ id = "Prism", name = "Prism", level = 16, a = Color3.fromRGB(255, 80, 200), b = Color3.fromRGB(80, 220, 255) },
	{
		id = "Breakpoint",
		name = "Breakpoint",
		achievement = "Breakpoint",
		a = Color3.fromRGB(255, 92, 160),
		b = Color3.fromRGB(255, 255, 255),
	},
} :: { any }

Progression.Celebrations = {
	{ id = "Point", name = "Point to the Sky", level = 1 },
	{ id = "Flex", name = "Flex", level = 5 },
	{ id = "Bow", name = "Take a Bow", level = 8 },
	{ id = "Spin", name = "Disc Spin", level = 12 },
	{ id = "Slide", name = "Knee Slide", level = 18 },
} :: { any }

Progression.Banners = {
	{ id = "Slate", name = "Slate", level = 1, color = Color3.fromRGB(40, 44, 56) },
	{ id = "Tide", name = "Tide", level = 3, color = Color3.fromRGB(20, 110, 200) },
	{ id = "Blaze", name = "Blaze", level = 3, color = Color3.fromRGB(230, 100, 30) },
	{ id = "Grass", name = "Field Day", level = 6, color = Color3.fromRGB(50, 140, 70) },
	{ id = "Night", name = "Night Game", level = 10, color = Color3.fromRGB(30, 20, 70) },
	{ id = "Champion", name = "Champion", level = 25, color = Color3.fromRGB(200, 160, 40) },
} :: { any }

Progression.Titles = {
	{ id = "Rookie", name = "Rookie", level = 1 },
	{ id = "Cutter", name = "Cutter", level = 4 },
	{ id = "Handler", name = "Handler", level = 8 },
	{ id = "Veteran", name = "Veteran", level = 15 },
	{ id = "LayoutArtist", name = "Layout Artist", achievement = "LayoutArtist" },
	{ id = "HammerTime", name = "Hammer Time", achievement = "HammerTime" },
	{ id = "Callahan", name = "Callahan Club", achievement = "Callahan" },
	{ id = "Greatest", name = "The Greatest", achievement = "Greatest" },
	{ id = "Lockdown", name = "Lockdown", achievement = "Lockdown" },
	{ id = "Engine", name = "The Engine", achievement = "Engine" },
	{ id = "Breakpoint", name = "Breakpoint", achievement = "Breakpoint" },
	{ id = "Flow", name = "Flow State", achievement = "Flow" },
} :: { any }

Progression.Achievements = {
	{ id = "FirstGoal", name = "On the Board", description = "Score your first goal.", stat = "goals", goal = 1 },
	{
		id = "ResetArtist",
		name = "Reset Artist",
		description = "Pull off 10 signature moves.",
		stat = "signatures",
		goal = 10,
	},
	{
		id = "FlipReset",
		name = "Flip Reset",
		description = "Land a Double Tip: two tips in one jump, then the catch.",
		stat = "sigDoubleTip",
		goal = 1,
	},
	{
		id = "SelfMade",
		name = "Self-Made",
		description = "Get a Self-D: tip it as a defender, then catch it yourself.",
		stat = "sigSelfD",
		goal = 1,
	},
	{
		id = "LayoutArtist",
		name = "Layout Artist",
		description = "Make 25 diving (layout) catches.",
		stat = "layouts",
		goal = 25,
	},
	{
		id = "HammerTime",
		name = "Hammer Time",
		description = "Throw 10 goals with a hammer.",
		stat = "hammerGoals",
		goal = 10,
	},
	{
		id = "Callahan",
		name = "Callahan",
		description = "Intercept a pass in the end zone you defend.",
		stat = "callahans",
		goal = 1,
	},
	{
		id = "Greatest",
		name = "The Greatest",
		description = "Catch in the air past the line and throw before landing.",
		stat = "greatests",
		goal = 1,
	},
	{ id = "Lockdown", name = "Lockdown", description = "Record 50 blocks.", stat = "blocks", goal = 50 },
	{
		id = "Engine",
		name = "The Engine",
		description = "Perform 2,000 movement techniques.",
		stat = "techs",
		goal = 2000,
	},
	{
		id = "Flow",
		name = "Flow State",
		description = "Be part of a 10-pass possession that scores.",
		stat = "flowGoals",
		goal = 1,
	},
	{
		id = "Breakpoint",
		name = "Breakpoint",
		description = "Convert a BREAKPOINT-tier combo.",
		stat = "breakpointCombos",
		goal = 1,
	},
	{
		id = "Huck",
		name = "Huck It",
		description = "Complete 10 HUCKs (a completion longer than half the field).",
		stat = "hucks",
		goal = 10,
	},
	{
		id = "Perfectionist",
		name = "Perfectionist",
		description = "Land 100 Perfect releases.",
		stat = "perfectReleases",
		goal = 100,
	},
	{
		id = "Student",
		name = "Student of the Game",
		description = "Finish every training drill once.",
		stat = "drillsCompleted",
		goal = 9,
	},
} :: { any }

function Progression.division(rating: number): any
	local current = Progression.Divisions[1]
	for _, d in Progression.Divisions do
		if rating >= d.min then
			current = d
		end
	end
	return current
end

return Progression
