--!strict
--[[
	ThrowService — validates throws and launches discs.

	The client sends only its INPUTS (type, aim, hold time, bank, release
	height). The server recomputes the launch from its own view of the
	thrower's position and velocity with the same ThrowModel, so a modified
	client cannot fire a disc from somewhere else or faster than allowed.

	Hold time: the server measures the charge itself (ThrowCharge -> Throw)
	and only accepts the client's figure when the two agree within 0.2 s.
	Windups and fakes are replicated as character attributes so defenders see
	the same motion for a real throw and for a fake.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local ThrowModel = require(Shared.Disc.ThrowModel)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local Net = require(Shared.Net)

local T = DiscConfig.Throw
local C = DiscConfig.Catch

local ThrowService = {}

local services: any
local chargeStart: { [number]: number } = {}
local lastFake: { [number]: number } = {}
local lastThrow: { [number]: number } = {}

local function now(): number
	return Net.now()
end

local function setAttr(actorId: number, key: string, value: any)
	local actor = services.PlayerService.get(actorId)
	if actor and actor.character then
		actor.character:SetAttribute(key, value)
	end
end

function ThrowService.beginCharge(actorId: number, throwType: string)
	if not services.DiscService.heldBy(actorId) then
		return
	end
	chargeStart[actorId] = os.clock()
	setAttr(actorId, "WindupType", throwType)
	setAttr(actorId, "Windup", now())
end

function ThrowService.fake(actorId: number, throwType: string)
	local clock = os.clock()
	if (lastFake[actorId] or 0) > clock - T.FakeCooldown then
		return
	end
	if not services.DiscService.heldBy(actorId) then
		return
	end
	lastFake[actorId] = clock
	chargeStart[actorId] = nil
	setAttr(actorId, "WindupType", throwType)
	setAttr(actorId, "Fake", now())
end

export type Result = {
	launch: ThrowModel.Launch,
	blocked: number?,
}

-- Core throw path shared by humans, bots and pulls.
function ThrowService.throw(actorId: number, raw: any, isBot: boolean?): Result?
	local params = ThrowModel.sanitize(raw)
	if not params then
		return nil
	end
	local p = params :: ThrowModel.Params
	local clock = os.clock()
	if (lastThrow[actorId] or 0) > clock - 0.25 then
		return nil
	end
	local d = services.DiscService.heldBy(actorId)
	if not d then
		return nil
	end
	if not d.handler.canThrow(d, actorId) then
		return nil
	end
	local actor = services.PlayerService.get(actorId)
	local root = actor and services.PlayerService.root(actor)
	if not actor or not root then
		return nil
	end

	-- hold time: trust the server's measurement unless the two agree
	if not isBot then
		local started = chargeStart[actorId]
		local measured = if started then clock - started else 0
		if math.abs(measured - p.holdTime) > 0.2 then
			p.holdTime = measured
		end
	end
	chargeStart[actorId] = nil

	-- balance and release height must match what the server can see
	local track = services.MovementService.track(actorId)
	local grounded = if track then track.grounded else true
	if grounded and p.height == "High" then
		p.height = "Mid"
	end
	p.offBalance = not grounded and p.height ~= "High"
	p.groundThrow = services.MovementService.isOnGroundAfterLayout(actorId)
	if p.groundThrow then
		p.height = "Mid"
	end
	p.leftHanded = actor.character ~= nil and actor.character:GetAttribute("LeftHanded") == true

	local vel = root.AssemblyLinearVelocity
	local launch = ThrowModel.launch(p, root.Position, vel)
	lastThrow[actorId] = clock

	-- hand blocks (match play only)
	local blocker: number? = nil
	local blockT: number? = nil
	local blockPos: Vector3? = nil
	if d.context == "Match" and not d.pull then
		blocker, blockT, blockPos = services.DefenseService.checkHandBlock(
			launch.state,
			actorId,
			actor.team,
			d.groundY,
			d.wind
		)
	end

	local pull = d.meta.pullPending == true
	services.DiscService.launch(d, launch.releasePos, launch.velocity, launch.normal, launch.state.spin, {
		thrower = actorId,
		throwerTeam = actor.team,
		throwType = p.throwType,
		quality = launch.quality,
		pull = pull,
		noCatch = if blockT then (blockT :: number) + 0.02 else T.NoCatchTime,
	})
	setAttr(actorId, "ReleaseType", p.throwType)
	setAttr(actorId, "Release", now())

	d.handler.onThrown(d, {
		id = actorId,
		team = actor.team,
		params = p,
		launch = launch,
		pos = root.Position,
		blocked = blocker,
	})

	if actor.player then
		Net.event("Feedback"):FireClient(actor.player, "Release", {
			quality = launch.quality,
			power = launch.power,
			spin = launch.spinFactor,
			speed = launch.speed,
			pitch = launch.pitchDeg,
			bank = launch.bankDeg,
			throwType = p.throwType,
			offBalance = p.offBalance,
			groundThrow = p.groundThrow,
			blocked = blocker ~= nil,
		})
	end

	if blocker and blockT and blockPos then
		local flightId = d.flightId
		local bt = blockT :: number
		local bp = blockPos :: Vector3
		local blockerId = blocker :: number
		task.delay(bt, function()
			if d.mode ~= "Flight" or d.flightId ~= flightId then
				return
			end
			local discVel = services.DiscService.velocity(d)
			local away = Vector3.new(bp.X - root.Position.X, 0, bp.Z - root.Position.Z)
			local push = if away.Magnitude > 0.1 then away.Unit * 3 else Vector3.zero
			local newVel = discVel * C.BlockCarry + Vector3.new(0, C.BlockDown, 0) + push
			services.DiscService.deflect(d, bp, newVel)
			Net.event("Effect"):FireAllClients("HandBlock", bp, blockerId, "Clean", "Mark")
			local blockerActor = services.PlayerService.get(blockerId)
			d.handler.onTouched(d, {
				id = blockerId,
				team = if blockerActor then blockerActor.team else "",
				kind = "HandBlock",
				pos = bp,
				zone = "Mark",
			})
		end)
	end
	local _ = DiscPhysics
	return { launch = launch, blocked = blocker }
end

-- Launches a disc without a thrower (training launchers, scripted drills).
function ThrowService.launchFrom(d: any, params: ThrowModel.Params, origin: Vector3, meta: { [string]: any }?)
	local launch = ThrowModel.launch(params, origin, Vector3.zero)
	local m: { [string]: any } = meta or {}
	services.DiscService.launch(d, launch.releasePos, launch.velocity, launch.normal, launch.state.spin, {
		thrower = m.thrower,
		throwerTeam = m.throwerTeam,
		throwType = params.throwType,
		quality = launch.quality,
		noCatch = m.noCatch or 0.05,
	})
	return launch
end

function ThrowService.Init(s: any)
	services = s
end

function ThrowService.Start()
	Net.event("ThrowCharge").OnServerEvent:Connect(function(player, throwType)
		local actor = services.PlayerService.fromPlayer(player)
		if actor and type(throwType) == "string" and (DiscConfig.Types :: any)[throwType] then
			ThrowService.beginCharge(actor.id, throwType)
		end
	end)
	Net.event("Fake").OnServerEvent:Connect(function(player, throwType)
		local actor = services.PlayerService.fromPlayer(player)
		if actor and type(throwType) == "string" and (DiscConfig.Types :: any)[throwType] then
			ThrowService.fake(actor.id, throwType)
		end
	end)
	Net.event("Throw").OnServerEvent:Connect(function(player, raw)
		local actor = services.PlayerService.fromPlayer(player)
		if actor then
			ThrowService.throw(actor.id, raw, false)
		end
	end)
	services.PlayerService.ActorRemoving:Connect(function(actor)
		chargeStart[actor.id] = nil
		lastFake[actor.id] = nil
		lastThrow[actor.id] = nil
	end)
end

return ThrowService
