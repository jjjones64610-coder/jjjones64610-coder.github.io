--!strict
--[[
	DiscRenderer — draws every disc from its replicated state.

	Flight segments are re-simulated locally from the replicated launch values
	with the same fixed-step DiscPhysics the server runs, synchronised to
	workspace:GetServerTimeNow(): smooth 60+ fps motion, zero per-frame
	network traffic, identical trajectory to the server's.

	Prediction:
	  * your own throw starts flying the instant you release; when the
	    authoritative flight arrives the visual blends onto it over 0.25 s
	  * your own catch snaps to your hand immediately; if the server awards
	    the disc to someone else the visual simply follows the new state

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
local ProgressionConfig = require(Shared.Config.Progression)
local TeamsConfig = require(Shared.Config.Teams)
local Actors = require(Shared.Actors)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local DiscRenderer = {}

DiscRenderer.FlightStarted = Signal.new() -- (discId, folder)
DiscRenderer.Landed = Signal.new() -- (discId, position)

local controllers: any
local player = Players.LocalPlayer
local visualsFolder: Folder

type Visual = {
	id: string,
	folder: Configuration,
	body: BasePart,
	cap: BasePart,
	stripe: BasePart,
	shadow: BasePart,
	trail: Trail,
	sim: DiscPhysics.State?,
	flightId: number,
	launchTime: number,
	wind: DiscPhysics.Wind,
	groundY: number,
	landed: boolean,
	spinAngle: number,
	spin: number,
	predicted: DiscPhysics.State?,
	predictedT0: number,
	predictedFlightId: number,
	blendOffset: Vector3,
	blendUntil: number,
	predictHoldUntil: number,
	pos: Vector3,
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
		sim = nil,
		flightId = 0,
		launchTime = 0,
		wind = { x = 0, y = 0, z = 0 },
		groundY = 0,
		landed = false,
		spinAngle = 0,
		spin = 0,
		predicted = nil,
		predictedT0 = 0,
		predictedFlightId = -1,
		blendOffset = Vector3.zero,
		blendUntil = 0,
		predictHoldUntil = 0,
		pos = Vector3.zero,
		normal = Vector3.new(0, 1, 0),
		skin = "",
		visible = true,
	}
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
	end
end

local function readFlight(v: Visual)
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
		return
	end
	local w = if typeof(wind) == "Vector3" then wind else Vector3.zero
	v.sim = DiscPhysics.fromVectors(pos, vel, n, spin)
	v.launchTime = t0
	v.wind = { x = w.X, y = w.Y, z = w.Z }
	v.groundY = (f:GetAttribute("GroundY") :: number?) or 0
	v.landed = false
	v.spin = spin
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
end

local function handCFrame(holderId: number): CFrame?
	local c = Actors.characterOf(holderId)
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

local function orient(pos: Vector3, n: Vector3, angle: number): CFrame
	local axis = if n.Magnitude > 0.1 then n.Unit else Vector3.new(0, 1, 0)
	local ref = if math.abs(axis.Y) < 0.95 then Vector3.new(0, 1, 0) else Vector3.new(1, 0, 0)
	local perp = axis:Cross(ref).Unit
	return CFrame.fromMatrix(pos, axis, perp) * CFrame.Angles(angle, 0, 0)
end

local function place(v: Visual, cf: CFrame)
	local r = DiscConfig.Physics.Radius
	local parts = { v.body, v.cap, v.stripe }
	local cfs = { cf, cf, cf * CFrame.new(0, r * 0.35, 0) }
	workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
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

local function render(v: Visual, dt: number)
	local f = v.folder
	local t = now()
	local mode = f:GetAttribute("Mode")
	local skin = f:GetAttribute("Skin")
	if type(skin) == "string" and skin ~= v.skin then
		applySkin(v, skin)
	end
	local flightId = (f:GetAttribute("FlightId") :: number?) or 0
	if flightId ~= v.flightId then
		local previousPos = v.pos
		local hadPrediction = v.predicted ~= nil and v.predictedFlightId == v.flightId
		v.flightId = flightId
		if mode == "Flight" then
			readFlight(v)
			DiscRenderer.FlightStarted:Fire(v.id, f)
			if hadPrediction and v.sim then
				local s = DiscPhysics.copy(v.sim :: DiscPhysics.State)
				DiscPhysics.advanceTo(s, t - v.launchTime, v.wind, v.groundY - 100)
				local x, y, z = DiscPhysics.positionAt(s, t - v.launchTime)
				v.blendOffset = previousPos - Vector3.new(x, y, z)
				v.blendUntil = t + 0.25
			end
		end
		v.predicted = nil
	end

	-- local catch prediction
	if t < v.predictHoldUntil and mode == "Flight" then
		local cf = handCFrame(player.UserId)
			or (if player.Character then (player.Character :: Model):GetPivot() else nil)
		if cf then
			setVisible(v, true)
			v.trail.Enabled = false
			place(v, cf)
			updateShadow(v, 0, false)
			return
		end
	end

	-- local throw prediction (server has not confirmed yet)
	local pred = v.predicted
	if pred and mode == "Held" then
		if t - v.predictedT0 > 0.8 then
			v.predicted = nil -- rejected; disc stays in hand
		else
			DiscPhysics.advanceTo(pred, t - v.predictedT0, v.wind, v.groundY)
			local x, y, z = DiscPhysics.positionAt(pred, t - v.predictedT0)
			setVisible(v, true)
			v.trail.Enabled = true
			v.spinAngle += pred.spin * dt
			place(v, orient(Vector3.new(x, y, z), DiscPhysics.normal(pred), v.spinAngle))
			updateShadow(v, y - v.groundY, shadowsEnabled(v))
			return
		end
	end

	if mode == "Flight" then
		local s = v.sim
		if not s then
			setVisible(v, false)
			return
		end
		local target = t - v.launchTime
		if not v.landed then
			local alive = DiscPhysics.advanceTo(s, target, v.wind, v.groundY)
			if not alive then
				v.landed = true
				DiscRenderer.Landed:Fire(v.id, Vector3.new(s.px, v.groundY, s.pz))
			end
		end
		local pos: Vector3
		local n: Vector3
		if v.landed then
			pos = Vector3.new(s.px, v.groundY + 0.13, s.pz)
			n = Vector3.new(0, 1, 0)
			v.trail.Enabled = false
		else
			local x, y, z = DiscPhysics.positionAt(s, target)
			pos = Vector3.new(x, y, z)
			n = DiscPhysics.normal(s)
			v.trail.Enabled = true
			v.spinAngle += s.spin * dt
		end
		if t < v.blendUntil then
			pos += v.blendOffset * ((v.blendUntil - t) / 0.25)
		end
		setVisible(v, true)
		place(v, orient(pos, n, v.spinAngle))
		updateShadow(v, pos.Y - v.groundY, shadowsEnabled(v) and not v.landed)
		return
	end

	v.trail.Enabled = false
	if mode == "Held" then
		local holder = f:GetAttribute("HolderId")
		local cf = if type(holder) == "number" and holder ~= 0 then handCFrame(holder) else nil
		if cf then
			setVisible(v, true)
			v.spinAngle += dt * 0.5
			place(v, cf)
			updateShadow(v, 0, false)
		else
			setVisible(v, false)
		end
	elseif mode == "Ground" then
		local gp = f:GetAttribute("GroundPos")
		if typeof(gp) == "Vector3" then
			setVisible(v, true)
			place(v, orient(gp, Vector3.new(0, 1, 0), v.spinAngle))
			updateShadow(v, 0, false)
		end
	else
		setVisible(v, false)
	end
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

function DiscRenderer.positionOf(id: string): Vector3?
	local v = visuals[id]
	return if v then v.pos else nil
end

-- Flight info for catch detection (nil unless flying).
function DiscRenderer.flight(id: string): (DiscPhysics.State?, number, DiscPhysics.Wind, number, boolean)
	local v = visuals[id]
	if not v or v.folder:GetAttribute("Mode") ~= "Flight" then
		return nil, 0, { x = 0, y = 0, z = 0 }, 0, true
	end
	return v.sim, v.launchTime, v.wind, v.groundY, v.landed
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

function DiscRenderer.predictThrow(id: string, state: DiscPhysics.State)
	local v = visuals[id]
	if not v then
		return
	end
	v.predicted = DiscPhysics.copy(state)
	v.predictedT0 = now()
	v.predictedFlightId = v.flightId
	local w = Net.state():GetAttribute("Wind")
	if typeof(w) == "Vector3" then
		v.wind = { x = w.X, y = w.Y, z = w.Z }
	end
end

function DiscRenderer.predictCatch(id: string)
	local v = visuals[id]
	if v then
		v.predictHoldUntil = now() + 0.5
	end
end

function DiscRenderer.cancelCatchPrediction(id: string)
	local v = visuals[id]
	if v then
		v.predictHoldUntil = 0
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
				if type(id) == "string" and not visuals[id] then
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
	RunService:BindToRenderStep("UBDiscs", Enum.RenderPriority.Camera.Value + 2, function(dt)
		for _, v in visuals do
			local ok, err = pcall(function()
				render(v, dt)
			end)
			if not ok then
				warn("[DiscRenderer] " .. tostring(err))
			end
		end
	end)
	Net.event("CatchResult").OnClientEvent:Connect(function(discId, accepted)
		if not accepted and type(discId) == "string" then
			DiscRenderer.cancelCatchPrediction(discId)
		end
	end)
	local _ = controllers
end

return DiscRenderer
