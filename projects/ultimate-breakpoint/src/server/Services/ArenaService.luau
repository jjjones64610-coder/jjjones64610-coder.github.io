--!strict
-- ArenaService — current arena, field geometry and wind. Rebuilds the world
-- between matches.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ArenasConfig = require(Shared.Config.Arenas)
local ModesConfig = require(Shared.Config.Modes)
local FieldGeometry = require(Shared.Rules.FieldGeometry)
local Net = require(Shared.Net)
local ArenaBuilder = require(script.Parent.Parent.Arena.ArenaBuilder)

local ArenaService = {}

local current: any = nil
local built: ArenaBuilder.Built? = nil
local field: FieldGeometry.Field? = nil
local fieldSpec: any = nil

function ArenaService.build(arenaId: string, fieldName: string)
	local arena = (ArenasConfig.List :: any)[arenaId] or ArenasConfig.List[ArenasConfig.Default]
	local spec = (ModesConfig.Fields :: any)[fieldName] or ModesConfig.Fields.Standard
	current = arena
	fieldSpec = spec
	built = ArenaBuilder.build(arena, spec, workspace)
	field = FieldGeometry.new({
		center = Vector3.new(0, 0, 0),
		width = spec.width,
		length = spec.length,
		endZone = spec.endZone,
		brick = spec.brick,
	})
	local state = Net.state()
	state:SetAttribute("Arena", arena.id)
	state:SetAttribute("ArenaName", arena.Display)
	state:SetAttribute("Wind", arena.Wind)
	state:SetAttribute("FieldWidth", spec.width)
	state:SetAttribute("FieldLength", spec.length)
	state:SetAttribute("FieldEndZone", spec.endZone)
	state:SetAttribute("FieldBrick", spec.brick)
end

function ArenaService.field(): FieldGeometry.Field
	assert(field, "arena not built")
	return field :: FieldGeometry.Field
end

function ArenaService.fieldSpec(): any
	return fieldSpec
end

function ArenaService.arena(): any
	return current
end

function ArenaService.wind(): { x: number, y: number, z: number }
	local w = if current then current.Wind else Vector3.zero
	return { x = w.X, y = w.Y, z = w.Z }
end

function ArenaService.windVector(): Vector3
	return if current then current.Wind else Vector3.zero
end

function ArenaService.endZone(side: string): BasePart?
	if built then
		return built.endZones[side]
	end
	return nil
end

function ArenaService.spawnCFrame(): CFrame
	if built then
		return built.spawn.CFrame + Vector3.new(0, 3, 0)
	end
	return CFrame.new(0, 5, -70)
end

function ArenaService.margin(): number
	return ArenaBuilder.Margin
end

function ArenaService.Init(_s: any)
	ArenaService.build(ArenasConfig.Default, "Standard")
end

function ArenaService.Start() end

return ArenaService
