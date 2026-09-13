--- Chat input: the editable prompt buffer, its window and keymaps.

---@class Crust.Chat.Input
---@field private _buf integer
---@field private _win integer?
---@field private _on_submit fun(text: string)
local Input = {}
Input.__index = Input

local scratch = require("crust.ui.scratch")

Input.HEIGHT = 5

--- @param on_submit fun(text: string) called with the trimmed buffer content
---@return Crust.Chat.Input
function Input.new(on_submit)
	local self = setmetatable({}, Input)

	self._buf = scratch("crust://input", "markdown")
	self._win = nil
	self._on_submit = on_submit

	vim.keymap.set({ "n", "i" }, "<CR>", function()
		self:submit()
	end, { buffer = self._buf, desc = "crust: send" })
	vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = self._buf, desc = "crust: newline" })

	return self
end

---@return integer
function Input:buf()
	return self._buf
end

---@return integer?
function Input:win()
	if self._win and vim.api.nvim_win_is_valid(self._win) then
		return self._win
	end
	return nil
end

--- Open the input window below the currently focused window.
function Input:open()
	if self:win() then
		return
	end

	vim.cmd("belowright " .. Input.HEIGHT .. "split")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, self._buf)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].winfixheight = true
	vim.wo[win].winfixbuf = true
	self._win = win
end

function Input:close()
	local win = self:win()
	if win then
		vim.api.nvim_win_close(win, false)
	end
	self._win = nil
end

function Input:focus()
	local win = self:win()
	if not win then
		return
	end
	vim.api.nvim_set_current_win(win)
	vim.cmd("startinsert")
end

---@return string
function Input:text()
	if not vim.api.nvim_buf_is_valid(self._buf) then
		return ""
	end
	return vim.trim(table.concat(vim.api.nvim_buf_get_lines(self._buf, 0, -1, false), "\n"))
end

---@param text string
function Input:set_text(text)
	vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

function Input:clear()
	self:set_text("")
end

--- Hand the current content to the submit callback; no-op when empty.
function Input:submit()
	local text = self:text()
	if text == "" then
		return
	end
	self._on_submit(text)
end

return Input
