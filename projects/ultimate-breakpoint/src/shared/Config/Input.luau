--!strict
-- DEFAULT BINDINGS
-- One small vocabulary. Advanced techniques come from pressing these in
-- context and on time (see MovementSim header), not from extra keys.
--   Movement actions: Sprint, Jump, Cut, Slide, Dive, Burst
--   Disc actions:     Primary (throw / reach), Secondary (fake / mark; in the air: tip)
--   With the disc:    Q / E quick swing left / right (the Cut / Dive keys),
--                     Space hop (high release), C low release, Z / X bank,
--                     mouse wheel or 1-5 throw type (T cycles too), R lead
--                     pass assist
--   Gamepad:          A jump, X cut (holding: swing to the other side),
--                     R1 burst, B slide, Y dive, L1 or L3 sprint
--   Marking:          hold Secondary near the holder; C toggles High / Low
-- Sprinting is automatic by default (AutoSprint: a full push held in one
-- direction for 0.3 s); Shift sprints at once and ToggleSprint still works.
-- Players can rebind everything in Settings > Controls; choices are saved.

local Input = {}

Input.Actions = {
	"Sprint",
	"Jump",
	"Cut",
	"Slide",
	"Dive",
	"Burst",
	"Primary",
	"Secondary",
	"BankLeft",
	"BankRight",
	"TypeNext",
	"TypePrev",
	"Type1",
	"Type2",
	"Type3",
	"Type4",
	"Type5",
	"LeadLock",
	"Celebrate",
	"Menu",
	"CameraLock",
}

Input.Display = {
	Sprint = "Sprint (hold; automatic when AutoSprint is on)",
	Jump = "Jump / Pop-up / Wall Rebound / Hop (with disc)",
	Cut = "Cut (Snap / Plant / Air Redirect) · Swing Left (with disc)",
	Slide = "Slide / Precision Landing · Low Release · Mark Stance",
	Dive = "Layout Dive · Swing Right (with disc)",
	Burst = "Burst Step (also restarts a plant)",
	Primary = "Throw (hold) / Reach",
	Secondary = "Fake Throw / Mark (hold near the holder) / Tip (in the air)",
	BankLeft = "Bank Left (with disc)",
	BankRight = "Bank Right (with disc)",
	TypeNext = "Next Throw Type",
	TypePrev = "Previous Throw Type",
	Type1 = "Backhand",
	Type2 = "Forehand",
	Type3 = "Hammer",
	Type4 = "Scoober",
	Type5 = "Blade",
	LeadLock = "Lead Pass Assist",
	Celebrate = "Celebrate",
	Menu = "Menu",
	CameraLock = "Free / Lock Mouse",
}

-- Values are Enum.KeyCode / Enum.UserInputType names so they can be saved.
-- The first key of each list is the one shown in HUD key pips.
Input.Keyboard = {
	Sprint = { "LeftShift" },
	Jump = { "Space" },
	Cut = { "Q" },
	Slide = { "C", "LeftControl" },
	Dive = { "E" },
	Burst = { "F" },
	Primary = { "MouseButton1" },
	Secondary = { "MouseButton2" },
	BankLeft = { "Z" },
	BankRight = { "X" },
	TypeNext = { "T" },
	TypePrev = {},
	Type1 = { "One" },
	Type2 = { "Two" },
	Type3 = { "Three" },
	Type4 = { "Four" },
	Type5 = { "Five" },
	LeadLock = { "R" },
	Celebrate = { "B" },
	Menu = { "M" },
	CameraLock = { "LeftAlt" },
} :: { [string]: { string } }

Input.Gamepad = {
	Sprint = { "ButtonL1", "ButtonL3" },
	Jump = { "ButtonA" },
	Cut = { "ButtonX" },
	Slide = { "ButtonB" },
	Dive = { "ButtonY" },
	Burst = { "ButtonR1" },
	Primary = { "ButtonR2" },
	Secondary = { "ButtonL2" },
	BankLeft = { "DPadLeft" },
	BankRight = { "DPadRight" },
	TypeNext = { "DPadUp" },
	TypePrev = { "DPadDown" },
	LeadLock = { "ButtonR3" },
	Celebrate = { "DPadDown" },
	Menu = { "ButtonSelect" },
} :: { [string]: { string } }

