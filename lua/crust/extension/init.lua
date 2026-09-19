--- The connection between crust and pi.
---
--- When `config.extension.enabled` is true, crust starts (or reuses) a neovim
--- server socket and passes the bundled pi extension with `-e`. The extension
--- talks back over `nvim --server <socket> --remote-expr`, calling
--- `crust.extension.tools`, so the LLM sees the editor state without the user
--- having to paste anything.
---
--- Everything here is about the wiring: the socket, the CLI args and the
--- environment. What the LLM can actually call lives in
--- `crust.extension.tools`.

---@class Crust.Extension
local M = {}

local Tools = require("crust.extension.tools")

--- Environment variable the bundled extension reads the socket from.
M.SERVER_ENV = "CRUST_NVIM_SERVER"

--- Environment variable holding the path of the one-shot token file. The
--- extension reads it once and deletes it, so the token never sits in the
--- environment of anything pi spawns later (the bash tool included).
M.TOKEN_ENV = "CRUST_NVIM_TOKEN_FILE"

---@type string?
local socket = nil

---@type string?
local token = nil

--- 32 random hex characters, from libuv's csprng when available.
---@return string
local function random()
	local ok, bytes = pcall(function()
		return vim.uv.random(16)
	end)
	if ok and type(bytes) == "string" and #bytes == 16 then
		return (bytes:gsub(".", function(char)
			return string.format("%02x", char:byte())
		end))
	end

	math.randomseed(vim.uv.hrtime() % 2 ^ 31)
	local out = {}
	for index = 1, 32 do
		out[index] = string.format("%x", math.random(0, 15))
	end
	return table.concat(out)
end

--- Secret shared with the bundled extension, generated once per session.
--- Every call into `crust.extension.tools` must carry it, so the socket
--- is useless to anything that did not get the token at startup.
---@return string
function M.token()
	if not token then
		token = random()
	end
	return token
end

--- True when `candidate` is this session's token.
---@param candidate any
---@return boolean
function M.authorized(candidate)
	return type(candidate) == "string" and candidate ~= "" and candidate == M.token()
end

--- Write the token where the extension can pick it up: a fresh file, owner
--- only, deleted by the extension as soon as it has read it.
---@return string? path
local function token_file()
	local path = vim.fn.tempname()
	local ok = pcall(vim.fn.writefile, { M.token() }, path)
	if not ok then
		vim.notify("crust: could not write the extension token file", vim.log.levels.WARN)
		return nil
	end

	pcall(vim.uv.fs_chmod, path, 384) -- 0600
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("crust.extension.token", { clear = false }),
		callback = function()
			-- Normally the extension already deleted it; this covers pi never
			-- starting.
			pcall(vim.fn.delete, path)
		end,
	})

	return path
end

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

	local env = { [M.SERVER_ENV] = server }

	local path = token_file()
	if path then
		env[M.TOKEN_ENV] = path
	end

	return env
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
