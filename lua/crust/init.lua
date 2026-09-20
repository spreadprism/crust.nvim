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

--- Do the slow parts before the user asks for the chat. Opening then costs
--- two window splits: the buffers exist, treesitter is attached, the history
--- is parsed and watched.
---
--- Everything runs on `vim.schedule`, so a `setup` during startup does not
--- pay for it, and each step is individually switchable under `preload`.
---@param cfg? Crust.Config.Preload defaults to `config.get().preload`
function M.preload(cfg)
	cfg = cfg or require("crust.config").get().preload

	if cfg.sessions ~= false then
		require("crust.sessions.cache").warm()
	end

	if cfg.chat == false then
		return
	end

	vim.schedule(function()
		-- Building the panels touches treesitter and the filetype autocmds of
		-- whatever markdown plugins are installed, which is the bulk of what
		-- the first open used to cost.
		local current = M.chat()
		if cfg.pi then
			current:pi():connect()
		end
	end)
end

---@param opts? Crust.Chat.OpenOpts
function M.toggle(opts)
	M.chat():toggle(opts)
end

--- Open the chat on the most recent session of the cwd.
function M.continue()
	M.open({ continue = true })
end

--- Switch the live chat to the most recent session that is not the one it is
--- already on — the picker's first entry, without the picker.
---
--- `continue` resumes the newest session of the cwd, which once the chat is
--- up is usually the live one, so it would reload what is on screen. This
--- steps back one instead, which is what a "last session" mapping is for.
---@param callback? fun(ok: boolean, err: string?)
---@return boolean switching false when the cwd has no other session
function M.session_last(callback)
	local current = M.chat()
	current:open()

	local session = require("crust.sessions").last({ exclude = current:session().file })
	if not session then
		if callback then
			callback(false, "no other session")
		end
		return false
	end

	current:load_session(session.path, callback)
	return true
end

--- Open the chat and pick a past session: `<CR>` resumes it, the delete key
--- removes the selected ones.
function M.sessions()
	local current = M.chat()
	current:open()
	current:sessions()
end

--- Put a reference to what is on screen into the prompt, without sending it.
---
--- Normal mode adds `@path` for the current file, or the browsed directory
--- in an oil buffer. Visual mode adds `@path:first-last` for the selected
--- lines, or one mention per selected entry in oil.
---
--- The mention is built before the chat opens: focusing the prompt ends
--- visual mode, which would take the selection with it.
---@param opts? Crust.Send.Opts
---@return boolean sent false when the buffer has nothing to reference
function M.send(opts)
	local mention = require("crust.send").mention(opts)
	if not mention then
		return false
	end

	local current = M.chat()
	current:open()
	current:input():append(mention)
	current:input():focus()
	return true
end

--- One key for both halves of the workflow: `open` while the panel is away,
--- `send` once it is up.
---
--- Bound in normal and visual mode it reads as "bring up the chat", and then
--- as "add this file / these lines to the prompt", so the same mapping
--- collects context instead of reopening what is already on screen.
---
--- Called from inside the chat itself there is nothing to reference — the
--- prompt and the transcript are not files — so it only focuses the input.
---@param opts? Crust.Send.Opts
---@return boolean sent false when the call only moved windows around
function M.smart(opts)
	if not (chat and chat:is_visible()) then
		M.open()
		return false
	end

	local buf = (opts and opts.buf) or vim.api.nvim_get_current_buf()
	local output, input = chat:bufs()
	if buf == output or buf == input then
		chat:input():focus()
		return false
	end

	return M.send(opts)
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
	require("crust.sessions.cache").stop()
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

	M.preload()
end

return M
