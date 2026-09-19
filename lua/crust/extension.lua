--- The connection between crust and pi.
---
--- When `config.extension.enabled` is true, crust starts (or reuses) a neovim
--- server socket and passes the bundled pi extension with `-e`. The extension
--- talks back over `nvim --server <socket> --remote-expr`, calling
--- `crust.integrations.extension`, so the LLM sees the editor state without the
--- user having to paste anything.
---
--- Everything here is about the wiring: the socket, the CLI args and the
--- environment. What the LLM can actually call lives in
--- `crust.integrations.extension`.

---@class Crust.Extension
local M = {}

local Tools = require("crust.integrations.extension")

--- Environment variable the bundled extension reads the socket from.
M.SERVER_ENV = "CRUST_NVIM_SERVER"

---@type string?
local socket = nil

--- Repository root of this plugin, derived from this file's own path.
---@return string
local function plugin_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	return vim.fn.fnamemodify(source, ":h:h:h")
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

--- Start the server early so the socket exists before the first chat, and let
--- the tools that need state of their own set it up.
---@param cfg? Crust.Config.Extension
function M.setup(cfg)
	if M.enabled(cfg) then
		M.server(cfg)
		Tools.setup()
	end
end

return M
