--- Minimal chat: wires the pi process to an Input and an Output panel.

---@class Crust.Chat
---@field private _pi Crust.Pi
---@field private _input Crust.Chat.Input
---@field private _output Crust.Chat.Output
---@field private _tools Crust.Chat.Tools
---@field private _status Crust.Chat.Status
---@field private _streaming boolean
---@field private _augroup integer?
---@field private _closing boolean
---@field private _session Crust.Chat.Session
---@field private _resumed boolean a past session was loaded into this chat
local Chat = {}
Chat.__index = Chat

---@class Crust.Chat.Session what the last `get_state` said about the session
---@field id? string
---@field name? string
---@field file? string path of the `.jsonl` pi is writing

---@class Crust.Chat.OpenOpts
---@field continue? boolean load the most recent session of the cwd
---@field session? string session file to load

local next_id = 0

local Pi = require("crust.pi.client")
local Command = require("crust.pi.rpc")
local Input = require("crust.ui.chat.input")
local Output = require("crust.ui.chat.output")
local Tools = require("crust.ui.chat.tools")
local Status = require("crust.ui.chat.status")
local Highlights = require("crust.ui.highlights")
local Replay = require("crust.ui.chat.replay")

local WIDTH_RATIO = 0.4

--- Window bar title of a session that has neither a name nor a message yet.
local NEW_SESSION_TITLE = "New session"

---@param opts? Crust.Pi.Opts
---@return Crust.Chat
function Chat.new(opts)
	local self = setmetatable({}, Chat)

	next_id = next_id + 1
	self._id = next_id
	self._closing = false
	self._streaming = false
	self._session = {}
	self._resumed = false
	self._output = Output.new()
	self._tools = Tools.new()
	self._status = Status.new(self._output)
	self._input = Input.new(function(text)
		self:_send(text)
	end)

	self:_setup_keymaps()

	self._pi = Pi.new(vim.tbl_extend("force", opts or {}, {
		on_event = function(event)
			vim.schedule(function()
				self:_on_event(event)
			end)
		end,
	}))

	return self
end

---@return Crust.Pi
function Chat:pi()
	return self._pi
end

---@return Crust.Chat.Input
function Chat:input()
	return self._input
end

---@return Crust.Chat.Output
function Chat:output()
	return self._output
end

---@return Crust.Chat.Status
function Chat:status()
	return self._status
end

--- Session pi last reported, refreshed after every state round-trip.
---@return Crust.Chat.Session
function Chat:session()
	return self._session
end

--- Chat keymaps, all buffer-local and all disabled with `false`.
---@private
function Chat:_setup_keymaps()
	local keymaps = require("crust.config").get().keymaps

	---@param lhs string|false
	---@param modes string[] modes bound in the input buffer
	---@param desc string
	---@param rhs fun()
	local function map(lhs, modes, desc, rhs)
		if not lhs then
			return
		end
		vim.keymap.set(modes, lhs, rhs, { buffer = self._input:buf(), desc = desc })
		vim.keymap.set("n", lhs, rhs, { buffer = self._output:buf(), desc = desc })
	end

	map(keymaps.cancel, { "n", "i" }, "crust: cancel", function()
		self:cancel()
	end)
	map(keymaps.sessions, { "n" }, "crust: sessions", function()
		self:sessions()
	end)

	-- Only the scrollback has tool blocks to preview, and `K` in the prompt
	-- is the user's own keyword lookup.
	if keymaps.preview then
		vim.keymap.set("n", keymaps.preview, function()
			self:preview_tool()
		end, { buffer = self._output:buf(), desc = "crust: preview the tool call" })
	end
end

--- Open the tool call under the cursor in a floating window: the full title
--- and the full output, neither cut to the panel.
---@return boolean opened false when the cursor is not on a tool block
function Chat:preview_tool()
	local display = self._tools:display_at(self._output:block_at())
	if not display then
		return false
	end

	return require("crust.ui.chat.tools.preview").open(display) ~= nil
end

---@return integer out_buf, integer in_buf
function Chat:bufs()
	return self._output:buf(), self._input:buf()
end

---@return boolean
function Chat:is_visible()
	return self._output:win() ~= nil
end

