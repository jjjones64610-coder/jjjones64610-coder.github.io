--!strict
-- AIR BURST — "a short directional air burst". In the air: a shove the way
-- you are holding and your air action back, so one jump can hold two moves
-- (burst, then dive; or dive early, burst, Sky Reach). Useless on the ground.
local Types = require(script.Parent.Parent.AbilityTypes)
local TechCore = require(script.Parent.Parent.Movement.TechCore)

local SPEED = 12 -- FEEL: studs/s added toward the stick
local LIFT = 8 -- FEEL: studs/s of upward kick

local def: Types.Def = {
	id = "AirBurst",
	name = "AIR BURST",
	desc = "In the air: a burst the way you hold, and your air action back.",
	color = Color3.fromRGB(180, 255, 255),
	icon = "AirBurst",
	price = 0,
	order = 1,
	cooldown = 14,
	duration = 0,
	airAction = true,
	canUse = function(ctx: Types.Context): (boolean, string?)
		if ctx.holding then
			return false, "NOT WITH THE DISC"
		elseif ctx.grounded == true then
			return false, "ONLY IN THE AIR"
		end
		return true, nil
	end,
	start = function(tech: TechCore.State, move: Vector3)
		TechCore.airBurst(tech, move, SPEED, LIFT)
	end,
}

return def
