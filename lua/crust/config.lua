local M = {}

---@class Crust.Config.Icons
---@field pending string
---@field success string
---@field error string

---@class Crust.Config.Labels
---@field user string
---@field agent string

---@class Crust.Config.Log
---@field enabled boolean write the raw rpc transcript to disk
---@field dir string directory holding `crust-<session>.log` files

---@class Crust.Config.RenderMarkdown
---@field enabled boolean|fun(): boolean push renders to render-markdown.nvim when it is installed
---@field debounce_ms integer quiet period before re-rendering while streaming

---@class Crust.Config.Prompt
---@field system_prompt? string|fun(): string? replaces pi's own system prompt
---@field append? string|string[]|fun(): string|string[]|nil appended after crust's block, text or a file path
---@field include_defaults boolean prepend crust's own instructions to `append`

---@class Crust.Config.Context
---@field enabled boolean keep pi's own AGENTS.md and CLAUDE.md discovery
---@field files? string|string[]|fun(): string|string[]|nil extra context files, appended after the discovered ones
---@field append? string|string[]|fun(): string|string[]|nil extra context lines

---@class Crust.Config
---@field bin string
---@field prompt Crust.Config.Prompt
---@field context Crust.Config.Context
---@field log Crust.Config.Log
---@field render_markdown Crust.Config.RenderMarkdown
---@field icons Crust.Config.Icons status icons shown before a tool title
---@field labels Crust.Config.Labels message icons, same glyphs as pi.nvim
---@field timestamp_format string passed to os.date for message timestamps
M.defaults = {
	bin = "pi",
	icons = {
		pending = "󰔟",
		success = "󰄬",
		error = "󰅖",
	},
	labels = {
		user = "",
		agent = "󰚩",
	},
	timestamp_format = "%b %-d %Y, %H:%M",
	log = {
		enabled = false,
		dir = vim.fn.stdpath("state") .. "/crust",
	},
	prompt = {
		system_prompt = nil,
		append = nil,
		include_defaults = true,
	},
	context = {
		enabled = true,
		files = nil,
		append = nil,
	},
	render_markdown = {
		enabled = function()
			local ok = pcall(require, "render-markdown")
			return ok
		end,
		debounce_ms = 100,
	},
}

---@type Crust.Config|nil
M.config = nil

---@type Crust.Config?
M.options = nil

function M.setup(opts)
	if M.options ~= nil then
		vim.notify("crust: setup() called more than once, overriding previous options", vim.log.levels.WARN)
	end
	M.options = opts
end

--- Resolve an option that may be given as a value or a function.
---@param value boolean|fun(): boolean
---@return boolean
function M.enabled(value)
	if type(value) == "function" then
		return value() == true
	end
	return value == true
end

---@return Crust.Config
function M.get()
	if M.config == nil then
		M.config = vim.tbl_deep_extend("force", M.defaults, M.options or {})
	end

	return M.config
end

return M
