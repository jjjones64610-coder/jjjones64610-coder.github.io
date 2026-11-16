--!strict
-- SURGE — "a brief speed surge". For a moment your top speed and
-- acceleration go up: enough to win one step on a defender, not a race.
local Types = require(script.Parent.Parent.AbilityTypes)
local TechCore = require(script.Parent.Parent.Movement.TechCore)

local TOP_SPEED = 7 -- FEEL: studs/s added to your top speed
local ACCEL = 1.4 -- FEEL: acceleration x this

local def: Types.Def = {
	id = "Surge",
	name = "SURGE",
	desc = "For 2.5 s: +7 top speed and quicker off the mark.",
	color = Color3.fromRGB(255, 110, 60),
	icon = "Surge",
	price = 1500,
	order = 2,
	cooldown = 18,
	duration = 2.5,
	canUse = function(ctx: Types.Context): (boolean, string?)
		if ctx.holding then
			return false, "NOT WITH THE DISC"
		end
		return true, nil
	end,
	start = function(tech: TechCore.State, _move: Vector3)
		TechCore.modify(tech, 2.5, { topSpeed = TOP_SPEED, accel = ACCEL })
	end,
}

return def
