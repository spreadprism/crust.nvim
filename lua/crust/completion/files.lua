--- Project files behind `@` mentions.
---
--- Listing is streamed, the way snacks.nvim's picker does it
--- (`snacks/picker/source/proc.lua`): `uv.spawn` with a pipe, `read_start`,
--- and each chunk split on newlines with the trailing partial line carried
--- over to the next one. Paths land in the cache as they arrive, so the
--- popup has results while `fd` is still walking, and no tick ever holds the
--- whole output as one string the way `vim.system(...).stdout` does.

---@class Crust.Completion.Files
local M = {}

---@class Crust.Completion.Files.Cache
---@field files string[] grows while the scan runs
---@field map table<string, true>
---@field cwd string
---@field at integer? `vim.uv.hrtime` when the scan finished, nil while running

---@type Crust.Completion.Files.Cache?
local cache = nil

---@class Crust.Completion.Files.Scan
---@field cwd string
---@field handle uv.uv_process_t?
---@field stdout uv.uv_pipe_t?
---@field rest string partial line carried between chunks
---@field stopped boolean
---@field waiting fun(files: string[])[]

---@type table<string, Crust.Completion.Files.Scan>
local scans = {}

--- How long a finished listing is reused, in nanoseconds.
M.TTL_NS = 10e9

--- Upper bound on the paths we keep. The scan is killed once it is reached,
--- so a stray `/` never turns into a runaway process.
M.MAX_FILES = 20000

--- External listers, in order of preference. All of them print one relative
--- path per line and respect ignore files.
---@type string[][]
M.COMMANDS = {
	{ "rg", "--files", "--no-messages", "--color", "never", "-g", "!.git" },
	{ "fd", "--type", "f", "--type", "l", "--color", "never", "-E", ".git" },
	{ "fdfind", "--type", "f", "--type", "l", "--color", "never", "-E", ".git" },
	{ "git", "ls-files", "--cached", "--others", "--exclude-standard" },
}

--- snacks.nvim keeps a tuned fd/fdfind/rg/find invocation and caches which
--- one exists. Its finder itself is a coroutine bound to a live picker, so
--- only the command lookup can be borrowed.
---@return string[]? command
local function snacks_command()
	local ok, source = pcall(require, "snacks.picker.source.files")
	if not ok or type(source.get_cmd) ~= "function" then
		return nil
	end

	local found, cmd, args = pcall(source.get_cmd)
	if not found or type(cmd) ~= "string" then
		return nil
	end

	local command = { cmd }
	vim.list_extend(command, args or {})
	return command
end

--- The listers to try, snacks' own choice first when it is installed.
---@return string[][]
function M.commands()
	local command = snacks_command()
	if not command then
		return M.COMMANDS
	end

	local commands = { command }
	vim.list_extend(commands, M.COMMANDS)
	return commands
end

