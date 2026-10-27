--!strict
--[[
	Signatures — recognises the signature moves (Config/Signatures) from one
	player's stream of events. Pure and deterministic; the client runs it for
	instant feedback and the server runs it on validated events to pay out.

	Feed it, in time order:
	  Tech      an accepted technique { tech, quality, info }
	  Land      the player touched down (ends the airtime)
	  Tip       the player tipped a disc in the air (a tip reset), with the
	            disc id and whether they were the defending team (a block)
	  Catch     the player caught a disc { discId, airborne, height,
	            interception }
	  Greatest  the rules called a Greatest for this player

	A catch is judged against the airtime it happened in by its timestamp: a
	catch confirmed after the Land that ended its airtime (the server answers
	a round trip later) still counts in that airtime.

	An airtime runs from one Land to the next. Within it the tracker counts
	tips (and which discs were tipped), wall rebounds, air moves used after a
	tip, and a Perfect recovery pop followed by an air layout. A catch in the
	air completes the best matching move in Config/Signatures.Order; Tip Reset
	pays as soon as the reset is used (first air move after a tip). Reset
	Loop and Self-D are tracked across airtimes.
]]

local Shared = script.Parent.Parent
local Config = require(Shared.Config.Signatures)

local Signatures = {}

export type Event = {
	kind: string, -- "Tech" | "Land" | "Tip" | "Catch" | "Greatest"
	t: number,
	tech: string?,
	quality: string?,
	info: string?,
	discId: string?,
	airborne: boolean?,
	height: number?, -- feet above the ground at the catch
	defender: boolean?, -- Tip: by the defending team
	interception: boolean?, -- Catch: by the defending team
}

export type Hit = {
	id: string,
	name: string,
	points: number,
	tier: number,
	t: number,
}

type Air = {
	tips: number,
	tipDiscs: { [string]: boolean },
	walls: number,
	movesAfterTip: number,
	tipResetPaid: boolean,
	popAt: number?, -- a Perfect recovery pop-up started this airtime
	popLayout: boolean, -- ... and an air layout followed it
}

export type Tracker = {
	air: Air,
	prevAir: Air?, -- the airtime the last Land ended ...
	prevLandAt: number, -- ... and when
	-- Reset Loop: landing reset -> burst -> Perfect snap cut
	loopStage: number, -- 0 none, 1 landing reset, 2 burst
	loopAt: number,
	loops: { number }, -- completion times of recent loops
	defenderTips: { [string]: number }, -- discId -> time of this player's defensive tip
}

local function newAir(): Air
	return {
		tips = 0,
		tipDiscs = {},
		walls = 0,
		movesAfterTip = 0,
		tipResetPaid = false,
		popAt = nil,
		popLayout = false,
	}
end

function Signatures.new(): Tracker
	return {
		air = newAir(),
		prevAir = nil,
		prevLandAt = -math.huge,
		loopStage = 0,
		loopAt = -math.huge,
		loops = {},
		defenderTips = {},
	}
end

local function hit(id: string, t: number): Hit
	local d = Config.List[id]
	return { id = id, name = d.name, points = d.points, tier = d.tier, t = t }
end

local function isAirMove(e: Event): boolean
	return e.tech == "AirRedirect" or (e.tech == "Dive" and e.info == "Air")
end

