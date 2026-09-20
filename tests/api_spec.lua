-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Sessions = require("crust.sessions")
local config = require("crust.config")

---@param dir string
---@param name string
---@param age integer seconds subtracted from the mtime, so order is stable
---@return string path
local function write_session(dir, name, age)
	vim.fn.mkdir(dir, "p")
	local path = dir .. "/" .. name .. ".jsonl"
	local file = assert(io.open(path, "w"))
	file:write(vim.json.encode({ type = "session", id = name, timestamp = "2026-09-19T10:00:00.000Z" }) .. "\n")
	file:close()

	local now = os.time()
	vim.uv.fs_utime(path, now - age, now - age)
	return path
end

describe("api session_last", function()
	local crust
	local agent_dir
	local cwd
	---@type Crust.Chat
	local chat
	local loaded
	local opened

	before_each(function()
		package.loaded["crust"] = nil
		package.loaded["crust.sessions.cache"] = nil
		config.options = {}
		config.config = nil

		agent_dir = vim.fn.tempname()
		cwd = vim.fn.getcwd()
		config.setup({ sessions = { agent_dir = agent_dir } })

		crust = require("crust")
		loaded, opened = nil, false

		chat = crust.chat()
		chat.open = function()
			opened = true
		end
		chat.load_session = function(_, path, callback)
			loaded = path
			if callback then
				callback(true)
			end
		end
	end)

	after_each(function()
		package.loaded["crust"] = nil
		vim.fn.delete(agent_dir, "rf")
		config.options = {}
		config.config = nil
	end)

	---@param file string?
	local function live(file)
		chat.session = function()
			return { file = file }
		end
	end

	it("loads the newest session when the chat has none yet", function()
		local newest = write_session(Sessions.dir(cwd), "newest", 0)
		write_session(Sessions.dir(cwd), "older", 60)
		live(nil)

		assert.is_true(crust.session_last())
		assert.is_true(opened)
		assert.are.equal(newest, loaded)
	end)

	it("steps back past the session the chat is already on", function()
		local newest = write_session(Sessions.dir(cwd), "newest", 0)
		local older = write_session(Sessions.dir(cwd), "older", 60)
		live(newest)

		assert.is_true(crust.session_last())
		assert.are.equal(older, loaded)
	end)

	it("does nothing, and stays quiet, without another session", function()
		local only = write_session(Sessions.dir(cwd), "only", 0)
		live(only)

		local notified = false
		local notify = vim.notify
		vim.notify = function()
			notified = true
		end

		local ok, err
		local switching = crust.session_last(function(success, message)
			ok, err = success, message
		end)

		vim.notify = notify
		assert.is_false(switching)
		assert.is_false(notified)
		assert.is_false(ok)
		assert.are.equal("no other session", err)
		assert.is_nil(loaded)
	end)
end)
