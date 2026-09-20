-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

--- Latency of `<CR>` in the prompt.
---
--- Everything between the keymap and `chansend` runs on the main loop, so
--- whatever it costs is felt as a freeze: the prompt is cleared, the typed
--- text is written into the scrollback, `@mentions` are expanded (which
--- reads files), and only then does the command reach the process.
---
--- These specs time that path and break it into phases, so a regression
--- shows up as "which phase" rather than "the chat feels slow". Budgets are
--- deliberately loose — CI machines are slow and erratic — and the scaling
--- assertions are ratios, which is the property that actually matters:
--- pressing `<CR>` must not get slower as the session grows.

local Chat = require("crust.ui.chat")
local Highlights = require("crust.ui.highlights")
local Expansion = require("crust.expansion")
local config = require("crust.config")

--- Submits per sample: one `<CR>` is too short to time reliably.
local SUBMITS = 20
--- Slack over the short-session baseline.
local TOLERANCE = 4
--- Milliseconds one `<CR>` may take on a plain prompt. A frame is 16ms and
--- this path is synchronous, so anything near that is felt.
local BUDGET_MS = 16

---@param fn fun()
---@return number milliseconds
local function timed(fn)
	local started = vim.uv.hrtime()
	fn()
	return (vim.uv.hrtime() - started) / 1e6
end

---@class Crust.Bench.Submit
---@field total number ms per submit, keypress to chansend
---@field to_send number ms per submit spent before the command is handed over
---@field expansion number ms per submit inside the prompt expanders
---@field output number ms per submit spent writing the scrollback
---@field input number ms per submit spent clearing the prompt

--- A chat whose process is a stub: `send` only records when it was reached.
---@return Crust.Chat chat
---@return fun(): number sent_at hrtime of the last command handed over
local function stub_chat()
	local chat = Chat.new()
	local sent_at = 0

	chat._pi = {
		connect = function()
			return true
		end,
		is_running = function()
			return true
		end,
		send = function()
			sent_at = vim.uv.hrtime()
			return "id"
		end,
		close = function() end,
	}

	return chat,
		function()
			return sent_at
		end
end

---@param chat Crust.Chat
---@param count integer messages already on screen
local function history(chat, count)
	local output = chat:output()
	output:batch(function()
		for index = 1, count do
			output:header("", Highlights.USER_TITLE, 0)
			output:append_message("question " .. index .. "\n")
			output:header("󰚩", Highlights.AGENT_TITLE, 0)
			output:append_message("answer " .. index .. "\nwith a second line\n")
		end
	end)
end

--- Time `SUBMITS` prompts through the real submit path.
---@param count integer messages already in the panel
---@param prompt string what is typed into the input
---@param open? boolean with the panel on screen, so the write is rendered
---@return Crust.Bench.Submit
local function sample(count, prompt, open)
	local chat, sent_at = stub_chat()
	if open then
		-- On screen the write is not just buffer lines: the viewport, the
		-- markdown pass and the highlights run on it too.
		chat:open()
	end
	history(chat, count)

	-- Phase timers: the expanders and the scrollback writes are the two
	-- halves of the work `_send` does before the process hears anything.
	local expansion, output_ms, input_ms = 0, 0, 0

	local expand = Expansion.expand
	Expansion.expand = function(...)
		local args = { ... }
		local result
		expansion = expansion + timed(function()
			result = expand(unpack(args))
		end)
		return result
	end

	local out = chat:output()
	local header, append_message = out.header, out.append_message
	out.header = function(...)
		local args = { ... }
		output_ms = output_ms + timed(function()
			header(unpack(args))
		end)
	end
	out.append_message = function(...)
		local args = { ... }
		output_ms = output_ms + timed(function()
			append_message(unpack(args))
		end)
	end

	local prompt_input = chat:input()
	local clear = prompt_input.clear
	prompt_input.clear = function(...)
		local args = { ... }
		input_ms = input_ms + timed(function()
			clear(unpack(args))
		end)
	end

	local to_send = 0
	local total = timed(function()
		for index = 1, SUBMITS do
			chat:input():set_text(prompt .. " " .. index)
			local pressed = vim.uv.hrtime()
			chat:input():submit()
			to_send = to_send + (sent_at() - pressed) / 1e6
		end
	end)

	Expansion.expand = expand
	out.header, out.append_message = header, append_message
	prompt_input.clear = clear
	chat:close()
	chat:stop()

	return {
		total = total / SUBMITS,
		to_send = to_send / SUBMITS,
		expansion = expansion / SUBMITS,
		output = output_ms / SUBMITS,
		input = input_ms / SUBMITS,
	}
