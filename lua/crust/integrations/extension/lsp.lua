--- Language server data the bundled pi extension asks neovim for.
---
--- Every function here is called over `--remote-expr` and must return a json
--- string, so the extension can hand the result straight to the model.

---@class Crust.Integrations.Extension.Lsp
local M = {}

--- Resolve a path to a loaded buffer, or nil for "every buffer".
---@param path? string
---@return integer? buf
---@return boolean found false when `path` names no loaded buffer
local function resolve(path)
	if type(path) ~= "string" or path == "" then
		return nil, true
	end

	local buf = vim.fn.bufnr(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
	if buf == -1 then
		return nil, false
	end

	return buf, true
end

--- Diagnostics of one buffer, or of every loaded buffer when `path` is nil.
---@param path? string
---@return string json
function M.diagnostics(path)
	local buf, found = resolve(path)
	if not found then
		return vim.json.encode({ diagnostics = {} })
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
