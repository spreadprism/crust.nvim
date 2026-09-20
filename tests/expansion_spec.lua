---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

-- The specs `cd` into a temp dir, so the plugin has to be on the
-- runtimepath by absolute path before that happens.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(".", ":p"))

local Expansion = require("crust.expansion")
local File = require("crust.expansion.file")

--- An expander that claims every occurrence of `word`.
---@param name string
---@param word string
---@param replacement string?
---@return Crust.Expansion.Expander
local function fake(name, word, replacement)
	return {
		name = name,
		trigger = function(text)
			local matches = {}
			local init = 1
			while true do
				local first, last = text:find(word, init, true)
				if not first then
					return matches
				end
				matches[#matches + 1] = { first = first, last = last, text = word }
				init = last + 1
			end
		end,
		expansion = function()
			return replacement
		end,
	}
end

describe("expansion", function()
	---@type string
	local dir

	before_each(function()
		require("crust.config").config = nil
		dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		vim.cmd.cd(dir)
	end)

	after_each(function()
		vim.fn.delete(dir, "rf")
		require("crust.config").config = nil
	end)

	---@param name string
	---@param lines string[]
	local function write(name, lines)
		vim.fn.writefile(lines, dir .. "/" .. name)
	end

	describe("expand", function()
		it("leaves text without triggers alone", function()
			assert.are.equal("plain text", Expansion.expand("plain text", { fake("x", "@nope", "!") }))
		end)

		it("replaces every claimed span", function()
			local out = Expansion.expand("a @x b @x", { fake("x", "@x", "[X]") })
			assert.are.equal("a [X] b [X]", out)
		end)

		it("keeps the text when the expansion returns nil", function()
			local out = Expansion.expand("a @x b", { fake("x", "@x", nil) })
			assert.are.equal("a @x b", out)
		end)

		it("gives overlapping spans to the first expander", function()
			local out = Expansion.expand("@ab", { fake("first", "@ab", "[1]"), fake("second", "@a", "[2]") })
			assert.are.equal("[1]", out)
		end)

		it("survives an expander that errors", function()
			local boom = {
				name = "boom",
				trigger = function()
					error("nope")
				end,
				expansion = function()
					return "!"
				end,
			}
			assert.are.equal("a @x", Expansion.expand("a @x", { boom }))
		end)

		it("can be turned off", function()
			require("crust.config").config = nil
			require("crust.config").options = { expansion = { enabled = false } }
			assert.are.equal("a @x", Expansion.expand("a @x", { fake("x", "@x", "[X]") }))
			require("crust.config").options = nil
			require("crust.config").config = nil
		end)
	end)

	describe("file", function()
		it("claims mentions with their byte offsets", function()
			local matches = File.trigger("see @justfile now")
			assert.are.equal(1, #matches)
			assert.are.equal("@justfile", matches[1].text)
			assert.are.equal("@justfile", ("see @justfile now"):sub(matches[1].first, matches[1].last))
		end)

		it("claims mentions on later lines", function()
			local text = "line one\nsee @justfile"
			local matches = File.trigger(text)
			assert.are.equal(1, #matches)
			assert.are.equal("@justfile", text:sub(matches[1].first, matches[1].last))
		end)

		it("expands a mention into the file content", function()
			write("justfile", { "default:", "  echo hi" })
			local out = Expansion.expand("look at @justfile please")
			assert.is_truthy(out:find("look at @justfile", 1, true))
			assert.is_truthy(out:find("default:\n  echo hi", 1, true))
			assert.is_truthy(out:find("please", 1, true))
		end)

		it("tags the fence with the filetype", function()
			write("init.lua", { "return {}" })
			assert.is_truthy(Expansion.expand("@init.lua"):find("```lua\n", 1, true))
		end)

		it("uses a longer fence when the file contains backticks", function()
			write("readme.md", { "```lua", "print(1)", "```" })
			assert.is_truthy(Expansion.expand("@readme.md"):find("````", 1, true))
		end)

		it("prefers the loaded buffer over the file on disk", function()
			write("draft.txt", { "on disk" })
			local buf = vim.fn.bufadd(dir .. "/draft.txt")
			vim.fn.bufload(buf)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })

			local out = Expansion.expand("@draft.txt")
			assert.is_truthy(out:find("unsaved", 1, true))
			assert.is_nil(out:find("on disk", 1, true))
			vim.api.nvim_buf_delete(buf, { force = true })
		end)

		it("truncates a file past the limit", function()
			local limit = File.MAX_BYTES
			File.MAX_BYTES = 16
			write("big.txt", { string.rep("x", 100) })
			local out = Expansion.expand("@big.txt")
			File.MAX_BYTES = limit
			assert.is_truthy(out:find("truncated at 16 bytes", 1, true))
		end)

		it("does not repeat the path in the fence, the mention is the path", function()
			write("justfile", { "default:" })
			assert.is_nil(Expansion.expand("@justfile"):find("path=", 1, true))
		end)

		it("expands a single line range", function()
			write("lines.txt", { "one", "two", "three" })
			local out = Expansion.expand("@lines.txt:2")
			assert.is_truthy(out:find("lines=2-2\n", 1, true))
			assert.is_truthy(out:find("\ntwo\n", 1, true))
			assert.is_nil(out:find("three", 1, true))
		end)

		it("expands a first-last range", function()
			write("lines.txt", { "one", "two", "three", "four" })
			local out = Expansion.expand("@lines.txt:2-3")
			assert.is_truthy(out:find("lines=2-3", 1, true))
			assert.is_truthy(out:find("two\nthree", 1, true))
			assert.is_nil(out:find("four", 1, true))
		end)

		it("runs an open-ended range to the last line", function()
			write("lines.txt", { "one", "two", "three" })
			local out = Expansion.expand("@lines.txt:2-")
			assert.is_truthy(out:find("lines=2-3", 1, true))
			assert.is_truthy(out:find("two\nthree", 1, true))
		end)

		it("clamps a range past the end of the file and swaps a reversed one", function()
			write("lines.txt", { "one", "two" })
			assert.is_truthy(Expansion.expand("@lines.txt:1-99"):find("lines=1-2", 1, true))
			assert.is_truthy(Expansion.expand("@lines.txt:2-1"):find("lines=1-2", 1, true))
		end)

		it("keeps the mention when the range starts past the end", function()
			write("lines.txt", { "one" })
			assert.are.equal("@lines.txt:9-10", Expansion.expand("@lines.txt:9-10"))
		end)

		it("keeps the leading mention text so the user's reference is intact", function()
			write("lines.txt", { "one", "two" })
			assert.is_truthy(Expansion.expand("see @lines.txt:1"):find("see @lines.txt:1\n", 1, true))
		end)

		it("prefers a file whose name really ends in a range", function()
			write("odd:2", { "colon file" })
			local out = Expansion.expand("@odd:2")
			assert.is_truthy(out:find("colon file", 1, true))
			assert.is_nil(out:find("lines=", 1, true))
		end)

		it("leaves a range on a file that does not exist", function()
			assert.are.equal("@nope.txt:1-2", Expansion.expand("@nope.txt:1-2"))
		end)

		it("leaves a mention that is not a readable file", function()
			assert.are.equal("@nothing-here", Expansion.expand("@nothing-here"))
		end)

		it("leaves a directory mention alone", function()
			vim.fn.mkdir(dir .. "/sub", "p")
			assert.are.equal("@sub", Expansion.expand("@sub"))
		end)
	end)
end)
