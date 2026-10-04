-- Specs poke at private fields, which is the point here: compaction is a
-- state machine fed by events, with no public surface of its own.
---@diagnostic disable: invisible

local Chat = require("crust.ui.chat")
local config = require("crust.config")

describe("ui.chat compaction", function()
	---@type Crust.Chat
	local chat
	---@type Crust.Pi.Command[]
	local sent
	local running

	--- Built per test: the config is read while the panel comes up, so
	--- `config.setup` has to run first.
	local function new_chat()
		sent = {}
		running = true
		chat = Chat.new()
		chat._pi = {
			connect = function()
				running = true
				return true
			end,
			is_running = function()
				return running
			end,
			send = function(_, command)
				sent[#sent + 1] = command
				return "id"
			end,
			close = function() end,
		}
		return chat
	end

	before_each(function()
		config.options = {}
		config.config = nil
		new_chat()
	end)

	---@param opts table
	local function reconfigure(opts)
		config.options = nil
		config.config = nil
		config.setup(opts)
		new_chat()
	end

	---@param events Crust.Pi.Event[]
	local function feed(events)
		for _, event in ipairs(events) do
			chat:_on_event(event)
		end
	end

	---@return string
	local function text()
		return table.concat(chat:output():lines(), "\n")
	end

	---@param tokens_before integer
	---@param tokens_after integer
	---@return Crust.Pi.Event
	local function ended(tokens_before, tokens_after)
		return {
			type = "compaction_end",
			result = {
				summary = "a summary",
				firstKeptEntryId = "e1",
				tokensBefore = tokens_before,
				estimatedTokensAfter = tokens_after,
			},
		}
	end

	describe("display", function()
		it("writes a notice with the tokens freed", function()
			feed({ { type = "compaction_start", reason = "threshold" }, ended(120000, 24000) })
			assert.is_truthy(text():find("context compacted: 120k → ~24k tokens", 1, true))
		end)

		it("prefixes the notice with the configured icon", function()
			reconfigure({ compaction = { icon = "#" } })
			feed({ { type = "compaction_start", reason = "manual" }, ended(1000, 100) })
			assert.is_truthy(text():find("# context compacted", 1, true))
		end)

		it("highlights the notice instead of letting markdown style it", function()
			feed({ { type = "compaction_start", reason = "manual" }, ended(1000, 100) })

			local row
			for index, line in ipairs(chat:output():lines()) do
				if line:find("context compacted", 1, true) then
					row = index - 1
				end
			end
			assert.is_not_nil(row)

			local marks = vim.api.nvim_buf_get_extmarks(
				chat:output():buf(),
				-1,
				{ row, 0 },
				{ row, -1 },
				{ details = true }
			)
			local groups = vim.tbl_map(function(mark)
				return mark[4].hl_group
			end, marks)
			assert.is_truthy(vim.tbl_contains(groups, require("crust.ui.highlights").NOTICE))
		end)

		it("can be turned off, the compaction itself still happens", function()
			reconfigure({ compaction = { notify = false } })
			feed({ { type = "compaction_start", reason = "threshold" }, ended(1000, 100) })
			assert.is_falsy(text():find("context compacted", 1, true))
			assert.is_false(chat._compacting)
		end)

		it("reports a failed compaction", function()
			feed({ { type = "compaction_start", reason = "overflow" }, { type = "compaction_end", aborted = true } })
			assert.is_truthy(text():find("compaction failed", 1, true))
			assert.is_falsy(text():find("context compacted", 1, true))
		end)

		it("says what is happening while it runs", function()
			feed({ { type = "compaction_start", reason = "threshold" } })
			assert.is_true(chat._compacting)
			assert.are.equal("compacting (threshold)", chat:status():text())
		end)

		it("drops the context estimate, the summary replaces what it measured", function()
			chat:bar():update_state({ model = { id = "m", name = "m", provider = "p", contextWindow = 1000 } })
			chat:bar():add_usage({ input = 900 })
			assert.are.equal(900, chat:bar()._state.context_tokens)

			feed({ { type = "compaction_start", reason = "threshold" } })
			assert.is_nil(chat:bar()._state.context_tokens)
		end)

		it("hands the status line back to the turn that is still running", function()
			feed({
				{ type = "agent_start" },
				{ type = "compaction_start", reason = "overflow" },
				ended(1000, 100),
			})
			assert.is_true(chat._streaming)
			assert.is_false(chat._compacting)
			assert.are.equal(config.get().status_text, chat:status():text())
		end)
	end)

	describe("the switch", function()
		---@param name string
		---@return Crust.Pi.Command?
		local function command(name)
			for _, item in ipairs(sent) do
				if item.type == name then
					return item
				end
			end
		end

		it("tells pi to compact on its own by default", function()
			running = false
			chat:_ensure_running()
			assert.are.equal(true, command("set_auto_compaction").enabled)
		end)

		it("turns it off when the config says so", function()
			reconfigure({ compaction = { auto = false } })
			running = false
			chat:_ensure_running()
			assert.are.equal(false, command("set_auto_compaction").enabled)
		end)

		it("leaves pi's own setting alone when the option is nil", function()
			config.get().compaction.auto = nil
			running = false
			chat:_ensure_running()
			assert.is_nil(command("set_auto_compaction"))
		end)

		it("sends a compact command with the instructions it was given", function()
			assert.is_true(chat:compact("keep the file list"))
			assert.are.equal("keep the file list", command("compact").customInstructions)
		end)

		it("refuses a second compaction while one runs", function()
			feed({ { type = "compaction_start", reason = "manual" } })
			assert.is_false(chat:compact())
			assert.is_truthy(text():find("already running", 1, true))
		end)
	end)
end)
