--!strict
--[[
	DiscRenderer — draws every disc from its replicated state.

	Flight segments are re-simulated locally from the replicated launch values
	with the same fixed-step DiscPhysics the server runs, synchronised to the
	shared server clock (Net.now): smooth motion, zero per-frame network
	traffic, exactly the server's trajectory. A landing stops at the same
	interpolated contact point the server uses, then slides a little
	(cosmetic skid, SKID_TIME at SKID_DECEL, at most SKID_MAX) instead of
	sticking into the turf.

	Continuity — the disc never pops:
	  * every change of segment (FlightId), holder or mode starts a visual
	    blend: the disc is drawn at its new place plus the old offset, which
	    eases out over BLEND_TIME (0.12 s); the trail is cleared on any real
	    jump so it never streaks across it. Jumps larger than BLEND_MAX (a
	    disc placed somewhere else entirely) are a clean cut instead
	  * your own throw flies the instant you release (prediction); the
	    authoritative flight starts at your release time, so the blend onto
	    it is tiny
	  * a hand block: the segment carries StopAt, so every client holds the
	    disc at the marker's hands until the deflection segment (which starts
	    there, at that moment) arrives; your own prediction does the same
	    when your preview expects the block
	  * your own catch: on the claim the disc eases into your hand
	    (CATCH_EASE, cubic ease-out) and stays until the server answers;
	    Denied (or no answer in time) eases it back onto its flight
	    (DENY_EASE)
	  * someone else's catch: when a flying disc enters a remote player's
	    catch zones as they are displayed here (depth < OBSERVER_DEPTH, the
	    same rule that makes a defender's touch an interception) it is
	    magnetised to their hand (OBSERVER_EASE) and held up to OBSERVER_HOLD
	    waiting for Mode = Held; if the flight continues instead it blends
	    back
	Rendering runs at RenderPriority.Character + 2, after PoseController has
	posed the hands (Character + 1), so a held disc never trails the hand.

	Visuals: spinning disc with a stripe so spin is readable, a team-coloured
	trail (brighter on a Perfect release) and an optional ground shadow that
	helps judge height.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local CatchGeometry = require(Shared.Rules.CatchGeometry)
local Hitbox = require(Shared.Config.Hitbox)
local ProgressionConfig = require(Shared.Config.Progression)
local TeamsConfig = require(Shared.Config.Teams)
local Actors = require(Shared.Actors)
local VecMath = require(Shared.Util.VecMath)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local DiscRenderer = {}

DiscRenderer.FlightStarted = Signal.new() -- (discId, folder)
DiscRenderer.Landed = Signal.new() -- (discId, position)

local controllers: any
local player = Players.LocalPlayer
local visualsFolder: Folder

local BLEND_TIME = 0.12 -- every discontinuity eases out over this long
local BLEND_MAX = 12 -- larger jumps are cut instead of slid
local TRAIL_CLEAR = 0.5 -- a correction larger than this clears the trail
local CATCH_EASE = 0.07 -- own claim: flight -> hand
local DENY_EASE = 0.1 -- own claim denied: hand -> flight
local CATCH_HOLD = 0.5 -- own claim: hold in the hand this long (+ 2 x ping)
local OBSERVER_DEPTH = 0.9
local OBSERVER_EASE = 0.08
local OBSERVER_HOLD = 0.35 -- (+ ping)
local OBSERVER_RANGE = 12 -- only characters this close to the disc are swept
local PREDICT_TIMEOUT = 0.8 -- own throw the server never launched: back to the hand
local LAND_HEIGHT = 0.15 -- resting disc centre above the ground (= server GroundPos)
local SKID_TIME = 0.25
local SKID_DECEL = 120
local SKID_MAX = 1.2
local SAME_SPOT = 0.6 -- GroundPos this close to our landing = the same landing
local MAX_DRAW_SPEED = 160 -- faster apparent motion is a cut, not movement
local UP = Vector3.new(0, 1, 0)

type Observer = { id: number, start: number, untilT: number, flightId: number }

type Visual = {
	id: string,
	folder: Configuration,
	body: BasePart,
	cap: BasePart,
	stripe: BasePart,
	shadow: BasePart,
	trail: Trail,
	trailOn: boolean,
	sim: DiscPhysics.State?,
	simFlight: number, -- FlightId the sim was read from
	flightId: number, -- last FlightId seen
	lastMode: string,
	lastHolder: number,
	launchTime: number,
	stopAt: number, -- flight time where a hand block stops this segment (math.huge = none)
	wind: DiscPhysics.Wind,
	groundY: number,
	landed: boolean,
	landT: number,
	landPos: Vector3,
	landNormal: Vector3,
	restUp: Vector3, -- the face it rests on (an inverted hammer stays inverted)
	skidDir: Vector3,
	skidSpeed: number,
	restOffset: Vector3, -- cosmetic skid kept while resting at the same spot
	spinAngle: number,
	spin: number,
	predicted: DiscPhysics.State?,
	predictedT0: number,
	tipPred: DiscPhysics.State?, -- your own tip: the disc's predicted pop (until the server's segment)
	tipPredT0: number,
	tipPredFlight: number,
	tipPredUntil: number,
	predictedStop: number,
	predictedFlightId: number,
	catchStart: number,
	catchUntil: number,
	catchFlight: number,
	catching: boolean, -- the hand magnet was active last frame
	observer: Observer?,
	lastFlightPos: Vector3?, -- flight position last frame (observer sweep)
	blendOffset: Vector3,
	blendStart: number,
	blendDur: number,
	pendingBlend: number, -- > 0: blend the next frame's jump over this long
	pos: Vector3,
	drawVel: Vector3, -- how fast the drawn disc moved last frame
	normal: Vector3,
	skin: string,
	visible: boolean,
}

local visuals: { [string]: Visual } = {}

local SKINS: { [string]: any } = {}
for _, s in ProgressionConfig.DiscSkins do
	SKINS[s.id] = s
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

local function easeOut(u: number): number
	local x = math.clamp(u, 0, 1)
	local inv = 1 - x
	return 1 - inv * inv * inv
end

local function part(name: string, shape: Enum.PartType, size: Vector3, color: Color3): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.Color = color
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = visualsFolder
	return p
end

local function applySkin(v: Visual, skinId: string)
	local s = SKINS[skinId] or SKINS.Classic
	v.skin = skinId
	v.body.Color = s.color
	v.cap.Color = s.rim
	v.stripe.Color = s.stripe
	v.body.Material = if s.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
end

local function create(folder: Configuration): Visual
	local r = DiscConfig.Physics.Radius
	local body = part("Disc", Enum.PartType.Cylinder, Vector3.new(0.24, r * 2, r * 2), Color3.new(1, 1, 1))
	local cap = part("DiscCap", Enum.PartType.Cylinder, Vector3.new(0.27, r * 1.1, r * 1.1), Color3.new(0.8, 0.8, 0.8))
	local stripe = part("DiscStripe", Enum.PartType.Block, Vector3.new(0.28, 0.28, r * 1.7), Color3.new(0, 0.5, 1))
	local shadow = part("DiscShadow", Enum.PartType.Cylinder, Vector3.new(0.04, r * 2, r * 2), Color3.new(0, 0, 0))
	shadow.Transparency = 1
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0, r * 0.9)
	a0.Parent = body
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, 0, -r * 0.9)
	a1.Parent = body
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.35
	trail.MinLength = 0.05
	trail.FaceCamera = true
	trail.LightEmission = 0.6
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
	trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.2) })
	trail.Enabled = false
	trail.Parent = body
	local v: Visual = {
		id = folder:GetAttribute("Id") :: string,
		folder = folder,
		body = body,
		cap = cap,
		stripe = stripe,
		shadow = shadow,
		trail = trail,
		trailOn = false,
		sim = nil,
		simFlight = -1,
		flightId = (folder:GetAttribute("FlightId") :: number?) or 0,
		lastMode = "",
		lastHolder = 0,
		launchTime = 0,
		stopAt = math.huge,
		wind = { x = 0, y = 0, z = 0 },
		groundY = 0,
		landed = false,
		landT = 0,
		landPos = Vector3.zero,
		landNormal = UP,
		restUp = UP,
		skidDir = Vector3.zero,
		skidSpeed = 0,
		restOffset = Vector3.zero,
		spinAngle = 0,
		spin = 0,
		predicted = nil,
		predictedT0 = 0,
		tipPred = nil,
		tipPredT0 = 0,
		tipPredFlight = -1,
		tipPredUntil = 0,
		predictedStop = math.huge,
		predictedFlightId = -1,
		catchStart = 0,
		catchUntil = 0,
		catchFlight = -1,
		catching = false,
		observer = nil,
		lastFlightPos = nil,
		blendOffset = Vector3.zero,
		blendStart = 0,
		blendDur = BLEND_TIME,
		pendingBlend = 0,
		pos = Vector3.zero,
		drawVel = Vector3.zero,
		normal = UP,
		skin = "",
		visible = false,
	}
	body.Transparency = 1
	cap.Transparency = 1
	stripe.Transparency = 1
	applySkin(v, (folder:GetAttribute("Skin") or "Classic") :: string)
	return v
