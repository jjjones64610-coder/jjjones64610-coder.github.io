--!strict
--[[
	AbilityService (server) — the FLOW meter and ability activations
	(Config/Abilities).

	  * The meter fills only from validated play: techniques the
	    MovementService accepted (Perfect ones most) and match stats
	    (catches, completions, assists, blocks, interceptions, goals,
	    Callahans, Greatests). It is written to the character as UBFlow
	    (0..100) for the HUD, and re-stamped after a respawn.
	  * The Ability remote (abilityId) fires an ability when the meter is
	    full and the player isn't frozen: the meter empties and the character
	    gets UBAbility (id), UBAbilityT (Net.now()) and UBAbilityUntil. The
	    owner's client applies the movement effect; every client draws the
	    aura. In Training the meter refills at once so abilities can be
	    practised.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Config.Abilities)
local MovementConfig = require(Shared.Config.Movement)
local Net = require(Shared.Net)

local AbilityService = {}

local services: any
local meters: { [number]: number } = {}

local MIN_CLEAN_POINTS = 100 -- Clean techs below this combo value (jumps, plants) earn nothing

local function characterOf(id: number): Model?
	local actor = services.PlayerService.get(id)
	return actor and actor.character
end

local function write(id: number)
	local c = characterOf(id)
	if c then
		c:SetAttribute("UBFlow", math.floor((meters[id] or 0) + 0.5))
	end
end

function AbilityService.meter(id: number): number
	return meters[id] or 0
end

function AbilityService.gain(id: number, amount: number)
	if amount <= 0 then
		return
	end
	local before = meters[id] or 0
	local after = math.min(Abilities.MeterMax, before + amount)
	if after ~= before then
		meters[id] = after
		write(id)
	end
end

-- Match stats (MatchService.stat) feed the meter.
function AbilityService.onStat(id: number, key: string, n: number?)
	local g = (Abilities.Gain :: any)[key]
	if type(g) == "number" then
		AbilityService.gain(id, g * (n or 1))
	end
end

local function onTech(id: number, tech: string, quality: string)
	if quality == "Perfect" then
		AbilityService.gain(id, Abilities.Gain.PerfectTech)
	elseif quality == "Clean" then
		local pts = (MovementConfig.ComboPoints :: any)[tech]
		if type(pts) == "number" and pts >= MIN_CLEAN_POINTS then
			AbilityService.gain(id, Abilities.Gain.CleanTech)
		end
	end
end

-- Fires `abilityId` for actor `id` if allowed. Returns whether it fired.
function AbilityService.activate(id: number, abilityId: any): boolean
	local def = Abilities.get(abilityId)
	local actor = services.PlayerService.get(id)
	local c = actor and actor.character
	if not def or not actor or not c then
		return false
	end
	if c:GetAttribute("UBFrozen") == true then
		return false
	end
	local track = services.MovementService.track(id)
	if def.id == "FlashStep" and track and track.holding then
		return false -- a blink while holding the disc would be a travel
	end
	local training = actor.role == "Training"
	if not training and (meters[id] or 0) < Abilities.MeterMax then
		return false
	end
	local t = Net.now()
	meters[id] = if training then Abilities.MeterMax else 0
	write(id)
	c:SetAttribute("UBAbility", def.id)
	c:SetAttribute("UBAbilityUntil", t + def.duration)
	c:SetAttribute("UBAbilityT", t)
	return true
end

function AbilityService.Init(s: any)
	services = s
end

function AbilityService.Start()
	local remote = Net.event("Ability")
	remote.OnServerEvent:Connect(function(player: Player, abilityId: any)
		local actor = services.PlayerService.fromPlayer(player)
		if actor then
			AbilityService.activate(actor.id, abilityId)
		end
	end)
	services.MovementService.TechAccepted:Connect(function(id: number, tech: string, quality: string)
		onTech(id, tech, quality)
	end)
	-- re-stamp the meter on new characters (respawns)
	task.spawn(function()
		while true do
			task.wait(1)
			for id in meters do
				local c = characterOf(id)
				if c and c:GetAttribute("UBFlow") == nil then
					write(id)
				elseif not services.PlayerService.get(id) then
					meters[id] = nil
				end
			end
		end
	end)
end

return AbilityService
