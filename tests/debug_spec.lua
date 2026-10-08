-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Debug = require("crust.debug")
local Pi = require("crust.pi.client")
local config = require("crust.config")

--- A process that never spawned, with traffic written into its ring by hand.
---@param entries { kind: string, text: string }[]
---@return Crust.Pi
local function traced(entries)
	local pi = Pi.new({ model = "anthropic/claude-haiku-4-5", cwd = "/tmp/project" })
	for _, entry in ipairs(entries) do
		pi:_record(entry.kind, entry.text)
	end
	return pi
end

---@param lines string[]
---@param needle string
---@return string?
local function find(lines, needle)
	for _, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			return line
		end
	end
	return nil
end

describe("debug", function()
	before_each(function()
		config.options = {}
		config.config = nil
	end)

	after_each(function()
		config.options = {}
		config.config = nil
		require("crust").stop()
		local buf = vim.fn.bufnr(Debug.BUFNAME)
		if buf ~= -1 then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end)

	describe("recording", function()
		it("keeps the command, both directions and stderr", function()
			local pi = traced({
				{ kind = "sent", text = '{"type":"prompt"}' },
				{ kind = "received", text = '{"type":"agent_start"}' },
				{ kind = "stderr", text = "Error: OAuth refresh failed" },
				{ kind = "exit", text = "pi exited with 1" },
			})

			local kinds = vim.tbl_map(function(entry)
				return entry.kind
			end, pi:trace())
			assert.are.same({ "sent", "received", "stderr", "exit" }, kinds)
		end)

		it("stamps every entry", function()
			local pi = traced({ { kind = "sent", text = "{}" } })
			assert.is_true(pi:trace()[1].time > 0)
		end)

		it("drops the oldest lines past the configured history", function()
			config.options = { debug = { history = 3 } }
			config.config = nil

			local entries = {}
			for index = 1, 10 do
				entries[index] = { kind = "sent", text = "line " .. index }
			end
			local pi = traced(entries)

			assert.are.equal(3, #pi:trace())
			assert.are.equal("line 8", pi:trace()[1].text)
			assert.are.equal("line 10", pi:trace()[3].text)
		end)

		it("clears on demand", function()
			local pi = traced({ { kind = "sent", text = "{}" } })
			pi:clear_trace()
			assert.are.equal(0, #pi:trace())
		end)

		it("records the command a connect was attempted with", function()
			local pi = Pi.new({ bin = "crust-no-such-binary", cwd = "/tmp/project" })
			pi:connect()

			local spawn = pi:trace()[1]
			assert.are.equal("spawn", spawn.kind)
			assert.is_not_nil(spawn.text:find("crust-no-such-binary", 1, true))
			assert.is_not_nil(spawn.text:find("--mode rpc", 1, true))
			assert.is_not_nil(spawn.text:find("/tmp/project", 1, true))
		end)
	end)

	describe("trace_lines", function()
		it("marks each direction and keeps the payload raw", function()
			local pi = traced({
				{ kind = "sent", text = '{"type":"prompt","id":"crust:1"}' },
				{ kind = "received", text = '{"type":"agent_end"}' },
				{ kind = "stderr", text = "Error: 429 rate limited" },
			})

			local lines = Debug.trace_lines(pi)
			assert.is_not_nil(find(lines, '> {"type":"prompt","id":"crust:1"}'))
			assert.is_not_nil(find(lines, '< {"type":"agent_end"}'))
			assert.is_not_nil(find(lines, "! Error: 429 rate limited"))
			-- Timestamps, not bare markers.
			assert.is_not_nil(lines[1]:match("^%d%d:%d%d:%d%d%.%d%d%d "))
		end)

		it("indents the continuation of a multi-line stderr under its stamp", function()
			local pi = traced({ { kind = "stderr", text = "Error: boom\n  at postJson" } })
			local lines = Debug.trace_lines(pi)

			assert.are.equal(2, #lines)
			assert.is_not_nil(lines[2]:match("^%s+at postJson$"))
		end)

		it("expands json when asked to", function()
			local pi = traced({ { kind = "sent", text = '{"type":"prompt"}' } })

			local flat = Debug.trace_lines(pi, { pretty = false })
			local expanded = Debug.trace_lines(pi, { pretty = true })

			assert.are.equal(1, #flat)
			assert.is_true(#expanded > 1)
			assert.is_not_nil(find(expanded, 'type = "prompt"'))
		end)

		it("leaves a line that is not json alone when expanding", function()
			local pi = traced({ { kind = "spawn", text = "pi --mode rpc" } })
			assert.are.same(1, #Debug.trace_lines(pi, { pretty = true }))
		end)

		it("says so when a process has no traffic", function()
			local pi = Pi.new()
			assert.is_not_nil(find(Debug.trace_lines(pi), "no traffic recorded"))
		end)
	end)

	describe("lines", function()
		it("says so when nothing is running", function()
			assert.is_not_nil(find(Debug.lines(), "No pi process is running."))
		end)

		it("has a legend for the markers", function()
			assert.is_not_nil(find(Debug.lines(), "$ spawn"))
		end)

		it("sections the live processes with their model and state", function()
			local crust = require("crust")
			local chat = crust.chat()
			chat:pi():_record("sent", '{"type":"prompt"}')

			local lines = Debug.lines()
			assert.is_not_nil(find(lines, "## chat"))
			assert.is_not_nil(find(lines, "not running"))
			assert.is_not_nil(find(lines, "model:"))
			assert.is_not_nil(find(lines, '> {"type":"prompt"}'))
		end)

		it("does not build a chat just to look at one", function()
			assert.is_nil(require("crust").current_chat())
			Debug.lines()
			assert.is_nil(require("crust").current_chat())
		end)

		it("includes the quickprompt and quickcomplete processes", function()
			require("crust.quickprompt").client():_record("sent", "qp")
			require("crust.quickcomplete").client():_record("sent", "qc")

			local lines = Debug.lines()
			assert.is_not_nil(find(lines, "## quickprompt"))
			assert.is_not_nil(find(lines, "## quickcomplete"))
		end)
	end)

	describe("open", function()
		it("puts the dump in a named scratch buffer", function()
			local buf = Debug.open()

			assert.are.equal("nofile", vim.bo[buf].buftype)
			assert.are.equal("crust_debug", vim.bo[buf].filetype)
			assert.is_not_nil(vim.api.nvim_buf_get_name(buf):find(Debug.BUFNAME, 1, true))
			assert.is_true(#vim.api.nvim_buf_get_lines(buf, 0, -1, false) > 0)
			assert.are.equal(buf, vim.api.nvim_win_get_buf(0))

			vim.cmd("tabclose")
		end)

		it("replaces the previous dump instead of stacking buffers", function()
			local first = Debug.open()
			vim.cmd("tabclose")
			local second = Debug.open()
			vim.cmd("tabclose")

			assert.are_not.equal(first, second)
			assert.is_false(vim.api.nvim_buf_is_valid(first))
		end)

		it("is reachable from the api", function()
			local buf = require("crust").debug()
			assert.are.equal(buf, vim.fn.bufnr(Debug.BUFNAME))
			vim.cmd("tabclose")
		end)
	end)
end)
