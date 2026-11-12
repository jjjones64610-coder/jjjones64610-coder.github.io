--!strict
-- CONTROLS (docs/CORE_DESIGN.md: "keep this list small and fixed")
--   WASD    move (let go and snap a new direction to cut)
--   Mouse   camera and aim
--   Space   jump
--   Shift   sprint / burst (hold)
--   LMB     throw (hold to charge, release to throw)
--   RMB     aim / fake (with the disc)
--   Ability Space + Shift pressed together (AbilityChord below)
-- M opens the menu (not a gameplay action). Nothing else is bound, and the
-- rebind menu only offers these actions. Every move other games give its
-- own button comes out of these inputs plus your state (grounded, airborne,
-- sprinting, holding the disc, diving, landing) — see TechCore.
-- Gamepad and touch map onto the same actions here, so adding them later
-- only means filling in the tables below.

local Input = {}

-- The only actions a key can trigger (the rebind menu lists these).
Input.Actions = {
	"Jump",
	"Burst",
	"Primary",
	"Secondary",
	"Menu",
}

Input.Display = {
	Jump = "Jump",
	Burst = "Sprint / Burst (hold)",
	Primary = "Throw (hold to charge, release to throw)",
	Secondary = "Aim / Fake (with the disc)",
	Menu = "Menu",
	Ability = "Ability (Jump + Sprint together)",
}

-- THE ABILITY CHORD (the one place to change it). The ability fires when
-- every action listed goes down within `window` seconds of each other. The
-- actions still do their own thing (the jump is never delayed); a normal
-- sprint-then-jump presses Shift long before Space, so it never fires by
-- accident. Listed as actions, so it follows rebinds and works on any device.
Input.AbilityChord = {
	actions = { "Jump", "Burst" },
	window = 0.04, -- s
}

-- Values are Enum.KeyCode / Enum.UserInputType names so they can be saved.
-- The first key of each list is the one shown in HUD key pips.
Input.Keyboard = {
	Jump = { "Space" },
	Burst = { "LeftShift" },
	Primary = { "MouseButton1" },
	Secondary = { "MouseButton2" },
	Menu = { "M" },
} :: { [string]: { string } }

-- (later) the same actions on a pad
Input.Gamepad = {
	Jump = { "ButtonA" },
	Burst = { "ButtonL1" },
	Primary = { "ButtonR2" },
	Secondary = { "ButtonL2" },
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
Input.SettingsVersion = 4
Input.Migrations = {
	[2] = { "ShowTechLabels" }, -- technique labels are now off by default (less HUD noise)
	[3] = { "Bindings" }, -- the tech-spec key layout replaces saved rebinds once
	[4] = { "Bindings" }, -- the six-input core design replaces saved rebinds once
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
	Ability = "FlashStep", -- Config/Abilities id
	AnimeEffects = true, -- speed lines, afterimages, impact frames, slash arcs
	TechDebug = false, -- the tech debug HUD (speed, state, burst, timing in ms); always on in Studio
	AutoSprint = true,
	ToggleSprint = false,
	AutoSprintTouch = true,
	LeftHanded = false,
	TrajectoryPreview = true,
	TouchButtonScale = 1.0,
	MasterVolume = 0.8,
	SfxVolume = 1.0,
	CrowdVolume = 0.7,
	MusicVolume = 0.5, -- the soundtrack (Config/Music)
}

return Input
