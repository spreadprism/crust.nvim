--- The tool call under the cursor, in full, in a floating window.
---
--- A call in the scrollback is one cut line plus a handful of body lines: the
--- command is truncated to the panel width and the output is a ten line tail.
--- Pressing the preview key (`K` by default) over a block opens the whole
--- thing here — the complete title, highlighted with the spec's language, and
--- the complete output with its ansi colours.
---
--- Specs can override both ends, see `preview_title` and `preview_body` in
--- `Crust.Chat.Tools.Spec`.

---@class Crust.Chat.Tools.Preview
local M = {}

local Ansi = require("crust.ui.ansi")
local Highlights = require("crust.ui.highlights")
local Syntax = require("crust.ui.syntax")

M.ns = vim.api.nvim_create_namespace("crust.chat.tools.preview")

--- Share of the editor the float may take.
local WIDTH_RATIO = 0.8
local HEIGHT_RATIO = 0.8
--- Narrower than this is unreadable whatever the content is.
local MIN_WIDTH = 30

--- Spec colours sit above the flat body group covering the same cells, the
--- same way `Crust.Chat.Tools.Display` stacks them in the scrollback.
local COLORED_PRIORITY = 4200

---@class Crust.Chat.Tools.Preview.Content
---@field lines string[]
---@field highlights Crust.Chat.Tools.Highlight[]

--- The window currently open, at most one: a second preview replaces it.
---@type integer?
local current = nil

--- Full title of the call: the spec's `preview_title` when it has one, else
--- the title the scrollback shows, uncut.
---@param display Crust.Chat.Tools.Display
---@return string?
local function title_of(display)
	local full = display.spec.preview_title
	if full then
		local text = full(display)
		if type(text) == "string" and text ~= "" then
			return text
		end
	end

	local title = display:title()
	return title ~= "" and title or nil
end

--- Full output of the call, with the ranges that colour it. Specs that have
--- something better to show than the raw result (a diff, say) say so with
--- `preview_body`; everything else is terminal output and goes through the
--- ansi parser.
---@param display Crust.Chat.Tools.Display
---@return string[] lines
---@return Crust.Ui.Ansi.Range[] ranges
local function body_of(display)
	local spec = display.spec.preview_body
	if spec then
		local text, lang = spec(display)
		if type(text) == "string" and text ~= "" then
			local lines = vim.split(text, "\n", { plain = true })
			return lines, (lang and Syntax.highlight(text, lang)) or {}
		end
	end

	local text = display:result_text()
	if not text or vim.trim(text) == "" then
		return {}, {}
	end

	local parsed = Ansi.parse(vim.trim(text))
	return parsed.lines, parsed.ranges
end

--- Header, title and output as lines plus their highlight ranges.
---@param display Crust.Chat.Tools.Display
---@return Crust.Chat.Tools.Preview.Content
function M.content(display)
	local lines = {}
	---@type Crust.Chat.Tools.Highlight[]
	local highlights = {}

	---@param line integer
	---@param col integer
	---@param end_col integer
	---@param group string
	---@param priority? integer
	local function mark(line, col, end_col, group, priority)
		highlights[#highlights + 1] =
			{ line = line, col = col, end_col = end_col, group = group, priority = priority }
	end

	local icon = display:icon()
	local head = icon .. " " .. display.name
	lines[1] = head
	mark(1, 0, #icon, Highlights.tool_icon[display.status])
	mark(1, #icon + 1, #head, Highlights.TOOL)

	local title = title_of(display)
	if title then
		local first = #lines + 1
		vim.list_extend(lines, vim.split(title, "\n", { plain = true }))

		-- The flat group covers what the parser leaves uncoloured, e.g. the
		-- plain words of a command.
		for index = first, #lines do
			mark(index, 0, #lines[index], Highlights.TOOL_TITLE)
		end
		for _, range in ipairs((display.spec.title_lang and Syntax.highlight(title, display.spec.title_lang)) or {}) do
			mark(first + range.line - 1, range.col, range.end_col, range.group, COLORED_PRIORITY)
		end
	end

	local body, ranges = body_of(display)
	lines[#lines + 1] = ""

	if #body == 0 then
		-- An empty preview would look like a broken one, so the state that
		-- explains it is spelled out.
		lines[#lines + 1] = display.status == "pending" and "running…" or "no output"
		mark(#lines, 0, #lines[#lines], Highlights.TOOL_BODY_INLINE)
		return { lines = lines, highlights = highlights }
	end

	local first = #lines + 1
	vim.list_extend(lines, body)
	for index = first, #lines do
		mark(index, 0, #lines[index], Highlights.TOOL_BODY)
	end
	for _, range in ipairs(ranges) do
		mark(first + range.line - 1, range.col, range.end_col, range.group, COLORED_PRIORITY)
	end

	return { lines = lines, highlights = highlights }
end

--- Close the open preview, if any.
---@return boolean closed
function M.close()
	local win = current
	current = nil
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
		return true
	end
	return false
end

--- The window the preview is showing, nil when none is open.
---@return integer?
function M.win()
	if current and vim.api.nvim_win_is_valid(current) then
		return current
	end
	return nil
end

--- Rows the content needs once wrapped into `width` columns.
---@param lines string[]
---@param width integer
---@return integer
local function wrapped_height(lines, width)
	local rows = 0
	for _, line in ipairs(lines) do
		rows = rows + math.max(math.ceil(vim.fn.strdisplaywidth(line) / width), 1)
	end
	return rows
end

--- Show a tool call in a centered float, focused so it can be scrolled,
--- searched and yanked from. Any key that closes it leaves the chat as it was.
---@param display Crust.Chat.Tools.Display
---@return integer? win
function M.open(display)
	Highlights.setup()
	M.close()

	local content = M.content(display)

	local widest = MIN_WIDTH
	for _, line in ipairs(content.lines) do
		widest = math.max(widest, vim.fn.strdisplaywidth(line))
	end
	local width = math.min(widest, math.floor(vim.o.columns * WIDTH_RATIO))
	local height = math.min(wrapped_height(content.lines, width), math.floor(vim.o.lines * HEIGHT_RATIO))
	height = math.max(height, 1)

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
	vim.bo[buf].modifiable = false

	local ok, win = pcall(vim.api.nvim_open_win, buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " " .. display.name .. " ",
		title_pos = "center",
	})
	if not ok then
		vim.api.nvim_buf_delete(buf, { force = true })
		return nil
	end

	current = win
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = false
	vim.wo[win].winfixbuf = true

	for _, hl in ipairs(content.highlights) do
		pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, hl.line - 1, hl.col, {
			end_col = hl.end_col,
			hl_group = hl.group,
			priority = hl.priority,
		})
	end

	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, function()
			M.close()
		end, { buffer = buf, nowait = true, desc = "crust: close the tool preview" })
	end

	-- Leaving the float dismisses it: it is a lookup, not a window to manage.
	vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(function()
				if current == win then
					M.close()
				end
			end)
		end,
	})

	return win
end

return M
