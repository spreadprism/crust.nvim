-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Syntax = require("crust.ui.syntax")

--- "lua" ships with neovim, "bash" comes from nvim-treesitter and is not
--- available in the isolated test runner.
local LANG = "lua"

describe("ui.syntax", function()
	it("reports installed parsers", function()
		assert.is_true(Syntax.available(LANG))
		assert.is_false(Syntax.available("definitely-not-a-language"))
	end)

	it("returns nil for an unavailable language", function()
		assert.is_nil(Syntax.highlight("local x = 1", "definitely-not-a-language"))
	end)

	it("returns nil for empty text", function()
		assert.is_nil(Syntax.highlight("", LANG))
	end)

	it("highlights code", function()
		local ranges = Syntax.highlight('local x = "hi"', LANG)
		local groups = vim.tbl_map(function(range)
			return range.group
		end, ranges)

		assert.is_truthy(vim.tbl_contains(groups, "@keyword"))
		assert.is_truthy(vim.tbl_contains(groups, "@string"))
	end)

	it("reports 1-based lines and byte columns inside each line", function()
		local text = 'local a = "one"\nlocal b = "two"'
		local lines = vim.split(text, "\n", { plain = true })
		local ranges = Syntax.highlight(text, LANG)

		local seen = {}
		for _, range in ipairs(ranges) do
			seen[range.line] = true
			assert.is_not_nil(lines[range.line])
			assert.is_true(range.col >= 0)
			assert.is_true(range.end_col <= #lines[range.line])
		end

		assert.is_true(seen[1])
		assert.is_true(seen[2])
	end)

	it("caches availability lookups", function()
		assert.are.equal(Syntax.available(LANG), Syntax.available(LANG))
	end)
end)