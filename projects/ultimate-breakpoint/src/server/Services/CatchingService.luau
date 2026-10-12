--!strict
--[[
	CatchingService — every catch, block and bobble is decided here.

	Humans: the client sees its own body at its true position and the disc at
	the shared server time, so it detects contact and sends a claim stamped
	with that server time. The server rewinds the DISC (cheap: deterministic
	history) to the claimed time and tests it against the claimer's catch
	zones built from the server's view of their character (which lags by
	about the same one-way latency the claim did). Slack grows with ping and
	is capped. Claims are collected for ResolveDelay so near-simultaneous
	touches become a fair contest instead of first-packet-wins.

	Bots: checked directly on the server every simulation step.

	Outcomes:
	  Catch          clean (or uncontested fingertip on a normal-speed disc)
	  Block          a defender's fingertip contact knocks the disc down
	  Bobble         contested / very fast fingertip contact pops the disc up
	The disc stays live after blocks and bobbles; anyone may still catch it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local CatchGeometry = require(Shared.Rules.CatchGeometry)
local VecMath = require(Shared.Util.VecMath)
local Net = require(Shared.Net)

local C = DiscConfig.Catch

local CatchingService = {}

local services: any

type ReachState = { at: number, dir: Vector3 }
local reaches: { [number]: ReachState } = {}
local lastClaim: { [number]: number } = {}

local function now(): number
	return Net.now()
end

local function facingOf(root: BasePart): Vector3
	return VecMath.flatUnit(root.CFrame.LookVector)
end

local function bodyFor(actorId: number, root: BasePart, kind: string?, reachDir: Vector3?, t: number): CatchGeometry.BodyState
	local reach = reaches[actorId]
	local reaching = false
	local dir: Vector3? = nil
	if reach and t >= reach.at - 0.12 and t <= reach.at + C.ReachWindow + 0.12 then
		reaching = true
		dir = if reachDir and reachDir.Magnitude > 0.5 then reachDir.Unit else reach.dir
	end
	local diving = services.MovementService.isDiving(actorId)
	local diveDir: Vector3? = nil
	if diving then
		local actor = services.PlayerService.get(actorId)
		local c = actor and actor.character
		local td = c and c:GetAttribute("TechDir")
		diveDir = if typeof(td) == "Vector3" and (td :: Vector3).Magnitude > 0.5 then td :: Vector3 else facingOf(root)
	end
	local _ = kind
	return {
		root = root.Position,
		facing = facingOf(root),
		reaching = reaching,
		reachDir = dir,
		diving = diving,
		diveDir = diveDir,
		sliding = services.MovementService.isSliding(actorId),
	}
end

local function slackFor(actorId: number): number
	local player = services.Actors.playerOf(actorId)
	local ping = 0
	if player then
		local ok, value = pcall(function()
			return player:GetNetworkPing()
		end)
		if ok and type(value) == "number" then
			ping = value
		end
	end
	return math.min(C.BaseSlack + ping * C.PingSlackPerSecond, C.MaxSlack)
end

local function claimable(d: any, t: number): boolean
	if d.mode == "Flight" then
		return true
	end
	return d.mode == "Landed" and t <= d.landAt + 0.02
end

local function addClaim(d: any, actorId: number, team: string, t: number, ev: CatchGeometry.Evaluation, actorVel: Vector3)
	local rel = (services.DiscService.velocity(d) - actorVel).Magnitude
	for _, c in d.claims do
		if c.id == actorId then
			if t < c.t then
				c.t, c.depth, c.quality, c.zone, c.relativeSpeed = t, ev.depth, ev.quality, ev.zone.kind, rel
			end
			return
		end
	end
	table.insert(d.claims, {
		id = actorId,
		team = team,
		t = t,
		depth = ev.depth,
		quality = ev.quality,
		relativeSpeed = rel,
		zone = ev.zone.kind,
		hand = ev.hand,
	})
	if d.resolveAt == nil then
		d.resolveAt = now() + C.ResolveDelay
	end
end

-- Validates a claim. Returns true if it was queued.
function CatchingService.claim(actorId: number, d: any, t: number, kind: string?, reachDir: Vector3?): boolean
	local actor = services.PlayerService.get(actorId)
	if not actor or actor.role == "Spectate" then
		return false
	end
	local root = services.PlayerService.root(actor)
	if not root then
		return false
	end
	local tNow = now()
	if t ~= t or t < tNow - C.MaxRewind or t > tNow + 0.05 then
		t = math.clamp(if t == t then t else tNow, tNow - C.MaxRewind, tNow)
	end
	if not claimable(d, t) or t < d.noCatchUntil then
		return false
	end
	if d.thrower == actorId and not d.touched then
		return false
	end
	if actor.character and actor.character:GetAttribute("UBFrozen") == true then
		return false
	end
	if not d.handler.canClaim(d, actorId, actor.team) then
		return false
	end
	local discPos = services.DiscService.positionAt(d, t)
	if not discPos then
		return false
	end
	local zones = CatchGeometry.zones(bodyFor(actorId, root, kind, reachDir, t))
	local slack = if actor.isBot then 0 else slackFor(actorId)
	local ev = CatchGeometry.evaluate(zones, discPos, slack)
	if not ev then
		return false
	end
	addClaim(d, actorId, actor.team, t, ev, root.AssemblyLinearVelocity)
	return true
end

-- Server-side check for bots along one simulation step of a flight.
function CatchingService.sweepBots(d: any, _from: Vector3, to: Vector3, t: number)
	if t < d.noCatchUntil then
		return
	end
	for _, actor in services.PlayerService.all() do
		if actor.isBot and actor.role == "Match" or (actor.isBot and actor.role == "Training") then
			local root = services.PlayerService.root(actor)
			if root and (root.Position - to).Magnitude < 9 then
				if not (d.thrower == actor.id and not d.touched) and d.handler.canClaim(d, actor.id, actor.team) then
					local zones = CatchGeometry.zones(bodyFor(actor.id, root, nil, nil, t))
					local ev = CatchGeometry.evaluate(zones, to, 0)
					if ev then
						addClaim(d, actor.id, actor.team, t, ev, root.AssemblyLinearVelocity)
					end
				end
			end
		end
	end
end

local function notifyClaimers(d: any, winnerId: number?, result: string)
	for _, c in d.claims do
		local player = services.Actors.playerOf(c.id)
		if player then
			Net.event("CatchResult"):FireClient(player, d.id, c.id == winnerId and result == "Catch", result, d.flightId)
		end
	end
end

function CatchingService.resolve(d: any)
	if #d.claims == 0 then
		return
	end
	if d.mode ~= "Flight" and d.mode ~= "Landed" then
		d.claims = {}
		return
	end
	local resolution = CatchGeometry.resolve(d.claims)
	if not resolution then
		d.claims = {}
		return
	end
	local w = resolution.winner :: any
	local winnerActor = services.PlayerService.get(w.id)
	local root = winnerActor and services.PlayerService.root(winnerActor)
	if not winnerActor or not root then
		d.claims = {}
		return
	end
	local discPos = services.DiscService.positionAt(d, w.t) or root.Position
	local discVel = services.DiscService.velocity(d)
	local isDefender = d.throwerTeam ~= nil and w.team ~= d.throwerTeam and not d.pull
	local outcome: string
	if isDefender and w.quality == "Fingertip" then
		outcome = "Block"
	elseif resolution.bobble then
		outcome = "Bobble"
	else
		outcome = "Catch"
	end

	notifyClaimers(d, w.id, outcome)
	local claims = d.claims
	d.claims = {}

	if outcome == "Catch" then
		local track = services.MovementService.track(w.id)
		local grounded = if track then track.grounded else true
		local jumpOrigin = if track then track.lastGroundedPos else root.Position
		services.DiscService.giveTo(d, w.id)
		Net.event("Effect"):FireAllClients("Catch", discPos, w.id, w.quality, w.zone)
		d.handler.onCaught(d, {
			id = w.id,
			team = w.team,
			pos = root.Position,
			grounded = grounded,
			jumpOrigin = jumpOrigin,
			quality = w.quality,
			zone = w.zone,
			relativeSpeed = w.relativeSpeed,
			contested = resolution.contested,
			t = w.t,
			discPos = discPos,
			claims = claims,
		})
		return
	end

	-- deflections keep the disc alive
	local away = VecMath.flatUnit(discPos - root.Position)
	local newVel: Vector3
	if outcome == "Block" then
		newVel = discVel * C.BlockCarry + Vector3.new(0, C.BlockDown, 0) + away * 6
	else
		newVel = discVel * C.BobbleCarry + Vector3.new(0, C.BobbleUp, 0) + away * 2
	end
	local pos = Vector3.new(discPos.X, math.max(discPos.Y, d.groundY + 0.6), discPos.Z)
	services.DiscService.deflect(d, pos, newVel, Vector3.new(0.3, 1, 0.2).Unit, 12)
	Net.event("Effect"):FireAllClients(outcome, discPos, w.id, w.quality, w.zone)
	d.handler.onTouched(d, { id = w.id, team = w.team, kind = outcome, pos = discPos, zone = w.zone, reason = resolution.reason })
end

function CatchingService.reachState(actorId: number): ReachState?
	return reaches[actorId]
end

-- Opens a reach window (humans via remote, bots directly).
function CatchingService.reach(actorId: number, dir: Vector3)
	local tNow = now()
	local prev = reaches[actorId]
	if prev and tNow - prev.at < C.ReachWindow + C.ReachCooldown * 0.6 then
		return
	end
	local unit = if dir.Magnitude > 0.1 and dir.Magnitude == dir.Magnitude then dir.Unit else Vector3.new(0, 0, -1)
	reaches[actorId] = { at = tNow, dir = unit }
	local actor = services.PlayerService.get(actorId)
	if actor and actor.character then
		actor.character:SetAttribute("ReachDir", unit)
		actor.character:SetAttribute("Reach", tNow)
	end
end

function CatchingService.Init(s: any)
	services = s
end

function CatchingService.Start()
	Net.event("Reach").OnServerEvent:Connect(function(player, dir)
		local actor = services.PlayerService.fromPlayer(player)
		if actor and typeof(dir) == "Vector3" then
			CatchingService.reach(actor.id, dir)
		end
	end)
	Net.event("Catch").OnServerEvent:Connect(function(player, discId, t, kind, reachDir)
		local actor = services.PlayerService.fromPlayer(player)
		if not actor or type(discId) ~= "string" or type(t) ~= "number" then
			return
		end
		local clock = os.clock()
		if (lastClaim[actor.id] or 0) > clock - 0.05 then
			return
		end
		lastClaim[actor.id] = clock
		local d = services.DiscService.get(discId)
		if not d then
			return
		end
		local rd = if typeof(reachDir) == "Vector3" then reachDir else nil
		local ok = CatchingService.claim(actor.id, d, t, if type(kind) == "string" then kind else nil, rd)
		if not ok then
			Net.event("CatchResult"):FireClient(player, d.id, false, "Denied", d.flightId)
		end
	end)
	services.PlayerService.ActorRemoving:Connect(function(actor)
		reaches[actor.id] = nil
		lastClaim[actor.id] = nil
	end)
end

return CatchingService
