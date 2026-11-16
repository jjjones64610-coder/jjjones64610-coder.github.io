--!strict
-- The shape of an ability module (src/shared/Abilities: one file each).
-- Kept beside the folder so the modules and the framework can both use it.
local TechCore = require(script.Parent.Movement.TechCore)

export type Context = {
	grounded: boolean?, -- nil when unknown (the server's view lags a jump)
	holding: boolean, -- holding the disc
}

-- (the throw parameters a hook may change; ThrowModel.Params has more)
export type ThrowParams = {
	throwType: string,
	bank: number,
	holdTime: number,
	snapAssist: number?,
	[string]: any,
}

export type Def = {
	id: string, -- the module's name
	name: string, -- shown on the HUD (upper case)
	desc: string, -- one line for the Locker / Shop
	color: Color3, -- aura and effects
	icon: string, -- Config/Art.Ui key
	price: number, -- coins in the Shop (0 = everyone starts with it)
	order: number, -- position in lists
	cooldown: number, -- s from firing until it is ready again
	duration: number, -- s the effect (and the aura) lasts; 0 = instant
	canUse: ((ctx: Context) -> (boolean, string?))?,
	start: ((tech: TechCore.State, move: Vector3) -> ())?,
	throw: ((p: ThrowParams) -> ())?,
	spendOnThrow: boolean?,
	catchReach: number?,
	airAction: boolean?,
}

return {}
