--!strict
--[[
	ThrowController — everything you do with the disc in your hand
	(docs/CORE_DESIGN.md, stage 3). Two buttons, no throw keys:

	  hold Primary (LMB)   charge. Power rises with the hold; releasing on
	                       the Snap point is a Perfect release (faster, more
	                       spin); holding past the zone overcharges (wobbly).
	  release Primary      throw where the crosshair points.
	  what you hold at the release shapes it (ThrowModel.shape):
	      nothing          a flat backhand
	      A                a backhand that bends left
	      D                a forehand, from your other side, bending right
	      aim up hard + a strong charge: a Hammer over the defence
	  hold Secondary (RMB) aim: a tighter view and a slower mouse
	  Secondary during a charge: a pump fake. The throw is cancelled; the
	                       defenders saw the same windup as a real throw.
	  WASD                 step the free foot around your planted pivot
	                       (double-tap to lunge); stepping out and bending
	                       the throw are the same keys, as in the real sport

	You can throw during the catch skid and in the air (catch it in a jump or
	a dive and release before you land): those releases aim exactly where you
	point but cost spin, since there is no planted pivot.

	The match disc mirrors the server's canThrow: no charge or release outside
	the Pull (puller) and Live phases (the starter holds the disc through the
	line-up); a press then says why instead of a throw the server ignores.

	A Primary press made after your catch claim but before the server confirms
	it (MovementController.holdingDisc() without the Held folder yet) is kept:
	if the button is still down when the disc becomes yours, the charge starts
	then (CatchController ignores Primary during that window, so no Reach).

	Release: the disc leaves from your pivot foot P (the server's UBPivot, or
	the foot you just planted) plus your step (ThrowModel). The Throw remote
	carries the inputs plus step, pivot, rootPos and releaseT, so ThrowService
	validates and launches from the same place at the same moment; the flight
	is predicted locally at once from the same parameters.

	The preview arc shows the first part of the flight (how much depends on
	the mode: full in training, less in matches). When the mode shows at
	least MARK_PREVIEW of it, the arc turns red from where it would cross a
	visible marker's hands (the same CatchGeometry box the server tests).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local TechConfig = require(Shared.Config.Tech)
local MovementConfig = require(Shared.Config.Movement)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local ThrowModel = require(Shared.Disc.ThrowModel)
local CatchGeometry = require(Shared.Rules.CatchGeometry)
local ComboEvaluator = require(Shared.Rules.ComboEvaluator)
local Actors = require(Shared.Actors)
local VecMath = require(Shared.Util.VecMath)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)
local Abilities = require(Shared.Config.Abilities)

local T = DiscConfig.Throw
local HD = MovementConfig.Holding

local ThrowController = {}

ThrowController.Released = Signal.new() -- (launch, params)
ThrowController.Faked = Signal.new()
ThrowController.Changed = Signal.new()
ThrowController.ChargeLost = Signal.new() -- a charge was cancelled by landing from the hop

local controllers: any
local player = Players.LocalPlayer

local AIM_OFFSET = math.rad(7) -- the camera looks slightly down over the shoulder
local MARK_PREVIEW = 0.35 -- modes showing at least this much of the arc show the mark
local MARKER_RANGE = 14 -- markers this close to P are drawn / tested

local state = {
	throwType = "Backhand", -- what a release right now would be (ThrowModel.shape)
	bank = 0, -- ... and its bend (-1..1 of BankRange, right-handed frame)
	side = 0, -- the sideways input behind it (-1 A .. +1 D)
	charging = false,
	chargeStart = 0,
	aiming = false, -- Secondary held (not charging): the aim view
	releasedAt = -math.huge,
	releasedFlight = -1,
	lastFake = -math.huge,
	heldFolder = nil :: Configuration?,
	holds = 0, -- possessions this session (key hints show for the first few)
	previewBlocked = false,
	pendingCharge = false, -- Primary went down while the catch was only predicted
}

local dots: { BasePart } = {}
local DOT_COUNT = 40
local BLOCK_COLOR = Color3.fromRGB(255, 70, 80)

local function now(): number
	return Net.now()
end

function ThrowController.heldFolder(): Configuration?
	local f = controllers.DiscRenderer.heldByMe()
	if not f then
		return nil
	end
	-- a just-released disc is no longer ours unless the server rejected it
	if os.clock() - state.releasedAt < 0.8 and (f:GetAttribute("FlightId") :: number? or 0) == state.releasedFlight then
		return nil
	end
	return f
end

function ThrowController.isHolding(): boolean
	return ThrowController.heldFolder() ~= nil
end

function ThrowController.isCharging(): boolean
	return state.charging
end

function ThrowController.chargeFraction(): (number, string)
	if not state.charging then
		return 0, "Idle"
	end
	local hold = os.clock() - state.chargeStart
	return math.min(hold / T.ChargeTime, 1.6), ThrowModel.chargePhase(hold, state.throwType)
end

local function airborne(): boolean
	return not controllers.MovementController.isGrounded()
end

local function leftHanded(): boolean
	return controllers.SettingsController.get("LeftHanded") == true
end

-- The pivot the server will release from: its UBPivot, or the foot our sim
-- just planted (its Pivot proposal reaches the server before any throw
-- does). nil = released from the root (still slowing down).
local function serverPivot(): Vector3?
	local c = player.Character
	local pv = c and c:GetAttribute("UBPivot")
	if typeof(pv) == "Vector3" then
		return pv
	end
	return controllers.MovementController.pivot()
end

-- Where the crosshair points: the first thing the camera's centre ray hits
-- (field, a player, a wall) within AIM_RANGE, else a point AIM_FALLBACK
-- ahead. The camera sits over the shoulder, so aiming along its yaw would
-- fly the disc parallel to the crosshair and miss to one side; the throw
-- yaw is aimed from the release point at this point instead.
local AIM_RANGE = 220
local AIM_FALLBACK = 60
local aimRay = RaycastParams.new()
aimRay.FilterType = Enum.RaycastFilterType.Exclude

local function crosshairPoint(): Vector3
	local cf = controllers.CameraController.getCFrame()
	local list: { Instance } = {}
	if player.Character then
		table.insert(list, player.Character)
	end
	local visuals = workspace:FindFirstChild("UBVisuals")
	if visuals then
		table.insert(list, visuals)
	end
	aimRay.FilterDescendantsInstances = list
	local hit = workspace:Raycast(cf.Position, cf.LookVector * AIM_RANGE, aimRay)
	if hit then
		return hit.Position
	end
	return cf.Position + cf.LookVector * AIM_FALLBACK
end

local function yawToward(from: Vector3, to: Vector3, fallback: number): number
	local d = VecMath.flat(to - from)
	if d.Magnitude < 2 then
		return fallback
	end
	return math.atan2(-d.X, -d.Z)
end

-- The aim elevation the throw uses (the camera's, plus the shoulder offset).
local function aimPitch(): number
	return controllers.CameraController.getPitch() + AIM_OFFSET
end

-- Reads what a release right now would be from your inputs: the sideways
-- input (A / D) and how high you aim. The windup pose, the HUD and the
-- preview all follow it live; changing side mid-charge never restarts it.
local function updateShape()
	local input = controllers.InputController
	local side = if input.menuOpen() then 0 else input.rawMove().X
	local hold = if state.charging then os.clock() - state.chargeStart else 0
	local kind, bank = ThrowModel.shape(side, aimPitch(), hold, leftHanded())
	state.side = side
	state.bank = bank
	if kind ~= state.throwType then
		state.throwType = kind
		if state.charging then
			Net.event("ThrowCharge"):FireServer(kind, true)
		end
		ThrowController.Changed:Fire()
	end
end

local function currentParams(holdTime: number): ThrowModel.Params
	local yaw = controllers.CameraController.getYaw()
	local pitch = aimPitch()
	local mc = controllers.MovementController
	local pivot = serverPivot()
	local root = mc.root()
	local step = if pivot then mc.step() else nil
	if root then
		-- converge on the crosshair (the release point depends on the yaw,
		-- so two passes settle it)
		local aim = crosshairPoint()
		local camYaw = yaw
		for _ = 1, 2 do
			local probe: ThrowModel.Params = {
				throwType = state.throwType,
				yaw = yaw,
				pitch = pitch,
				holdTime = holdTime,
				bank = 0,
				height = "Mid",
				leftHanded = leftHanded(),
				pivot = pivot,
				step = step,
			}
			yaw = yawToward(ThrowModel.releasePosition(probe, root.Position), aim, camYaw)
		end
	end
	local body = mc.techState().state
	return {
		throwType = state.throwType,
		yaw = yaw,
		pitch = pitch,
		holdTime = holdTime,
		bank = state.bank,
		height = "Mid",
		offBalance = false,
		-- face down after a layout catch: a weak throw from the ground
		groundThrow = body == "Downed" or body == "Recovering",
		leftHanded = leftHanded(),
		pivot = pivot,
		step = step,
	}
end

-- Opposing markers near P as this client displays them.
type Marker = { pos: Vector3, facing: Vector3, stance: CatchGeometry.MarkStance, jump: number }

local function standOf(model: Model, root: BasePart): number
	local h = model:FindFirstChildOfClass("Humanoid")
	if h and h.RigType == Enum.HumanoidRigType.R15 then
		return h.HipHeight + root.Size.Y / 2
	end
	return 3
end

local function markersNear(origin: Vector3, groundY: number): { Marker }
	local list: { Marker } = {}
	local me = player.Character
	local myTeam = me and me:GetAttribute("UBTeam")
	for _, model in Actors.characters() do
		local role = model:GetAttribute("UBRole")
		-- off the field (bench, spectators) never blocks, as on the server
		if model ~= me and role ~= "Bench" and role ~= "Spectate" then
			local team = model:GetAttribute("UBTeam")
			local mark = model:GetAttribute("Mark")
			local opponent = (team ~= myTeam and team ~= "N") or mark == "Low" or mark == "High"
			local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if opponent and root and VecMath.flat(root.Position - origin).Magnitude < MARKER_RANGE then
				local rise = root.Position.Y - groundY - standOf(model, root)
				table.insert(list, {
					pos = root.Position,
					facing = VecMath.flatUnit(root.CFrame.LookVector),
					stance = if mark == "Low" or mark == "High" then mark else "Relaxed",
					jump = if rise > 0.3 then rise else 0,
				})
			end
		end
	end
	return list
end

local function groundYOf(folder: Configuration?): number
	local g = folder and folder:GetAttribute("GroundY")
	return if type(g) == "number" then g else 0
end

-- The wind the server flies this disc with (its own Wind attribute: the arena
-- wind for match and warm-up discs, none in training).
local function windOf(folder: Configuration?): DiscPhysics.Wind?
	local w = folder and folder:GetAttribute("Wind")
	return if typeof(w) == "Vector3" then { x = w.X, y = w.Y, z = w.Z } else nil
end

-- The open side for the thrower (-1 screen-left, +1 right, 0 unknown): the
-- side the marking team forces (UBState ForceA/B), else read from the
-- marker's shade (a marker stands on the side they take away).
local function openSide(marker: { x: number, y: number }?): (number, string?)
	local c = player.Character
	local team = c and c:GetAttribute("UBTeam")
	local markers = if team == "A" then "B" elseif team == "B" then "A" else nil
	local force = if markers then Net.state():GetAttribute("Force" .. markers) else nil
	if force == "FH" or force == "BH" then
		local fhSide = if leftHanded() then -1 else 1
		return if force == "FH" then fhSide else -fhSide, force
	end
	if marker and math.abs(marker.x) > 0.4 then
		return if marker.x < 0 then 1 else -1, nil
	end
	return 0, nil
end

function ThrowController.hud(): { [string]: any }
	local fraction, phase = ThrowController.chargeFraction()
	local holding = ThrowController.isHolding()
	-- the step gauge, in the throw frame (x = right, y = forward, studs)
	local stepX, stepY = 0, 0
	local marker: { [string]: any }? = nil
	local pivot = serverPivot()
	local root = controllers.MovementController.root()
	if holding and root then
		local forward, right = ThrowModel.basis(controllers.CameraController.getYaw())
		local s = controllers.MovementController.step()
		stepX, stepY = s:Dot(right), s:Dot(forward)
		local origin = pivot or root.Position
		local best, bestD = nil, MARKER_RANGE
		for _, m in markersNear(origin, groundYOf(state.heldFolder)) do
			local d = VecMath.flat(m.pos - origin).Magnitude
			if d < bestD then
				best, bestD = m, d
			end
		end
		if best then
			local rel = best.pos - origin
			local fwd = CatchGeometry.markForward(best.pos, best.facing, origin)
			marker = {
				x = rel:Dot(right),
				y = rel:Dot(forward),
				fx = fwd:Dot(right),
				fy = fwd:Dot(forward),
				stance = best.stance,
				halfWidth = if best.stance == "High"
					then DiscConfig.Mark.HighHalfWidth
					else DiscConfig.Mark.LowHalfWidth,
			}
		end
	end
	local open, force = openSide(marker :: any)
	return {
		holding = holding,
		throwType = state.throwType,
		bank = state.bank, -- -1..1 of BankRange
		aiming = state.aiming,
		airborne = airborne(),
		charge = fraction,
		phase = phase,
		holds = state.holds,
		pivoted = pivot ~= nil,
		stepX = stepX,
		stepY = stepY,
		stepRadius = HD.StepRadius,
		marker = marker,
		openSide = open,
		force = force,
		leftHanded = leftHanded(),
		blocked = state.previewBlocked,
	}
end

-- First time (into the flight) the release crosses a visible marker's hands.
local function previewBlockTime(
	launch: ThrowModel.Launch,
	wind: DiscPhysics.Wind?,
	groundY: number,
	origin: Vector3
): number?
	local markers = markersNear(origin, groundY)
	if #markers == 0 then
		return nil
	end
	local boxes = {}
	for _, m in markers do
		table.insert(boxes, CatchGeometry.markBox(m.pos, m.facing, origin, m.stance, groundY, m.jump))
	end
	local early = DiscPhysics.simulate(launch.state, T.HandBlockCheckTime, wind, groundY, 1)
	for _, s in early.samples do
		local p = Vector3.new(s.x, s.y, s.z)
		for _, box in boxes do
			if CatchGeometry.inMarkBox(box, p) then
				return s.t
			end
		end
	end
	return nil
end

-- The server's canThrow for the match disc: only the puller in the Pull
-- phase and the holder in Live may throw (the starter gets the disc during
-- the line-up). Returns why not, or nil.
local function throwRefusal(folder: Configuration?): string?
	if not folder or folder:GetAttribute("Context") ~= "Match" then
		return nil
	end
	local phase = Net.state():GetAttribute("Phase")
	if phase == "Pull" or phase == "Live" then
		return nil
	end
	return if phase == "PointSetup" then "WAIT FOR THE START" else "NOT NOW"
end

local function refuseThrow(text: string)
	controllers.MovementController.Feedback:Fire({ kind = "Context", text = text })
end

local function release()
	if not state.charging then
		return
	end
	state.charging = false
	local folder = ThrowController.heldFolder()
	local root = controllers.MovementController.root()
	if not folder or not root then
		return
	end
	local refusal = throwRefusal(folder)
	if refusal then
		-- the server would refuse it silently: say so and drop the windup
		Net.event("ThrowCharge"):FireServer(false)
		refuseThrow(refusal)
		ThrowController.Changed:Fire()
		return
	end
	local hold = os.clock() - state.chargeStart
	state.charging = true -- (for the shape's charge share)
	updateShape() -- what you hold on the release frame is what counts
	state.charging = false
	local params = currentParams(hold)
	params.tempest = Abilities.activeOn(player.Character, "TempestThrow", now()) or nil
	if params.tempest then
		controllers.TechFeedback.play("TEMPEST", "Perfect")
		controllers.AnimeFX.impactFrame(Abilities.List.TempestThrow.color)
	end
	params.pinch = controllers.MovementController.pinch()
	if params.pinch then
		controllers.TechFeedback.play(if params.pinch == "Perfect" then "Perfect Pinch" else "Pinch", params.pinch)
	end
	local releaseT = now()
	Net.event("Throw"):FireServer({
		throwType = params.throwType,
		yaw = params.yaw,
		pitch = params.pitch,
		holdTime = params.holdTime,
		bank = params.bank,
		height = params.height,
		offBalance = params.offBalance,
		groundThrow = params.groundThrow,
		step = params.step,
		pivot = params.pivot,
		pinch = params.pinch,
		tempest = params.tempest,
		releaseT = releaseT,
		rootPos = root.Position,
	})
	local launch = ThrowModel.launch(params, root.Position, root.AssemblyLinearVelocity)
	local id = folder:GetAttribute("Id") :: string
	-- if your own view says the mark gets it, the predicted disc stops at the hands
	local wind = windOf(folder)
	local blockT = if folder:GetAttribute("Context") == "Match"
		then previewBlockTime(launch, wind, groundYOf(folder), serverPivot() or root.Position)
		else nil
	controllers.DiscRenderer.predictThrow(id, launch.state, releaseT, blockT)
	state.releasedAt = os.clock()
	state.releasedFlight = (folder:GetAttribute("FlightId") :: number?) or 0

	-- fake -> Sold swing -> release: the Break link
	local mc = controllers.MovementController
	local breakQ = ComboEvaluator.breakQuality(mc.combo(), releaseT)
	if breakQ then
		local forward = ThrowModel.basis(params.yaw)
		mc.addTech("Break", breakQ, forward, nil)
	end

	local c = player.Character
	if c then
		c:SetAttribute("UB_LocalRelease", now())
		c:SetAttribute("UB_LocalWindup", 0)
	end
	ThrowController.Released:Fire(launch, params)
	ThrowController.Changed:Fire()
end

-- The pump fake: Secondary during a charge. The throw is cancelled; the
-- windup everyone saw was a real one. It leans toward the side you hold.
local function fake()
	if not state.charging or os.clock() - state.lastFake < T.FakeCooldown then
		return
	end
	state.lastFake = os.clock()
	state.charging = false
	local side = if state.side > T.BendInput then 1 elseif state.side < -T.BendInput then -1 else 0
	Net.event("Fake"):FireServer(state.throwType, side)
	local c = player.Character
	if c then
		c:SetAttribute("UB_LocalFake", now())
		c:SetAttribute("UB_LocalWindupType", state.throwType)
	end
	controllers.AudioController.play("Fake", 0.08)
	ThrowController.Faked:Fire()
	ThrowController.Changed:Fire()
end

local function previewFraction(folder: Configuration): number
	local context = folder:GetAttribute("Context")
	if context ~= "Match" then
		return 1
	end
	local f = Net.state():GetAttribute("PreviewFraction")
	return if type(f) == "number" then f else 0.5
end

local function hideDots()
	for _, d in dots do
		d.Transparency = 1
	end
	state.previewBlocked = false
end

local function drawPreview(folder: Configuration)
	if not controllers.SettingsController.get("TrajectoryPreview") then
		hideDots()
		return
	end
	local root = controllers.MovementController.root()
	if not root then
		hideDots()
		return
	end
	local hold: number
	if state.charging then
		hold = os.clock() - state.chargeStart
	else
		hold = T.ChargeTime * T.SnapPoint -- not charging: what a Snap would do
	end
	local params = currentParams(hold)
	local launch = ThrowModel.launch(params, root.Position, root.AssemblyLinearVelocity)
	local wind = windOf(folder)
	local groundY = groundYOf(folder)
	local result = DiscPhysics.simulate(launch.state, 8, wind, groundY, 6)
	local total = result.landT
	local fraction = previewFraction(folder)
	local limit = total * fraction
	local origin = serverPivot() or root.Position
	local blockT = if fraction >= MARK_PREVIEW then previewBlockTime(launch, wind, groundY, origin) else nil
	state.previewBlocked = blockT ~= nil
	local _, phase = ThrowController.chargeFraction()
	local color = if phase == "Perfect"
		then Color3.fromRGB(255, 215, 80)
		elseif phase == "Over" then Color3.fromRGB(255, 90, 100)
		else Color3.fromRGB(230, 245, 255)
	local idx = 0
	local nextT = 0
	for _, s in result.samples do
		if s.t > limit or idx >= DOT_COUNT then
			break
		end
		if s.t >= nextT then
			idx += 1
			local d = dots[idx]
			d.Position = Vector3.new(s.x, s.y, s.z)
			d.Color = if blockT and s.t >= blockT then BLOCK_COLOR else color
			d.Transparency = 0.15 + 0.6 * (s.t / math.max(limit, 0.01))
			nextT = s.t + 0.07
		end
	end
	for i = idx + 1, DOT_COUNT do
		dots[i].Transparency = 1
	end
end

local function setAiming(on: boolean)
	if on ~= state.aiming then
		state.aiming = on
		controllers.CameraController.setAim(on)
		ThrowController.Changed:Fire()
	end
end

local function beginCharge()
	local refusal = throwRefusal(ThrowController.heldFolder())
	if refusal then
		refuseThrow(refusal)
		return
	end
	if os.clock() - state.lastFake < T.FakeRecovery then
		return -- still recovering from the fake
	end
	state.charging = true
	state.chargeStart = os.clock()
	updateShape()
	Net.event("ThrowCharge"):FireServer(state.throwType)
	if controllers.CatchController.hotHands() then
		-- Hot Hands: a Perfect Catch skips the charge, out at 70 % at once
		state.chargeStart = os.clock() - T.ChargeTime * TechConfig.HOT_HANDS_POWER
		controllers.TechFeedback.play("Hot Hands", "Perfect")
		release()
	end
end

local function step()
	local folder = ThrowController.heldFolder()
	if not folder and not controllers.MovementController.holdingDisc() then
		state.pendingCharge = false -- the predicted catch was denied / expired
	end
	if folder ~= state.heldFolder then
		state.heldFolder = folder
		if folder then
			state.holds += 1
			-- a press made while the catch was still predicted charges now
			-- (InputController never repeats the "began" of a held button)
			if state.pendingCharge and controllers.InputController.isHeld("Primary") then
				beginCharge()
			end
			state.pendingCharge = false
		else
			state.charging = false
			setAiming(false)
		end
		ThrowController.Changed:Fire()
	end
	if not folder then
		hideDots()
		return
	end
	updateShape()
	drawPreview(folder)
	local c = player.Character
	if c then
		c:SetAttribute("UB_LocalWindup", if state.charging then state.chargeStart else 0)
		c:SetAttribute("UB_LocalWindupType", state.throwType)
	end
end

function ThrowController.Init(c: any)
	controllers = c
end

function ThrowController.Start()
	local visuals = workspace:WaitForChild("UBVisuals")
	for i = 1, DOT_COUNT do
		local d = Instance.new("Part")
		d.Name = "PreviewDot"
		d.Shape = Enum.PartType.Ball
		d.Size = Vector3.new(0.35, 0.35, 0.35)
		d.Anchored = true
		d.CanCollide = false
		d.CanQuery = false
		d.CanTouch = false
		d.CastShadow = false
		d.Material = Enum.Material.Neon
		d.Transparency = 1
		d.Parent = visuals
		dots[i] = d
	end

	local input = controllers.InputController
	input.ActionBegan:Connect(function(action)
		if not ThrowController.isHolding() then
			if action == "Primary" and controllers.MovementController.holdingDisc() then
				-- caught, but the server has not confirmed yet: charge on confirm
				state.pendingCharge = true
			end
			return
		end
		if action == "Primary" then
			if not state.charging then
				beginCharge()
			end
		elseif action == "Secondary" then
			if state.charging then
				fake()
			else
				setAiming(true)
			end
		end
	end)
	input.ActionEnded:Connect(function(action)
		if action == "Primary" then
			state.pendingCharge = false
			release()
		elseif action == "Secondary" then
			setAiming(false)
		end
	end)
	RunService:BindToRenderStep("UBThrow", Enum.RenderPriority.Camera.Value + 4, step)
end

return ThrowController
