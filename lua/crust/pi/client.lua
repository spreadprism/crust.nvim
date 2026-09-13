---@class Crust.Pi.Opts
---@field bin? string pi executable (default "pi")
---@field model? string
---@field args? string[] extra CLI args, "--mode rpc" is always appended
---@field cwd? string working directory for the process
---@field on_event? fun(event: Crust.Pi.Event) called for every decoded rpc event
---@field log? boolean|string false disables the transcript, a string names the session
---@field prompt? Crust.Config.Prompt system prompt overrides, defaults to `config.prompt`

---@class Crust.Pi Pi instance process that manages everything
---@field opts Crust.Pi.Opts
---@field job_id integer?
---@field private _pending table<string, fun(event: Crust.Pi.Event)>
---@field private _req_id integer
---@field private _stdout_buf string
---@field private _log Crust.Log?
local Pi = {}
Pi.__index = Pi

local Command = require("crust.pi.rpc")
local Log = require("crust.log")
local Prompt = require("crust.prompt")

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

---@private
---@return string[]
function Pi:_command()
	local cmd = { self.opts.bin }
	vim.list_extend(cmd, self.opts.args or {})
	if self.opts.model then
		vim.list_extend(cmd, { "--model", self.opts.model })
	end
	vim.list_extend(cmd, Prompt.args(self.opts.prompt))
	vim.list_extend(cmd, { "--mode", "rpc" })
	return cmd
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

	local started, job_id = pcall(vim.fn.jobstart, self:_command(), {
		cwd = self.opts.cwd,
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, data)
			self:_on_stdout(data)
		end,
		on_stderr = function(_, data)
			self:_on_stderr(data)
		end,
		on_exit = function(_, code)
			self:_on_exit(code)
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
		self._log:close()
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

	for _, line in ipairs(data) do
		if line ~= "" then
			self:_dispatch({ type = "_stderr", message = line })
		end
	end
end

---@private
---@param code integer
function Pi:_on_exit(code)
	self.job_id = nil
	self._stdout_buf = ""
	self._pending = {}
	self:_dispatch({ type = "_process_exit", code = code })
end

return Pi
