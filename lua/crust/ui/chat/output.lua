--- Chat output: the read-only scrollback buffer and its window.

---@class Crust.Chat.Output
---@field private _buf integer
---@field private _win integer?
---@field private _blocks Crust.Chat.Output.Block[]
---@field private _regions_timer uv.uv_timer_t?
local Output = {}
Output.__index = Output

Output.FILETYPE = require("crust.filetypes").output
Output.SEPARATOR = "---"

local scratch = require("crust.ui.scratch")
local Highlights = require("crust.ui.highlights")
local RenderMarkdown = require("crust.integrations.render_markdown")
local Regions = require("crust.ui.regions")

--- Quiet period before the markdown regions are recomputed.
local REGIONS_DEBOUNCE_MS = 50

--- Tracks appended blocks so they can be rewritten after later appends.
local ns = vim.api.nvim_create_namespace("crust.chat.output.blocks")
--- Highlights belonging to blocks, cleared and reapplied on every rewrite.
local hl_ns = vim.api.nvim_create_namespace("crust.chat.output.highlights")

---@class Crust.Chat.Output.Block
---@field id integer extmark id anchoring the first line
---@field count integer number of lines the block currently occupies

---@return Crust.Chat.Output
function Output.new()
	local self = setmetatable({}, Output)

	Highlights.setup()
	self._buf = scratch("crust://chat", Output.FILETYPE, true)
	self._blocks = {}
	vim.bo[self._buf].modifiable = false
	self._win = nil

	return self
end

---@return integer
function Output:buf()
	return self._buf
end

---@return integer?
function Output:win()
	if self._win and vim.api.nvim_win_is_valid(self._win) then
		return self._win
	end
	return nil
end

--- Open the output window as a right-hand vertical split.
---@param width integer
function Output:open(width)
	if self:win() then
		return
	end

	vim.cmd("botright " .. width .. "vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, self._buf)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].winfixwidth = true
	vim.wo[win].winfixbuf = true
	self._win = win
end

--- Resize the output window, the panel owns the remaining space.
---@param width integer
function Output:set_width(width)
	local win = self:win()
	if win then
		vim.api.nvim_win_set_width(win, math.max(width, 1))
	end
end

function Output:close()
	local win = self:win()
	if win then
		vim.api.nvim_win_close(win, false)
	end
	self._win = nil
	RenderMarkdown.detach(self._buf)

	if self._regions_timer then
		self._regions_timer:stop()
		self._regions_timer:close()
		self._regions_timer = nil
	end
end

--- Append raw text, continuing the last line (streaming friendly).
---@param text string
function Output:append(text)
	if not vim.api.nvim_buf_is_valid(self._buf) then
		return
	end

	local line_count = vim.api.nvim_buf_line_count(self._buf)
	local last = vim.api.nvim_buf_get_lines(self._buf, line_count - 1, line_count, false)[1] or ""

	vim.bo[self._buf].modifiable = true
	-- Insert instead of rewriting the last line: rewriting would move any
	-- block extmark anchored there to the end of the new text.
	vim.api.nvim_buf_set_text(
		self._buf,
		line_count - 1,
		#last,
		line_count - 1,
		#last,
		vim.split(text, "\n", { plain = true })
	)
	vim.bo[self._buf].modifiable = false

	self:follow()
	self:_render_markdown()
end

--- Text columns available in the output window, nil when it is not shown.
---@return integer?
function Output:width()
	local win = self:win()
	if not win then
		return nil
	end

	local info = vim.fn.getwininfo(win)[1]
	local width = info and info.width or vim.api.nvim_win_get_width(win)
	local textoff = info and info.textoff or 0
	return math.max(width - textoff, 1)
end

--- Drop trailing blank lines so separators never stack up.
---@private
---@return boolean has_content false when the buffer is blank
function Output:_trim_trailing_blanks()
	local count = vim.api.nvim_buf_line_count(self._buf)
	local lines = vim.api.nvim_buf_get_lines(self._buf, 0, -1, false)

	local last_content = 0
	for i = #lines, 1, -1 do
		if lines[i] ~= "" then
			last_content = i
			break
		end
	end

	if last_content == 0 then
		if count > 1 then
			vim.bo[self._buf].modifiable = true
			vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, { "" })
			vim.bo[self._buf].modifiable = false
		end
		return false
	end

	if last_content < count then
		vim.bo[self._buf].modifiable = true
		vim.api.nvim_buf_set_lines(self._buf, last_content, -1, false, {})
		vim.bo[self._buf].modifiable = false
	end

	return true
