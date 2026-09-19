local Chat = require("crust.ui.chat")
local config = require("crust.config")

---@param text string
---@return table
local function text_content(text)
	return { { type = "text", text = text } }
end

describe("ui.chat sessions", function()
	---@type Crust.Chat
	local chat
	---@type Crust.Pi.Command[]
	local sent
	---@type table<string, fun(event: Crust.Pi.Response)>
	local callbacks

	before_each(function()
		config.options = {}
		config.config = nil
		chat = Chat.new()
		sent = {}
		callbacks = {}

		-- Stub client: record commands and keep their callbacks so a
		-- response can be delivered by hand.
		chat._pi = {
			connect = function()
				return true
			end,
			is_running = function()
				return true
			end,
			send = function(_, command, callback)
				sent[#sent + 1] = command
				local id = "id-" .. #sent
				if callback then
					callbacks[command.type] = callback
				end
				return id
			end,
			close = function() end,
		}
	end)

	---@param command_type string
	---@param response table
	local function answer(command_type, response)
		local callback = assert(callbacks[command_type], "no pending " .. command_type)
		callbacks[command_type] = nil
		callback(response)
	end

	---@return string[]
	local function types()
		return vim.tbl_map(function(command)
			return command.type
		end, sent)
	end

	describe("load_session", function()
		it("switches, then replays the returned messages", function()
			local ok
			chat:load_session("/tmp/session.jsonl", function(success)
				ok = success
			end)

			assert.are.equal("switch_session", sent[1].type)
			assert.are.equal("/tmp/session.jsonl", sent[1].sessionPath)
			assert.are.equal("Loading session…", chat:status():text())

			answer("switch_session", { success = true, data = {} })
			assert.is_truthy(vim.tbl_contains(types(), "get_messages"))

			answer("get_messages", {
				success = true,
				data = {
					messages = {
						{ role = "user", content = text_content("hello"), timestamp = 1789857639275 },
						{ role = "assistant", content = text_content("hi there"), timestamp = 1789857640000 },
					},
				},
			})

			local output = table.concat(chat:output():lines(), "\n")
			assert.is_true(ok)
			assert.is_truthy(output:find("hello", 1, true))
			assert.is_truthy(output:find("hi there", 1, true))
			assert.is_nil(chat:status():text())
		end)

		it("replays tool calls with their results", function()
			chat:load_session("/tmp/session.jsonl")
			answer("switch_session", { success = true })
			answer("get_messages", {
				success = true,
				data = {
					messages = {
						{
							role = "assistant",
							content = {
								{ type = "toolCall", id = "call-1", name = "read", arguments = { path = "init.lua" } },
							},
						},
						{
							role = "toolResult",
							toolCallId = "call-1",
							toolName = "read",
							content = text_content("file body"),
						},
					},
				},
			})

			local output = table.concat(chat:output():lines(), "\n")
			assert.is_truthy(output:find("read", 1, true))
			assert.is_truthy(output:find("init.lua", 1, true))
			assert.are.equal("success", chat._tools:display("call-1").status)
		end)

		it("reports a failed switch and keeps the panel", function()
			local ok, err
			chat:load_session("/tmp/missing.jsonl", function(success, message)
				ok, err = success, message
			end)
			answer("switch_session", { success = false, error = "no such session" })

			assert.is_false(ok)
			assert.are.equal("no such session", err)
			assert.is_truthy(table.concat(chat:output():lines(), "\n"):find("no such session", 1, true))
		end)

		it("reports a cancelled switch", function()
			local ok
			chat:load_session("/tmp/session.jsonl", function(success)
				ok = success
			end)
			answer("switch_session", { success = true, data = { cancelled = true } })

			assert.is_false(ok)
			assert.is_falsy(vim.tbl_contains(types(), "get_messages"))
		end)
	end)

	describe("continue", function()
		local agent_dir

		before_each(function()
			agent_dir = vim.fn.tempname()
			config.options = { sessions = { agent_dir = agent_dir } }
			config.config = nil
		end)

		after_each(function()
			vim.fn.delete(agent_dir, "rf")
		end)

		it("loads the most recent session of the cwd", function()
			local dir = require("crust.sessions").dir()
			vim.fn.mkdir(dir, "p")
			local path = dir .. "/one.jsonl"
			local file = assert(io.open(path, "w"))
			file:write(
				vim.json.encode({ type = "session", id = "one", timestamp = "2026-09-19T10:00:00.000Z" }) .. "\n"
			)
			file:close()

			chat:continue()
			assert.are.equal("switch_session", sent[1].type)
			assert.are.equal(path, sent[1].sessionPath)
		end)

		it("resumes the same session when continued twice", function()
			local dir = require("crust.sessions").dir()
			vim.fn.mkdir(dir, "p")

			---@param name string
			---@param mtime integer
			local function session(name, mtime)
				local path = dir .. "/" .. name .. ".jsonl"
				local file = assert(io.open(path, "w"))
				file:write(
					vim.json.encode({ type = "session", id = name, timestamp = "2026-09-19T10:00:00.000Z" }) .. "\n"
				)
				file:close()
				vim.uv.fs_utime(path, mtime, mtime)
				return path
			end

			session("older", 1000)
			local newest = session("newest", 2000)

			chat:continue()
			answer("switch_session", { success = true })
			-- pi now reports the resumed session as the live one.
			chat:_on_event({
				type = "response",
				command = "get_state",
				success = true,
				data = { sessionId = "newest", sessionFile = newest },
			})

			chat:continue()

			assert.are.equal(newest, sent[1].sessionPath)
			assert.are.equal(newest, sent[#sent].sessionPath)
		end)

		it("only resumes on the first open, later ones just focus", function()
			local dir = require("crust.sessions").dir()
			vim.fn.mkdir(dir, "p")
			local path = dir .. "/one.jsonl"
			local file = assert(io.open(path, "w"))
			file:write(
				vim.json.encode({ type = "session", id = "one", timestamp = "2026-09-19T10:00:00.000Z" }) .. "\n"
			)
			file:close()

			chat:open({ continue = true })
			answer("switch_session", { success = true })
			local switches = #vim.tbl_filter(function(command)
				return command.type == "switch_session"
			end, sent)

			chat:open({ continue = true })
			chat:close()

			assert.are.equal(switches, #vim.tbl_filter(function(command)
				return command.type == "switch_session"
			end, sent))
		end)

		it("does nothing when the cwd has no sessions", function()
			local ok, err
			chat:continue(function(success, message)
				ok, err = success, message
			end)

			assert.is_false(ok)
			assert.are.equal("no previous session", err)
			assert.are.same({}, sent)
		end)
	end)

	describe("new_session", function()
		it("sends new_session with the live session as parent and clears the panel", function()
			chat:_on_event({
				type = "response",
				command = "get_state",
				success = true,
				data = { sessionId = "abc", sessionFile = "/tmp/abc.jsonl" },
			})
			chat:_on_event({ type = "agent_start" })
			chat:input():set_text("draft")

			local ok
			chat:new_session(function(success)
				ok = success
			end)

			assert.are.equal("new_session", sent[1].type)
			assert.are.equal("/tmp/abc.jsonl", sent[1].parentSession)

			answer("new_session", { success = true })

			assert.is_true(ok)
			assert.are.same({ "" }, chat:output():lines())
			assert.are.equal("", chat:input():text())
			assert.is_nil(chat:status():text())
		end)

		it("keeps the transcript when pi refuses", function()
			chat:output():append("old talk\n")

			local ok, err
			chat:new_session(function(success, message)
				ok, err = success, message
			end)
			answer("new_session", { success = false, error = "busy" })

			assert.is_false(ok)
			assert.are.equal("busy", err)
			assert.is_truthy(table.concat(chat:output():lines(), "\n"):find("old talk", 1, true))
		end)
	end)

	describe("rename", function()
		it("sends set_session_name and caches it", function()
			local ok
			chat:rename("bug hunt", function(success)
				ok = success
			end)

			assert.are.equal("set_session_name", sent[1].type)
			assert.are.equal("bug hunt", sent[1].name)

			answer("set_session_name", { success = true })
			assert.is_true(ok)
			assert.are.equal("bug hunt", chat:session().name)
		end)

		it("prompts with the current name when none is given", function()
			local prompted
			local input = vim.ui.input
			vim.ui.input = function(opts, on_confirm)
				prompted = opts
				on_confirm("renamed")
			end

			chat:rename()
			answer("get_state", { success = true, data = { sessionId = "abc", sessionName = "old name" } })

			vim.ui.input = input
			assert.are.equal("old name", prompted.default)
			assert.are.equal("set_session_name", sent[#sent].type)
			assert.are.equal("renamed", sent[#sent].name)
		end)

		it("reports a failure in the output", function()
			chat:rename("nope")
			answer("set_session_name", { success = false, error = "rename failed" })
			assert.is_truthy(table.concat(chat:output():lines(), "\n"):find("rename failed", 1, true))
		end)
	end)

	describe("session state", function()
		it("is filled from any get_state response", function()
			chat:_on_event({
				type = "response",
				command = "get_state",
				success = true,
				data = { sessionId = "abc", sessionName = "named", sessionFile = "/tmp/abc.jsonl" },
			})

			assert.are.same({ id = "abc", name = "named", file = "/tmp/abc.jsonl" }, chat:session())
		end)
	end)

	describe("session title", function()
		---@param entries table[]
		---@return string path
		local function write_session(entries)
			local path = vim.fn.tempname() .. ".jsonl"
			local file = assert(io.open(path, "w"))
			file:write(vim.json.encode({ type = "session", id = "abc", timestamp = "2026-09-01T10:00:00.000Z" }) .. "\n")
			for _, entry in ipairs(entries) do
				file:write(vim.json.encode(entry) .. "\n")
			end
			file:close()
			return path
		end

		---@param data table
		local function state(data)
			chat:_on_event({ type = "response", command = "get_state", success = true, data = data })
		end

		it("is the session name, and lands in the window bar", function()
			state({ sessionId = "abc", sessionName = "bug hunt" })

			assert.are.equal("bug hunt", chat:session_title())
			assert.are.equal("bug hunt", chat:output():title())
		end)

		it("falls back to the first message of the session file", function()
			local path = write_session({
				{ type = "message", message = { role = "user", content = text_content("fix the parser") } },
			})

			state({ sessionId = "abc", sessionFile = path })
			assert.are.equal("fix the parser", chat:session_title())

			vim.fn.delete(path)
		end)

		it("falls back to a placeholder for an empty session", function()
			local path = write_session({})

			state({ sessionId = "abc", sessionFile = path })
			assert.are.equal("New session", chat:session_title())

			vim.fn.delete(path)
		end)
	end)

	describe("clear", function()
		it("drops the transcript and the tool blocks", function()
			chat:_on_event({ type = "agent_start" })
			chat:_on_event({
				type = "tool_execution_start",
				toolCallId = "call-1",
				toolName = "read",
				args = { path = "init.lua" },
			})

			chat:clear()

			assert.are.same({ "" }, chat:output():lines())
			assert.is_nil(chat:status():text())
			assert.is_nil(chat._tools:display("call-1"))
		end)
	end)
end)
