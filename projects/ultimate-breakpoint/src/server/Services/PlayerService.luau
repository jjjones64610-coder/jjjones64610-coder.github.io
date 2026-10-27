--!strict
--[[
	PlayerService — the roster of actors (human players and bots).

	Owns team objects, character setup (collision group, attributes the rest
	of the game keys on), teleports, the per-actor "frozen" flag and the
	pre-pull line restriction. Players never collide with each other (ultimate
	is a non-contact sport; body positioning is resolved by catch geometry).

	Roles: "Match" (on the field this point), "Bench" (on the team, waiting
	for the next point on the sideline bench), "Training", "Spectate".
	onTeam() lists the field players; roster() includes the bench.

	Movement is client-driven: each client sets its own Humanoid WalkSpeed /
	Move every frame from its MovementSim. The server only sets the spawn
	defaults (AutoRotate off, jump power 0) once and never writes WalkSpeed on
	a player's Humanoid afterwards, so it never fights the client.

	Teleports are an explicit protocol (character attributes, written in this
	order):
	  UBTeleportPos  Vector3   where the root goes
	  UBTeleportYaw  number    facing (CameraController.getYaw convention)
	  UBTeleportFace boolean   the client also turns its camera (line-ups,
	                           drills, spawns); false keeps the camera
	  UBTeleport     number    counter, bumped last
	The client puts its root there if it is more than a stud away, zeroes its
	velocity and resets its sim (keeping frozen, holding, exertion, pivot).

	Line restriction (before the pull): UBLineX / UBLineSide; the character
	must keep (pos.X - UBLineX) * UBLineSide >= 0. nil = free.

	Fixed hitbox (Config/Hitbox): every player's avatar is rescaled to the
	standard proportions when it spawns (HumanoidDescription scales; clothes,
	colours and accessories are kept), so no avatar is bigger or smaller
	than another. Gameplay zones are measured from the feet anyway.
]]

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeamsService = game:GetService("Teams")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)
local TeamsConfig = require(Shared.Config.Teams)
local Hitbox = require(Shared.Config.Hitbox)

local PlayerService = {}

export type Actor = {
	id: number,
	name: string,
	player: Player?,
	isBot: boolean,
	team: string, -- "A" | "B" | "N"
	role: string, -- "Match" | "Bench" | "Training" | "Spectate"
	character: Model?,
	teleportCount: number,
	joinedAt: number,
	lineX: number?, -- pre-pull restriction (UBLineX / UBLineSide), re-stamped on respawn
	lineSide: number?,
}

export type TeleportOptions = {
	face: boolean?, -- the client also turns its camera to the new facing
}

local actors: { [number]: Actor } = {}
local teamObjects: { [string]: Team } = {}
local services: any

PlayerService.ActorAdded = Signal.new()
PlayerService.ActorRemoving = Signal.new()
PlayerService.CharacterSpawned = Signal.new()
PlayerService.TeamChanged = Signal.new()

PlayerService.CollisionGroup = "UBPlayers"

-- Root parts collide with the world but not with each other. Limbs collide
-- with nothing: the procedural layout/slide poses must never snag the ground
-- (the Humanoid floats on its root part, so limbs need no collision).
PlayerService.LimbGroup = "UBLimbs"

local function setupCollisionGroups()
	for _, g in { PlayerService.CollisionGroup, PlayerService.LimbGroup } do
		pcall(function()
			PhysicsService:RegisterCollisionGroup(g)
		end)
	end
	PhysicsService:CollisionGroupSetCollidable(PlayerService.CollisionGroup, PlayerService.CollisionGroup, false)
	PhysicsService:CollisionGroupSetCollidable(PlayerService.LimbGroup, "Default", false)
	PhysicsService:CollisionGroupSetCollidable(PlayerService.LimbGroup, PlayerService.CollisionGroup, false)
	PhysicsService:CollisionGroupSetCollidable(PlayerService.LimbGroup, PlayerService.LimbGroup, false)
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

local function groupFor(part: BasePart): string
	return if part.Name == "HumanoidRootPart" then PlayerService.CollisionGroup else PlayerService.LimbGroup
end

local function applyCollision(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = groupFor(d)
		end
	end
	model.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = groupFor(d)
		end
	end)
end

local function stampCharacter(actor: Actor, model: Model)
	model:SetAttribute("UBId", actor.id)
	model:SetAttribute("UBTeam", actor.team)
	model:SetAttribute("UBName", actor.name)
	model:SetAttribute("UBRole", actor.role)
	model:SetAttribute("UBTeleport", actor.teleportCount)
	model:SetAttribute("UBLineX", actor.lineX)
	model:SetAttribute("UBLineSide", actor.lineSide)
end

-- True when a description already has the standard scales.
local function isStandard(desc: HumanoidDescription): boolean
	local S = Hitbox.Scales
	local function near(a: number, b: number): boolean
		return math.abs(a - b) < 1e-3
	end
	return near(desc.HeightScale, S.HeightScale)
		and near(desc.WidthScale, S.WidthScale)
		and near(desc.DepthScale, S.DepthScale)
		and near(desc.HeadScale, S.HeadScale)
		and near(desc.BodyTypeScale, S.BodyTypeScale)
		and near(desc.ProportionScale, S.ProportionScale)
end

