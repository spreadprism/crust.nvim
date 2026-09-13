local Chat = require("crust.ui.chat")
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
				icons.success .. " bash: sleep 2",
				"  hi",
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
end)