---@param opts? Crust.Chat.OpenOpts
function Chat:open(opts)
	opts = opts or {}

	-- The panel comes up first and the conversation is replayed into it: pi's
	-- startup plus the switch_session/get_messages round trip is far too slow
	-- to hold the windows back on, `load_session` shows "Loading session…"
	-- in the status line meanwhile.
	self:_show()

	-- Only the first open resumes: later ones just focus the chat, or a
	-- repeated keymap would walk further back through the history.
	if opts.session then
		self:load_session(opts.session)
	elseif opts.continue and not self._resumed then
		self:continue()
	end
end

--- Open both windows on the buffers as they are.
---@private
function Chat:_show()
	-- A title is up before the first `get_state` answers.
	self._output:set_title(self:session_title())

	if self:is_visible() then
		self._input:focus()
		return
	end

	self._output:open(math.floor(vim.o.columns * WIDTH_RATIO))
	self._input:open()
	self:_watch_windows()
	self._status:render()

	local ok, err = self._pi:connect()
	if not ok then
		self._output:error(tostring(err))
		return
	end

	self._output:follow()
	self._input:focus()
	self:refresh_session()
	-- Slash commands come from the session, so they are fetched once the
	-- process is up and again whenever the session changes.
	require("crust.completion.commands").fetch(self._pi)
end

--- Closing one panel closes the other: the two windows are one unit.
---@private
function Chat:_watch_windows()
	local watched = { [self._output:win()] = true, [self._input:win()] = true }

	self._augroup = vim.api.nvim_create_augroup("crust.chat." .. self._id, { clear = true })
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = self._augroup,
		callback = function()
			self:resize()
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = self._augroup,
		callback = function(event)
			if not watched[tonumber(event.match)] then
				return
			end
			-- WinClosed fires before the window is gone, so close the sibling
			-- once neovim is done tearing this one down.
			vim.schedule(function()
				self:close()
			end)
		end,
	})
end

--- Give the width change to the output panel and keep the input at its
--- fixed height.
function Chat:resize()
	if not self:is_visible() then
		return
	end

	self._output:set_width(math.floor(vim.o.columns * WIDTH_RATIO))
	self._input:restore_height()
	self._status:update_window()
end

function Chat:close()
	if self._closing then
		return
	end
	self._closing = true

	if self._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, self._augroup)
		self._augroup = nil
	end

	self._status:close()
	self._input:close()
	self._output:close()
	self._closing = false
end

---@param opts? Crust.Chat.OpenOpts
function Chat:toggle(opts)
	if self:is_visible() then
		self:close()
	else
		self:open(opts)
	end
end

function Chat:focus_input()
	self._input:focus()
end

--- Send the input buffer content as a prompt.
function Chat:submit()
	self._input:submit()
end

---@private
---@param text string
function Chat:_send(text)
	if not self._pi:is_running() then
		local ok, err = self._pi:connect()
		if not ok then
			self._output:error(tostring(err))
			return
		end
	end

	self._input:clear()
	self._output:header(require("crust.config").get().labels.user, Highlights.USER_TITLE)
	-- The scrollback shows what was typed; pi gets the expanded prompt, so a
	-- `@path` mention stays one blue word here and is a whole file there.
	self._output:append_message(text .. "\n")
	local prompt = require("crust.expansion").expand(text)

	local _, err = self._pi:send(
		Command.prompt(prompt, self._streaming and { streaming_behavior = "followUp" } or nil),
		function(event)
			if event.success == false then
				self._output:error(event.error or "prompt failed")
			end
		end
	)
	if err then
		self._output:error(err)
	end
end

--- Abort the running turn. Does nothing when the agent is idle.
---@return boolean aborted
function Chat:cancel()
	if not self._streaming or not self._pi:is_running() then
		return false
	end

	local _, err = self._pi:send(Command.abort())
	if err then
		self._output:error(err)
		return false
	end

	self._status:set("Cancelling…")
	return true
end

function Chat:stop()
	self._pi:close()
end

--- Wipe the transcript, the tool blocks and any running status.
function Chat:clear()
	self._streaming = false
	self._status:clear()
	self._tools:reset()
	self._output:clear()
end