end

local function destroy(v: Visual)
	v.body:Destroy()
	v.cap:Destroy()
	v.stripe:Destroy()
	v.shadow:Destroy()
end

local function setVisible(v: Visual, on: boolean)
	if v.visible == on then
		return
	end
	v.visible = on
	local t = if on then 0 else 1
	v.body.Transparency = t
	v.cap.Transparency = t
	v.stripe.Transparency = t
	if not on then
		v.shadow.Transparency = 1
		v.trail.Enabled = false
		v.trailOn = false
	end
end

local function setTrail(v: Visual, on: boolean)
	if on == v.trailOn then
		return
	end
	v.trailOn = on
	if on then
		v.trail:Clear() -- start fresh where the disc is now
	end
	v.trail.Enabled = on
end

local function readFlight(v: Visual, flightId: number): boolean
	local f = v.folder
	local pos = f:GetAttribute("LaunchPos")
	local vel = f:GetAttribute("LaunchVel")
	local n = f:GetAttribute("LaunchNormal")
	local spin = f:GetAttribute("Spin")
	local t0 = f:GetAttribute("LaunchTime")
	local wind = f:GetAttribute("Wind")
	if
		typeof(pos) ~= "Vector3"
		or typeof(vel) ~= "Vector3"
		or typeof(n) ~= "Vector3"
		or type(spin) ~= "number"
		or type(t0) ~= "number"
	then
		return false
	end
	local w = if typeof(wind) == "Vector3" then wind else Vector3.zero
	v.sim = DiscPhysics.fromVectors(pos, vel, n, spin)
	v.simFlight = flightId
	v.launchTime = t0
	local stop = f:GetAttribute("StopAt")
	v.stopAt = if type(stop) == "number" and stop > 0 then stop else math.huge
	v.wind = { x = w.X, y = w.Y, z = w.Z }
	v.groundY = (f:GetAttribute("GroundY") :: number?) or 0
	v.landed = false
	v.spin = spin
	v.restOffset = Vector3.zero
	v.lastFlightPos = nil
	-- trail colour: thrower team, brighter for a Perfect release
	local team = f:GetAttribute("ThrowerTeam")
	local color = if team == "A"
		then TeamsConfig.A.Color
		elseif team == "B" then TeamsConfig.B.Color
		else Color3.new(1, 1, 1)
	v.trail.Color = ColorSequence.new(color)
	local perfect = f:GetAttribute("Quality") == "Perfect"
	v.trail.Lifetime = if perfect then 0.55 else 0.35
	v.trail.LightEmission = if perfect then 1 else 0.5
	return true
