--!strict
--[[
	GameFeel — the one module that plays effects for gameplay events
	(docs/CORE_DESIGN.md, stage 7). Gameplay code says WHAT happened:

	    controllers.GameFeel.play("PerfectLayoutCatch", { pos = p, own = true })

	and this module decides how it looks, from Config/Tuning Feel.Events
	(impact frame, hit-stop, camera shake and punch, particle burst, ground
	ring, dust, afterimages), scaled by Feel.Intensity and the per-channel
	dials. Nothing else calls the effect primitives for a gameplay moment, so
	the whole game can be turned up or down in one place.

	It also owns the always-on anime layer:
	  * Hit-stop: frozen() is true for a few frames after a big play of your
	    own; MovementController and PoseController hold still while it is
	    (your body and pose freeze, the world goes on: time can't stop for
	    one player in a shared game).
	  * Outlines: Roblox renders at most 31 Highlights, so they are dealt
	    out every Feel.Outlines.Refresh: the disc, its holder, you, anyone
	    using an ability, then the players nearest the camera, up to
	    Feel.Outlines.Budget. An active ability tints its owner's outline
	    and fill (so a model never needs two Highlights).
	  * Sprint trails: a team-coloured ribbon behind anyone past
	    Feel.Trail.FromSpeed.
	  * The colour grade: extra saturation and contrast on top of the
	    arena's own lighting.

	Screen effects (flash, hit-stop, shake, kick) only play for your own
	events (ctx.own); world effects (burst, ring, dust, ghosts) play for
	everyone's.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TechConfig = require(Shared.Config.Tech)
local Abilities = require(Shared.Abilities)
local Actors = require(Shared.Actors)
local Net = require(Shared.Net)
local Theme = require(script.Parent.Parent.UI.Theme)

local Feel = TechConfig.Feel
local OUT = Feel.Outlines

local GameFeel = {}

export type Context = {
	pos: Vector3?, -- where it happened (defaults to your feet)
	color: Color3?, -- defaults to the Perfect gold
	model: Model?, -- whose body (afterimages)
	dir: Vector3?,
	own: boolean?, -- your own play: screen effects too
}

local controllers: any
local player = Players.LocalPlayer
local freezeUntil = -math.huge

local function enabled(): boolean
	return controllers.SettingsController.get("AnimeEffects") ~= false
end

-- True during a hit-stop (your body and pose hold still).
function GameFeel.frozen(): boolean
	return os.clock() < freezeUntil
end

-- Freezes your body and pose for `seconds` (scaled, capped at MaxHitStop).
function GameFeel.hitStop(seconds: number)
	local s = math.min(seconds * Feel.HitStop * Feel.Intensity, Feel.MaxHitStop)
	if s > 0 and enabled() then
		freezeUntil = math.max(freezeUntil, os.clock() + s)
	end
end

-- Plays the effects of `event` (a row of Config/Tuning Feel.Events).
function GameFeel.play(event: string, ctx: Context?)
	local row = Feel.Events[event]
	if not row or not enabled() then
		return
	end
	local c: Context = ctx or {}
	local k = Feel.Intensity
	local color = c.color or Theme.Colors.Perfect
	local root = controllers.MovementController.root()
	local pos = c.pos
	if not pos and root then
		pos = root.Position
	end
	local fx = controllers.EffectsController
	local anime = controllers.AnimeFX
	local cam = controllers.CameraController

	-- the world: everyone's plays
	if pos then
		local p = pos :: Vector3
		local particles = k * Feel.Particles
		if (row.burst or 0) > 0 and particles > 0 then
			anime.impactBurst(p, color, math.max(4, row.burst * particles * 0.4))
			fx.burst(p, color, math.floor(row.burst * particles + 0.5), 14)
		end
		if (row.ring or 0) > 0 and particles > 0 then
			anime.shockwave(p - Vector3.new(0, 2.8, 0), color, row.ring)
		end
		if (row.dust or 0) > 0 and particles > 0 then
			fx.dust(p - Vector3.new(0, 2.9, 0), math.floor(row.dust * particles + 0.5))
		end
	end
	if (row.ghosts or 0) > 0 and c.model then
		anime.afterimage(c.model, color, row.ghosts)
	end

	-- the screen: only your own
	if not c.own then
		return
	end
	if (row.flash or 0) > 0 then
		anime.impactFrame(color, row.flash * Feel.Flash * k)
	end
	if (row.hitStop or 0) > 0 then
		GameFeel.hitStop(row.hitStop)
	end
	if (row.shake or 0) > 0 then
		cam.shake(row.shake * Feel.Shake * k, 0.3)
	end
	if (row.kick or 0) > 0 then
		cam.kick(row.kick * Feel.Kick * k)
	end
end

---------------------------------------------------------------------------
-- outlines (the Highlight budget) and sprint trails
---------------------------------------------------------------------------

local outlined: { [Instance]: Highlight } = {}

local function outline(target: Instance, lineColor: Color3, fill: Color3?, fillTransparency: number)
	local h = outlined[target]
	if not h or h.Parent ~= target then
		local made = Instance.new("Highlight")
		made.Name = "UBOutline"
		made.DepthMode = Enum.HighlightDepthMode.Occluded
		made.OutlineTransparency = 0
		made.Parent = target
		outlined[target] = made
		h = made
	end
	local hl = h :: Highlight
	hl.OutlineColor = lineColor
	hl.FillColor = fill or lineColor
	hl.FillTransparency = fillTransparency
end

local function sprintTrail(model: Model, root: BasePart)
	local trail = root:FindFirstChild("UBSpeedTrail") :: Trail?
	local v = root.AssemblyLinearVelocity
	local fast = Vector3.new(v.X, 0, v.Z).Magnitude >= Feel.Trail.FromSpeed and enabled()
	if not trail then
		if not fast then
			return
		end
		local a0 = Instance.new("Attachment")
		a0.Name = "UBSpeedTrailTop"
		a0.Position = Vector3.new(0, Feel.Trail.Width / 2, 0)
		a0.Parent = root
		local a1 = Instance.new("Attachment")
		a1.Name = "UBSpeedTrailBottom"
		a1.Position = Vector3.new(0, -Feel.Trail.Width / 2, 0)
		a1.Parent = root
		local made = Instance.new("Trail")
		made.Name = "UBSpeedTrail"
		made.Attachment0 = a0
		made.Attachment1 = a1
		made.Lifetime = Feel.Trail.Lifetime
		made.MinLength = 0.1
		made.FaceCamera = true
		made.LightEmission = 0.7
		made.Transparency =
			NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) })
		made.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) })
		made.Parent = root
		trail = made
	end
	local t = trail :: Trail
	t.Color = ColorSequence.new(Theme.teamColor(model:GetAttribute("UBTeam") :: string?))
	t.Enabled = fast
