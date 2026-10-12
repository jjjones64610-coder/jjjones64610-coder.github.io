--[[
	Offline test harness (runs under Lune: https://lune-org.github.io).

	Loads the pure shared modules from src/shared exactly as Roblox would:
	each module receives a `script` object whose `.Parent` chain mirrors the
	Rojo folder layout, and `require(script.Parent.X)` resolves to the matching
	.luau file. Roblox datatypes (Vector3, CFrame, ...) come from @lune/roblox.

	Only modules that do not touch Instances are loaded here. Everything that
	needs the engine is verified in Roblox Studio (see docs/TESTING.md).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Harness = {}

local cache: { [string]: any } = {}
local nodeCache: { [string]: any } = {}

local function dirname(p: string): string
	local d = string.match(p, "^(.*)/[^/]+$")
	return d or "."
end

local makeNode

local function resolveFile(path: string): string?
	if fs.isFile(path .. ".luau") then
		return path .. ".luau"
	elseif fs.isFile(path .. ".lua") then
		return path .. ".lua"
	elseif fs.isDir(path) and fs.isFile(path .. "/init.luau") then
		return path .. "/init.luau"
	end
	return nil
end

function makeNode(path: string)
	local existing = nodeCache[path]
	if existing then
		return existing
	end
	local node = setmetatable({ __path = path }, {
		__index = function(_self, key)
			if key == "Parent" then
				return makeNode(dirname(path))
			end
			return makeNode(path .. "/" .. tostring(key))
		end,
		__tostring = function()
			return "Node(" .. path .. ")"
		end,
	})
	nodeCache[path] = node
	return node
end

local requireModule

local stubGame = {
	GetService = function(_self, name: string)
		if name == "RunService" then
			return {
				IsServer = function()
					return true
				end,
				IsClient = function()
					return false
				end,
				IsStudio = function()
					return true
				end,
			}
		end
		error("[harness] game:GetService('" .. name .. "') is not available offline")
	end,
}

local function makeEnv(node)
	local env = {
		script = node,
		require = function(target)
			return requireModule(target)
		end,
		game = stubGame,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		NumberRange = roblox.NumberRange,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		typeof = typeof,
		warn = function(...)
			print("[warn]", ...)
		end,
	}
	return setmetatable(env, { __index = _G })
end

function requireModule(node)
	if type(node) ~= "table" or rawget(node, "__path") == nil then
		error("[harness] require expects a script node, got " .. tostring(node))
	end
	local path = rawget(node, "__path")
	local file = resolveFile(path)
	if not file then
		error("[harness] module not found: " .. path)
	end
	if cache[file] ~= nil then
		return cache[file]
	end
	local source = fs.readFile(file)
	local fn = luau.load(source, {
		debugName = file,
		environment = makeEnv(makeNode(string.gsub(file, "%.luau?$", ""))),
	})
	local result = fn()
	cache[file] = result
	return result
end

function Harness.require(relativePath: string)
	return requireModule(makeNode("src/shared/" .. relativePath))
end

-- minimal assertion / reporting helpers --------------------------------------

local results = { passed = 0, failed = 0, failures = {} }

function Harness.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		results.passed += 1
		print("  ok   " .. name)
	else
		results.failed += 1
		table.insert(results.failures, name .. ": " .. tostring(err))
		print("  FAIL " .. name .. "\n       " .. tostring(err))
	end
end

function Harness.expect(cond: any, msg: string?)
	if not cond then
		error(msg or "expectation failed", 2)
	end
end

function Harness.near(a: number, b: number, tol: number, msg: string?)
	if math.abs(a - b) > tol then
		error(string.format("%s: expected %.4f ~ %.4f (tol %.4f)", msg or "near", a, b, tol), 2)
	end
end

function Harness.results()
	return results
end

return Harness
