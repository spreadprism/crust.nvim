--- Editor context the bundled pi extension injects on every turn.
---
--- Every function here is called over `--remote-expr` and must return a json
--- string, so the extension can hand the result straight to the model.
---
--- The reported window is never a crust panel: while the user types a prompt
--- the focused window is `crust://input`, which says nothing about what they
--- are working on. A `WinEnter` autocmd remembers the last window that held a
--- real buffer, so "current" keeps pointing at the file behind the chat.

---@class Crust.Integrations.Extension.Context
local M = {}

local Filetypes = require("crust.filetypes")

--- Filetypes of the chat panels, none of which is useful as context.
---@type table<string, true>
local PANELS = {
	[Filetypes.input] = true,
	[Filetypes.output] = true,
	-- Spelled out instead of required, so this module never pulls in the ui.
	["crust_status"] = true,
}

---@type integer? window id, tracked by `M.setup`
local last_win = nil

--- True for the chat input, output and status buffers.
---@param buf integer
---@return boolean
function M.is_panel(buf)
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
	return not M.is_panel(vim.api.nvim_win_get_buf(win))
end

--- Window the user last worked in, ignoring the chat panels.
--- Falls back to the tracked window, then to any ordinary window.
---@return integer? win
function M.win()
	local current = vim.api.nvim_get_current_win()
	if usable(current) then
		return current
	end

	if usable(last_win) then
		return last_win
	end

	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if usable(win) then
			return win
		end
	end

	return nil
end

--- Remember the last non-panel window, so the chat can report it later.
function M.setup()
	local group = vim.api.nvim_create_augroup("crust.extension.context", { clear = true })
	vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
		group = group,
		callback = function()
			local win = vim.api.nvim_get_current_win()
			if usable(win) then
				last_win = win
			end
		end,
	})
end

---@param buf integer
---@return table
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
---@return string json
function M.ctx()
	local buffers = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and not M.is_panel(buf) then
			buffers[#buffers + 1] = buffer_info(buf)
		end
	end

	local context = {
		cwd = vim.fn.getcwd(),
		buffers = buffers,
	}

	local win = M.win()
	if win then
		local cursor = vim.api.nvim_win_get_cursor(win)
		context.current = buffer_info(vim.api.nvim_win_get_buf(win))
		context.cursor = { line = cursor[1], col = cursor[2] + 1 }
	end

	return vim.json.encode(context)
end

return M