--- Make sure the pi process is up, reporting failures in the panel.
---@private
---@return boolean ok
function Chat:_ensure_running()
	if self._pi:is_running() then
		return true
	end

	local ok, err = self._pi:connect()
	if not ok then
		self._output:error(tostring(err))
	end
	return ok
end

--- Refresh the cached session id, name and file.
---@param callback? fun(session: Crust.Chat.Session)
function Chat:refresh_session(callback)
	if not self:_ensure_running() then
		return
	end

	self._pi:send(Command.get_state(), function(event)
		local data = event.success ~= false and event.data or nil --[[@as Crust.Pi.Data.State?]]
		if data then
			self._session = {
				id = data.sessionId,
				name = data.sessionName,
				file = data.sessionFile,
			}
			self:_refresh_title()
		end
		if callback then
			callback(self._session)
		end
	end)
end

--- Title of the live session: its name, else its first message, else a
--- placeholder. pi only reports the name, so the file is read for the rest.
---@return string
function Chat:session_title()
	if self._session.name and self._session.name ~= "" then
		return self._session.name
	end

	if self._session.file then
		local stored = require("crust.sessions").parse(self._session.file)
		if stored and stored.first_message ~= "" then
			return stored.first_message
		end
	end

	return NEW_SESSION_TITLE
end

--- Draw the session title in the output window bar.
---@private
function Chat:_refresh_title()
	self._output:set_title(self:session_title())
end

--- Switch pi to `path` and redraw the panel with that conversation.
---@param path string session `.jsonl`
---@param callback? fun(ok: boolean, err: string?)
function Chat:load_session(path, callback)
	if not self:_ensure_running() then
		if callback then
			callback(false, "pi process is not running")
		end
		return
	end

	---@param ok boolean
	---@param err string?
	local function finish(ok, err)
		if not ok and err then
			self._output:error(err)
		end
		self._status:clear()
		if callback then
			callback(ok, err)
		end
	end

	self._status:set("Loading session…")

	local _, send_err = self._pi:send(Command.switch_session(path), function(event)
		if event.success == false then
			return finish(false, event.error or "failed to switch session")
		end

		local data = event.data --[[@as Crust.Pi.Data.Cancelled?]]
		if data and data.cancelled then
			return finish(false, "session switch was cancelled")
		end

		self._resumed = true
		self:clear()
		self:refresh_session()
		require("crust.completion.commands").fetch(self._pi)

		local _, messages_err = self._pi:send(Command.get_messages(), function(response)
			if response.success == false then
				return finish(false, response.error or "failed to load session messages")
			end

			local messages = response.data --[[@as Crust.Pi.Data.Messages?]]
			Replay.render(messages and messages.messages or {}, self._output, self._tools)
			finish(true)
		end)
		if messages_err then
			finish(false, messages_err)
		end
	end)

	if send_err then
		finish(false, send_err)
	end
end

--- Load the most recent session of the cwd, like `pi --continue`.
--- A cwd without history simply keeps the empty session pi started with.
---@param callback? fun(ok: boolean, err: string?)
function Chat:continue(callback)
	local path = self:_continue_path()
	if not path then
		if callback then
			callback(false, "no previous session")
		end
		return
	end

	self:load_session(path, callback)
end

--- Session `continue` would resume, nil (and a notification) when there is
--- none.
---@private
---@return string?
function Chat:_continue_path()
	-- The live session is skipped while it is still the untouched one pi
	-- created at startup. Once a session has been resumed it is the most
	-- recent one, and continuing again has to land on it, not before it.
	local session = require("crust.sessions").last({
		exclude = not self._resumed and self._session.file or nil,
	})

	-- Nothing to continue is not a problem: the chat stays on the fresh
	-- session pi created, so there is nothing to report either.
	return session and session.path or nil
end

