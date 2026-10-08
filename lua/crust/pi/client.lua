---@class Crust.Pi.Opts
---@field bin? string pi executable (default "pi")
---@field model? string
---@field args? string[] extra CLI args, "--mode rpc" is always appended
---@field cwd? string working directory for the process
---@field on_event? fun(event: Crust.Pi.Event) called for every decoded rpc event
---@field log? boolean|string false disables the transcript, a string names the session
---@field prompt? Crust.Config.Prompt system prompt overrides, defaults to `config.prompt`
---@field context? Crust.Config.Context context overrides, defaults to `config.context`
---@field extension? Crust.Config.Extension neovim integration overrides, defaults to `config.extension`

---@class Crust.Pi.Trace.Entry one line of raw traffic, as it crossed the pipe
---@field kind Crust.Pi.Trace.Kind
---@field text string undecoded payload
---@field time integer epoch milliseconds

---@alias Crust.Pi.Trace.Kind
---| "spawn" the command line the process was started with
---| "sent" an rpc command written to stdin
---| "received" a line read from stdout, decoded or not
---| "stderr" a line pi wrote to stderr
---| "exit" the process died

---@class Crust.Pi Pi instance process that manages everything
---@field opts Crust.Pi.Opts
---@field job_id integer?
---@field private _pending table<string, fun(event: Crust.Pi.Event)>
---@field private _req_id integer
---@field private _stdout_buf string
---@field private _log Crust.Log?
---@field private _trace Crust.Pi.Trace.Entry[] ring of raw traffic, for `crust.debug`
local Pi = {}
Pi.__index = Pi

local Command = require("crust.pi.rpc")
local Errors = require("crust.pi.errors")
local Log = require("crust.log")
local Extension = require("crust.extension")
local Prompt = require("crust.prompt")
local Sessions = require("crust.sessions")

local PING_TIMEOUT_MS = 5000

---@param opts? Crust.Pi.Opts
---@return Crust.Pi
function Pi.new(opts)
	local self = setmetatable({}, Pi)
	local cfg = require("crust.config").get()

	---@type Crust.Pi.Opts
	local defaults = {
		bin = cfg.bin,
		cwd = vim.fn.getcwd(),
	}
	self.opts = vim.tbl_deep_extend("force", defaults, opts or {})

	self.job_id = nil
	self._pending = {}
	self._req_id = 0
	self._stdout_buf = ""
	self._trace = {}

	local log_opt = self.opts.log
	if log_opt ~= false and cfg.log.enabled then
		self._log = Log.new(type(log_opt) == "string" and log_opt or nil)
	end

	return self
end

--- Transcript of this process' rpc traffic, when logging is enabled.
---@return Crust.Log?
function Pi:log()
	return self._log
end

--- Raw traffic of this process, oldest first.
---
--- Always recorded, unlike the on-disk log: a failure worth debugging is
--- usually noticed after it happened, when turning logging on and
--- reproducing it is the expensive way to look. The ring is capped by
--- `config.debug.history`, so an endless session cannot grow it.
---@return Crust.Pi.Trace.Entry[]
function Pi:trace()
	return self._trace
end

--- Drop the recorded traffic.
function Pi:clear_trace()
	self._trace = {}
end

---@private
---@param kind Crust.Pi.Trace.Kind
---@param text string
function Pi:_record(kind, text)
	local secs, usecs = vim.uv.gettimeofday()
	self._trace[#self._trace + 1] = {
		kind = kind,
		text = text,
		time = secs * 1000 + math.floor(usecs / 1000),
	}

	local limit = require("crust.config").get().debug.history
	local excess = #self._trace - limit
	if excess > 0 then
		-- Keeping the tail: the lines near a failure are the ones that
		-- explain it.
		self._trace = vim.list_slice(self._trace, excess + 1)
	end
end

---@private
---@return string[]
function Pi:_command()
	local cmd = { self.opts.bin }
	vim.list_extend(cmd, self.opts.args or {})
	if self.opts.model then
		vim.list_extend(cmd, { "--model", self.opts.model })
	end
	vim.list_extend(cmd, Prompt.args(self.opts.prompt))
	vim.list_extend(cmd, Prompt.context_args(self.opts.context))
	vim.list_extend(cmd, Extension.args(self.opts.extension))
	vim.list_extend(cmd, { "--mode", "rpc" })
	return cmd
end

--- Extra environment for the pi process, merged with nvim's own.
---@private
---@return table<string, string>?
function Pi:_env()
	local env = Extension.env(self.opts.extension)
	return next(env) and env or nil
end

---@return boolean running
function Pi:is_running()
	return self.job_id ~= nil
end

--- Start the pi process in rpc mode.
---@return boolean ok
---@return string? err
function Pi:connect()
	if self.job_id then
		return true
	end

	self._stdout_buf = ""

	local command = self:_command()
	self:_record("spawn", table.concat(command, " ") .. "  (cwd: " .. tostring(self.opts.cwd) .. ")")

	local started, job_id = pcall(vim.fn.jobstart, command, {
		cwd = self.opts.cwd,
		env = self:_env(),
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, data)
			self:_on_stdout(data)
		end,
		on_stderr = function(_, data)
			self:_on_stderr(data)
		end,
		on_exit = function(job, code)
			self:_on_exit(code, job)
		end,
	})

	if not started then
		return false, tostring(job_id)
	end

	if job_id <= 0 then
		return false, "failed to start '" .. (self.opts.bin or "pi") .. "' (jobstart returned " .. job_id .. ")"
	end

	self.job_id = job_id

	-- Learn the session id so the transcript gets pi's own name.
	if self._log then
		self:send(Command.get_state())
	end

	return true
