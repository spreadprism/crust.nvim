-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Highlights = require("crust.ui.highlights")
local InputBar = require("crust.ui.chat.inputbar")
local config = require("crust.config")

describe("ui.chat.inputbar", function()
	---@type Crust.Chat.InputBar
	local bar
	---@type integer
	local buf
	---@type integer?
	local win

	---@param opts? table input_bar options
	local function configure(opts)
		config.options = opts and { input_bar = opts } or {}
		config.config = nil
	end

	--- A bar over a scratch buffer in a window of `width` columns.
	---@param width? integer
	local function open(width)
		buf = vim.api.nvim_create_buf(false, true)
		win = vim.api.nvim_open_win(buf, false, {
			relative = "editor",
			width = width or 60,
			height = 5,
			row = 1,
			col = 1,
			style = "minimal",
		})
		bar = InputBar.new(buf, function()
			return win and vim.api.nvim_win_is_valid(win) and win or nil
		end)
	end

	--- The bar as text, sides separated by their padding.
	---@return string
	local function text()
		local parts = {}
		for _, chunk in ipairs(bar:line(60)) do
			parts[#parts + 1] = chunk[1]
		end
		return table.concat(parts)
	end

	--- Virtual line the extmark draws, nil when the bar is not on the buffer.
	---@return table[]?
	local function drawn()
		local marks = vim.api.nvim_buf_get_extmarks(buf, InputBar.ns, 0, -1, { details = true })
		local lines = marks[1] and marks[1][4].virt_lines
		return lines and lines[#lines] or nil
	end

	---@param cost number
	---@return Crust.Pi.Usage
	local function usage(cost)
		return { input = 1000, output = 200, cacheRead = 50, cacheWrite = 10, cost = { total = cost } }
	end

	before_each(function()
		configure()
		open()
	end)

	after_each(function()
		bar:close()
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		win = nil
		configure()
	end)

	describe("defaults", function()
		it("shows nothing before pi has answered", function()
			assert.are.same({}, bar:line(60))
			assert.is_nil(drawn())
		end)

		it("puts the cost on the left and the model on the right", function()
			bar:update_state({ model = { id = "claude-opus-4-6" } })
			bar:add_usage(usage(1.5))

			local chunks = bar:line(60)
			assert.is_truthy(chunks[1][1]:find("$1.500", 1, true))
			assert.is_truthy(chunks[#chunks][1]:find("claude-opus-4-6", 1, true))
			-- Left, padding, right: the two sides are pushed apart.
			assert.are.equal(3, #chunks)
			assert.is_truthy(chunks[2][1]:match("^ +$"))
		end)

		it("draws everything in CrustInputBar", function()
			bar:update_state({ model = { id = "gpt-5" } })
			bar:add_usage(usage(0.5))

			for _, chunk in ipairs(bar:line(60)) do
				assert.are.equal(Highlights.INPUT_BAR, chunk[2])
			end
		end)

		it("hides the cost until the session has cost something", function()
			bar:update_state({ model = { id = "gpt-5" } })
			assert.is_falsy(text():find("$", 1, true))

			bar:add_usage(usage(0.002))
			assert.is_truthy(text():find("$0.002", 1, true))
		end)
	end)

	describe("state", function()
		it("accumulates the cost and the tokens over the session", function()
			configure({ layout = { left = { "cost", "tokens" }, right = {} } })

			bar:add_usage(usage(0.5))
			bar:add_usage(usage(0.25))

			assert.are.equal(0.75, bar:state().cost)
			assert.are.equal(2000, bar:state().input)
			assert.is_truthy(text():find("↑2.0k", 1, true))
		end)

		it("replaces the context estimate instead of adding it up", function()
			bar:add_usage(usage(0.5))
			bar:add_usage(usage(0.5))
			assert.are.equal(1260, bar:state().context_tokens)
		end)

		it("ignores a message that never reached the model", function()
			bar:add_usage({ input = 0, output = 0, cost = { total = 0.5 } })
			assert.are.equal(0, bar:state().cost)
		end)

		it("forgets the totals on reset but keeps the model", function()
			bar:update_state({ model = { id = "gpt-5" } })
			bar:add_usage(usage(0.5))

			bar:reset()
			assert.are.equal(0, bar:state().cost)
			assert.is_nil(bar:state().context_tokens)
			assert.are.equal("gpt-5", bar:state().model_id)
		end)
	end)

	describe("components", function()
		it("shows how full the context window is", function()
			configure({ layout = { left = { "context" }, right = {} } })
			bar:update_state({ model = { id = "gpt-5", contextWindow = 200000 } })

			assert.is_truthy(text():find("-/200k", 1, true))
			bar:add_usage({ input = 100000, output = 0 })
			assert.is_truthy(text():find("50.0%/200k", 1, true))
		end)

		it("warns and then errors as the context fills up", function()
			configure({
				layout = { left = { "context" }, right = {} },
				components = { context = { icon = "", warn = 70, error = 90 } },
			})
			bar:update_state({ model = { id = "gpt-5", contextWindow = 1000 } })

			bar:add_usage({ input = 750 })
			assert.are.equal(Highlights.INPUT_BAR_WARNING, bar:line(60)[1][2])

			bar:add_usage({ input = 950 })
			assert.are.equal(Highlights.INPUT_BAR_ERROR, bar:line(60)[1][2])
		end)

		it("only shows the thinking level for a model that reasons", function()
			configure({ layout = { left = { "thinking" }, right = {} } })

			bar:update_state({ model = { id = "gpt-5", reasoning = false }, thinkingLevel = "high" })
			assert.are.equal("", text())

			bar:update_state({ model = { id = "gpt-5", reasoning = true }, thinkingLevel = "high" })
			assert.is_truthy(text():find("high", 1, true))

			bar:update_state({ model = { id = "gpt-5", reasoning = true }, thinkingLevel = "off" })
			assert.is_truthy(text():find("thinking off", 1, true))
		end)

		it("reports the cache reads and writes", function()
			configure({ layout = { left = { "cache" }, right = {} } })
			bar:add_usage({ input = 10, cacheRead = 7200000, cacheWrite = 416000 })

			assert.is_truthy(text():find("R7.2M", 1, true))
			assert.is_truthy(text():find("W416k", 1, true))
		end)
	end)

	describe("icons", function()
		it("draws the configured icon before the component", function()
			configure({ layout = { left = { "model" }, right = {} }, components = { model = { icon = "M" } } })
			bar:update_state({ model = { id = "gpt-5" } })

			assert.are.equal("M gpt-5", text())
		end)

		it("drops the default icon when the component table gives none", function()
			-- `icon = nil` is the spelling everybody reaches for, and in Lua it
			-- is an empty table: the merge must not bring the default back.
			configure({ layout = { left = { "model" }, right = {} }, components = { model = { icon = nil } } })
			bar:update_state({ model = { id = "gpt-5" } })

			assert.are.equal("gpt-5", text())
		end)

		it("drops it for false and for an empty string too", function()
			for _, value in ipairs({ false, "" }) do
				configure({
					layout = { left = { "model" }, right = {} },
					components = { model = { icon = value } },
				})
				bar:update_state({ model = { id = "gpt-5" } })

				assert.are.equal("gpt-5", text())
			end
		end)

		it("keeps the other options of the component it unsets the icon of", function()
			configure({
				layout = { left = { "context" }, right = {} },
				components = { context = { icon = nil } },
			})
			bar:update_state({ model = { id = "gpt-5", contextWindow = 1000 } })
			bar:add_usage({ input = 950 })

			-- The default warn/error levels survive, only the icon is gone.
			assert.are.equal("95.0%/1.0k", text())
			assert.are.equal(Highlights.INPUT_BAR_ERROR, bar:line(60)[1][2])
		end)

		it("leaves the components the user did not mention alone", function()
			configure({
				layout = { left = { "cost" }, right = { "model" } },
				components = { cost = { icon = "$$" } },
			})
			bar:update_state({ model = { id = "gpt-5" } })
			bar:add_usage(usage(1.5))

			assert.is_truthy(text():find("$$ $1.500", 1, true))
			assert.is_truthy(text():find("󰚩 gpt-5", 1, true))
		end)
	end)

	describe("layout", function()
		it("takes a whole list from the user, not just its first entries", function()
			configure({ layout = { left = { "model" }, right = { "cost" } } })
			bar:update_state({ model = { id = "gpt-5" } })
			bar:add_usage(usage(0.5))

			local chunks = bar:line(60)
			assert.is_truthy(chunks[1][1]:find("gpt-5", 1, true))
			assert.is_truthy(chunks[#chunks][1]:find("$0.500", 1, true))
		end)

		it("draws a separator between two visible components only", function()
			configure({ layout = { left = { "cost", " · ", "model" }, right = {} } })
			bar:update_state({ model = { id = "gpt-5" } })

			-- No cost yet, so the separator would dangle: it is dropped.
			assert.is_falsy(text():find("·", 1, true))

			bar:add_usage(usage(0.5))
			assert.is_truthy(text():find("$0.500 · ", 1, true))
		end)

		it("takes a function as a component", function()
			configure({
				layout = {
					left = {
						function(state)
							return "spent " .. string.format("%.2f", state.cost), Highlights.INPUT_BAR_ERROR
						end,
					},
					right = {},
				},
			})
			bar:add_usage(usage(2))

			assert.are.same({ { "spent 2.00", Highlights.INPUT_BAR_ERROR } }, bar:line(60))
		end)

		it("keeps the left side when the right one does not fit", function()
			configure({ layout = { left = { "cost" }, right = { "model" } } })
			bar:update_state({ model = { id = "a-very-long-model-identifier" } })
			bar:add_usage(usage(0.5))

			local width = 0
			for _, chunk in ipairs(bar:line(20)) do
				width = width + vim.fn.strdisplaywidth(chunk[1])
			end
			assert.is_true(width <= 20)
			assert.is_truthy(bar:line(20)[1][1]:find("$0.500", 1, true))
		end)
	end)

	describe("rendering", function()
		it("pins the bar to the last row of the window", function()
			bar:update_state({ model = { id = "gpt-5" } })

			local lines = vim.api.nvim_buf_get_extmarks(buf, InputBar.ns, 0, -1, { details = true })[1][4].virt_lines
			-- An empty prompt is one line, so three blanks and the bar put it
			-- on the last of the five window rows.
			assert.are.equal(4, #lines)
			assert.are.equal(4, bar:rows())
			assert.is_truthy(lines[#lines][#lines[#lines]][1]:find("gpt-5", 1, true))
		end)

		it("redraws when the prompt grows", function()
			bar:update_state({ model = { id = "gpt-5" } })
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
			bar:render()

			-- Two typed lines, so one blank less above the bar.
			assert.are.equal(3, bar:rows())
			assert.is_truthy(drawn())
		end)

		it("can be turned off", function()
			configure({ enabled = false })
			bar:update_state({ model = { id = "gpt-5" } })

			assert.is_nil(drawn())
			assert.are.equal(0, bar:rows())
		end)

		it("takes itself off the buffer when the window closes", function()
			bar:update_state({ model = { id = "gpt-5" } })
			assert.is_truthy(drawn())

			vim.api.nvim_win_close(win, true)
			win = nil
			bar:render()

			assert.is_nil(drawn())
		end)
	end)
end)
