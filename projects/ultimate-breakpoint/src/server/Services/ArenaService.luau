--!strict
--[[
	ArenaService — current arena, field geometry and wind. Rebuilds the world
	between matches.

	The field follows the mode: Config/Modes.Fields.Mini (240 x 90 including
	end zones) for 3v3 and .Normal (360 x 136) for 7v7. The server boots on
	the Normal field; MatchService rebuilds when a match needs the other one.
	Field size is published on UBState (Field, FieldWidth, FieldLength,
	FieldEndZone, FieldBrick) for clients.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ArenasConfig = require(Shared.Config.Arenas)
local ModesConfig = require(Shared.Config.Modes)
local DiscConfig = require(Shared.Config.Disc)
local FieldGeometry = require(Shared.Rules.FieldGeometry)
local Net = require(Shared.Net)
local ArenaBuilder = require(script.Parent.Parent.Arena.ArenaBuilder)

local ArenaService = {}

ArenaService.DefaultField = "Normal"

local current: any = nil
local built: ArenaBuilder.Built? = nil
local field: FieldGeometry.Field? = nil
local fieldSpec: ModesConfig.FieldSpec? = nil
local currentFieldName = ArenaService.DefaultField

function ArenaService.build(arenaId: string, fieldName: string)
	local arena = (ArenasConfig.List :: any)[arenaId] or ArenasConfig.List[ArenasConfig.Default]
	local name = if ModesConfig.Fields[fieldName] then fieldName else ArenaService.DefaultField
	local spec = ModesConfig.Fields[name]
	current = arena
	fieldSpec = spec
	currentFieldName = name
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
	state:SetAttribute("Field", name)
	state:SetAttribute("FieldWidth", spec.width)
	state:SetAttribute("FieldLength", spec.length)
	state:SetAttribute("FieldEndZone", spec.endZone)
	state:SetAttribute("FieldBrick", spec.brick)
end

function ArenaService.field(): FieldGeometry.Field
	assert(field, "arena not built")
	return field :: FieldGeometry.Field
end

function ArenaService.fieldSpec(): ModesConfig.FieldSpec?
	return fieldSpec
end

-- Key into Config/Modes.Fields of the field that is built ("Mini" / "Normal").
function ArenaService.fieldName(): string
	return currentFieldName
end

function ArenaService.arena(): any
	return current
end

-- The arena's wind as the disc feels it (Config/Arenas values are at the
-- real-world tempo; flights run at Config/Disc.Tempo, so wind scales too).
function ArenaService.windVector(): Vector3
	return (if current then current.Wind else Vector3.zero) * DiscConfig.Tempo
end

function ArenaService.wind(): { x: number, y: number, z: number }
	local w = ArenaService.windVector()
	return { x = w.X, y = w.Y, z = w.Z }
end

function ArenaService.endZone(side: string): BasePart?
	if built then
		return built.endZones[side]
	end
	return nil
end

-- Centre of a team's sideline bench (where FieldGeometry.benchSpots stand),
-- facing the field.
function ArenaService.benchCFrame(team: string): CFrame?
	if built then
		return built.benches[team]
	end
	return nil
end

function ArenaService.spawnCFrame(): CFrame
	if built then
		return built.spawn.CFrame + Vector3.new(0, 3, 0)
	end
	local width = if fieldSpec then fieldSpec.width else ModesConfig.Fields[ArenaService.DefaultField].width
	return CFrame.new(0, 5, -(width / 2 + 16))
end

function ArenaService.margin(): number
	return ArenaBuilder.Margin
end

function ArenaService.Init(_s: any)
	ArenaService.build(ArenasConfig.Default, ArenaService.DefaultField)
end

function ArenaService.Start() end

return ArenaService
