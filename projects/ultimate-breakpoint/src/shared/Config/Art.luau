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

-- Anime effect textures (ForgeGUI, transparent sprites) for AnimeFX and
-- the ability auras. Empty = the effect falls back to plain neon shapes.
Art.Vfx = {
	Impact = "114639680211643", -- spiky starburst (Perfect impact frames)
	Slash = "126416714683393", -- crescent slash arc (cuts, zap dashes)
	Aura = "92068753120602", -- flame wisp (ability auras)
	Shockwave = "140164455409997", -- ring (wavedash, plant stop, landings)
	Sparkle = "109676763334543", -- four-point glint (resets, Perfect catches)
	Streak = "132502257002630", -- motion streak (speed lines)
}

-- "rbxassetid://123" for an effect texture, or nil when the slot is empty.
function Art.vfx(name: string): string?
	local id = (Art.Vfx :: any)[name]
	if type(id) == "string" and id ~= "" then
		return "rbxassetid://" .. id
	end
	return nil
end

-- Menu and shop art (ForgeGUI).
Art.Ui = {
	Logo = "111364135042535",
	Coin = "126354451655390",
	MenuBackground = "77694382940410", -- the store thumbnail
	FlashStep = "120616402487903",
	Zone = "72311911062044",
	SkyWalk = "97193595800423",
	Overdrive = "91517007108188",
	Emote = "89850613445736",
	Trail = "103052506400160",
	Aura = "106340578522274",
}

function Art.ui(name: string): string?
	local id = (Art.Ui :: any)[name]
	if type(id) == "string" and id ~= "" then
		return "rbxassetid://" .. id
	end
	return nil
end

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
