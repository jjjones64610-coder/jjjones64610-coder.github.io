--!strict
--[[
	SettingsController — local settings and key bindings, synced to the
	player's saved profile (Settings > Controls rebinding writes here).

	Every key in Config/Input DefaultSettings is persisted (AutoSprint, on by
	default, included); profiles saved before a key existed simply get its
	default. When a default changes on purpose (Input.SettingsVersion /
	Input.Migrations) the listed keys are reset once for older profiles.

	keyLabel(action, scheme) gives the short label of the first key bound to
	an action ("Q", "SHIFT", "LMB", "X"), so HUD pips and hints follow rebinds.
]]

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

-- Short label of the first key bound to `action` in `scheme` ("keyboard" or
-- "gamepad"); "" when nothing is bound.
function SettingsController.keyLabel(action: string, scheme: string?): string
	local keys = SettingsController.bindings(scheme or "keyboard")[action]
	return InputConfig.keyLabel(if keys then keys[1] else nil)
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

-- Keys whose default changed after the profile was saved.
local function migratedKeys(savedVersion: any): { [string]: boolean }
	local skip: { [string]: boolean } = {}
	local from = if type(savedVersion) == "number" then savedVersion else 1
	for version, keys in InputConfig.Migrations do
		if version > from then
			for _, k in keys do
				skip[k] = true
			end
		end
	end
	return skip
end

local function applyProfile(profile: any)
	if applied or type(profile) ~= "table" or type(profile.settings) ~= "table" then
		return
	end
	applied = true
	local s = profile.settings
	local migrated = false
	if type(s.values) == "table" then
		local skip = migratedKeys(s.values.SettingsVersion)
		migrated = next(skip) ~= nil
		for k: string, default: any in InputConfig.DefaultSettings :: any do
			if not skip[k] and k ~= "SettingsVersion" and type(s.values[k]) == type(default) then
				values[k] = s.values[k]
			end
		end
		values.SettingsVersion = InputConfig.SettingsVersion
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
	if migrated then
		-- store the new version so the reset happens only once
		SettingsController.save()
	end
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