--- Start a fresh session in this chat, wiping the panel.
--- The previous session stays on disk and can be resumed from the picker.
---@param callback? fun(ok: boolean, err: string?)
function Chat:new_session(callback)
	if not self:_ensure_running() then
		if callback then
			callback(false, "pi process is not running")
		end
		return
	end

	---@param message string
	local function fail(message)
		self._output:error(message)
		if callback then
			callback(false, message)
		end
	end

	-- The session pi is leaving is recorded as the parent of the new one.
	local parent = self._session.file

	local _, err = self._pi:send(Command.new_session(parent), function(event)
		if event.success == false then
			return fail(event.error or "failed to start a new session")
		end

		-- A new session is the live one again, so `continue` may resume the
		-- session it was started from.
		self._resumed = false
		self:clear()
		self._input:clear()
		self:refresh_session()
		if callback then
			callback(true)
		end
	end)

	if err then
		fail(err)
	end
end

--- Open the whole conversation in an ordinary buffer.
---
--- The panel only ever holds the messages around the cursor, so searching,
--- yanking or writing out the full transcript needs a buffer of its own.
---@return integer buf
function Chat:transcript()
	local lines = self._output:lines()

	local buf = vim.api.nvim_create_buf(true, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
	vim.bo[buf].filetype = "markdown"
	pcall(vim.api.nvim_buf_set_name, buf, "crust://transcript/" .. (self._session.id or self._id))

	vim.cmd("tabnew")
	vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)

	return buf
end

--- Pick a past session and load it. The picker can also delete sessions.
function Chat:sessions()
	require("crust.sessions.picker").select({
		---@param paths string[]
		on_delete = function(paths)
			self:_on_sessions_deleted(paths)
		end,
	}, function(session)
		if session then
			self:load_session(session.path)
		end
	end)
end

--- Leave the live session when it is one of the deleted files: pi would keep
--- writing to a `.jsonl` that no longer exists, so a fresh one is started.
---@private
---@param paths string[]
function Chat:_on_sessions_deleted(paths)
	local current = self._session.file
	if not current then
		return
	end

	current = vim.fs.normalize(current)
	for _, path in ipairs(paths) do
		if vim.fs.normalize(path) == current then
			-- The file is gone, so it cannot be the parent of the new session.
			self._session.file = nil
			self:new_session()
			return
		end
	end
end

--- Rename the current session. Prompts when `name` is omitted.
---@param name? string
---@param callback? fun(ok: boolean, err: string?)
function Chat:rename(name, callback)
	if not self:_ensure_running() then
		if callback then
			callback(false, "pi process is not running")
		end
		return
	end

	if name == nil then
		self:refresh_session(function(session)
			vim.ui.input({ prompt = "Session name: ", default = session.name or "" }, function(value)
				if value and vim.trim(value) ~= "" then
					self:rename(vim.trim(value), callback)
				end
			end)
		end)
		return
	end

	local _, err = self._pi:send(Command.set_session_name(name), function(event)
		if event.success == false then
			local message = event.error or "failed to rename session"
			self._output:error(message)
			if callback then
				callback(false, message)
			end
			return
		end

		self._session.name = name
		self:_refresh_title()
		if callback then
			callback(true)
		end
	end)

	if err then
		self._output:error(err)
		if callback then
			callback(false, err)
		end
	end
end

---@private
---@param event Crust.Pi.Event
function Chat:_on_event(event)
	-- Every state answer carries the session, whoever asked for it.
	if event.type == "response" and event.command == "get_state" and type(event.data) == "table" then
		local data = event.data --[[@as Crust.Pi.Data.State]]
		self._session = { id = data.sessionId, name = data.sessionName, file = data.sessionFile }
		self:_refresh_title()
	end

	if event.type == "agent_start" then
		self._streaming = true
		self._output:header(require("crust.config").get().labels.agent, Highlights.AGENT_TITLE)
		self._status:set(require("crust.config").get().status_text)
	elseif event.type == "agent_end" then
		self._streaming = false
		self._status:clear()
		self._output:append("\n")
	elseif event.type == "message_update" then
		local ev = event.assistantMessageEvent
		if ev and ev.type == "text_delta" and ev.delta then
			self._output:append(ev.delta)
		end
	elseif Tools.handles(event.type) then
		self._tools:render(self._output, event)
	elseif event.type == "_stderr" then
		self._output:error(tostring(event.message))
	elseif event.type == "_process_exit" then
		self._streaming = false
		self._status:clear()
		self._output:error("pi exited (" .. tostring(event.code) .. ")")
	end
end

return Chat
