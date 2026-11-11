--!strict
--[[
	Art — uploaded image assets for the interface (made with ForgeGUI in the
	"Breakpoint Neon Sport" style and published to Roblox as Image assets).

	An empty id falls back to the plain drawn look, so the game still works if
	an asset is missing or waiting on moderation. Swap any id for your own.
	The game icon and thumbnail are not used in code: set them on the
	experience's page in the Creator Dashboard.
]]

local Art = {}

Art.Images = {
	Scoreboard = "115503255890906", -- the top scoreboard bar (team slots left and right)
	Button = "72548992304180", -- every menu / panel button
}

-- Not used in code; listed so they are easy to find.
Art.Store = {
	Icon = "122240476504741",
	Thumbnail = "77694382940410",
}

-- "rbxassetid://123" for an id, or nil when the slot is empty.
function Art.image(name: string): string?
	local id = (Art.Images :: any)[name]
	if type(id) == "string" and id ~= "" then
		return "rbxassetid://" .. id
	end
	return nil
end

return Art
