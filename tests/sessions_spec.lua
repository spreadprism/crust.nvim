local Sessions = require("crust.sessions")
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

describe("sessions", function()
	local agent_dir
	local cwd

	before_each(function()
		config.options = {}
		config.config = nil
		agent_dir = vim.fn.tempname()
		cwd = "/tmp/crust-project"
		config.setup({ sessions = { agent_dir = agent_dir } })
	end)

	after_each(function()
		vim.fn.delete(agent_dir, "rf")
	end)

	describe("dir", function()
		it("flattens the cwd the way pi does", function()
			assert.are.equal(
				"--home-avalon-workspace-crust.nvim--",
				Sessions.encode_cwd("/home/avalon/workspace/crust.nvim")
			)
		end)

		it("resolves to <agent dir>/sessions/<encoded cwd>", function()
			assert.are.equal(agent_dir .. "/sessions/--tmp-crust-project--", Sessions.dir(cwd))
		end)

		it("falls back to the configured agent dir over the environment", function()
			assert.are.equal(agent_dir, Sessions.agent_dir())
		end)
	end)

	describe("parse", function()
		it("reads the header, the name and the first user message", function()
			local path = write_session(Sessions.dir(cwd), "a.jsonl", {
				{ type = "session", id = "abc", timestamp = "2026-09-19T22:40:30.396Z" },
				{
					type = "message",
					message = { role = "user", content = { { type = "text", text = "fix  the\nproblem" } } },
				},
				{ type = "message", message = { role = "user", content = "later one" } },
				{ type = "session_info", name = "  bug hunt  " },
			})

			local session = assert(Sessions.parse(path))
			assert.are.equal("abc", session.id)
			assert.are.equal("2026-09-19T22:40:30.396Z", session.timestamp)
			assert.are.equal("bug hunt", session.name)
			assert.are.equal("fix the problem", session.first_message)
		end)

		it("keeps the last name of a renamed session", function()
			local path = write_session(Sessions.dir(cwd), "b.jsonl", {
				{ type = "session", id = "abc", timestamp = "2026-09-19T22:40:30.396Z" },
				{ type = "session_info", name = "first" },
				{ type = "session_info", name = "second" },
			})

			assert.are.equal("second", assert(Sessions.parse(path)).name)
		end)

		it("rejects files without a session header", function()
			local path = write_session(Sessions.dir(cwd), "c.jsonl", { { type = "message" } })
			assert.is_nil(Sessions.parse(path))
		end)
	end)

	describe("list", function()
		it("is empty when the directory does not exist", function()
			assert.are.same({}, Sessions.list(cwd))
		end)

		it("returns sessions newest first", function()
			local dir = Sessions.dir(cwd)
			local old = write_session(dir, "old.jsonl", {
				{ type = "session", id = "old", timestamp = "2026-09-01T10:00:00.000Z" },
			})
			local new = write_session(dir, "new.jsonl", {
				{ type = "session", id = "new", timestamp = "2026-09-02T10:00:00.000Z" },
			})
			-- getftime has one second resolution, so the mtimes are forced.
			vim.uv.fs_utime(old, 1000, 1000)
			vim.uv.fs_utime(new, 2000, 2000)

			local sessions = Sessions.list(cwd)
			assert.are.equal(2, #sessions)
			assert.are.equal(new, sessions[1].path)
			assert.are.equal(old, sessions[2].path)
		end)
	end)

	describe("last", function()
		local dir, old, new

		before_each(function()
			dir = Sessions.dir(cwd)
			old = write_session(dir, "old.jsonl", {
				{ type = "session", id = "old", timestamp = "2026-09-01T10:00:00.000Z" },
			})
			new = write_session(dir, "new.jsonl", {
				{ type = "session", id = "new", timestamp = "2026-09-02T10:00:00.000Z" },
			})
			vim.uv.fs_utime(old, 1000, 1000)
			vim.uv.fs_utime(new, 2000, 2000)
		end)

		it("returns the most recent session", function()
			assert.are.equal(new, assert(Sessions.last({ cwd = cwd })).path)
		end)

		it("skips the excluded session, usually the live one", function()
			assert.are.equal(old, assert(Sessions.last({ cwd = cwd, exclude = new })).path)
		end)

		it("is nil when everything is excluded", function()
			vim.fn.delete(old)
			assert.is_nil(Sessions.last({ cwd = cwd, exclude = new }))
		end)
	end)

	describe("label", function()
		it("prefers the name, then the first message", function()
			assert.are.equal("named", Sessions.label({ name = "named", first_message = "hello" }))
			assert.are.equal("hello", Sessions.label({ first_message = "hello" }))
			assert.are.equal("(empty session)", Sessions.label({ first_message = "" }))
		end)

		it("takes the date out of the timestamp", function()
			assert.are.equal("2026-09-19", Sessions.date({ timestamp = "2026-09-19T22:40:30.396Z" }))
		end)
	end)
end)
