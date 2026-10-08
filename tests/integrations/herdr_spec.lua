-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Herdr = require("crust.integrations.herdr")
local config = require("crust.config")

--- Pretend neovim runs in a herdr pane.
local function fake_pane()
	vim.env.HERDR_ENV = "1"
	vim.env.HERDR_PANE_ID = "w1:p1"
	vim.env.HERDR_BIN_PATH = "herdr"
	vim.env.HERDR_SOCKET_PATH = "/tmp/herdr.sock"
end

local function clear_pane()
	vim.env.HERDR_ENV = nil
	vim.env.HERDR_PANE_ID = nil
	vim.env.HERDR_BIN_PATH = nil
	vim.env.HERDR_SOCKET_PATH = nil
end

--- Collect what would be spawned. Calls settle immediately unless `hold`.
---@param hold? boolean keep the report in flight until the returned `finish`
local function record(hold)
	local calls = {}
	local pending = {}
	Herdr.spawn = function(argv, on_exit, opts)
		calls[#calls + 1] = argv
		calls[#calls].opts = opts
		if hold then
			pending[#pending + 1] = on_exit
		else
			on_exit()
		end
	end
	return calls, function()
		local queue = pending
		pending = {}
		for _, on_exit in ipairs(queue) do
			on_exit()
		end
	end
end

---@param argv string[]
---@param flag string
---@return string?
local function value(argv, flag)
	for index, item in ipairs(argv) do
		if item == flag then
			return argv[index + 1]
		end
	end
	return nil
end

describe("integrations.herdr", function()
	local spawn = Herdr.spawn

	before_each(function()
		config.options = { herdr = { enabled = true } }
		config.config = nil
		Herdr.reset()
		fake_pane()
	end)

	after_each(function()
		Herdr.spawn = spawn
		Herdr.reset()
		clear_pane()
		config.options = {}
		config.config = nil
	end)

	describe("env", function()
		it("reads the pane herdr exported", function()
			local env = Herdr.env()
			assert.are.equal("w1:p1", env.pane)
			assert.are.equal("herdr", env.bin)
		end)

		it("is nothing outside herdr", function()
			clear_pane()
			assert.is_nil(Herdr.env())
			assert.is_false(Herdr.available())
		end)

		it("is nothing with a half-set environment", function()
			vim.env.HERDR_PANE_ID = nil
			assert.is_nil(Herdr.env())
		end)
	end)

	describe("availability", function()
		it("is on by default, inside a herdr pane", function()
			config.options = {}
			config.config = nil
			assert.is_true(config.get().herdr.enabled)
			assert.is_true(Herdr.available())
		end)

		it("stays out of the way outside herdr, enabled or not", function()
			config.options = {}
			config.config = nil
			clear_pane()
			assert.is_false(Herdr.available())
		end)

		it("can be turned off inside herdr", function()
			config.options = { herdr = { enabled = false } }
			config.config = nil
			assert.is_false(Herdr.available())
		end)

		it("takes a function", function()
			config.options = { herdr = { enabled = function()
				return false
			end } }
			config.config = nil
			assert.is_false(Herdr.available())
		end)
	end)

	describe("report", function()
		it("sends the agent, the source and the state", function()
			local calls = record()
			assert.is_true(Herdr.report("working"))

			assert.are.equal(1, #calls)
			local argv = calls[1]
			assert.are.same({ "herdr", "pane", "report-agent", "w1:p1" }, vim.list_slice(argv, 1, 4))
			assert.are.equal("crust", value(argv, "--agent"))
			assert.are.equal("crust.nvim", value(argv, "--source"))
			assert.are.equal("working", value(argv, "--state"))
			assert.is_not_nil(value(argv, "--seq"))
			assert.are.equal("working", Herdr.state())
		end)

		it("does nothing when the integration is off", function()
			config.options = { herdr = { enabled = false } }
			config.config = nil
			local calls = record()
			assert.is_false(Herdr.report("working"))
			assert.are.equal(0, #calls)
		end)

		it("does nothing outside herdr", function()
			clear_pane()
			local calls = record()
			assert.is_false(Herdr.report("working"))
			assert.are.equal(0, #calls)
		end)

		it("skips a state that is already reported", function()
			local calls = record()
			Herdr.report("idle")
			assert.is_false(Herdr.report("idle"))
			assert.are.equal(1, #calls)
		end)

		it("raises the seq on every call", function()
			local calls = record()
			Herdr.report("working")
			Herdr.report("idle")

			local first = tonumber(value(calls[1], "--seq"))
			local second = tonumber(value(calls[2], "--seq"))
			assert.is_true(second > first)
		end)

		it("collapses a burst into the latest state", function()
			local calls, finish = record(true)
			Herdr.report("working")
			Herdr.report("idle")
			Herdr.report("blocked")
			assert.are.equal(1, #calls)

			finish()
			assert.are.equal(2, #calls)
			assert.are.equal("blocked", value(calls[2], "--state"))

			finish()
			assert.are.equal(2, #calls)
		end)

		it("carries a reason for a block", function()
			local calls = record()
			Herdr.report("blocked", { message = "approve the edit" })
			assert.are.equal("approve the edit", value(calls[1], "--message"))
		end)
	end)

	describe("busy", function()
		it("works while anything is busy and idles when nothing is", function()
			local calls = record()
			Herdr.busy("chat", true)
			assert.are.equal("working", value(calls[1], "--state"))

			Herdr.busy("quickprompt", true)
			assert.are.equal(1, #calls, "still working, nothing to say")

			Herdr.busy("chat", false)
			assert.are.equal(1, #calls, "quickprompt is still running")

			Herdr.busy("quickprompt", false)
			assert.are.equal("idle", value(calls[2], "--state"))
		end)
	end)

	describe("release", function()
		it("hands the pane back without a state", function()
			local calls = record()
			Herdr.report("working")
			assert.is_true(Herdr.release())

			local argv = calls[2]
			assert.are.same({ "herdr", "pane", "release-agent", "w1:p1" }, vim.list_slice(argv, 1, 4))
			assert.is_nil(value(argv, "--state"))
			assert.is_nil(Herdr.state())
		end)

		it("does nothing outside herdr", function()
			clear_pane()
			local calls = record()
			assert.is_false(Herdr.release())
			assert.are.equal(0, #calls)
		end)

		it("drops a report still in flight instead of reviving the agent", function()
			local calls, finish = record(true)
			Herdr.report("working")
			Herdr.report("idle")
			assert.is_true(Herdr.release())

			-- The queued `idle` must not be sent after the release-agent call.
			finish()
			assert.are.equal(2, #calls)
			assert.are.equal("release-agent", calls[2][3])
		end)

		it("waits for herdr only when asked, so quitting cannot kill the call", function()
			local calls = record()
			Herdr.release()
			assert.is_nil(calls[1].opts and calls[1].opts.sync)

			Herdr.release({ sync = true })
			assert.is_true(calls[2].opts.sync)
		end)
	end)

	describe("setup", function()
		it("claims the pane as idle", function()
			local calls = record()
			assert.is_true(Herdr.setup())
			assert.are.equal("idle", value(calls[1], "--state"))
		end)

		it("releases the pane once when the editor quits", function()
			local calls = record()
			Herdr.setup()

			-- Both events fire on a real quit; herdr must hear about it once.
			vim.api.nvim_exec_autocmds("VimLeavePre", { group = "crust.herdr" })
			vim.api.nvim_exec_autocmds("VimLeave", { group = "crust.herdr" })

			assert.are.equal(2, #calls)
			assert.are.equal("release-agent", calls[2][3])
			assert.is_true(calls[2].opts.sync)
			assert.is_nil(Herdr.state())
		end)

		it("is a no-op outside herdr: no report, no autocmd", function()
			clear_pane()
			local calls = record()
			assert.is_false(Herdr.setup())
			assert.are.equal(0, #calls)
			-- The group is only created when there is a pane to release, so an
			-- unknown group here is the pass, not a failure.
			local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { event = "VimLeavePre", group = "crust.herdr" })
			assert.is_true(not ok or #autocmds == 0)
		end)
	end)
end)
