--!strict
-- Replaces Roblox's default "Animate" script (same name in
-- StarterCharacterScripts). Plays base locomotion (Shared/Animation/Locomotion)
-- from the character's real, lightly smoothed velocity, so animation always
-- matches the movement engine. The local MovementController publishes its
-- pose mode in the "UB_LocalMode" attribute: slides, dives, the dive recovery,
-- the disc holder's pivot ("Pivot") and the mark shuffle ("Mark") use the
-- pose layer (calm idle under PoseController), never the walk cycle.
-- Short airborne blips (a step down, a bump) do not switch to the fall
-- animation: only a real jump or more than AIR_GRACE seconds in the air does.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local character = script.Parent :: Model
local humanoid = character:WaitForChild("Humanoid") :: Humanoid
local root = character:WaitForChild("HumanoidRootPart") :: BasePart

local Locomotion =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Animation"):WaitForChild("Locomotion"))

local controller = Locomotion.new(humanoid)

local POSE_MODES = {
	Slide = true,
	Dive = true,
	DiveSlide = true,
	Recover = true,
	Pivot = true,
	Mark = true,
}

local AIR_GRACE = 0.12
local SPEED_RATE = 20 -- smoothing of the measured speed (1/s)

local speed = 0
local airSince: number? = nil

local connection = RunService.Heartbeat:Connect(function(dt)
	if humanoid.Health <= 0 then
		return
	end
	local v = root.AssemblyLinearVelocity
	local raw = Vector3.new(v.X, 0, v.Z).Magnitude
	speed += (raw - speed) * (1 - math.exp(-SPEED_RATE * dt))

	local localMode = character:GetAttribute("UB_LocalMode")
	local state = humanoid:GetState()
	local airborne = state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping
	local clock = os.clock()
	if airborne then
		airSince = airSince or clock
	else
		airSince = nil
	end

	local mode: Locomotion.Mode = "Ground"
	if type(localMode) == "string" and POSE_MODES[localMode] then
		mode = "Pose"
	elseif airborne and (state == Enum.HumanoidStateType.Jumping or clock - (airSince :: number) > AIR_GRACE) then
		mode = if v.Y > 2 then "Rising" else "Falling"
	end
	Locomotion.update(controller, dt, speed, mode)
end)

humanoid.Died:Connect(function()
	connection:Disconnect()
	Locomotion.destroy(controller)
end)
