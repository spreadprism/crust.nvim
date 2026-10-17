--- Extension dialogs, the `extension_ui_request` half of the rpc protocol.
---
--- An extension that needs an answer — a permission system above all, see
--- `pi-permission-system` — calls `ui.select`, `ui.confirm`, `ui.input` or
--- `ui.editor`. pi turns each of those into an `extension_ui_request` on
--- stdout and *blocks the agent* until an `extension_ui_response` carrying the
--- same id comes back. A front-end that ignores them hangs the turn, so every
--- dialog request is drawn here and every one of them is answered, cancelled
--- included.
---
--- The fire-and-forget methods (`notify`, `setStatus`, `setWidget`,
--- `setTitle`, `set_editor_text`) expect no answer: only `notify` is shown,
--- the rest are ignored.
---
--- One dialog is on screen at a time. A request that arrives while another is
--- open is queued and drawn as soon as the open one is answered, because the
--- agent is blocked on each of them anyway.

---@class Crust.Ui.Ask
local M = {}

local Command = require("crust.pi.rpc")
local Filetypes = require("crust.filetypes")
local Highlights = require("crust.ui.highlights")

M.ns = vim.api.nvim_create_namespace("crust.ui.ask")

--- Share of the editor a dialog may take.
local WIDTH_RATIO = 0.8
local HEIGHT_RATIO = 0.8
--- Narrower than this no command is readable.
local MIN_WIDTH = 40
--- Rows of the editable area, one line for `input` and a paragraph for
--- `editor`.
local INPUT_HEIGHT = 1
local EDITOR_HEIGHT = 10

--- How each dialog method is drawn: a list to pick from, or a buffer to type
--- in. Anything missing here is fire-and-forget.
---@type table<string, "choice"|"text">
local KIND = {
	select = "choice",
	confirm = "choice",
	input = "text",
	editor = "text",
}

--- A `confirm` is a two-option select whose answer is a boolean.
local CONFIRM_OPTIONS = { "Yes", "No" }

---@class Crust.Ui.Ask.Request
---@field pi Crust.Pi process that asked, and that gets the answer
---@field event Crust.Pi.Event the `extension_ui_request`

---@class Crust.Ui.Ask.Dialog
---@field request Crust.Ui.Ask.Request
---@field kind "choice"|"text"
---@field buf integer
---@field win integer
---@field message string[] what the extension wrote, already wrapped
---@field options string[] choice dialogs only
---@field first integer row of the first option, 1-based
---@field answered boolean an answer was already sent, or none is expected
---@field timer uv.uv_timer_t? pi's own timeout, after which it answers itself

--- The dialog on screen, at most one.
---@type Crust.Ui.Ask.Dialog?
local current = nil

--- Requests waiting for the open dialog to be answered, oldest first.
---@type Crust.Ui.Ask.Request[]
local queue = {}

