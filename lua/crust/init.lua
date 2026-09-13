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

function M.open()
	M.chat():open()
end

function M.toggle()
	M.chat():toggle()
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

	-- Starts the neovim socket now so it exists before the first chat.
	require("crust.integrations.mcp_server").setup()

	-- render-markdown.nvim may load after us, so only report, never disable.
	M.has_render_markdown = require("crust.integrations.render_markdown").available()
end

return M