end

local function handCFrameOf(c: Model?): CFrame?
	if not c then
		return nil
	end
	local leftHanded = c:GetAttribute("LeftHanded") == true
	local hand = c:FindFirstChild(if leftHanded then "LeftHand" else "RightHand") :: BasePart?
	if not hand then
		hand = c:FindFirstChild(if leftHanded then "Left Arm" else "Right Arm") :: BasePart?
	end
	if not hand then
		return nil
	end
	return hand.CFrame * CFrame.new(0, -0.35, -0.75) * CFrame.Angles(0, 0, math.rad(90))
end

local function handCFrame(holderId: number): CFrame?
	if holderId == player.UserId then
		return handCFrameOf(player.Character)
	end
	return handCFrameOf(Actors.characterOf(holderId))
end

local function orient(pos: Vector3, n: Vector3, angle: number): CFrame
	local axis = if n.Magnitude > 0.1 then n.Unit else UP
	local ref = if math.abs(axis.Y) < 0.95 then UP else Vector3.new(1, 0, 0)
	local perp = axis:Cross(ref).Unit
	return CFrame.fromMatrix(pos, axis, perp) * CFrame.Angles(angle, 0, 0)
end

local function place(v: Visual, cf: CFrame, dt: number)
	local r = DiscConfig.Physics.Radius
	local parts = { v.body, v.cap, v.stripe }
	local cfs = { cf, cf, cf * CFrame.new(0, r * 0.35, 0) }
	workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	local moved = (cf.Position - v.pos) / math.max(dt, 1 / 240)
	v.drawVel = if v.visible and moved.Magnitude < MAX_DRAW_SPEED then moved else Vector3.zero
	v.pos = cf.Position
