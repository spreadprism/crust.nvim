--- The tools the bundled pi extension exposes to the LLM.
---
--- `M.manifest()` hands pi a json description of every tool (name, description,
--- json-schema parameters) at startup, pi registers them dynamically, and every
--- call comes back through `M.call(name, args)`. `extensions/nvim.ts` knows
--- nothing about the individual tools, so adding one is a lua-only change.
---
--- A tool is declared in one of the sibling modules listed in `SOURCES`, each
--- of which returns nothing but an array of tools. This file only gathers them.
--- The connection to pi itself lives in `crust.extension`.

---@class Crust.Integrations.Extension.Tool
---@field name string tool name as the LLM sees it
---@field label? string short label for the chat ui
---@field description string what the tool does
---@field parameters? table json schema of the arguments, object at the top
---@field promptSnippet? string one-line hint for the system prompt
---@field promptGuidelines? string[] usage guidelines for the system prompt
---@field context? boolean also inject the result before every turn
---@field setup? fun() state the tool needs, run once from `crust.extension`
---@field handler fun(args: table): table the result, encoded as json for pi

---@class Crust.Integrations.Extension
local M = {}

--- Sibling modules that each return a `Crust.Integrations.Extension.Tool[]`.
---@type string[]
local SOURCES = {
	"context",
	"lsp",
}

---@type Crust.Integrations.Extension.Tool[]
local TOOLS = {}
for _, source in ipairs(SOURCES) do
	vim.list_extend(TOOLS, require("crust.integrations.extension." .. source))
end

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

--- Run the `setup` of every tool that has one. Called by `crust.extension`.
function M.setup()
	for _, tool in ipairs(TOOLS) do
		if tool.setup then
			tool.setup()
		end
	end
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
			parameters = tool.parameters or { type = "object", properties = vim.empty_dict() },
			promptSnippet = tool.promptSnippet,
			promptGuidelines = tool.promptGuidelines,
			context = tool.context or nil,
		}
	end
	return vim.json.encode(manifest)
end

--- Run one tool. Arguments arrive as a json object string from pi and the
--- handler's table goes back as json; failures come back as
--- `{"error": "..."}` instead of raising, so a broken tool never kills the
--- turn.
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

	return vim.json.encode(result)
end

return M
