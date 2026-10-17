-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Render = require("crust.usage.render")
local Usage = require("crust.usage")
local Ui = require("crust.ui.usage")

--- A response like the one the oauth endpoint sends.
---@param now integer
---@return Crust.Usage.Data
local function response(now)
	---@param secs integer
	local function at(secs)
		return os.date("!%Y-%m-%dT%H:%M:%S+00:00", now + secs)
	end

	return {
		limits = {
			{ kind = "session", percent = 21.4, resets_at = at(3 * 3600 + 12 * 60) },
			{ kind = "weekly_all", percent = 54, resets_at = at(2 * 86400 + 4 * 3600) },
			{
				kind = "weekly_scoped",
				percent = 83,
				severity = "high",
				resets_at = at(86400),
				scope = { model = { display_name = "Opus" } },
			},
		},
		seven_day_breakdown = {
			rows = { { display_name = "Sonnet", percent = 40 }, { display_name = "Haiku", percent = 0 } },
		},
	}
end

describe("usage", function()
	local now = 1700000000

	after_each(function()
		Usage.clear()
	end)

	describe("render.rows", function()
		it("labels and rounds every limit", function()
			local rows = Render.rows(response(now), now)

			assert.are.equal(3, #rows)
			assert.are.same({ "5-hour session", "Weekly (all models)", "Weekly (Opus)" }, {
				rows[1].label,
				rows[2].label,
				rows[3].label,
			})
			assert.are.equal(21, rows[1].percent)
			assert.are.equal("high", rows[3].tag)
			assert.is_nil(rows[1].tag)
		end)

		it("words the reset time like the skill does", function()
			local rows = Render.rows(response(now), now)

			assert.are.equal("(resets in 3h 12m)", rows[1].detail)
			assert.are.equal("(resets in 2d 4h)", rows[2].detail)
		end)

		it("handles a missing or past reset time", function()
			assert.are.equal("", Render.resets_in(nil, now))
			assert.are.equal("(resets now)", Render.resets_in(now - 5, now))
			assert.are.equal("(resets in <1m)", Render.resets_in(now + 30, now))
			assert.are.equal("(resets in 42m)", Render.resets_in(now + 42 * 60, now))
		end)

		it("reads extra usage as money", function()
			local rows = Render.rows({
				extra_usage = {
					is_enabled = true,
					used_credits = 21548,
					monthly_limit = 50000,
					currency = "USD",
					decimal_places = 2,
					spend_limit_reached = false,
				},
			}, now)

			assert.are.equal("Extra usage", rows[1].label)
			assert.are.equal(43, rows[1].percent)
			assert.are.equal("(215.48 / 500.00 USD)", rows[1].detail)
		end)

		it("ignores extra usage that is turned off", function()
			assert.are.same({}, Render.rows({ extra_usage = { is_enabled = false } }, now))
		end)

		it("survives the json nulls the endpoint sends as vim.NIL", function()
			local data = {
				limits = {
					{
						kind = "session",
						percent = vim.NIL,
						resets_at = vim.NIL,
						severity = vim.NIL,
					},
					{ kind = "weekly_scoped", percent = 10, scope = { model = { display_name = vim.NIL } } },
				},
				seven_day_breakdown = { rows = { { display_name = vim.NIL, percent = vim.NIL } } },
				extra_usage = {
					is_enabled = true,
					used_credits = 100,
					monthly_limit = vim.NIL,
					currency = vim.NIL,
					decimal_places = vim.NIL,
				},
			}

			local rows = Render.rows(data, now)
			assert.are.equal(0, rows[1].percent)
			assert.are.equal("", rows[1].detail)
			assert.is_nil(rows[1].tag)
			assert.are.equal("Weekly (model)", rows[2].label)
			assert.are.equal("(1.00  used, no limit)", rows[3].detail)
			assert.is_nil(Render.breakdown(data))

			-- The whole block has to render, that is what the float asks for.
			assert.has_no.errors(function()
				Render.lines(data, { now = now })
			end)
		end)
	end)

	describe("render.lines", function()
		it("draws a title, a bar per limit and the breakdown", function()
			local lines = Render.lines(response(now), { now = now })

			assert.are.equal("Claude plan usage", lines[1])
			assert.is_truthy(lines[2]:find("5-hour session", 1, true))
			assert.is_truthy(lines[2]:find("21%", 1, true))
			assert.is_truthy(lines[2]:find("(resets in 3h 12m)", 1, true))
			assert.is_truthy(lines[5]:find("Weekly breakdown: Sonnet 40%", 1, true))
		end)

		it("fills the bar in fives and pads the labels to one column", function()
			local lines = Render.lines(response(now), { now = now })
			local filled = select(1, Render.bar(21))

			assert.are.equal(4, vim.fn.strchars(filled))
			local column = lines[2]:find("█", 1, true)
			assert.are.equal(column, lines[3]:find("█", 1, true))
		end)

		it("colours a limit by how full it is", function()
			local Highlights = require("crust.ui.highlights")

			assert.are.equal(Highlights.USAGE_OK, Render.level(21))
			assert.are.equal(Highlights.USAGE_WARNING, Render.level(54))
			assert.are.equal(Highlights.USAGE_ERROR, Render.level(83))
		end)

		it("says so when there is nothing to show", function()
			local lines = Render.lines({}, { now = now })
			assert.are.same({ "Claude plan usage", "  No limits reported." }, lines)
		end)
	end)

	describe("render.summary", function()
		it("picks the session and the weekly limit", function()
			local summary = Render.summary(response(now), now)

			assert.are.equal(21, summary.session.percent)
			assert.are.equal(54, summary.weekly.percent)
		end)

		it("falls back to a scoped weekly limit", function()
			local summary = Render.summary({
				limits = { { kind = "weekly_scoped", percent = 12, scope = { model = { display_name = "Opus" } } } },
			}, now)

			assert.is_nil(summary.session)
			assert.are.equal(12, summary.weekly.percent)
		end)
	end)

	describe("cache", function()
		it("serves an injected answer without asking the network", function()
			Usage.inject(response(now))

			local seen
			Usage.get(function(data)
				seen = data
			end)

			assert.is_truthy(seen)
			assert.is_true(Usage.is_fresh())
			assert.is_false(Usage.is_loading())
		end)

		it("goes stale after the ttl", function()
			Usage.inject(response(now))
			assert.is_true(Usage.is_fresh())

			-- Reach into the clock the module uses, rather than waiting a minute.
			local real = os.time
			os.time = function(...)
				return real(...) + Usage.TTL + 1
			end
			local fresh = Usage.is_fresh()
			os.time = real

			assert.is_false(fresh)
		end)

		it("waits out a minute before retrying a failure", function()
			local calls = 0
			local real = vim.system
			---@diagnostic disable-next-line: duplicate-set-field
			vim.system = function(_, _, callback)
				calls = calls + 1
				callback({ code = 1, signal = 0, stdout = "", stderr = "not logged in" })
				return { wait = function() end }
			end

			Usage.ensure()
			Usage.ensure()
			vim.system = real

			-- One token call, and no second attempt behind it.
			assert.are.equal(1, calls)
			assert.is_truthy(Usage.error())
			assert.is_false(Usage.is_loading())
		end)

		it("forgets everything on clear", function()
			Usage.inject(response(now))
			Usage.clear()

			assert.is_nil(Usage.peek())
			assert.is_false(Usage.is_fresh())
		end)
	end)

	describe("float", function()
		after_each(function()
			Ui.close()
		end)

		it("shows the cached numbers", function()
			Usage.inject(response(now))
			local lines = Ui.content(Usage.peek(), nil)

			assert.are.equal("Claude plan usage", lines[1])
			assert.is_truthy(lines[2]:find("5-hour session", 1, true))
		end)

		it("shows the error when there is nothing cached", function()
			local lines = Ui.content(nil, "Rate limited by Anthropic. Try again in a minute.")
			assert.is_truthy(lines[2]:find("Rate limited", 1, true))
		end)

		it("notes a stale answer under the figures", function()
			local lines = Ui.content(response(now), "Couldn't reach api.anthropic.com.")
			assert.is_truthy(lines[#lines]:find("note: Couldn't reach", 1, true))
		end)
	end)
end)
