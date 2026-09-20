-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Pi = require("crust.pi.client")
local Rpc = require("crust.pi.rpc")

local async = vim.async

--- Real model calls are slow, keep the budget generous.
local ANSWER_TIMEOUT_MS = 120000

local EXPECTED = "hello from llm"

local TEST_MODEL = "anthropic/claude-haiku-4-5"

--- Keep the run reproducible: discovered extensions, skills and AGENTS.md
--- files would otherwise steer the answer.
--- Extensions needed for the run (auth providers, for example) can be listed
--- in CRUST_TEST_PI_EXTENSIONS as ":" separated paths, they are loaded with -e.
local function isolated_args()
	local args = {
		"--no-session",
		"--no-skills",
		"--no-context-files",
		"--no-tools",
	}

	for _, path in ipairs(vim.split(vim.env.CRUST_TEST_PI_EXTENSIONS or "", ":", { trimempty = true })) do
		vim.list_extend(args, { "-e", path })
	end

	return args
end
local PROMPT = table.concat({
	"This is an automated integration test of the rpc protocol.",
	"Do not use any tools and do not add any commentary.",
	"Reply with exactly this text and nothing else: " .. EXPECTED,
}, " ")

--- One-shot signal usable from an event handler, awaited from a task.
---@return { resolve: fun(value: any), await: async fun(): any }
local function signal()
	local resolved, value = false, nil
	local waiter ---@type fun(value: any)?

	return {
		resolve = function(v)
			if resolved then
				return
			end
			resolved, value = true, v
			if waiter then
				waiter(v)
			end
		end,
		await = function()
			if resolved then
				return value
			end
			return async.await(1, function(callback)
				waiter = callback --[[@as fun(value: any)]]
			end)
		end,
	}
end

--- Run an async task from a synchronous test body and re-raise its errors.
---@param fn async fun()
local function run(fn)
	async.run(fn):wait(ANSWER_TIMEOUT_MS)
end

describe("quick chat", function()
	it("answers the test prompt with the exact requested text", function()
		if vim.fn.executable("pi") == 0 then
			return
		end

		local chunks = {} ---@type string[]
		local agent_error ---@type string?
		local answered = signal()

		local pi = Pi.new({
			args = isolated_args(),
			model = TEST_MODEL,
			on_event = function(event)
				if event.type == "message_update" then
					local delta = event.assistantMessageEvent
					if delta and delta.type == "text_delta" and delta.delta then
						chunks[#chunks + 1] = delta.delta
					end
				elseif event.type == "message_end" then
					local message = event.message --[[@as Crust.Pi.Message?]]
					if type(message) == "table" and message.stopReason == "error" then
						agent_error = message.errorMessage or "assistant message failed"
					end
				elseif event.type == "agent_end" or event.type == "agent_settled" then
					answered.resolve(table.concat(chunks))
				elseif event.type == "_process_exit" then
					answered.resolve(nil)
				end
			end,
		})

		assert.True(pi:connect())

		local ok, err = pcall(function()
			run(function()
				local res = async.await(1, function(callback)
					local id, send_err = pi:send(Rpc.prompt(PROMPT), callback --[[@as fun(event: Crust.Pi.Response)]])
					assert(id, send_err)
				end) --[[@as Crust.Pi.Response]]

				assert.are.equal("prompt", res.command)
				assert.True(res.success)

				local text = answered.await() --[[@as string?]]
				assert.is_nil(agent_error)
				assert.is_string(text)
				assert.are.equal(EXPECTED, vim.trim(text or ""):lower())
			end)
		end)

		pi:close()
		assert(ok, err)
	end)
end)