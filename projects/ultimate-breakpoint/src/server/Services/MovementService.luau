--!strict
--[[
	MovementService (server) — authority over how actors are allowed to move.

	Movement is simulated on each client for responsiveness (the client owns
	its character's physics). The server never trusts that blindly:

	  * Kinematics: every actor's position/velocity is sampled; a ground
	    raycast gives an authoritative grounded flag, the last grounded point
	    (needed for "did they jump from in bounds?") and touchdown events.
	  * Techniques: clients report technique events; the server checks names,
	    rate, cooldowns (mirrored from Config/Movement) and an exertion budget,
	    then replicates accepted ones as character attributes so every client
	    can pose that character. Rejected events earn nothing (no combo, no
	    highlight) and are counted.
	  * Speed: displacement over 0.2 s windows must stay under the hard cap
	    plus latency slack; repeated violations snap the actor back.
	  * Travel: a disc holder must stay within the pivot radius once their
	    pivot is set; leaving it snaps them back to the pivot ("Travel").
	  * Fake Commit replicates as a generic "Lean" so opponents see a real
	    sell, not a label that says "this is a fake".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MovementConfig = require(Shared.Config.Movement)
local ComboEvaluator = require(Shared.Rules.ComboEvaluator)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)
local Actors = require(Shared.Actors)

local MovementService = {}

MovementService.Landed = Signal.new() -- (actorId, position)
MovementService.TechAccepted = Signal.new() -- (actorId, tech, quality, info)
MovementService.Travel = Signal.new() -- (actorId)

local services: any

export type Track = {
	id: number,
	pos: Vector3,
	vel: Vector3,
	grounded: boolean,
	heightAboveGround: number,
	lastGroundedPos: Vector3,
	airborneSince: number?,
	lastSamplePos: Vector3,
	lastSampleAt: number,
	lastGoodPos: Vector3,
	strikes: number,
	strikeAt: number,
	graceUntil: number,
	ready: { [string]: number },
	exertion: number,
	techTimes: { number },
	rejected: number,
	combo: ComboEvaluator.Tracker,
	mode: string,
	lastTech: string?,
	lastTechAt: number,
	lastDiveAt: number,
	-- holding
	holding: boolean,
	holdStart: number,
	pivot: Vector3?,
	pendingLanding: boolean,
	wasGrounded: boolean,
}

local tracks: { [number]: Track } = {}

local KNOWN_TECHS = MovementConfig.TechCosts
local VALID_MODES = {
	Ground = true,
	Air = true,
	Slide = true,
	Dive = true,
	DiveSlide = true,
	Recover = true,
	Landing = true,
	Frozen = true,
}
local MAX_TECHS_PER_SECOND = 12
local SAMPLE = 0.2
local GROUND_PROBE = 4.2 -- root centre to ground when standing is ~3

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function now(): number
	return Net.now()
end

local function newTrack(id: number, pos: Vector3): Track
	return {
		id = id,
		pos = pos,
		vel = Vector3.zero,
		grounded = true,
		heightAboveGround = 0,
		lastGroundedPos = pos,
		airborneSince = nil,
		lastSamplePos = pos,
		lastSampleAt = os.clock(),
		lastGoodPos = pos,
		strikes = 0,
		strikeAt = 0,
		graceUntil = os.clock() + 1,
		ready = {},
		exertion = MovementConfig.ExertionMax,
		techTimes = {},
		rejected = 0,
		combo = ComboEvaluator.newTracker(),
		mode = "Ground",
		lastTech = nil,
		lastTechAt = -math.huge,
		lastDiveAt = -math.huge,
		holding = false,
		holdStart = 0,
		pivot = nil,
		pendingLanding = false,
		wasGrounded = true,
	}
end

function MovementService.track(id: number): Track?
	return tracks[id]
end

function MovementService.noteTeleport(id: number)
	local t = tracks[id]
	if t then
		t.graceUntil = os.clock() + 0.8
	end
end

local function exclusionList(): { Instance }
	local list: { Instance } = {}
	for _, c in Actors.characters() do
		table.insert(list, c)
	end
	return list
end

-- Updates kinematics for every actor (runs every Heartbeat; cheap).
local function updateKinematics()
	local exclude = exclusionList()
	rayParams.FilterDescendantsInstances = exclude
	local clock = os.clock()
	for _, actor in services.PlayerService.all() do
		local root = services.PlayerService.root(actor)
		if root then
			local t = tracks[actor.id]
			local pos = root.Position
			if not t then
				t = newTrack(actor.id, pos)
				tracks[actor.id] = t
			end
			local track = t :: Track
			track.pos = pos
			track.vel = root.AssemblyLinearVelocity
			local hit = workspace:Raycast(pos, Vector3.new(0, -GROUND_PROBE - 2, 0), rayParams)
			local h = if hit then pos.Y - hit.Position.Y else math.huge
			track.heightAboveGround = h
			local grounded = h <= GROUND_PROBE and track.vel.Y < 8
			track.grounded = grounded
			if grounded then
				track.lastGroundedPos = Vector3.new(pos.X, if hit then hit.Position.Y else pos.Y - 3, pos.Z)
				track.airborneSince = nil
			elseif track.airborneSince == nil then
				track.airborneSince = clock
			end
			if grounded and not track.wasGrounded then
				if track.pendingLanding then
					track.pendingLanding = false
					MovementService.Landed:Fire(actor.id, track.lastGroundedPos)
				end
			end
			track.wasGrounded = grounded

			-- speed validation on sample windows (humans only; bots are server-driven)
			if not actor.isBot and clock - track.lastSampleAt >= SAMPLE then
				local dt = clock - track.lastSampleAt
				local disp = Vector3.new(pos.X - track.lastSamplePos.X, 0, pos.Z - track.lastSamplePos.Z).Magnitude
				local speed = disp / dt
				local allowed = MovementConfig.HardCap * 1.25 + 6
				if clock < track.graceUntil then
					track.lastGoodPos = pos
				elseif speed > allowed then
					track.strikes += 1
					track.strikeAt = clock
					if track.strikes >= 3 then
						warn(string.format("[MovementService] %s moved %.1f studs/s; resetting", actor.name, speed))
						track.strikes = 0
						services.PlayerService.teleport(actor, CFrame.new(track.lastGoodPos + Vector3.new(0, 0.5, 0)))
					end
				else
					if clock - track.strikeAt > 4 then
						track.strikes = 0
					end
					track.lastGoodPos = pos
				end
				-- long hover with no ground below and no vertical motion
				if
					track.airborneSince
					and clock - (track.airborneSince :: number) > 4
					and math.abs(track.vel.Y) < 1
					and clock >= track.graceUntil
				then
					track.airborneSince = clock
					services.PlayerService.teleport(actor, CFrame.new(track.lastGroundedPos + Vector3.new(0, 3, 0)))
				end
				track.lastSamplePos = pos
				track.lastSampleAt = clock
			end

			-- travel enforcement
			if track.holding then
				if track.pivot == nil and grounded and now() - track.holdStart >= MovementConfig.Holding.DecelMaxTime + 0.15 then
					track.pivot = Vector3.new(pos.X, pos.Y, pos.Z)
				end
				local pivot = track.pivot
				if pivot and grounded and not actor.isBot then
					local d = Vector3.new(pos.X - pivot.X, 0, pos.Z - pivot.Z).Magnitude
					if d > MovementConfig.Holding.PivotRadius + 2.5 and clock >= track.graceUntil then
						services.PlayerService.teleport(actor, CFrame.new(pivot) * root.CFrame.Rotation)
						MovementService.Travel:Fire(actor.id)
					end
				end
			end
		end
	end
end

-- Exertion mirror: regenerates while the actor is not sprinting.
local function regen(dt: number)
	for _, t in tracks do
		local flat = Vector3.new(t.vel.X, 0, t.vel.Z).Magnitude
		if flat > MovementConfig.JogSpeed + 1 then
			t.exertion = math.max(-40, t.exertion - MovementConfig.SprintDrain * dt)
		else
			t.exertion = math.min(MovementConfig.ExertionMax, t.exertion + MovementConfig.ExertionRegen * dt)
		end
	end
end

local function replicate(actorId: number, tech: string, quality: string, dir: Vector3, info: string?)
	local actor = services.PlayerService.get(actorId)
	local c = actor and actor.character
	if not c then
		return
	end
	local public = tech
	if tech == "FakeCommit" then
		public = "Lean"
	end
	c:SetAttribute("TechDir", dir)
	c:SetAttribute("TechQ", quality)
	c:SetAttribute("TechInfo", info or "")
	c:SetAttribute("Tech", public)
	c:SetAttribute("TechT", now())
end

-- Validates one reported technique. Returns true if accepted.
local function accept(t: Track, tech: string, quality: string): boolean
	local clock = os.clock()
	if KNOWN_TECHS[tech] == nil then
		return false
	end
	-- rate limit
	while #t.techTimes > 0 and clock - t.techTimes[1] > 1 do
		table.remove(t.techTimes, 1)
	end
	if #t.techTimes >= MAX_TECHS_PER_SECOND then
		return false
	end
	-- cooldown mirror (with latency slack)
	local cd = (MovementConfig.TechCooldowns :: any)[tech] or 0
	if cd > 0 and (t.ready[tech] or -math.huge) > clock + 0.12 then
		return false
	end
	local cost = (MovementConfig.TechCosts :: any)[tech] or 0
	if t.exertion < -30 and cost > 0 and quality ~= "Gassed" then
		-- client claims a full-strength technique it cannot have afforded
		return false
	end
	table.insert(t.techTimes, clock)
	t.ready[tech] = clock + cd
	t.exertion -= cost
	return true
end

local VALID_QUALITY = { Perfect = true, Clean = true, Sloppy = true, Gassed = true }

local function onTech(player: Player, events: any, mode: any)
	local actor = services.PlayerService.fromPlayer(player)
	if not actor then
		return
	end
	local t = tracks[actor.id]
	if not t then
		return
	end
	if type(mode) == "string" and VALID_MODES[mode] and mode ~= t.mode then
		t.mode = mode
		if actor.character then
			actor.character:SetAttribute("MS", mode)
		end
	end
	if type(events) ~= "table" then
		return
	end
	local n = 0
	for _, e in events do
		n += 1
		if n > 6 then
			break
		end
		if type(e) == "table" and type(e.tech) == "string" then
			local quality = if type(e.quality) == "string" and VALID_QUALITY[e.quality] then e.quality else "Clean"
			local dir = if typeof(e.dir) == "Vector3" then e.dir else Vector3.zero
			if dir.Magnitude > 1.01 or dir.Magnitude ~= dir.Magnitude then
				dir = Vector3.zero
			end
			local info = if type(e.info) == "string" and #e.info <= 24 then e.info else nil
			if accept(t, e.tech, quality) then
				t.lastTech = e.tech
				t.lastTechAt = now()
				if e.tech == "Dive" then
					t.lastDiveAt = now()
				end
				replicate(actor.id, e.tech, quality, dir, info)
				ComboEvaluator.add(t.combo, e.tech, quality, now())
				MovementService.TechAccepted:Fire(actor.id, e.tech, quality, info)
			else
				t.rejected += 1
			end
		end
	end
end

-- Server-driven technique for bots (no validation needed).
function MovementService.botTech(id: number, tech: string, dir: Vector3, mode: string?)
	local t = tracks[id]
	if t then
		t.lastTech = tech
		t.lastTechAt = now()
		if tech == "Dive" then
			t.lastDiveAt = now()
		end
		if mode then
			t.mode = mode
		end
	end
	replicate(id, tech, "Clean", dir, nil)
	local actor = services.PlayerService.get(id)
	if actor and actor.character and mode then
		actor.character:SetAttribute("MS", mode)
	end
end

function MovementService.setBotMode(id: number, mode: string)
	local t = tracks[id]
	if t then
		t.mode = mode
	end
	local actor = services.PlayerService.get(id)
	if actor and actor.character then
		actor.character:SetAttribute("MS", mode)
	end
end

-- Is the actor currently in a layout (dive) or its ground slide?
function MovementService.isDiving(id: number): boolean
	local t = tracks[id]
	if not t then
		return false
	end
	return t.mode == "Dive" or t.mode == "DiveSlide" or now() - t.lastDiveAt < 0.9
end

function MovementService.isSliding(id: number): boolean
	local t = tracks[id]
	return t ~= nil and t.mode == "Slide"
end

function MovementService.isOnGroundAfterLayout(id: number): boolean
	local t = tracks[id]
	return t ~= nil and (t.mode == "DiveSlide" or t.mode == "Recover") and now() - t.lastDiveAt < 2
end

function MovementService.setHolding(id: number, holding: boolean)
	local t = tracks[id]
	if not t then
		return
	end
	t.holding = holding
	t.holdStart = now()
	t.pivot = nil
	t.pendingLanding = holding and not t.grounded
end

function MovementService.setPivot(id: number, pos: Vector3)
	local t = tracks[id]
	if t then
		t.pivot = pos
	end
end

function MovementService.expectLanding(id: number)
	local t = tracks[id]
	if t then
		t.pendingLanding = true
	end
end

function MovementService.convertCombo(id: number, payoff: string): ComboEvaluator.Summary?
	local t = tracks[id]
	if not t then
		return nil
	end
	return ComboEvaluator.convert(t.combo, now(), payoff)
end

function MovementService.Init(s: any)
	services = s
end

function MovementService.Start()
	Net.event("Tech").OnServerEvent:Connect(onTech)
	RunService.Heartbeat:Connect(function(dt)
		updateKinematics()
		regen(dt)
	end)
	services.PlayerService.ActorRemoving:Connect(function(actor)
		tracks[actor.id] = nil
	end)
	services.PlayerService.CharacterSpawned:Connect(function(actor, model)
		local root = model:WaitForChild("HumanoidRootPart", 5) :: BasePart?
		if root then
			tracks[actor.id] = newTrack(actor.id, root.Position)
		end
	end)
	local _ = Players
end

return MovementService