end

--- Apply a block's highlight ranges, relative to its first line.
---@private
---@param first integer 0-based row of the block's first line
---@param count integer lines in the block
---@param highlights? Crust.Chat.Tools.Highlight[]
---@param line_highlights? table<integer, string> full-line backgrounds
function Output:_highlight_block(first, count, highlights, line_highlights)
	vim.api.nvim_buf_clear_namespace(self._buf, hl_ns, first, first + count)

	for line, group in pairs(line_highlights or {}) do
		vim.api.nvim_buf_set_extmark(self._buf, hl_ns, first + line - 1, 0, { line_hl_group = group })
	end

	for _, hl in ipairs(highlights or {}) do
		vim.api.nvim_buf_set_extmark(self._buf, hl_ns, first + hl.line - 1, hl.col, {
			end_col = hl.end_col,
			hl_group = hl.group,
			priority = hl.priority,
			-- Blocks are excluded from the markdown tree, so a quote marker
			-- has to be drawn here instead of by render-markdown.
			virt_text = hl.overlay and { { hl.overlay, hl.group } } or nil,
			virt_text_pos = hl.overlay and "overlay" or nil,
		})
	end
end

--- True when nothing but blank lines follows the block, so the next block
--- can be appended directly under it.
---@param block Crust.Chat.Output.Block
---@return boolean
function Output:block_ends_buffer(block)
	local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.id, {})
	if not pos[1] then
		return false
	end

	local lines = vim.api.nvim_buf_get_lines(self._buf, 0, -1, false)
	for index = #lines, 1, -1 do
		if lines[index] ~= "" then
			return pos[1] + block.count == index
		end
	end
	return false
end

