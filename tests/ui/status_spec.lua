local Status = require("crust.ui.chat.status")
local Output = require("crust.ui.chat.output")
local Highlights = require("crust.ui.highlights")
local config = require("crust.config")

--- The bar as it reads on screen, trailing padding trimmed.
---@param status Crust.Chat.Status
---@param width? integer
---@return string
local function rendered(status, width)
	if not status:text() then
		return ""
	end
	return (status:line_for(width or 40):gsub("%\s+$", ""))
end

--- Highlight groups of the bar, in order.
---@param status Crust.Chat.Status
---@return string[]
local function groups(status)
	local out = {}
	local _, highlights = status:line_for(40)
	for _, hl in ipairs(highlights) do
		out[#out + 1] = hl.group
	end
	return out
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
		out:close()
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
		it("starts empty", function()
			assert.is_nil(status:text())
			assert.is_false(status:is_running())
			assert.is_nil(status:win())
		end)

		it("shows the text with a spinner frame", function()
			config.options = { spinner = { frames = { "X" }, refresh_rate = 10 } }
			config.config = nil

			status:set("Thinking…")
			assert.is_true(status:is_running())
			assert.are.equal("X  Thinking…", status:line())
			assert.are.equal(" X  Thinking…", rendered(status):match("^(.-)%s%s+"))
			assert.is_truthy(rendered(status):find("<C-c> to cancel", 1, true))
		end)

		it("shows the icon alone when the text is empty", function()
			config.options = { spinner = { frames = { "X" }, refresh_rate = 10 } }
			config.config = nil

			status:set("")
			assert.are.equal("X", status:line())
			assert.are.equal(" X", rendered(status):match("^(.-)%s%s+"))
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

		it("clears the bar and stops the timer", function()
			out:open(40)
			status:set("busy")
			assert.is_not_nil(status:win())

			status:clear()
			assert.is_nil(status:text())
			assert.is_false(status:is_running())
			assert.is_nil(status:win())
		end)

		it("ignores setting the same text twice", function()
			config.options = { spinner = { frames = { "A", "B" }, refresh_rate = 10 } }
			config.config = nil

			status:set("busy")
			vim.wait(200, function()
				return status:line() ~= "A  busy"
			end)
			status:set("busy")
			assert.are.equal("B  busy", status:line())
		end)

		it("never writes to the output buffer", function()
			out:open(40)
			status:set("busy")
			assert.are.same({ "" }, out:lines())
		end)
	end)

	describe("window", function()
		it("floats over the bottom row of the output window", function()
			out:open(40)
			status:set("busy")

			local config_ = vim.api.nvim_win_get_config(status:win())
			assert.are.equal("win", config_.relative)
			assert.are.equal(out:win(), config_.win)
			assert.are.equal("SW", config_.anchor)
			assert.are.equal(Status.HEIGHT, config_.height)
			assert.are.equal(vim.api.nvim_win_get_width(out:win()), config_.width)
			assert.is_false(config_.focusable)
		end)

		it("works with a global statusline", function()
			local laststatus = vim.o.laststatus
			vim.o.laststatus = 3

			out:open(40)
			status:set("busy")
			assert.is_not_nil(status:win())
			assert.is_truthy(rendered(status):find("busy", 1, true))

			vim.o.laststatus = laststatus
		end)

		it("does not open a window while the output is hidden", function()
			status:set("busy")
			assert.is_nil(status:win())
		end)

		it("follows the output window on resize", function()
			out:open(40)
			status:set("busy")

			out:set_width(60)
			status:update_window()
			assert.are.equal(60, vim.api.nvim_win_get_config(status:win()).width)
		end)

		it("uses its own scratch buffer", function()
			assert.are.equal("crust_status", vim.bo[status:buf()].filetype)
			assert.are.equal("nofile", vim.bo[status:buf()].buftype)
		end)
	end)

	describe("layout", function()
		it("pushes the hint to the right edge", function()
			local line = status
			line:set("busy")
			local text = line:line_for(40)
			assert.are.equal(40, vim.fn.strdisplaywidth(text))
			assert.is_truthy(text:find("<C-c> to cancel $"))
		end)

		it("highlights the icon, text, elapsed time and hint apart", function()
			status:set("busy")
			status._started_at = math.floor(vim.uv.hrtime() / 1e9) - 5

			assert.are.same({
				Highlights.STATUS_ICON,
				Highlights.STATUS,
				Highlights.STATUS_TIME,
				Highlights.STATUS_HINT,
			}, groups(status))
		end)

		it("names the status groups after the output panel", function()
			assert.are.equal("CrustOutputStatus", Highlights.STATUS)
			assert.are.equal("CrustOutputStatusIcon", Highlights.STATUS_ICON)
		end)

		it("does not fail when the output window is hidden", function()
			assert.has_no.errors(function()
				status:set("busy")
				status:render()
			end)
		end)
	end)

	describe("hint", function()
		it("shows the configured cancel key", function()
			assert.are.equal("<C-c> to cancel", status:hint())
		end)

		it("follows a custom key", function()
			config.options = { keymaps = { cancel = "<Esc>" } }
			config.config = nil
			assert.are.equal("<Esc> to cancel", status:hint())
		end)

		it("is empty when cancelling is unbound", function()
			config.options = { keymaps = { cancel = false } }
			config.config = nil

			status:set("busy")
			assert.are.equal("", status:hint())
			assert.is_falsy(rendered(status):find("to cancel", 1, true))
			assert.are.equal("%=", rendered(status):sub(-2))
		end)
	end)

	describe("elapsed", function()
		it("shows zero seconds right away", function()
			status:set("busy")
			assert.are.equal("  for 0s", status:elapsed())
		end)

		it("is empty when no status is set", function()
			assert.are.equal("", status:elapsed())
		end)

		it("formats seconds and minutes", function()
			status:set("busy")
			status._started_at = math.floor(vim.uv.hrtime() / 1e9) - 5
			assert.are.equal("  for 5s", status:elapsed())

			status._started_at = math.floor(vim.uv.hrtime() / 1e9) - 64
			assert.are.equal("  for 1m 4s", status:elapsed())
		end)
	end)
end)
