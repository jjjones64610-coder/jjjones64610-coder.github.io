--!strict
--[[
	ThrowController — everything you do with the disc in your hand.

	  hold Primary      charge (power rises to full at ChargeTime; release in
	                    the Perfect window for +speed/+spin; holding longer
	                    bleeds spin = a wobblier line)
	  Secondary         pump fake (same windup the defender sees on a real throw)
	  Q / E             bank the disc left / right (curves the flight)
	  1-5, wheel, Z/X   throw type
	  hold Slide key    low release (step out under the mark)
	  Jump              hop -> high release over the mark (must release before landing)
	  R                 Lead Pass assist: aims at the teammate nearest your
	                    crosshair using their CURRENT velocity and marks the
	                    ideal power on the meter; timing the release is still on you

	The preview arc shows the first part of the flight (how much depends on the
	mode: full in training, half in casual, a fifth in ranked).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DiscConfig = require(Shared.Config.Disc)
local DiscPhysics = require(Shared.Disc.DiscPhysics)
local ThrowModel = require(Shared.Disc.ThrowModel)
local Solver = require(Shared.Disc.Solver)
local Actors = require(Shared.Actors)
local VecMath = require(Shared.Util.VecMath)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net)

local T = DiscConfig.Throw

local ThrowController = {}

ThrowController.Released = Signal.new() -- (launch, params)
ThrowController.Faked = Signal.new()
ThrowController.Changed = Signal.new()

local controllers: any
local player = Players.LocalPlayer

local AIM_OFFSET = math.rad(7) -- the camera looks slightly down over the shoulder
local BANK_STEPS = 3

local state = {
	throwType = "Backhand",
	bankStep = 0,
	low = false,
	charging = false,
	chargeStart = 0,
	releasedAt = -math.huge,
	releasedFlight = -1,
	leadLock = false,
	leadTarget = nil :: number?,
	leadSolution = nil :: Solver.Solution?,
	lastSolve = 0,
	lastFake = 0,
	heldFolder = nil :: Configuration?,
}

local dots: { BasePart } = {}
local DOT_COUNT = 40

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
	local power, quality = ThrowModel.charge(hold, state.throwType)
	local info = ThrowModel.typeInfo(state.throwType)
	local t = hold * (info.ChargeMult or 1)
	return math.min(t / T.ChargeTime, 1.6), if quality == "Clean" and power < 1 then "Charging" else quality
end

local function airborne(): boolean
	return not controllers.MovementController.isGrounded()
end

local function releaseHeight(): string
	if state.low then
		return "Low"
	end
	if airborne() then
		return "High"
	end
	return "Mid"
end

local function currentParams(holdTime: number): ThrowModel.Params
	local yaw = controllers.CameraController.getYaw()
	local pitch = controllers.CameraController.getPitch() + AIM_OFFSET
	local sol = state.leadSolution
	if state.leadLock and sol then
		yaw = sol.params.yaw
		pitch = sol.params.pitch
	end
	local sim = controllers.MovementController.sim()
	local height = releaseHeight()
	return {
		throwType = state.throwType,
		yaw = yaw,
		pitch = pitch,
		holdTime = holdTime,
		bank = state.bankStep / BANK_STEPS,
		height = height,
		offBalance = airborne() and height ~= "High",
		groundThrow = sim.mode == "DiveSlide" or sim.mode == "Recover",
		leftHanded = controllers.SettingsController.get("LeftHanded") == true,
	}
end

function ThrowController.hud(): { [string]: any }
	local fraction, phase = ThrowController.chargeFraction()
	local idealPower: number? = nil
	local sol = state.leadSolution
	if state.leadLock and sol then
		idealPower = math.clamp(
			sol.params.holdTime / T.ChargeTime * (ThrowModel.typeInfo(state.throwType).ChargeMult or 1),
			0,
			1
		)
	end
	return {
		holding = ThrowController.isHolding(),
		throwType = state.throwType,
		bank = state.bankStep,
		bankSteps = BANK_STEPS,
		height = releaseHeight(),
		charge = fraction,
		phase = phase,
		leadLock = state.leadLock,
		leadName = if state.leadTarget then Actors.nameOf(state.leadTarget) else nil,
		idealPower = idealPower,
	}
end

local function setType(t: string)
	if (DiscConfig.Types :: any)[t] and t ~= state.throwType then
		state.throwType = t
		if state.charging then
			-- switching mid-charge restarts the windup (no type-switch exploits)
			state.chargeStart = os.clock()
			Net.event("ThrowCharge"):FireServer(t)
		end
		ThrowController.Changed:Fire()
	end
end

local function cycleType(delta: number)
	local order = DiscConfig.TypeOrder
	local i = table.find(order, state.throwType) or 1
	i = ((i - 1 + delta) % #order) + 1
	setType(order[i])
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
	local hold = os.clock() - state.chargeStart
	local params = currentParams(hold)
	Net.event("Throw"):FireServer({
		throwType = params.throwType,
		yaw = params.yaw,
		pitch = params.pitch,
		holdTime = params.holdTime,
		bank = params.bank,
		height = params.height,
	})
	local launch = ThrowModel.launch(params, root.Position, root.AssemblyLinearVelocity)
	local id = folder:GetAttribute("Id") :: string
	controllers.DiscRenderer.predictThrow(id, launch.state)
	state.releasedAt = os.clock()
	state.releasedFlight = (folder:GetAttribute("FlightId") :: number?) or 0
	local c = player.Character
	if c then
		c:SetAttribute("UB_LocalRelease", now())
		c:SetAttribute("UB_LocalWindup", 0)
	end
	ThrowController.Released:Fire(launch, params)
	ThrowController.Changed:Fire()
end

local function fake()
	if os.clock() - state.lastFake < T.FakeCooldown then
		return
	end
	state.lastFake = os.clock()
	state.charging = false
	Net.event("Fake"):FireServer(state.throwType)
	local c = player.Character
	if c then
		c:SetAttribute("UB_LocalFake", now())
		c:SetAttribute("UB_LocalWindupType", state.throwType)
	end
	ThrowController.Faked:Fire()
end

-- picks the teammate closest to the crosshair and solves a lead pass
local function updateLead()
	if not state.leadLock then
		return
	end
	local root = controllers.MovementController.root()
	local c = player.Character
	if not root or not c then
		return
	end
	local myTeam = c:GetAttribute("UBTeam")
	local aim = controllers.CameraController.getAimDirection()
	local best, bestDot = nil, math.cos(math.rad(35))
	for _, model in Actors.characters() do
		if model ~= c and (model:GetAttribute("UBTeam") == myTeam or myTeam == "N") then
			local r = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r then
				local dir = (r.Position - root.Position)
				if dir.Magnitude > 6 then
					local d = aim:Dot(dir.Unit)
					if d > bestDot then
						best, bestDot = model, d
					end
				end
			end
		end
	end
	local id = if best then Actors.idOf(best) else nil
	state.leadTarget = id
	if not best or os.clock() - state.lastSolve < 0.2 then
		if not best then
			state.leadSolution = nil
		end
		return
	end
	state.lastSolve = os.clock()
	local r = (best :: Model):FindFirstChild("HumanoidRootPart") :: BasePart
	local w = Net.state():GetAttribute("Wind")
	local wind = if typeof(w) == "Vector3" then { x = w.X, y = w.Y, z = w.Z } else nil
	local sol = Solver.solve({
		rootPos = root.Position,
		throwerVel = root.AssemblyLinearVelocity,
		throwType = state.throwType,
		bank = state.bankStep / BANK_STEPS,
		height = releaseHeight(),
		target = r.Position + Vector3.new(0, 1, 0),
		targetVel = VecMath.flat(r.AssemblyLinearVelocity),
		wind = wind,
		groundY = 0,
		coarse = true,
		leftHanded = controllers.SettingsController.get("LeftHanded") == true,
	})
	-- only offer a lead when a catchable pass exists
	state.leadSolution = if sol and sol.miss <= 4 then sol else nil
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
	elseif state.leadLock and state.leadSolution then
		hold = (state.leadSolution :: Solver.Solution).params.holdTime
	else
		hold = T.ChargeTime * 0.6 / (ThrowModel.typeInfo(state.throwType).ChargeMult or 1)
	end
	local params = currentParams(hold)
	local launch = ThrowModel.launch(params, root.Position, root.AssemblyLinearVelocity)
	local w = Net.state():GetAttribute("Wind")
	local wind = if typeof(w) == "Vector3" then { x = w.X, y = w.Y, z = w.Z } else nil
	local result = DiscPhysics.simulate(launch.state, 8, wind, 0, 6)
	local total = result.landT
	local fraction = previewFraction(folder)
	local limit = total * fraction
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
			d.Color = color
			d.Transparency = 0.15 + 0.6 * (s.t / math.max(limit, 0.01))
			nextT = s.t + 0.07
		end
	end
	for i = idx + 1, DOT_COUNT do
		dots[i].Transparency = 1
	end
end

local function step()
	local folder = ThrowController.heldFolder()
	if folder ~= state.heldFolder then
		state.heldFolder = folder
		if not folder then
			state.charging = false
			state.leadSolution = nil
		end
		ThrowController.Changed:Fire()
	end
	if not folder then
		hideDots()
		return
	end
	updateLead()
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
			if action == "Celebrate" then
				Net.event("Action"):FireServer("Celebrate", nil)
			end
			return
		end
		if action == "Primary" then
			state.charging = true
			state.chargeStart = os.clock()
			Net.event("ThrowCharge"):FireServer(state.throwType)
		elseif action == "Secondary" then
			fake()
		elseif action == "BankLeft" then
			state.bankStep = math.max(-BANK_STEPS, state.bankStep - 1)
			ThrowController.Changed:Fire()
		elseif action == "BankRight" then
			state.bankStep = math.min(BANK_STEPS, state.bankStep + 1)
			ThrowController.Changed:Fire()
		elseif action == "TypeNext" then
			cycleType(1)
		elseif action == "TypePrev" then
			cycleType(-1)
		elseif string.sub(action, 1, 4) == "Type" then
			local n = tonumber(string.sub(action, 5))
			if n and DiscConfig.TypeOrder[n] then
				setType(DiscConfig.TypeOrder[n])
			end
		elseif action == "Slide" then
			state.low = true
			ThrowController.Changed:Fire()
		elseif action == "LeadLock" then
			state.leadLock = not state.leadLock
			state.leadSolution = nil
			ThrowController.Changed:Fire()
		end
	end)
	input.ActionEnded:Connect(function(action)
		if action == "Primary" then
			release()
		elseif action == "Slide" then
			state.low = false
			ThrowController.Changed:Fire()
		end
	end)
	input.Wheel:Connect(function(delta)
		if ThrowController.isHolding() then
			cycleType(if delta > 0 then -1 else 1)
		end
	end)
	controllers.MovementController.Feedback:Connect(function(fb)
		if fb.kind == "Travel" and state.charging then
			state.charging = false
		end
	end)
	RunService:BindToRenderStep("UBThrow", Enum.RenderPriority.Camera.Value + 4, step)
end

return ThrowController
