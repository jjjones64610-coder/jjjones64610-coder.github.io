--!strict
-- FIXED HITBOX
-- Every player plays with the same body, whatever their avatar:
--   * The server rescales every character to the standard proportions below
--     on spawn (PlayerService), so tall, wide or Rthro avatars look the same
--     size as everyone else. Clothes, colours and accessories are kept.
--   * Gameplay never reads the avatar's own parts. Catch zones are built from
--     a fixed capsule that starts at the feet (ground under the root) and
--     uses the numbers in Config/Disc.Catch, so even if an avatar could not
--     be rescaled (a failed load), its zones sit exactly where everyone
--     else's do. Mark boxes are measured from the ground already.
--   * Physics only collides the HumanoidRootPart (2 x 2 x 1 for every
--     standard body); limbs and accessories collide with nothing.
-- The optional "Show hitboxes" setting draws this capsule for every player.

local Hitbox = {
	-- standard avatar scales applied on spawn (HumanoidDescription fields)
	Scales = {
		HeightScale = 1,
		WidthScale = 1,
		DepthScale = 1,
		HeadScale = 1,
		BodyTypeScale = 0,
		ProportionScale = 0,
	},
	NormalizeAvatars = true,

	-- the gameplay body: a vertical capsule from the feet
	RootHeight = 3, -- standard root centre above the ground (HipHeight 2 + half the 2-stud root)
	Height = 5.4, -- feet to the top of the head
	Radius = 1.2, -- body capsule radius (drawn by the overlay)

	-- lying flat after a layout (DiveSlide, start of Recover): zones drop to the turf
	ProneDrop = 1.8, -- the chest zone sits this much lower than standing
	ProneDiveHeight = -1.6, -- the dive zone runs this far below the standing root (along the ground)
}

-- The root position every gameplay volume is built from: the real root moved
-- so it stands RootHeight above the same ground. `standHeight` is how far
-- this character's real root sits above its feet (HipHeight + half the root
-- height; 3 for a standard R15 body).
function Hitbox.root(rootPos: Vector3, standHeight: number): Vector3
	local sh = if standHeight == standHeight
			and standHeight > 0
			and standHeight < 20
		then standHeight
		else Hitbox.RootHeight
	return rootPos - Vector3.new(0, sh - Hitbox.RootHeight, 0)
end

-- How far a character's real root sits above its feet.
function Hitbox.standHeightOf(humanoid: Humanoid?, root: BasePart?): number
	if humanoid and root and humanoid.RigType == Enum.HumanoidRigType.R15 then
		return humanoid.HipHeight + root.Size.Y / 2
	end
	return Hitbox.RootHeight
end

return Hitbox
