local Status = require("crust.ui.chat.status")
local Output = require("crust.ui.chat.output")
local Highlights = require("crust.ui.highlights")
local config = require("crust.config")

--- Statusline with the highlight groups stripped, as it reads on screen.
---@param status Crust.Chat.Status
---@return string
local function rendered(status)
	return (status:statusline():gsub("%%#[%w_]+#", ""))
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
			assert.are.equal("", status:statusline())
		end)

		it("shows the text with a spinner frame", function()
			config.options = { spinner = { frames = { "X" }, refresh_rate = 10 } }
			config.config = nil

			status:set("Thinking…")
			assert.is_true(status:is_running())
			assert.are.equal("X  Thinking…", status:line())
			assert.are.equal(" X  Thinking…%=<C-c> to cancel ", rendered(status))
		end)

		it("shows the icon alone when the text is empty", function()
			config.options = { spinner = { frames = { "X" }, refresh_rate = 10 } }
			config.config = nil

			status:set("")
			assert.are.equal("X", status:line())
			assert.are.equal(" X%=<C-c> to cancel ", rendered(status))
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
			status:set("busy")
			status:clear()

			assert.is_nil(status:text())
			assert.is_false(status:is_running())
			assert.are.equal("", status:statusline())
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
			status:set("busy")
			assert.are.same({ "" }, out:lines())
		end)
	end)

	describe("statusline", function()
		it("is set on the output window", function()
			out:open(40)
			status:set("busy")

			assert.are.equal(status:statusline(), vim.wo[out:win()].statusline)
		end)

		it("is restored when the status clears", function()
			out:open(40)
			status:set("busy")
			status:clear()

			-- Empty means "fall back to the global statusline".
			assert.are.equal(vim.go.statusline, vim.wo[out:win()].statusline)
		end)

		it("splits left and right with %=", function()
			status:set("busy")

			local left, right = status:statusline():match("^(.*)%%=(.*)$")
			assert.is_truthy(left:find("busy", 1, true))
			assert.is_truthy(right:find("<C-c> to cancel", 1, true))
		end)

		it("highlights the icon, text, elapsed time and hint apart", function()
			status:set("busy")
			status._started_at = math.floor(vim.uv.hrtime() / 1e9) - 5

			local line = status:statusline()
			assert.is_truthy(line:find("%#" .. Highlights.STATUS_ICON .. "#", 1, true))
			assert.is_truthy(line:find("%#" .. Highlights.STATUS .. "#  busy", 1, true))
			assert.is_truthy(line:find("%#" .. Highlights.STATUS_TIME .. "#", 1, true))
			assert.is_truthy(line:find("%#" .. Highlights.STATUS_HINT .. "#<C-c> to cancel", 1, true))
		end)

		it("names the status groups after the output panel", function()
			assert.are.equal("CrustOutputStatus", Highlights.STATUS)
			assert.are.equal("CrustOutputStatusIcon", Highlights.STATUS_ICON)
		end)

		it("does not fail when the output window is hidden", function()
			assert.has_no.errors(function()
				status:set("busy")
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
