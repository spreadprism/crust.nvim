--- Parsed sessions, kept warm so opening the chat never waits on disk.
---
--- Parsing is the expensive part: every `.jsonl` is read to its last line to
--- find the newest rename. The directory listing is not, so a lookup always
--- re-globs and only reparses the files whose mtime moved. A cache can
--- therefore never go stale, and the usual case after startup is zero reads.
---
--- `M.warm` does the first pass off the startup path and puts an fs_event on
--- the session directory, so later writes are parsed in the background
--- instead of on the next open.

---@class Crust.Sessions.Cache.Entry
---@field dir string session directory this entry describes
---@field files table<string, { modified: integer, session: Crust.Session }> by path
---@field sessions Crust.Session[] newest first, the answer `M.list` hands out
---@field warm boolean whether a full pass has run
---@field watcher uv.uv_fs_event_t? watches `dir`
---@field parent uv.uv_fs_event_t? watches the sessions root until `dir` exists
---@field timer uv.uv_timer_t? debounces the refreshes a watcher asks for

---@class Crust.Sessions.Cache
local M = {}

--- Quiet period before a watched change is reparsed. pi appends a line per
--- message, so a streaming turn would otherwise refresh on every token.
M.DEBOUNCE_MS = 200

---@type table<string, Crust.Sessions.Cache.Entry>
local entries = {}

---@param cwd? string
---@return Crust.Sessions.Cache.Entry
local function entry(cwd)
	local dir = require("crust.sessions").dir(cwd)
	if not entries[dir] then
		entries[dir] = { dir = dir, files = {}, sessions = {}, warm = false }
	end
	return entries[dir]
end

--- Reparse what changed and rebuild the sorted list.
---@param item Crust.Sessions.Cache.Entry
local function refresh(item)
	local Sessions = require("crust.sessions")

	---@type table<string, { modified: integer, session: Crust.Session }>
	local files = {}
	---@type Crust.Session[]
	local sessions = {}

	for _, path in ipairs(vim.fn.glob(item.dir .. "/*.jsonl", false, true)) do
		local modified = vim.fn.getftime(path)
		local known = item.files[path]

		-- Same mtime, same content: the parse from last time still holds.
		local cached = known and known.modified == modified and known.session or nil
		local session = cached or Sessions.parse(path)

		if session then
			files[path] = { modified = modified, session = session }
			sessions[#sessions + 1] = session
		end
	end

	table.sort(sessions, function(a, b)
		return a.modified > b.modified
	end)

	item.files = files
	item.sessions = sessions
	item.warm = true
end

--- Refresh after the writes settle, off the main path.
---@param item Crust.Sessions.Cache.Entry
local function schedule_refresh(item)
	item.timer = item.timer or assert(vim.uv.new_timer())
	item.timer:stop()
	item.timer:start(
		M.DEBOUNCE_MS,
		0,
		vim.schedule_wrap(function()
			refresh(item)
		end)
	)
end

---@param item Crust.Sessions.Cache.Entry
local function watch(item)
	if item.watcher then
		return
	end

	if vim.fn.isdirectory(item.dir) == 0 then
		-- pi creates the directory with the first session of a cwd. Until
		-- then, watch the sessions root and pick it up when it appears.
		local root = vim.fs.dirname(item.dir)
		if item.parent or vim.fn.isdirectory(root) == 0 then
			return
		end

		local parent = vim.uv.new_fs_event()
		if not parent then
			return
		end
		item.parent = parent
		parent:start(
			root,
			{},
			vim.schedule_wrap(function()
				if vim.fn.isdirectory(item.dir) == 1 then
					if item.parent then
						item.parent:stop()
						item.parent = nil
					end
					watch(item)
					schedule_refresh(item)
				end
			end)
		)
		return
	end

	local watcher = vim.uv.new_fs_event()
	if not watcher then
		return
	end
	item.watcher = watcher

	watcher:start(
		item.dir,
		{},
		vim.schedule_wrap(function(err)
			if err then
				M.stop(item.dir)
				return
			end
			schedule_refresh(item)
		end)
	)
end

--- Parse the sessions of `cwd` now and keep them fresh from then on.
--- Safe to call repeatedly; the scan only runs on the first call.
---@param cwd? string
function M.warm(cwd)
	local item = entry(cwd)
	watch(item)

	if item.warm then
		return
	end
	-- Off the startup path: a cold history is a few hundred file reads.
	vim.schedule(function()
		if not item.warm then
			refresh(item)
		end
	end)
end

--- Sessions of `cwd`, newest first. Answered from the cache, with only the
--- files that changed since the last call reparsed.
---@param cwd? string
---@return Crust.Session[]
function M.list(cwd)
	local item = entry(cwd)
	-- A first lookup without `M.warm`, e.g. when `setup` never ran, still
	-- leaves the directory watched from here on.
	watch(item)
	refresh(item)
	return item.sessions
end

--- Cached sessions without touching disk, empty when the warm-up has not
--- finished. For callers that would rather show nothing than block.
---@param cwd? string
---@return Crust.Session[]
function M.cached(cwd)
	return entry(cwd).sessions
end

--- Drop a directory's cache and its watchers, or all of them.
---@param cwd? string nil clears every entry
function M.stop(cwd)
	---@param item Crust.Sessions.Cache.Entry
	local function close(item)
		for _, handle in ipairs({ item.watcher, item.parent, item.timer }) do
			if handle and not handle:is_closing() then
				handle:stop()
				handle:close()
			end
		end
		entries[item.dir] = nil
	end

	if cwd == nil then
		for _, item in pairs(entries) do
			close(item)
		end
		entries = {}
		return
	end

	-- `cwd` may be a cwd or an already-resolved session directory.
	local item = entries[cwd] or entries[require("crust.sessions").dir(cwd)]
	if item then
		close(item)
	end
end

return M
