-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Output = require("crust.ui.chat.output")
local Preview = require("crust.ui.chat.tools.preview")
local Tools = require("crust.ui.chat.tools")
local config = require("crust.config")

---@param text string
---@return Crust.Pi.ToolResult
local function result(text)
	return { content = { { type = "text", text = text } } }
end

--- A finished bash call with `command` and `output`.
---@param output Crust.Chat.Output
---@param tools Crust.Chat.Tools
---@param command string
---@param text string
local function bash(output, tools, command, text)
	tools:render(output, {
		type = "tool_execution_start",
		toolCallId = "a",
		toolName = "bash",
		args = { command = command },
	})
	tools:render(output, {
		type = "tool_execution_end",
		toolCallId = "a",
		toolName = "bash",
		args = { command = command },
		result = result(text),
	})
end

describe("ui.chat.tools.preview", function()
	---@type Crust.Chat.Output
	local out
	---@type Crust.Chat.Tools
	local tools

	before_each(function()
		config.options = {}
		config.config = nil
		out = Output.new()
		tools = Tools.new()
	end)

	after_each(function()
		Preview.close()
		out:close()
		config.options = {}
		config.config = nil
	end)

	describe("content", function()
		it("shows the command whole, newlines and all", function()
			local command = "for file in *.lua; do\n\techo $file\ndone"
			bash(out, tools, command, "a.lua")

			local lines = Preview.content(assert(tools:display("a"))).lines
			assert.are.equal("for file in *.lua; do", lines[2])
			assert.are.equal("\techo $file", lines[3])
			assert.are.equal("done", lines[4])
		end)

		it("shows the output past the tail the block cuts it to", function()
			local text = {}
			for index = 1, 40 do
				text[index] = "line " .. index
			end
			bash(out, tools, "seq", table.concat(text, "\n"))

			local display = assert(tools:display("a"))
			local drawn = table.concat(display:lines(), "\n")
			assert.is_falsy(drawn:find("line 1\n", 1, true))

			local lines = Preview.content(display).lines
			assert.is_truthy(vim.tbl_contains(lines, "line 1"))
			assert.is_truthy(vim.tbl_contains(lines, "line 40"))
		end)

		it("highlights the title with the spec's language", function()
			bash(out, tools, "echo hello", "hello")

			local content = Preview.content(assert(tools:display("a")))
			local groups = vim.tbl_map(function(hl)
				return hl.group
			end, content.highlights)
			assert.is_true(vim.tbl_contains(groups, require("crust.ui.highlights").TOOL_TITLE))

			-- The bash parser colours the command on top of that, when it is
			-- installed: CI without the grammar still gets the flat group.
			if require("crust.ui.syntax").available("bash") then
				local colored = vim.tbl_filter(function(hl)
					return hl.line == 2 and hl.group:sub(1, 1) == "@"
				end, content.highlights)
				assert.is_true(#colored > 0)
			end
		end)

		it("strips the ansi escapes of the output", function()
			bash(out, tools, "ls", "\27[31mred\27[0m")

			local lines = Preview.content(assert(tools:display("a"))).lines
			assert.is_true(vim.tbl_contains(lines, "red"))
		end)

		it("says so when a call has no output yet", function()
			tools:render(out, {
				type = "tool_execution_start",
				toolCallId = "a",
				toolName = "bash",
				args = { command = "sleep 10" },
			})

			local lines = Preview.content(assert(tools:display("a"))).lines
			assert.are.equal("running…", lines[#lines])
		end)

		it("prefers the diff of a write over its confirmation line", function()
			tools:render(out, {
				type = "tool_execution_end",
				toolCallId = "w",
				toolName = "write",
				args = { path = "init.lua", content = "one\n" },
				result = {
					content = { { type = "text", text = "wrote init.lua" } },
					details = { diff = "--- a\n+++ b\n+one" },
				},
			})

			local lines = Preview.content(assert(tools:display("w"))).lines
			assert.is_true(vim.tbl_contains(lines, "+one"))
			assert.is_false(vim.tbl_contains(lines, "wrote init.lua"))
		end)
	end)

	describe("lookup", function()
		it("finds the call under the cursor", function()
			out:header("󰚩", require("crust.ui.highlights").AGENT_TITLE, 0)
			out:append("before\n")
			bash(out, tools, "ls", "a.lua")

			local block = assert(tools._blocks["a"])
			local row = assert(out:view():block_row(block))
			assert.are.equal(tools:display("a"), tools:display_at(out:block_at(row)))
		end)

		it("has nothing to show on prose", function()
			out:header("󰚩", require("crust.ui.highlights").AGENT_TITLE, 0)
			out:append("just text\n")

			assert.is_nil(out:block_at(0))
			assert.is_nil(tools:display_at(nil))
		end)
	end)

	describe("window", function()
		it("opens a focused float and closes it again", function()
			bash(out, tools, "ls", "a.lua")

			local win = assert(Preview.open(assert(tools:display("a"))))
			assert.are.equal(win, vim.api.nvim_get_current_win())
			assert.are.equal("editor", vim.api.nvim_win_get_config(win).relative)

			assert.is_true(Preview.close())
			assert.is_false(vim.api.nvim_win_is_valid(win))
			assert.is_nil(Preview.win())
		end)

		it("replaces the float a second preview would stack on", function()
			bash(out, tools, "ls", "a.lua")

			local first = assert(Preview.open(assert(tools:display("a"))))
			local second = assert(Preview.open(assert(tools:display("a"))))

			assert.is_false(vim.api.nvim_win_is_valid(first))
			assert.are.equal(second, Preview.win())
		end)
	end)
end)