-- Gives a description the standard body scales (Config/Hitbox.Scales).
function PlayerService.standardize(desc: HumanoidDescription)
	local S = Hitbox.Scales
	desc.HeightScale = S.HeightScale
	desc.WidthScale = S.WidthScale
	desc.DepthScale = S.DepthScale
	desc.HeadScale = S.HeadScale
	desc.BodyTypeScale = S.BodyTypeScale
	desc.ProportionScale = S.ProportionScale
end

-- Rescales a freshly spawned player character to the standard body. Runs in
-- its own thread (applying a description yields). Leaves the avatar as it is
-- if the description cannot be read or applied; gameplay zones still use
-- the fixed hitbox.
local function normalizeAvatar(model: Model, humanoid: Humanoid)
	-- CharacterAdded can fire before the model is parented to the workspace
	for _ = 1, 50 do
		if model:IsDescendantOf(workspace) then
			break
		end
		task.wait(0.1)
	end
	if not model:IsDescendantOf(workspace) or humanoid.Parent ~= model then
		return
	end
	local ok, desc = pcall(function()
		return humanoid:GetAppliedDescription()
	end)
	if not ok or not desc or isStandard(desc) then
		return
	end
	PlayerService.standardize(desc)
	local applied, err = pcall(function()
		humanoid:ApplyDescriptionAsync(desc)
	end)
	if not applied then
		warn("[PlayerService] could not apply the standard body: " .. tostring(err))
	end
end

function PlayerService.setupCharacter(actor: Actor, model: Model)
	actor.character = model
	applyCollision(model)
	stampCharacter(actor, model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- one-time spawn defaults; the owner (client MovementController for
		-- players, BotService for bots) drives WalkSpeed / Move / JumpPower
		humanoid.BreakJointsOnDeath = false
		humanoid.UseJumpPower = true
		humanoid.JumpPower = 0
		humanoid.AutoRotate = false
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		if not actor.isBot and Hitbox.NormalizeAvatars and humanoid.RigType == Enum.HumanoidRigType.R15 then
			task.spawn(normalizeAvatar, model, humanoid)
		end
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
		lineX = nil,
		lineSide = nil,
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
		lineX = nil,
		lineSide = nil,
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

-- Field players of a team (role "Match").
function PlayerService.onTeam(team: string, includeBots: boolean?): { Actor }
	local list = {}
	for _, a in PlayerService.all() do
		if a.team == team and a.role == "Match" and (includeBots ~= false or not a.isBot) then
			table.insert(list, a)
		end
	end
	return list
end

-- Everyone on a team: field players and the bench.
function PlayerService.roster(team: string, includeBots: boolean?): { Actor }
	local list = {}
	for _, a in PlayerService.all() do
		if a.team == team and (a.role == "Match" or a.role == "Bench") and (includeBots ~= false or not a.isBot) then
			table.insert(list, a)
		end
	end
	return list
end

-- The bench of a team (humans waiting for the next point).
function PlayerService.bench(team: string): { Actor }
	local list = {}
	for _, a in PlayerService.all() do
		if a.team == team and a.role == "Bench" then
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

-- Facing yaw of a CFrame in the CameraController.getYaw convention
-- (CFrame.Angles(0, yaw, 0) looks along the flat LookVector).
local function yawOf(cf: CFrame): number?
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		return nil
	end
	return math.atan2(-flat.X, -flat.Z)
end

-- Moves an actor's root to cf (kept upright) and tells their client exactly
-- where it went (see the protocol in the header). opts.face also turns the
-- camera; without it the client keeps its camera.
function PlayerService.teleport(actor: Actor, cf: CFrame, opts: TeleportOptions?)
	local c = actor.character
	if not c or not c.Parent then
		return
	end
	local root = PlayerService.root(actor)
	local yaw = yawOf(cf) or (if root then yawOf(root.CFrame) else nil) or 0
	local target = CFrame.new(cf.Position) * CFrame.Angles(0, yaw, 0)
	c:SetAttribute("UBTeleportPos", target.Position)
	c:SetAttribute("UBTeleportYaw", yaw)
	c:SetAttribute("UBTeleportFace", opts ~= nil and opts.face == true)
	if root then
		-- sticks for server-owned bots; the owning client zeroes its own
		root.AssemblyLinearVelocity = Vector3.zero
	end
	c:PivotTo(target)
	actor.teleportCount += 1
	c:SetAttribute("UBTeleport", actor.teleportCount)
	if services and services.MovementService then
		services.MovementService.noteTeleport(actor.id, target.Position)
	end
end

-- Pre-pull line restriction: keep (pos.X - x) * side >= 0. nil clears it.
function PlayerService.setLine(actor: Actor, x: number?, side: number?)
	if x == nil or side == nil then
		actor.lineX = nil
		actor.lineSide = nil
	else
		actor.lineX = x
		actor.lineSide = if side < 0 then -1 else 1
	end
	local c = actor.character
	if c then
		c:SetAttribute("UBLineX", actor.lineX)
		c:SetAttribute("UBLineSide", actor.lineSide)
	end
end

-- Clears every actor's line restriction.
function PlayerService.clearLines()
	for _, a in PlayerService.all() do
		if a.lineX ~= nil then
			PlayerService.setLine(a, nil, nil)
		end
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
