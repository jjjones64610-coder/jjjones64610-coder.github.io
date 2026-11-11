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
	passChain = 3, -- x the chain length, to the thrower and the catcher
}

export type Def = {
	id: string,
	name: string,
	desc: string,
	duration: number, -- s the effect lasts (0 = instant)
	color: Color3,
}

Abilities.Order = { "FlashStep", "Zone", "SkyWalk", "Overdrive", "MagnetHands", "TempestThrow" }

Abilities.List = {
	FlashStep = {
		id = "FlashStep",
		name = "FLASH STEP",
		desc = "Vanish 18 studs the way you're moving and surge +8 speed.",
		duration = 2,
		color = Color3.fromRGB(90, 230, 255),
	},
	Zone = {
		id = "Zone",
		name = "THE ZONE",
		desc = "For 8 s every Perfect timing window is twice as wide.",
		duration = 8,
		color = Color3.fromRGB(255, 215, 80),
	},
	SkyWalk = {
		id = "SkyWalk",
		name = "SKY WALK",
		desc = "For 8 s: three extra Air Dodges every airtime and floatier jumps.",
		duration = 8,
		color = Color3.fromRGB(180, 255, 255),
	},
	Overdrive = {
		id = "Overdrive",
		name = "OVERDRIVE",
		desc = "For 7 s Burst never drains and your top speed is +6.",
		duration = 7,
		color = Color3.fromRGB(255, 110, 60),
	},
	MagnetHands = {
		id = "MagnetHands",
		name = "MAGNET HANDS",
		desc = "For 8 s the disc snaps to your hands from 2.5 studs further.",
		duration = 8,
		color = Color3.fromRGB(255, 90, 220),
	},
	TempestThrow = {
		id = "TempestThrow",
		name = "TEMPEST THROW",
		desc = "Your next throw (within 10 s) flies 35 % faster and holds its line.",
		duration = 10,
		color = Color3.fromRGB(60, 230, 200),
	},
} :: { [string]: Def }

Abilities.FlashDistance = 18 -- studs
Abilities.FlashSurge = 8 -- studs/s added on arrival (overspeed decays it)
Abilities.ZoneScale = 2 -- Perfect windows x this
Abilities.SkyWalkDodges = 3
Abilities.SkyWalkGravity = 0.75 -- gravity x this
Abilities.OverdriveTop = 6 -- extra top speed while Burst is held
Abilities.MagnetReach = 2.5 -- studs of extra catch reach
Abilities.TempestSpeed = 1.35 -- disc speed x this
Abilities.TempestSpin = 1.3 -- spin x this (holds its line)

function Abilities.get(id: any): Def?
	if type(id) ~= "string" then
		return nil
	end
	return Abilities.List[id]
end

-- Is ability `id` running on `model` at time `t` (Net.now())? Read from the
-- attributes AbilityService stamps; both sides use it.
function Abilities.activeOn(model: Instance?, id: string, t: number): boolean
	if not model then
		return false
	end
	local untilT = model:GetAttribute("UBAbilityUntil")
	return model:GetAttribute("UBAbility") == id and type(untilT) == "number" and t < untilT
end

return Abilities
