--!strict
-- MAGNET HANDS — for a few seconds your catch zones reach a little further.
-- A hard catch still needs your hands on time; this only widens where.
local Types = require(script.Parent.Parent.AbilityTypes)

local def: Types.Def = {
	id = "MagnetHands",
	name = "MAGNET HANDS",
	desc = "For 5 s your hands reach 2 studs further for the disc.",
	color = Color3.fromRGB(255, 90, 220),
	icon = "MagnetHands",
	price = 2000,
	order = 5,
	cooldown = 20,
	duration = 5,
	catchReach = 2,
}

return def
