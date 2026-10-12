--!strict
--[[
	Actors — a single way to address "someone on the field", human or bot.

	Every character model (players and bots) carries attributes set by the
	server:
	  UBId    number  (Player.UserId, or a negative id for bots)
	  UBTeam  string  "A" | "B" | "N" (training/spectating)
	  UBName  string  display name
	Clients and server both use these helpers to find characters by id.
	In Studio, local test players can have negative UserIds; bots use ids
	below -1000000 so they never collide.
]]

local Players = game:GetService("Players")

local Actors = {}

Actors.BotIdBase = -1000000
Actors.BotFolderName = "UBBots"

function Actors.botFolder(): Folder?
	return workspace:FindFirstChild(Actors.BotFolderName) :: Folder?
end

function Actors.isBotId(id: number): boolean
	return id <= Actors.BotIdBase
end

function Actors.idOf(model: Instance?): number?
	if not model then
		return nil
	end
	local id = model:GetAttribute("UBId")
	if type(id) == "number" then
		return id
	end
	return nil
end

function Actors.teamOf(model: Instance?): string?
	if not model then
		return nil
	end
	local t = model:GetAttribute("UBTeam")
	if type(t) == "string" then
		return t
	end
	return nil
end

-- All live character models with a UBId.
function Actors.characters(): { Model }
	local list: { Model } = {}
	for _, p in Players:GetPlayers() do
		local c = p.Character
		if c and c:GetAttribute("UBId") ~= nil then
			table.insert(list, c)
		end
	end
	local bots = Actors.botFolder()
	if bots then
		for _, m in bots:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("UBId") ~= nil then
				table.insert(list, m)
			end
		end
	end
	return list
end

function Actors.characterOf(id: number): Model?
	if Actors.isBotId(id) then
		local bots = Actors.botFolder()
		if bots then
			for _, m in bots:GetChildren() do
				if m:IsA("Model") and m:GetAttribute("UBId") == id then
					return m
				end
			end
		end
		return nil
	end
	local p = Players:GetPlayerByUserId(id)
	if p and p.Character then
		return p.Character
	end
	-- Studio test players may carry ids GetPlayerByUserId cannot resolve
	for _, pl in Players:GetPlayers() do
		local c = pl.Character
		if c and c:GetAttribute("UBId") == id then
			return c
		end
	end
	return nil
end

function Actors.rootOf(id: number): BasePart?
	local c = Actors.characterOf(id)
	if c then
		return c:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	return nil
end

function Actors.nameOf(id: number): string
	local c = Actors.characterOf(id)
	if c then
		local n = c:GetAttribute("UBName")
		if type(n) == "string" then
			return n
		end
	end
	local p = Players:GetPlayerByUserId(id)
	if p then
		return p.DisplayName
	end
	return "Player"
end

function Actors.playerOf(id: number): Player?
	if Actors.isBotId(id) then
		return nil
	end
	return Players:GetPlayerByUserId(id)
end

return Actors
