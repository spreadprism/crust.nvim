-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local QuickPrompt = require("crust.quickprompt")
local config = require("crust.config")

describe("quickprompt", function()
	local buf
	local path
	local notifications
	local notify

	--- Stands in for the pi process: records what was sent, answers nothing
	--- until the spec feeds events in through `QuickPrompt.on_event`.
	local function fake_client(opts)
		opts = opts or {}
		return {
			sent = {},
			connect = function()
				if opts.connect_error then
					return false, opts.connect_error
				end
				return true
			end,
			send = function(self, command)
				self.sent[#self.sent + 1] = command
				if opts.send_error then
					return nil, opts.send_error
				end
				return "id"
			end,
			close = function() end,
		}
	end

	before_each(function()
		config.options = {}
		config.config = nil

		path = vim.fn.tempname() .. ".lua"
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, path)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"one",
			"two",
			"three",
			"four",
			"five",
			"six",
			"seven",
			"eight",
			"nine",
			"ten",
		})
		vim.bo[buf].filetype = "lua"
		vim.api.nvim_win_set_buf(0, buf)

		notifications = {}
		notify = vim.notify
		vim.notify = function(message, level)
			notifications[#notifications + 1] = { message = message, level = level }
		end
	end)

	after_each(function()
		vim.notify = notify
		QuickPrompt.stop()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		config.options = {}
		config.config = nil
	end)

	describe("config", function()
		it("defaults to a small model and five lines of context", function()
			local cfg = config.get().quickprompt
			assert.is_true(cfg.enabled)
			assert.are.equal("anthropic/claude-haiku-4-5", cfg.model)
			assert.are.equal(5, cfg.context_lines)
		end)

		it("takes the model from setup", function()
			config.options = { quickprompt = { model = "openai/gpt-5" } }
			config.config = nil
			assert.are.equal("openai/gpt-5", config.get().quickprompt.model)
		end)
	end)

	describe("context", function()
		it("takes the lines around the cursor in normal mode", function()
			vim.api.nvim_win_set_cursor(0, { 6, 0 })

			local context = QuickPrompt.context({ visual = false })
			assert.are.equal(buf, context.buf)
			assert.are.equal(vim.fs.normalize(path), context.path)
			assert.are.equal("lua", context.filetype)
			assert.are.equal(10, #context.lines)
			-- Row 6 ± 5 lines, clamped to the ten lines there are.
			assert.are.equal(1, context.first)
			assert.are.equal(10, context.last)
			assert.is_false(context.visual)
		end)

		it("clamps the window to the buffer", function()
			vim.api.nvim_win_set_cursor(0, { 2, 0 })

			local context = QuickPrompt.context({ visual = false })
			assert.are.equal(1, context.first)
			assert.are.equal(7, context.last)
		end)

		it("narrows the window with context_lines", function()
			config.options = { quickprompt = { context_lines = 1 } }
			config.config = nil
			vim.api.nvim_win_set_cursor(0, { 5, 0 })

			local context = QuickPrompt.context({ visual = false })
			assert.are.equal(4, context.first)
			assert.are.equal(6, context.last)
		end)

		it("takes the selection in visual mode", function()
			vim.api.nvim_win_set_cursor(0, { 3, 0 })
			vim.cmd("normal! Vjj")

			local context = QuickPrompt.context()
			assert.are.equal(3, context.first)
			assert.are.equal(5, context.last)
			assert.is_true(context.visual)
			vim.cmd("normal! \27")
		end)

		it("takes a range given by the caller, ordered", function()
			local context = QuickPrompt.context({ first = 8, last = 4 })
			assert.are.equal(4, context.first)
			assert.are.equal(8, context.last)
			assert.is_true(context.visual)
		end)

		it("has nothing to send for a buffer without a file", function()
			local scratch = vim.api.nvim_create_buf(false, true)
			assert.is_nil(QuickPrompt.context({ buf = scratch }))
			vim.api.nvim_buf_delete(scratch, { force = true })
		end)
	end)

	describe("message", function()
		it("carries the path, the numbered file, the region and the instruction", function()
			local context = QuickPrompt.context({ first = 2, last = 3 })
			local message = QuickPrompt.message("rename two", context)

			assert.is_truthy(message:find("File: " .. vim.fs.normalize(path), 1, true))
			assert.is_truthy(message:find("1\tone", 1, true))
			assert.is_truthy(message:find("10\tten", 1, true))
			assert.is_truthy(message:find("Selected lines 2-3:", 1, true))
			assert.is_truthy(message:find("Instruction: rename two", 1, true))
			assert.is_truthy(message:find("```lua", 1, true))
		end)

		it("calls the region lines, not a selection, in normal mode", function()
			local context = QuickPrompt.context({ visual = false })
			assert.is_truthy(QuickPrompt.message("go", context):find("Lines 1-", 1, true))
		end)
	end)

	describe("run", function()
		local client

		before_each(function()
			client = fake_client()
			QuickPrompt.client = function()
				return client
			end
		end)

		it("sends one prompt and reports it is running", function()
			local context = QuickPrompt.context({ first = 1, last = 2 })
			assert.is_true(QuickPrompt.run("fix it", context))

			assert.are.equal(1, #client.sent)
			assert.are.equal("prompt", client.sent[1].type)
			assert.is_truthy(client.sent[1].message:find("Instruction: fix it", 1, true))

			local status = QuickPrompt.status()
			assert.are.equal("running", status.state)
			assert.is_true(status.busy)
			assert.are.equal("fix it", status.prompt)
			assert.is_true(QuickPrompt.busy())
		end)

		it("goes back to idle when the model answers nothing", function()
			local ok, err
			QuickPrompt.run("fix it", QuickPrompt.context({ first = 1, last = 2 }), function(o, e)
				ok, err = o, e
			end)
			QuickPrompt.on_event({ type = "agent_end" })

			assert.is_true(ok)
			assert.is_nil(err)
			assert.are.equal("idle", QuickPrompt.status().state)
			assert.is_false(QuickPrompt.busy())
			assert.are.same({}, notifications)
		end)

		it("notifies an ERROR answer instead of editing", function()
			local ok, err
			QuickPrompt.run("fix it", QuickPrompt.context({ first = 1, last = 2 }), function(o, e)
				ok, err = o, e
			end)
			QuickPrompt.on_event({
				type = "message_update",
				assistantMessageEvent = { type = "text_delta", delta = "ERROR: nothing " },
			})
			QuickPrompt.on_event({
				type = "message_update",
				assistantMessageEvent = { type = "text_delta", delta = "to rename here" },
			})
			QuickPrompt.on_event({ type = "agent_end" })

			assert.is_false(ok)
			assert.are.equal("nothing to rename here", err)

			local status = QuickPrompt.status()
			assert.are.equal("error", status.state)
			assert.are.equal("nothing to rename here", status.message)
			assert.are.equal(1, #notifications)
			assert.are.equal(vim.log.levels.ERROR, notifications[1].level)
			assert.is_truthy(notifications[1].message:find("nothing to rename here", 1, true))
		end)

		it("reports a process that dies mid-request", function()
			QuickPrompt.run("fix it", QuickPrompt.context({ first = 1, last = 2 }))
			QuickPrompt.on_event({ type = "_process_exit", code = 1 })

			assert.are.equal("error", QuickPrompt.status().state)
			assert.is_truthy(QuickPrompt.status().message:find("pi exited (1)", 1, true))
		end)

		it("refuses a second request while one is running", function()
			local context = QuickPrompt.context({ first = 1, last = 2 })
			QuickPrompt.run("first", context)

			assert.is_false(QuickPrompt.run("second", context))
			assert.are.equal(1, #client.sent)
			assert.are.equal("first", QuickPrompt.status().prompt)
			assert.are.equal(vim.log.levels.WARN, notifications[1].level)
		end)

		it("reports a process that will not start", function()
			client = fake_client({ connect_error = "no pi here" })

			assert.is_false(QuickPrompt.run("fix it", QuickPrompt.context({ first = 1, last = 2 })))
			assert.are.equal("error", QuickPrompt.status().state)
			assert.are.equal("no pi here", QuickPrompt.status().message)
		end)

		it("reports a prompt that could not be sent", function()
			client = fake_client({ send_error = "pi process is not running" })

			assert.is_false(QuickPrompt.run("fix it", QuickPrompt.context({ first = 1, last = 2 })))
			assert.are.equal("error", QuickPrompt.status().state)
			assert.are.equal("pi process is not running", QuickPrompt.status().message)
			assert.is_false(QuickPrompt.busy())
		end)

		it("ignores events that arrive outside a request", function()
			QuickPrompt.on_event({ type = "agent_end" })
			assert.are.equal("idle", QuickPrompt.status().state)
		end)
	end)

	describe("status", function()
		it("hands out a copy, not the live table", function()
			local status = QuickPrompt.status()
			status.state = "running"
			assert.are.equal("idle", QuickPrompt.status().state)
		end)

		it("fires a User event on every change, for statuslines", function()
			QuickPrompt.client = function()
				return fake_client()
			end

			local seen = {}
			local group = vim.api.nvim_create_augroup("crust.quickprompt.spec", { clear = true })
			vim.api.nvim_create_autocmd("User", {
				group = group,
				pattern = QuickPrompt.EVENT,
				callback = function()
					seen[#seen + 1] = QuickPrompt.status().state
				end,
			})

			QuickPrompt.run("fix it", QuickPrompt.context({ first = 1, last = 2 }))
			QuickPrompt.on_event({ type = "agent_end" })

			assert.are.same({ "running", "idle" }, seen)
			vim.api.nvim_del_augroup_by_id(group)
		end)
	end)

	describe("ask", function()
		local client
		local input

		before_each(function()
			client = fake_client()
			QuickPrompt.client = function()
				return client
			end
			input = vim.ui.input
		end)

		after_each(function()
			vim.ui.input = input
		end)

		it("runs the instruction it is given without asking", function()
			vim.ui.input = function()
				error("should not ask")
			end

			assert.is_true(QuickPrompt.ask({ prompt = "fix it", first = 1, last = 2 }))
			assert.are.equal(1, #client.sent)
		end)

		it("asks for an instruction and runs the answer", function()
			vim.ui.input = function(_, on_confirm)
				on_confirm("make it lua")
			end

			assert.is_true(QuickPrompt.ask({ first = 1, last = 2 }))
			assert.are.equal(1, #client.sent)
			assert.are.equal("make it lua", QuickPrompt.status().prompt)
		end)

		it("does nothing when the prompt is cancelled", function()
			vim.ui.input = function(_, on_confirm)
				on_confirm(nil)
			end

			assert.is_true(QuickPrompt.ask({ first = 1, last = 2 }))
			assert.are.same({}, client.sent)
			assert.are.equal("idle", QuickPrompt.status().state)
		end)

		it("refuses a buffer without a file", function()
			local scratch = vim.api.nvim_create_buf(false, true)

			assert.is_false(QuickPrompt.ask({ buf = scratch }))
			assert.are.equal(vim.log.levels.WARN, notifications[1].level)

			vim.api.nvim_buf_delete(scratch, { force = true })
		end)
	end)
end)
