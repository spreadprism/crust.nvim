local Status = require("crust.ui.chat.status")
local Output = require("crust.ui.chat.output")
local Highlights = require("crust.ui.highlights")
local config = require("crust.config")

local ns = vim.api.nvim_create_namespace("crust.chat.status")

--- Virtual lines of the status extmark, flattened to strings.
---@param output Crust.Chat.Output
---@return string[]
local function virt_lines(output)
	local marks = vim.api.nvim_buf_get_extmarks(output:buf(), ns, 0, -1, { details = true })
	local lines = {}
	for _, mark in ipairs(marks) do
		for _, virt in ipairs(mark[4].virt_lines or {}) do
			local text = ""
			for _, chunk in ipairs(virt) do
				text = text .. chunk[1]
			end
			lines[#lines + 1] = text
		end
	end
	return lines
end

describe("ui.chat.status", function()
	---@type Crust.Chat.Output
	local out
	---@type Crust.Chat.Status
	local status

	before_each(function()
		config.options = {}
		config.config = nil
		out = Output.new()
		status = Status.new(out)
	end)

	after_each(function()
		status:close()
	end)

	describe("spinner", function()
		it("resolves preset names", function()
			assert.are.same(Status.presets.robot, Status.spinner("robot"))
			assert.are.same(Status.presets.classic, Status.spinner("classic"))
		end)

		it("falls back to robot for an unknown name", function()
			assert.are.same(Status.presets.robot, Status.spinner("nope"))
		end)

		it("accepts a plain list of frames", function()
			local spinner = Status.spinner({ "a", "b" })
			assert.are.same({ "a", "b" }, spinner.frames)
			assert.are.equal(Status.presets.classic.refresh_rate, spinner.refresh_rate)
		end)

		it("accepts a custom definition", function()
			local spinner = Status.spinner({ frames = { "x" }, refresh_rate = 42 })
			assert.are.same({ "x" }, spinner.frames)
			assert.are.equal(42, spinner.refresh_rate)
		end)
	end)

	describe("set", function()
		it("starts hidden", function()
			assert.is_nil(status:text())
			assert.is_false(status:is_running())
			assert.are.same({}, virt_lines(out))
		end)

		it("shows the text with a spinner frame", function()
			config.options = { spinner = { frames = { "X" }, refresh_rate = 10 } }
			config.config = nil

			status:set("Thinking…")
			assert.is_true(status:is_running())
			assert.are.equal("X  Thinking…", status:line())
			assert.are.same({ "", "X  Thinking…  <C-c> to cancel", "" }, virt_lines(out))
		end)

		it("shows the icon alone when the text is empty", function()
			config.options = { spinner = { frames = { "X" }, refresh_rate = 10 } }
			config.config = nil

			status:set("")
			assert.is_true(status:is_running())
			assert.are.equal("X", status:line())
			assert.are.same({ "", "X  <C-c> to cancel", "" }, virt_lines(out))
		end)

		it("defaults to no status text", function()
			assert.are.equal("", config.get().status_text)
		end)

		it("advances the frame on a tick", function()
			config.options = { spinner = { frames = { "A", "B" }, refresh_rate = 10 } }
			config.config = nil

			status:set("busy")
			assert.are.equal("A  busy", status:line())
			vim.wait(200, function()
				return status:line() ~= "A  busy"
			end)
			assert.are.equal("B  busy", status:line())
		end)

		it("clears the extmark and stops the timer", function()
			status:set("busy")
			status:clear()

			assert.is_nil(status:text())
			assert.is_false(status:is_running())
			assert.are.same({}, virt_lines(out))
		end)

		it("ignores setting the same text twice", function()
			config.options = { spinner = { frames = { "A", "B" }, refresh_rate = 10 } }
			config.config = nil

			status:set("busy")
			vim.wait(200, function()
				return status:line() ~= "A  busy"
			end)
			status:set("busy")
			-- The frame is not reset, the status simply keeps running.
			assert.are.equal("B  busy", status:line())
		end)

		it("does not write to the buffer", function()
			status:set("busy")
			assert.are.same({ "" }, out:lines())
		end)
	end)

	describe("render", function()
		it("follows the last line of the buffer", function()
			status:set("busy")
			out:append("one\ntwo\n")
			status:render()

			local marks = vim.api.nvim_buf_get_extmarks(out:buf(), ns, 0, -1, {})
			assert.are.equal(vim.api.nvim_buf_line_count(out:buf()) - 1, marks[1][2])
		end)

		it("keeps a single extmark across renders", function()
			status:set("busy")
			status:render()
			status:render()
			assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(out:buf(), ns, 0, -1, {}))
		end)

		it("centers the text in the output window", function()
			out:open(40)
			status:set("busy")

			local line = virt_lines(out)[2]
			local pad = #line:match("^ *")
			assert.is_true(pad > 0)
			assert.is_true(vim.fn.strdisplaywidth(line) <= out:width())
			out:close()
		end)

		it("highlights the icon, text, elapsed time and hint apart", function()
			status:set("busy")

			local mark = vim.api.nvim_buf_get_extmarks(out:buf(), ns, 0, -1, { details = true })[1]
			local chunks = mark[4].virt_lines[2]
			assert.are.equal(Highlights.STATUS_ICON, chunks[1][2])
			assert.are.equal(Highlights.STATUS, chunks[2][2])
			assert.are.equal("  busy", chunks[2][1])
			assert.are.equal(Highlights.STATUS_TIME, chunks[3][2])
			assert.are.equal(Highlights.STATUS_HINT, chunks[4][2])
		end)

		it("names the status groups after the output panel", function()
			assert.are.equal("CrustOutputStatus", Highlights.STATUS)
			assert.are.equal("CrustOutputStatusIcon", Highlights.STATUS_ICON)
		end)
	end)

	describe("hint", function()
		it("shows the configured cancel key", function()
			assert.are.equal("  <C-c> to cancel", status:hint())
		end)

		it("follows a custom key", function()
			config.options = { keymaps = { cancel = "<Esc>" } }
			config.config = nil
			assert.are.equal("  <Esc> to cancel", status:hint())
		end)

		it("is empty when cancelling is unbound", function()
			config.options = { keymaps = { cancel = false } }
			config.config = nil
			assert.are.equal("", status:hint())
		end)

		it("appears next to the status text", function()
			status:set("busy")
			assert.is_truthy(virt_lines(out)[2]:find("<C-c> to cancel", 1, true))
		end)
	end)

	describe("elapsed", function()
		it("is empty before the first second", function()
			status:set("busy")
			assert.are.equal("", status:elapsed())
		end)

		it("formats seconds and minutes", function()
			status:set("busy")
			status._started_at = math.floor(vim.uv.hrtime() / 1e9) - 5
			assert.are.equal(" for 5s", status:elapsed())

			status._started_at = math.floor(vim.uv.hrtime() / 1e9) - 64
			assert.are.equal(" for 1m 4s", status:elapsed())
		end)
	end)
end)
