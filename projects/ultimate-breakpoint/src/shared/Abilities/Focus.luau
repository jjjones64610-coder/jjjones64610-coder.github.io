--!strict
-- FOCUS — the closest Roblox allows to "a moment of slowed time while
-- aiming" (time can't slow for one player in a multiplayer game). For a few
-- seconds you hang in the air (low gravity) and your release is forgiving:
-- letting go anywhere near the Snap point leaves as a Perfect release. It
-- helps you make the hard throw; it does not make it for you.
local Types = require(script.Parent.Parent.AbilityTypes)
local TechCore = require(script.Parent.Parent.Movement.TechCore)

local GRAVITY = 0.35 -- FEEL: gravity x this while it lasts (the hang)
local SNAP_ASSIST = 0.09 -- FEEL: s either side of the Snap point that still counts (normally 0.025)

local def: Types.Def = {
	id = "Focus",
	name = "FOCUS",
	desc = "For 3 s you hang in the air and your next release snaps to Perfect if it is close.",
	color = Color3.fromRGB(255, 215, 80),
	icon = "Focus",
	price = 2200,
	order = 4,
	cooldown = 22,
	duration = 3,
	spendOnThrow = true,
	start = function(tech: TechCore.State, _move: Vector3)
		TechCore.modify(tech, 3, { gravity = GRAVITY })
	end,
	throw = function(p: Types.ThrowParams)
		p.snapAssist = SNAP_ASSIST
	end,
}

return def