end

local function updateShadow(v: Visual, height: number, show: boolean)
	if not show or height < 0.4 then
		v.shadow.Transparency = 1
		return
	end
	local h = math.clamp(height, 0, 40)
	local scale = 1 + h * 0.03
	local r = DiscConfig.Physics.Radius
	v.shadow.Size = Vector3.new(0.04, r * 2 * scale, r * 2 * scale)
	v.shadow.Transparency = math.clamp(0.55 + h * 0.012, 0.55, 0.9)
	v.shadow.CFrame = CFrame.new(v.pos.X, v.groundY + 0.07, v.pos.Z) * CFrame.Angles(0, 0, math.rad(90))
end

local function shadowsEnabled(v: Visual): boolean
	if v.folder:GetAttribute("Context") ~= "Match" then
		return true
	end
	return Net.state():GetAttribute("LandingShadow") ~= false
end

-- Where the authoritative flight is now (advances the sim; handles landing
-- and the cosmetic skid). Returns (cframe, landed).
local function flightCFrame(v: Visual, s: DiscPhysics.State, t: number, dt: number): (CFrame, boolean)
	-- a hand block holds the disc at the hands until its deflection arrives
	local target = math.min(t - v.launchTime, v.stopAt)
	if not v.landed then
		local alive = DiscPhysics.advanceTo(s, target, v.wind, v.groundY)
		if not alive then
			-- s is at the interpolated contact point and time (as on the server)
			v.landed = true
			v.landT = v.launchTime + s.t
			v.landPos = Vector3.new(s.px, v.groundY + LAND_HEIGHT, s.pz)
			v.landNormal = DiscPhysics.normal(s)
			v.restUp = if v.landNormal.Y < 0 then -UP else UP
			local hv = Vector3.new(s.vx, 0, s.vz)
			v.skidSpeed = hv.Magnitude
			v.skidDir = if v.skidSpeed > 0.1 then hv / v.skidSpeed else Vector3.zero
			DiscRenderer.Landed:Fire(v.id, Vector3.new(s.px, v.groundY, s.pz))
		end
	end
	if v.landed then
		local stopT = math.min(SKID_TIME, v.skidSpeed / SKID_DECEL)
		local tau = math.clamp(t - v.landT, 0, stopT)
		local dist = math.min(v.skidSpeed * tau - 0.5 * SKID_DECEL * tau * tau, SKID_MAX)
		v.restOffset = v.skidDir * dist
		local slowing = if stopT > 0 then 1 - tau / stopT else 0
		v.spinAngle += v.spin * 0.25 * slowing * dt
		-- settle flat over the skid instead of snapping level at touchdown
		local settle = easeOut(math.clamp((t - v.landT) / SKID_TIME, 0, 1))
		return orient(v.landPos + v.restOffset, v.landNormal:Lerp(v.restUp, settle), v.spinAngle), true
	end
	local x, y, z = DiscPhysics.positionAt(s, target)
	v.spinAngle += s.spin * dt
	return orient(Vector3.new(x, y, z), DiscPhysics.normal(s), v.spinAngle), false
