---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Sessions = require("crust.sessions")
local Cache = require("crust.sessions.cache")
local config = require("crust.config")

---@param dir string
---@param name string
---@param lines table[]
---@return string path
local function write_session(dir, name, lines)
	vim.fn.mkdir(dir, "p")
	local path = dir .. "/" .. name
	local file = assert(io.open(path, "w"))
	for _, line in ipairs(lines) do
		file:write(vim.json.encode(line) .. "\n")
	end
	file:close()
	return path
end

---@param id string
---@param name? string
---@return table[]
local function session_lines(id, name)
	local lines = { { type = "session", id = id, timestamp = "2024-03-07T09:05:11Z" } }
	if name then
		lines[#lines + 1] = { type = "session_info", name = name }
	end
	return lines
end

--- Wait until `check` passes, pumping the event loop.
---@param check fun(): boolean
---@return boolean
local function wait(check)
	return vim.wait(2000, check, 20)
end

describe("sessions.cache", function()
	local agent_dir
	local cwd
	local dir

	before_each(function()
		config.options = nil
		config.config = nil
		agent_dir = vim.fn.tempname()
		cwd = "/tmp/crust-cache-project"
		config.setup({ sessions = { agent_dir = agent_dir } })
		dir = Sessions.dir(cwd)
	end)

	after_each(function()
		Cache.stop()
		vim.fn.delete(agent_dir, "rf")
		config.options = nil
		config.config = nil
	end)

	describe("list", function()
		it("returns the sessions newest first", function()
			write_session(dir, "old.jsonl", session_lines("old", "older"))
			local recent = write_session(dir, "new.jsonl", session_lines("new", "newer"))
			vim.uv.fs_utime(recent, os.time() + 10, os.time() + 10)

			local sessions = Cache.list(cwd)
			assert.are.equal(2, #sessions)
			assert.are.equal("newer", sessions[1].name)
		end)

		it("reuses the parse of an unchanged file", function()
			write_session(dir, "a.jsonl", session_lines("a", "first"))
			local first = Cache.list(cwd)[1]
			assert.are.equal(first, Cache.list(cwd)[1])
		end)

		it("reparses a file whose mtime moved", function()
			local path = write_session(dir, "a.jsonl", session_lines("a", "first"))
			assert.are.equal("first", Cache.list(cwd)[1].name)

			write_session(dir, "a.jsonl", session_lines("a", "renamed"))
			vim.uv.fs_utime(path, os.time() + 10, os.time() + 10)
			assert.are.equal("renamed", Cache.list(cwd)[1].name)
		end)

		it("drops a session that was deleted", function()
			write_session(dir, "a.jsonl", session_lines("a"))
			write_session(dir, "b.jsonl", session_lines("b"))
			assert.are.equal(2, #Cache.list(cwd))

			vim.fn.delete(dir .. "/b.jsonl")
			assert.are.equal(1, #Cache.list(cwd))
		end)

		it("is empty for a cwd without history", function()
			assert.are.same({}, Cache.list("/tmp/crust-no-history"))
		end)
	end)

	describe("warm", function()
		it("fills the cache in the background", function()
			write_session(dir, "a.jsonl", session_lines("a", "warmed"))
			assert.are.same({}, Cache.cached(cwd))

			Cache.warm(cwd)
			assert.is_true(wait(function()
				return #Cache.cached(cwd) == 1
			end))
			assert.are.equal("warmed", Cache.cached(cwd)[1].name)
		end)

		it("picks up a session written after the warm-up", function()
			write_session(dir, "a.jsonl", session_lines("a"))
			Cache.warm(cwd)
			assert.is_true(wait(function()
				return #Cache.cached(cwd) == 1
			end))

			write_session(dir, "b.jsonl", session_lines("b"))
			assert.is_true(wait(function()
				return #Cache.cached(cwd) == 2
			end))
		end)

		it("starts watching a session directory created later", function()
			vim.fn.mkdir(vim.fs.dirname(dir), "p")
			Cache.warm(cwd)
			assert.is_true(wait(function()
				return #Cache.cached(cwd) == 0
			end))

			write_session(dir, "a.jsonl", session_lines("a", "late"))
			assert.is_true(wait(function()
				return #Cache.cached(cwd) == 1
			end))
		end)

		it("does not rescan once warm", function()
			write_session(dir, "a.jsonl", session_lines("a"))
			Cache.warm(cwd)
			assert.is_true(wait(function()
				return #Cache.cached(cwd) == 1
			end))

			local before = Cache.cached(cwd)[1]
			Cache.warm(cwd)
			vim.wait(50)
			assert.are.equal(before, Cache.cached(cwd)[1])
		end)
	end)

	describe("stop", function()
		it("forgets the cache and stops watching", function()
			write_session(dir, "a.jsonl", session_lines("a"))
			Cache.warm(cwd)
			assert.is_true(wait(function()
				return #Cache.cached(cwd) == 1
			end))

			Cache.stop(cwd)
			assert.are.same({}, Cache.cached(cwd))

			write_session(dir, "b.jsonl", session_lines("b"))
			vim.wait(100)
			assert.are.same({}, Cache.cached(cwd))
		end)
	end)

	describe("sessions.list", function()
		it("goes through the cache", function()
			write_session(dir, "a.jsonl", session_lines("a", "through cache"))
			assert.are.equal("through cache", Sessions.list(cwd)[1].name)
			assert.are.equal(Sessions.list(cwd)[1], Cache.cached(cwd)[1])
		end)

		it("still has an uncached scan", function()
			write_session(dir, "a.jsonl", session_lines("a", "scanned"))
			local scanned = Sessions.scan(cwd)
			assert.are.equal("scanned", scanned[1].name)
			assert.are_not.equal(scanned[1], Sessions.list(cwd)[1])
		end)
	end)
end)