local function onTech(tr: Tracker, e: Event, out: { Hit })
	local air = tr.air
	local tech = e.tech
	if tech == "WallRebound" then
		air.walls += 1
	elseif tech == "RecoveryChain" and e.quality == "Perfect" and e.info == "Jump" then
		-- a Perfect pop-up out of a layout: the next airtime can hold a second layout
		air.popAt = e.t
		air.popLayout = false
	end
	if isAirMove(e) then
		if air.tips > 0 then
			air.movesAfterTip += 1
			if not air.tipResetPaid then
				air.tipResetPaid = true
				table.insert(out, hit("TipReset", e.t))
			end
		end
		if e.tech == "Dive" and air.popAt ~= nil and e.t - (air.popAt :: number) <= Config.LayoutWindow then
			air.popLayout = true
		end
	end

	-- Reset Loop
	if tech == "PrecisionLanding" and e.info == "Reset" then
		tr.loopStage = 1
		tr.loopAt = e.t
	elseif tech == "BurstStep" and tr.loopStage == 1 and e.t - tr.loopAt <= Config.LoopStep then
		tr.loopStage = 2
		tr.loopAt = e.t
	elseif tech == "SnapCut" and tr.loopStage == 2 and e.t - tr.loopAt <= Config.LoopStep then
		tr.loopStage = 0
		if e.quality == "Perfect" then
			local prev = tr.loops[#tr.loops]
			if prev ~= nil and e.t - prev <= Config.LoopGap then
				tr.loops = {}
				table.insert(out, hit("ResetLoop", e.t))
			else
				tr.loops = { e.t }
			end
		end
	elseif tr.loopStage > 0 and e.t - tr.loopAt > Config.LoopStep then
		tr.loopStage = 0
	end
end

local function onCatch(tr: Tracker, e: Event, out: { Hit })
	-- a catch from before the last landing belongs to that airtime
	local prev = tr.prevAir
	local air = if prev ~= nil and e.t <= tr.prevLandAt + 1e-3 then prev else tr.air
	local disc = e.discId
	local tipped = disc ~= nil and air.tipDiscs[disc :: string] == true
	local done: { [string]: boolean } = {}
	if e.airborne then
		if air.tips >= 2 and tipped then
			done.DoubleTip = true
		end
		if air.walls >= 1 and air.tips >= 1 and tipped then
			done.WallTip = true
		end
		if air.tips >= 1 and tipped and air.movesAfterTip >= 1 then
			done.ResetGrab = true
		end
		if air.popLayout and air.popAt ~= nil and e.t - (air.popAt :: number) <= Config.LayoutWindow then
			done.DoubleLayout = true
		end
		if (e.height or 0) >= Config.SkyHeight then
			done.Skyball = true
		end
	end
	if e.interception and disc ~= nil then
		local at = tr.defenderTips[disc :: string]
		if at ~= nil and e.t - at <= Config.SelfDWindow then
			done.SelfD = true
		end
	end
	if disc ~= nil then
		tr.defenderTips[disc :: string] = nil
	end
	for _, id in Config.Order do
		if done[id] then
			table.insert(out, hit(id, e.t))
			break
		end
	end
	-- the airtime's resets are spent by the catch
	if e.airborne then
		air.tips = 0
		air.tipDiscs = {}
		air.movesAfterTip = 0
		air.walls = 0
		air.popAt = nil
		air.popLayout = false
	end
end

-- Feeds one event; returns the signature moves it completed (usually none).
function Signatures.feed(tr: Tracker, e: Event): { Hit }
	local out: { Hit } = {}
	local kind = e.kind
	if kind == "Tech" then
		onTech(tr, e, out)
	elseif kind == "Land" then
		local pop = tr.air.popAt
		tr.prevAir = tr.air
		tr.prevLandAt = e.t
		tr.air = newAir()
		-- the layout before a pop-up lands first: keep a pop that has not
		-- left the ground yet
		if pop ~= nil and e.t - pop < 0.05 then
			tr.air.popAt = pop
		end
	elseif kind == "Tip" then
		local disc = e.discId
		if e.defender then
			if disc then
				tr.defenderTips[disc] = e.t
			end
		end
		tr.air.tips += 1
		if disc then
			tr.air.tipDiscs[disc] = true
		end
	elseif kind == "Catch" then
		onCatch(tr, e, out)
	elseif kind == "Greatest" then
		table.insert(out, hit("Greatest", e.t))
	end
	return out
end

-- Definition of a signature move by id (for UI).
function Signatures.def(id: string): Config.Def?
	return Config.List[id]
end

return Signatures