end

-- Catch zones of another character as displayed on this client.
local function displayedZones(model: Model, root: BasePart, t: number): { CatchGeometry.Zone }
	local reachT = model:GetAttribute("Reach")
	local reachDir = model:GetAttribute("ReachDir")
	local ms = model:GetAttribute("MS")
	local techDir = model:GetAttribute("TechDir")
	local facing = VecMath.flatUnit(root.CFrame.LookVector)
	local diving = ms == "Dive" or ms == "DiveSlide"
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return CatchGeometry.zones({
		root = Hitbox.root(root.Position, Hitbox.standHeightOf(humanoid, root)),
		facing = facing,
		reaching = type(reachT) == "number" and t - reachT <= DiscConfig.Catch.ReachWindow + 0.1,
		reachDir = if typeof(reachDir) == "Vector3" then reachDir else nil,
		diving = diving,
		diveDir = if diving and typeof(techDir) == "Vector3" and techDir.Magnitude > 0.5 then techDir else facing,
		sliding = ms == "Slide",
		prone = ms == "DiveSlide" or ms == "Recover",
	})
end

local function mayCatch(model: Model, folder: Configuration): boolean
	local role = model:GetAttribute("UBRole")
	if role == "Bench" or role == "Spectate" or model:GetAttribute("UBFrozen") == true then
		return false
	end
	local id = Actors.idOf(model)
	if id == nil or (id == folder:GetAttribute("ThrowerId") and folder:GetAttribute("Touched") ~= true) then
		return false
	end
	if folder:GetAttribute("Context") == "Training" then
		return id == folder:GetAttribute("Owner")
	end
	if folder:GetAttribute("Pull") == true then
		return model:GetAttribute("UBTeam") == Net.state():GetAttribute("Offense")
	end
	return true
end

-- Someone else is about to catch this disc: find them along this frame's path.
local function findObserverCatch(v: Visual, from: Vector3, to: Vector3, t: number): number?
	local mine = player.Character
	for _, model in Actors.characters() do
		if model ~= mine then
			local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root and (root.Position - to).Magnitude < OBSERVER_RANGE and mayCatch(model, v.folder) then
				local zones = displayedZones(model, root, t)
				for k = 1, 3 do
					local ev = CatchGeometry.evaluate(zones, from:Lerp(to, k / 3))
					if ev and ev.depth < OBSERVER_DEPTH then
						return Actors.idOf(model)
					end
				end
			end
		end
	end
	return nil
end

-- The predicted flight of your own throw, before the server launches it.
local function predictedCFrame(v: Visual, pred: DiscPhysics.State, t: number, dt: number): CFrame
	local ft = math.min(t - v.predictedT0, v.predictedStop)
	if not DiscPhysics.advanceTo(pred, ft, v.wind, v.groundY) then
		-- landed before the server's flight arrived: rest at the contact
		return orient(Vector3.new(pred.px, v.groundY + LAND_HEIGHT, pred.pz), UP, v.spinAngle)
	end
	local x, y, z = DiscPhysics.positionAt(pred, math.max(ft, pred.t))
	v.spinAngle += pred.spin * dt
	return orient(Vector3.new(x, y, z), DiscPhysics.normal(pred), v.spinAngle)
end

type Frame = { cf: CFrame?, trail: boolean, shadow: boolean }

