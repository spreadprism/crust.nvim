-- Specs poke at private fields and build events by hand.
---@diagnostic disable: invisible, missing-fields, param-type-mismatch

local Ask = require("crust.ui.ask")
local config = require("crust.config")

describe("ui.ask", function()
	---@type Crust.Pi.Command[]
	local sent
	---@type Crust.Pi
	local pi

	--- Let the scheduled callbacks of `close` run.
	local function flush()
		vim.wait(20, function()
			return false
		end)
	end

	---@param fields table
	---@return Crust.Pi.Event
	local function request(fields)
		return vim.tbl_extend("force", { type = "extension_ui_request", id = "uuid-1" }, fields)
	end

	before_each(function()
		config.options = {}
		config.config = nil
		sent = {}
		pi = {
			send = function(_, command)
				sent[#sent + 1] = command
			end,
		}
	end)

	after_each(function()
		Ask.reset()
		flush()
	end)

	it("ignores events that are not ui requests", function()
		assert.is_false(Ask.handle(pi, { type = "agent_start" }))
		assert.is_nil(Ask.current())
	end)

	describe("select", function()
		local event = request({
			method = "select",
			title = "Allow bash?",
			message = "rm -rf /tmp/x",
			options = { "Yes", "Yes, for this session", "No", "No, provide reason" },
		})

		it("draws the question and every option", function()
			Ask.handle(pi, event)

			local dialog = Ask.current()
			assert.is_not_nil(dialog)
			local lines = vim.api.nvim_buf_get_lines(dialog.buf, 0, -1, false)
			assert.are.same({ "Allow bash?", "rm -rf /tmp/x" }, { lines[1], lines[2] })
			assert.are.equal(" 1  Yes", lines[dialog.first])
			assert.are.equal(" 4  No, provide reason", lines[dialog.first + 3])
			assert.is_true(vim.api.nvim_win_is_valid(dialog.win))
		end)

		it("answers with the chosen option and closes", function()
			Ask.handle(pi, event)
			assert.is_true(Ask.choose(2))

			assert.are.equal(1, #sent)
			assert.are.same({
				type = "extension_ui_response",
				id = "uuid-1",
				value = "Yes, for this session",
			}, {
				type = sent[1].type,
				id = sent[1].id,
				value = sent[1].value,
			})
			assert.is_nil(Ask.current())
		end)

		it("ignores an option that does not exist", function()
			Ask.handle(pi, event)
			assert.is_false(Ask.choose(9))
			assert.are.equal(0, #sent)
			assert.is_not_nil(Ask.current())
		end)

		it("answers cancelled when the dialog is dismissed", function()
			Ask.handle(pi, event)
			assert.is_true(Ask.cancel())

			assert.are.equal(1, #sent)
			assert.is_true(sent[1].cancelled)
			assert.is_nil(sent[1].value)
		end)

		it("answers once, whatever happens next", function()
			Ask.handle(pi, event)
			Ask.choose(1)
			Ask.cancel()
			assert.are.equal(1, #sent)
		end)
	end)

	describe("confirm", function()
		local event = request({ method = "confirm", title = "Clear session?", message = "All messages are lost." })

		it("answers with a boolean", function()
			Ask.handle(pi, event)
			Ask.choose(1)
			assert.is_true(sent[1].confirmed)

			sent = {}
			Ask.handle(pi, event)
			Ask.choose(2)
			assert.is_false(sent[1].confirmed)
		end)
	end)

	describe("input", function()
		local event = request({ method = "input", title = "Why?", placeholder = "reason" })

		it("keeps the question out of the editable buffer", function()
			Ask.handle(pi, event)
			local dialog = Ask.current()
			assert.are.same({ "" }, vim.api.nvim_buf_get_lines(dialog.buf, 0, -1, false))
			assert.is_true(vim.bo[dialog.buf].modifiable)
		end)

		it("answers with what was typed", function()
			Ask.handle(pi, event)
			vim.api.nvim_buf_set_lines(Ask.current().buf, 0, -1, false, { "not this time" })
			assert.is_true(Ask.submit())

			assert.are.equal("not this time", sent[1].value)
			assert.is_nil(Ask.current())
		end)

		it("prefills an editor dialog", function()
			Ask.handle(pi, request({ method = "editor", title = "Edit", prefill = "one\ntwo" }))
			assert.are.same({ "one", "two" }, vim.api.nvim_buf_get_lines(Ask.current().buf, 0, -1, false))
			Ask.submit()
			assert.are.equal("one\ntwo", sent[1].value)
		end)
	end)

	describe("queue", function()
		it("shows one dialog at a time and drains the rest", function()
			Ask.handle(pi, request({ id = "a", method = "confirm", title = "first" }))
			Ask.handle(pi, request({ id = "b", method = "confirm", title = "second" }))

			assert.are.equal(1, Ask.pending())
			assert.are.equal("a", Ask.current().request.event.id)

			Ask.choose(1)
			flush()

			assert.are.equal(0, Ask.pending())
			assert.are.equal("b", Ask.current().request.event.id)
		end)

		it("cancels everything a dead process left behind", function()
			Ask.handle(pi, request({ id = "a", method = "confirm", title = "first" }))
			Ask.handle(pi, request({ id = "b", method = "confirm", title = "second" }))

			Ask.reset(pi)

			assert.are.equal(0, Ask.pending())
			assert.is_nil(Ask.current())
			assert.are.equal(2, #sent)
			assert.is_true(sent[1].cancelled)
			assert.is_true(sent[2].cancelled)
		end)
	end)

	describe("fire-and-forget methods", function()
		it("never answers them", function()
			local notified = {}
			local notify = vim.notify
			vim.notify = function(message, level)
				notified[#notified + 1] = { message = message, level = level }
			end

			assert.is_true(Ask.handle(pi, request({ method = "notify", message = "blocked", notifyType = "warning" })))
			assert.is_true(Ask.handle(pi, request({ method = "setStatus", statusKey = "x", statusText = "y" })))

			vim.notify = notify

			assert.are.equal(0, #sent)
			assert.is_nil(Ask.current())
			assert.are.equal(1, #notified)
			assert.are.equal("blocked", notified[1].message)
			assert.are.equal(vim.log.levels.WARN, notified[1].level)
		end)
	end)

	describe("disabled", function()
		it("refuses dialogs instead of hanging the turn", function()
			config.options = { ask = { enabled = false } }
			config.config = nil

			assert.is_true(Ask.handle(pi, request({ method = "select", title = "Allow?", options = { "Yes", "No" } })))

			assert.is_nil(Ask.current())
			assert.are.equal(1, #sent)
			assert.is_true(sent[1].cancelled)
		end)
	end)
end)
