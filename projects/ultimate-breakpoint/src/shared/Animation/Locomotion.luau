--!strict
--[[
	Locomotion — base-layer animation driven by ACTUAL velocity, not by
	Humanoid.WalkSpeed (our movement engine sets velocity directly, so the
	default Animate script would not know we are running).

	Uses Roblox's own default R15/R6 animation assets, which every experience
	may use. The procedural PoseController layers leans, dives, slides, reaches
	and throws on top of this by offsetting Motor6D.C0.

	Runs on the client for the local character (src/character/Animate) and on
	the server for bots (animations played by the server replicate).
]]

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

export type Mode = "Ground" | "Rising" | "Falling" | "Pose"

export type Controller = {
	humanoid: Humanoid,
	tracks: { [string]: AnimationTrack },
	weights: { [string]: number },
	current: string?,
	mode: Mode,
	idleTimer: number,
}

local function getAnimator(humanoid: Humanoid): Animator
	local existing = humanoid:FindFirstChildOfClass("Animator")
	if existing then
		return existing
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
		current = nil,
		mode = "Ground",
		idleTimer = 0,
	}
end

local function play(c: Controller, name: string, fade: number, speed: number)
	local track = c.tracks[name]
	if not track then
		return
	end
	if c.current ~= name then
		local prev = c.current
		if prev and c.tracks[prev] then
			c.tracks[prev]:Stop(fade)
		end
		track:Play(fade, 1, speed)
		c.current = name
	else
		track:AdjustSpeed(speed)
	end
end

-- speed: horizontal studs/s. mode: Ground / Rising / Falling / Pose (Pose =
-- procedural layer owns the body; base layer settles to a neutral idle).
function Locomotion.update(c: Controller, dt: number, speed: number, mode: Mode)
	c.mode = mode
	if mode == "Rising" then
		play(c, "jump", 0.1, 1)
		return
	elseif mode == "Falling" then
		play(c, "fall", 0.2, 1)
		return
	elseif mode == "Pose" then
		play(c, "idle", 0.15, 0.5)
		return
	end
	if speed < 0.8 then
		c.idleTimer += dt
		play(c, "idle", 0.2, 1)
	elseif speed < 11 then
		c.idleTimer = 0
		play(c, "walk", 0.15, math.clamp(speed / 10, 0.5, 1.4))
	else
		c.idleTimer = 0
		-- default run cycle is authored for ~16 studs/s
		play(c, "run", 0.15, math.clamp(speed / 16, 0.8, 1.9))
	end
end

function Locomotion.destroy(c: Controller)
	for _, t in c.tracks do
		t:Stop(0)
		t:Destroy()
	end
	table.clear(c.tracks)
end

return Locomotion
