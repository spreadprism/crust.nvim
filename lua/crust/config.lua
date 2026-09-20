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
---@field preview string|false expand the tool call under the cursor in a float, output panel only

---@class Crust.Config.Output.Markers
---@field above string format of the "older messages" hint, `%d` is the count
---@field below string format of the "newer messages" hint

---@class Crust.Config.Output.Keep messages pinned whatever the cursor looks at
---@field first integer oldest messages always drawn, 0 pins none
---@field last integer newest messages always drawn, 0 pins none

---@class Crust.Config.Output.Viewport only the messages around the cursor are drawn
---@field enabled boolean false keeps the whole transcript in the buffer
---@field max_sections integer messages drawn at once, the one in view always is
---@field max_lines integer soft cap on the drawn lines, never splits a message
---@field guard_lines integer rows from an elision marker that pull more in
---@field keep Crust.Config.Output.Keep head and tail pinned outside the budget
---@field markers Crust.Config.Output.Markers

---@class Crust.Config.Output
---@field viewport Crust.Config.Output.Viewport

---@class Crust.Config.InputBar.Layout
---@field left (string|Crust.Chat.InputBar.Component)[] drawn from the left edge
---@field right (string|Crust.Chat.InputBar.Component)[] pushed against the right one

---@class Crust.Config.InputBar the bar along the bottom of the prompt
---@field enabled boolean
---@field layout Crust.Config.InputBar.Layout component names, literal separators or functions
---@field components table<string, table> per-component options: `icon`, and `warn`/`error` levels

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
---@field input_bar Crust.Config.InputBar cost and model under the prompt
---@field output Crust.Config.Output scrollback rendering
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
		-- `K` over a tool block: the scrollback shows a cut title and a tail of
		-- the output, the float shows the call whole.
		preview = "K",
	},
	sessions = {
		agent_dir = nil,
	},
	output = {
		-- A session grows without bound, a buffer that holds all of it makes
		-- every write, every markdown pass and every highlight sweep grow with
		-- it. Only the messages around the one in view are materialized.
		viewport = {
			enabled = true,
			max_sections = 40,
			max_lines = 4000,
			guard_lines = 20,
			-- The start of a conversation (the task) and its newest messages
			-- are what one scrolls back for, so they are drawn whatever the
			-- cursor sits on, on top of the budget above.
			keep = {
				first = 4,
				last = 4,
			},
			markers = {
				above = "⋯ %d earlier messages ⋯",
				below = "⋯ %d newer messages ⋯",
			},
		},
	},
	input_bar = {
		enabled = true,
		-- What the turn costs on one side, what is answering on the other.
		layout = {
			left = { "cost" },
			right = { "model" },
		},
		components = {
			cost = { icon = "\u{f155}" },
			model = { icon = "󰚩" },
			tokens = { icon = "\u{f0ec}" },
			cache = { icon = "󰆼" },
			context = { icon = "\u{f0e4}", warn = 70, error = 90 },
			thinking = { icon = "󰟶" },
		},
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

--- Lists are values, not tables to merge into: a user layout of one
--- component would otherwise keep the tail of the default one.
---@param config Crust.Config
---@param options table
local function restore_lists(config, options)
	local layout = options.input_bar and options.input_bar.layout
	if type(layout) ~= "table" then
		return
	end
	for _, side in ipairs({ "left", "right" }) do
		if type(layout[side]) == "table" then
			config.input_bar.layout[side] = vim.deepcopy(layout[side])
		end
	end
end

---@return Crust.Config
function M.get()
	if M.config == nil then
		M.config = vim.tbl_deep_extend("force", M.defaults, M.options or {})
		restore_lists(M.config, M.options or {})
	end

	return M.config
end

return M
