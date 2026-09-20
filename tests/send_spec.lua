-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Send = require("crust.send")
local Input = require("crust.ui.chat.input")

describe("send", function()
	local buf
	local dir

	before_each(function()
		dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		buf = vim.api.nvim_create_buf(false, true)
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		vim.fn.delete(dir, "rf")
		package.loaded["oil"] = nil
	end)

	---@param path string
	local function open(path)
		vim.api.nvim_buf_set_name(buf, path)
		vim.api.nvim_win_set_buf(0, buf)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
	end

	describe("a file buffer", function()
		it("mentions the file itself in normal mode", function()
			open(dir .. "/init.lua")
			assert.are.equal("@" .. Send.relative(dir) .. "/init.lua", Send.mention({ visual = false }))
		end)

		it("mentions the selected range in visual mode", function()
			open(dir .. "/init.lua")
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			vim.cmd("normal! Vjj")

			assert.are.equal("@" .. Send.relative(dir) .. "/init.lua:2-4", Send.mention())
			vim.cmd("normal! \27")
		end)

		it("mentions a single line without a range", function()
			open(dir .. "/init.lua")
			vim.api.nvim_win_set_cursor(0, { 3, 0 })
			vim.cmd("normal! V")

			assert.are.equal("@" .. Send.relative(dir) .. "/init.lua:3", Send.mention())
			vim.cmd("normal! \27")
		end)

		it("reads the marks when the caller already left visual mode", function()
			open(dir .. "/init.lua")
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("normal! Vj")
			vim.cmd("normal! \27")

			assert.are.equal("@" .. Send.relative(dir) .. "/init.lua:1-2", Send.mention({ visual = true }))
		end)

		it("takes an explicit range, like `:'<,'>Crust send`", function()
			open(dir .. "/init.lua")
			assert.are.equal(
				"@" .. Send.relative(dir) .. "/init.lua:2-3",
				Send.mention({ first = 2, last = 3 })
			)
		end)

		it("has nothing to send for an unnamed buffer", function()
			vim.api.nvim_win_set_buf(0, buf)
			assert.is_nil(Send.mention({ visual = false }))
		end)
	end)

	describe("an oil buffer", function()
		before_each(function()
			vim.bo[buf].filetype = "oil"
			vim.api.nvim_win_set_buf(0, buf)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "../", "init.lua", "lua/", "README.md" })

			package.loaded["oil"] = {
				get_current_dir = function()
					return dir
				end,
				get_entry_on_line = function(_, lnum)
					local entries = {
						{ name = "..", type = "directory" },
						{ name = "init.lua", type = "file" },
						{ name = "lua", type = "directory" },
						{ name = "README.md", type = "file" },
					}
					return entries[lnum]
				end,
			}
		end)

		it("mentions the browsed directory in normal mode", function()
			assert.are.equal("@" .. Send.relative(dir) .. "/", Send.mention({ visual = false }))
		end)

		it("mentions every selected entry in visual mode", function()
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			vim.cmd("normal! Vjj")

			local root = "@" .. Send.relative(dir)
			assert.are.equal(root .. "/init.lua " .. root .. "/lua/ " .. root .. "/README.md", Send.mention())
			vim.cmd("normal! \27")
		end)

		it("skips the parent entry", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("normal! Vj")

			assert.are.equal("@" .. Send.relative(dir) .. "/init.lua", Send.mention())
			vim.cmd("normal! \27")
		end)
	end)

	describe("input:append", function()
		---@type Crust.Chat.Input
		local input

		before_each(function()
			input = Input.new(function() end)
		end)

		it("fills an empty prompt", function()
			input:append("@init.lua")
			assert.are.equal("@init.lua", input:text())
		end)

		it("keeps what is typed and separates with a space", function()
			input:set_text("look at")
			input:append("@init.lua")
			assert.are.equal("look at @init.lua", input:text())
		end)

		it("does not double the separator", function()
			input:set_text("look at ")
			input:append("@init.lua")
			assert.are.equal("look at @init.lua", input:text())
		end)

		it("ignores empty text", function()
			input:set_text("kept")
			input:append("")
			assert.are.equal("kept", input:text())
		end)
	end)

	describe("smart", function()
		local crust = require("crust")
		---@type Crust.Chat
		local chat
		local opened, sent, focused

		before_each(function()
			opened, sent, focused = false, false, false
			chat = crust.chat()
			chat.open = function()
				opened = true
			end
			chat.is_visible = function()
				return false
			end
			chat.input = function()
				return { focus = function()
					focused = true
				end }
			end
			crust.send = function()
				sent = true
				return true
			end
		end)

		after_each(function()
			package.loaded["crust"] = nil
			package.loaded["crust.ui.chat"] = nil
		end)

		it("opens the panel while it is away", function()
			assert.is_false(crust.smart())
			assert.is_true(opened)
			assert.is_false(sent)
		end)

		it("sends context once the panel is up", function()
			chat.is_visible = function()
				return true
			end

			assert.is_true(crust.smart({ buf = buf }))
			assert.is_true(sent)
			assert.is_false(opened)
		end)

		it("only focuses the prompt when called from the chat itself", function()
			chat.is_visible = function()
				return true
			end
			local output_buf, input_buf = chat:bufs()

			assert.is_false(crust.smart({ buf = input_buf }))
			assert.is_true(focused)
			assert.is_false(sent)

			focused = false
			assert.is_false(crust.smart({ buf = output_buf }))
			assert.is_true(focused)
			assert.is_false(sent)
		end)
	end)

	describe("input:focus", function()
		---@type Crust.Chat.Input
		local input
		local config = require("crust.config")
		local cmd
		local commands

		before_each(function()
			config.options = {}
			config.config = nil
			input = Input.new(function() end)
			vim.cmd("new")
			input._win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(input._win, input:buf())

			-- `startinsert` only takes effect back in the main loop, so the
			-- mode cannot be read here: the command itself is what is checked.
			commands = {}
			cmd = vim.cmd
			vim.cmd = function(command)
				commands[#commands + 1] = command
			end
		end)

		after_each(function()
			vim.cmd = cmd
			if input:win() then
				vim.api.nvim_win_close(input._win, true)
			end
			config.options = {}
			config.config = nil
		end)

		it("focuses without starting insert mode by default", function()
			input:focus()
			assert.are.equal(input._win, vim.api.nvim_get_current_win())
			assert.are.same({}, commands)
		end)

		it("starts insert mode with window.auto_insert", function()
			config.setup({ window = { auto_insert = true } })
			input:focus()
			assert.are.same({ "startinsert" }, commands)
		end)

		it("takes a per-call override", function()
			input:focus(true)
			assert.are.same({ "startinsert" }, commands)
		end)
	end)
end)
