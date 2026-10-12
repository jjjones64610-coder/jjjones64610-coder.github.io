--!strict
-- DEFAULT BINDINGS
-- One small vocabulary. Advanced techniques come from pressing these in
-- context and on time (see MovementSim header), not from extra keys.
--   Movement actions: Sprint, Jump, Cut, Slide, Dive, Burst
--   Disc actions:     Primary (throw / reach), Secondary (fake / mark stance)
--   With the disc:    Q/E bank, 1-5 throw type, C = low release, Space = hop (high release)
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
	Sprint = "Sprint",
	Jump = "Jump / Hop",
	Cut = "Cut (Snap / Cancel / Fake / Air Redirect)",
	Slide = "Slide / Precision Landing / Low Release",
	Dive = "Dive (Layout)",
	Burst = "Burst Step",
	Primary = "Throw (hold) / Reach",
	Secondary = "Fake Throw / Mark Stance",
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
	CameraLock = "Toggle Mouse Lock",
}

-- Values are Enum.KeyCode / Enum.UserInputType names so they can be saved.
Input.Keyboard = {
	Sprint = { "LeftShift" },
	Jump = { "Space" },
	Cut = { "Q" },
	Slide = { "LeftControl", "C" },
	Dive = { "E" },
	Burst = { "F" },
	Primary = { "MouseButton1" },
	Secondary = { "MouseButton2" },
	BankLeft = { "Q" },
	BankRight = { "E" },
	TypeNext = { "X" },
	TypePrev = { "Z" },
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
	Sprint = { "ButtonL1" },
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

Input.DefaultSettings = {
	MouseSensitivity = 1.0,
	GamepadSensitivity = 1.0,
	TouchSensitivity = 1.0,
	InvertY = false,
	FieldOfView = 72,
	CameraShake = true,
	ShowComboFeed = true,
	ShowTechLabels = true,
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
