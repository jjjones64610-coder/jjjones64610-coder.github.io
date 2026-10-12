--!strict
-- ULTIMATE: BREAKPOINT — client bootstrap. Controllers are initialised and
-- started in dependency order with a shared registry (no circular requires).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

ReplicatedStorage:WaitForChild("Shared")
ReplicatedStorage:WaitForChild("UBRemotes")

local Controllers = script.Parent:WaitForChild("Controllers")

local ORDER = {
	"SettingsController",
	"InputController",
	"CameraController",
	"DiscRenderer",
	"MovementController",
	"CatchController",
	"ThrowController",
	"PoseController",
	"AudioController",
	"EffectsController",
	"UIController",
}

local controllers: { [string]: any } = {}
for _, name in ORDER do
	controllers[name] = require(Controllers:WaitForChild(name)) :: any
end

for _, name in ORDER do
	local ok, err = pcall(controllers[name].Init, controllers)
	if not ok then
		warn(string.format("[Breakpoint] %s.Init failed: %s", name, tostring(err)))
	end
end

for _, name in ORDER do
	local ok, err = pcall(controllers[name].Start)
	if not ok then
		warn(string.format("[Breakpoint] %s.Start failed: %s", name, tostring(err)))
	end
end
