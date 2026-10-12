--!strict
--[[
	PlayerService — the roster of actors (human players and bots).

	Owns team objects, character setup (collision group, attributes the rest
	of the game keys on), teleports and the per-actor "frozen" flag used during
	line-ups. Players never collide with each other (ultimate is a non-contact
	sport; body positioning is resolved by catch geometry instead).
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeamsService = game:GetService("Teams")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)
local TeamsConfig = require(Shared.Config.Teams)

local PlayerService = {}

export type Actor = {
	id: number,
	name: string,
	player: Player?,
	isBot: boolean,
	team: string, -- "A" | "B" | "N"
	role: string, -- "Match" | "Training" | "Spectate"
	character: Model?,
	teleportCount: number,
	joinedAt: number,
}

local actors: { [number]: Actor } = {}
local teamObjects: { [string]: Team } = {}
local services: any

PlayerService.ActorAdded = Signal.new()
PlayerService.ActorRemoving = Signal.new()
PlayerService.CharacterSpawned = Signal.new()
PlayerService.TeamChanged = Signal.new()

PlayerService.CollisionGroup = "UBPlayers"

local function setupCollisionGroups()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(PlayerService.CollisionGroup)
	end)
	PhysicsService:CollisionGroupSetCollidable(PlayerService.CollisionGroup, PlayerService.CollisionGroup, false)
end

local function setupTeams()
	local list: { [string]: any } = { A = TeamsConfig.A, B = TeamsConfig.B, N = TeamsConfig.Neutral }
	for key, cfg in list do
		local t = TeamsService:FindFirstChild(cfg.Name) :: Team?
		if not t then
			local nt = Instance.new("Team")
			nt.Name = cfg.Name
			nt.TeamColor = cfg.BrickColor
			nt.AutoAssignable = false
			nt.Parent = TeamsService
			t = nt
		end
		teamObjects[key] = t :: Team
	end
end

local function applyCollision(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = PlayerService.CollisionGroup
		end
	end
	model.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = PlayerService.CollisionGroup
		end
	end)
end

local function stampCharacter(actor: Actor, model: Model)
	model:SetAttribute("UBId", actor.id)
	model:SetAttribute("UBTeam", actor.team)
	model:SetAttribute("UBName", actor.name)
	model:SetAttribute("UBRole", actor.role)
	model:SetAttribute("UBTeleport", actor.teleportCount)
end

function PlayerService.setupCharacter(actor: Actor, model: Model)
	actor.character = model
	applyCollision(model)
	stampCharacter(actor, model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.BreakJointsOnDeath = false
		humanoid.UseJumpPower = true
		humanoid.JumpPower = 0
		humanoid.AutoRotate = false
		if not actor.isBot then
			humanoid.WalkSpeed = 0
		end
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end
	PlayerService.CharacterSpawned:Fire(actor, model)
end

local function onPlayerAdded(player: Player)
	local actor: Actor = {
		id = player.UserId,
		name = player.DisplayName,
		player = player,
		isBot = false,
		team = "N",
		role = "Spectate",
		character = nil,
		teleportCount = 0,
		joinedAt = os.clock(),
	}
	actors[actor.id] = actor
	player.Team = teamObjects.N
	player.CharacterAdded:Connect(function(model)
		PlayerService.setupCharacter(actor, model)
	end)
	PlayerService.ActorAdded:Fire(actor)
	if player.Character then
		PlayerService.setupCharacter(actor, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	local actor = actors[player.UserId]
	if actor then
		PlayerService.ActorRemoving:Fire(actor)
		actors[player.UserId] = nil
	end
end

function PlayerService.registerBot(id: number, name: string, team: string, model: Model): Actor
	local actor: Actor = {
		id = id,
		name = name,
		player = nil,
		isBot = true,
		team = team,
		role = "Match",
		character = model,
		teleportCount = 0,
		joinedAt = os.clock(),
	}
	actors[id] = actor
	PlayerService.setupCharacter(actor, model)
	PlayerService.ActorAdded:Fire(actor)
	return actor
end

function PlayerService.unregisterBot(id: number)
	local actor = actors[id]
	if actor and actor.isBot then
		PlayerService.ActorRemoving:Fire(actor)
		actors[id] = nil
		if actor.character then
			actor.character:Destroy()
		end
	end
end

function PlayerService.get(id: number): Actor?
	return actors[id]
end

function PlayerService.fromPlayer(player: Player): Actor?
	return actors[player.UserId]
end

function PlayerService.all(): { Actor }
	local list = {}
	for _, a in actors do
		table.insert(list, a)
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

function PlayerService.humans(): { Actor }
	local list = {}
	for _, a in PlayerService.all() do
		if not a.isBot then
			table.insert(list, a)
		end
	end
	return list
end

function PlayerService.onTeam(team: string, includeBots: boolean?): { Actor }
	local list = {}
	for _, a in PlayerService.all() do
		if a.team == team and a.role == "Match" and (includeBots ~= false or not a.isBot) then
			table.insert(list, a)
		end
	end
	return list
end

function PlayerService.setTeam(actor: Actor, team: string, role: string?)
	actor.team = team
	if role then
		actor.role = role
	end
	if actor.player then
		actor.player.Team = teamObjects[team] or teamObjects.N
	end
	if actor.character then
		stampCharacter(actor, actor.character)
	end
	PlayerService.TeamChanged:Fire(actor)
end

function PlayerService.root(actor: Actor): BasePart?
	local c = actor.character
	if c and c.Parent then
		return c:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	return nil
end

function PlayerService.humanoid(actor: Actor): Humanoid?
	local c = actor.character
	if c then
		return c:FindFirstChildOfClass("Humanoid")
	end
	return nil
end

-- Moves an actor and tells their client to drop its momentum.
function PlayerService.teleport(actor: Actor, cf: CFrame)
	local c = actor.character
	if not c or not c.Parent then
		return
	end
	local root = PlayerService.root(actor)
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
	end
	c:PivotTo(cf)
	actor.teleportCount += 1
	c:SetAttribute("UBTeleport", actor.teleportCount)
	if services and services.MovementService then
		services.MovementService.noteTeleport(actor.id)
	end
end

function PlayerService.setFrozen(actor: Actor, frozen: boolean)
	local c = actor.character
	if c then
		c:SetAttribute("UBFrozen", frozen)
	end
end

function PlayerService.setAllFrozen(frozen: boolean, filter: ((Actor) -> boolean)?)
	for _, a in PlayerService.all() do
		if filter == nil or filter(a) then
			PlayerService.setFrozen(a, frozen)
		end
	end
end

function PlayerService.Init(s: any)
	services = s
	setupCollisionGroups()
	setupTeams()
end

function PlayerService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
end

return PlayerService
