--- Optional integration that hands pi a view of this neovim instance.
---
--- When `config.extension.enabled` is true, crust starts (or reuses) a neovim
--- server socket and passes a bundled pi extension with `-e`. The extension
--- talks back over `nvim --server <socket> --remote-expr`, calling the functions
--- below, so the LLM sees the editor state without the user having to paste
--- anything.

---@class Crust.Integrations.Extension
local M = {}

local Context = require("crust.integrations.extension.context")
local Lsp = require("crust.integrations.extension.lsp")
local Tools = require("crust.integrations.extension.tools")

--- Environment variable the bundled extension reads the socket from.
M.SERVER_ENV = "CRUST_NVIM_SERVER"

---@type string?
local socket = nil

--- Repository root of this plugin, derived from this file's own path.
---@return string
local function plugin_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	return vim.fn.fnamemodify(source, ":h:h:h:h:h")
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

--- Start the server early so the socket exists before the first chat, and
--- begin tracking the window the user works in.
---@param cfg? Crust.Config.Extension
function M.setup(cfg)
	if M.enabled(cfg) then
		M.server(cfg)
		Context.setup()
	end
end

--- Editor context: cwd, listed buffers, and the cursor position.
--- Lives in `crust.integrations.extension.context`, re-exported so the
--- extension keeps calling a single module over `--remote-expr`.
---@return string json
function M.ctx()
	return Context.ctx()
end

--- Diagnostics of one buffer, or of every loaded buffer when `path` is nil.
--- Lives in `crust.integrations.extension.lsp`, re-exported the same way.
---@param path? string
---@return string json
function M.diagnostics(path)
	return Lsp.diagnostics(path)
end

--- Json manifest of every tool the extension should register.
--- Declared in `crust.integrations.extension.tools`, which is the only file to
--- touch when adding a tool.
---@return string json
function M.tools()
	return Tools.manifest()
end

--- Run one of the tools from the manifest.
---@param name string
---@param args? string json object of arguments
---@return string json
function M.call(name, args)
	return Tools.call(name, args)
end

return M
