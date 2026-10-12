--!strict
--[[
	Net — one place that names every remote and replicated-state folder.

	The server creates everything in Net.init(); clients wait for it. Remotes
	are coarse and event-driven (a technique, a throw, a catch claim) — there is
	no per-frame client->server traffic except the optional unreliable
	MarkAim stream while a defender holds Mark Stance (10 Hz).

	Client -> server
	  Tech        (events: {{tech, quality, dir, t, info}}, mode)   validated, replicated as pose attributes
	  ThrowCharge (throwType)                                        windup pose for everyone
	  Throw       (params)                                           server computes the launch itself
	  Fake        (throwType)
	  Catch       (discId, clientServerTime, zoneKind, reachDir)      claim, validated with lag compensation
	  Reach       (dir)                                              opens the reach window server-side
	  MarkStance  (on, stance)
	  MarkAim     (pitch)          [unreliable]
	  Action      (kind, payload)                                    votes, training, settings, cosmetics
	Server -> client
	  Notify, Highlight, CatchResult, Profile, Summary, Feedback, Effect, Combo
	Replicated state (attributes, late-join safe)
	  ReplicatedStorage.UBState   match phase, score, clock, possession, stall
	  ReplicatedStorage.UBDiscs   one Configuration per disc (flight launch params)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

Net.FolderName = "UBRemotes"
Net.StateName = "UBState"
Net.DiscsName = "UBDiscs"

Net.Events = {
	"Tech",
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

Net.Unreliable = { "MarkAim" }

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
