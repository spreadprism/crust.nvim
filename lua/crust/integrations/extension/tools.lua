--- The tools the bundled pi extension exposes to the LLM.
---
--- This is the only place a tool is declared. `M.manifest()` hands pi a json
--- description of every tool (name, description, json-schema parameters) at
--- startup, pi registers them dynamically, and every call comes back through
--- `M.call(name, args)`. Adding or changing a tool means editing `TOOLS`
--- below — `extensions/nvim.ts` never has to change.
---
--- A handler receives the decoded arguments table and returns a json string
--- (or a table, which is encoded for it).

---@class Crust.Integrations.Extension.Tool
---@field name string tool name as the LLM sees it
---@field label? string short label for the chat ui
---@field description string what the tool does
---@field parameters? table json schema of the arguments, object at the top
---@field promptSnippet? string one-line hint for the system prompt
---@field promptGuidelines? string[] usage guidelines for the system prompt
---@field context? boolean also inject the result before every turn
---@field handler fun(args: table): string|table

---@class Crust.Integrations.Extension.Tools
local M = {}

local Context = require("crust.integrations.extension.context")
local Lsp = require("crust.integrations.extension.lsp")

--- Json schema for a tool that takes no arguments.
---@return table
local function no_params()
	return { type = "object", properties = vim.empty_dict() }
end

---@type Crust.Integrations.Extension.Tool[]
local TOOLS = {
	{
		name = "nvim_context",
		label = "Neovim Context",
		description = "Current neovim state: cwd, listed buffers, the file the user is working in and the cursor position.",
		promptSnippet = "Inspect the current neovim editor state",
		promptGuidelines = {
			"Use nvim_context when the user says 'this file', 'here' or 'the current buffer'.",
		},
		context = true,
		parameters = no_params(),
		handler = function()
			return Context.ctx()
		end,
	},
	{
		name = "nvim_diagnostics",
		label = "Neovim Diagnostics",
		description = "Diagnostics from the language servers of this neovim instance, for one file or for every loaded buffer.",
		promptSnippet = "Read language server diagnostics from neovim",
		promptGuidelines = {
			"Use nvim_diagnostics after editing code to see what the user's language servers report.",
		},
		parameters = {
			type = "object",
			properties = {
				path = { type = "string", description = "File to report on; omit for every loaded buffer" },
			},
		},
		handler = function(args)
			return Lsp.diagnostics(args.path)
		end,
	},
}

---@param name string
---@return Crust.Integrations.Extension.Tool?
local function find(name)
	for _, tool in ipairs(TOOLS) do
		if tool.name == name then
			return tool
		end
	end
	return nil
end

--- Every tool, as the json manifest pi registers at startup.
---@return string json
function M.manifest()
	local manifest = {}
	for _, tool in ipairs(TOOLS) do
		manifest[#manifest + 1] = {
			name = tool.name,
			label = tool.label,
			description = tool.description,
			parameters = tool.parameters or no_params(),
			promptSnippet = tool.promptSnippet,
			promptGuidelines = tool.promptGuidelines,
			context = tool.context or nil,
		}
	end
	return vim.json.encode(manifest)
end

--- Run one tool. Arguments arrive as a json object string from pi; failures
--- come back as `{"error": "..."}` instead of raising, so a broken tool never
--- kills the turn.
---@param name string
---@param args? string json object
---@return string json
function M.call(name, args)
	local tool = find(name)
	if not tool then
		return vim.json.encode({ error = "unknown tool: " .. tostring(name) })
	end

	local decoded = {}
	if type(args) == "string" and args ~= "" then
		local ok, parsed = pcall(vim.json.decode, args)
		if not ok then
			return vim.json.encode({ error = "invalid arguments: " .. tostring(parsed) })
		end
		if type(parsed) == "table" then
			decoded = parsed
		end
	end

	local ok, result = pcall(tool.handler, decoded)
	if not ok then
		return vim.json.encode({ error = tostring(result) })
	end

	if type(result) == "string" then
		return result
	end
	return vim.json.encode(result)
end

return M
