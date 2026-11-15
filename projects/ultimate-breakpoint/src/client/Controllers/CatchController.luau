--!strict
--[[
	CatchController — catching, blocking and marking for the local player
	(docs/CORE_DESIGN.md, stage 4). One button: Primary (LMB) is your hands.

	EASY CATCHES ARE AUTOMATIC. Every frame the disc's path since the last
	frame is swept against your catch zones (CatchGeometry, the module the
	server validates with): a ball in front of your chest, plus a reach
	toward your aim after a press, a long layout zone while you dive, and a
	hands-up zone during a Sky Reach. On contact the controller tracks to the
	disc's closest approach, then claims it; the disc eases into your hands
	at once (DiscRenderer) and the server confirms.

	HARD CATCHES NEED YOUR HANDS ON TIME. A catch is hard when you are in
	the air (a jump or a dive), when the disc is taken with the layout or
	Sky Reach zone, or at full sprint (CatchGeometry.isHard). Press Primary
	as the disc arrives: within CATCH_HARD_WINDOW it is a catch, within
	CATCH_PERFECT a Perfect Catch (Burst back, Hot Hands for an instant
	release, the big effect). With no press an attacker bobbles it (it pops
	up and can be caught again) and a defender only knocks it down: a block.
	The catch ring on the disc closes as it reaches your hands and turns
	gold in the Perfect window. A press on an easy catch still earns the
	Perfect.

	BLOCKS come from your body: get any of your zones into the disc's path
	with a well-timed jump or dive. On time it is an interception, otherwise
	a block. When two players touch the disc together, the better-timed
	press wins it, then the better position (CatchGeometry.resolve).

	Primary also: picks up a disc lying next to you; opens a short reach
	toward your aim (the extra zone above); and, on the mark, swings a hand
	at the release (DefenseService).

	MARKING is automatic: within Marking.Range of an opposing thrower's pivot
	you shuffle with your hands out. The stance follows your body: on the
	ground it is Low and wide; jump and it is High. No mark keys.

	The server always answers a claim (CatchResult). Denied, or the disc
	going to someone else, fires Denied(discId): the slow-down is cancelled
	and the disc eases back onto its flight.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local TechConfig = require(Shared.Config.Tech)
local TechCore = require(Shared.Movement.TechCore)
local MovementConfig = require(Shared.Config.Movement)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local CatchGeometry = require(Shared.Rules.CatchGeometry)
local Abilities = require(Shared.Config.Abilities)
local Hitbox = require(Shared.Config.Hitbox)
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
CatchController.Caught = Signal.new() -- (discId, interception) the server confirmed your catch
CatchController.Tipped = Signal.new() -- (kept for listeners; the tip press is gone with its key)

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

-- marking (automatic)
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
	closestT: number?, -- timed catch: when the disc was closest (claim held for a late press)
	hard: boolean, -- a hard catch (CatchGeometry.isHard): needs the press
	grade: string?, -- the timed grade of the claim that went out
}
local contacts: { [string]: Contact } = {}
local lastLocalFx = -math.huge -- os.clock() of the last local catch feedback
local catchPressAt = -math.huge -- Net.now() of the last Catch press
local grades: { [string]: string } = {} -- disc id -> grade of our pending claim
local kinds: { [string]: string } = {} -- disc id -> zone of our pending claim
local hotHandsUntil = -math.huge -- os.clock()
local CATCH_W = TechConfig.CATCH_WINDOW / 1000

-- Open for HOT_HANDS_TIME after a confirmed Perfect Catch (ThrowController).
function CatchController.hotHands(): boolean
	return os.clock() < hotHandsUntil
end

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
	local mc = controllers.MovementController
	if controllers.ThrowController.isHolding() or mc.holdingDisc() then
		setMarking(false)
		return
	end
	local d = holderDistance()
	if marking then
		if d == nil or d > MK.Range + MARK_DROP then
			setMarking(false)
		end
	elseif d ~= nil and d <= MK.Range and mc.isGrounded() then
		setMarking(true)
	end
	-- the stance follows the body: hands low and wide on the ground, high
	-- in a jump
	if marking then
		local want = if mc.isGrounded() then "Low" else "High"
		if want ~= markStance then
			markStance = want
			sendStance()
		end
	end
end

---------------------------------------------------------------------------
-- catching
---------------------------------------------------------------------------

local function bodyState(root: BasePart): CatchGeometry.BodyState
	local mc = controllers.MovementController
	local tech: TechCore.State = mc.techState()
	local st = tech.state
	local facing = VecMath.flatUnit(root.CFrame.LookVector)
	local diving = st == "Diving" or st == "Downed"
	return {
		root = Hitbox.root(root.Position, mc.standHeight()),
		facing = facing,
		reaching = CatchController.reachActive(),
		reachDir = reachDir,
		diving = diving,
		diveDir = if diving then VecMath.flatUnit(tech.heading) else facing,
		sliding = st == "Sliding",
		prone = st == "Downed" or (st == "Recovering" and tech.now < tech.recoverUntil),
		skyReach = TechCore.reachBonus(tech) > 0,
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
	local slack = if Abilities.activeOn(player.Character, "MagnetHands", Net.now()) then Abilities.MagnetReach else nil
	local firstT = tTo
	for k = 1, n do
		local a = k / n
		local ev = CatchGeometry.evaluate(zones, from:Lerp(to, a), slack)
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
	local pressT: number? = nil
	local hard = false
	if TechConfig.TIMED_CATCH then
		local closest = c.closestT or now()
		local offset = catchPressAt - closest
		local tech = controllers.MovementController.techState()
		hard = c.hard
		local window = if hard then TechConfig.CATCH_HARD_WINDOW else TechConfig.CATCH_WINDOW
		local grade = CatchGeometry.pressGrade(catchPressAt, closest, hard)
		if grade > 0 then
			pressT = catchPressAt
			TechCore.noteTiming(tech, "Catch", offset * 1000, window, TechConfig.CATCH_PERFECT)
			c.grade = if grade == 2 then "Perfect" else "Clean"
		else
			c.grade = "Miss"
			if catchPressAt > closest - 1 then
				TechCore.noteTiming(tech, "Catch", offset * 1000, window, TechConfig.CATCH_PERFECT)
			end
		end
		grades[id] = c.grade :: string
		kinds[id] = c.kind
		c.closestT = nil
	end
	Net.event("Catch"):FireServer(id, tFirst, c.kind, reachDir, c.body, c.bodyVel, pressT)
	if TechConfig.TIMED_CATCH and (hard or TechConfig.TIMED_CATCH_STRICT) and pressT == nil then
		-- a hard catch with no press on time: the server bobbles it (or, on
		-- defence, rules a block), so predict nothing
		return
	end
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
		or (folder:GetAttribute("ThrowerId") == player.UserId and folder:GetAttribute("Touched") ~= true)
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
			hard = false,
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
		if TechConfig.TIMED_CATCH then
			-- hold the claim at the closest approach for a late press
			if c.closestT == nil then
				c.closestT = tNow
			end
			local closest = c.closestT :: number
			-- is it a hard catch? (the same numbers go to the server)
			local groundY = folder:GetAttribute("GroundY")
			local height = c.body.Y
				- controllers.MovementController.standHeight()
				- (if type(groundY) == "number" then groundY else 0)
			c.hard = CatchGeometry.isHard(height, VecMath.flat(c.bodyVel).Magnitude, c.kind)
			-- a hard catch waits its whole window for a late press; an easy
			-- one only the Perfect part (the touch is a catch anyway)
			local need = c.hard or TechConfig.TIMED_CATCH_STRICT
			local window = if c.hard then TechConfig.CATCH_HARD_WINDOW / 1000 else CATCH_W
			local wait = if need then window else TechConfig.CATCH_PERFECT / 1000
			if catchPressAt < closest - window and tNow < closest + wait then
				return
			end
		end
		sendClaim(folder, id, c, p)
		if ev == nil then
			c.tFirst = nil -- the disc has left the zones; a new touch is a new episode
		end
	end
end

-- The catch ring: a circle on the disc that closes as its closest approach
-- to your hands nears, gold inside the Perfect window (timed catch only).
local ring: Frame? = nil
local RING_LOOK = 0.6 -- s ahead the ring watches
local RING_MISS = 4 -- studs: only discs passing this close to your hands

local function ensureRing(): Frame
	local r = ring
	if r and r.Parent then
		return r
	end
	local g = Instance.new("ScreenGui")
	g.Name = "UBCatchRing"
	g.IgnoreGuiInset = true
	g.ResetOnSpawn = false
	g.Parent = player:WaitForChild("PlayerGui")
	local f = Instance.new("Frame")
	f.Name = "Ring"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundTransparency = 1
	f.Visible = false
	f.Parent = g
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Parent = f
	ring = f
	return f
end

local function updateRing(root: BasePart, tNow: number)
	if not TechConfig.TIMED_CATCH then
		return
	end
	local f = ensureRing()
	local hands = root.Position + Vector3.new(0, C.ShoulderHeight, 0)
	local bestT, bestPos = math.huge, nil :: Vector3?
	for _, folder in controllers.DiscRenderer.folders() do
		local id = folder:GetAttribute("Id")
		if type(id) == "string" and folder:GetAttribute("Mode") == "Flight" then
			local sim, launchTime, _, _, landed = controllers.DiscRenderer.flight(id)
			if sim and not landed then
				local minD, minT = math.huge, 0
				for i = 0, 12 do
					local dt = RING_LOOK * i / 12
					local x, y, z = DiscPhysics.positionAt(sim, tNow + dt - launchTime)
					local d = (Vector3.new(x, y, z) - hands).Magnitude
					if d < minD then
						minD, minT = d, dt
					end
				end
				if minD < RING_MISS and minT > 0 and minT < bestT then
					local x, y, z = DiscPhysics.positionAt(sim, tNow - launchTime)
					bestT, bestPos = minT, Vector3.new(x, y, z)
				end
			end
		end
	end
	local cam = workspace.CurrentCamera
	if not bestPos or not cam or controllers.ThrowController.isHolding() then
		f.Visible = false
		return
	end
	local sp, onScreen = cam:WorldToViewportPoint(bestPos)
	if not onScreen then
		f.Visible = false
		return
	end
	local size = 24 + 150 * math.clamp(bestT / RING_LOOK, 0, 1)
	f.Visible = true
	f.Position = UDim2.fromOffset(sp.X, sp.Y)
	f.Size = UDim2.fromOffset(size, size)
	local stroke = f:FindFirstChildOfClass("UIStroke")
	if stroke then
		local perfect = bestT * 1000 <= TechConfig.CATCH_PERFECT + 25
		stroke.Color = if perfect then Color3.fromRGB(255, 215, 80) else Color3.new(1, 1, 1)
		stroke.Transparency = 0.15
	end
end

local function step()
	local root = controllers.MovementController.root()
	if not root then
		return
	end
	updateMarking()
	updateRing(root, now())
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
			-- retry at once if the disc is still in reach (a refused tip
			-- gives the segment back to catching too)
			c.sentAt = -math.huge
			c.retry = true
			c.settled = false
		else
			c.settled = true -- caught, or someone else won it
		end
	end
	local grade = grades[discId]
	grades[discId] = nil
	local kind = kinds[discId]
	kinds[discId] = nil
	local hard = c ~= nil and c.hard
	if accepted ~= true then
		controllers.DiscRenderer.cancelCatchPrediction(discId)
		CatchController.Denied:Fire(discId)
		if result == "Bobble" then
			controllers.TechFeedback.play(if hard then "Bobbled: hands late" else "Bobble", "Miss")
		elseif result == "Block" then
			controllers.TechFeedback.play("Block", "Clean")
		end
	else
		if grade == "Perfect" then
			-- Perfect Catch: Burst back, a scored tech, and Hot Hands
			hotHandsUntil = os.clock() + TechConfig.HOT_HANDS_TIME
			TechCore.addBurst(controllers.MovementController.techState(), TechConfig.PERFECT_BURST_REFUND)
			controllers.MovementController.addTech("PerfectCatch", "Perfect", Vector3.zero)
		end
		-- the reward: hard catches are named, Perfect ones hit like a highlight
		local name = if kind == "Dive"
			then "Layout Catch"
			elseif kind == "Sky" then "Sky Catch"
			elseif hard and not controllers.MovementController.isGrounded() then "Air Catch"
			elseif hard then "Sprint Catch"
			else "Catch"
		if grade == "Perfect" then
			controllers.TechFeedback.play("Perfect " .. name, "Perfect")
			if hard then
				controllers.AnimeFX.impactFrame(Color3.fromRGB(255, 215, 80))
				controllers.CameraController.kick(0.5)
			end
		elseif hard then
			controllers.TechFeedback.play(name, "Clean")
		end
		local folder = controllers.DiscRenderer.folderOf(discId)
		local me = player.Character
		local throwerTeam = folder and folder:GetAttribute("ThrowerTeam")
		local interception = me ~= nil
			and type(throwerTeam) == "string"
			and throwerTeam ~= ""
			and throwerTeam ~= me:GetAttribute("UBTeam")
		CatchController.Caught:Fire(discId, interception)
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
			catchPressAt = now() -- your hands, whatever else the press does
		end
		if action == "Primary" and marking then
			-- on the mark: swing a hand toward your aim (DefenseService)
			local aim = VecMath.flatUnit(controllers.CameraController.getAimDirection())
			Net.event("Action"):FireServer("HandBlock", aim)
			reachAt = now()
			reachDir = aim
			local c = player.Character
			if c then
				c:SetAttribute("UB_LocalReach", reachAt)
				c:SetAttribute("UB_LocalReachDir", aim)
			end
			return
		end
		if action == "Primary" then
			if not requestPickup() then
				CatchController.reach()
			end
		end
	end)
	Net.event("CatchResult").OnClientEvent:Connect(onResult)
	player.CharacterAdded:Connect(function()
		if marking then
			marking = false
			sendStance()
		end
		markStance = "Low"
		reachAt = -math.huge
		table.clear(contacts)
	end)
	-- after DiscRenderer (Character + 2) has advanced this frame's flights
	RunService:BindToRenderStep("UBCatch", Enum.RenderPriority.Character.Value + 3, step)
end

return CatchController
