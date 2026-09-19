--- Session history on disk.
---
--- pi keeps one `.jsonl` per session under
--- `<agent dir>/sessions/<encoded cwd>/`, where the cwd is flattened into
--- `--home-user-project--`. The first line is the session header, later
--- lines carry messages and `session_info` renames.

---@class Crust.Session
---@field path string absolute path of the `.jsonl` file
---@field id string session id from the header
---@field timestamp string ISO timestamp from the header
---@field modified integer file mtime, sessions are sorted by it
---@field name? string display name, set with `set_session_name`
---@field first_message string first user message, trimmed to one line

local M = {}

--- Longest first user message kept for the picker label.
local LABEL_WIDTH = 80

---@return string
function M.agent_dir()
	local dir = require("crust.config").get().sessions.agent_dir
	if type(dir) == "string" and dir ~= "" then
		return vim.fs.normalize(vim.fn.expand(dir))
	end

	local env = vim.env.PI_CODING_AGENT_DIR
	if type(env) == "string" and env ~= "" then
		return vim.fs.normalize(env)
	end

	return vim.fs.normalize("~/.pi/agent")
end

--- Flatten a cwd the way pi names its session directories.
---@param cwd string
---@return string
function M.encode_cwd(cwd)
	local encoded = vim.fs.normalize(cwd):gsub("^[\\/]", ""):gsub("[\\/:]", "-")
	return "--" .. encoded .. "--"
end

--- Directory holding the sessions of `cwd`.
---@param cwd? string defaults to the current working directory
---@return string
function M.dir(cwd)
	return M.agent_dir() .. "/sessions/" .. M.encode_cwd(cwd or vim.fn.getcwd())
end

---@param content string|table|nil
---@return string
local function message_text(content)
	if type(content) == "string" then
		return content
	end
	if type(content) ~= "table" then
		return ""
	end

	for _, part in ipairs(content) do
		if type(part) == "table" and part.type == "text" and part.text then
			return part.text
		end
	end
	return ""
end

--- Read one session file: header, latest name and first user message.
---@param path string
---@return Crust.Session?
function M.parse(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end

	local header_line = file:read("*l")
	local ok, header = pcall(vim.json.decode, header_line or "")
	if not ok or type(header) ~= "table" or header.type ~= "session" then
		file:close()
		return nil
	end

	local first_message, name = "", nil ---@type string, string?
	for line in file:lines() do
		local decoded, entry = pcall(vim.json.decode, line)
		if decoded and type(entry) == "table" then
			-- A session can be renamed repeatedly, the last name wins.
			if entry.type == "session_info" and type(entry.name) == "string" and entry.name ~= "" then
				name = vim.trim(entry.name)
			end
			if first_message == "" and entry.type == "message" then
				local message = entry.message
				if type(message) == "table" and message.role == "user" then
					first_message = message_text(message.content)
				end
			end
		end
	end
	file:close()

	return {
		path = path,
		id = header.id or "",
		timestamp = header.timestamp or "",
		modified = vim.fn.getftime(path),
		name = name,
		first_message = vim.trim(first_message:gsub("%s+", " ")):sub(1, LABEL_WIDTH),
	}
end

--- Sessions of `cwd`, newest first.
---@param cwd? string
---@return Crust.Session[]
function M.list(cwd)
	---@type Crust.Session[]
	local sessions = {}

	for _, path in ipairs(vim.fn.glob(M.dir(cwd) .. "/*.jsonl", false, true)) do
		local info = M.parse(path)
		if info then
			sessions[#sessions + 1] = info
		end
	end

	table.sort(sessions, function(a, b)
		return a.modified > b.modified
	end)
	return sessions
end

---@class Crust.Sessions.LastOpts
---@field cwd? string
---@field exclude? string session file to skip, usually the live one

--- Most recently touched session, the one `--continue` would pick.
---@param opts? Crust.Sessions.LastOpts
---@return Crust.Session?
function M.last(opts)
	opts = opts or {}
	local exclude = opts.exclude and vim.fs.normalize(opts.exclude) or nil

	for _, session in ipairs(M.list(opts.cwd)) do
		if not exclude or vim.fs.normalize(session.path) ~= exclude then
			return session
		end
	end
	return nil
end

--- Whether `cwd` has a session known by id, name or file stem.
---@param session string
---@param cwd? string
---@return boolean
function M.exists(session, cwd)
	if type(session) ~= "string" or session == "" then
		return false
	end

	for _, entry in ipairs(M.list(cwd)) do
		if entry.id == session or entry.name == session or vim.fn.fnamemodify(entry.path, ":t:r") == session then
			return true
		end
	end
	return false
end

--- Remove a session file from disk.
---@param path string
---@return boolean ok
---@return string? err
function M.delete(path)
	local ok, err = os.remove(path)
	if not ok then
		return false, err or ("cannot delete " .. path)
	end
	return true
end

--- Human label for a session: its name, else its first message.
---@param session Crust.Session
---@return string
function M.label(session)
	if session.name and session.name ~= "" then
		return session.name
	end
	if session.first_message ~= "" then
		return session.first_message
	end
	return "(empty session)"
end

--- Date part of the session timestamp, for picker columns.
---@param session Crust.Session
---@return string
function M.date(session)
	return session.timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)") or session.timestamp
end

return M
