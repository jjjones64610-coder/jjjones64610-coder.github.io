--!strict
--[[
	Locomotion — base-layer animation driven by ACTUAL velocity, so the legs
	always match what the body is really doing (the movement engine decides
	speed itself; Humanoid.WalkSpeed is just its output).

	Uses Roblox's own default R15/R6 animation assets, which every experience
	may use. The procedural PoseController layers leans, plants, slides,
	layouts, the pivot lunge, mark stances, reaches and throws on top by
	offsetting Motor6D.C0.

	On the ground idle, walk and run all keep playing and are cross-weighted
	(no Stop/Play when speed wobbles, so strides never restart):
	  * walk weight 1 up to 7 studs/s, run weight 1 from 12, linear between
	  * time-warp walk = speed / 6.4, run = speed / 12.8 (the speeds the
	    default cycles are authored for), divided by the body height scale;
	    clamped walk 0.5..2.0, run 0.7..2.4 — feet do not skate
	  * idle with hysteresis: in below 0.6 studs/s, out above 1.5
	Tracks only start / stop on real mode changes (ground, rising, falling,
	pose). "Pose" (slides, dives, the pivot, the mark shuffle) plays the idle
	layer only and lets PoseController own the body.

	Runs on the client for the local character (src/character/Animate; tracks
	on the character's own Animator replicate to everyone) and on the server
	for bots.
]]

local RunService = game:GetService("RunService")

local Locomotion = {}

local R15 = {
	idle = "rbxassetid://507766666",
	idle2 = "rbxassetid://507766951",
	walk = "rbxassetid://913402848",
	run = "rbxassetid://913376220",
	jump = "rbxassetid://507765000",
	fall = "rbxassetid://507767968",
}

local R6 = {
	idle = "rbxassetid://180435571",
	idle2 = "rbxassetid://180435792",
	walk = "rbxassetid://180426354",
	run = "rbxassetid://180426354",
	jump = "rbxassetid://125750702",
	fall = "rbxassetid://180436148",
}

-- blend / time-warp (studs per second, before the height scale)
local WALK_FULL = 7 -- walk weight 1 up to here
local RUN_FULL = 12 -- run weight 1 from here
local WALK_AUTHORED = 6.4 -- the walk cycle matches the ground at this speed
local RUN_AUTHORED = 12.8
local IDLE_ENTER = 0.6
local IDLE_LEAVE = 1.5
local SMALL = 0.0001 -- "off" weight that keeps a track playing (0 is unreliable)
local POSE_IDLE_SPEED = 0.7

local GROUND = { "idle", "walk", "run" }

export type Mode = "Ground" | "Rising" | "Falling" | "Pose"

export type Controller = {
	humanoid: Humanoid,
	tracks: { [string]: AnimationTrack },
	weights: { [string]: number }, -- last weight sent per track
	speeds: { [string]: number }, -- last speed sent per track
	current: string?, -- the single non-ground track playing (jump / fall / pose idle)
	mode: Mode?,
	idle: boolean,
	idleTimer: number,
	scale: NumberValue?,
}

local function getAnimator(humanoid: Humanoid): Animator
	local existing = humanoid:FindFirstChildOfClass("Animator")
	if existing then
		return existing
	end
	if RunService:IsClient() then
		-- the server-made Animator replicates; one made here would not
		local waited = humanoid:WaitForChild("Animator", 5) :: Instance?
		if waited and waited:IsA("Animator") then
			return waited
		end
	end
	local animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

function Locomotion.new(humanoid: Humanoid): Controller
	local ids: { [string]: string } = if humanoid.RigType == Enum.HumanoidRigType.R15 then R15 else R6
	local animator = getAnimator(humanoid)
	local tracks: { [string]: AnimationTrack } = {}
	for name, id in ids do
		local anim = Instance.new("Animation")
		anim.Name = "UB_" .. name
		anim.AnimationId = id
		local ok, track = pcall(function()
			return animator:LoadAnimation(anim)
		end)
		if ok and track then
			track.Priority = Enum.AnimationPriority.Core
			track.Looped = name ~= "jump"
			tracks[name] = track
		end
	end
	return {
		humanoid = humanoid,
		tracks = tracks,
		weights = {},
		speeds = {},
		current = nil,
		mode = nil,
		idle = true,
		idleTimer = 0,
		scale = nil,
	}
end

-- Body height scale (R15 BodyHeightScale value), so tall avatars take longer strides.
local function heightScale(c: Controller): number
	if c.humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return 1
	end
	local v = c.scale
	if v == nil or v.Parent ~= c.humanoid then
		local found = c.humanoid:FindFirstChild("BodyHeightScale")
		v = if found and found:IsA("NumberValue") then found else nil
		c.scale = v
	end
	return if v then math.clamp(v.Value, 0.5, 2) else 1
end

-- Weight / speed changes are only sent when they matter (they replicate).
local function setWeight(c: Controller, name: string, weight: number, fade: number)
	local track = c.tracks[name]
	if not track then
		return
	end
	local last = c.weights[name]
	if last == nil or math.abs(last - weight) > 0.03 or (weight <= SMALL and last > SMALL) then
		track:AdjustWeight(weight, fade)
		c.weights[name] = weight
	end
end

local function setSpeed(c: Controller, name: string, speed: number)
	local track = c.tracks[name]
	if not track then
		return
	end
	local last = c.speeds[name]
	if last == nil or math.abs(last - speed) > math.max(0.03 * last, 0.01) then
		track:AdjustSpeed(speed)
		c.speeds[name] = speed
	end
end

local function start(c: Controller, name: string, fade: number, weight: number, speed: number)
	local track = c.tracks[name]
	if not track then
		return
	end
	if not track.IsPlaying then
		track:Play(fade, weight, speed)
	else
		track:AdjustWeight(weight, fade)
		track:AdjustSpeed(speed)
	end
	c.weights[name] = weight
	c.speeds[name] = speed
end

local function stop(c: Controller, name: string, fade: number)
	local track = c.tracks[name]
	if track and track.IsPlaying then
		track:Stop(fade)
	end
	c.weights[name] = nil
	c.speeds[name] = nil
end

local function stopGround(c: Controller, fade: number)
	for _, name in GROUND do
		stop(c, name, fade)
	end
end

-- The only real track switches: entering a mode.
local function enter(c: Controller, mode: Mode)
	c.mode = mode
	if mode == "Ground" then
		stop(c, "jump", 0.15)
		stop(c, "fall", 0.15)
		c.current = nil
		-- weights are set by the blend right after
		start(c, "idle", 0.15, if c.idle then 1 else SMALL, 1)
		start(c, "walk", 0.15, SMALL, 1)
		start(c, "run", 0.15, SMALL, 1)
	elseif mode == "Rising" then
		stopGround(c, 0.1)
		stop(c, "fall", 0.1)
		start(c, "jump", 0.1, 1, 1)
		c.current = "jump"
	elseif mode == "Falling" then
		stopGround(c, 0.2)
		stop(c, "jump", 0.2)
		start(c, "fall", 0.2, 1, 1)
		c.current = "fall"
	else -- Pose: the procedural layer owns the body over a calm idle
		stop(c, "walk", 0.15)
		stop(c, "run", 0.15)
		stop(c, "jump", 0.15)
		stop(c, "fall", 0.15)
		start(c, "idle", 0.15, 1, POSE_IDLE_SPEED)
		c.current = "idle"
	end
end

local function blendGround(c: Controller, dt: number, speed: number)
	if c.idle then
		if speed > IDLE_LEAVE then
			c.idle = false
		end
	elseif speed < IDLE_ENTER then
		c.idle = true
	end
	local s = speed / heightScale(c)
	if c.idle then
		c.idleTimer += dt
		setWeight(c, "idle", 1, 0.25)
		setWeight(c, "walk", SMALL, 0.25)
		setWeight(c, "run", SMALL, 0.25)
		setSpeed(c, "idle", 1)
		return
	end
	c.idleTimer = 0
	local runW = math.clamp((s - WALK_FULL) / (RUN_FULL - WALK_FULL), 0, 1)
	setWeight(c, "idle", SMALL, 0.15)
	setWeight(c, "walk", math.max(1 - runW, SMALL), 0.1)
	setWeight(c, "run", math.max(runW, SMALL), 0.1)
	setSpeed(c, "walk", math.clamp(s / WALK_AUTHORED, 0.5, 2.0))
	setSpeed(c, "run", math.clamp(s / RUN_AUTHORED, 0.7, 2.4))
end

-- speed: horizontal studs/s. mode: Ground / Rising / Falling / Pose (Pose =
-- procedural layer owns the body; base layer settles to a neutral idle).
function Locomotion.update(c: Controller, dt: number, speed: number, mode: Mode)
	if mode ~= c.mode then
		enter(c, mode)
	end
	if mode == "Ground" then
		blendGround(c, dt, speed)
	end
end

function Locomotion.destroy(c: Controller)
	for _, t in c.tracks do
		t:Stop(0)
		t:Destroy()
	end
	table.clear(c.tracks)
	table.clear(c.weights)
	table.clear(c.speeds)
end

return Locomotion
