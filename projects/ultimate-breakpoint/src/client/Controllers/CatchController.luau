--!strict
--[[
	CatchController — catching, reaching and marking for the local player.

	Catching. Contact is detected here, where your body is exactly where you
	see it and the disc is at the shared server time. Every frame the disc's
	path since the last frame (keyed by FlightId, so a new segment never
	sweeps from the old one's last point) is swept against your catch zones
	(CatchGeometry, the module the server validates with). On first contact
	the controller keeps tracking for up to ClaimTrackTime, or until the disc
	starts moving away from your zone core (its closest approach), then
	claims: Catch(discId, tFirst, zoneKind, reachDir, rootPos, rootVel) with
	your body as it was at first contact. On the claim (except a defender's
	rim touch deeper than BlockDepth, which the server rules a Block and is
	not predicted):
	  * Claimed(discId, zoneKind) fires (MovementController starts the catch
	    slow-down) and the disc eases into your hand (DiscRenderer)
	  * the catch sound and a small burst play at once for a confident claim
	    (depth < LOCAL_FX_DEPTH), once per flight segment; recentLocalCatch()
	    lets the effects skip the server's copy of your own catch
	The server always answers (CatchResult). Denied, or the disc going to
	someone else, fires Denied(discId): MovementController cancels the
	slow-down, the disc eases back onto its flight, and the throttle is
	cleared so a disc still inside your zones is claimed again at once. A
	claim with no answer yet is never repeated sooner than ClaimThrottle.

	Reach (Primary while not holding, and not while a claimed catch awaits
	the server's answer): opens a 0.28 s window where your hand
	extends toward your aim. A light assist bends the reach toward a disc that
	is close and roughly where you are looking. Primary next to a disc lying
	on the ground asks the server to pick it up instead (Action "Pickup").

	Marking: hold Secondary within Marking.Range of an opposing holder (their
	pivot) for the mark shuffle (MovementController.setMarking) with your
	hands up, replicated as MarkStance(on, stance). The Slide key toggles High
	/ Low while marking. A Cut / Dive / Burst ends the mark inside the sim;
	press Secondary again to re-mark. Moving well out of range drops the
	mark until you come back in.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local MovementConfig = require(Shared.Config.Movement)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local CatchGeometry = require(Shared.Rules.CatchGeometry)
local Actors = require(Shared.Actors)
local VecMath = require(Shared.Util.VecMath)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local C = DiscConfig.Catch
local MK = MovementConfig.Marking

local CatchController = {}

CatchController.Reached = Signal.new() -- (dir)
CatchController.Claimed = Signal.new() -- (discId, zoneKind)
CatchController.Denied = Signal.new() -- (discId)

local LOCAL_FX_DEPTH = 0.85 -- claims this deep play the catch feedback at once
local LOCAL_FX_RECENT = 1.2 -- recentLocalCatch(): feedback played this recently
local RECEDE = 0.01 -- depth growth per frame that means the disc is moving away
local SUB_STEP = 0.6 -- studs between swept sub-samples
local MAX_SUB = 8
local ANSWER_TIMEOUT = 0.6 -- (+ 2 x ping) a claim with no answer may be repeated
local MARK_DROP = 2 -- the mark ends this far beyond Marking.Range
local PICKUP_REACH = 1.5 -- Primary picks up a grounded disc within PickupRadius + this

local controllers: any
local player = Players.LocalPlayer

local reachAt = -math.huge
local reachDir = Vector3.new(0, 0, -1)

-- marking
local markHeld = false -- Secondary is held (and armed: a technique disarms it)
local marking = false
local markStance = "Low"

type Contact = {
	flightId: number,
	lastPos: Vector3, -- disc position last frame
	lastT: number,
	tFirst: number?, -- first contact of the current episode
	kind: string,
	bestDepth: number,
	lastDepth: number,
	body: Vector3, -- your root at first contact
	bodyVel: Vector3,
	retry: boolean, -- after a Denied: claim at the next contact without tracking
	awaiting: boolean, -- a claim is out, no answer yet
	sentAt: number, -- os.clock() of the last claim
	fxDone: boolean, -- local catch feedback already played for this segment
	settled: boolean, -- the server decided this segment (caught / lost): no more claims
}
local contacts: { [string]: Contact } = {}
local lastLocalFx = -math.huge -- os.clock() of the last local catch feedback

local function now(): number
	return Net.now()
end

local function myPing(): number
	local ok, value = pcall(function()
		return player:GetNetworkPing()
	end)
	if ok and type(value) == "number" and value == value then
		return math.clamp(value, 0, 0.35)
	end
	return 0.1
end

function CatchController.reachActive(): boolean
	return now() - reachAt <= C.ReachWindow
end

function CatchController.isMarking(): boolean
	return marking
end

function CatchController.markStance(): string
	return markStance
end

function CatchController.reachState(): (number, Vector3)
	return reachAt, reachDir
end

-- Did your own catch feedback (sound + burst) just play on a claim? The
-- server's "Catch" effect for you can then be skipped (no double sound).
function CatchController.recentLocalCatch(): boolean
	return os.clock() - lastLocalFx <= LOCAL_FX_RECENT
end

local function myTeam(): string?
	local c = player.Character
	return if c then c:GetAttribute("UBTeam") :: string? else nil
end

local function canClaim(folder: Configuration): boolean
	local context = folder:GetAttribute("Context")
	local c = player.Character
	if not c or c:GetAttribute("UBFrozen") == true then
		return false
	end
	local role = c:GetAttribute("UBRole")
	if role == "Bench" or role == "Spectate" then
		return false
	end
	if context == "Training" then
		return folder:GetAttribute("Owner") == player.UserId
	elseif context == "Warmup" then
		return true
	end
	local team = myTeam()
	if team ~= "A" and team ~= "B" then
		return false
	end
	if folder:GetAttribute("Pull") == true then
		return Net.state():GetAttribute("Offense") == team
	end
	return Net.state():GetAttribute("Phase") == "Live"
end

local function nearestFlyingDisc(maxDist: number): (Vector3?, string?)
	local root = controllers.MovementController.root()
	if not root then
		return nil, nil
	end
	local best, bestId, bestD = nil, nil, maxDist
	for _, f in controllers.DiscRenderer.folders() do
		if f:GetAttribute("Mode") == "Flight" then
			local id = f:GetAttribute("Id") :: string
			local p = controllers.DiscRenderer.positionOf(id)
			if p then
				local d = (p - root.Position).Magnitude
				if d < bestD then
					best, bestId, bestD = p, id, d
				end
			end
		end
	end
	return best, bestId
end

-- Primary next to a disc on the ground: ask for it (no teleport; the server
-- plants your pivot on it and your body glides there).
local function requestPickup(): boolean
	local root = controllers.MovementController.root()
	if not root then
		return false
	end
	for _, f in controllers.DiscRenderer.folders() do
		if f:GetAttribute("Mode") == "Ground" then
			local gp = f:GetAttribute("GroundPos")
			if typeof(gp) == "Vector3" then
				local d = VecMath.flat(gp - root.Position).Magnitude
				if d <= C.PickupRadius + PICKUP_REACH and math.abs(gp.Y - root.Position.Y) < 8 then
					Net.event("Action"):FireServer("Pickup", nil)
					return true
				end
			end
		end
	end
	return false
end

function CatchController.reach()
	local t = now()
	if t - reachAt < C.ReachWindow + C.ReachCooldown then
		return
	end
	local root = controllers.MovementController.root()
	if not root then
		return
	end
	local aim = controllers.CameraController.getAimDirection()
	local discPos = nearestFlyingDisc(8)
	if discPos then
		local toDisc = (discPos - (root.Position + Vector3.new(0, C.ShoulderHeight, 0))).Unit
		if aim:Dot(toDisc) > math.cos(math.rad(55)) then
			aim = aim:Lerp(toDisc, 0.6).Unit
		end
	end
	reachAt = t
	reachDir = aim
	Net.event("Reach"):FireServer(aim)
	local c = player.Character
	if c then
		c:SetAttribute("UB_LocalReach", t)
		c:SetAttribute("UB_LocalReachDir", aim)
	end
	controllers.MovementController.noteAerialReach(aim)
	CatchController.Reached:Fire(aim)
end

---------------------------------------------------------------------------
-- marking
---------------------------------------------------------------------------

local function sendStance()
	Net.event("MarkStance"):FireServer(marking, markStance)
	local c = player.Character
	if c then
		c:SetAttribute("UB_LocalMark", if marking then markStance else "")
	end
end

local function setMarking(on: boolean)
	if marking == on then
		return
	end
	marking = on
	controllers.MovementController.setMarking(on)
	sendStance()
end

-- Flat distance from you to the nearest opposing holder's pivot (or root).
local function holderDistance(): number?
	local c = player.Character
	local root = controllers.MovementController.root()
	if not c or not root then
		return nil
	end
	local team = c:GetAttribute("UBTeam")
	local best: number? = nil
	for _, folder in controllers.DiscRenderer.folders() do
		local hid = folder:GetAttribute("HolderId")
		if folder:GetAttribute("Mode") == "Held" and type(hid) == "number" and hid ~= 0 and hid ~= player.UserId then
			local model = Actors.characterOf(hid)
			if model and (model:GetAttribute("UBTeam") ~= team or folder:GetAttribute("Context") ~= "Match") then
				local pv = model:GetAttribute("UBPivot")
				local hroot = model:FindFirstChild("HumanoidRootPart") :: BasePart?
				local p = if typeof(pv) == "Vector3" then pv elseif hroot then hroot.Position else nil
				if p then
					local d = VecMath.flat(p - root.Position).Magnitude
					if best == nil or d < (best :: number) then
						best = d
					end
				end
			end
		end
	end
	return best
end

local function updateMarking()
	if marking and not controllers.MovementController.isMarking() then
		-- a technique ended the mark inside the sim: press Secondary again
		markHeld = false
		setMarking(false)
		return
	end
	if not markHeld or controllers.ThrowController.isHolding() then
		setMarking(false)
		return
	end
	local d = holderDistance()
	if marking then
		if d == nil or d > MK.Range + MARK_DROP then
			setMarking(false)
		end
	elseif d ~= nil and d <= MK.Range then
		setMarking(true)
	end
end

local function toggleStance()
	markStance = if markStance == "High" then "Low" else "High"
	sendStance()
end

---------------------------------------------------------------------------
-- catching
---------------------------------------------------------------------------

local function bodyState(root: BasePart): CatchGeometry.BodyState
	local sim = controllers.MovementController.sim()
	local diving = sim.mode == "Dive" or sim.mode == "DiveSlide"
	return {
		root = root.Position,
		facing = VecMath.flatUnit(root.CFrame.LookVector),
		reaching = CatchController.reachActive(),
		reachDir = reachDir,
		diving = diving,
		diveDir = sim.diveDir,
		sliding = sim.mode == "Slide",
	}
end

-- Deepest evaluation along this frame's disc path, and the time of the
-- first sub-sample inside a zone.
local function sweep(
	zones: { CatchGeometry.Zone },
	from: Vector3,
	to: Vector3,
	tFrom: number,
	tTo: number
): (CatchGeometry.Evaluation?, number)
	local n = math.clamp(math.ceil((to - from).Magnitude / SUB_STEP), 1, MAX_SUB)
	local best: CatchGeometry.Evaluation? = nil
	local firstT = tTo
	for k = 1, n do
		local a = k / n
		local ev = CatchGeometry.evaluate(zones, from:Lerp(to, a))
		if ev then
			if best == nil then
				firstT = tFrom + (tTo - tFrom) * a
			end
			if best == nil or ev.depth < (best :: CatchGeometry.Evaluation).depth then
				best = ev
			end
		end
	end
	return best, firstT
end

local function localFeedback(c: Contact, pos: Vector3)
	if c.fxDone or c.bestDepth >= LOCAL_FX_DEPTH then
		return
	end
	c.fxDone = true
	lastLocalFx = os.clock()
	local clean = c.bestDepth <= C.CleanFraction
	controllers.AudioController.playAt(if clean then "CleanCatch" else "Catch", pos)
	local color = if clean then Color3.fromRGB(210, 240, 255) else Color3.fromRGB(255, 205, 70)
	controllers.EffectsController.burst(pos, color, 6, 8)
end

-- Would the server rule this touch a Block? (a defender who only got the
-- rim: depth > BlockDepth; CatchGeometry.outcome, never on a pull)
local function likelyBlock(folder: Configuration, c: Contact): boolean
	local throwerTeam = folder:GetAttribute("ThrowerTeam")
	local defending = type(throwerTeam) == "string"
		and throwerTeam ~= ""
		and throwerTeam ~= myTeam()
		and folder:GetAttribute("Pull") ~= true
	return defending and c.bestDepth > C.BlockDepth
end

local function sendClaim(folder: Configuration, id: string, c: Contact, discPos: Vector3)
	local tFirst = c.tFirst :: number
	c.sentAt = os.clock()
	c.awaiting = true
	c.retry = false
	Net.event("Catch"):FireServer(id, tFirst, c.kind, reachDir, c.body, c.bodyVel)
	if likelyBlock(folder, c) then
		-- a rim touch on defense is a Block: no predicted catch (no slow-down,
		-- no disc in the hand); an interception after all is confirmed by
		-- the server like any catch
		return
	end
	controllers.DiscRenderer.predictCatch(id)
	localFeedback(c, discPos)
	CatchController.Claimed:Fire(id, c.kind)
end

local function stepDisc(folder: Configuration, root: BasePart, zones: { CatchGeometry.Zone }, tNow: number)
	local id = folder:GetAttribute("Id") :: string
	local sim, launchTime, _, _, landed, flightId = controllers.DiscRenderer.flight(id)
	if
		not sim
		or landed
		or not canClaim(folder)
		or folder:GetAttribute("ThrowerId") == player.UserId
		or tNow < launchTime + DiscConfig.Throw.NoCatchTime
	then
		contacts[id] = nil
		return
	end
	local x, y, z = DiscPhysics.positionAt(sim, tNow - launchTime)
	local p = Vector3.new(x, y, z)
	local c = contacts[id]
	if not c or c.flightId ~= flightId then
		-- a new segment: start sweeping from here, never from the old one
		contacts[id] = {
			flightId = flightId,
			lastPos = p,
			lastT = tNow,
			tFirst = nil,
			kind = "Secure",
			bestDepth = 1,
			lastDepth = 1,
			body = root.Position,
			bodyVel = root.AssemblyLinearVelocity,
			retry = false,
			awaiting = false,
			sentAt = -math.huge,
			fxDone = false,
			settled = false,
		}
		return
	end
	if c.settled then
		return
	end
	local ev, firstT = sweep(zones, c.lastPos, p, c.lastT, tNow)
	c.lastPos, c.lastT = p, tNow
	if ev then
		if c.tFirst == nil then
			-- the body as it was at the (sub-frame) moment of first contact
			local vel = root.AssemblyLinearVelocity
			c.tFirst = firstT
			c.kind = ev.zone.kind
			c.bestDepth = ev.depth
			c.lastDepth = ev.depth
			c.body = root.Position - vel * (tNow - firstT)
			c.bodyVel = vel
		elseif ev.depth < c.bestDepth then
			c.bestDepth = ev.depth
			c.kind = ev.zone.kind
		end
	end
	local tFirst = c.tFirst
	if tFirst == nil then
		return
	end
	local clock = os.clock()
	if c.awaiting and clock - c.sentAt < ANSWER_TIMEOUT + 2 * myPing() then
		return
	end
	-- claim at the closest approach (or after tracking long enough)
	local receding = ev == nil or ev.depth > c.lastDepth + RECEDE
	local tracked = tNow - tFirst >= C.ClaimTrackTime
	c.lastDepth = if ev then ev.depth else 1
	if (c.retry or receding or tracked) and clock - c.sentAt >= C.ClaimThrottle then
		sendClaim(folder, id, c, p)
		if ev == nil then
			c.tFirst = nil -- the disc has left the zones; a new touch is a new episode
		end
	end
end

local function step()
	local root = controllers.MovementController.root()
	if not root then
		return
	end
	updateMarking()
	if controllers.ThrowController.isHolding() then
		table.clear(contacts)
		return
	end
	local zones = CatchGeometry.zones(bodyState(root))
	local tNow = now()
	for _, folder in controllers.DiscRenderer.folders() do
		stepDisc(folder, root, zones, tNow)
	end
end

-- The server's answer to a claim (always sent, Denied included).
local function onResult(discId: any, accepted: any, result: any, flightId: any)
	if type(discId) ~= "string" then
		return
	end
	local c = contacts[discId]
	local current = c == nil or type(flightId) ~= "number" or flightId == c.flightId
	if not current then
		-- an answer about an older segment (e.g. the block that started this
		-- one): it ends that claim, but a claim already out on the current
		-- segment will get its own answer
		if accepted ~= true and not (c :: Contact).awaiting then
			controllers.DiscRenderer.cancelCatchPrediction(discId)
			CatchController.Denied:Fire(discId)
		end
		return
	end
	if c then
		c.awaiting = false
		c.tFirst = nil
		c.bestDepth = 1
		c.lastDepth = 1
		if result == "Denied" then
			-- retry at once if the disc is still in reach
			c.sentAt = -math.huge
			c.retry = true
		else
			c.settled = true -- caught, or someone else won it
		end
	end
	if accepted ~= true then
		controllers.DiscRenderer.cancelCatchPrediction(discId)
		CatchController.Denied:Fire(discId)
	end
end

function CatchController.Init(c: any)
	controllers = c
end

function CatchController.Start()
	controllers.InputController.ActionBegan:Connect(function(action)
		-- holding, or a catch claimed but not yet confirmed: the disc keys
		-- belong to ThrowController (no Reach / pickup / mark mid-claim)
		if controllers.ThrowController.isHolding() or controllers.MovementController.holdingDisc() then
			return
		end
		if action == "Primary" then
			if not requestPickup() then
				CatchController.reach()
			end
		elseif action == "Secondary" then
			markHeld = true
			updateMarking()
		elseif action == "Slide" and marking then
			toggleStance()
		end
	end)
	controllers.InputController.ActionEnded:Connect(function(action)
		if action == "Secondary" then
			markHeld = false
			setMarking(false)
		end
	end)
	Net.event("CatchResult").OnClientEvent:Connect(onResult)
	player.CharacterAdded:Connect(function()
		if marking then
			marking = false
			sendStance()
		end
		markHeld = false
		markStance = "Low"
		reachAt = -math.huge
		table.clear(contacts)
	end)
	-- after DiscRenderer (Character + 2) has advanced this frame's flights
	RunService:BindToRenderStep("UBCatch", Enum.RenderPriority.Character.Value + 3, step)
end

return CatchController
