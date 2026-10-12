--!strict
--[[
	MATCH RULE PRESETS — exactly two modes, both PvP first:

	  Mini    3v3 on the Mini field (240 x 90 including end zones)
	  Normal  7v7 on the Normal field (360 x 136 including end zones)

	Which mode is played follows the head count (Modes.eligible): up to 6
	humans play Mini, 10 or more play Normal, and 7-9 humans may vote between
	them. Empty spots are filled with bots (FillWithBots) so the field is always
	exactly 3v3 or 7v7; Rules/MatchPlan decides who is on the line each point.

	Ranked is not a mode. A match is ranked automatically when its mode is
	RankedEligible, the server is public (not private, not Studio) and both
	lines are all human (MatchPlan.rankedEligible). Ranked matches play the
	preset plus Modes.RankedOverrides and never take private-server rules.

	Private servers (and Studio) let the host change the keys in
	Modes.Editable, including which mode is played; Modes.resolve applies them.
]]

local Modes = {}

-- Field sizes in studs. `length` is the playing field proper (between the
-- goal lines); the total length is length + 2 * endZone. `brick` is measured
-- from the goal line into the playing field.
export type FieldSpec = {
	width: number,
	length: number,
	endZone: number,
	brick: number,
}

Modes.Fields = {
	Mini = { width = 90, length = 160, endZone = 40, brick = 44 },
	Normal = { width = 136, length = 240, endZone = 60, brick = 64 },
} :: { [string]: FieldSpec }

export type ModeRules = {
	id: string,
	Display: string,
	Short: string, -- "3v3" / "7v7" for compact HUD lines
	Description: string,
	TeamSize: number, -- players per team on the field
	Field: string, -- key into Modes.Fields
	PointsToWin: number,
	TimeCap: number, -- seconds; when reached the current point finishes
	StallMax: number,
	StallInterval: number,
	UsePull: boolean,
	PullTimeout: number,
	PointSetupTime: number,
	CelebrationTime: number,
	FillWithBots: boolean, -- bots take every empty spot so the line is always TeamSize
	PreviewFraction: number, -- how much of the throw arc the thrower sees (0..1)
	LandingShadow: boolean, -- show the disc's ground shadow
	RankedEligible: boolean, -- may become ranked when the lines are all human
	Ranked: boolean, -- true only on rules resolved for a ranked match
	SpecialArenas: boolean, -- arenas with rebound walls may be picked
	StartUniverse: boolean, -- the first point is already universe point
}

local function mode(t: ModeRules): ModeRules
	return t
end

Modes.List = {
	Mini = mode({
		id = "Mini",
		Display = "Mini 3v3",
		Short = "3v3",
		Description = "3 v 3 on a compact field, first to 5. Bots fill empty spots.",
		TeamSize = 3,
		Field = "Mini",
		PointsToWin = 5,
		TimeCap = 420,
		StallMax = 8,
		StallInterval = 1.0,
		UsePull = true,
		PullTimeout = 8,
		PointSetupTime = 3,
		CelebrationTime = 3,
		FillWithBots = true,
		PreviewFraction = 0.5,
		LandingShadow = true,
		RankedEligible = true,
		Ranked = false,
		SpecialArenas = true,
		StartUniverse = false,
	}),
	Normal = mode({
		id = "Normal",
		Display = "Normal 7v7",
		Short = "7v7",
		Description = "7 v 7 on the full field, first to 5. Bots fill empty spots.",
		TeamSize = 7,
		Field = "Normal",
		PointsToWin = 5,
		TimeCap = 720,
		StallMax = 10,
		StallInterval = 1.0,
		UsePull = true,
		PullTimeout = 10,
		PointSetupTime = 4,
		CelebrationTime = 4,
		FillWithBots = true,
		PreviewFraction = 0.35,
		LandingShadow = true,
		RankedEligible = true,
		Ranked = false,
		SpecialArenas = true,
		StartUniverse = false,
	}),
} :: { [string]: ModeRules }

-- Smallest mode first; also the order modes are shown in.
Modes.Order = { "Mini", "Normal" }
Modes.Default = "Mini"

-- Applied on top of the preset when a match is ranked.
Modes.RankedOverrides = {
	PreviewFraction = 0.2,
	SpecialArenas = false,
} :: { [string]: any }

export type EditSpec = {
	label: string,
	bool: boolean?,
	options: { string }?,
	min: number?,
	max: number?,
	step: number?,
}

