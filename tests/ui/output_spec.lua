local Output = require("crust.ui.chat.output")

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

	describe("helpers", function()
		it("writes a header with the role icon and a timestamp", function()
			local at = os.time({ year = 2024, month = 3, day = 7, hour = 9, min = 5 })
			out:header("󰚩", at)
			assert.are.same({ "", "## 󰚩 Mar 7 2024, 09:05", "", "" }, out:lines())
		end)

		it("defaults the header timestamp to now", function()
			out:header("󰚩")
			local expected = tostring(os.date(require("crust.config").get().timestamp_format))
			assert.are.equal("## 󰚩 " .. expected, out:lines()[2])
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
