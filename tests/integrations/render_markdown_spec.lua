-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local RenderMarkdown = require("crust.integrations.render_markdown")
local Output = require("crust.ui.chat.output")
local config = require("crust.config")

--- Install a fake render-markdown.nvim and collect its render calls.
---@return table[] calls
local function fake_plugin()
	local calls = {}
	package.loaded["render-markdown.api"] = {
		render = function(ctx)
			calls[#calls + 1] = ctx
		end,
	}
	return calls
end

describe("integrations.render_markdown", function()
	before_each(function()
		config.options = {}
		config.config = nil
		package.loaded["render-markdown.api"] = nil
	end)

	after_each(function()
		package.loaded["render-markdown.api"] = nil
	end)

	it("reports the plugin as missing when it is not installed", function()
		assert.is_nil(RenderMarkdown.api())
		assert.is_false(RenderMarkdown.available())
	end)

	it("detects the plugin when it is installed", function()
		fake_plugin()
		assert.is_true(RenderMarkdown.available())
	end)

	it("does nothing without the plugin", function()
		local out = Output.new()
		out:open(40)
		assert.has_no.errors(function()
			out:append("# hello")
		end)
		out:close()
	end)

	it("renders the buffer for every window showing it", function()
		local calls = fake_plugin()
		local out = Output.new()
		out:open(40)

		RenderMarkdown.render_now(out:buf(), Output.FILETYPE)

		assert.are.equal(1, #calls)
		assert.are.equal(out:buf(), calls[1].buf)
		assert.are.same(vim.fn.win_findbuf(out:buf()), calls[1].win)
		assert.are.same({ Output.FILETYPE }, calls[1].config.file_types)
		out:close()
	end)

	it("skips rendering when no window shows the buffer", function()
		local calls = fake_plugin()
		local out = Output.new()

		RenderMarkdown.render_now(out:buf(), Output.FILETYPE)

		assert.are.equal(0, #calls)
	end)

	it("accepts a function for enabled", function()
		assert.is_true(config.enabled(function()
			return true
		end))
		assert.is_false(config.enabled(function()
			return false
		end))
		assert.is_true(config.enabled(true))
		assert.is_false(config.enabled(false))
	end)

	it("default enabled follows whether render-markdown is installed", function()
		package.loaded["render-markdown"] = nil
		assert.is_false(config.enabled(config.defaults.render_markdown.enabled))

		package.loaded["render-markdown"] = {}
		assert.is_true(config.enabled(config.defaults.render_markdown.enabled))
		package.loaded["render-markdown"] = nil
	end)

	it("skips rendering when the enabled function returns false", function()
		local calls = fake_plugin()
		config.options = {
			render_markdown = {
				enabled = function()
					return false
				end,
				debounce_ms = 10,
			},
		}
		config.config = nil

		local out = Output.new()
		out:open(40)
		out:append("# hello")
		vim.wait(100)

		assert.are.equal(0, #calls)
		out:close()
	end)

	it("debounces streamed appends into a single render", function()
		local calls = fake_plugin()
		config.options = { render_markdown = { enabled = true, debounce_ms = 10 } }
		config.config = nil

		local out = Output.new()
		out:open(40)
		for _ = 1, 20 do
			out:append("delta ")
		end

		assert.are.equal(0, #calls)
		vim.wait(200, function()
			return #calls > 0
		end)
		assert.are.equal(1, #calls)
		out:close()
	end)

	it("can be disabled in the config", function()
		local calls = fake_plugin()
		config.options = { render_markdown = { enabled = false, debounce_ms = 10 } }
		config.config = nil
		config.config = nil

		local out = Output.new()
		out:open(40)
		out:append("# hello")
		vim.wait(100)

		assert.are.equal(0, #calls)
		out:close()
	end)

	it("stops the timer when the output closes", function()
		local calls = fake_plugin()
		config.options = { render_markdown = { enabled = true, debounce_ms = 10 } }
		config.config = nil

		local out = Output.new()
		out:open(40)
		out:append("# hello")
		out:close()
		vim.wait(100)

		assert.are.equal(0, #calls)
	end)
end)