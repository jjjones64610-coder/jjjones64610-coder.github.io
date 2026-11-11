--!strict
--[[
	Music — the ULTIMATE: BREAKPOINT soundtrack (made with ForgeGUI and
	published to Roblox as Audio). MusicController picks the track from the
	match state and crossfades between them. An empty id is skipped (silence
	for that state). Swap any id for your own.
]]

export type Track = { id: string, volume: number, looped: boolean }

local Music = {}

Music.Tracks = {
	MainTheme = { id = "89839473750126", volume = 0.55, looped = true }, -- warm-up / lobby
	Lobby = { id = "77177846609423", volume = 0.5, looped = true }, -- the Training hall
	Match = { id = "", volume = 0.4, looped = true }, -- live points
	Universe = { id = "", volume = 0.5, looped = true }, -- universe point
	Victory = { id = "90928091766762", volume = 0.7, looped = false }, -- match over (once)
} :: { [string]: Track }

Music.Fade = 1.5 -- s crossfade

return Music
