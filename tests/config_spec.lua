-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local config = require("crust.config")

describe("config", function()
	before_each(function()
		config.options = {}
		config.config = nil
	end)

	describe("get", function()
		it("returns defaults if setup not called", function()
			local cfg = config.get()
			assert.is_not_nil(cfg)
			assert.True(vim.deep_equal(cfg, config.defaults))
		end)

		it("returns same instance on multiple calls", function()
			config.setup({})
			local opts1 = config.get()
			local opts2 = config.get()
			assert.are.equal(opts1, opts2)
		end)
	end)
end)