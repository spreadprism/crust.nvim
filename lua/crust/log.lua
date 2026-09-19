--- Raw rpc transcript logging.
---
--- One file per session under `config.log.dir`, named
--- `crust-<session>.log`, with one line per message:
---
---   {"type":"prompt",...} 2024-03-07T09:05:11.412
---   {"type":"response",...} 2024-03-07T09:05:11.930

---@class Crust.Log
---@field private _dir string
---@field private _session string
---@field private _path string?
---@field private _file file*?
local Log = {}
Log.__index = Log

---@param session? string defaults to a timestamped name
---@param dir? string defaults to `config.log.dir`
---@return Crust.Log
function Log.new(session, dir)
	local self = setmetatable({}, Log)
	self._dir = dir or require("crust.config").get().log.dir
	self._session = session or tostring(os.date("%Y%m%d-%H%M%S"))
	self._path = nil
	self._file = nil
	return self
end

--- Strip path separators so a session id can never escape the log dir.
---@param session string
---@return string
local function sanitize(session)
	return (session:gsub("[^%w%-%._]", "_"))
end

---@return string
function Log:session()
	return self._session
end

---@return string
function Log:path()
	return self._dir .. "/crust-" .. sanitize(self._session) .. ".log"
end

---@private
---@return file*?
function Log:_open()
	if self._file then
		return self._file
	end

	vim.fn.mkdir(self._dir, "p")
	local path = self:path()
	local file, err = io.open(path, "a")
	if not file then
		vim.notify("crust: cannot write " .. path .. ": " .. tostring(err), vim.log.levels.WARN)
		return nil
	end

	self._path = path
	self._file = file
	return file
end

---@return string
local function now()
	local secs, usecs = vim.uv.gettimeofday()
	return string.format("%s.%03d", os.date("%Y-%m-%dT%H:%M:%S", secs), math.floor(usecs / 1000))
end

--- Append one transcript line.
---@param payload string raw json line
function Log:write(payload)
	local file = self:_open()
	if not file then
		return
	end

	file:write((payload:gsub("%s+$", "")) .. " " .. now() .. "\n")
	file:flush()
end

---@param payload string
function Log:sent(payload)
	self:write(payload)
end

---@param payload string
function Log:received(payload)
	self:write(payload)
end

--- Adopt pi's real session id, moving any lines already written.
---@param session string
function Log:set_session(session)
	if session == self._session then
		return
	end

	local old_path = self._path
	local was_open = self._file ~= nil
	self:close()
	self._session = session

	if old_path and was_open then
		local new_path = self:path()
		if old_path ~= new_path then
			os.rename(old_path, new_path)
		end
	end
end

function Log:close()
	if self._file then
		self._file:close()
		self._file = nil
	end
end

return Log
