local Input = require("crust.ui.chat.input")

describe("ui.chat.input", function()
	---@type string[]
	local submitted
	---@type Crust.Chat.Input
	local input

	before_each(function()
		submitted = {}
		input = Input.new(function(text)
			submitted[#submitted + 1] = text
		end)
	end)

	it("starts empty", function()
		assert.are.equal("", input:text())
	end)

	it("round-trips multi-line text", function()
		input:set_text("a\nb")
		assert.are.equal("a\nb", input:text())
	end)

	it("trims surrounding whitespace", function()
		input:set_text("  hello  ")
		assert.are.equal("hello", input:text())
	end)

	it("clears back to empty", function()
		input:set_text("hello")
		input:clear()
		assert.are.equal("", input:text())
	end)

	describe("submit", function()
		it("passes the trimmed text to the callback", function()
			input:set_text(" hello ")
			input:submit()
			assert.are.same({ "hello" }, submitted)
		end)

		it("does nothing when empty", function()
			input:submit()
			input:set_text("   \n  ")
			input:submit()
			assert.are.same({}, submitted)
		end)

		it("does not clear the buffer itself", function()
			input:set_text("hello")
			input:submit()
			assert.are.equal("hello", input:text())
		end)
	end)

	describe("keymaps", function()
		it("maps <CR> in normal and insert mode", function()
			local modes = {}
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(input:buf(), "n")) do
				modes[map.lhs] = true
			end
			assert.is_true(modes["<CR>"])

			modes = {}
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(input:buf(), "i")) do
				modes[map.lhs] = true
			end
			assert.is_true(modes["<CR>"])
			assert.is_true(modes["<S-CR>"])
		end)

		it("submits when <CR> is pressed in the input buffer", function()
			input:set_text("from keymap")
			vim.api.nvim_set_current_buf(input:buf())
			vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
			assert.are.same({ "from keymap" }, submitted)
		end)
	end)
end)
