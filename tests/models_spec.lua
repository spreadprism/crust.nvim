-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Models = require("crust.models")
local Picker = require("crust.models.picker")

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
	model("anthropic", "claude-sonnet-4-6", "Claude Sonnet 4.6"),
	model("openai", "gpt-5.6", "GPT-5.6"),
}

describe("models.resolve", function()
	it("takes the provider/id form of pi's --model flag", function()
		local found = Models.resolve(MODELS, "anthropic/claude-sonnet-4-6")
		assert.are.equal("claude-sonnet-4-6", found.id)
	end)

	it("takes a bare model id", function()
		local found = Models.resolve(MODELS, "gpt-5.6")
		assert.are.equal("openai", found.provider)
	end)

	it("takes the display name, spacing and case aside", function()
		local found = Models.resolve(MODELS, "claude haiku 4.5")
		assert.are.equal("claude-haiku-4-5", found.id)
	end)

	it("takes an unambiguous fragment", function()
		local found = Models.resolve(MODELS, "haiku")
		assert.are.equal("claude-haiku-4-5", found.id)
	end)

	it("reports the candidates of an ambiguous fragment", function()
		local found, err = Models.resolve(MODELS, "claude")
		assert.is_nil(found)
		assert.is_truthy(err:find("matches 2 models", 1, true))
		assert.is_truthy(err:find("anthropic/claude-haiku-4-5", 1, true))
	end)

	it("reports an unknown model", function()
		local found, err = Models.resolve(MODELS, "llama")
		assert.is_nil(found)
		assert.are.equal("unknown model 'llama'", err)
	end)

	it("refuses an empty query", function()
		local found, err = Models.resolve(MODELS, "  ")
		assert.is_nil(found)
		assert.are.equal("no model given", err)
	end)
end)

describe("models.label", function()
	it("puts the provider/id next to the display name", function()
		assert.are.equal("Claude Haiku 4.5  anthropic/claude-haiku-4-5", Models.label(MODELS[1]))
	end)

	it("drops the name when it is the id", function()
		assert.are.equal("anthropic/x", Models.label(model("anthropic", "x")))
	end)
end)

describe("models.fetch", function()
	it("answers empty when the process is down", function()
		local models, err = nil, nil
		Models.fetch(nil, function(list, message)
			models, err = list, message
		end)
		assert.are.same({}, models)
		assert.are.equal("pi process is not running", err)
	end)

	it("unwraps the get_available_models payload", function()
		local sent
		local pi = {
			is_running = function()
				return true
			end,
			send = function(_, command, callback)
				sent = command.type
				callback({ type = "response", command = "get_available_models", success = true, data = { models = MODELS } })
				return "id"
			end,
		}

		local models
		Models.fetch(pi, function(list)
			models = list
		end)

		assert.are.equal("get_available_models", sent)
		assert.are.equal(3, #models)
	end)

	it("passes pi's error through", function()
		local pi = {
			is_running = function()
				return true
			end,
			send = function(_, _, callback)
				callback({ type = "response", command = "get_available_models", success = false, error = "boom" })
				return "id"
			end,
		}

		local err
		Models.fetch(pi, function(_, message)
			err = message
		end)
		assert.are.equal("boom", err)
	end)
end)

describe("models.picker", function()
	it("answers with nil when there is nothing to pick", function()
		local called = false
		Picker.select({}, {}, function(chosen)
			called = true
			assert.is_nil(chosen)
		end)
		assert.is_true(called)
	end)

	it("falls back to vim.ui.select without snacks", function()
		if Picker.has_snacks() then
			return
		end

		local items, formatted
		local select = vim.ui.select
		vim.ui.select = function(list, opts, on_choice)
			items = list
			formatted = opts.format_item(list[1])
			on_choice(list[2])
		end

		local chosen
		Picker.select(MODELS, {}, function(value)
			chosen = value
		end)
		vim.ui.select = select

		assert.are.equal(3, #items)
		assert.are.equal("Claude Haiku 4.5  anthropic/claude-haiku-4-5", formatted)
		assert.are.equal("claude-sonnet-4-6", chosen.id)
	end)
end)

describe("api model", function()
	local crust

	before_each(function()
		package.loaded["crust"] = nil
		crust = require("crust")
	end)

	after_each(function()
		package.loaded["crust"] = nil
	end)

	it("opens the chat and forwards the query", function()
		local chat = crust.chat()
		local opened, query = false, nil
		chat.open = function()
			opened = true
		end
		chat.model = function(_, value, callback)
			query = value
			callback(true)
		end

		local ok
		crust.model("haiku", function(success)
			ok = success
		end)

		assert.is_true(opened)
		assert.are.equal("haiku", query)
		assert.is_true(ok)
	end)
end)
