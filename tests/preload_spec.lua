---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local crust = require("crust")
local config = require("crust.config")
local Cache = require("crust.sessions.cache")

--- Run the scheduled part of the warm-up.
local function flush()
	vim.wait(200, function()
		return vim.fn.bufnr("crust://chat") ~= -1
	end, 10)
end

---@return boolean
local function chat_built()
	return vim.fn.bufnr("crust://chat") ~= -1 and vim.fn.bufnr("crust://input") ~= -1
end

describe("preload", function()
	before_each(function()
		crust.stop()
		Cache.stop()
		for _, name in ipairs({ "crust://chat", "crust://input" }) do
			local buf = vim.fn.bufnr(name)
			if buf ~= -1 then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end
		config.options = nil
		config.config = nil
	end)

	after_each(function()
		crust.stop()
		Cache.stop()
		config.options = nil
		config.config = nil
	end)

	it("builds the chat buffers in the background", function()
		assert.is_false(chat_built())
		crust.preload({ sessions = false, chat = true })
		-- Scheduled, so nothing has happened yet on this tick.
		assert.is_false(chat_built())

		flush()
		assert.is_true(chat_built())
	end)

	it("leaves the chat alone when it is turned off", function()
		crust.preload({ sessions = false, chat = false })
		flush()
		assert.is_false(chat_built())
	end)

	it("does not start pi unless asked", function()
		crust.preload({ sessions = false, chat = true })
		flush()
		assert.is_false(crust.chat():pi():is_running())
	end)

	it("reuses the preloaded chat when the panel is opened", function()
		crust.preload({ sessions = false, chat = true })
		flush()
		local buf = vim.fn.bufnr("crust://chat")

		crust.open()
		assert.are.equal(buf, crust.chat():output():buf())
		crust.chat():close()
	end)

	it("warms the session cache", function()
		local agent_dir = vim.fn.tempname()
		config.setup({ sessions = { agent_dir = agent_dir } })
		local dir = require("crust.sessions").dir()
		vim.fn.mkdir(dir, "p")
		local file = assert(io.open(dir .. "/a.jsonl", "w"))
		file:write(vim.json.encode({ type = "session", id = "a", timestamp = "2024-03-07T09:05:11Z" }) .. "\n")
		file:close()

		crust.preload({ sessions = true, chat = false })
		assert.is_true(vim.wait(2000, function()
			return #Cache.cached() == 1
		end, 20))

		vim.fn.delete(agent_dir, "rf")
	end)
end)
