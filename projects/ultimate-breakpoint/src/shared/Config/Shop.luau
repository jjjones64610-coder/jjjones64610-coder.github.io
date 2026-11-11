--!strict
--[[
	Shop — the economy (ShopService, Menu → SHOP).

	Coins are earned by playing (a share of every XP grant: matches, goals,
	catches, blocks, Perfect techs through combos, signature moves, drills)
	and spent on items with a `price` in Config/Progression (trails, emotes,
	auras) and on abilities (Abilities below). Robux buys coin packs
	(developer products) and the VIP pass (a game pass: x1.5 coins and the
	VIP cosmetics).

	Robux ids are 0 until the game is published: create the products and the
	pass on the Creator Dashboard (Monetization), paste their ids here, and
	the shop's Robux buttons switch on. Nothing else to change.
]]

local Shop = {}

Shop.CoinsPerXp = 0.25 -- coins for every XP point earned
Shop.VipCoinMult = 1.5
Shop.StartingCoins = 250

-- Abilities and their prices (Flash Step is everyone's to start).
Shop.Abilities = {
	{ id = "FlashStep", name = "Flash Step", price = 0 },
	{ id = "Zone", name = "The Zone", price = 1500 },
	{ id = "Overdrive", name = "Overdrive", price = 2000 },
	{ id = "SkyWalk", name = "Sky Walk", price = 2500 },
	{ id = "MagnetHands", name = "Magnet Hands", price = 1800 },
	{ id = "TempestThrow", name = "Tempest Throw", price = 2200 },
} :: { any }

export type Product = { id: string, productId: number, coins: number, robux: number, name: string }

-- Developer products (coin packs). robux is the price you set on the dashboard (shown on the button).
Shop.Products = {
	{ id = "Coins500", name = "Pouch", coins = 500, robux = 49, productId = 0 },
	{ id = "Coins1500", name = "Bag", coins = 1500, robux = 129, productId = 0 },
	{ id = "Coins4000", name = "Chest", coins = 4000, robux = 299, productId = 0 },
	{ id = "Coins10000", name = "Vault", coins = 10000, robux = 649, productId = 0 },
} :: { Product }

-- The VIP game pass.
Shop.Vip = { gamePassId = 0, robux = 299, name = "VIP" }

function Shop.product(productId: number): Product?
	for _, p in Shop.Products do
		if p.productId ~= 0 and p.productId == productId then
			return p
		end
	end
	return nil
end

return Shop
