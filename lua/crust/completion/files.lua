--- Project files behind `@` mentions.
---
--- `git ls-files` with a glob fallback, cached per cwd for a short while:
--- completion asks for the list on every keystroke, and the process is only
--- paid for once per burst.

---@class Crust.Completion.Files
local M = {}

---@class Crust.Completion.Files.Cache
---@field files string[]
---@field map table<string, true>
---@field cwd string
---@field at integer `vim.uv.hrtime` of the listing

---@type Crust.Completion.Files.Cache?
local cache = nil

--- How long a listing is reused, in nanoseconds.
local TTL_NS = 5e9

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
---@return string[]?
local function git_files(cwd)
	local result = vim
		.system({ "git", "ls-files", "--cached", "--others", "--exclude-standard" }, { text = true, cwd = cwd })
		:wait()

	if result.code ~= 0 or not result.stdout or result.stdout == "" then
		return nil
	end
	return vim.split(vim.trim(result.stdout), "\n", { plain = true, trimempty = true })
end

---@return string[]
local function globbed_files()
	local files = {}
	for _, path in ipairs(vim.fn.glob("**/*", false, true)) do
		if vim.fn.isdirectory(path) == 0 then
			files[#files + 1] = path
		end
	end
	return files
end

--- Project files as paths relative to the cwd.
---@param cwd? string defaults to the current working directory
---@return string[]
function M.list(cwd)
	cwd = cwd or vim.fn.getcwd()

	local now = vim.uv.hrtime()
	if cache and cache.cwd == cwd and (now - cache.at) < TTL_NS then
		return cache.files
	end

	local files = git_files(cwd) or globbed_files()

	local map = {}
	for _, path in ipairs(files) do
		map[path] = true
	end

	cache = { files = files, map = map, cwd = cwd, at = now }
	return files
end

--- Whether `path` is a file or directory of the project.
---@param path string relative path
---@return boolean
function M.exists(path)
	M.list()
	if cache and cache.map[path] then
		return true
	end

	local absolute = vim.fn.fnamemodify(path, ":p")
	return vim.fn.filereadable(absolute) == 1 or vim.fn.isdirectory(absolute) == 1
end

--- Drop the cached listing, e.g. after writing a new file.
function M.invalidate()
	cache = nil
end

return M
