--- System prompt assembly for the pi process.
---
--- pi takes `--system-prompt <text>` (replaces its default) and any number of
--- `--append-system-prompt <text>` (appended, text or a file path). Crust adds
--- its own appended block, and the user's additions are concatenated after it.

---@class Crust.Prompt
local M = {}

--- What crust tells pi about its frontend. Disable with
--- `prompt = { include_defaults = false }`.
M.DEFAULT_APPEND = table.concat({
	"Your replies are rendered as markdown, so write them in markdown.",
	"Always tag fenced code blocks with their language so they are highlighted,",
	"for example ```lua instead of a bare fence.",
}, " ")

--- Resolve a value that may be a string, a list of strings, or a function
--- returning either.
---@param value string|string[]|fun(): string|string[]|nil
---@return string[]
function M.resolve(value)
	if type(value) == "function" then
		value = value()
	end

	if type(value) == "string" then
		return value ~= "" and { value } or {}
	end

	if type(value) ~= "table" then
		return {}
	end

	local out = {}
	for _, item in ipairs(value) do
		if type(item) == "string" and item ~= "" then
			out[#out + 1] = item
		end
	end
	return out
end

--- Build the prompt part of the pi command line.
---@param cfg? Crust.Config.Prompt defaults to `config.get().prompt`
---@return string[] args
function M.args(cfg)
	cfg = cfg or require("crust.config").get().prompt

	local args = {}

	local system = M.resolve(cfg.system_prompt)[1]
	if system then
		vim.list_extend(args, { "--system-prompt", system })
	end

	for _, text in ipairs(M.appends(cfg)) do
		vim.list_extend(args, { "--append-system-prompt", text })
	end

	return args
end

--- Crust's own block first, then whatever the user appended.
---@param cfg? Crust.Config.Prompt
---@return string[]
function M.appends(cfg)
	cfg = cfg or require("crust.config").get().prompt

	local appends = {}
	if cfg.include_defaults ~= false then
		appends[#appends + 1] = M.DEFAULT_APPEND
	end
	vim.list_extend(appends, M.resolve(cfg.append))

	return appends
end

return M
