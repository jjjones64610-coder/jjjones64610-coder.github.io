--!strict
--[[
	CatchController — catching, reaching and marking for the local player.

	Contact is detected here, where your body is exactly where you see it and
	the disc is at shared server time. Each frame the disc's path since the
	last frame is swept against your catch zones (CatchGeometry, the same
	module the server validates with); on contact a claim stamped with server
	time is sent and the disc snaps to your hand immediately (prediction). The
	server's verdict follows within a round trip.

	Reach (Primary while not holding): opens a 0.28 s window where your hand
	extends toward your aim. A light assist bends the reach toward a disc that
	is close and roughly where you are looking, so it reads naturally.
	Mark stance (hold Secondary): hands up; aim up/down for High/Low.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local CatchGeometry = require(Shared.Rules.CatchGeometry)
local VecMath = require(Shared.Util.VecMath)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local C = DiscConfig.Catch

local CatchController = {}

CatchController.Reached = Signal.new() -- (dir)
CatchController.Claimed = Signal.new() -- (discId, zoneKind)

local controllers: any
local player = Players.LocalPlayer

local reachAt = -math.huge
local reachDir = Vector3.new(0, 0, -1)
local marking = false
local markStance = "Low"
local lastAim = 0
local lastClaim: { [string]: number } = {}
local lastSample: { [string]: Vector3 } = {}

local function now(): number
	return Net.now()
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

local function setMarking(on: boolean)
	if marking == on then
		return
	end
	marking = on
	local pitch = controllers.CameraController.getPitch()
	markStance = if pitch > math.rad(12) then "High" else "Low"
	Net.event("MarkStance"):FireServer(on, markStance)
	local c = player.Character
	if c then
		c:SetAttribute("UB_LocalMark", if on then markStance else "")
	end
end

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

local function step()
	local root = controllers.MovementController.root()
	if not root then
		return
	end
	-- mark stance aim stream (10 Hz)
	if marking then
		local t = os.clock()
		if t - lastAim > 0.1 then
			lastAim = t
			local pitch = controllers.CameraController.getPitch()
			Net.unreliable("MarkAim"):FireServer(pitch)
			local stance = if pitch > math.rad(12) then "High" else "Low"
			if stance ~= markStance then
				markStance = stance
				local c = player.Character
				if c then
					c:SetAttribute("UB_LocalMark", stance)
				end
			end
		end
	end
	if controllers.ThrowController.isHolding() then
		return
	end
	local zones = CatchGeometry.zones(bodyState(root))
	local tNow = now()
	for _, folder in controllers.DiscRenderer.folders() do
		local id = folder:GetAttribute("Id") :: string
		local sim, launchTime, _, _, landed = controllers.DiscRenderer.flight(id)
		if sim and not landed and canClaim(folder) then
			local thrower = folder:GetAttribute("ThrowerId")
			local noCatch = launchTime + DiscConfig.Throw.NoCatchTime
			if thrower ~= player.UserId and tNow >= noCatch then
				local x, y, z = DiscPhysics.positionAt(sim, tNow - launchTime)
				local p = Vector3.new(x, y, z)
				local prev = lastSample[id] or p
				lastSample[id] = p
				-- sweep the path travelled since last frame
				local hitEval = nil
				for k = 1, 3 do
					local sample = prev:Lerp(p, k / 3)
					local ev = CatchGeometry.evaluate(zones, sample)
					if ev then
						hitEval = ev
						break
					end
				end
				if hitEval and (lastClaim[id] or 0) < os.clock() - 0.12 then
					lastClaim[id] = os.clock()
					Net.event("Catch"):FireServer(id, tNow, hitEval.zone.kind, reachDir)
					controllers.DiscRenderer.predictCatch(id)
					CatchController.Claimed:Fire(id, hitEval.zone.kind)
				end
			end
		else
			lastSample[id] = nil
		end
	end
end

function CatchController.Init(c: any)
	controllers = c
end

function CatchController.Start()
	controllers.InputController.ActionBegan:Connect(function(action)
		if controllers.ThrowController.isHolding() then
			return
		end
		if action == "Primary" then
			CatchController.reach()
		elseif action == "Secondary" then
			setMarking(true)
		end
	end)
	controllers.InputController.ActionEnded:Connect(function(action)
		if action == "Secondary" then
			setMarking(false)
		end
	end)
	player.CharacterAdded:Connect(function()
		marking = false
		reachAt = -math.huge
	end)
	RunService:BindToRenderStep("UBCatch", Enum.RenderPriority.Camera.Value + 3, step)
end

return CatchController
