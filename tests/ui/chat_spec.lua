-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Chat = require("crust.ui.chat")
local Input = require("crust.ui.chat.input")
local config = require("crust.config")

---@param text string
local function result(text)
	return { content = { { type = "text", text = text } } }
end

describe("ui.chat", function()
	---@type Crust.Chat
	local chat
	local icons
	local labels

	before_each(function()
		config.options = {}
		config.config = nil
		icons = config.get().icons
		labels = config.get().labels
		chat = Chat.new()
	end)

	---@param label string
	---@return string
	local function header(label)
		return label .. " " .. tostring(os.date(config.get().timestamp_format))
	end

	---@param events Crust.Pi.Event[]
	local function feed(events)
		for _, event in ipairs(events) do
			chat:_on_event(event)
		end
	end

	it("exposes both panels and their buffers", function()
		local out_buf, in_buf = chat:bufs()
		assert.are.equal(chat:output():buf(), out_buf)
		assert.are.equal(chat:input():buf(), in_buf)
		assert.are_not.equal(out_buf, in_buf)
	end)

	it("is not visible before open", function()
		assert.is_false(chat:is_visible())
	end)

	describe("windows", function()
		before_each(function()
			chat._pi = {
				connect = function()
					return true
				end,
				is_running = function()
					return true
				end,
				send = function()
					return "id"
				end,
				close = function() end,
			}
			chat:open()
		end)

		after_each(function()
			chat:close()
		end)

		it("opens both windows", function()
			assert.is_not_nil(chat:output():win())
			assert.is_not_nil(chat:input():win())
			assert.is_true(chat:is_visible())
		end)

		it("closes the input when the output window is closed", function()
			vim.api.nvim_win_close(chat:output():win(), false)
			vim.wait(100, function()
				return chat:input():win() == nil
			end)
			assert.is_nil(chat:input():win())
			assert.is_false(chat:is_visible())
		end)

		it("closes the output when the input window is closed", function()
			vim.api.nvim_win_close(chat:input():win(), false)
			vim.wait(100, function()
				return chat:output():win() == nil
			end)
			assert.is_nil(chat:output():win())
			assert.is_false(chat:is_visible())
		end)

		it("keeps the input height and gives the rest to the output on resize", function()
			local columns, lines = vim.o.columns, vim.o.lines

			vim.o.columns, vim.o.lines = 200, 60
			vim.api.nvim_exec_autocmds("VimResized", {})

			assert.are.equal(math.floor(200 * 0.4), vim.api.nvim_win_get_width(chat:output():win()))
			assert.are.equal(Input.HEIGHT, vim.api.nvim_win_get_height(chat:input():win()))

			vim.o.columns, vim.o.lines = 80, 24
			vim.api.nvim_exec_autocmds("VimResized", {})

			assert.are.equal(math.floor(80 * 0.4), vim.api.nvim_win_get_width(chat:output():win()))
			assert.are.equal(Input.HEIGHT, vim.api.nvim_win_get_height(chat:input():win()))

			vim.o.columns, vim.o.lines = columns, lines
			vim.api.nvim_exec_autocmds("VimResized", {})
		end)

		it("keeps an input height set by hand", function()
			vim.api.nvim_win_set_height(chat:input():win(), 15)
			chat:resize()
			assert.are.equal(15, vim.api.nvim_win_get_height(chat:input():win()))
		end)

		it("grows the input back when something squashed it below the minimum", function()
			vim.api.nvim_win_set_height(chat:input():win(), 2)
			chat:resize()
			assert.are.equal(Input.min_height(), vim.api.nvim_win_get_height(chat:input():win()))
		end)

		it("does nothing when the chat is hidden", function()
			chat:close()
			assert.has_no.errors(function()
				chat:resize()
			end)
		end)

		it("ignores unrelated windows closing", function()
			vim.cmd("topleft split")
			local other = vim.api.nvim_get_current_win()
			vim.api.nvim_win_close(other, false)
			vim.wait(50)
			assert.is_true(chat:is_visible())
		end)

		it("reopens after both windows are gone", function()
			vim.api.nvim_win_close(chat:input():win(), false)
			vim.wait(100, function()
				return not chat:is_visible()
			end)

			chat:open()
			assert.is_true(chat:is_visible())
			assert.is_not_nil(chat:input():win())
		end)
	end)

	describe("events", function()
		it("renders a full assistant turn", function()
			feed({
				{ type = "agent_start" },
				{ type = "message_update", assistantMessageEvent = { type = "text_delta", delta = "Hel" } },
				{ type = "message_update", assistantMessageEvent = { type = "text_delta", delta = "lo" } },
				{ type = "agent_end" },
			})

			assert.are.same({ header(labels.agent), "", "Hello", "" }, chat:output():lines())
		end)

		it("ignores non-text assistant events", function()
			feed({
				{ type = "agent_start" },
				{ type = "message_update", assistantMessageEvent = { type = "thinking_delta", delta = "hmm" } },
				{ type = "message_update", assistantMessageEvent = { type = "text_delta", delta = "hi" } },
			})

			assert.are.equal("hi", chat:output():lines()[3])
		end)

		it("tracks streaming state", function()
			assert.is_false(chat._streaming)
			feed({ { type = "agent_start" } })
			assert.is_true(chat._streaming)
			feed({ { type = "agent_end" } })
			assert.is_false(chat._streaming)
		end)

		it("renders tool calls as in-place blocks around streamed text", function()
			feed({
				{ type = "agent_start" },
				{ type = "message_update", assistantMessageEvent = { type = "text_delta", delta = "Running." } },
				{ type = "tool_execution_start", toolCallId = "1", toolName = "bash", args = { command = "sleep 2" } },
				{ type = "tool_execution_update", toolCallId = "1", toolName = "bash", partialResult = result("hi") },
				{ type = "tool_execution_end", toolCallId = "1", toolName = "bash", result = result("hi") },
				{ type = "message_update", assistantMessageEvent = { type = "text_delta", delta = "Done." } },
				{ type = "agent_end" },
			})

			assert.are.same({
				header(labels.agent),
				"",
				"Running.",
				"",
				"> " .. icons.success .. " bash: sleep 2",
				"> hi",
				"",
				"Done.",
				"",
			}, chat:output():lines())
		end)

		it("reports stderr and process exit as errors", function()
			feed({
				{ type = "agent_start" },
				{ type = "_stderr", message = "bad thing" },
				{ type = "_process_exit", code = 1 },
			})

			local text = table.concat(chat:output():lines(), "\n")
			assert.is_truthy(text:find("**crust: bad thing**", 1, true))
			assert.is_truthy(text:find("**crust: pi exited (1)**", 1, true))
			assert.is_false(chat._streaming)
		end)

		it("ignores unknown events", function()
			feed({ { type = "queue_update", steering = {} } })
			assert.are.same({ "" }, chat:output():lines())
		end)
	end)

	describe("cancel", function()
		local sent

		before_each(function()
			sent = {}
			chat._pi = {
				connect = function()
					return true
				end,
				is_running = function()
					return true
				end,
				send = function(_, command)
					sent[#sent + 1] = command.type
					return "id"
				end,
				close = function() end,
			}
		end)

		it("does nothing when the agent is idle", function()
			assert.is_false(chat:cancel())
			assert.are.same({}, sent)
		end)

		it("sends abort while streaming", function()
			feed({ { type = "agent_start" } })
			assert.is_true(chat:cancel())
			assert.are.same({ "abort" }, sent)
			assert.are.equal("Cancelling…", chat:status():text())
		end)

		it("clears the status when the turn ends", function()
			feed({ { type = "agent_start" } })
			chat:cancel()
			feed({ { type = "agent_end" } })
			assert.is_nil(chat:status():text())
		end)

		it("binds the cancel key in both buffers", function()
			local function has_key(buf, mode)
				for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
					if map.lhs == "<C-C>" then
						return true
					end
				end
				return false
			end

			assert.is_true(has_key(chat:input():buf(), "n"))
			assert.is_true(has_key(chat:input():buf(), "i"))
			assert.is_true(has_key(chat:output():buf(), "n"))
		end)

		it("cancels from the keymap", function()
			feed({ { type = "agent_start" } })
			vim.api.nvim_set_current_buf(chat:input():buf())
			vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "x", false)
			assert.are.same({ "abort" }, sent)
		end)

		it("can be unbound", function()
			config.options = { keymaps = { cancel = false } }
			config.config = nil

			local other = Chat.new()
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(other:input():buf(), "n")) do
				assert.are_not.equal("<C-C>", map.lhs)
			end
		end)
	end)

	describe("submit", function()
		it("does nothing when the input is empty", function()
			chat:submit()
			assert.are.same({ "" }, chat:output():lines())
		end)

		it("echoes the prompt, clears the input, and sends it to pi", function()
			local sent
			-- Stub the client so no real pi process is spawned.
			chat._pi = {
				is_running = function()
					return true
				end,
				send = function(_, command)
					sent = command
					return "id-1"
				end,
			}

			chat:input():set_text("hello there")
			chat:submit()

			assert.are.same({ header(labels.user), "", "hello there", "" }, chat:output():lines())
			assert.are.equal("", chat:input():text())
			assert.are.equal("prompt", sent.type)
			assert.are.equal("hello there", sent.message)
		end)

		it("reports a send failure in the output", function()
			chat._pi = {
				is_running = function()
					return true
				end,
				send = function()
					return nil, "pi process is not running"
				end,
			}

			chat:input():set_text("hello")
			chat:submit()

			local text = table.concat(chat:output():lines(), "\n")
			assert.is_truthy(text:find("**crust: pi process is not running**", 1, true))
		end)

		it("streams follow-up prompts while the agent is running", function()
			local sent
			chat._pi = {
				is_running = function()
					return true
				end,
				send = function(_, command)
					sent = command
					return "id-1"
				end,
			}

			feed({ { type = "agent_start" } })
			chat:input():set_text("also do this")
			chat:submit()

			assert.are.equal("followUp", sent.streamingBehavior)
		end)
	end)

	describe("input bar", function()
		it("takes the model from a get_state answer", function()
			feed({
				{
					type = "response",
					command = "get_state",
					data = { sessionId = "s", model = { id = "gpt-5", contextWindow = 400000 }, thinkingLevel = "high" },
				},
			})

			assert.are.equal("gpt-5", chat:bar():state().model_id)
			assert.are.equal(400000, chat:bar():state().context_window)
		end)

		it("bills the messages the agent finishes", function()
			feed({
				{ type = "message_end", message = { role = "assistant", usage = { input = 10, cost = { total = 0.5 } } } },
				{ type = "message_end", message = { role = "user", usage = { input = 10, cost = { total = 9 } } } },
				{
					type = "message_end",
					message = {
						role = "assistant",
						stopReason = "aborted",
						usage = { input = 10, cost = { total = 9 } },
					},
				},
			})

			assert.are.equal(0.5, chat:bar():state().cost)
		end)

		it("clears the totals with the transcript", function()
			feed({
				{ type = "message_end", message = { role = "assistant", usage = { input = 10, cost = { total = 0.5 } } } },
			})
			chat:clear()

			assert.are.equal(0, chat:bar():state().cost)
		end)
	end)

	describe("tool preview", function()
		local Preview = require("crust.ui.chat.tools.preview")

		---@param command string
		local function call(command)
			feed({
				{ type = "agent_start" },
				{
					type = "tool_execution_end",
					toolCallId = "a",
					toolName = "bash",
					args = { command = command },
					result = result("output"),
				},
			})
		end

		after_each(function()
			Preview.close()
		end)

		it("opens the call under the cursor", function()
			chat:open()
			call("echo hi")

			local block = assert(chat._tools:display("a"))
			local row = assert(chat:output():view():block_row(chat._tools._blocks["a"]))
			vim.api.nvim_win_set_cursor(assert(chat:output():win()), { row + 1, 0 })

			assert.is_true(chat:preview_tool())
			-- luassert's `assert` passes its arguments back, so the window id
			-- has to be pinned down before it reaches an api call.
			local win = assert(Preview.win())
			local buf = vim.api.nvim_win_get_buf(win)
			assert.are.same(Preview.content(block).lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		end)

		it("does nothing on a line without a tool call", function()
			chat:open()
			call("echo hi")
			vim.api.nvim_win_set_cursor(assert(chat:output():win()), { 1, 0 })

			assert.is_false(chat:preview_tool())
			assert.is_nil(Preview.win())
		end)

		it("binds the preview key in the output panel only", function()
			---@param buf integer
			---@return boolean
			local function bound(buf)
				for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
					if map.lhs == "K" then
						return true
					end
				end
				return false
			end

			assert.is_true(bound(chat:output():buf()))
			assert.is_false(bound(chat:input():buf()))
		end)

		it("can be unbound", function()
			config.options = { keymaps = { preview = false } }
			config.config = nil

			local other = Chat.new()
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(other:output():buf(), "n")) do
				assert.are_not.equal("K", map.lhs)
			end
		end)
	end)
end)