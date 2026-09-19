--- `nvim_diagnostics`: what the language servers of this neovim instance
--- report, for one file or for every loaded buffer.
---
--- Returns an array of tools; see `crust.integrations.extension`.

---@class Crust.Diagnostics.Item
---@field path string `:~:.` path of the file
---@field line integer 1-based
---@field col integer 1-based
---@field severity string ERROR, WARN, INFO or HINT
---@field source string? language server that reported it
---@field message string

---@class Crust.Diagnostics
---@field scope string the requested path, or "workspace"
---@field diagnostics Crust.Diagnostics.Item[]

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

--- Diagnostics of one buffer, or of the whole workspace when `path` is nil.
---@param path? string
---@return Crust.Diagnostics
local function diagnostics(path)
	local scope = (type(path) == "string" and path ~= "") and path or "workspace"

	local buf, found = resolve(path)
	if not found then
		return { scope = scope, diagnostics = {} }
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

	return { scope = scope, diagnostics = items }
end

---@type Crust.Integrations.Extension.Tool[]
return {
	{
		name = "nvim_diagnostics",
		label = "Neovim Diagnostics",
		description = "Diagnostics from the language servers of this neovim instance. Without `path`, every loaded buffer in the workspace; with `path`, only that file.",
		promptSnippet = "Read language server diagnostics from neovim",
		promptGuidelines = {
			"Use nvim_diagnostics after editing code to see what the user's language servers report.",
		},
		parameters = {
			type = "object",
			properties = {
				path = {
					type = "string",
					description = "Optional file to report on; omit for the whole workspace",
				},
			},
			required = {},
			additionalProperties = false,
		},
		context = true,
		handler = function(args)
			return diagnostics(args.path)
		end,
	},
}