local function target(v: Visual, mode: string, holder: number, t: number, dt: number): Frame
	local f = v.folder
	if mode == "Flight" then
		local s = v.sim
		if not s then
			return { cf = nil, trail = false, shadow = false }
		end
		-- your own tip: draw the predicted pop until the server's segment
		-- (a new FlightId) replaces it, or the tip was refused
		local tp = v.tipPred
		if tp then
			if v.tipPredFlight == v.flightId and t < v.tipPredUntil then
				local x, y, z = DiscPhysics.positionAt(tp, math.max(0, t - v.tipPredT0))
				local pos = Vector3.new(x, math.max(y, v.groundY + DiscConfig.Physics.GroundContact), z)
				v.spinAngle += tp.spin * dt
				return { cf = orient(pos, DiscPhysics.normal(tp), v.spinAngle), trail = true, shadow = true }
			end
			v.tipPred = nil
			if v.tipPredFlight == v.flightId then
				v.pendingBlend = DENY_EASE -- refused: ease back onto the flight
			end
		end
		local cf, landed = flightCFrame(v, s, t, dt)
		local flightPos = cf.Position
		local stopped = t - v.launchTime >= v.stopAt

		-- own claim: ease into the hand while the server decides
		local catching = t < v.catchUntil and v.catchFlight == v.flightId
		if catching then
			local hand = handCFrame(player.UserId)
			if hand then
				v.catching = true
				v.lastFlightPos = flightPos
				return { cf = cf:Lerp(hand, easeOut((t - v.catchStart) / CATCH_EASE)), trail = false, shadow = false }
			end
		end
		if v.catching then
			v.catching = false
			v.pendingBlend = DENY_EASE -- denied / no answer: back onto the flight
		end

		-- someone else's catch, as this client displays them
		local ob = v.observer
		if ob and (ob.flightId ~= v.flightId or t >= ob.untilT) then
			v.observer = nil
			ob = nil
			v.pendingBlend = BLEND_TIME
		end
		local catchable = t >= v.launchTime + DiscConfig.Throw.NoCatchTime
		if not ob and not landed and not stopped and catchable and v.lastFlightPos then
			local id = findObserverCatch(v, v.lastFlightPos :: Vector3, flightPos, t)
			if id then
				ob = { id = id, start = t, untilT = t + OBSERVER_HOLD + myPing(), flightId = v.flightId }
				v.observer = ob
			end
		end
		v.lastFlightPos = flightPos
		if ob then
			local hand = handCFrame(ob.id)
			if hand then
				return { cf = cf:Lerp(hand, easeOut((t - ob.start) / OBSERVER_EASE)), trail = false, shadow = false }
			end
		end
		return { cf = cf, trail = not landed, shadow = not landed }
	end

	v.observer = nil
	v.catching = false
	v.lastFlightPos = nil
	if mode == "Held" then
		local pred = v.predicted
		if pred and holder == player.UserId and t - v.predictedT0 <= PREDICT_TIMEOUT then
			return { cf = predictedCFrame(v, pred, t, dt), trail = true, shadow = true }
		end
		if pred then
			v.predicted = nil -- the server never launched it: back to the hand
		end
		v.spinAngle += dt * 0.5
		return { cf = if holder ~= 0 then handCFrame(holder) else nil, trail = false, shadow = false }
	elseif mode == "Ground" then
		local gp = f:GetAttribute("GroundPos")
		if typeof(gp) ~= "Vector3" then
			return { cf = nil, trail = false, shadow = false }
		end
		-- keep the cosmetic skid (and the face it landed on) when the server
		-- rests it where we landed it
		local offset = Vector3.zero
		local up = UP
		if v.landed and (VecMath.flat(gp - v.landPos)).Magnitude <= SAME_SPOT then
			offset = v.restOffset
			up = v.restUp
		end
		return { cf = orient(gp + offset, up, v.spinAngle), trail = false, shadow = false }
	end
	return { cf = nil, trail = false, shadow = false }
end

