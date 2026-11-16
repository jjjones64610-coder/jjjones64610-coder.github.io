--!strict
--[[
	Abilities — the framework (docs/CORE_DESIGN.md, stage 6).

	TO ADD AN ABILITY: drop one ModuleScript in this folder that returns a
	Def (AbilityTypes.Def; copy any module here as a start). Nothing else changes: it is found here, appears in the
	Locker and the Shop, gets its cooldown, its aura colour, its server
	checks and its effect. Each module holds its own numbers.

	The rules every ability follows:
	  * one per player, chosen before the match (Locker), fired with the
	    Ability chord (Config/Input.AbilityChord: Jump + Sprint together)
	  * a cooldown, never a meter; they add to movement and throwing, they
	    never replace skill and never win the play by themselves
	  * the server decides when it fires (AbilityService: ownership, cooldown,
	    canUse) and stamps the character; the owner's client applies the
	    movement part to its own TechCore; throw and catch parts are applied
	    by the same hook on the client (prediction) and the server (truth)

	What a Def can do (all optional; mix freely):
	  canUse(ctx)        may it fire right now? (false + a short reason)
	  start(tech, move)  the movement effect, on the owner's own TechCore:
	                     use TechCore.modify / TechCore.airBurst (generic
	                     hooks; never edit TechCore for one ability)
	  throw(params)      changes the throw released while it is active
	  spendOnThrow       ... and that throw ends it
	  catchReach         studs of extra catch reach while it is active
	  airAction          the server allows one more air action this airtime
]]

local Types = require(script.Parent.AbilityTypes)

local Abilities = {}

export type Context = Types.Context
export type ThrowParams = Types.ThrowParams
export type Def = Types.Def

local list: { [string]: Def } = {}
local order: { string } = {}

for _, child in script:GetChildren() do
	if child:IsA("ModuleScript") then
		local def = (require :: any)(child) :: Def
		assert(
			type(def) == "table" and def.id == child.Name,
			"ability module " .. child.Name .. " must return a Def with id = its name"
		)
		list[def.id] = def
		table.insert(order, def.id)
	end
end
table.sort(order, function(a, b)
	if list[a].order ~= list[b].order then
		return list[a].order < list[b].order
	end
	return a < b
end)

Abilities.List = list
Abilities.Order = order
-- the one everyone owns (the cheapest; price 0)
Abilities.Default = order[1]

function Abilities.get(id: any): Def?
	if type(id) ~= "string" then
		return nil
	end
	return list[id]
end

-- The ability running on `model` at time `t` (Net.now()), read from the
-- attributes AbilityService stamps. Both sides use it.
function Abilities.active(model: Instance?, t: number): Def?
	if not model then
		return nil
	end
	local untilT = model:GetAttribute("UBAbilityUntil")
	if type(untilT) ~= "number" or t >= untilT then
		return nil
	end
	return Abilities.get(model:GetAttribute("UBAbility"))
end

function Abilities.activeOn(model: Instance?, id: string, t: number): boolean
	local def = Abilities.active(model, t)
	return def ~= nil and def.id == id
end

-- Extra catch reach (studs) `model` has at time `t`.
function Abilities.catchReach(model: Instance?, t: number): number
	local def = Abilities.active(model, t)
	return if def and def.catchReach then def.catchReach else 0
end

-- Applies the active ability's throw hook to `p`. Returns the ability when
-- it changed the throw (the caller ends it if def.spendOnThrow).
function Abilities.applyThrow(model: Instance?, t: number, p: ThrowParams): Def?
	local def = Abilities.active(model, t)
	if def and def.throw then
		def.throw(p)
		return def
	end
	return nil
end

return Abilities
