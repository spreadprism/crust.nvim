local Pi = require("crust.pi.client")

local TEST_MODEL = "anthropic/claude-haiku-4-5"

describe("pi", function()
	it("reports not running before connect", function()
		local pi = Pi.new()
		assert.False(pi:is_running())
		local ok, err = pi:ping()
		assert.False(ok)
		assert.is_not_nil(err)
	end)

	it("fails to connect with a missing binary", function()
		local pi = Pi.new({ bin = "crust-no-such-binary" })
		local ok = pi:connect()
		assert.False(ok)
		assert.False(pi:is_running())
	end)

	it("connects, pings and closes", function()
		if vim.fn.executable("pi") == 0 then
			return
		end

		local pi = Pi.new({ args = { "--no-session" } })
		assert.True(pi:connect())
		assert.True(pi:is_running())

		local ok, err = pi:ping(nil, 15000)
		assert.is_nil(err)
		assert.True(ok)

		pi:close()
		assert.False(pi:is_running())
	end)

	describe("send", function()
		it("rejects raw tables", function()
			local pi = Pi.new()
			local id, err = pi:send({ type = "get_state" })
			assert.is_nil(id)
			assert.is_not_nil(err)
		end)
	end)

	describe("model", function()
		it("accepts valid model", function()
			if vim.fn.executable("pi") == 0 then
				return
			end

			local pi = Pi.new({ args = { "--no-session" }, model = TEST_MODEL })
			assert.True(pi:connect())
			assert.True(pi:is_running())

			local ok, err = pi:ping(nil, 15000)
			pi:close()

			assert.is_nil(err)
			assert.True(ok)
		end)

		it("refuses invalid model", function()
			if vim.fn.executable("pi") == 0 then
				return
			end

			local exit_code ---@type integer?
			local stderr = {} ---@type string[]

			local pi = Pi.new({
				args = { "--no-session" },
				model = "crust/no-such-model",
				on_event = function(event)
					if event.type == "_stderr" then
						stderr[#stderr + 1] = event.message --[[@as string]]
					elseif event.type == "_process_exit" then
						exit_code = event.code
					end
				end,
			})

			-- jobstart succeeds, pi rejects the model and exits.
			assert.True(pi:connect())

			local exited = vim.wait(15000, function()
				return exit_code ~= nil
			end, 20)

			pi:close()

			assert.True(exited)
			assert.are.equal(1, exit_code)
			assert.is_not_nil(table.concat(stderr, "\n"):match("not found"))
			assert.False(pi:is_running())

			local ok, err = pi:ping()
			assert.False(ok)
			assert.is_not_nil(err)
		end)
	end)
end)