end

---@param label string
---@param result Crust.Bench.Submit
local function report(label, result)
	print(
		string.format(
			"submit %s: %.2fms to chansend (total %.2fms, expansion %.2fms, output %.2fms, input %.2fms)",
			label,
			result.to_send,
			result.total,
			result.expansion,
			result.output,
			result.input
		)
	)
end

describe("ui.chat submit latency", function()
	before_each(function()
		config.options = {}
		config.config = nil
	end)

	it("reaches the process within a frame on a plain prompt", function()
		-- Warm everything: the first submit pays for treesitter, the config
		-- and the expander modules.
		sample(5, "warmup")

		local result = sample(50, "hello there")
		report("plain prompt, 50 messages", result)

		assert.is_true(
			result.to_send < BUDGET_MS,
			string.format("<CR> took %.2fms to reach the process (budget %dms)", result.to_send, BUDGET_MS)
		)
	end)

	it("costs the same in a long session as in a short one", function()
		sample(5, "warmup")

		local short = sample(50, "hello there")
		local long = sample(2000, "hello there")
		report("short session", short)
		report("long session", long)

		local ratio = long.to_send / math.max(short.to_send, 0.01)
		assert.is_true(
			ratio < TOLERANCE,
			string.format(
				"<CR> got %.1fx slower with 40x the history (%.2fms -> %.2fms)",
				ratio,
				short.to_send,
				long.to_send
			)
		)
	end)

	it("reaches the process within a frame with the panel on screen", function()
		sample(5, "warmup", true)

		local short = sample(50, "hello there", true)
		local long = sample(2000, "hello there", true)
		report("visible panel, 50 messages", short)
		report("visible panel, 2000 messages", long)

		assert.is_true(
			short.to_send < BUDGET_MS,
			string.format("<CR> took %.2fms with the panel open (budget %dms)", short.to_send, BUDGET_MS)
		)

		local ratio = long.to_send / math.max(short.to_send, 0.01)
		assert.is_true(
			ratio < TOLERANCE,
			string.format(
				"<CR> on screen got %.1fx slower with 40x the history (%.2fms -> %.2fms)",
				ratio,
				short.to_send,
				long.to_send
			)
		)
	end)

	it("costs the same whatever the prompt length", function()
		sample(5, "warmup")

		local short = sample(50, "hello there")
		local long = sample(50, string.rep("a longer prompt with many words ", 200))
		report("long prompt", long)

		local ratio = long.to_send / math.max(short.to_send, 0.01)
		assert.is_true(
			ratio < TOLERANCE * 2,
			string.format("a 200x longer prompt cost %.1fx (%.2fms -> %.2fms)", ratio, short.to_send, long.to_send)
		)
	end)

	it("charges a mention to the expander, and reads each file once", function()
		sample(5, "warmup")

		local file = vim.fn.tempname()
		local lines = {}
		for index = 1, 2000 do
			lines[index] = "line " .. index .. " of a file the mention pulls in"
		end
		vim.fn.writefile(lines, file)

		local plain = sample(50, "hello there")
		local mention = sample(50, "please read @" .. file)
		report("with a @mention", mention)

		vim.fn.delete(file)

		-- The point of the breakdown: a mention makes `<CR>` slower, and the
		-- cost has to sit in the expander (file IO) and nowhere else.
		local overhead = mention.to_send - plain.to_send
		if overhead > 1 then
			assert.is_true(
				mention.expansion > overhead * 0.5,
				string.format(
					"mention added %.2fms but only %.2fms of it is expansion",
					overhead,
					mention.expansion
				)
			)
		end
	end)
end)
