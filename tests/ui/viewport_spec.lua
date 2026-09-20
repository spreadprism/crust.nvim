-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Output = require("crust.ui.chat.output")
local Highlights = require("crust.ui.highlights")
local config = require("crust.config")

describe("ui.chat.viewport", function()
	---@type Crust.Chat.Output
	local out

	---@param viewport table
	local function configure(viewport)
		config.options = { output = { viewport = viewport } }
		config.config = nil
	end

	--- `count` messages of `body_lines` lines each.
	---@param output Crust.Chat.Output
	---@param count integer
	---@param body_lines? integer
	local function conversation(output, count, body_lines)
		for index = 1, count do
			output:header("󰚩", Highlights.AGENT_TITLE, 0)
			for line = 1, body_lines or 1 do
				output:append("message " .. index .. " line " .. line .. "\n")
			end
		end
	end

	---@return string[]
	local function drawn()
		return vim.api.nvim_buf_get_lines(out:buf(), 0, -1, false)
	end

	before_each(function()
		configure({ enabled = true, max_sections = 3, max_lines = 1000, guard_lines = 2 })
		out = Output.new()
	end)

	after_each(function()
		out:close()
		config.options = {}
		config.config = nil
	end)

	describe("selection", function()
		it("draws everything while the transcript is small", function()
			conversation(out, 2)
			assert.are.same(out:lines(), drawn())
			assert.are.same({ 1, 2 }, { out:view():range() })
		end)

		it("keeps only the budget around the newest message", function()
			conversation(out, 10)

			local first, last = out:view():range()
			assert.are.equal(10, last)
			assert.are.equal(8, first)
			assert.is_true(#drawn() < #out:lines())
		end)

		it("never splits a message, whatever the line budget", function()
			configure({ enabled = true, max_sections = 40, max_lines = 4, guard_lines = 2 })
			-- A second panel wipes the first one's buffer, so `out` is done here.
			out = Output.new()
			conversation(out, 5, 6)

			assert.are.same({ 5, 5 }, { out:view():range() })
			-- The whole message is there, cap or no cap.
			assert.is_truthy(table.concat(drawn(), "\n"):find("message 5 line 6", 1, true))
		end)

		it("renders the whole transcript when the viewport is off", function()
			configure({ enabled = false, max_sections = 3, max_lines = 10, guard_lines = 2 })
			out = Output.new()
			conversation(out, 10)

			assert.are.same(out:lines(), drawn())
		end)

		it("keeps the transcript complete behind the view", function()
			conversation(out, 10)
			local text = table.concat(out:lines(), "\n")
			for index = 1, 10 do
				assert.is_truthy(text:find("message " .. index .. " line 1", 1, true))
			end
		end)
	end)

	describe("markers", function()
		it("announces the elided messages above", function()
			conversation(out, 10)
			assert.are.equal("⋯ 7 earlier messages ⋯", drawn()[1])
		end)

		it("highlights the marker", function()
			conversation(out, 10)
			local marks = vim.api.nvim_buf_get_extmarks(out:buf(), out:view().ns, 0, { 0, -1 }, { details = true })
			local groups = vim.tbl_map(function(mark)
				return mark[4].hl_group
			end, marks)
			assert.is_true(vim.tbl_contains(groups, Highlights.ELISION))
		end)

		it("announces the newer messages below", function()
			conversation(out, 10)
			out:view():set_anchor(5)
			out:view():rebuild()

			local lines = drawn()
			assert.are.equal("⋯ 3 earlier messages ⋯", lines[1])
			assert.are.equal("⋯ 4 newer messages ⋯", lines[#lines])
		end)

		it("keeps the count fresh when a message lands off screen", function()
			conversation(out, 10)
			out:view():set_anchor(2)
			out:view():rebuild()
			out._following = false

			conversation(out, 1)
			assert.are.equal("⋯ 8 newer messages ⋯", drawn()[#drawn()])
		end)
	end)

	describe("streaming", function()
		it("costs nothing while the tail is off screen", function()
			conversation(out, 10)
			out:view():set_anchor(2)
			out:view():rebuild()
			out._following = false

			local before = drawn()
			out:append("invisible delta")

			assert.are.same(before, drawn())
			assert.is_truthy(table.concat(out:lines(), "\n"):find("invisible delta", 1, true))
		end)

		it("comes back on screen when the view follows again", function()
			conversation(out, 10)
			out:view():set_anchor(2)
			out:view():rebuild()
			out._following = false
			out:append("late delta")

			out:follow()
			assert.is_truthy(table.concat(drawn(), "\n"):find("late delta", 1, true))
		end)

		it("keeps writing into the drawn tail", function()
			conversation(out, 10)
			out:append("visible delta")
			assert.is_truthy(table.concat(drawn(), "\n"):find("visible delta", 1, true))
		end)
	end)

	describe("blocks", function()
		it("draws the highlights of a block in the view", function()
			conversation(out, 3)
			out:append_block({ "tool" }, { { line = 1, col = 0, end_col = 4, group = Highlights.TOOL } })

			local marks = vim.api.nvim_buf_get_extmarks(out:buf(), out:view().ns, 0, -1, { details = true })
			local groups = vim.tbl_map(function(mark)
				return mark[4].hl_group
			end, marks)
			assert.is_true(vim.tbl_contains(groups, Highlights.TOOL))
		end)

		it("only reports the blocks on screen to the markdown exclusion", function()
			conversation(out, 1)
			out:append_block({ "tool" })
			conversation(out, 10)

			assert.are.same({}, out:view():block_ranges())
		end)

		it("rewrites a block that scrolled back into view", function()
			conversation(out, 1)
			local block = out:append_block({ "pending" })
			conversation(out, 10)

			out:replace_block(block, { "done" })
			assert.is_truthy(table.concat(out:lines(), "\n"):find("done", 1, true))

			out:view():set_anchor(1)
			out:view():rebuild()
			assert.is_truthy(table.concat(drawn(), "\n"):find("done", 1, true))
		end)
	end)

	describe("scrolling", function()
		before_each(function()
			out:open(60)
		end)

		it("pulls older messages in at the top", function()
			conversation(out, 10)
			local first = out:view():range()

			vim.api.nvim_win_set_cursor(assert(out:win()), { 1, 0 })
			out:_on_scroll()

			assert.is_true(out:view():range() < first)
		end)

		it("keeps the line under the cursor where it was", function()
			conversation(out, 10)

			local win = assert(out:win())
			-- The header of the oldest drawn message, right under the marker.
			local row = assert(out:view():row(out:view():range())) + 1
			vim.api.nvim_win_set_cursor(win, { row, 0 })
			local before = vim.api.nvim_buf_get_lines(out:buf(), row - 1, row, false)[1]

			out:_on_scroll()

			local row = vim.api.nvim_win_get_cursor(win)[1]
			assert.are.equal(before, vim.api.nvim_buf_get_lines(out:buf(), row - 1, row, false)[1])
		end)

		it("stops following once the cursor leaves the newest message", function()
			conversation(out, 10)
			assert.is_true(out._following)

			vim.api.nvim_win_set_cursor(assert(out:win()), { 1, 0 })
			out:_on_scroll()
			assert.is_false(out._following)
		end)

		it("follows again from the bottom", function()
			conversation(out, 10)
			out:view():set_anchor(2)
			out:view():rebuild()
			out._following = false

			out:follow()
			out:_on_scroll()
			assert.is_true(out._following)
		end)
	end)
end)