local function render(v: Visual, dt: number)
	local f = v.folder
	local t = now()
	local modeAttr = f:GetAttribute("Mode")
	local mode = if type(modeAttr) == "string" then modeAttr else "None"
	local holderAttr = f:GetAttribute("HolderId")
	local holder = if type(holderAttr) == "number" then holderAttr else 0
	local skin = f:GetAttribute("Skin")
	if type(skin) == "string" and skin ~= v.skin then
		applySkin(v, skin)
	end

	-- state changes (each one is blended below)
	local changed = false
	local flightId = (f:GetAttribute("FlightId") :: number?) or 0
	if flightId ~= v.flightId then
		v.flightId = flightId
		v.observer = nil
		changed = true
	end
	-- a new segment: FlightId, or LaunchTime should FlightId arrive a frame late
	local launchT = f:GetAttribute("LaunchTime")
	if mode == "Flight" and (v.simFlight ~= flightId or (type(launchT) == "number" and launchT ~= v.launchTime)) then
		if readFlight(v, flightId) then
			DiscRenderer.FlightStarted:Fire(v.id, f)
			changed = true
		else
			v.sim = nil
		end
	end
	if v.predicted and (mode ~= "Held" or v.predictedFlightId ~= flightId) then
		v.predicted = nil -- the authoritative flight (or another state) took over
	end
	if mode ~= v.lastMode or holder ~= v.lastHolder then
		changed = true
		v.lastMode = mode
		v.lastHolder = holder
	end

	local fr = target(v, mode, holder, t, dt)
	local cf = fr.cf
	if not cf then
		setVisible(v, false)
		return
	end

	-- blend every discontinuity (or cut a big one)
	local blendFor = if changed then BLEND_TIME else 0
	if v.pendingBlend > 0 then
		blendFor = v.pendingBlend
		v.pendingBlend = 0
	end
	if blendFor > 0 then
		-- the jump between where the old state would have drawn the disc this
		-- frame and where the new one does (not the disc's own motion)
		local jump = if v.visible then v.pos + v.drawVel * dt - cf.Position else Vector3.zero
		local size = jump.Magnitude
		if size > TRAIL_CLEAR then
			v.trail:Clear()
		end
		if size > 1e-3 and size <= BLEND_MAX then
			-- continue from wherever the disc is drawn now (including a running blend)
			v.blendOffset = jump
			v.blendStart = t
			v.blendDur = blendFor
		else
			v.blendOffset = Vector3.zero
			v.blendDur = 0
		end
	end
	if v.blendDur > 0 then
		local k = 1 - (t - v.blendStart) / v.blendDur
		if k <= 0 then
			v.blendDur = 0
			v.blendOffset = Vector3.zero
		else
			local w = k * k * (3 - 2 * k)
			cf = cf + v.blendOffset * w
		end
	end

	place(v, cf, dt)
	setVisible(v, true)
	setTrail(v, fr.trail)
	updateShadow(v, v.pos.Y - v.groundY, fr.shadow and shadowsEnabled(v))
end

---------------------------------------------------------------------------
-- public API
---------------------------------------------------------------------------

function DiscRenderer.folders(): { Configuration }
	local list = {}
	for _, v in visuals do
		table.insert(list, v.folder)
	end
	return list
end

-- Where the disc is drawn this frame.
function DiscRenderer.positionOf(id: string): Vector3?
	local v = visuals[id]
	return if v and v.visible then v.pos else nil
end

-- Flight info for catch detection (nil sim unless flying). The last value is
-- the FlightId the sim belongs to.
function DiscRenderer.flight(id: string): (DiscPhysics.State?, number, DiscPhysics.Wind, number, boolean, number)
	local v = visuals[id]
	if not v or v.folder:GetAttribute("Mode") ~= "Flight" or v.simFlight ~= v.flightId then
		return nil, 0, { x = 0, y = 0, z = 0 }, 0, true, -1
	end
	-- a disc held up by a marker's hands is not catchable either
	local over = v.landed or now() - v.launchTime >= v.stopAt
	return v.sim, v.launchTime, v.wind, v.groundY, over, v.simFlight
end

function DiscRenderer.folderOf(id: string): Configuration?
	local v = visuals[id]
	return if v then v.folder else nil
end

function DiscRenderer.heldByMe(): Configuration?
	for _, v in visuals do
		if v.folder:GetAttribute("Mode") == "Held" and v.folder:GetAttribute("HolderId") == player.UserId then
			return v.folder
		end
	end
	return nil
end

-- Your own throw: fly `state` from server time `t0` (default now) until the
-- server's flight arrives; `stopAt` (flight time) holds it at a marker's
-- hands when the release is expected to be hand-blocked.
function DiscRenderer.predictThrow(id: string, state: DiscPhysics.State, t0: number?, stopAt: number?)
	local v = visuals[id]
	if not v then
		return
	end
	v.predicted = DiscPhysics.copy(state)
	v.predictedT0 = t0 or now()
	v.predictedStop = if stopAt and stopAt > 0 then stopAt else math.huge
	v.predictedFlightId = v.flightId
	-- the server flies the throw with the disc's own wind (Wind attribute)
	local w = v.folder:GetAttribute("Wind")
	v.wind = if typeof(w) == "Vector3" then { x = w.X, y = w.Y, z = w.Z } else { x = 0, y = 0, z = 0 }
end

-- Your own tip: draw the disc's predicted pop (from contact time t0) until
-- the server's deflection arrives, at most TIP_PREDICT + 2 x ping.
local TIP_PREDICT = 0.35
function DiscRenderer.predictTip(id: string, state: DiscPhysics.State, t0: number)
	local v = visuals[id]
	if not v or v.folder:GetAttribute("Mode") ~= "Flight" then
		return
	end
	v.tipPred = DiscPhysics.copy(state)
	v.tipPredT0 = t0
	v.tipPredFlight = v.flightId
	v.tipPredUntil = now() + TIP_PREDICT + 2 * myPing()
	v.catchUntil = 0
	v.observer = nil
	v.pendingBlend = BLEND_TIME
end

-- Your own claim: ease the disc into your hand until the server answers.
function DiscRenderer.predictCatch(id: string)
	local v = visuals[id]
	if not v or v.folder:GetAttribute("Mode") ~= "Flight" then
		return
	end
	local t = now()
	if not (t < v.catchUntil and v.catchFlight == v.flightId) then
		v.catchStart = t
	end
	v.catchUntil = t + CATCH_HOLD + 2 * myPing()
	v.catchFlight = v.flightId
	v.observer = nil
end

-- The claim was denied (or went to someone else): ease back onto the flight.
function DiscRenderer.cancelCatchPrediction(id: string)
	local v = visuals[id]
	if v then
		v.catchUntil = 0
	end
end

function DiscRenderer.Init(c: any)
	controllers = c
	local f = workspace:FindFirstChild("UBVisuals")
	if not f then
		local nf = Instance.new("Folder")
		nf.Name = "UBVisuals"
		nf.Parent = workspace
		f = nf
	end
	visualsFolder = f :: Folder
end

function DiscRenderer.Start()
	local discs = Net.discs()
	local function add(child: Instance)
		if child:IsA("Configuration") then
			-- attributes may arrive a frame after the instance
			task.defer(function()
				local id = child:GetAttribute("Id")
				if type(id) == "string" and not visuals[id] and child.Parent then
					visuals[id] = create(child)
				end
			end)
		end
	end
	discs.ChildAdded:Connect(add)
	discs.ChildRemoved:Connect(function(child)
		for id, v in visuals do
			if v.folder == child then
				destroy(v)
				visuals[id] = nil
			end
		end
	end)
	for _, c in discs:GetChildren() do
		add(c)
	end
	-- after PoseController (Character + 1) has posed the hands this frame
	RunService:BindToRenderStep("UBDiscs", Enum.RenderPriority.Character.Value + 2, function(dt)
		for _, v in visuals do
			local ok, err = pcall(function()
				render(v, dt)
			end)
			if not ok then
				warn("[DiscRenderer] " .. tostring(err))
			end
		end
	end)
	local _ = controllers
end

return DiscRenderer
