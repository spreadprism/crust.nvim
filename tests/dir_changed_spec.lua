---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local crust = require("crust")
local config = require("crust.config")
local Cache = require("crust.sessions.cache")

describe("DirChanged", function()
	local cwd

	before_each(function()
		cwd = vim.fn.getcwd()
		crust.stop()
		Cache.stop()
		config.options = nil
		config.config = nil
		crust.watch_dir()
	end)

	after_each(function()
		vim.api.nvim_set_current_dir(cwd)
		pcall(vim.api.nvim_del_augroup_by_name, "crust.dir")
		crust.stop()
		Cache.stop()
		config.options = nil
		config.config = nil
	end)

	it("drops the chat when the cwd moves", function()
		local chat = crust.chat()
		chat:open()
		assert.is_true(chat:is_visible())

		local other = vim.fn.tempname()
		vim.fn.mkdir(other, "p")
		vim.api.nvim_set_current_dir(other)

		assert.is_false(chat:is_visible())
		assert.are_not.equal(chat, crust.chat())
	end)

	it("keeps the chat when the cwd does not actually change", function()
		local chat = crust.chat()
		crust.dir_changed(vim.fn.getcwd())
		assert.are.equal(chat, crust.chat())
	end)
end)
