local M = {}

---@class Crust.Config.Icons
---@field pending string
---@field success string
---@field error string
---@field quote string drawn over the "> " prefix of tool blocks, "" keeps the raw text

---@class Crust.Config.Labels
---@field user string
---@field agent string

---@class Crust.Config.Log
---@field enabled boolean write the raw rpc transcript to disk
---@field dir string directory holding `crust-<session>.log` files

---@class Crust.Config.RenderMarkdown
---@field enabled boolean|fun(): boolean push renders to render-markdown.nvim when it is installed
---@field debounce_ms integer quiet period before re-rendering while streaming

---@class Crust.Config.Keymaps
---@field cancel string|false abort the running turn, set to false to unbind
---@field sessions string|false open the session picker, normal mode in both panels

---@class Crust.Config.Window
---@field input_min_height integer smallest height of the prompt window, a taller one set by hand is kept
---@field auto_insert boolean start insert mode whenever the prompt takes focus

---@class Crust.Config.Sessions
---@field agent_dir? string pi agent directory, defaults to `$PI_CODING_AGENT_DIR` or `~/.pi/agent`

---@class Crust.Config.Preload work done in the background after `setup`, so opening the chat is just two splits
---@field sessions boolean parse the session history and watch the directory
---@field chat boolean build the chat buffers: treesitter, keymaps, completion
---@field pi boolean start the pi process too, before anything is typed

---@class Crust.Config.Prompt
---@field system_prompt? string|fun(): string? replaces pi's own system prompt
---@field append? string|string[]|fun(): string|string[]|nil appended after crust's block, text or a file path
---@field include_defaults boolean prepend crust's own instructions to `append`

---@class Crust.Config.Extension
---@field enabled boolean|fun(): boolean expose this neovim instance to pi through a bundled extension
---@field path? string pi extension handed to `-e`, defaults to the bundled one
---@field server? string neovim socket to reuse, defaults to `v:servername` or a fresh `serverstart()`

---@class Crust.Config.Expansion
---@field enabled boolean|fun(): boolean rewrite prompts for the model, e.g. `@path` into the file content

---@class Crust.Config.Context
---@field enabled boolean keep pi's own AGENTS.md and CLAUDE.md discovery
---@field files? string|string[]|fun(): string|string[]|nil extra context files, appended after the discovered ones
---@field append? string|string[]|fun(): string|string[]|nil extra context lines

---@class Crust.Config
---@field bin string
---@field prompt Crust.Config.Prompt
---@field context Crust.Config.Context
---@field expansion Crust.Config.Expansion
---@field extension Crust.Config.Extension
---@field log Crust.Config.Log
---@field render_markdown Crust.Config.RenderMarkdown
---@field icons Crust.Config.Icons status icons shown before a tool title
---@field labels Crust.Config.Labels message icons, same glyphs as pi.nvim
---@field timestamp_format string passed to os.date for message timestamps
---@field sessions Crust.Config.Sessions where session history is read from
---@field preload Crust.Config.Preload startup warm-up
---@field spinner string|string[]|Crust.Spinner preset name ("robot", "classic", "dots") or a custom definition
---@field status_text string shown next to the spinner while the agent works, empty for the icon alone
---@field keymaps Crust.Config.Keymaps
---@field window Crust.Config.Window chat panel geometry
---@field raw_tool_blocks boolean keep tool blocks out of the markdown tree
M.defaults = {
	bin = "pi",
	icons = {
		pending = "󰔟",
		success = "󰄬",
		error = "󰅖",
		quote = "▋",
	},
	-- Tool blocks are excluded from the markdown tree, so markdown plugins
	-- leave them alone. Crust draws their highlights itself.
	raw_tool_blocks = true,
	labels = {
		user = "",
		agent = "󰚩",
	},
	timestamp_format = "%b %-d %Y, %H:%M",
	spinner = "robot",
	status_text = "",
	keymaps = {
		cancel = "<C-c>",
		sessions = "<leader>s",
	},
	sessions = {
		agent_dir = nil,
	},
	window = {
		input_min_height = 5,
		-- Opening the chat leaves you in normal mode: a panel that grabs
		-- insert mode breaks `<leader>` mappings and the jumplist.
		auto_insert = false,
	},
	preload = {
		sessions = true,
		chat = true,
		pi = false,
	},
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
	expansion = {
		enabled = true,
	},
	extension = {
		enabled = false,
		path = nil,
		server = nil,
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
