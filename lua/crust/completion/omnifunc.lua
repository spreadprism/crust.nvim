--- `completefunc` fallback, so completion works without blink.cmp.
--- Bound on the input buffer and triggered with `<C-x><C-u>`.

---@class Crust.Completion.Omnifunc
local M = {}

local Completion = require("crust.completion")

---@param command Crust.Pi.CommandInfo
---@return table
local function command_item(command)
	return {
		word = "/" .. command.name,
		abbr = "/" .. command.name,
		menu = command.description or command.source,
		kind = command.source,
	}
end

---@param path string
---@param kind "file"|"dir"
---@return table
local function file_item(path, kind)
	return { word = "@" .. path, abbr = "@" .. path, kind = kind }
end

--- See `:help complete-functions`.
---@param findstart integer
---@param base string
---@return integer|table[]
function M.completefunc(findstart, base)
	local line = vim.api.nvim_get_current_line()
	local col = vim.fn.col(".") - 1
	local row = vim.fn.line(".")

	local context = Completion.context(line, col, row)

	if findstart == 1 then
		-- -3 keeps the popup closed without starting a new completion.
		return context and context.col or -3
	end

	if not context then
		return {}
	end

	if context.kind == "command" then
		return Completion.complete_commands(base:gsub("^/", ""), command_item)
	end

	-- Kick off a refresh for the next invocation: completefunc is synchronous
	-- and must answer from the cache.
	require("crust.completion.files").ensure()
	return Completion.complete_files((base:gsub("^@", "")), file_item)
end

--- Wire `completefunc` on a crust input buffer and warm the file cache, so
--- the first `@` already has something to show.
---@param buf integer
function M.attach(buf)
	vim.bo[buf].completefunc = "v:lua.require'crust.completion.omnifunc'.completefunc"
	require("crust.completion.files").ensure()
end

return M
