--!strict
--[[
	Net — one place that names every remote and replicated-state folder.

	The server creates everything in Net.init(); clients wait for it. Remotes
	are coarse and event-driven (a technique, a pivot plant, a throw, a catch
	claim): there is no per-frame client->server traffic. Every technique
	event carries its own timestamp `t` (the client's Net.now() when it
	happened), so the server judges cooldowns, chains and conversions on when
	things happened rather than when the packet arrived.

	Client -> server
	  Tech        (events: {{tech, quality, dir, t, info}}, mode)   validated on t, replicated as pose attributes
	  Pivot       (pos: Vector3)                                 proposed pivot foot P; server validates, writes UBPivot
	  ThrowCharge (throwType | false)                            windup pose for everyone (false = charge lost)
	  Throw       (params)                                       params incl. step, pivot, releaseT, rootPos; the
	                                                             server computes the launch itself
	  Fake        (throwType, side)
	  Catch       (discId, tFirst, zoneKind, reachDir, rootPos, rootVel)  claim, lag-compensated; always answered
	  Reach       (dir)                                          opens the reach window server-side
	  MarkStance  (on, stance)
	  Action      (kind, payload)                                votes, pickup, training, settings, cosmetics
	Server -> client
	  Notify, Highlight, CatchResult (also Denied), Profile, Summary, Feedback, Effect, Combo
	Replicated state (attributes, late-join safe)
	  ReplicatedStorage.UBState   match phase, mode, score, clock, possession, stall, team counts
	  ReplicatedStorage.UBDiscs   one Configuration per disc (flight launch params)
	  character models            UBPivot, UBTeleport(+Pos/Yaw/Face), UBLineX/UBLineSide, UBRole, pose attributes
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

Net.FolderName = "UBRemotes"
Net.StateName = "UBState"
Net.DiscsName = "UBDiscs"

Net.Events = {
	"Tech",
	"Pivot",
	"ThrowCharge",
	"Throw",
	"Fake",
	"Catch",
	"Reach",
	"MarkStance",
	"Action",
	"Notify",
	"Highlight",
	"CatchResult",
	"Profile",
	"Summary",
	"Feedback",
	"Effect",
	"Combo",
}

-- Unreliable streams (none at the moment; Net.unreliable() stays for future ones).
Net.Unreliable = {} :: { string }

Net.Functions = { "GetProfile", "GetLeaderboard" }

local folder: Folder? = nil

local function ensureChild(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

function Net.init()
	assert(RunService:IsServer(), "Net.init is server-only")
	local f = ensureChild(ReplicatedStorage, "Folder", Net.FolderName) :: Folder
	for _, name in Net.Events do
		ensureChild(f, "RemoteEvent", name)
	end
	for _, name in Net.Unreliable do
		ensureChild(f, "UnreliableRemoteEvent", name)
	end
	for _, name in Net.Functions do
		ensureChild(f, "RemoteFunction", name)
	end
	ensureChild(ReplicatedStorage, "Folder", Net.StateName)
	ensureChild(ReplicatedStorage, "Folder", Net.DiscsName)
	folder = f
end

local function getFolder(): Folder
	if folder then
		return folder :: Folder
	end
	local f = ReplicatedStorage:WaitForChild(Net.FolderName, 60) :: Folder
	assert(f, "UBRemotes folder missing (is the server running?)")
	folder = f
	return f
end

function Net.event(name: string): RemoteEvent
	return getFolder():WaitForChild(name) :: RemoteEvent
end

function Net.unreliable(name: string): UnreliableRemoteEvent
	return getFolder():WaitForChild(name) :: UnreliableRemoteEvent
end

function Net.func(name: string): RemoteFunction
	return getFolder():WaitForChild(name) :: RemoteFunction
end

function Net.state(): Folder
	return ReplicatedStorage:WaitForChild(Net.StateName) :: Folder
end

function Net.discs(): Folder
	return ReplicatedStorage:WaitForChild(Net.DiscsName) :: Folder
end

-- Server time shared by every machine (used for disc flights and windows).
function Net.now(): number
	return workspace:GetServerTimeNow()
end

return Net
