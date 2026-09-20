-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Pi = require("crust.pi.client")
local Rpc = require("crust.pi.rpc")

local async = vim.async

local TIMEOUT_MS = 15000

local TEST_MODEL = "anthropic/claude-haiku-4-5"
local TEST_MODEL_PROVIDER, TEST_MODEL_ID = TEST_MODEL:match("^(.-)/(.+)$")

--- Await the response to a command inside an async task.
---@async
---@param pi Crust.Pi
---@param command Crust.Pi.Command
---@return Crust.Pi.Response
local function request(pi, command)
	local response = async.await(1, function(callback)
		local id, err = pi:send(command, callback --[[@as fun(event: Crust.Pi.Response)]])
		assert(id, err)
	end)

	return response --[[@as Crust.Pi.Response]]
end

--- Run an async task from a synchronous test body and re-raise its errors.
---@param fn async fun()
local function run(fn)
	async.run(fn):wait(TIMEOUT_MS)
end

describe("rpc against a live pi instance", function()
	local pi ---@type Crust.Pi

	before_each(function()
		pi = Pi.new({ args = { "--no-session" } })
		assert.True(pi:connect())
	end)

	after_each(function()
		pi:close()
	end)

	it("answers get_state with a parsed state payload", function()
		if vim.fn.executable("pi") == 0 then
			return
		end

		run(function()
			local res = request(pi, Rpc.get_state())

			assert.are.equal("response", res.type)
			assert.are.equal("get_state", res.command)
			assert.True(res.success)
			assert.is_nil(res.error)

			local state = res.data --[[@as Crust.Pi.Data.State]]
			assert.is_table(state)
			assert.is_string(state.thinkingLevel)
			assert.is_boolean(state.isStreaming)
			assert.is_boolean(state.isCompacting)
			assert.is_boolean(state.autoCompactionEnabled)
			assert.is_number(state.messageCount)
			assert.is_number(state.pendingMessageCount)
			assert.is_string(state.sessionId)
			assert.is_true(state.steeringMode == "all" or state.steeringMode == "one-at-a-time")
			assert.is_true(state.followUpMode == "all" or state.followUpMode == "one-at-a-time")

			if state.model ~= nil then
				assert.is_string(state.model.id)
				assert.is_string(state.model.provider)
				assert.is_number(state.model.contextWindow)
			end
		end)
	end)

	it("correlates the response with the request id", function()
		if vim.fn.executable("pi") == 0 then
			return
		end

		run(function()
			local cmd = Rpc.get_state()
			local res = request(pi, cmd)
			assert.are.equal(cmd.id, res.id)
		end)
	end)
end)

describe("rpc model selection", function()
	it("starts the process with the model given in opts", function()
		if vim.fn.executable("pi") == 0 then
			return
		end

		local pi = Pi.new({ args = { "--no-session" }, model = TEST_MODEL })
		assert.True(pi:connect())

		local ok, err = pcall(function()
			run(function()
				local res = request(pi, Rpc.get_state())
				assert.True(res.success)

				local state = res.data --[[@as Crust.Pi.Data.State]]
				assert.is_table(state.model)
				assert.are.equal(TEST_MODEL_PROVIDER, state.model.provider)
				assert.are.equal(TEST_MODEL_ID, state.model.id)
			end)
		end)

		pi:close()
		assert(ok, err)
	end)

	it("switches the model at runtime with set_model", function()
		if vim.fn.executable("pi") == 0 then
			return
		end

		local pi = Pi.new({ args = { "--no-session" } })
		assert.True(pi:connect())

		local ok, err = pcall(function()
			run(function()
				local res = request(pi, Rpc.set_model(TEST_MODEL_PROVIDER, TEST_MODEL_ID))
				assert.are.equal("set_model", res.command)
				assert.True(res.success)

				local state = request(pi, Rpc.get_state()).data --[[@as Crust.Pi.Data.State]]
				assert.are.equal(TEST_MODEL_PROVIDER, state.model.provider)
				assert.are.equal(TEST_MODEL_ID, state.model.id)
			end)
		end)

		pi:close()
		assert(ok, err)
	end)
end)