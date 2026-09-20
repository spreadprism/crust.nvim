--- Chat input: the editable prompt buffer, its window and keymaps.

---@class Crust.Chat.Input
---@field private _buf integer
---@field private _win integer?
---@field private _on_submit fun(text: string)
local Input = {}
Input.__index = Input

local scratch = require("crust.ui.scratch")

--- Fallback for `window.input_min_height`.
Input.HEIGHT = 5

--- Smallest height of the prompt window. A taller one, set with `<C-w>+` or
--- the mouse, is left alone.
---@return integer
function Input.min_height()
	local window = require("crust.config").get().window or {}
	local height = window.input_min_height
	if type(height) ~= "number" or height < 1 then
		return Input.HEIGHT
	end
	return math.floor(height)
end
Input.FILETYPE = require("crust.filetypes").input

--- @param on_submit fun(text: string) called with the trimmed buffer content
---@return Crust.Chat.Input
function Input.new(on_submit)
	local self = setmetatable({}, Input)

	self._buf = scratch("crust://input", Input.FILETYPE, true)
	self._win = nil
	self._on_submit = on_submit

	-- `<C-x><C-u>` completes @mentions and /commands without blink.cmp.
	require("crust.completion.omnifunc").attach(self._buf)
	-- Colour @mentions as they are typed.
	require("crust.ui.highlights").setup()
	require("crust.ui.mentions").attach(self._buf)

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

	vim.cmd("belowright " .. Input.min_height() .. "split")
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

--- Grow the input back to its minimum height when something squashed it,
--- e.g. a resize of the editor. A height set by hand is kept.
function Input:restore_height()
	local win = self:win()
	if not win then
		return
	end

	local min = Input.min_height()
	if vim.api.nvim_win_get_height(win) < min then
		vim.api.nvim_win_set_height(win, min)
	end
end

function Input:close()
	local win = self:win()
	if win then
		vim.api.nvim_win_close(win, false)
	end
	self._win = nil
end

--- Whether focusing the prompt also starts insert mode.
---@return boolean
function Input.auto_insert()
	local window = require("crust.config").get().window or {}
	return window.auto_insert == true
end

--- Put the cursor in the prompt. Insert mode is only entered when
--- `window.auto_insert` asks for it, so the panel does not steal the mode.
---@param insert? boolean override the config for this call
function Input:focus(insert)
	local win = self:win()
	if not win then
		return
	end

	vim.api.nvim_set_current_win(win)
	if insert == nil then
		insert = Input.auto_insert()
	end
	if insert then
		vim.cmd("startinsert")
	end
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

--- Add `text` to the end of the prompt, keeping what is already typed, and
--- leave the cursor behind it. A space is inserted when the prompt does not
--- already end in whitespace, so two mentions never run together.
---@param text string
function Input:append(text)
	if text == "" or not vim.api.nvim_buf_is_valid(self._buf) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(self._buf, 0, -1, false)
	local last = lines[#lines] or ""
	local separator = (last ~= "" and not last:match("%s$")) and " " or ""

	lines[#lines] = last .. separator .. text
	lines = vim.split(table.concat(lines, "\n"), "\n", { plain = true })
	vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, lines)

	local win = self:win()
	if win then
		vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
	end
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
