local M = {}

local Chat = require("crust.ui.chat")

---@type Crust.Chat?
local chat = nil

---@return Crust.Chat
function M.chat()
	if not chat then
		chat = Chat.new()
	end
	return chat
end

---@param opts? Crust.Chat.OpenOpts
function M.open(opts)
	M.chat():open(opts)
end

---@param opts? Crust.Chat.OpenOpts
function M.toggle(opts)
	M.chat():toggle(opts)
end

--- Open the chat on the most recent session of the cwd.
function M.continue()
	M.open({ continue = true })
end

--- Open the chat and pick a past session: `<CR>` resumes it, the delete key
--- removes the selected ones.
function M.sessions()
	local current = M.chat()
	current:open()
	current:sessions()
end

--- Start a new session in the current chat, clearing the panel.
function M.new_session()
	local current = M.chat()
	current:open()
	current:new_session()
end

--- Rename the live session, prompting when `name` is omitted.
---@param name? string
function M.rename_session(name)
	M.chat():rename(name)
end

function M.stop()
	if chat then
		chat:close()
		chat:stop()
		chat = nil
	end
end

---@param opts? Crust.Config
function M.setup(opts)
	if vim.fn.has("nvim-0.13") == 0 then
		vim.notify("crust.nvim requires nvim-0.13 features", vim.log.levels.ERROR)
		return
	end

	if opts then
		require("crust.config").setup(opts)
	end

	require("crust.filetypes").setup()
	require("crust.ui.highlights").setup()

	-- render-markdown.nvim may load after us, so only report, never disable.
	M.has_render_markdown = require("crust.integrations.render_markdown").available()

	-- Starts the neovim socket now so it exists before the first chat.
	require("crust.extension").setup()
end

return M
