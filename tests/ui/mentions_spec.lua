---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Mentions = require("crust.ui.mentions")

--- Mention marks on a buffer as `{ row, col, end_col }` triples.
---@param buf integer
---@return integer[][]
local function marks(buf)
	local found = {}
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, Mentions.ns, 0, -1, { details = true })) do
		found[#found + 1] = { mark[2], mark[3], mark[4].end_col, mark[4].hl_group }
	end
	return found
end

describe("ui.mentions", function()
	---@type integer
	local buf

	before_each(function()
		buf = vim.api.nvim_create_buf(false, true)
	end)

	describe("ranges", function()
		it("matches a mention", function()
			assert.are.same({ { col = 6, end_col = 15 } }, Mentions.ranges("check @justfile"))
		end)

		it("stops at whitespace", function()
			assert.are.same({ { col = 0, end_col = 5 } }, Mentions.ranges("@here and there"))
		end)

		it("matches several mentions", function()
			assert.are.same({ { col = 0, end_col = 2 }, { col = 3, end_col = 5 } }, Mentions.ranges("@a @b"))
		end)

		it("ignores a bare @ and a mid-word @", function()
			assert.are.same({}, Mentions.ranges("@ me"))
			assert.are.same({}, Mentions.ranges("me@example.com"))
		end)

		it("drops trailing punctuation", function()
			assert.are.same({ { col = 0, end_col = 5 } }, Mentions.ranges("@file, next"))
			assert.are.same({ { col = 5, end_col = 14 } }, Mentions.ranges("read @justfile."))
		end)
	end)

	describe("highlight", function()
		it("marks mentions with CrustMention", function()
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "see @justfile", "plain" })
			Mentions.highlight(buf)
			assert.are.same({ { 0, 4, 13, "CrustMention" } }, marks(buf))
		end)

		it("replaces the previous marks", function()
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@one" })
			Mentions.highlight(buf)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain" })
			Mentions.highlight(buf)
			assert.are.same({}, marks(buf))
		end)

		it("only touches the given rows", function()
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@one", "@two" })
			Mentions.highlight(buf, 1, -1)
			assert.are.same({ { 1, 0, 4, "CrustMention" } }, marks(buf))
		end)
	end)

	describe("attach", function()
		it("highlights on edit", function()
			Mentions.attach(buf)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hi @justfile" })
			vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
			assert.are.same({ { 0, 3, 12, "CrustMention" } }, marks(buf))
		end)
	end)
end)