-- Stick shaping (applied by InputController): below Dead the stick reads 0,
-- from Full it reads 1, linear in between, so small tilts start at a crawl and
-- pads that never report a full 1.0 still reach top speed.
Input.Stick = {
	GamepadDead = 0.15,
	GamepadFull = 0.92,
	TouchDead = 0.1,
	TouchFull = 0.92,
}

-- AutoSprint: sprint once the move input has been at least MinMagnitude for
-- ChargeTime without leaving a MaxAngle cone; it then lasts while the input
-- stays strong (short dips under Grace are forgiven, e.g. switching keys).
Input.AutoSprint = {
	MinMagnitude = 0.9,
	ChargeTime = 0.3,
	MaxAngle = 35,
	Grace = 0.15,
}

-- Short key names for HUD pips / hints ("Q", "LMB", "SHIFT"). Anything not
-- listed is shown upper-cased.
Input.KeyLabels = {
	LeftShift = "SHIFT",
	RightShift = "SHIFT",
	LeftControl = "CTRL",
	RightControl = "CTRL",
	LeftAlt = "ALT",
	RightAlt = "ALT",
	Space = "SPACE",
	Return = "ENTER",
	Tab = "TAB",
	Backspace = "BKSP",
	MouseButton1 = "LMB",
	MouseButton2 = "RMB",
	MouseButton3 = "MMB",
	One = "1",
	Two = "2",
	Three = "3",
	Four = "4",
	Five = "5",
	Six = "6",
	Seven = "7",
	Eight = "8",
	Nine = "9",
	Zero = "0",
	ButtonA = "A",
	ButtonB = "B",
	ButtonX = "X",
	ButtonY = "Y",
	ButtonL1 = "L1",
	ButtonR1 = "R1",
	ButtonL2 = "L2",
	ButtonR2 = "R2",
	ButtonL3 = "L3",
	ButtonR3 = "R3",
	ButtonSelect = "VIEW",
	ButtonStart = "MENU",
	DPadLeft = "D-LEFT",
	DPadRight = "D-RIGHT",
	DPadUp = "D-UP",
	DPadDown = "D-DOWN",
	Up = "UP",
	Down = "DOWN",
	Left = "LEFT",
	Right = "RIGHT",
} :: { [string]: string }

-- Label for one key name ("LeftShift" -> "SHIFT"); "" for nil.
function Input.keyLabel(name: string?): string
	if name == nil or name == "" then
		return ""
	end
	return Input.KeyLabels[name] or string.upper(name)
end

-- Bump SettingsVersion when a default changes on purpose; keys listed under
-- the new version in Migrations are reset to their default for profiles saved
-- by an older version (everything else a player saved is kept).
Input.SettingsVersion = 2
Input.Migrations = {
	[2] = { "ShowTechLabels" }, -- technique labels are now off by default (less HUD noise)
} :: { [number]: { string } }

Input.DefaultSettings = {
	SettingsVersion = Input.SettingsVersion,
	MouseSensitivity = 1.0,
	GamepadSensitivity = 1.0,
	TouchSensitivity = 1.0,
	InvertY = false,
	FieldOfView = 72,
	CameraShake = true,
	ShowComboFeed = true,
	ShowTechLabels = false,
	ShowHitboxes = false, -- draw everyone's fixed hitbox (Config/Hitbox)
	AutoSprint = true,
	ToggleSprint = false,
	AutoSprintTouch = true,
	LeftHanded = false,
	TrajectoryPreview = true,
	TouchButtonScale = 1.0,
	MasterVolume = 0.8,
	SfxVolume = 1.0,
	CrowdVolume = 0.7,
}

return Input
