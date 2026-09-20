-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

--- Live checks of the session rpc commands against a real pi process.
--- Nothing here talks to a model, so the run stays fast.

local Pi = require("crust.pi.client")
local Rpc = require("crust.pi.rpc")
local Sessions = require("crust.sessions")

local TIMEOUT_MS = 10000

local function isolated_args()
	local args = { "--no-skills", "--no-context-files", "--no-tools" }
	for _, path in ipairs(vim.split(vim.env.CRUST_TEST_PI_EXTENSIONS or "", ":", { trimempty = true })) do
		vim.list_extend(args, { "-e", path })
	end
	return args
end

--- Send a command and block until pi answers.
---@param pi Crust.Pi
---@param command Crust.Pi.Command
---@return Crust.Pi.Response
local function request(pi, command)
	local response ---@type Crust.Pi.Response?
	local id, err = pi:send(command, function(event)
		response = event
	end)
	assert(id, err)

	vim.wait(TIMEOUT_MS, function()
		return response ~= nil
	end, 25)

	return assert(response, command.type .. " timed out")
end

describe("pi sessions", function()
	---@type string
	local cwd
	---@type string
	local dir

	before_each(function()
		cwd = vim.fn.tempname()
		vim.fn.mkdir(cwd, "p")
		dir = Sessions.dir(cwd)
	end)

	after_each(function()
		vim.fn.delete(cwd, "rf")
		vim.fn.delete(dir, "rf")
	end)

	--- Write a session pi can be switched to.
	---@return string path
	local function write_session()
		vim.fn.mkdir(dir, "p")
		local id = "01a0bbdd-0000-7000-b000-000000000000"
		local path = dir .. "/2026-09-19T00-00-00-000Z_" .. id .. ".jsonl"

		local file = assert(io.open(path, "w"))
		for _, entry in ipairs({
			{ type = "session", version = 3, id = id, timestamp = "2026-09-19T00:00:00.000Z", cwd = cwd },
			{
				type = "message",
				id = "m1",
				timestamp = "2026-09-19T00:00:01.000Z",
				message = {
					role = "user",
					content = { { type = "text", text = "remembered question" } },
					timestamp = 1789800000000,
				},
			},
			{
				type = "session_info",
				id = "s1",
				parentId = "m1",
				timestamp = "2026-09-19T00:00:02.000Z",
				name = "handmade",
			},
		}) do
			file:write(vim.json.encode(entry) .. "\n")
		end
		file:close()

		return path
	end

	---@return Crust.Pi
	local function connect()
		local pi = Pi.new({ args = isolated_args(), cwd = cwd })
		assert.True(pi:connect())
		return pi
	end

	it("writes its sessions where crust.sessions looks for them", function()
		if vim.fn.executable("pi") == 0 then
			return
		end

		local pi = connect()
		local state = request(pi, Rpc.get_state()).data --[[@as Crust.Pi.Data.State]]
		pi:close()

		assert.are.equal(dir, vim.fs.dirname(assert(state.sessionFile)))
	end)

	it("starts a new session and records the old one as its parent", function()
		if vim.fn.executable("pi") == 0 then
			return
		end

		local pi = connect()
		local before = request(pi, Rpc.get_state()).data --[[@as Crust.Pi.Data.State]]
		assert.True(request(pi, Rpc.new_session(before.sessionFile)).success)
		local after = request(pi, Rpc.get_state()).data --[[@as Crust.Pi.Data.State]]
		pi:close()

		assert.are_not.equal(before.sessionId, after.sessionId)
		assert.are.equal(0, after.messageCount)
	end)

	it("renames the live session", function()
		if vim.fn.executable("pi") == 0 then
			return
		end

		local pi = connect()
		assert.True(request(pi, Rpc.set_session_name("crust test")).success)
		local state = request(pi, Rpc.get_state()).data --[[@as Crust.Pi.Data.State]]
		pi:close()

		assert.are.equal("crust test", state.sessionName)
	end)

	it("switches to a recorded session and replays its messages", function()
		if vim.fn.executable("pi") == 0 then
			return
		end

		local path = write_session()

		local session = assert(Sessions.parse(path))
		assert.are.equal("handmade", session.name)
		assert.are.equal("remembered question", session.first_message)
		assert.are.equal(path, assert(Sessions.last({ cwd = cwd })).path)

		local pi = connect()
		local switched = request(pi, Rpc.switch_session(path))
		local messages = request(pi, Rpc.get_messages()).data --[[@as Crust.Pi.Data.Messages]]
		pi:close()

		assert.True(switched.success)
		assert.are.equal(1, #messages.messages)
		assert.are.equal("user", messages.messages[1].role)
		assert.are.equal("remembered question", messages.messages[1].content[1].text)
	end)
end)