-- Keys a private-server (or Studio) host can change, with legal ranges.
-- `Mode` picks the preset itself; the field always follows the mode.
Modes.Editable = {
	Mode = { label = "Mode", options = { "Mini", "Normal" } },
	FillWithBots = { label = "Fill with bots", bool = true },
	PointsToWin = { label = "Points to win", min = 1, max = 15, step = 1 },
	TimeCap = { label = "Time cap (s)", min = 60, max = 1800, step = 30 },
	StallMax = { label = "Stall count", min = 5, max = 10, step = 1 },
	StallInterval = { label = "Stall interval (s)", min = 0.7, max = 1.2, step = 0.1 },
	UsePull = { label = "Pulls", bool = true },
	PreviewFraction = { label = "Throw preview", min = 0, max = 1, step = 0.1 },
	LandingShadow = { label = "Landing shadow", bool = true },
} :: { [string]: EditSpec }

-- Display order for the host's rules panel.
Modes.EditableOrder = {
	"Mode",
	"FillWithBots",
	"PointsToWin",
	"TimeCap",
	"StallMax",
	"StallInterval",
	"UsePull",
	"PreviewFraction",
	"LandingShadow",
}

function Modes.has(id: string?): boolean
	return id ~= nil and Modes.List[id] ~= nil
end

-- A fresh copy of a preset (unknown ids give the default mode).
function Modes.copy(id: string?): ModeRules
	local base = if id and Modes.List[id] then Modes.List[id] else Modes.List[Modes.Default]
	return table.clone(base)
end

-- Which modes a lobby of `humans` players may play, and the one picked when
-- nobody votes. Players only vote when more than one mode is returned.
--   <= 6 humans: Mini        7: Mini or Normal (default Mini)
--   8-9: Mini or Normal (default Normal)   >= 10: Normal
function Modes.eligible(humans: number): ({ string }, string)
	if humans <= 6 then
		return { "Mini" }, "Mini"
	elseif humans <= 9 then
		return { "Mini", "Normal" }, if humans == 7 then "Mini" else "Normal"
	end
	return { "Normal" }, "Normal"
end

-- The legal form of a host-edited value, or nil when it can't be used.
-- Numbers are clamped to the range; keys with whole-number steps take whole
-- numbers, the rest are rounded to 1e-6 so stepping 0.1 at a time stays tidy.
function Modes.sanitize(key: string, value: any): any
	local spec = Modes.Editable[key]
	if spec == nil then
		return nil
	end
	if spec.bool then
		return if type(value) == "boolean" then value else nil
	end
	local options = spec.options
	if options then
		return if type(value) == "string" and table.find(options, value) then value else nil
	end
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	local v = math.clamp(value, spec.min or -math.huge, spec.max or math.huge)
	if (spec.step or 0) >= 1 then
		return math.floor(v + 0.5)
	end
	return math.floor(v * 1e6 + 0.5) / 1e6
end

-- Current value of every editable key for a preset (what the host panel shows
-- before anything is changed). `Mode` is the preset id.
function Modes.editableDefaults(id: string?): { [string]: any }
	local base = Modes.copy(id)
	local out: { [string]: any } = {}
	for _, key in Modes.EditableOrder do
		out[key] = if key == "Mode" then base.id else (base :: any)[key]
	end
	return out
end

export type ResolveOptions = {
	ranked: boolean?, -- this match is ranked: apply RankedOverrides, ignore `private`
	private: { [string]: any }?, -- host-edited keys (private server / Studio)
}

-- The rules a match actually plays. A ranked match is the preset plus
-- RankedOverrides and never takes private config. Otherwise the host's
-- `Mode` (when valid) picks the preset and the other editable keys are
-- applied after sanitising; unknown keys are ignored.
function Modes.resolve(id: string?, opts: ResolveOptions?): ModeRules
	local o: ResolveOptions = opts or {}
	if o.ranked then
		local rules = Modes.copy(id)
		for k, v in Modes.RankedOverrides do
			(rules :: any)[k] = v
		end
		rules.Ranked = true
		return rules
	end
	local private = o.private
	local pick = id
	if private and Modes.has(private.Mode) then
		pick = private.Mode
	end
	local rules = Modes.copy(pick)
	if private then
		for _, key in Modes.EditableOrder do
			if key ~= "Mode" and private[key] ~= nil then
				local v = Modes.sanitize(key, private[key])
				if v ~= nil then
					(rules :: any)[key] = v
				end
			end
		end
	end
	rules.Ranked = false
	return rules
end

return Modes
