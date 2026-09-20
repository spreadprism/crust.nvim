-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Chat = require("crust.ui.chat")
local Picker = require("crust.models.picker")
local config = require("crust.config")

---@param provider string
---@param id string
---@param name? string
---@return Crust.Pi.Model
local function model(provider, id, name)
	return {
		id = id,
		name = name or id,
		provider = provider,
		api = "anthropic-messages",
		baseUrl = "https://example.invalid",
		reasoning = true,
		input = { "text" },
		contextWindow = 200000,
		maxTokens = 16384,
		cost = { input = 1, output = 2, cacheRead = 0, cacheWrite = 0 },
	}
end

local MODELS = {
	model("anthropic", "claude-haiku-4-5", "Claude Haiku 4.5"),
	model("openai", "gpt-5.6", "GPT-5.6"),
}

describe("ui.chat model", function()
	---@type Crust.Chat
	local chat
	---@type Crust.Pi.Command[]
	local sent
	---@type table<string, fun(event: Crust.Pi.Response)>
	local callbacks

	before_each(function()
		config.options = {}
		config.config = nil
		chat = Chat.new()
		sent = {}
		callbacks = {}

		chat._pi = {
			connect = function()
				return true
			end,
			is_running = function()
				return true
			end,
			send = function(_, command, callback)
				sent[#sent + 1] = command
				if callback then
					callbacks[command.type] = callback
				end
				return "id-" .. #sent
			end,
			close = function() end,
		}
	end)

	---@param command_type string
	---@param response table
	local function answer(command_type, response)
		local callback = assert(callbacks[command_type], "no pending " .. command_type)
		callbacks[command_type] = nil
		callback(response)
	end

	local function answer_models()
		answer("get_available_models", { success = true, data = { models = MODELS } })
	end

	it("resolves the query against pi's models and switches", function()
		local ok
		chat:model("haiku", function(success)
			ok = success
		end)

		assert.are.equal("get_available_models", sent[1].type)
		answer_models()

		assert.are.equal("set_model", sent[2].type)
		assert.are.equal("anthropic", sent[2].provider)
		assert.are.equal("claude-haiku-4-5", sent[2].modelId)

		answer("set_model", { success = true, data = MODELS[1] })
		assert.is_true(ok)
		-- The bar is refreshed from the state, not from the model alone.
		assert.is_truthy(callbacks["get_state"])
	end)

	it("reports an unknown model without sending set_model", function()
		local ok, err
		chat:model("llama", function(success, message)
			ok, err = success, message
		end)
		answer_models()

		assert.is_false(ok)
		assert.are.equal("unknown model 'llama'", err)
		assert.is_nil(callbacks["set_model"])
	end)

	it("reports pi's own failure to switch", function()
		local ok, err
		chat:model("gpt-5.6", function(success, message)
			ok, err = success, message
		end)
		answer_models()
		answer("set_model", { success = false, error = "no api key" })

		assert.is_false(ok)
		assert.are.equal("no api key", err)
	end)

	it("picks when no model is given, marking the live one", function()
		chat:bar():update_state({ model = MODELS[2], thinkingLevel = "off" })

		local offered, current
		local select = Picker.select
		Picker.select = function(models, opts, on_choice)
			offered, current = models, opts.current
			on_choice(models[1])
		end

		local ok
		chat:model(nil, function(success)
			ok = success
		end)
		answer_models()
		Picker.select = select

		assert.are.equal(2, #offered)
		assert.are.equal("openai/gpt-5.6", current)
		assert.are.equal("claude-haiku-4-5", sent[2].modelId)

		answer("set_model", { success = true, data = MODELS[1] })
		assert.is_true(ok)
	end)

	it("reports a cancelled pick without switching", function()
		local select = Picker.select
		Picker.select = function(_, _, on_choice)
			on_choice(nil)
		end

		local ok, err
		chat:model(nil, function(success, message)
			ok, err = success, message
		end)
		answer_models()
		Picker.select = select

		assert.is_false(ok)
		assert.are.equal("cancelled", err)
		assert.is_nil(callbacks["set_model"])
	end)

	it("errors when pi has no models to offer", function()
		local ok, err
		chat:model(nil, function(success, message)
			ok, err = success, message
		end)
		answer("get_available_models", { success = true, data = { models = {} } })

		assert.is_false(ok)
		assert.are.equal("pi reported no available models", err)
	end)
end)
