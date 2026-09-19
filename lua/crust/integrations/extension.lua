--- Optional integration that hands pi a view of this neovim instance.
---
--- When `config.extension.enabled` is true, crust starts (or reuses) a neovim
--- server socket and passes a bundled pi extension with `-e`. The extension
--- talks back over `nvim --server <socket> --remote-expr`, calling the functions
--- below, so the LLM sees the editor state without the user having to paste
--- anything.

---@class Crust.Integrations.Extension
local M = {}

--- Environment variable the bundled extension reads the socket from.
M.SERVER_ENV = "CRUST_NVIM_SERVER"

---@type string?
local socket = nil

--- Repository root of this plugin, derived from this file's own path.
---@return string
local function plugin_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	return vim.fn.fnamemodify(source, ":h:h:h:h")
end

---@param cfg? Crust.Config.Extension defaults to `config.get().extension`
---@return Crust.Config.Extension
local function options(cfg)
	return cfg or require("crust.config").get().extension
end

---@param cfg? Crust.Config.Extension
---@return boolean
function M.enabled(cfg)
	cfg = options(cfg)
	return require("crust.config").enabled(cfg.enabled)
end

--- Path of the pi extension handed to `-e`, or nil when it is missing.
---@param cfg? Crust.Config.Extension
---@return string?
function M.path(cfg)
	cfg = options(cfg)

	local path = cfg.path or (plugin_root() .. "/extensions/nvim.ts")
	path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
	if vim.fn.filereadable(path) == 1 then
		return path
	end

	vim.notify("crust: pi extension not found: " .. path, vim.log.levels.WARN)
	return nil
end

--- Address of the neovim socket the extension connects back to.
--- Reuses `--listen`/`v:servername` when nvim already has one, otherwise starts
--- a server on first call and keeps it for the rest of the session.
---@param cfg? Crust.Config.Extension
---@return string?
function M.server(cfg)
	cfg = options(cfg)

	if type(cfg.server) == "string" and cfg.server ~= "" then
		return cfg.server
	end

	if socket and vim.fn.filereadable(socket) == 0 and vim.fn.executable(socket) == 0 then
		-- A pipe disappears when the server is stopped, start a fresh one.
		socket = nil
	end

	if socket then
		return socket
	end

	if vim.v.servername ~= "" then
		socket = vim.v.servername
		return socket
	end

	local ok, address = pcall(vim.fn.serverstart)
	if not ok or address == "" then
		vim.notify("crust: could not start a neovim server for the nvim extension integration", vim.log.levels.WARN)
		return nil
	end

	socket = address
	return socket
end

--- Extra pi CLI args, empty when the integration is off or unusable.
---@param cfg? Crust.Config.Extension
---@return string[] args
function M.args(cfg)
	if not M.enabled(cfg) then
		return {}
	end

	local path = M.path(cfg)
	if not path then
		return {}
	end

	return { "-e", path }
end

--- Environment for the pi process, empty when the integration is off.
---@param cfg? Crust.Config.Extension
---@return table<string, string> env
function M.env(cfg)
	if not M.enabled(cfg) then
		return {}
	end

	local server = M.server(cfg)
	if not server then
		return {}
	end

	return { [M.SERVER_ENV] = server }
end

--- Start the server early so the socket exists before the first chat.
---@param cfg? Crust.Config.Extension
function M.setup(cfg)
	if M.enabled(cfg) then
		M.server(cfg)
	end
end

---@param buf integer
---@return table
local function buffer_info(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	return {
		buf = buf,
		path = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or nil,
		filetype = vim.bo[buf].filetype,
		modified = vim.bo[buf].modified,
		lines = vim.api.nvim_buf_line_count(buf),
	}
end

--- Everything the extension injects as context: cwd, listed buffers, and the
--- cursor position of the window the user was last in.
---@return string json
function M.snapshot()
	local buffers = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
			buffers[#buffers + 1] = buffer_info(buf)
		end
	end

	local win = vim.api.nvim_get_current_win()
	local cursor = vim.api.nvim_win_get_cursor(win)
	local current = vim.api.nvim_win_get_buf(win)

	return vim.json.encode({
		cwd = vim.fn.getcwd(),
		current = buffer_info(current),
		cursor = { line = cursor[1], col = cursor[2] + 1 },
		buffers = buffers,
	})
end

--- Diagnostics of one buffer, or of every loaded buffer when `path` is nil.
---@param path? string
---@return string json
function M.diagnostics(path)
	local buf = nil
	if type(path) == "string" and path ~= "" then
		buf = vim.fn.bufnr(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
		if buf == -1 then
			return vim.json.encode({ diagnostics = {} })
		end
	end

	local items = {}
	for _, diagnostic in ipairs(vim.diagnostic.get(buf)) do
		items[#items + 1] = {
			path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(diagnostic.bufnr), ":~:."),
			line = diagnostic.lnum + 1,
			col = diagnostic.col + 1,
			severity = vim.diagnostic.severity[diagnostic.severity],
			source = diagnostic.source,
			message = diagnostic.message,
		}
	end

	return vim.json.encode({ diagnostics = items })
end

return M