end

-- Deals the Highlights out, most important first.
local function dealOutlines()
	local t = Net.now()
	local keep: { [Instance]: boolean } = {}
	local used = 0
	local budget = if enabled() then math.min(OUT.Budget, 31) else 0
	local function take(target: Instance?, lineColor: Color3, fill: Color3?, fillTransparency: number)
		if target and not keep[target] and used < budget then
			used += 1
			keep[target] = true
			outline(target, lineColor, fill, fillTransparency)
		end
	end
	local function takeModel(model: Model)
		local def = Abilities.active(model, t)
		if def and def.duration > 0 then
			take(model, def.color, def.color, OUT.AbilityFill)
		else
			take(model, OUT.Color, nil, 1)
		end
	end

	-- 1. every disc, and whoever holds one
	local holders: { [number]: boolean } = {}
	for _, folder in controllers.DiscRenderer.folders() do
		local id = folder:GetAttribute("Id")
		if type(id) == "string" then
			take(controllers.DiscRenderer.bodyOf(id), OUT.DiscColor, nil, 1)
		end
		local hid = folder:GetAttribute("HolderId")
		if folder:GetAttribute("Mode") == "Held" and type(hid) == "number" and hid ~= 0 then
			holders[hid] = true
		end
	end
	local models = Actors.characters()
	for _, m in models do
		local id = Actors.idOf(m)
		if id and holders[id] then
			local def = Abilities.active(m, t)
			if def and def.duration > 0 then
				take(m, def.color, def.color, OUT.AbilityFill)
			else
				take(m, OUT.HolderColor, nil, 1)
			end
		end
	end
	-- 2. you, then anyone using an ability
	if player.Character then
		takeModel(player.Character)
	end
	for _, m in models do
		local def = Abilities.active(m, t)
		if def and def.duration > 0 then
			takeModel(m)
		end
	end
	-- 3. the players nearest the camera
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	local rest: { { model: Model, dist: number } } = {}
	for _, m in models do
		local r = m:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r then
			sprintTrail(m, r)
			if not keep[m] then
				table.insert(rest, { model = m, dist = (r.Position - camPos).Magnitude })
			end
		end
	end
	table.sort(rest, function(a, b)
		return a.dist < b.dist
	end)
	for _, e in rest do
		if used >= budget then
			break
		end
		takeModel(e.model)
	end
	-- everything that lost its place gives the Highlight back
	for target, h in outlined do
		if not keep[target] or not target.Parent then
			h:Destroy()
			outlined[target] = nil
		end
	end
end

---------------------------------------------------------------------------

local function applyGrade()
	local grade = Lighting:FindFirstChild("UBAnimeGrade") :: ColorCorrectionEffect?
	if not grade then
		local made = Instance.new("ColorCorrectionEffect")
		made.Name = "UBAnimeGrade"
		made.Parent = Lighting
		grade = made
	end
	local g = grade :: ColorCorrectionEffect
	local on = enabled()
	g.Saturation = if on then Feel.Saturation * Feel.Intensity else 0
	g.Contrast = if on then Feel.Contrast * Feel.Intensity else 0
end

function GameFeel.Init(c: any)
	controllers = c
end

function GameFeel.Start()
	applyGrade()
	controllers.SettingsController.Changed:Connect(function(key)
		if key == "AnimeEffects" or key == "All" then
			applyGrade()
		end
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= OUT.Refresh then
			acc = 0
			local ok, err = pcall(function()
				dealOutlines()
			end)
			if not ok then
				warn("[GameFeel] outlines: " .. tostring(err))
			end
		end
	end)
end

return GameFeel
