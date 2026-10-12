--!strict
-- Deterministic xorshift32 generator. Used wherever a sequence must be
-- reproducible (training drills, bot personalities, fuzz tests). Gameplay
-- outcomes never use randomness.

local Rng = {}
Rng.__index = Rng

export type Rng = typeof(setmetatable({} :: { state: number }, Rng))

function Rng.new(seed: number): Rng
	local s = bit32.band(math.floor(math.abs(seed)), 0xFFFFFFFF)
	if s == 0 then
		s = 0x9E3779B9
	end
	return setmetatable({ state = s }, Rng)
end

function Rng.nextInt32(self: Rng): number
	local x = self.state
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	self.state = x
	return x
end

-- Uniform in [0, 1).
function Rng.next(self: Rng): number
	return self:nextInt32() / 4294967296
end

function Rng.range(self: Rng, a: number, b: number): number
	return a + (b - a) * self:next()
end

function Rng.int(self: Rng, a: number, b: number): number
	return math.min(b, a + math.floor(self:next() * (b - a + 1)))
end

return Rng