end

--- Stop the pi process and drop pending requests.
function Pi:close()
	if self.job_id then
		vim.fn.jobstop(self.job_id)
		self.job_id = nil
	end
	self._stdout_buf = ""
	self._pending = {}
	if self._log then
		-- pi only persists a session once it has something to store, so a
		-- transcript without one is just handshake noise.
		if Sessions.exists(self._log:session(), self.opts.cwd) then
			self._log:close()
		else
			self._log:remove()
		end
	end
end

--- Send an rpc command. Returns the request id on success.
---@param command Crust.Pi.Command built with `require("crust.pi.rpc")`
---@param callback? fun(event: Crust.Pi.Response) called with the matching response
---@return string? id
---@return string? err
function Pi:send(command, callback)
	if not Command.is(command) then
		return nil, "expected a Crust.Pi.Command, see crust.pi.rpc"
	end

	if not self.job_id then
		return nil, "pi process is not running"
	end

	if not command.id then
		self._req_id = self._req_id + 1
		command.id = "crust:" .. self._req_id
	end

	if callback then
		self._pending[command.id] = callback
	end

	local payload = command:encode()
	self:_record("sent", payload)
	if self._log then
		self._log:sent(payload)
	end

	vim.fn.chansend(self.job_id, payload .. "\n")
	return command.id
end

--- Round-trip check that the process answers rpc commands.
--- Async when `callback` is given, otherwise blocks until answer or timeout.
---@param callback? fun(ok: boolean, err: string?)
---@param timeout_ms? integer default 5000
---@return boolean? ok nil when async
---@return string? err
function Pi:ping(callback, timeout_ms)
	timeout_ms = timeout_ms or PING_TIMEOUT_MS

	if not self.job_id then
		local err = "pi process is not running"
		if callback then
			callback(false, err)
			return
		end
		return false, err
	end

	local done, ok, err = false, false, nil ---@type boolean, boolean, string?

	local function finish(success, message)
		if done then
			return
		end
		done, ok, err = true, success, message
		if callback then
			callback(success, message)
		end
	end

	local id = self:send(Command.get_state(), function(event)
		if event.success == false then
			finish(false, event.error or "pi returned an error response")
		else
			finish(true)
		end
	end)

	if not id then
		finish(false, "failed to send ping")
		if callback then
			return
		end
		return ok, err
	end

	local timer = vim.defer_fn(function()
		self._pending[id] = nil
		finish(false, "ping timed out after " .. timeout_ms .. "ms")
	end, timeout_ms)

	if callback then
		return
	end

	vim.wait(timeout_ms + 50, function()
		return done
	end, 20)

	pcall(function()
		timer:stop()
	end)

	if not done then
		self._pending[id] = nil
		return false, "ping timed out after " .. timeout_ms .. "ms"
	end

	return ok, err
end

--- Rename the transcript once pi reports its own session id.
---@private
---@param event Crust.Pi.Event
function Pi:_adopt_session(event)
	if not self._log then
		return
	end
	local data = event.data --[[@as Crust.Pi.Data.State?]]
	local session = data and (data.sessionName or data.sessionId)
	if type(session) == "string" and session ~= "" then
		self._log:set_session(session)
	end
end

---@private
---@param event Crust.Pi.Event
function Pi:_dispatch(event)
	if type(event) ~= "table" or not event.type then
		return
	end

	if self.opts.on_event then
		self.opts.on_event(event)
	end

	local cb = event.id and self._pending[event.id]
	if cb then
		self._pending[event.id] = nil
		cb(event)
	end
end

---@private
---@param data string[]?
function Pi:_on_stdout(data)
	if not data then
		return
	end

	data[1] = self._stdout_buf .. data[1]
	self._stdout_buf = data[#data]

	for i = 1, #data - 1 do
		local line = data[i]
		if line ~= "" then
			self:_record("received", line)
			if self._log then
				self._log:received(line)
			end
			local ok, event = pcall(vim.json.decode, line)
			if ok then
				self:_adopt_session(event)
				self:_dispatch(event)
			end
		end
	end
end

---@private
---@param data string[]?
function Pi:_on_stderr(data)
	if not data then
		return
	end

	-- A provider error is one json body wrapped over several lines; the
	-- halves are useless apart, so they are dispatched as one message.
	for _, line in ipairs(Errors.join(data)) do
		self:_record("stderr", line)
		self:_dispatch({ type = "_stderr", message = line })
	end
end

---@private
---@param code integer
---@param job? integer the job that exited, as reported by nvim
function Pi:_on_exit(code, job)
	-- A process that was already replaced, e.g. after a forced restart: its
	-- death says nothing about the one running now.
	if job and self.job_id and job ~= self.job_id then
		return
	end

	self.job_id = nil
	self._stdout_buf = ""
	self._pending = {}
	self:_record("exit", "pi exited with " .. tostring(code))
	self:_dispatch({ type = "_process_exit", code = code })
end

return Pi
