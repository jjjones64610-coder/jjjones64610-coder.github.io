-- Structural check of the built place file (run after `rojo build`):
--   lune run tests/place_check.luau
-- Verifies that every script landed in the right service with the right class
-- and that the place-level settings the game relies on are present.
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local path = "build/UltimateBreakpoint.rbxlx"
if not fs.isFile(path) then
	print("missing " .. path .. " (run rojo build first)")
	process.exit(1)
end

local game = roblox.deserializePlace(fs.readFile(path))
local failures = 0
local function check(cond: boolean, msg: string)
	if cond then
		print("  ok   " .. msg)
	else
		failures += 1
		print("  FAIL " .. msg)
	end
end

local function find(root: any, names: { string }): any
	local cur = root
	for _, n in names do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(n)
	end
	return cur
end

local rs = game:GetService("ReplicatedStorage")
local sss = game:GetService("ServerScriptService")
local sp = game:GetService("StarterPlayer")

check(
	find(sss, { "Server", "Main" }) ~= nil and find(sss, { "Server", "Main" }).ClassName == "Script",
	"server Main is a Script"
)
check(find(sp, { "StarterPlayerScripts", "Client", "Main" }).ClassName == "LocalScript", "client Main is a LocalScript")
check(
	find(sp, { "StarterCharacterScripts", "Animate" }).ClassName == "LocalScript",
	"Animate replaces the default (LocalScript)"
)

for _, name in
	{
		"PlayerService",
		"DataService",
		"ArenaService",
		"MovementService",
		"DiscService",
		"CatchingService",
		"DefenseService",
		"ThrowService",
		"LeaderboardService",
		"ProgressionService",
		"HighlightService",
		"TeamService",
		"BotService",
		"TrainingService",
		"MatchService",
	}
do
	local m = find(sss, { "Server", "Services", name })
	check(m ~= nil and m.ClassName == "ModuleScript", "service " .. name)
end
for _, name in
	{
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
do
	local m = find(sp, { "StarterPlayerScripts", "Client", "Controllers", name })
	check(m ~= nil and m.ClassName == "ModuleScript", "controller " .. name)
end
for _, p in
	{
		{ "Movement", "MovementSim" },
		{ "Disc", "DiscPhysics" },
		{ "Disc", "ThrowModel" },
		{ "Disc", "Solver" },
		{ "Rules", "RulesEngine" },
		{ "Rules", "CatchGeometry" },
		{ "Rules", "ComboEvaluator" },
		{ "Net" },
		{ "Actors" },
	}
do
	local names = { "Shared" }
	for _, n in p do
		table.insert(names, n)
	end
	check(find(rs, names) ~= nil, "shared " .. table.concat(p, "/"))
end

check(game:GetService("Workspace").Gravity == 160, "workspace gravity 160")
check(game:GetService("Workspace").StreamingEnabled == false, "streaming disabled (whole field must be present)")
check(sp.EnableMouseLockOption == false, "shift-lock disabled (Shift is sprint)")
check(sp.CharacterWalkSpeed == 0, "default walk speed 0 (movement engine drives characters)")

if failures > 0 then
	print(string.format("\n%d structural checks failed", failures))
	process.exit(1)
end
print("\nplace structure OK")
