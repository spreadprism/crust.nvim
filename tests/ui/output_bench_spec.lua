-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

--- Scaling guard for the output panel.
---
--- The panel used to keep the whole session in its buffer, so every write
--- scanned everything written before it and a long session crawled. These
--- specs pin the shape of the cost: writing into a long conversation has to
--- cost the same as writing into a short one.
---
--- Timings are ratios, never absolute numbers: CI machines are slow and
--- erratic, the property under test is "flat", not "fast".

local Output = require("crust.ui.chat.output")
local Highlights = require("crust.ui.highlights")
local config = require("crust.config")

--- Streamed deltas per sample.
local DELTAS = 300
--- Tool block rewrites per sample.
local REWRITES = 100
--- Slack over the short-session baseline. Generous on purpose.
local TOLERANCE = 4

---@param fn fun()
---@return number milliseconds
local function timed(fn)
	local started = vim.uv.hrtime()
	fn()
	return (vim.uv.hrtime() - started) / 1e6
end

---@param output Crust.Chat.Output
---@param count integer
local function conversation(output, count)
	output:batch(function()
		for index = 1, count do
			output:header("", Highlights.USER_TITLE, 0)
			output:append("question " .. index .. "\n")
			output:header("󰚩", Highlights.AGENT_TITLE, 0)
			output:append("answer " .. index .. "\nwith a second line\n")
		end
	end)
end

---@param count integer messages already in the panel
---@return table<string, number> milliseconds per phase
local function sample(count)
	local output = Output.new()
	local result = {}

	result.replay = timed(function()
		conversation(output, count)
	end)

	result.stream = timed(function()
		for index = 1, DELTAS do
			output:append("delta " .. index .. " ")
		end
	end)

	local block = output:append_block({ "> tool" })
	result.rewrite = timed(function()
		for index = 1, REWRITES do
			output:replace_block(block, { "> tool", "> line " .. index })
		end
	end)

	output:close()
	return result
end

describe("ui.chat.output scaling", function()
	before_each(function()
		config.options = {}
		config.config = nil
	end)

	it("writes at the same cost into a short and a long session", function()
		-- Warm the module, the very first render pays for treesitter.
		sample(10)

		local short = sample(50)
		local long = sample(2000)

		for _, phase in ipairs({ "stream", "rewrite" }) do
			local ratio = long[phase] / math.max(short[phase], 0.01)
			assert.is_true(
				ratio < TOLERANCE,
				string.format(
					"%s got %.1fx slower with 40x the history (%.1fms -> %.1fms)",
					phase,
					ratio,
					short[phase],
					long[phase]
				)
			)
		end
	end)

	it("replays a long session without quadratic cost", function()
		sample(10)

		local short = timed(function()
			local output = Output.new()
			conversation(output, 100)
			output:close()
		end)

		local long = timed(function()
			local output = Output.new()
			conversation(output, 1000)
			output:close()
		end)

		-- 10x the messages may cost 10x the work, not 100x.
		local ratio = long / math.max(short, 0.01)
		assert.is_true(ratio < 10 * TOLERANCE, string.format("replay scaled %.1fx for 10x the messages", ratio))
	end)

	it("keeps the buffer bounded however long the session runs", function()
		local output = Output.new()
		conversation(output, 2000)

		local drawn = vim.api.nvim_buf_line_count(output:buf())
		assert.is_true(drawn <= config.get().output.viewport.max_lines + 4, "drew " .. drawn .. " lines")
		assert.is_true(#output:lines() > 10000, "the transcript itself must stay complete")

		output:close()
	end)
end)
