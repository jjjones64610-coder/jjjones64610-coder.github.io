--!strict
--[[
	Abilities — one per player, picked from the same pool (Menu → Settings →
	Ability), so everyone has the same tools (docs/tech-spec.md pillar 6: no
	stat upgrades). The FLOW meter only fills through skill: Perfect techs,
	catches, blocks and goals. Full meter + Ability key = one use.

	The server owns the meter (AbilityService, from validated events) and
	says when an ability fires; the client applies the effect to its own
	movement (TechCore) and everyone sees the aura.
]]

local Abilities = {}

Abilities.MeterMax = 100

-- FLOW gained (server, from accepted events)
Abilities.Gain = {
	PerfectTech = 8,
	CleanTech = 1,
	catches = 4,
	completions = 3,
	assists = 8,
	blocks = 15,
	interceptions = 15,
	goals = 18,
	callahans = 40,
	greatests = 40,
}

export type Def = {
	id: string,
	name: string,
	desc: string,
	duration: number, -- s the effect lasts (0 = instant)
	color: Color3,
}

Abilities.Order = { "FlashStep", "Zone", "SkyWalk", "Overdrive" }

Abilities.List = {
	FlashStep = {
		id = "FlashStep",
		name = "FLASH STEP",
		desc = "Blink 10 studs the way you're moving and keep your speed.",
		duration = 0,
		color = Color3.fromRGB(90, 230, 255),
	},
	Zone = {
		id = "Zone",
		name = "THE ZONE",
		desc = "For 5 s every Perfect timing window is twice as wide.",
		duration = 5,
		color = Color3.fromRGB(255, 215, 80),
	},
	SkyWalk = {
		id = "SkyWalk",
		name = "SKY WALK",
		desc = "For 5 s you get two extra Air Dodges every airtime.",
		duration = 5,
		color = Color3.fromRGB(180, 255, 255),
	},
	Overdrive = {
		id = "Overdrive",
		name = "OVERDRIVE",
		desc = "For 4 s Burst is full and never drains.",
		duration = 4,
		color = Color3.fromRGB(255, 110, 60),
	},
} :: { [string]: Def }

Abilities.FlashDistance = 10 -- studs
Abilities.ZoneScale = 2 -- Perfect windows x this
Abilities.SkyWalkDodges = 2

function Abilities.get(id: any): Def?
	if type(id) ~= "string" then
		return nil
	end
	return Abilities.List[id]
end

return Abilities
