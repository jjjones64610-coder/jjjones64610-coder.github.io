--!strict
-- Replaces Roblox's default "Animate" script (same name in
-- StarterCharacterScripts). Plays base locomotion from the character's real
-- velocity so animation always matches the movement engine. The local
-- MovementController publishes its mode in the "UB_LocalMode" attribute.

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
}

local connection = RunService.Heartbeat:Connect(function(dt)
	if humanoid.Health <= 0 then
		return
	end
	local v = root.AssemblyLinearVelocity
	local speed = Vector3.new(v.X, 0, v.Z).Magnitude
	local localMode = character:GetAttribute("UB_LocalMode")
	local state = humanoid:GetState()
	local mode: Locomotion.Mode = "Ground"
	if type(localMode) == "string" and POSE_MODES[localMode] then
		mode = "Pose"
	elseif state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping then
		mode = if v.Y > 2 then "Rising" else "Falling"
	end
	Locomotion.update(controller, dt, speed, mode)
end)

humanoid.Died:Connect(function()
	connection:Disconnect()
	Locomotion.destroy(controller)
end)
