-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

--- What a tool call actually looks like *in the buffer*.
---
--- `tools_spec` checks what a display renders; these specs check that the
--- render survives the trip into the buffer. It does not always: rewriting
--- rows drops their extmarks, and a block appended under another one
--- continues its last line, which used to leave the call above plain white
--- (no icon, no title, no shading).

local Highlights = require("crust.ui.highlights")
local Output = require("crust.ui.chat.output")
local Tools = require("crust.ui.chat.tools")
local config = require("crust.config")

---@param text string
---@return Crust.Pi.ToolResult
local function result(text)
	return { content = { { type = "text", text = text } } }
end

describe("ui.chat.tools highlighting", function()
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
		out:close()
		config.options = {}
		config.config = nil
	end)

	---@param id string
	---@param name string
	---@param args table
	local function start(id, name, args)
		tools:render(out, { type = "tool_execution_start", toolCallId = id, toolName = name, args = args })
	end

	---@param id string
	---@param name string
	---@param args table
	---@param text string
	---@param details? table
	---@param is_error? boolean
	local function finish(id, name, args, text, details, is_error)
		tools:render(out, {
			type = "tool_execution_end",
			toolCallId = id,
			toolName = name,
			args = args,
			isError = is_error,
			result = vim.tbl_extend("force", result(text), { details = details }),
		})
	end

	---@param id string
	---@return integer 0-based row of the call's first line
	local function row_of(id)
		return assert(out:block_row(assert(tools._blocks[id])))
	end

	--- Highlight groups drawn on a buffer row, background included.
	---@param row integer 0-based
	---@return string[]
	local function groups(row)
		local marks = vim.api.nvim_buf_get_extmarks(out:buf(), Output.hl_ns, { row, 0 }, { row, -1 }, {
			details = true,
		})
		local found = {}
		for _, mark in ipairs(marks) do
			found[#found + 1] = mark[4].hl_group or mark[4].line_hl_group
		end
		return found
	end

	---@param row integer
	---@param group string
	---@param message? string
	local function assert_group(row, group, message)
		assert.is_true(vim.tbl_contains(groups(row), group), (message or "row " .. row) .. " is missing " .. group)
	end

	--- Every call renders the same four things: the quote marker, the status
	--- icon, the tool name and the shaded background.
	---@param row integer
	local function assert_call(row)
		assert_group(row, Highlights.TOOL_PREFIX)
		assert_group(row, Highlights.TOOL)
		assert_group(row, Highlights.TOOL_BACKGROUND)
	end

	describe("a single call", function()
		it("draws the icon, name, title and body of a write", function()
			finish("w", "write", { path = "a.lua", content = "one\ntwo\n" }, "wrote a.lua")

			local row = row_of("w")
			assert_call(row)
			assert_group(row, Highlights.TOOL_ICON_SUCCESS)
			assert_group(row, Highlights.TOOL_TITLE)
			assert_group(row, Highlights.TOOL_BODY_INLINE)
		end)

		it("keeps the pending highlights until the call ends", function()
			start("b", "bash", { command = "sleep 1" })
			assert_group(row_of("b"), Highlights.TOOL_ICON_PENDING)

			finish("b", "bash", { command = "sleep 1" }, "done")
			assert_group(row_of("b"), Highlights.TOOL_ICON_SUCCESS)
			assert.is_false(vim.tbl_contains(groups(row_of("b")), Highlights.TOOL_ICON_PENDING))
		end)

		it("colours the diff counters of an edit", function()
			finish("e", "edit", { path = "a.lua", edits = { {} } }, "ok", { diff = "+one\n-two" })

			local row = row_of("e")
			assert_group(row, Highlights.DIFF_ADD)
			assert_group(row, Highlights.DIFF_DELETE)
		end)

		it("shades every line of a multi-line call", function()
			finish("r", "read", { path = "a.lua" }, "no such file", nil, true)

			local row = row_of("r")
			assert_call(row)
			assert_group(row, Highlights.TOOL_ICON_ERROR)
			-- The error message goes under the title, on its own shaded lines.
			assert_group(row + 1, Highlights.TOOL_BODY_BACKGROUND)
			assert_group(row + 1, Highlights.TOOL_BODY)
		end)
	end)

	describe("stacked calls", function()
		--- A write without a diff, then an edit with one: the pair from the
		--- report where the write came out plain white.
		local function write_then_edit()
			finish("w", "write", { path = "a.lua", content = "one\n" }, "wrote a.lua")
			finish("e", "edit", { path = "a.lua", edits = { {} } }, "ok", { diff = "+one\n-two" })
		end

		it("keeps the first call highlighted when a second is stacked on it", function()
			write_then_edit()

			assert_call(row_of("w"))
			assert_group(row_of("w"), Highlights.TOOL_TITLE)
			assert_group(row_of("w"), Highlights.TOOL_BODY_INLINE)
			assert_call(row_of("e"))
		end)

		it("leaves no shading behind on the blank line under the block", function()
			write_then_edit()

			local below = row_of("e") + 1
			assert.are.same({}, groups(below))
		end)

		it("survives a call that is rewritten while stacked", function()
			start("w", "write", { path = "a.lua", content = "one\n" })
			start("e", "edit", { path = "a.lua", edits = { {} } })
			finish("w", "write", { path = "a.lua", content = "one\n" }, "wrote a.lua")
			finish("e", "edit", { path = "a.lua", edits = { {} } }, "ok", { diff = "+one" })

			assert_call(row_of("w"))
			assert_call(row_of("e"))
			assert_group(row_of("w"), Highlights.TOOL_ICON_SUCCESS)
			assert_group(row_of("e"), Highlights.DIFF_ADD)
		end)

		it("keeps three calls in a row highlighted", function()
			finish("a", "read", { path = "a.lua" }, "one\ntwo")
			finish("b", "read", { path = "b.lua" }, "one")
			finish("c", "read", { path = "c.lua" }, "one")

			for _, id in ipairs({ "a", "b", "c" }) do
				assert_call(row_of(id))
				assert_group(row_of(id), Highlights.TOOL_TITLE)
			end
		end)
	end)

	describe("around the call", function()
		it("keeps the message header highlighted when a call opens the message", function()
			out:header("󰚩", Highlights.AGENT_TITLE, 0)
			finish("w", "write", { path = "a.lua", content = "one\n" }, "wrote a.lua")

			-- The header is the line the message opens with: the first row of
			-- the call, minus its blank line and the header row itself.
			local row = row_of("w") - 2
			assert_group(row, Highlights.AGENT_TITLE)
			assert_group(row, Highlights.TIMESTAMP)
		end)

		it("keeps the call highlighted while text streams under it", function()
			out:header("󰚩", Highlights.AGENT_TITLE, 0)
			finish("b", "bash", { command = "ls" }, "a.lua")

			local row = row_of("b")
			for _, delta in ipairs({ "all ", "done", "\n" }) do
				out:append(delta)
			end

			assert_call(row)
			assert_group(row, Highlights.TOOL_TITLE)
		end)

		it("keeps the calls highlighted when a new message is opened under them", function()
			out:header("󰚩", Highlights.AGENT_TITLE, 0)
			finish("w", "write", { path = "a.lua", content = "one\n" }, "wrote a.lua")
			finish("e", "edit", { path = "a.lua", edits = { {} } }, "ok", { diff = "+one" })

			local before = { groups(row_of("w")), groups(row_of("e")) }
			out:header("", Highlights.USER_TITLE, 0)

			assert.are.same(before[1], groups(row_of("w")))
			assert.are.same(before[2], groups(row_of("e")))
		end)
	end)
end)
