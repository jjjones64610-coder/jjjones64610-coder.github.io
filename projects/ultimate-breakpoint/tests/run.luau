-- Entry point: `lune run tests/run.luau` from the project root.
local process = require("@lune/process")
local H = require("./harness")

local specs = {
	movement = function()
		return require("./movement_spec")
	end,
	disc = function()
		return require("./disc_spec")
	end,
	throw = function()
		return require("./throw_spec")
	end,
	catch = function()
		return require("./catch_spec")
	end,
	rules = function()
		return require("./rules_spec")
	end,
	combo = function()
		return require("./combo_spec")
	end,
	misc = function()
		return require("./misc_spec")
	end,
	modes = function()
		return require("./modes_spec")
	end,
	signatures = function()
		return require("./signatures_spec")
	end,
	tech = function()
		return require("./tech_spec")
	end,
}

local order = { "movement", "disc", "throw", "catch", "rules", "combo", "misc", "modes", "signatures", "tech" }
local only = process.args[1]

for _, name in order do
	if only == nil or only == name then
		local ok, err = pcall(specs[name])
		if not ok then
			H.test("load " .. name .. " spec", function()
				error(err)
			end)
		end
	end
end

local r = H.results()
print(string.format("\n%d passed, %d failed", r.passed, r.failed))
if r.failed > 0 then
	for _, f in r.failures do
		print(" - " .. f)
	end
	process.exit(1)
end