--- Whether `buf` is a crust input buffer, the only place we complete in.
---@param buf? integer defaults to the current buffer
---@return boolean
function M.is_input_buf(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	return vim.bo[buf].filetype == require("crust.filetypes").input
end

---@param cwd string
local function reset_cache(cwd)
	cache = { files = {}, map = {}, cwd = cwd, at = nil }
end

--- Append one path to the live cache.
---@param path string
---@return boolean room whether more paths fit
local function add(path)
	if path == "" or not cache then
		return true
	end

	if not cache.map[path] then
		cache.map[path] = true
		cache.files[#cache.files + 1] = path
	end
	return #cache.files < M.MAX_FILES
end

---@param cwd string
local function stop(cwd)
	local scan = scans[cwd]
	if not scan or scan.stopped then
		return
	end
	scan.stopped = true

	if scan.stdout and not scan.stdout:is_closing() then
		scan.stdout:read_stop()
		scan.stdout:close()
	end

	-- Same escalation snacks uses: ask nicely, then insist.
	local handle = scan.handle
	if handle and not handle:is_closing() then
		pcall(handle.kill, handle, "sigterm")
		vim.defer_fn(function()
			if not handle:is_closing() then
				pcall(handle.kill, handle, "sigkill")
			end
		end, 200)
	end
end

---@param cwd string
local function finish(cwd)
	local scan = scans[cwd]
	if not scan then
		return
	end
	scans[cwd] = nil

	if cache and cache.cwd == cwd then
		cache.at = vim.uv.hrtime()
	end

	local files = M.list(cwd)
	for _, callback in ipairs(scan.waiting) do
		callback(files)
	end
end

--- Split a chunk into lines, keeping the tail for the next one.
---@param scan Crust.Completion.Files.Scan
---@param data string
---@return boolean room whether more paths fit
local function consume(scan, data)
	local from = 1

	while from <= #data do
		local newline = data:find("\n", from, true)
		if not newline then
			scan.rest = scan.rest .. data:sub(from)
			break
		end

		local line = scan.rest .. data:sub(from, newline - 1)
		scan.rest = ""
		-- rg and fd print "./path" for some invocations.
		line = line:gsub("^%./", "")

		if not add(line) then
			return false
		end
		from = newline + 1
	end

	return true
end

--- Walk the tree ourselves when no lister is installed. Bounded by
--- `MAX_FILES` and skipping the usual noise, so it cannot run away.
---@param cwd string
local function walk(cwd)
	local skip = { [".git"] = true, ["node_modules"] = true, [".venv"] = true, ["target"] = true }
	local dirs = { "" }

	while #dirs > 0 do
		local relative = table.remove(dirs)
		local absolute = relative == "" and cwd or (cwd .. "/" .. relative)

		local ok, iterator = pcall(vim.fs.dir, absolute)
		if ok then
			for name, kind in iterator do
				local path = relative == "" and name or (relative .. "/" .. name)
				if kind == "directory" then
					if not skip[name] and name:sub(1, 1) ~= "." then
						dirs[#dirs + 1] = path
					end
				elseif kind == "file" and not add(path) then
					return
				end
			end
		end
	end
end

---@param cwd string
---@param index integer command to try
---@param commands string[][]
local function spawn(cwd, index, commands)
	local scan = scans[cwd]
	if not scan then
		return
	end

	local command = commands[index]
	if not command then
		walk(cwd)
		return finish(cwd)
	end

	if vim.fn.executable(command[1]) ~= 1 then
		return spawn(cwd, index + 1, commands)
	end

	local stdout = assert(vim.uv.new_pipe())
	scan.stdout = stdout
	scan.rest = ""

	local handle
	handle = vim.uv.spawn(command[1], {
		args = vim.list_slice(command, 2),
		stdio = { nil, stdout, nil },
		cwd = cwd,
		hide = true,
	}, function(code)
		if handle and not handle:is_closing() then
			handle:close()
		end
		vim.schedule(function()
			-- A lister that is installed but unhappy here (no git repo, for
			-- instance) hands over to the next one, unless it already
			-- produced paths.
			if code ~= 0 and not scan.stopped and #M.list(cwd) == 0 then
				return spawn(cwd, index + 1, commands)
			end
			if scan.rest ~= "" then
				add((scan.rest:gsub("^%./", "")))
				scan.rest = ""
			end
			finish(cwd)
		end)
	end)

	if not handle then
		stdout:close()
		return spawn(cwd, index + 1, commands)
	end
	scan.handle = handle

	stdout:read_start(function(err, data)
		if err or not data then
			if not stdout:is_closing() then
				stdout:read_stop()
				stdout:close()
			end
			return
		end

		-- Parsing is cheap, but it must not run in the libuv callback where
		-- vim api calls are forbidden.
		vim.schedule(function()
			if scan.stopped or not consume(scan, data) then
				stop(cwd)
			end
		end)
	end)
end

---@param cwd string
---@return boolean
local function is_fresh(cwd)
	return cache ~= nil and cache.cwd == cwd and cache.at ~= nil and (vim.uv.hrtime() - cache.at) < M.TTL_NS
end

--- Project files as paths relative to the cwd, as known right now. Never
--- blocks, and returns the partial listing while a scan is running.
---@param cwd? string defaults to the current working directory
---@return string[]
function M.list(cwd)
	cwd = cwd or vim.fn.getcwd()
	if cache and cache.cwd == cwd then
		return cache.files
	end
	return {}
end

--- Whether a scan is currently filling the cache.
---@param cwd? string
---@return boolean
function M.scanning(cwd)
	return scans[cwd or vim.fn.getcwd()] ~= nil
end

--- Refresh the listing when it is missing or stale, then call back with the
--- complete list. The callback runs immediately when the cache is fresh.
---@param cwd? string
---@param callback? fun(files: string[])
function M.ensure(cwd, callback)
	cwd = cwd or vim.fn.getcwd()

	if is_fresh(cwd) then
		if callback then
			callback(M.list(cwd))
		end
		return
	end

	local scan = scans[cwd]
	if scan then
		if callback then
			table.insert(scan.waiting, callback)
		end
		return
	end

	scans[cwd] = { cwd = cwd, rest = "", stopped = false, waiting = callback and { callback } or {} }
	reset_cache(cwd)
	spawn(cwd, 1, M.commands())
end

--- Whether `path` is a file or directory of the project.
---@param path string relative path
---@return boolean
function M.exists(path)
	if cache and cache.map[path] then
		return true
	end

	local absolute = vim.fn.fnamemodify(path, ":p")
	return vim.fn.filereadable(absolute) == 1 or vim.fn.isdirectory(absolute) == 1
end

--- Drop the cached listing and stop any running scan.
function M.invalidate()
	for cwd in pairs(scans) do
		stop(cwd)
		scans[cwd] = nil
	end
	cache = nil
end

return M
