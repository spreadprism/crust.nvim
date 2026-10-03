-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local QuickComplete = require("crust.quickcomplete")
local Highlights = require("crust.ui.highlights")
local config = require("crust.config")

describe("quickcomplete", function()
	local buf
	local client

	--- Stands in for the pi process: records what was sent, answers only
	--- when the spec feeds events in through `QuickComplete.on_event`.
	local function fake_client(opts)
		opts = opts or {}
		return {
			sent = {},
			running = true,
			is_running = function(self)
				return self.running
			end,
			connect = function()
				if opts.connect_error then
					return false, opts.connect_error
				end
				return true
			end,
			send = function(self, command)
				self.sent[#self.sent + 1] = command
				if opts.send_error and command.type == "prompt" then
					return nil, opts.send_error
				end
				return "id"
			end,
			close = function() end,
		}
	end

	--- The commands of a given type that reached the fake process.
	---@param kind string
	local function sent(kind)
		return vim.tbl_filter(function(command)
			return command.type == kind
		end, client.sent)
	end

	--- Answer the request in flight with `text`, as pi would.
	---@param text string
	local function answer(text)
		QuickComplete.on_event({
			type = "message_update",
			assistantMessageEvent = { type = "text_delta", delta = text },
		})
		QuickComplete.on_event({ type = "agent_end" })
	end

	---@return vim.api.keyset.get_extmark_item[]
	local function marks()
		return vim.api.nvim_buf_get_extmarks(buf, QuickComplete.ns, 0, -1, { details = true })
	end

	before_each(function()
		config.options = {}
		config.config = nil

		buf = vim.api.nvim_create_buf(true, false)
		-- The cursor sits inside the parens, where normal mode can actually
		-- put it: `nvim_win_set_cursor` clamps to the last character.
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
			"local function add(a, b)",
			"\tprint()",
			"end",
		})
		vim.bo[buf].filetype = "lua"
		vim.api.nvim_win_set_buf(0, buf)
		vim.api.nvim_win_set_cursor(0, { 2, 7 })

		client = fake_client()
		QuickComplete.client = function()
			return client
		end
	end)

	after_each(function()
		QuickComplete.stop()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
		config.options = {}
		config.config = nil
	end)

	describe("config", function()
		it("is off until it is asked for", function()
			assert.is_false(config.get().quickcomplete.enabled)
		end)

		it("defaults to the small model, debounced, with a short window", function()
			local cfg = config.get().quickcomplete
			assert.are.equal("anthropic/claude-haiku-4-5", cfg.model)
			assert.is_true(cfg.auto)
			assert.are.equal(250, cfg.debounce_ms)
			assert.are.equal(40, cfg.window_lines)
			assert.are.equal(64, cfg.cache_size)
		end)
	end)

	describe("context", function()
		it("splits the buffer at the cursor", function()
			local context = QuickComplete.context()
			assert.are.equal(buf, context.buf)
			assert.are.equal(1, context.row)
			assert.are.equal(7, context.col)
			assert.are.equal("\tprint(", context.before)
			assert.are.equal("local function add(a, b)\n\tprint(", context.prefix)
			assert.are.equal(")\nend", context.suffix)
		end)

		it("keeps only a window of lines around the cursor", function()
			config.options = { quickcomplete = { window_lines = 1 } }
			config.config = nil

			local lines = {}
			for index = 1, 40 do
				lines[index] = "line " .. index
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.api.nvim_win_set_cursor(0, { 20, 0 })

			local context = QuickComplete.context()
			assert.are.equal("line 19\n", context.prefix)
			assert.are.equal("line 20\nline 21", context.suffix)
		end)

		it("keys identical windows the same and different ones apart", function()
			local first = QuickComplete.context()
			local same = QuickComplete.context()
			vim.api.nvim_win_set_cursor(0, { 1, 5 })
			local other = QuickComplete.context()

			assert.are.equal(first.key, same.key)
			assert.are_not.equal(first.key, other.key)
		end)

		it("has nothing to complete in a chat panel", function()
			local panel = vim.api.nvim_create_buf(false, true)
			vim.bo[panel].filetype = require("crust.filetypes").output
			assert.is_nil(QuickComplete.context({ buf = panel }))
			vim.api.nvim_buf_delete(panel, { force = true })
		end)
	end)

	describe("prompt", function()
		it("frames the split with markers, not prose", function()
			local prompt = QuickComplete.prompt(QuickComplete.context())
			assert.is_truthy(prompt:find("<|language|> lua", 1, true))
			assert.is_truthy(prompt:find("<|prefix|>\nlocal function add(a, b)\n\tprint(\n<|suffix|>", 1, true))
			assert.is_truthy(prompt:find("<|complete|>", 1, true))
		end)
	end)

	describe("sanitize", function()
		local context

		before_each(function()
			context = QuickComplete.context()
		end)

		it("keeps the first line of raw text", function()
			assert.are.equal("a + b", QuickComplete.sanitize("a + b", context))
		end)

		it("drops fences and blank leading lines", function()
			assert.are.equal("a + b", QuickComplete.sanitize("```lua\na + b\n```", context))
		end)

		it("drops the prefix when the model repeats the line", function()
			assert.are.equal("a + b", QuickComplete.sanitize("\tprint(a + b", context))
		end)

		it("answers nothing for an empty answer", function()
			assert.are.equal("", QuickComplete.sanitize("\n\n", context))
		end)
	end)

	describe("request", function()
		it("sends one prompt and reports it is running", function()
			assert.is_true(QuickComplete.request(QuickComplete.context()))

			assert.are.equal(1, #sent("prompt"))
			assert.are.equal("running", QuickComplete.status().state)
			assert.is_true(QuickComplete.status().busy)
		end)

		it("caches the answer and never asks twice", function()
			local context = QuickComplete.context()
			QuickComplete.request(context)
			answer("a + b")

			assert.are.equal("idle", QuickComplete.status().state)
			assert.are.equal(1, QuickComplete.status().cached)
			assert.is_false(QuickComplete.request(context))
			assert.are.equal(1, #sent("prompt"))
		end)

		it("cuts the answer short at the first newline", function()
			local context = QuickComplete.context()
			QuickComplete.request(context, true)

			QuickComplete.on_event({
				type = "message_update",
				assistantMessageEvent = { type = "text_delta", delta = "a + b\nmore" },
			})

			assert.are.equal("a + b", QuickComplete.text())
			assert.are.equal("idle", QuickComplete.status().state)
		end)

		it("joins a request already in flight for the same context", function()
			local context = QuickComplete.context()
			QuickComplete.request(context)

			assert.is_false(QuickComplete.request(context, true))
			assert.are.equal(1, #sent("prompt"))

			answer("a + b")
			assert.are.equal("a + b", QuickComplete.text())
		end)

		it("aborts the request in flight when the context moves", function()
			QuickComplete.request(QuickComplete.context())
			vim.api.nvim_win_set_cursor(0, { 1, 5 })
			QuickComplete.request(QuickComplete.context())

			assert.are.equal(1, #sent("abort"))
			assert.are.equal(2, #sent("prompt"))
		end)

		it("drops an answer that arrives after the cursor moved on", function()
			QuickComplete.request(QuickComplete.context(), true)
			vim.api.nvim_win_set_cursor(0, { 1, 5 })
			answer("a + b")

			assert.is_false(QuickComplete.visible())

			-- Still worth keeping: coming back to that line is free, and costs
			-- no second request.
			assert.are.equal(1, QuickComplete.status().cached)
			vim.api.nvim_win_set_cursor(0, { 2, 7 })
			assert.is_true(QuickComplete.show_completion())
			assert.are.equal("a + b", QuickComplete.text())
			assert.are.equal(1, #sent("prompt"))
		end)

		it("reports a process that will not start", function()
			client = fake_client({ connect_error = "no pi here" })

			assert.is_false(QuickComplete.request(QuickComplete.context()))
			assert.are.equal("error", QuickComplete.status().state)
			assert.are.equal("no pi here", QuickComplete.status().message)
		end)

		it("reports a prompt that could not be sent", function()
			client = fake_client({ send_error = "pi process is not running" })

			assert.is_false(QuickComplete.request(QuickComplete.context()))
			assert.are.equal("error", QuickComplete.status().state)
			assert.is_false(QuickComplete.status().busy)
		end)

		it("reports a process that dies", function()
			QuickComplete.request(QuickComplete.context())
			QuickComplete.on_event({ type = "_process_exit", code = 1 })

			assert.are.equal("error", QuickComplete.status().state)
			assert.is_truthy(QuickComplete.status().message:find("pi exited (1)", 1, true))
		end)

		it("forgets the oldest completion past the cache size", function()
			config.options = { quickcomplete = { cache_size = 1 } }
			config.config = nil

			QuickComplete.request(QuickComplete.context())
			answer("a + b")
			vim.api.nvim_win_set_cursor(0, { 1, 5 })
			QuickComplete.request(QuickComplete.context())
			answer("tion")

			assert.are.equal(1, QuickComplete.status().cached)
		end)
	end)

	describe("schedule", function()
		it("fires one request for a burst of keystrokes", function()
			QuickComplete.schedule({ delay = 10 })
			QuickComplete.schedule({ delay = 10 })
			QuickComplete.schedule({ delay = 10 })

			vim.wait(200, function()
				return #sent("prompt") > 0
			end)
			assert.are.equal(1, #sent("prompt"))
		end)
	end)

	describe("show_completion", function()
		it("draws a cached completion as ghost text at the cursor", function()
			local context = QuickComplete.context()
			QuickComplete.request(context)
			answer("a + b")

			assert.is_true(QuickComplete.show_completion())
			assert.is_true(QuickComplete.visible())
			assert.are.equal("a + b", QuickComplete.text())

			local mark = marks()[1]
			assert.are.equal(1, mark[2])
			assert.are.equal(7, mark[3])
			assert.are.same({ { "a + b", Highlights.GHOST_TEXT } }, mark[4].virt_text)
		end)

		it("asks and draws the answer when nothing is cached", function()
			assert.is_false(QuickComplete.show_completion())
			assert.are.equal(1, #sent("prompt"))

			answer("a + b")
			assert.is_true(QuickComplete.visible())
		end)

		it("shows nothing for an empty completion", function()
			QuickComplete.show_completion()
			answer("")

			assert.is_false(QuickComplete.visible())
			assert.are.same({}, marks())
		end)

		it("has nothing to show in a chat panel", function()
			local panel = vim.api.nvim_create_buf(false, true)
			vim.bo[panel].filetype = require("crust.filetypes").input

			assert.is_false(QuickComplete.show_completion({ buf = panel }))
			assert.are.same({}, sent("prompt"))

			vim.api.nvim_buf_delete(panel, { force = true })
		end)
	end)

	describe("accept_completion", function()
		before_each(function()
			QuickComplete.request(QuickComplete.context())
			answer("a + b")
			QuickComplete.show_completion()
		end)

		it("inserts the ghost text and puts the cursor behind it", function()
			assert.is_true(QuickComplete.accept_completion())

			assert.are.equal("\tprint(a + b)", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
			assert.are.same({ 2, 12 }, vim.api.nvim_win_get_cursor(0))
			assert.is_false(QuickComplete.visible())
			assert.are.same({}, marks())
		end)

		it("does nothing when no completion is shown", function()
			QuickComplete.hide_completion()

			assert.is_false(QuickComplete.accept_completion())
			assert.are.equal("\tprint()", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1])
		end)
	end)

	describe("hide_completion", function()
		it("takes the ghost text off the buffer", function()
			QuickComplete.show_completion()
			answer("a + b")
			assert.is_true(QuickComplete.visible())

			QuickComplete.hide_completion()
			assert.is_false(QuickComplete.visible())
			assert.is_nil(QuickComplete.text())
			assert.are.same({}, marks())
		end)

		it("is a no-op when nothing is shown", function()
			assert.has_no.errors(function()
				QuickComplete.hide_completion()
			end)
		end)
	end)

	describe("status", function()
		it("fires a User event on every change, for statuslines", function()
			local seen = {}
			local group = vim.api.nvim_create_augroup("crust.quickcomplete.spec", { clear = true })
			vim.api.nvim_create_autocmd("User", {
				group = group,
				pattern = QuickComplete.EVENT,
				callback = function()
					seen[#seen + 1] = QuickComplete.status().state
				end,
			})

			QuickComplete.request(QuickComplete.context(), true)
			answer("a + b")

			assert.is_truthy(vim.tbl_contains(seen, "running"))
			assert.is_truthy(vim.tbl_contains(seen, "idle"))
			vim.api.nvim_del_augroup_by_id(group)
		end)

		it("hands out a copy, not the live table", function()
			local status = QuickComplete.status()
			status.state = "running"
			assert.are.equal("idle", QuickComplete.status().state)
		end)
	end)
end)
