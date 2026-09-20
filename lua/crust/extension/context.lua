--- `nvim_context`: the editor state the bundled pi extension injects on every
--- turn and can ask for again mid-turn.
---
--- The reported window is never a crust panel: while the user types a prompt
--- the focused window is `crust://input`, which says nothing about what they
--- are working on. A `WinEnter` autocmd remembers the last window that held a
--- real buffer, so "current" keeps pointing at the file behind the chat.
---
--- Returns an array of tools; see `crust.integrations.extension`.

---@class Crust.Context.Buffer
---@field buf integer buffer number
---@field path string? `:~:.` path, nil for an unnamed buffer
---@field filetype string
---@field modified boolean
---@field lines integer

---@class Crust.Context.Cursor
---@field line integer 1-based
---@field col integer 1-based

---@class Crust.Context
---@field cwd string
---@field branch string? checked out git branch, omitted outside a repository
---@field buffers Crust.Context.Buffer[] loaded and listed, panels excluded
---@field current Crust.Context.Buffer? omitted when only chat panels are open
---@field cursor Crust.Context.Cursor? omitted with `current`

local Filetypes = require("crust.filetypes")

--- Filetypes of the chat panels, none of which is useful as context.
---@type table<string, true>
local PANELS = {
	[Filetypes.input] = true,
	[Filetypes.output] = true,
	-- Spelled out instead of required, so this module never pulls in the ui.
	["crust_status"] = true,
}

---@type integer? window id, tracked by the tool's `setup`
local last_win = nil

--- True for the chat input, output and status buffers.
---@param buf integer
---@return boolean
local function is_panel(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	if PANELS[vim.bo[buf].filetype] then
		return true
	end
	return vim.api.nvim_buf_get_name(buf):match("^crust://") ~= nil
end

--- True for a window that can be reported as "current".
---@param win integer?
---@return boolean
local function usable(win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return false
	end
	-- Floats are overlays (status bar, pickers), not what the user edits.
	if vim.api.nvim_win_get_config(win).relative ~= "" then
		return false
	end
	return not is_panel(vim.api.nvim_win_get_buf(win))
end

--- Window the user last worked in, ignoring the chat panels.
--- Falls back to the tracked window, then to any ordinary window.
---@return integer? win
local function win()
	local current = vim.api.nvim_get_current_win()
	if usable(current) then
		return current
	end

	if usable(last_win) then
		return last_win
	end

	for _, candidate in ipairs(vim.api.nvim_list_wins()) do
		if usable(candidate) then
			return candidate
		end
	end

	return nil
end

--- Remember the last non-panel window, so the chat can report it later.
local function setup()
	local group = vim.api.nvim_create_augroup("crust.extension.context", { clear = true })
	vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
		group = group,
		callback = function()
			local current = vim.api.nvim_get_current_win()
			if usable(current) then
				last_win = current
			end
		end,
	})
end

--- Checked out branch of the repository `dir` lives in, read straight from
--- `.git/HEAD` so no git process is spawned. Returns the short commit hash
--- when the head is detached, nil outside a repository.
---@param dir string
---@return string?
local function branch(dir)
	local git = vim.fs.find(".git", { path = dir, upward = true })[1]
	if not git then
		return nil
	end

	-- A worktree or submodule has a `.git` file pointing at the real gitdir.
	if vim.fn.isdirectory(git) == 0 then
		local pointer = (vim.fn.readfile(git)[1] or ""):match("^gitdir: (.+)$")
		if not pointer then
			return nil
		end
		git = vim.startswith(pointer, "/") and pointer or vim.fs.joinpath(vim.fs.dirname(git), pointer)
		git = vim.fs.normalize(git)
	end

	local ok, head = pcall(vim.fn.readfile, vim.fs.joinpath(git, "HEAD"), "", 1)
	if not ok then
		return nil
	end

	local ref = head[1]
	if not ref or ref == "" then
		return nil
	end

	return ref:match("^ref: refs/heads/(.+)$") or ref:sub(1, 7)
end

---@param buf integer
---@return Crust.Context.Buffer
local function buffer_info(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	return {
		buf = buf,
		path = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or nil,
		filetype = vim.bo[buf].filetype,
		modified = vim.bo[buf].modified,
		lines = vim.api.nvim_buf_line_count(buf),
	}
end

--- Everything the extension injects as context: cwd, listed buffers, and the
--- cursor position of the window the user was last in. `current` and `cursor`
--- are omitted when only chat panels are open.
---@return Crust.Context
local function ctx()
	local buffers = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and not is_panel(buf) then
			buffers[#buffers + 1] = buffer_info(buf)
		end
	end

	local cwd = vim.fn.getcwd()

	---@type Crust.Context
	local context = {
		cwd = cwd,
		branch = branch(cwd),
		buffers = buffers,
	}

	local window = win()
	if window then
		local cursor = vim.api.nvim_win_get_cursor(window)
		context.current = buffer_info(vim.api.nvim_win_get_buf(window))
		context.cursor = { line = cursor[1], col = cursor[2] + 1 }
	end

	return context
end

---@type Crust.Extension.Tool[]
return {
	{
		name = "nvim_context",
		label = "Neovim Context",
		description = "Current neovim state: cwd, git branch, listed buffers and the file the user is working in and the cursor position.",
		promptSnippet = "Inspect the current neovim editor state",
		promptGuidelines = {
			"Use nvim_context when the user says 'this file', 'here' or 'the current buffer'.",
		},
		context = true,
		parameters = { type = "object", properties = vim.empty_dict() },
		setup = setup,
		handler = ctx,
	},
}
