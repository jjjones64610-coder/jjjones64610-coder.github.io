--!strict
--[[
	JerseyService — team kits. Every character on TIDE or BLAZE (players and
	bots) wears that team's jersey and shorts (Config/Teams Shirt / Pants,
	ForgeGUI-made clothing templates) with a number on the back; sideline
	players wear their own clothes. It re-dresses on spawn and whenever the
	character's team (UBTeam) changes, and puts the player's own clothes back
	when they leave a team.

	If a team has no template ids yet, the jersey is drawn with body colours:
	torso and arms in the team colour, legs in its dark shade.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local TeamsConfig = require(Shared.Config.Teams)

local JerseyService = {}

local services: any
local numbers: { [number]: number } = {} -- actor id -> jersey number
local nextNumber = 1

local TORSO = { "UpperTorso", "LowerTorso", "Torso" }
local ARMS = { "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm", "Left Arm", "Right Arm" }
local LEGS = { "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "Left Leg", "Right Leg" }

local function numberFor(id: number): number
	local n = numbers[id]
	if n == nil then
		-- 1..99, handed out in join order and skipping a few for variety
		n = ((nextNumber * 7) % 99) + 1
		nextNumber += 1
		numbers[id] = n
	end
	return n
end

-- Stores the character's own clothes the first time it is dressed.
local function remember(model: Model)
	if model:FindFirstChild("UBOwnClothes") then
		return
	end
	local store = Instance.new("Folder")
	store.Name = "UBOwnClothes"
	for _, c in model:GetChildren() do
		if c:IsA("Shirt") or c:IsA("Pants") or c:IsA("ShirtGraphic") then
			(c :: Instance).Parent = store
		end
	end
	local bc = model:FindFirstChildOfClass("BodyColors")
	if bc then
		bc:Clone().Parent = store
	end
	store.Parent = model
end

local function clearKit(model: Model)
	for _, c in model:GetChildren() do
		if c:GetAttribute("UBKit") == true then
			c:Destroy()
		end
	end
	for _, part in model:GetChildren() do
		local n = part:FindFirstChild("UBNumber")
		if n then
			n:Destroy()
		end
	end
end

local function restore(model: Model)
	clearKit(model)
	local store = model:FindFirstChild("UBOwnClothes")
	if not store then
		return
	end
	local bc = model:FindFirstChildOfClass("BodyColors")
	for _, c in store:GetChildren() do
		if c:IsA("BodyColors") then
			if bc then
				bc:Destroy()
			end
			c:Clone().Parent = model
		else
			c:Clone().Parent = model
		end
	end
	store:Destroy()
end

local function setPartColors(model: Model, names: { string }, color: Color3)
	for _, n in names do
		local p = model:FindFirstChild(n)
		if p and p:IsA("BasePart") then
			p.Color = color
		end
	end
end

local function addNumber(model: Model, n: number, color: Color3)
	local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
	if not torso or not torso:IsA("BasePart") then
		return
	end
	local gui = Instance.new("SurfaceGui")
	gui.Name = "UBNumber"
	gui.Face = Enum.NormalId.Back
	gui.CanvasSize = Vector2.new(200, 200)
	gui.LightInfluence = 0.6
	gui.Parent = torso
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = tostring(n)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Parent = gui
end

-- Dresses `model` for `team` ("A" / "B"), or gives back its own clothes.
function JerseyService.dress(model: Model, team: string?, actorId: number)
	local kit = if team == "A" then TeamsConfig.A elseif team == "B" then TeamsConfig.B else nil
	if not kit then
		restore(model)
		return
	end
	remember(model)
	clearKit(model)
	for _, c in model:GetChildren() do
		if c:IsA("Shirt") or c:IsA("Pants") or c:IsA("ShirtGraphic") then
			c:Destroy()
		end
	end
	local k = kit :: any
	if k.Shirt ~= "" then
		local s = Instance.new("Shirt")
		s.ShirtTemplate = "rbxassetid://" .. k.Shirt
		s:SetAttribute("UBKit", true)
		s.Parent = model
	end
	if k.Pants ~= "" then
		local p = Instance.new("Pants")
		p.PantsTemplate = "rbxassetid://" .. k.Pants
		p:SetAttribute("UBKit", true)
		p.Parent = model
	end
	-- body colours: the jersey colour shows where the template is missing
	if k.Shirt == "" then
		setPartColors(model, TORSO, kit.Color)
		setPartColors(model, ARMS, kit.Color)
	end
	if k.Pants == "" then
		setPartColors(model, LEGS, kit.Dark or kit.Color)
	end
	addNumber(model, numberFor(actorId), Color3.new(1, 1, 1))
end

local function watch(actor: any, model: Model)
	local function apply()
		local team = model:GetAttribute("UBTeam")
		JerseyService.dress(model, if type(team) == "string" then team else nil, actor.id)
	end
	-- clothing loads with the avatar (and the standard-body pass re-applies
	-- the description): dress after it settles, then on every team change
	task.delay(1.5, apply)
	model:GetAttributeChangedSignal("UBTeam"):Connect(apply)
	-- an avatar (re)load that brings its own clothes back gets the kit again
	model.ChildAdded:Connect(function(c)
		local team = model:GetAttribute("UBTeam")
		if
			(c:IsA("Shirt") or c:IsA("Pants") or c:IsA("ShirtGraphic"))
			and c:GetAttribute("UBKit") ~= true
			and (team == "A" or team == "B")
		then
			task.defer(apply)
		end
	end)
end

function JerseyService.Init(s: any)
	services = s
end

function JerseyService.Start()
	services.PlayerService.CharacterSpawned:Connect(watch)
	for _, actor in services.PlayerService.all() do
		if actor.character then
			watch(actor, actor.character)
		end
	end
	services.PlayerService.ActorRemoving:Connect(function(actor)
		numbers[actor.id] = nil
	end)
end

return JerseyService
