--!strict
--[[
	TechFeedback — the one feedback channel every tech uses
	(docs/tech-spec.md, "Roblox architecture"): a sound, a screen flash, a
	particle burst at your feet and a short text pop over the crosshair
	("PERFECT CUT"). Perfect gets all four in gold; Clean gets the sound,
	particles and a white pop; Miss only a dim pop, so a missed window is
	always readable.

	It says what you just did, never what you could do next.

	  TechFeedback.play("Perfect Cut", "Perfect")
	  TechFeedback.play("Cut", "Miss", position)
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Parent.UI.Theme)

local TechFeedback = {}

local controllers: any
local player = Players.LocalPlayer
local gui: ScreenGui? = nil
local flash: Frame? = nil
local popAt = 0

local C = Theme.Colors
local POP_TIME = 0.6
local POP_RISE = 28 -- px
local FLASH_TIME = 0.12

local function ensureGui(): ScreenGui
	local g = gui
	if g and g.Parent then
		return g
	end
	local new = Instance.new("ScreenGui")
	new.Name = "UBTechFeedback"
	new.ResetOnSpawn = false
	new.IgnoreGuiInset = true
	new.DisplayOrder = 5
	new.Parent = player:WaitForChild("PlayerGui")
	local f = Instance.new("Frame")
	f.Name = "Flash"
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = C.Perfect
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = new
	gui = new
	flash = f
	return new
end

local function doFlash(color: Color3, strength: number)
	ensureGui()
	local f = flash
	if not f then
		return
	end
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 1 - strength
	TweenService:Create(f, TweenInfo.new(FLASH_TIME), { BackgroundTransparency = 1 }):Play()
end

local function pop(text: string, color: Color3, size: number)
	local parent = ensureGui()
	-- a new pop replaces the last one so they never stack up
	local old = parent:FindFirstChild("Pop")
	if old then
		old:Destroy()
	end
	popAt = os.clock()
	local label = Theme.label(string.upper(text), size, {
		Name = "Pop",
		Parent = parent,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0.5, -26),
		Size = UDim2.fromOffset(420, size + 6),
		TextXAlignment = Enum.TextXAlignment.Center,
		Font = Theme.Fonts.Heavy,
		TextColor3 = color,
		TextStrokeTransparency = 0.5,
	})
	local info = TweenInfo.new(POP_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(label, info, {
		Position = UDim2.new(0.5, 0, 0.5, -26 - POP_RISE),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}):Play()
	task.delay(POP_TIME, function()
		if label.Parent then
			label:Destroy()
		end
	end)
end

-- Plays the feedback for a tech. `quality` is "Perfect", "Clean" or "Miss";
-- `pos` defaults to your feet.
function TechFeedback.play(name: string, quality: string, pos: Vector3?)
	local root = controllers.MovementController.root()
	local at = pos
	if not at and root then
		at = root.Position - Vector3.new(0, controllers.MovementController.standHeight(), 0)
	end
	if quality == "Perfect" then
		controllers.AudioController.play("TechPerfect")
		doFlash(C.Perfect, 0.18)
		if at then
			controllers.EffectsController.burst(at, C.Perfect, 18, 16)
		end
		pop(name, C.Perfect, 22)
	elseif quality == "Clean" then
		controllers.AudioController.play("Tech")
		if at then
			controllers.EffectsController.burst(at, C.Clean, 8, 10)
		end
		pop(name, C.Clean, 18)
	else
		pop(name, C.Muted, 16)
	end
end

-- os.clock() of the last pop (tests and the debug HUD).
function TechFeedback.lastPopAt(): number
	return popAt
end

function TechFeedback.Init(c: any)
	controllers = c
end

function TechFeedback.Start() end

return TechFeedback
