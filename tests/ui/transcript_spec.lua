-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Transcript = require("crust.ui.chat.transcript")

describe("ui.chat.transcript", function()
	---@type Crust.Chat.Transcript
	local t

	before_each(function()
		t = Transcript.new()
	end)

	describe("sections", function()
		it("starts with one empty section", function()
			assert.are.equal(1, t:count())
			assert.is_true(t:is_empty())
			assert.are.same({ "" }, t:lines())
		end)

		it("reuses the empty section for the first message", function()
			t:begin_section("󰚩 now")
			assert.are.equal(1, t:count())
			assert.are.same({ "󰚩 now", "", "" }, t:lines())
		end)

		it("separates later messages with a rule", function()
			t:begin_section("󰚩 now")
			t:append("hi")
			t:begin_section(" now")

			assert.are.equal(2, t:count())
			assert.are.same({ "󰚩 now", "", "hi", "", "---", " now", "", "" }, t:lines())
		end)

		it("counts the rule in a section's height", function()
			t:begin_section("󰚩 now")
			t:begin_section(" now")
			-- Opening a message trims the blank tail of the one before it.
			assert.are.equal(1, t:height(1))
			assert.are.equal(5, t:height(2))
		end)

		it("keeps a section's text out of its neighbours", function()
			t:begin_section("a")
			t:append("one")
			t:begin_section("b")
			t:append("two")

			assert.are.same({ "a", "", "one" }, t:section(1).lines)
			assert.are.same({ "b", "", "two" }, t:section(2).lines)
		end)
	end)

	describe("append", function()
		it("continues the last line", function()
			t:append("hel")
			t:append("lo")
			assert.are.same({ "hello" }, t:lines())
		end)

		it("splits on newlines", function()
			t:append("a\nb\n")
			assert.are.same({ "a", "b", "" }, t:lines())
		end)

		it("reports the rewritten rows", function()
			t:append("a\nb")
			local patch = t:append("c\nd")
			assert.are.same({ section = 1, first = 2, removed = 1, lines = { "bc", "d" } }, patch)
		end)
	end)

	describe("blocks", function()
		it("isolates a block with one blank line on each side", function()
			t:append("head")
			t:append_block({ "one" })
			assert.are.same({ "head", "", "one", "", "" }, t:lines())
		end)

		it("anchors the block on its section row", function()
			t:append("head")
			local block = t:append_block({ "one" })
			assert.are.equal(1, block.section)
			assert.are.equal(3, block.first)
			assert.are.equal(1, block.count)
		end)

		it("reports a patch that covers the trimmed rows", function()
			t:append("head\n\n\n")
			local _, patch = t:append_block({ "one" })
			assert.are.equal(1, patch.section)

			-- Applying the patch by hand must reproduce the section.
			local lines = vim.list_slice({ "head", "", "", "" }, 1, patch.first - 1)
			vim.list_extend(lines, patch.lines)
			assert.are.same(t:lines(), lines)
		end)

		it("moves the blocks under a block that grew", function()
			local first = t:append_block({ "first" })
			local second = t:append_block({ "second" })
			t:replace_block(first, { "first", "more" })

			assert.are.equal(1, first.first)
			assert.are.equal(4, second.first)
			assert.are.same({ "first", "more", "", "second", "", "" }, t:lines())
		end)

		it("moves them back when it shrinks", function()
			local first = t:append_block({ "a", "b", "c" })
			local second = t:append_block({ "second" })
			t:replace_block(first, { "a" })

			assert.are.equal(3, second.first)
			assert.are.same({ "a", "", "second", "", "" }, t:lines())
		end)

		it("ignores a block whose transcript was cleared", function()
			local block = t:append_block({ "gone" })
			t:clear()
			assert.is_nil(t:replace_block(block, { "still gone" }))
		end)

		it("knows when a block ends the transcript", function()
			local block = t:append_block({ "one" })
			assert.is_true(t:block_ends_transcript(block))

			t:append("text")
			assert.is_false(t:block_ends_transcript(block))
		end)

		it("knows a block in an older section does not", function()
			local block = t:append_block({ "one" })
			t:begin_section("󰚩 now")
			assert.is_false(t:block_ends_transcript(block))
		end)
	end)

	describe("render", function()
		before_each(function()
			for index = 1, 4 do
				t:begin_section("head " .. index)
				t:append("body " .. index)
			end
		end)

		it("draws a slice with its rules", function()
			local lines, rows = t:render(2, 3)
			assert.are.same({ "", "---", "head 2", "", "body 2", "", "---", "head 3", "", "body 3" }, lines)
			assert.are.same({ [2] = 2, [3] = 7 }, rows)
		end)

		it("reports where each section starts", function()
			local _, rows = t:render()
			assert.are.equal(0, rows[1])
			assert.are.equal(5, rows[2])
		end)

		it("never renders an empty buffer", function()
			assert.are.same({ "" }, Transcript.new():render())
		end)
	end)

	describe("clear", function()
		it("drops everything back to one empty section", function()
			t:begin_section("head")
			t:append("body")
			t:clear()

			assert.are.equal(1, t:count())
			assert.are.same({ "" }, t:lines())
			assert.is_true(t:is_empty())
		end)
	end)
end)
