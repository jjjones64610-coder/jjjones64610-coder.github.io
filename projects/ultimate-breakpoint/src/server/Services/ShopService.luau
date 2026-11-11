--!strict
--[[
	ShopService — Robux purchases (Config/Shop).

	  * Coin packs are developer products. ProcessReceipt grants the coins once
	    per purchase id (recorded in the profile's receipts, so a retried
	    receipt is never paid twice) and only says PurchaseGranted after the
	    profile has the coins; if the profile isn't loaded yet it answers
	    NotProcessedYet and Roblox retries later.
	  * The VIP pass is a game pass, checked on join and when bought in game
	    (PromptGamePassPurchaseFinished): x1.5 coins and the VIP cosmetics.
	  * With every id still 0 (not published yet) nothing is prompted; the
	    shop shows the packs as "available after publishing".
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ShopConfig = require(Shared.Config.Shop)
local Net = require(Shared.Net)

local ShopService = {}

local services: any

local function setVip(player: Player, on: boolean)
	local d = services.DataService.get(player)
	if d and d.vip ~= on then
		services.DataService.update(player, function(dd: { [string]: any })
			dd.vip = on
		end)
		services.ProgressionService.push(player)
	end
end

local function checkVip(player: Player)
	local pass = ShopConfig.Vip.gamePassId
	if pass == 0 then
		return
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass)
	end)
	if ok then
		setVip(player, owns == true)
	end
end

function ShopService.isVip(player: Player): boolean
	local d = services.DataService.get(player)
	return d ~= nil and d.vip == true
end

local function processReceipt(info: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(info.PlayerId)
	local product = ShopConfig.product(info.ProductId)
	if not product then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local d = services.DataService.get(player)
	if not d then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local key = tostring(info.PurchaseId)
	if d.receipts[key] then
		return Enum.ProductPurchaseDecision.PurchaseGranted -- already paid out
	end
	services.DataService.update(player, function(dd: { [string]: any })
		dd.receipts[key] = true
		dd.coins = (dd.coins or 0) + product.coins
	end)
	pcall(function()
		services.DataService.saveNow(player)
	end)
	services.ProgressionService.push(player)
	Net.event("Notify"):FireClient(player, "Purchase", string.format("+%d coins", product.coins), nil)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function ShopService.Init(s: any)
	services = s
end

function ShopService.Start()
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, bought)
		if bought and passId == ShopConfig.Vip.gamePassId then
			setVip(player, true)
			Net.event("Notify"):FireClient(player, "Purchase", "VIP unlocked", nil)
		end
	end)
	Players.PlayerAdded:Connect(function(player)
		task.delay(3, checkVip, player) -- after the profile has loaded
	end)
	for _, p in Players:GetPlayers() do
		task.spawn(checkVip, p)
	end
end

return ShopService
