--!strict
-- SettingsController — local settings and key bindings, synced to the
-- player's saved profile (Settings > Controls rebinding writes here).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local InputConfig = require(Shared.Config.Input)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local SettingsController = {}

SettingsController.Changed = Signal.new() -- (key)

local values: { [string]: any } = table.clone(InputConfig.DefaultSettings)
local overrides: { keyboard: { [string]: { string } }, gamepad: { [string]: { string } } } =
	{ keyboard = {}, gamepad = {} }
local applied = false
local saveQueued = false

function SettingsController.get(key: string): any
	return values[key]
end

function SettingsController.set(key: string, value: any)
	if values[key] == value then
		return
	end
	values[key] = value
	SettingsController.Changed:Fire(key)
	SettingsController.save()
end

function SettingsController.bindings(scheme: string): { [string]: { string } }
	local base: { [string]: { string } } = if scheme == "gamepad" then InputConfig.Gamepad else InputConfig.Keyboard
	local result: { [string]: { string } } = table.clone(base)
	local o = (overrides :: any)[scheme]
	if o then
		for action, keys in o do
			result[action] = keys
		end
	end
	return result
end

function SettingsController.setBinding(scheme: string, action: string, keys: { string })
	local o = (overrides :: any)[scheme]
	if not o then
		return
	end
	o[action] = keys
	SettingsController.Changed:Fire("Bindings")
	SettingsController.save()
end

function SettingsController.resetBindings()
	overrides = { keyboard = {}, gamepad = {} }
	SettingsController.Changed:Fire("Bindings")
	SettingsController.save()
end

function SettingsController.save()
	if saveQueued then
		return
	end
	saveQueued = true
	task.delay(1.5, function()
		saveQueued = false
		Net.event("Action"):FireServer("SaveSettings", {
			values = values,
			keyboard = overrides.keyboard,
			gamepad = overrides.gamepad,
		})
	end)
end

local function applyProfile(profile: any)
	if applied or type(profile) ~= "table" or type(profile.settings) ~= "table" then
		return
	end
	applied = true
	local s = profile.settings
	if type(s.values) == "table" then
		for k: string, default: any in InputConfig.DefaultSettings :: any do
			if type(s.values[k]) == type(default) then
				values[k] = s.values[k]
			end
		end
	end
	for _, scheme in { "keyboard", "gamepad" } do
		if type(s[scheme]) == "table" then
			for action, keys in s[scheme] do
				if type(keys) == "table" and #keys > 0 then
					(overrides :: any)[scheme][action] = keys
				end
			end
		end
	end
	SettingsController.Changed:Fire("All")
end

function SettingsController.Init(_c: any) end

function SettingsController.Start()
	Net.event("Profile").OnClientEvent:Connect(applyProfile)
	task.spawn(function()
		local ok, profile = pcall(function()
			return Net.func("GetProfile"):InvokeServer()
		end)
		if ok then
			applyProfile(profile)
		end
	end)
end

return SettingsController
