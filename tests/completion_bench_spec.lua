-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

--- Latency of one keystroke inside a `@mention` or a `/command`.
---
--- Completion runs on every character typed in the prompt, synchronously on
--- the main loop, over a file list that can hold `Files.MAX_FILES` paths. A
--- keystroke that costs more than a frame is felt directly as typing lag,
--- and the worst case is not the one that shows results: a prefix nothing
--- starts with walks the whole list twice, once for prefixes and once for
--- the fuzzy pass.
---
--- The scan itself is not timed here: it is asynchronous, and `complete_*`
--- only ever reads the cache it has filled so far.

local Completion = require("crust.completion")
local Files = require("crust.completion.files")
local Commands = require("crust.completion.commands")
local Omnifunc = require("crust.completion.omnifunc")
local Blink = require("crust.completion.blink")

--- Keystrokes per sample: one call is too short to time reliably.
local KEYSTROKES = 50
--- Milliseconds one keystroke may take. A frame is 16ms; completion shares
--- it with the redraw and with blink's own filtering, so it gets half.
local BUDGET_MS = 8

---@param fn fun()
---@return number milliseconds
local function timed(fn)
	local started = vim.uv.hrtime()
	fn()
	return (vim.uv.hrtime() - started) / 1e6
end

--- A project listing shaped like a real one: nested directories, a long
--- tail of leaf files.
---@param count integer
---@return string[]
local function paths(count)
	local list = {}
	for index = 1, count do
		local dir = string.format("lua/module%03d/sub%02d", index % 250, index % 40)
		list[index] = string.format("%s/file_%05d.lua", dir, index)
	end
	return list
end

---@param count integer
---@return Crust.Pi.CommandInfo[]
local function commands(count)
	local list = {}
	for index = 1, count do
		list[index] = {
			name = index % 3 == 0 and ("skill:helper" .. index) or ("command" .. index),
			description = "command number " .. index,
			source = index % 3 == 0 and "skill" or (index % 2 == 0 and "prompt" or "extension"),
		}
	end
	return list
end

---@param path string
---@param kind string
---@param fuzzy boolean
---@return table
local function item(path, kind, fuzzy)
	return { word = path, kind = kind, fuzzy = fuzzy }
end

--- Average cost of `KEYSTROKES` completions.
---@param fn fun(index: integer)
---@return number milliseconds per keystroke
local function per_keystroke(fn)
	return timed(function()
		for index = 1, KEYSTROKES do
			fn(index)
		end
	end) / KEYSTROKES
end

---@param label string
---@param ms number
local function report(label, ms)
	print(string.format("completion %s: %.3fms per keystroke", label, ms))
end

---@param label string
---@param ms number
local function assert_budget(label, ms)
	assert.is_true(
		ms < BUDGET_MS,
		string.format("%s cost %.3fms per keystroke (budget %dms)", label, ms, BUDGET_MS)
	)
end

describe("completion latency", function()
	local list, command_list

	before_each(function()
		list, command_list = Files.list, Commands.list
	end)

	after_each(function()
		Files.list, Commands.list = list, command_list
	end)

	---@param count integer
	local function stub_files(count)
		local files = paths(count)
		Files.list = function()
			return files
		end
	end

	describe("@mentions", function()
		it("answers a bare @ within the budget, whatever the project size", function()
			stub_files(1000)
			local small = per_keystroke(function()
				Completion.complete_files("", item)
			end)

			stub_files(Files.MAX_FILES)
			local large = per_keystroke(function()
				Completion.complete_files("", item)
			end)

			report("@ on 1k files", small)
			report("@ on " .. Files.MAX_FILES .. " files", large)

			-- `MAX_ITEMS` caps the popup, not the walk: directories collapse
			-- into one entry each, so a wide tree is scanned whole before the
			-- cap is reached. The budget is what has to hold.
			assert_budget("@ on a large project", large)
			print(string.format("completion scaling: %.1fx for 20x the files", large / math.max(small, 0.001)))
		end)

		it("answers a matching prefix within the budget", function()
			stub_files(Files.MAX_FILES)

			local ms = per_keystroke(function(index)
				Completion.complete_files(("lua/module%03d/"):format(index % 250), item)
			end)

			report("@lua/moduleNNN/ on " .. Files.MAX_FILES .. " files", ms)
			assert_budget("a matching prefix", ms)
		end)

		it("answers the worst case — a prefix nothing starts with — within the budget", function()
			stub_files(Files.MAX_FILES)

			-- No prefix hit, so every path is walked twice: the prefix pass and
			-- then the fuzzy one, which also fails on every path.
			local ms = per_keystroke(function(index)
				Completion.complete_files("zqx" .. index, item)
			end)

			report("@zqxNN (no match) on " .. Files.MAX_FILES .. " files", ms)
			assert_budget("a prefix nothing matches", ms)
		end)

		it("answers a deep prefix within the budget", function()
			stub_files(Files.MAX_FILES)

			local ms = per_keystroke(function(index)
				Completion.complete_files(("lua/module%03d/sub%02d/file_"):format(index % 250, index % 40), item)
			end)

			report("@lua/…/file_ on " .. Files.MAX_FILES .. " files", ms)
			assert_budget("a deep prefix", ms)
		end)
	end)

	describe("/commands", function()
		it("answers within the budget with many commands", function()
			Commands.list = function()
				return commands(500)
			end

			local prefix = per_keystroke(function(index)
				Completion.complete_commands("command" .. (index % 100), item)
			end)
			local miss = per_keystroke(function(index)
				Completion.complete_commands("zqx" .. index, item)
			end)

			report("/commandNN over 500 commands", prefix)
			report("/zqxNN (no match) over 500 commands", miss)
			assert_budget("a command prefix", prefix)
			assert_budget("a command prefix nothing matches", miss)
		end)
	end)

	describe("front ends", function()
		---@return integer buf
		local function input_buf()
			local buf = vim.api.nvim_create_buf(false, true)
			vim.bo[buf].filetype = require("crust.filetypes").input
			vim.api.nvim_set_current_buf(buf)
			return buf
		end

		it("answers a blink request within the budget", function()
			stub_files(Files.MAX_FILES)
			local buf = input_buf()

			-- The scan is asynchronous and out of scope: the source only reads
			-- the cache, and kicking off a refresh must not be timed.
			local ensure = Files.ensure
			Files.ensure = function() end

			local source = Blink.new()
			assert.is_true(source:enabled())

			local line = "please look at @lua/module001/"
			local ms = per_keystroke(function()
				source:get_completions({ line = line, cursor = { 3, #line } }, function() end)
			end)

			Files.ensure = ensure
			vim.api.nvim_buf_delete(buf, { force = true })

			report("blink @lua/module001/", ms)
			assert_budget("a blink request", ms)
		end)

		it("answers a completefunc request within the budget", function()
			stub_files(Files.MAX_FILES)
			local buf = input_buf()

			local ensure = Files.ensure
			Files.ensure = function() end

			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "", "look at @lua/module001/" })
			vim.api.nvim_win_set_cursor(0, { 3, #"look at @lua/module001/" })

			local start = Omnifunc.completefunc(1, "")
			assert.are.equal(8, start)

			local ms = per_keystroke(function()
				Omnifunc.completefunc(0, "@lua/module001/")
			end)

			Files.ensure = ensure
			vim.api.nvim_buf_delete(buf, { force = true })

			report("completefunc @lua/module001/", ms)
			assert_budget("a completefunc request", ms)
		end)
	end)
end)
