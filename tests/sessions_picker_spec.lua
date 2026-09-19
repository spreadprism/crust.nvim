local Picker = require("crust.sessions.picker")
local Sessions = require("crust.sessions")
local config = require("crust.config")

---@param dir string
---@param name string
---@return string path
local function write_session(dir, name)
	vim.fn.mkdir(dir, "p")
	local path = dir .. "/" .. name .. ".jsonl"
	local file = assert(io.open(path, "w"))
	file:write(vim.json.encode({ type = "session", id = name, timestamp = "2026-09-19T10:00:00.000Z" }) .. "\n")
	file:close()
	return path
end

describe("sessions.picker", function()
	local agent_dir
	local cwd
	local confirm

	before_each(function()
		config.options = {}
		config.config = nil
		agent_dir = vim.fn.tempname()
		cwd = "/tmp/crust-project"
		config.setup({ sessions = { agent_dir = agent_dir } })
		confirm = vim.fn.confirm
	end)

	after_each(function()
		vim.fn.confirm = confirm
		vim.fn.delete(agent_dir, "rf")
	end)

	describe("select", function()
		it("answers with nil and notifies when there is nothing to pick", function()
			local called, level = false, nil
			local notify = vim.notify
			vim.notify = function(_, lvl)
				level = lvl
			end

			Picker.select({ cwd = cwd }, function(session)
				called = true
				assert.is_nil(session)
			end)

			vim.notify = notify
			assert.is_true(called)
			assert.are.equal(vim.log.levels.INFO, level)
		end)

		it("falls back to vim.ui.select without snacks", function()
			write_session(Sessions.dir(cwd), "one")

			local prompted
			local select = vim.ui.select
			vim.ui.select = function(items, opts, on_choice)
				prompted = opts
				on_choice(items[1])
			end

			local chosen
			Picker.select({ cwd = cwd, title = "Pick one" }, function(session)
				chosen = session
			end)

			vim.ui.select = select
			assert.are.equal("Pick one", prompted.prompt)
			assert.are.equal("crust-sessions", prompted.kind)
			assert.are.equal("one", chosen.id)
		end)
	end)

	describe("delete", function()
		local first, second

		before_each(function()
			local dir = Sessions.dir(cwd)
			first = write_session(dir, "first")
			second = write_session(dir, "second")
		end)

		---@return { session: Crust.Session }[]
		local function entries()
			return vim.tbl_map(function(session)
				return { session = session }
			end, Sessions.list(cwd))
		end

		it("removes the confirmed sessions and reports back", function()
			vim.fn.confirm = function()
				return 1
			end

			local done = false
			Picker.delete(entries(), function()
				done = true
			end)

			assert.is_true(done)
			assert.are.equal(0, vim.fn.filereadable(first))
			assert.are.equal(0, vim.fn.filereadable(second))
			assert.are.same({}, Sessions.list(cwd))
		end)

		it("keeps everything when the confirmation is declined", function()
			vim.fn.confirm = function()
				return 2
			end

			local done = false
			Picker.delete(entries(), function()
				done = true
			end)

			assert.is_false(done)
			assert.are.equal(2, #Sessions.list(cwd))
		end)

		it("labels the session in the prompt when a single one is deleted", function()
			local prompt
			vim.fn.confirm = function(message)
				prompt = message
				return 2
			end

			local session = assert(Sessions.parse(first))
			session.name = "bug hunt"
			Picker.delete({ { session = session } })

			assert.are.equal("Delete session 'bug hunt'?", prompt)
		end)

		it("counts the sessions in the prompt when several are deleted", function()
			local prompt
			vim.fn.confirm = function(message)
				prompt = message
				return 2
			end

			Picker.delete(entries())
			assert.are.equal("Delete 2 sessions?", prompt)
		end)

		it("does nothing without a selection", function()
			vim.fn.confirm = function()
				error("should not ask")
			end

			Picker.delete({})
			assert.are.equal(2, #Sessions.list(cwd))
		end)
	end)
end)
