--!strict
-- SIGNATURE MOVES
-- Hard, named plays built from the reset mechanics (see Config/Movement.Reset
-- and docs/DESIGN.md "Resets and signature moves"). Each one is recognised
-- by Rules/Signatures from the stream of techniques, tips, landings and
-- catches, pays its points into the combo chain (x2 again when the chain is
-- converted, which a catch always does), and is announced to the whole
-- server. Order matters: when one airborne catch completes several, only the
-- first match in Order pays.

export type Def = {
	id: string,
	name: string,
	points: number,
	how: string, -- one line for the Training menu
	tier: number, -- 1 = hard, 2 = very hard, 3 = insane (banner style)
}

local Signatures = {}

Signatures.List = {
	-- world-class (tech engine)
	DoubleFlip = {
		id = "DoubleFlip",
		name = "DOUBLE FLIP RESET",
		points = 3500,
		how = "Land your feet on a disc in the air, spend the reset, and land on a disc again before touching down.",
		tier = 3,
	},
	FlipCatch = {
		id = "FlipCatch",
		name = "FLIP RESET GRAB",
		points = 3000,
		how = "Flip Reset off a disc, spend the stored dodge, then catch a disc before you land.",
		tier = 3,
	},
	WallFlip = {
		id = "WallFlip",
		name = "WALL FLIP RESET",
		points = 2800,
		how = "Wall Kick, then Flip Reset off a disc in the same airtime.",
		tier = 3,
	},
	ZapChain = {
		id = "ZapChain",
		name = "ZAP CHAIN",
		points = 1800,
		how = "Wavedash, Zap Dash, then a Perfect Cut, each right after the last.",
		tier = 2,
	},
	StallGrab = {
		id = "StallGrab",
		name = "STALL GRAB",
		points = 1500,
		how = "Stall in the air and catch the disc before you land.",
		tier = 2,
	},
	DoubleTip = {
		id = "DoubleTip",
		name = "DOUBLE TIP",
		points = 3000,
		how = "Tip the disc twice in one jump, then catch it before you land.",
		tier = 3,
	},
	WallTip = {
		id = "WallTip",
		name = "WALL TIP",
		points = 2500,
		how = "Wall rebound and tip reset in the same jump, then catch it in the air.",
		tier = 3,
	},
	ResetGrab = {
		id = "ResetGrab",
		name = "RESET GRAB",
		points = 2000,
		how = "Tip the disc in the air, use the reset (air cut or air layout), catch it before you land.",
		tier = 2,
	},
	SelfD = {
		id = "SelfD",
		name = "SELF-D",
		points = 2000,
		how = "As a defender, tip the disc out of the air, then catch it yourself.",
		tier = 2,
	},
	DoubleLayout = {
		id = "DoubleLayout",
		name = "DOUBLE LAYOUT",
		points = 1800,
		how = "Layout, Perfect pop-up (recovery reset), then layout again in the air and catch.",
		tier = 2,
	},
	ResetLoop = {
		id = "ResetLoop",
		name = "RESET LOOP",
		points = 1500,
		how = "Perfect landing reset, burst, Perfect snap cut - twice in one chain.",
		tier = 2,
	},
	Greatest = {
		id = "Greatest",
		name = "THE GREATEST",
		points = 2500,
		how = "Jump from in bounds, catch a disc that is flying out, and throw it back in before you land.",
		tier = 3,
	},
	Skyball = {
		id = "Skyball",
		name = "SKYBALL",
		points = 800,
		how = "Catch with your feet more than 5 studs off the ground.",
		tier = 1,
	},
	-- saves and combos with the disc
	DivingSave = {
		id = "DivingSave",
		name = "DIVING SAVE",
		points = 1200,
		how = "Lay out and catch the disc an inch off the grass (under 1.6 studs).",
		tier = 2,
	},
	Shoestring = {
		id = "Shoestring",
		name = "SHOESTRING",
		points = 600,
		how = "Catch the disc at your shoelaces (under 1.2 studs off the ground) without laying out.",
		tier = 1,
	},
	AlleyOop = {
		id = "AlleyOop",
		name = "ALLEY-OOP",
		points = 1400,
		how = "Catch the disc in the air and throw it before you land.",
		tier = 2,
	},
	TipReset = {
		id = "TipReset",
		name = "TIP RESET",
		points = 500,
		how = "Tip the disc in the air (RMB as it reaches your hands), then use the air move it gives back.",
		tier = 1,
	},
} :: { [string]: Def }

-- Priority when one event completes several.
Signatures.Order = {
	"DoubleFlip",
	"FlipCatch",
	"WallFlip",
	"DoubleTip",
	"WallTip",
	"ResetGrab",
	"SelfD",
	"DoubleLayout",
	"ResetLoop",
	"Greatest",
	"StallGrab",
	"ZapChain",
	"Skyball",
	"DivingSave",
	"Shoestring",
	"AlleyOop",
	"TipReset",
}

-- Recognition windows.
Signatures.SkyHeight = 5 -- feet above the ground for a Skyball
Signatures.SaveHeight = 1.6 -- disc height (studs over the grass) for a Diving Save
Signatures.ShoestringHeight = 1.2 -- ... and for a Shoestring
Signatures.LoopStep = 0.7 -- Reset Loop: each step within this of the previous
Signatures.LoopGap = 2.0 -- ... and the second loop within this of the first
Signatures.SelfDWindow = 2.5 -- Self-D: the catch within this of the defender's tip
Signatures.ZapStep = 0.7 -- Zap Chain: each step within this of the previous
Signatures.LayoutWindow = 2.5 -- Double Layout: pop-up -> air layout -> catch within this

return Signatures
