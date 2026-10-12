--!strict
--[[
	BotService — server-driven teammates/opponents so a match is playable with
	one human (and Studio solo testing works).

	Bots use the same rules, catch geometry, throw model and solver as humans.
	They are deliberately imperfect: reaction delay, aim noise and a skill
	value per bot (deterministic, seeded). They do not use the advanced
	movement techniques except jumping and diving; outplaying them with
	movement tech is part of the fun.

	Behaviour summary
	  offense, disc held by a teammate   handlers reset beside the disc;
	                                     cutters pick open space upfield
	                                     (scored by distance from defenders
	                                     and progress) and sprint to it
	  offense, holding                   wait a beat, read lanes, throw a
	                                     solved lead pass to the most open
	                                     receiver; panic-throw late in stall
	  defense                            the closest defender marks (hands
	                                     up, force side), the rest play
	                                     goal-side man-to-man with a
	                                     reaction lag
	  disc in the air                    the best-placed bot on each team
	                                     chases the earliest reachable point
	                                     on the flight; jumps or lays out
	                                     when needed
	  disc on the ground                 nearest offensive bot picks it up
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Actors = require(Shared.Actors)
local Rng = require(Shared.Util.Rng)
local VecMath = require(Shared.Util.VecMath)
local TeamsConfig = require(Shared.Config.Teams)
local DiscConfig = require(Shared.Config.Disc)
local MovementConfig = require(Shared.Config.Movement)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local Solver = require(Shared.Disc.Solver)
local FieldGeometry = require(Shared.Rules.FieldGeometry)
local RulesEngine = require(Shared.Rules.RulesEngine)
local Locomotion = require(Shared.Animation.Locomotion)

local BotService = {}

local services: any
local folder: Folder

type Brain = {
	id: number,
	name: string,
	team: string,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	loco: Locomotion.Controller?,
	rng: Rng.Rng,
	skill: number,
	reaction: number,
	nextThink: number,
	target: Vector3?,
	speed: number,
	cutUntil: number,
	holdUntil: number,
	diveLockUntil: number,
	lastReach: number,
	lagBuffer: { { t: number, p: Vector3 } },
	custom: ((Brain, number) -> ())?,
	mode: string,
}

local brains: { [number]: Brain } = {}
local nextId = Actors.BotIdBase
local seedCounter = 0

local NAMES = {
	"Huck Norris",
	"Flick Jagger",
	"Layla Out",
	"Hammer Time",
	"Scoober Doo",
	"Stall Ten",
	"Pivot Pete",
	"Blade Runner",
	"Callahan Kid",
	"Greatest Gwen",
	"Bricky",
	"Swing Lowe",
	"Dump Truck",
	"Deep Dana",
	"Break Mark",
	"Zone Defense",
	"Spin Doctor",
	"Pancake",
	"Hospital Hal",
	"Sky Walker",
}

local SKIN = {
	Color3.fromRGB(255, 220, 190),
	Color3.fromRGB(234, 184, 146),
	Color3.fromRGB(198, 140, 100),
	Color3.fromRGB(141, 92, 62),
	Color3.fromRGB(96, 62, 42),
}

local SPRINT = 24
local JOG = 16

local function now(): number
	return Net.now()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function teamColor(team: string): (Color3, Color3)
	if team == "A" then
		return TeamsConfig.A.Color, TeamsConfig.A.Dark
	elseif team == "B" then
		return TeamsConfig.B.Color, TeamsConfig.B.Dark
	end
	return TeamsConfig.Neutral.Color, Color3.fromRGB(80, 80, 90)
end

function BotService.spawn(team: string, custom: ((any, number) -> ())?, role: string?): number
	nextId -= 1
	seedCounter += 1
	local id = nextId
	local rng = Rng.new(seedCounter * 2654435761 + 97)
	local name = NAMES[((seedCounter - 1) % #NAMES) + 1]
	local shirt, shorts = teamColor(team)
	local desc = Instance.new("HumanoidDescription")
	local skin = SKIN[rng:int(1, #SKIN)]
	desc.HeadColor = skin
	desc.LeftArmColor = skin
	desc.RightArmColor = skin
	desc.TorsoColor = shirt
	desc.LeftLegColor = shorts
	desc.RightLegColor = shorts

	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok or not model then
		warn("[BotService] could not create bot model: " .. tostring(model))
		return id
	end
	local m = model :: Model
	m.Name = "Bot_" .. name
	local humanoid = m:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart
	if not humanoid or not root then
		m:Destroy()
		return id
	end
	m:PivotTo(services.ArenaService.spawnCFrame() + Vector3.new(rng:range(-6, 6), 0, rng:range(-3, 3)))
	m.Parent = folder
	root:SetNetworkOwner(nil)
	local actor = services.PlayerService.registerBot(id, name .. " [BOT]", team, m)
	if role then
		services.PlayerService.setTeam(actor, team, role)
	end
	humanoid.AutoRotate = true
	for _, st in
		{
			Enum.HumanoidStateType.Climbing,
			Enum.HumanoidStateType.Seated,
			Enum.HumanoidStateType.Ragdoll,
			Enum.HumanoidStateType.FallingDown,
		}
	do
		humanoid:SetStateEnabled(st, false)
	end
	humanoid.UseJumpPower = true
	humanoid.JumpPower = MovementConfig.JumpVelocity
	humanoid.WalkSpeed = JOG
	local brain: Brain = {
		id = id,
		name = name,
		team = team,
		model = m,
		humanoid = humanoid,
		root = root,
		loco = nil,
		rng = rng,
		skill = rng:range(0.6, 0.85),
		reaction = rng:range(0.18, 0.32),
		nextThink = 0,
		target = nil,
		speed = JOG,
		cutUntil = 0,
		holdUntil = 0,
		diveLockUntil = 0,
		lastReach = 0,
		lagBuffer = {},
		custom = custom,
		mode = "Ground",
	}
	brains[id] = brain
	task.spawn(function()
		local okLoco, loco = pcall(Locomotion.new, humanoid)
		if okLoco then
			brain.loco = loco
		end
	end)
	return id
end

function BotService.remove(id: number)
	local b = brains[id]
	brains[id] = nil
	if b and b.loco then
		Locomotion.destroy(b.loco)
	end
	services.PlayerService.unregisterBot(id)
end

function BotService.brain(id: number): Brain?
	return brains[id]
end

---------------------------------------------------------------------------
-- motor helpers
---------------------------------------------------------------------------

local function frozen(b: Brain): boolean
	return b.model:GetAttribute("UBFrozen") == true
end

local function moveToward(b: Brain, target: Vector3?, speed: number)
	if not target then
		b.humanoid:Move(Vector3.zero)
		return
	end
	local delta = flat(target - b.root.Position)
	if delta.Magnitude < 1.0 then
		b.humanoid:Move(Vector3.zero)
		return
	end
	b.humanoid.WalkSpeed = speed
	b.humanoid:Move(delta.Unit)
end

local function face(b: Brain, point: Vector3)
	local p = b.root.Position
	local dir = flat(point - p)
	if dir.Magnitude > 0.1 then
		b.root.CFrame = CFrame.lookAt(p, p + dir)
	end
end

local function setMode(b: Brain, mode: string)
	if b.mode ~= mode then
		b.mode = mode
		services.MovementService.setBotMode(b.id, mode)
	end
end

local function dive(b: Brain, dir: Vector3)
	local t = now()
	if t < b.diveLockUntil then
		return
	end
	b.diveLockUntil = t + 1.6
	local d = VecMath.flatUnit(dir)
	services.MovementService.botTech(b.id, "Dive", d, "Dive")
	b.mode = "Dive"
	b.humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	b.root.AssemblyLinearVelocity = d * 27 + Vector3.new(0, 18, 0)
	task.delay(0.45, function()
		if brains[b.id] then
			setMode(b, "DiveSlide")
		end
	end)
	task.delay(0.9, function()
		if brains[b.id] then
			setMode(b, "Recover")
		end
	end)
	task.delay(1.35, function()
		if brains[b.id] then
			setMode(b, "Ground")
		end
	end)
end

local function jump(b: Brain)
	if b.humanoid.FloorMaterial ~= Enum.Material.Air then
		b.humanoid.Jump = true
		services.MovementService.botTech(b.id, "Jump", VecMath.flatUnit(b.root.CFrame.LookVector), "Air")
		task.delay(0.6, function()
			if brains[b.id] and b.mode == "Air" then
				setMode(b, "Ground")
			end
		end)
	end
end

local function reachFor(b: Brain, point: Vector3)
	local t = now()
	if t - b.lastReach < 0.7 then
		return
	end
	b.lastReach = t
	local dir = point - (b.root.Position + Vector3.new(0, 1.5, 0))
	services.CatchingService.reach(b.id, dir)
end

-- position of an actor `lag` seconds ago (reaction delay for defenders)
local function laggedPosition(b: Brain, targetId: number, lag: number): Vector3?
	local root = Actors.rootOf(targetId)
	if not root then
		return nil
	end
	local t = now()
	table.insert(b.lagBuffer, { t = t, p = root.Position })
	while #b.lagBuffer > 2 and b.lagBuffer[2].t < t - lag do
		table.remove(b.lagBuffer, 1)
	end
	return b.lagBuffer[1].p
end

---------------------------------------------------------------------------
-- reading the game
---------------------------------------------------------------------------

local function teammates(b: Brain): { any }
	local list = {}
	for _, a in services.PlayerService.onTeam(b.team) do
		if a.id ~= b.id then
			table.insert(list, a)
		end
	end
	return list
end

local function opponents(b: Brain): { any }
	return services.PlayerService.onTeam(RulesEngine.other(b.team))
end

local function nearestDistance(pos: Vector3, actors: { any }): number
	local best = math.huge
	for _, a in actors do
		local r = services.PlayerService.root(a)
		if r then
			best = math.min(best, flat(r.Position - pos).Magnitude)
		end
	end
	return best
end

local function laneClearance(from: Vector3, to: Vector3, actors: { any }): number
	local best = math.huge
	for _, a in actors do
		local r = services.PlayerService.root(a)
		if r then
			local c = VecMath.closestOnSegment(flat(from), flat(to), flat(r.Position))
			best = math.min(best, (c - flat(r.Position)).Magnitude)
		end
	end
	return best
end

-- Earliest point on the current flight this bot can reach in time.
local function interceptPoint(b: Brain, d: any): (Vector3?, number?)
	local s = d.sim
	if not s then
		return nil, nil
	end
	local copy = DiscPhysics.copy(s)
	local base = now()
	local ground = d.groundY
	local myPos = b.root.Position
	local dt = 1 / 30
	local reaction = b.reaction * (1.4 - b.skill)
	while copy.t < s.t + 6 do
		DiscPhysics.step(copy, dt, d.wind)
		local h = copy.py - ground
		if h <= DiscConfig.Physics.GroundContact then
			break
		end
		if h < 9 then
			local tLeft = (d.launchTime + copy.t) - base
			local p = Vector3.new(copy.px, ground, copy.pz)
			local runTime = flat(p - myPos).Magnitude / SPRINT + reaction
			if runTime <= tLeft + 0.05 then
				return Vector3.new(copy.px, copy.py, copy.pz), tLeft
			end
		end
	end
	return nil, nil
end

local function chaseFlight(b: Brain, d: any): boolean
	local point, tLeft = interceptPoint(b, d)
	if not point or not tLeft then
		return false
	end
	local horiz = flat(point - b.root.Position)
	local dist = horiz.Magnitude
	b.target = Vector3.new(point.X, b.root.Position.Y, point.Z)
	b.speed = SPRINT
	local discPos = services.DiscService.currentPosition(d)
	if discPos then
		local toDisc = discPos - b.root.Position
		local flatDist = flat(toDisc).Magnitude
		local height = discPos.Y - d.groundY
		if flatDist < 6 and height > 6.5 and tLeft < 0.45 then
			jump(b)
		end
		if flatDist < 5.5 then
			reachFor(b, discPos)
		end
		-- lay out for a disc that would otherwise be just out of reach
		if flatDist > 3.5 and flatDist < 7 and height < 4.5 and tLeft < 0.35 and b.rng:next() < b.skill then
			dive(b, toDisc)
		end
	end
	local _ = dist
	return true
end

-- Which bot on a team should chase the current flight? (closest arrival)
local function isBestChaser(b: Brain, d: any): boolean
	local myPoint, myT = interceptPoint(b, d)
	if not myPoint or not myT then
		return false
	end
	local myDist = flat(myPoint - b.root.Position).Magnitude
	for _, a in services.PlayerService.onTeam(b.team) do
		if a.id ~= b.id then
			local r = services.PlayerService.root(a)
			if r and flat(myPoint - r.Position).Magnitude < myDist - 2 then
				if a.isBot then
					return false
				end
				-- a human teammate is closer: let them have it
				return false
			end
		end
	end
	return true
end

---------------------------------------------------------------------------
-- decisions
---------------------------------------------------------------------------

local function thinkHolder(b: Brain, e: RulesEngine.State)
	local t = now()
	b.target = nil
	if b.holdUntil == 0 then
		b.holdUntil = t + b.rng:range(0.8, 2.2) * (1.3 - b.skill)
		return
	end
	local stall = services.DefenseService.stallCount()
	local stallMax = services.MatchService.mode().StallMax
	if t < b.holdUntil and stall < stallMax - 3 then
		return
	end
	local f = services.ArenaService.field()
	local attackDir = FieldGeometry.attackDirection(e.attack[b.team])
	local opp = opponents(b)
	local best, bestScore = nil, -math.huge
	for _, a in teammates(b) do
		local r = services.PlayerService.root(a)
		if r then
			local lead = r.Position + flat(r.AssemblyLinearVelocity) * 0.9
			if FieldGeometry.inBounds(f, lead) then
				local open = math.min(nearestDistance(lead, opp), 18)
				local lane = math.min(laneClearance(b.root.Position, lead, opp), 10)
				local progress = (lead - b.root.Position):Dot(attackDir)
				local dist = flat(lead - b.root.Position).Magnitude
				local score = open * 1.2 + lane * 1.6 + progress * 0.08 - math.max(0, dist - 90) * 0.15
				if dist < 8 then
					score -= 20
				end
				if score > bestScore then
					best, bestScore = a, score
				end
			end
		end
	end
	if not best then
		return
	end
	if bestScore < 10 and stall < stallMax - 2 then
		b.holdUntil = t + 0.4
		return
	end
	local r = services.PlayerService.root(best) :: BasePart
	-- release from the side away from the marker
	local markerId = Net.state():GetAttribute("MarkerId")
	local throwType = "Backhand"
	if type(markerId) == "number" and markerId ~= 0 then
		local mroot = Actors.rootOf(markerId)
		if mroot then
			local right = VecMath.flatUnit(b.root.CFrame.RightVector)
			throwType = if (mroot.Position - b.root.Position):Dot(right) < 0 then "Forehand" else "Backhand"
		end
	end
	local lane = laneClearance(b.root.Position, r.Position, opp)
	if lane < 3 and flat(r.Position - b.root.Position).Magnitude > 30 and b.rng:next() < 0.5 then
		throwType = "Hammer"
	end
	local sol = Solver.solve({
		rootPos = b.root.Position,
		throwType = throwType,
		target = r.Position + Vector3.new(0, 1, 0),
		targetVel = flat(r.AssemblyLinearVelocity),
		groundY = f.groundY,
		wind = services.ArenaService.wind(),
		coarse = true,
	})
	if not sol or (sol.miss > 3.5 and stall < stallMax - 2) then
		-- no catchable pass to that receiver right now; look again shortly
		b.holdUntil = t + 0.3
		return
	end
	local params = sol.params
	local noise = (1 - b.skill) * 0.07
	params.yaw += b.rng:range(-noise, noise)
	params.pitch += b.rng:range(-noise, noise) * 0.6
	face(b, r.Position)
	b.holdUntil = 0
	services.ThrowService.throw(b.id, params, true)
end

local function thinkOffense(b: Brain, e: RulesEngine.State)
	local t = now()
	local holderRoot = if e.holder then Actors.rootOf(e.holder) else nil
	if not holderRoot then
		return
	end
	local attackDir = FieldGeometry.attackDirection(e.attack[b.team])
	local f = services.ArenaService.field()
	local distToHolder = flat(b.root.Position - holderRoot.Position).Magnitude
	-- the closest teammate stays available as a reset ("dump") option
	local isHandler = true
	for _, a in teammates(b) do
		if a.id ~= e.holder then
			local r = services.PlayerService.root(a)
			if r and flat(r.Position - holderRoot.Position).Magnitude < distToHolder then
				isHandler = false
				break
			end
		end
	end
	if t < b.cutUntil and b.target then
		return
	end
	local opp = opponents(b)
	local bestSpot, bestScore = nil, -math.huge
	for _ = 1, 10 do
		local forward = if isHandler then b.rng:range(-12, 6) else b.rng:range(20, 75)
		local side = if isHandler then b.rng:range(-14, 14) else b.rng:range(-f.halfWidth + 8, f.halfWidth - 8)
		local spot = holderRoot.Position + attackDir * forward
		spot = Vector3.new(spot.X, b.root.Position.Y, if isHandler then holderRoot.Position.Z + side else side)
		local clamped = FieldGeometry.clampInBounds(f, spot, 6)
		spot = Vector3.new(clamped.X, b.root.Position.Y, clamped.Z)
		local open = math.min(nearestDistance(spot, opp), 20)
		local crowd = math.min(nearestDistance(spot, teammates(b)), 15)
		local score = open * 1.5 + crowd + (spot - holderRoot.Position):Dot(attackDir) * 0.05
		if score > bestScore then
			bestSpot, bestScore = spot, score
		end
	end
	b.target = bestSpot
	b.speed = if isHandler then JOG else SPRINT
	b.cutUntil = t + b.rng:range(1.2, 2.6)
end

local function thinkDefense(b: Brain, e: RulesEngine.State)
	local holder = e.holder
	if not holder then
		return
	end
	local holderRoot = Actors.rootOf(holder)
	if not holderRoot then
		return
	end
	-- "goal side": between an attacker and the end zone the offense attacks
	local offenseTeam = RulesEngine.other(b.team)
	local goalSide = FieldGeometry.attackDirection(e.attack[offenseTeam])
	local myDist = flat(b.root.Position - holderRoot.Position).Magnitude
	local marker = true
	for _, a in services.PlayerService.onTeam(b.team) do
		if a.id ~= b.id then
			local r = services.PlayerService.root(a)
			if r and flat(r.Position - holderRoot.Position).Magnitude < myDist then
				marker = false
				break
			end
		end
	end
	if marker then
		-- force one side: shade toward the open-side sideline
		local forceSide = Vector3.new(0, 0, if e.pointNumber % 2 == 0 then 1 else -1)
		local spot = holderRoot.Position + goalSide * 3.4 + forceSide * 1.0
		b.target = Vector3.new(spot.X, b.root.Position.Y, spot.Z)
		b.speed = JOG
		local windup = holderRoot.Parent and holderRoot.Parent:GetAttribute("WindupType")
		local stance = if windup == "Hammer" or windup == "Scoober" then "High" else "Low"
		if myDist < 7 then
			services.DefenseService.setStance(b.id, true, stance)
			face(b, holderRoot.Position)
		end
		return
	end
	services.DefenseService.setStance(b.id, false, "Low")
	-- man-to-man: guard the closest attacker no teammate is already on
	local opp = opponents(b)
	local best, bestD = nil, math.huge
	for _, a in opp do
		if a.id ~= holder then
			local r = services.PlayerService.root(a)
			if r then
				local dd = flat(r.Position - b.root.Position).Magnitude
				local claimed = false
				for _, mate in services.PlayerService.onTeam(b.team) do
					if mate.id ~= b.id then
						local mr = services.PlayerService.root(mate)
						if mr and flat(mr.Position - r.Position).Magnitude < dd - 1 then
							claimed = true
							break
						end
					end
				end
				if not claimed and dd < bestD then
					best, bestD = a, dd
				end
			end
		end
	end
	if not best then
		local spot = holderRoot.Position + goalSide * 25
		b.target = Vector3.new(spot.X, b.root.Position.Y, spot.Z)
		b.speed = JOG
		return
	end
	local lagged = laggedPosition(b, best.id, b.reaction * (1.5 - b.skill))
	if lagged then
		local toDisc = VecMath.flatUnit(holderRoot.Position - lagged)
		local spot = lagged + goalSide * 3 + toDisc * 2
		b.target = Vector3.new(spot.X, b.root.Position.Y, spot.Z)
		b.speed = SPRINT
	end
end

local function thinkMatch(b: Brain)
	local e = services.MatchService.engine()
	local phase = services.MatchService.phase()
	if not e or frozen(b) then
		b.target = nil
		return
	end
	if phase == "PointOver" then
		b.target = nil
		if b.rng:next() < 0.05 then
			jump(b)
		end
		return
	end
	if phase ~= "Live" then
		b.target = nil
		return
	end
	local d = services.MatchService.disc()
	if not d then
		return
	end
	if e.disc == "Flight" and (d.mode == "Flight") then
		local isOffense = b.team == d.throwerTeam
		if d.pull then
			isOffense = b.team == e.offense
			if not isOffense then
				-- the pulling team sprints down to cover
				local pullDir = -FieldGeometry.attackDirection(e.attack[e.offense])
				local spot = b.root.Position + pullDir * 30
				b.target = Vector3.new(spot.X, b.root.Position.Y, spot.Z)
				b.speed = SPRINT
				return
			end
		end
		if isBestChaser(b, d) and chaseFlight(b, d) then
			return
		end
		-- not chasing: keep structure
		if b.team == e.offense or isOffense then
			thinkOffense(b, e)
		else
			thinkDefense(b, e)
		end
		return
	end
	if e.disc == "Ground" then
		local spot = d.folder:GetAttribute("GroundPos") :: Vector3?
		if spot and b.team == e.offense then
			-- nearest offensive actor goes for it
			local myD = flat(spot - b.root.Position).Magnitude
			for _, a in services.PlayerService.onTeam(b.team) do
				if a.id ~= b.id then
					local r = services.PlayerService.root(a)
					if r and flat(spot - r.Position).Magnitude < myD then
						b.target = nil
						return
					end
				end
			end
			b.target = Vector3.new(spot.X, b.root.Position.Y, spot.Z)
			b.speed = SPRINT
		elseif spot then
			b.target = Vector3.new(spot.X, b.root.Position.Y, spot.Z) + (b.root.Position - spot).Unit * 10
			b.speed = JOG
		end
		return
	end
	if e.disc == "Held" then
		if e.holder == b.id then
			thinkHolder(b, e)
		elseif e.holderTeam == b.team then
			thinkOffense(b, e)
		else
			thinkDefense(b, e)
		end
	end
end

function BotService.schedulePull(id: number)
	local b = brains[id]
	if not b then
		return
	end
	task.delay(b.rng:range(1.0, 2.2), function()
		if brains[id] and services.MatchService.phase() == "Pull" then
			services.MatchService.pullNow(id)
		end
	end)
end

local function update(dt: number)
	local t = now()
	for _, b in brains do
		if b.model.Parent == nil then
			continue
		end
		if b.custom then
			b.custom(b, dt)
		elseif t >= b.nextThink then
			b.nextThink = t + 0.1
			local ok, err = pcall(function()
				thinkMatch(b)
			end)
			if not ok then
				warn("[BotService] " .. tostring(err))
			end
		end
		local holding = b.model:GetAttribute("HasDisc") == true
		if frozen(b) or holding or t < b.diveLockUntil - 0.7 then
			b.humanoid:Move(Vector3.zero)
		else
			moveToward(b, b.target, b.speed)
		end
		if b.loco then
			local v = b.root.AssemblyLinearVelocity
			local state = b.humanoid:GetState()
			local m: Locomotion.Mode = "Ground"
			if b.mode == "Dive" or b.mode == "DiveSlide" or b.mode == "Recover" then
				m = "Pose"
			elseif state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping then
				m = if v.Y > 2 then "Rising" else "Falling"
			end
			Locomotion.update(b.loco :: Locomotion.Controller, dt, flat(v).Magnitude, m)
		end
	end
end

-- Helpers for scripted (training) bots.
BotService.moveToward = moveToward
BotService.face = face
BotService.reachFor = reachFor
BotService.chaseFlight = chaseFlight

function BotService.Init(s: any)
	services = s
	local f = workspace:FindFirstChild(Actors.BotFolderName)
	if not f then
		local nf = Instance.new("Folder")
		nf.Name = Actors.BotFolderName
		nf.Parent = workspace
		f = nf
	end
	folder = f :: Folder
end

function BotService.Start()
	RunService.Heartbeat:Connect(update)
end

return BotService
