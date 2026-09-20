-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Filetypes = require("crust.filetypes")

describe("filetypes", function()
	it("names the input and output filetypes", function()
		assert.are.equal("crust_input", Filetypes.input)
		assert.are.equal("crust_output", Filetypes.output)
	end)

	it("registers both filetypes with the markdown parser", function()
		Filetypes.setup()
		assert.are.equal("markdown", vim.treesitter.language.get_lang(Filetypes.input))
		assert.are.equal("markdown", vim.treesitter.language.get_lang(Filetypes.output))
	end)

	it("is idempotent", function()
		Filetypes.setup()
		Filetypes.setup()
		assert.are.equal("markdown", vim.treesitter.language.get_lang(Filetypes.output))
	end)

	it("highlights chat buffers through the registration", function()
		local chat = require("crust.ui.chat").new()
		local out_buf, in_buf = chat:bufs()
		assert.is_not_nil(vim.treesitter.highlighter.active[out_buf])
		assert.is_not_nil(vim.treesitter.highlighter.active[in_buf])
	end)
end)