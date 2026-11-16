--!strict
--[[
	AbilityService (server) — when an ability fires (src/shared/Abilities).

	The Ability remote (abilityId) fires it when the player owns it (Shop /
	Locker), it is off cooldown, the player isn't frozen and the ability's
	own canUse agrees. Then the character gets:
	  UBAbility         the id
	  UBAbilityT        Net.now() it fired (the owner's client applies the
	                    movement part; every client plays the cast)
	  UBAbilityUntil    when its effect ends (aura, throw and catch hooks)
	  UBAbilityReadyAt  when it can fire again (the HUD's cooldown)
	  UBAbilityCooldown its length, for the HUD
	Throw and catch effects are read from those attributes by ThrowService
	and CatchingService through the framework, so the server is always the
	one applying them. In Training the cooldown is short so abilities can be
	practised.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Abilities)
local Net = require(Shared.Net)

local AbilityService = {}

local services: any
local readyAt: { [number]: number } = {} -- actor id -> Net.now() it is ready again
local cooldownOf: { [number]: number } = {}

local TRAINING_COOLDOWN = 2

local function characterOf(id: number): Model?
	local actor = services.PlayerService.get(id)
	return actor and actor.character
end

local function write(id: number)
	local c = characterOf(id)
	if c then
		c:SetAttribute("UBAbilityReadyAt", readyAt[id] or 0)
		c:SetAttribute("UBAbilityCooldown", cooldownOf[id] or 0)
	end
end

-- Seconds until actor `id` can fire again (0 = ready).
function AbilityService.cooldownLeft(id: number): number
	return math.max(0, (readyAt[id] or 0) - Net.now())
end

-- Ends the running effect now (a throw spent it).
function AbilityService.spend(id: number)
	local c = characterOf(id)
	if c then
		c:SetAttribute("UBAbilityUntil", Net.now())
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
	-- only an ability you own (Shop); bots have them all
	if actor.player and not services.ProgressionService.owns(actor.player, "ability", def.id) then
		return false
	end
	local t = Net.now()
	if t < (readyAt[id] or 0) then
		return false
	end
	if def.canUse then
		-- the server's view of "in the air" lags a jump, so it is left
		-- unknown here (the client checked it); holding is the server's own
		local track = services.MovementService.track(id)
		local ok = def.canUse({ grounded = nil, holding = track ~= nil and track.holding == true })
		if not ok then
			return false
		end
	end
	local cooldown = if actor.role == "Training" then math.min(def.cooldown, TRAINING_COOLDOWN) else def.cooldown
	readyAt[id] = t + cooldown
	cooldownOf[id] = cooldown
	if def.airAction then
		services.MovementService.grantAirAction(id)
	end
	c:SetAttribute("UBAbility", def.id)
	c:SetAttribute("UBAbilityUntil", t + def.duration)
	c:SetAttribute("UBAbilityT", t)
	write(id)
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
	-- re-stamp the cooldown on new characters (respawns)
	task.spawn(function()
		while true do
			task.wait(1)
			for id in readyAt do
				local c = characterOf(id)
				if c and c:GetAttribute("UBAbilityReadyAt") == nil then
					write(id)
				elseif not services.PlayerService.get(id) then
					readyAt[id] = nil
					cooldownOf[id] = nil
				end
			end
		end
	end)
end

return AbilityService