--- Append lines as a rewritable block, isolated by one blank line on each
--- side so streamed text never reads as part of the block.
---@param lines string[]
---@param highlights? Crust.Chat.Tools.Highlight[]
---@param line_highlights? table<integer, string>
---@param compact? boolean append directly under the previous line, no blank line
---@return Crust.Chat.Output.Block
function Output:append_block(lines, highlights, line_highlights, compact)
	local has_content = self:_trim_trailing_blanks()
	local prefix = has_content and (compact and "\n" or "\n\n") or ""

	self:append(prefix .. table.concat(lines, "\n") .. "\n\n")
	local first = vim.api.nvim_buf_line_count(self._buf) - 2 - #lines
	self:_highlight_block(first, #lines, highlights, line_highlights)

	---@type Crust.Chat.Output.Block
	local block = {
		id = vim.api.nvim_buf_set_extmark(self._buf, ns, first, 0, {}),
		count = #lines,
	}
	self._blocks[#self._blocks + 1] = block
	self:_refresh_regions()

	return block
end

--- Rows currently covered by blocks, resolved through their extmarks.
---@private
---@return Crust.Regions.Range[]
function Output:_block_ranges()
	local ranges = {}
	for _, block in ipairs(self._blocks) do
		local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.id, {})
		if pos[1] then
			ranges[#ranges + 1] = { first = pos[1], last = pos[1] + block.count }
		end
	end
	return ranges
end

--- Keep tool blocks out of the markdown tree so nothing styles them. Our own
--- highlights and prefix icons are extmarks, they are unaffected.
---@private
function Output:_refresh_regions()
	if not require("crust.config").get().raw_tool_blocks then
		return
	end

	self._regions_timer = self._regions_timer or assert(vim.uv.new_timer())
	self._regions_timer:stop()
	self._regions_timer:start(
		REGIONS_DEBOUNCE_MS,
		0,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(self._buf) then
				Regions.exclude(self._buf, self:_block_ranges())
			end
		end)
	)
end

--- Rewrite a block in place, wherever it has drifted to.
---@param block Crust.Chat.Output.Block
---@param lines string[]
---@param highlights? Crust.Chat.Tools.Highlight[]
---@param line_highlights? table<integer, string>
function Output:replace_block(block, lines, highlights, line_highlights)
	if not vim.api.nvim_buf_is_valid(self._buf) then
		return
	end

	local pos = vim.api.nvim_buf_get_extmark_by_id(self._buf, ns, block.id, {})
	if not pos[1] then
		return
	end

	-- Clear before rewriting: marks on replaced lines drift to the end of
	-- the new text, where a later clear would no longer cover them.
	vim.api.nvim_buf_clear_namespace(self._buf, hl_ns, pos[1], pos[1] + block.count)

	vim.bo[self._buf].modifiable = true
	vim.api.nvim_buf_set_lines(self._buf, pos[1], pos[1] + block.count, false, lines)
	-- Replacing the anchored line moves the extmark to the end of the new
	-- text, so re-anchor it on the first line of the block.
	vim.api.nvim_buf_set_extmark(self._buf, ns, pos[1], 0, { id = block.id })
	vim.bo[self._buf].modifiable = false
	block.count = #lines
	self:_highlight_block(pos[1], #lines, highlights, line_highlights)
	self:_refresh_regions()

	self:follow()
	self:_render_markdown()
end

--- Highlight a range on an absolute row.
---@private
---@param row integer 0-based
---@param col integer
---@param end_col integer
---@param group string
function Output:_highlight(row, col, end_col, group)
	vim.api.nvim_buf_set_extmark(self._buf, hl_ns, row, col, { end_col = end_col, hl_group = group })
end

--- Start a message: a `---` rule, then the role icon and a timestamp.
--- The rule is skipped for the first message, there is nothing to separate.
---@param label string role icon, see `config.labels`
---@param group string highlight group for the icon
---@param timestamp? integer epoch seconds, defaults to now
function Output:header(label, group, timestamp)
	local format = require("crust.config").get().timestamp_format
	local time = tostring(os.date(format, timestamp or os.time()))

	local has_content = self:_trim_trailing_blanks()
	local head = label .. " " .. time
	if has_content then
		self:append("\n\n" .. Output.SEPARATOR .. "\n" .. head .. "\n\n")
	else
		self:append(head .. "\n\n")
	end

	local head_row = vim.api.nvim_buf_line_count(self._buf) - 3
	if has_content then
		self:_highlight(head_row - 1, 0, #Output.SEPARATOR, Highlights.SEPARATOR)
	end
	self:_highlight(head_row, 0, #label, group)
	self:_highlight(head_row, #label + 1, #head, Highlights.TIMESTAMP)
end

---@param message string
function Output:error(message)
	self:append("\n**crust: " .. message .. "**\n")
end

---@return string[]
function Output:lines()
	return vim.api.nvim_buf_get_lines(self._buf, 0, -1, false)
end

function Output:clear()
	vim.bo[self._buf].modifiable = true
	vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, { "" })
	vim.bo[self._buf].modifiable = false
end

--- Ask render-markdown.nvim to re-render, it does not see our buffer while
--- the user is typing in the input window.
---@private
function Output:_render_markdown()
	local config = require("crust.config")
	local cfg = config.get().render_markdown
	if not config.enabled(cfg.enabled) then
		return
	end
	RenderMarkdown.render(self._buf, Output.FILETYPE, cfg.debounce_ms)
end

--- Keep the cursor pinned to the last line so streaming stays visible.
function Output:follow()
	local win = self:win()
	if not win then
		return
	end
	vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(self._buf), 0 })
end

return Output
