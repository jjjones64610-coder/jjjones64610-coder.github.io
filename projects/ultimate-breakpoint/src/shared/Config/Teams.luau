--!strict
-- Team identities. Blue vs orange stays distinguishable for the most common
-- forms of colour blindness; end zones glow in the attacking team's colour.

local Teams = {
	A = {
		Name = "TIDE",
		Color = Color3.fromRGB(32, 140, 255),
		Dark = Color3.fromRGB(14, 60, 120),
		BrickColor = BrickColor.new("Bright blue"),
	},
	B = {
		Name = "BLAZE",
		Color = Color3.fromRGB(255, 120, 30),
		Dark = Color3.fromRGB(120, 50, 10),
		BrickColor = BrickColor.new("Neon orange"),
	},
	Neutral = {
		Name = "SIDELINE",
		Color = Color3.fromRGB(200, 200, 210),
		BrickColor = BrickColor.new("Medium stone grey"),
	},
}

return Teams