--- Break `text` into lines no wider than `width`, keeping its own newlines.
--- Long words are cut rather than left hanging over the border.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
	local out = {}
	for _, paragraph in ipairs(vim.split(text, "\n", { plain = true })) do
		local line = ""
		for word in paragraph:gmatch("%S+") do
			while #word > width do
				if line ~= "" then
					out[#out + 1] = line
					line = ""
				end
				out[#out + 1] = word:sub(1, width)
				word = word:sub(width + 1)
			end
			if line == "" then
				line = word
			elseif #line + 1 + #word <= width then
				line = line .. " " .. word
			else
				out[#out + 1] = line
				line = word
			end
		end
		out[#out + 1] = line
	end
	return out
end

--- Everything the extension wrote, title and message both: the permission
--- system packs the tool call into the title and the question into the
--- message, and either half alone is meaningless.
---@param event Crust.Pi.Event
---@return string
local function text_of(event)
	local parts = {}
	for _, value in ipairs({ event.title, event.message }) do
		if type(value) == "string" and vim.trim(value) ~= "" then
			parts[#parts + 1] = value
		end
	end
	return table.concat(parts, "\n")
end

---@param event Crust.Pi.Event
---@return string[]
local function options_of(event)
	if event.method == "confirm" then
		return vim.deepcopy(CONFIRM_OPTIONS)
	end
	local options = {}
	for _, option in ipairs(event.options or {}) do
		options[#options + 1] = tostring(option)
	end
	return options
end

--- Send the answer and take the dialog down. Called once per request:
--- whatever happens next — a second key, the window being closed by hand —
--- pi has its answer already.
---@param opts Crust.Pi.UiResponseOpts
local function answer(opts)
	local dialog = current
	if not dialog or dialog.answered then
		return
	end
	dialog.answered = true

	local id = dialog.request.event.id
	if id then
		dialog.request.pi:send(Command.extension_ui_response(id, opts))
	end

	M.close()
end

--- The answer pi gets when the user walks away from a dialog: the extension
--- sees `undefined` (or `false` for a confirm), which every one of them
--- treats as a refusal.
local function cancel()
	answer({ cancelled = true })
end

---@param dialog Crust.Ui.Ask.Dialog
---@return string[] lines
local function render(dialog)
	local lines = vim.deepcopy(dialog.message)
	if dialog.kind ~= "choice" then
		return lines
	end

	lines[#lines + 1] = ""
	dialog.first = #lines + 1
	for index, option in ipairs(dialog.options) do
		lines[#lines + 1] = string.format(" %d  %s", index, option)
	end
	return lines
end

---@param dialog Crust.Ui.Ask.Dialog
---@param lines string[]
local function highlight(dialog, lines)
	vim.api.nvim_buf_clear_namespace(dialog.buf, M.ns, 0, -1)

	for row = 0, #dialog.message - 1 do
		vim.api.nvim_buf_set_extmark(dialog.buf, M.ns, row, 0, {
			end_row = row + 1,
			hl_group = Highlights.ASK_MESSAGE,
			hl_eol = true,
		})
	end

	if dialog.kind ~= "choice" then
		return
	end

	for index = 1, #dialog.options do
		local row = dialog.first + index - 2
		local line = lines[row + 1] or ""
		vim.api.nvim_buf_set_extmark(dialog.buf, M.ns, row, 0, {
			end_col = math.min(3, #line),
			hl_group = Highlights.ASK_KEY,
		})
		vim.api.nvim_buf_set_extmark(dialog.buf, M.ns, row, math.min(3, #line), {
			end_row = row + 1,
			hl_group = Highlights.ASK_OPTION,
			hl_eol = true,
		})
	end
end

--- Text dialogs keep the question out of the buffer: the buffer is what the
--- user types, the question hangs above it as virtual lines, so submitting
--- never has to strip it back off.
---@param dialog Crust.Ui.Ask.Dialog
local function virtual_message(dialog)
	local virt_lines = {}
	for _, line in ipairs(dialog.message) do
		virt_lines[#virt_lines + 1] = { { line, Highlights.ASK_MESSAGE } }
	end
	virt_lines[#virt_lines + 1] = { { "", Highlights.ASK_MESSAGE } }

	vim.api.nvim_buf_set_extmark(dialog.buf, M.ns, 0, 0, {
		virt_lines = virt_lines,
		virt_lines_above = true,
	})
end

---@param dialog Crust.Ui.Ask.Dialog
local function keymaps(dialog)
	local function map(modes, lhs, rhs)
		vim.keymap.set(modes, lhs, rhs, { buffer = dialog.buf, nowait = true, silent = true })
	end

	map("n", "q", cancel)
	map("n", "<Esc>", cancel)

	if dialog.kind == "choice" then
		map("n", "<CR>", function()
			M.choose(vim.api.nvim_win_get_cursor(dialog.win)[1] - dialog.first + 1)
		end)
		for index = 1, math.min(#dialog.options, 9) do
			map("n", tostring(index), function()
				M.choose(index)
			end)
		end
		return
	end

	-- A one-line answer is submitted with Enter, a multi-line one needs
	-- Enter for what it is: C-s submits both, so the key never changes.
	map({ "n", "i" }, "<C-s>", M.submit)
	if dialog.request.event.method == "input" then
		map({ "n", "i" }, "<CR>", M.submit)
	end
end

--- Draw `request` and wait for the user. The window is the only place the
--- answer can come from, so closing it by any means cancels the request.
---@param request Crust.Ui.Ask.Request
local function open(request)
	local event = request.event
	local kind = KIND[event.method or ""] or "choice"

	local width = math.max(MIN_WIDTH, math.min(math.floor(vim.o.columns * WIDTH_RATIO), 100))
	Filetypes.setup()
	Highlights.setup()

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = Filetypes.ask

	---@type Crust.Ui.Ask.Dialog
	local dialog = {
		request = request,
		kind = kind,
		buf = buf,
		win = -1,
		message = wrap(text_of(event), width),
		options = options_of(event),
		first = 1,
		answered = false,
	}
	current = dialog

	local lines = render(dialog)
	local height = #lines
	if kind == "text" then
		height = #dialog.message + 1 + (event.method == "editor" and EDITOR_HEIGHT or INPUT_HEIGHT)
		lines = vim.split(type(event.prefill) == "string" and event.prefill or "", "\n", { plain = true })
	end
	height = math.max(1, math.min(height, math.floor(vim.o.lines * HEIGHT_RATIO)))

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = kind == "text"

	dialog.win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. (event.method or "ask") .. " ",
		footer = kind == "choice" and " <CR> choose · 1-9 pick · q cancel "
			or (event.method == "editor" and " <C-s> submit · q cancel " or " <CR> submit · q cancel "),
	})
	vim.wo[dialog.win].wrap = false

	if kind == "choice" then
		highlight(dialog, lines)
		vim.wo[dialog.win].cursorline = true
		pcall(vim.api.nvim_win_set_cursor, dialog.win, { dialog.first, 0 })
	else
		virtual_message(dialog)
		local last = vim.api.nvim_buf_line_count(buf)
		pcall(vim.api.nvim_win_set_cursor, dialog.win, { last, #(lines[last] or "") })
		vim.cmd("startinsert!")
	end

	keymaps(dialog)

	vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
		buffer = buf,
		once = true,
		callback = function()
			-- Closed without an answer: pi is still waiting for one.
			if current == dialog and not dialog.answered then
				vim.schedule(cancel)
			end
		end,
	})

	-- pi answers a timed-out dialog by itself, so the window is only taken
	-- down; sending afterwards would be answering a request that is gone.
	local timeout = tonumber(event.timeout)
	if timeout and timeout > 0 then
		dialog.timer = vim.defer_fn(function()
			if current == dialog then
				dialog.answered = true
				M.close()
			end
		end, timeout)
	end
end

--- Draw the next queued request, if the screen is free.
local function drain()
	if current or #queue == 0 then
		return
	end
	open(table.remove(queue, 1))
end

--- Take the open dialog down without answering it. The answer, when there is
--- one, is sent by `answer` before this runs.
function M.close()
	local dialog = current
	if not dialog then
		return
	end
	current = nil

	if dialog.timer then
		pcall(function()
			dialog.timer:stop()
		end)
	end
	if vim.api.nvim_win_is_valid(dialog.win) then
		pcall(vim.api.nvim_win_close, dialog.win, true)
	end
	if vim.api.nvim_buf_is_valid(dialog.buf) then
		pcall(vim.api.nvim_buf_delete, dialog.buf, { force = true })
	end

	vim.schedule(drain)
end

--- Answer a choice dialog with its `index`-th option. Out of range indices
--- are ignored: a stray key should not decide a permission.
---@param index integer 1-based, in the order the extension gave them
---@return boolean chosen
function M.choose(index)
	local dialog = current
	if not dialog or dialog.kind ~= "choice" then
		return false
	end

	local option = dialog.options[index]
	if option == nil then
		return false
	end

	if dialog.request.event.method == "confirm" then
		answer({ confirmed = index == 1 })
	else
		answer({ value = option })
	end
	return true
end

--- Answer a text dialog with the buffer content.
---@return boolean submitted
function M.submit()
	local dialog = current
	if not dialog or dialog.kind ~= "text" then
		return false
	end

	local lines = vim.api.nvim_buf_get_lines(dialog.buf, 0, -1, false)
	vim.cmd("stopinsert")
	answer({ value = table.concat(lines, "\n") })
	return true
end

--- Dismiss the open dialog, which refuses whatever it asked for.
---@return boolean cancelled
function M.cancel()
	if not current then
		return false
	end
	cancel()
	return true
end

--- Notifications and status updates an extension pushes. Nothing here is
--- answered; only `notify` is worth the user's attention.
---@param event Crust.Pi.Event
local function fire_and_forget(event)
	if event.method ~= "notify" or not require("crust.config").get().ask.notify then
		return
	end

	local levels = { info = vim.log.levels.INFO, warning = vim.log.levels.WARN, error = vim.log.levels.ERROR }
	local message = type(event.message) == "string" and event.message or text_of(event)
	if vim.trim(message) ~= "" then
		vim.notify(message, levels[event.notifyType or "info"] or vim.log.levels.INFO)
	end
end

--- Handle one `extension_ui_request`. Dialogs are drawn and answered, the
--- rest is a notification at most.
---@param pi Crust.Pi process to answer on
---@param event Crust.Pi.Event
---@return boolean handled false when the event is not an extension ui request
function M.handle(pi, event)
	if event.type ~= "extension_ui_request" then
		return false
	end

	if not KIND[event.method or ""] then
		fire_and_forget(event)
		return true
	end

	---@type Crust.Ui.Ask.Request
	local request = { pi = pi, event = event }

	-- Dialogs turned off still have to be answered: the agent is blocked on
	-- this request and a silent drop would hang the turn forever.
	if not require("crust.config").get().ask.enabled then
		if event.id then
			pi:send(Command.extension_ui_response(event.id, { cancelled = true }))
		end
		return true
	end

	if current then
		queue[#queue + 1] = request
		vim.notify("crust: another permission request is waiting", vim.log.levels.INFO)
		return true
	end

	open(request)
	return true
end

--- Requests waiting behind the open dialog.
---@return integer
function M.pending()
	return #queue
end

--- The dialog on screen, nil when there is none. Mostly for tests and
--- statusline bits.
---@return Crust.Ui.Ask.Dialog?
function M.current()
	return current
end

--- Drop the open dialog and everything queued behind it, answering each one
--- as cancelled. Used when the process they belong to goes away.
---@param pi? Crust.Pi only requests of this process, all of them without it
function M.reset(pi)
	local kept = {}
	for _, request in ipairs(queue) do
		if pi and request.pi ~= pi then
			kept[#kept + 1] = request
		elseif request.event.id then
			request.pi:send(Command.extension_ui_response(request.event.id, { cancelled = true }))
		end
	end
	queue = kept

	if current and (not pi or current.request.pi == pi) then
		cancel()
	end
end

return M
