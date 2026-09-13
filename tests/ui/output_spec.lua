local Output = require("crust.ui.chat.output")
local Highlights = require("crust.ui.highlights")

describe("ui.chat.output", function()
	---@type Crust.Chat.Output
	local out

	before_each(function()
		out = Output.new()
	end)

	describe("buffer", function()
		it("uses the crust_output filetype", function()
			assert.are.equal("crust_output", vim.bo[out:buf()].filetype)
			assert.are.equal("crust_output", Output.FILETYPE)
		end)

		it("is a scratch buffer", function()
			assert.are.equal("nofile", vim.bo[out:buf()].buftype)
			assert.is_false(vim.bo[out:buf()].swapfile)
		end)
	end)

	describe("append", function()
		it("starts from an empty buffer", function()
			assert.are.same({ "" }, out:lines())
		end)

		it("continues the last line across calls", function()
			out:append("hel")
			out:append("lo")
			assert.are.same({ "hello" }, out:lines())
		end)

		it("splits on newlines", function()
			out:append("a\nb\n")
			assert.are.same({ "a", "b", "" }, out:lines())
		end)

		it("keeps the buffer unmodifiable between writes", function()
			out:append("x")
			assert.is_false(vim.bo[out:buf()].modifiable)
		end)
	end)

	describe("blocks", function()
		it("isolates the block with one blank line on each side", function()
			out:append("head")
			out:append_block({ "one" })
			assert.are.same({ "head", "", "one", "", "" }, out:lines())
		end)

		it("does not stack blank lines before a block", function()
			out:append("head\n\n\n")
			out:append_block({ "one" })
			assert.are.same({ "head", "", "one", "", "" }, out:lines())
		end)

		it("replaces a block in place instead of appending a new one", function()
			out:append("head")
			local block = out:append_block({ "pending" })
			out:replace_block(block, { "done" })
			assert.are.same({ "head", "", "done", "", "" }, out:lines())
		end)

		it("replaces the same block repeatedly (regression: drifting extmark)", function()
			local block = out:append_block({ "pending" })
			out:replace_block(block, { "pending", "  partial" })
			out:replace_block(block, { "success", "  final" })
			assert.are.same({ "success", "  final", "", "" }, out:lines())
		end)

		it("grows and shrinks a block without eating surrounding lines", function()
			out:append("head")
			local block = out:append_block({ "a" })
			out:append("tail")
			out:replace_block(block, { "a", "b", "c" })
			assert.are.same({ "head", "", "a", "b", "c", "", "tail" }, out:lines())
			out:replace_block(block, { "a" })
			assert.are.same({ "head", "", "a", "", "tail" }, out:lines())
		end)

		it("keeps a blank line between a block and text streamed after it", function()
			local block = out:append_block({ "tool" })
			out:replace_block(block, { "tool", "  output" })
			out:append("assistant text")
			assert.are.same({ "tool", "  output", "", "assistant text" }, out:lines())
		end)

		it("rewrites the right block when several are interleaved", function()
			local first = out:append_block({ "first" })
			local second = out:append_block({ "second" })
			out:replace_block(first, { "first", "  done" })
			out:replace_block(second, { "second", "  done" })
			assert.are.same({
				"first",
				"  done",
				"",
				"second",
				"  done",
				"",
				"",
			}, out:lines())
		end)
	end)

	describe("markdown regions", function()
		---@return integer[] rows of heading captures
		local function heading_rows()
			local parser = vim.treesitter.get_parser(out:buf())
			local query = vim.treesitter.query.get("markdown", "highlights")
			local rows = {}
			for _, tree in ipairs(parser:parse(true)) do
				for id, node in query:iter_captures(tree:root(), out:buf()) do
					if query.captures[id]:match("heading") then
						rows[#rows + 1] = (node:range())
					end
				end
			end
			return rows
		end

		it("keeps block rows out of the markdown tree", function()
			out:append("# prose heading\n")
			out:append_block({ "# not a heading" })
			out:append("# another heading")

			vim.wait(300, function()
				return #heading_rows() == 2
			end)
			assert.are.same({ 0, 4 }, heading_rows())
		end)

		it("follows a block that grew", function()
			local block = out:append_block({ "# one" })
			out:replace_block(block, { "# one", "# two" })

			vim.wait(300, function()
				return #heading_rows() == 0
			end)
			assert.are.same({}, heading_rows())
		end)

		it("can be turned off", function()
			local config = require("crust.config")
			config.options = { raw_tool_blocks = false }
			config.config = nil

			local other = Output.new()
			other:append_block({ "# still a heading" })
			vim.wait(150)

			local parser = vim.treesitter.get_parser(other:buf())
			assert.are.equal(1, #parser:parse(true))

			config.options = {}
			config.config = nil
		end)
	end)

	describe("helpers", function()
		it("omits the rule for the first message", function()
			local at = os.time({ year = 2024, month = 3, day = 7, hour = 9, min = 5 })
			out:header("󰚩", Highlights.AGENT_TITLE, at)
			assert.are.same({ "󰚩 Mar 7 2024, 09:05", "", "" }, out:lines())
		end)

		it("separates later messages with a rule instead of a markdown header", function()
			local at = os.time({ year = 2024, month = 3, day = 7, hour = 9, min = 5 })
			out:header("󰚩", Highlights.AGENT_TITLE, at)
			out:append("hi")
			out:header("󰚩", Highlights.AGENT_TITLE, at)
			assert.are.same({
				"󰚩 Mar 7 2024, 09:05",
				"",
				"hi",
				"",
				"---",
				"󰚩 Mar 7 2024, 09:05",
				"",
				"",
			}, out:lines())
		end)

		it("defaults the header timestamp to now", function()
			out:header("󰚩", Highlights.AGENT_TITLE)
			local expected = tostring(os.date(require("crust.config").get().timestamp_format))
			assert.are.equal("󰚩 " .. expected, out:lines()[1])
		end)

		it("keeps exactly one blank line before the rule", function()
			out:append("text\n\n\n")
			out:header("󰚩", Highlights.AGENT_TITLE)
			assert.are.same({ "text", "", "---" }, vim.list_slice(out:lines(), 1, 3))
		end)

		it("highlights the rule, the role icon and the timestamp", function()
			local at = os.time({ year = 2024, month = 3, day = 7, hour = 9, min = 5 })
			out:header("󰚩", Highlights.AGENT_TITLE, at)
			out:append("hi")
			out:header("󰚩", Highlights.AGENT_TITLE, at)

			local ns = vim.api.nvim_get_namespaces()["crust.chat.output.highlights"]
			local marks = vim.api.nvim_buf_get_extmarks(out:buf(), ns, 0, -1, { details = true })
			local got = vim.tbl_map(function(mark)
				local line = vim.api.nvim_buf_get_lines(out:buf(), mark[2], mark[2] + 1, false)[1]
				return { mark[4].hl_group, line:sub(mark[3] + 1, mark[4].end_col) }
			end, marks)

			assert.are.same({
				{ Highlights.AGENT_TITLE, "󰚩" },
				{ Highlights.TIMESTAMP, "Mar 7 2024, 09:05" },
				{ Highlights.SEPARATOR, "---" },
				{ Highlights.AGENT_TITLE, "󰚩" },
				{ Highlights.TIMESTAMP, "Mar 7 2024, 09:05" },
			}, got)
		end)

		it("writes errors in bold", function()
			out:error("boom")
			assert.are.same({ "", "**crust: boom**", "" }, out:lines())
		end)

		it("clears back to a single empty line", function()
			out:append("a\nb")
			out:clear()
			assert.are.same({ "" }, out:lines())
		end)
	end)
end)
