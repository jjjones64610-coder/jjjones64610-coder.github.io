--!strict
-- CURVEBALL — "a throw with extra curve". Arm it, and the next throw you
-- bend (A or D at the release) bends twice as hard: round a mark or a
-- poach that a normal bend can't clear. A flat throw gets nothing.
local Types = require(script.Parent.Parent.AbilityTypes)

local BEND = 2 -- FEEL: the bend x this

local def: Types.Def = {
	id = "Curveball",
	name = "CURVEBALL",
	desc = "Your next bent throw (within 6 s) curves twice as hard.",
	color = Color3.fromRGB(60, 230, 200),
	icon = "Curveball",
	price = 1800,
	order = 3,
	cooldown = 16,
	duration = 6,
	spendOnThrow = true,
	throw = function(p: Types.ThrowParams)
		p.bank = math.clamp(p.bank * BEND, -1, 1)
	end,
}

return def
