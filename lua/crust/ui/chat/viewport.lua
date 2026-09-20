--- The window onto the transcript: which sections are materialized in the
--- output buffer, and where.
---
--- A long session must not cost anything to display, so only the sections
--- around the anchor — the message the user is looking at, the newest one
--- while following — are written to the buffer. What is left out is announced
--- by one marker line on each side, and scrolling into a marker extends the
--- selection (`Crust.Chat.Output` drives that from its scroll autocmd).
---
--- Rows are 0-based buffer rows, lines are 1-based indices into a section.

---@class Crust.Chat.Viewport.Opts
---@field enabled boolean false renders the whole transcript
---@field max_sections integer
---@field max_lines integer
---@field guard_lines integer
---@field markers { above: string, below: string }

---@class Crust.Chat.Viewport.Ref  a position, in transcript coordinates
---@field section integer
---@field offset integer rows below the section's first row

---@class Crust.Chat.Viewport
---@field private _buf integer
---@field private _transcript Crust.Chat.Transcript
---@field private _opts fun(): Crust.Chat.Viewport.Opts
---@field private _first integer first materialized section
---@field private _last integer last materialized section
---@field private _rows table<integer, integer> section index -> 0-based row
---@field private _anchor integer? section to keep, nil follows the tail
---@field private _markers { above: boolean, below: boolean } markers on screen
local Viewport = {}
Viewport.__index = Viewport

local Highlights = require("crust.ui.highlights")
local Mentions = require("crust.ui.mentions")
local Transcript = require("crust.ui.chat.transcript")

--- Highlights of the sections currently drawn, cleared on every redraw.
Viewport.ns = vim.api.nvim_create_namespace("crust.chat.output.highlights")

---@param buf integer
---@param transcript Crust.Chat.Transcript
---@param opts fun(): Crust.Chat.Viewport.Opts read on every use, so `setup`
--- after the panel was built still counts
---@return Crust.Chat.Viewport
function Viewport.new(buf, transcript, opts)
	local self = setmetatable({}, Viewport)

	self._buf = buf
	self._transcript = transcript
	self._opts = opts
	self._first = 1
	self._last = 0
	self._rows = {}
	self._anchor = nil
	self._markers = { above = false, below = false }

	return self
end

---@return Crust.Chat.Viewport.Opts
function Viewport:opts()
	return self._opts()
end

---@return integer first, integer last materialized sections
function Viewport:range()
	return self._first, self._last
end

---@param index integer
---@return boolean
function Viewport:rendered(index)
	return self._rows[index] ~= nil
end

--- 0-based first row of a section, nil when it is not materialized.
---@param index integer
---@return integer?
function Viewport:row(index)
	return self._rows[index]
end

--- Section the view is built around. nil follows the newest message.
---@param index integer?
function Viewport:set_anchor(index)
	self._anchor = index
end

---@return integer?
function Viewport:anchor()
	return self._anchor
end

--- Sections elided above and below the view.
---@return integer above, integer below
function Viewport:elided()
	return self._first - 1, self._transcript:count() - self._last
end

--- Sections that fit the budget around the anchor, never splitting one.
---@return integer first, integer last
function Viewport:select()
	local count = self._transcript:count()
	local opts = self:opts()
	if not opts.enabled then
		return 1, count
	end

	local anchor = math.min(math.max(self._anchor or count, 1), count)
	local first, last = anchor, anchor
	local rows = self._transcript:height(anchor)
	local sections = 1

	---@param height integer
	---@return boolean
	local function fits(height)
		return sections + 1 <= opts.max_sections and rows + height <= opts.max_lines
	end

	-- Grown one section at a time on each side, so the anchor keeps context
	-- below it (the answer) as well as above it (the question).
	while true do
		local grew = false

		if last < count and fits(self._transcript:height(last + 1)) then
			last = last + 1
			rows = rows + self._transcript:height(last)
			sections = sections + 1
			grew = true
		end

		if first > 1 and fits(self._transcript:height(first - 1)) then
			first = first - 1
			rows = rows + self._transcript:height(first)
			sections = sections + 1
			grew = true
		end

		if not grew then
			return first, last
		end
	end
end

---@private
---@param first integer 0-based
---@param last integer exclusive, -1 for the end
---@param lines string[]
function Viewport:_set(first, last, lines)
	vim.bo[self._buf].modifiable = true
	vim.api.nvim_buf_set_lines(self._buf, first, last, false, lines)
	vim.bo[self._buf].modifiable = false
end

---@private
---@param count integer elided sections
---@param key "above"|"below"
---@return string
function Viewport:_marker(count, key)
	local markers = self:opts().markers
	local format = markers and markers[key] or "%d more"
	local ok, text = pcall(string.format, format, count)
	return ok and text or format
end

--- Rewrite the whole window: pick the sections, draw them, highlight them.
function Viewport:rebuild()
	if not vim.api.nvim_buf_is_valid(self._buf) then
		return
	end

	local first, last = self:select()
	local lines, rows = self._transcript:render(first, last)
	local total = self._transcript:count()

	local offset = 0
	if first > 1 then
		table.insert(lines, 1, self:_marker(first - 1, "above"))
		offset = 1
	end
	if last < total then
		lines[#lines + 1] = ""
		lines[#lines + 1] = self:_marker(total - last, "below")
	end

	self._rows = {}
	for index, row in pairs(rows) do
		self._rows[index] = row + offset
	end
	self._first, self._last = first, last
	self._markers = { above = first > 1, below = last < total }

	self:_set(0, -1, lines)

	vim.api.nvim_buf_clear_namespace(self._buf, Viewport.ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(self._buf, Mentions.ns, 0, -1)
	for index = first, last do
		self:apply(index)
	end
	self:_apply_markers()
end

--- Draw the newest message under the ones already on screen.
---
--- The common case by far: a message arrives while the view follows the
--- conversation. Redrawing the whole window for it would make every message
--- cost as much as the view is long.
---@return boolean appended false when the view has to be rebuilt instead
function Viewport:extend_tail()
	local total = self._transcript:count()
	if self._last ~= total - 1 or self._markers.below then
		return false
	end

	-- Anything else — an eviction at the top, a budget that no longer fits —
	-- is a redraw.
	local first, last = self:select()
	if first ~= self._first or last ~= total then
		return false
	end

	local previous = self._transcript:section(total - 1)
	local row = self._rows[total - 1]
	if not previous or not row then
		return false
	end

	-- Opening a message trims the blank tail of the one before it.
	local at = row + #previous.lines
	local drawn = vim.api.nvim_buf_line_count(self._buf)
	if drawn > at then
		self:_set(at, drawn, {})
	end

	local lines, rows = self._transcript:render(total, total)
	self:_set(at, at, lines)

	self._rows[total] = at + rows[total]
	self._last = total
	self:apply(total)

	return true
end

--- Redraw the marker lines alone, e.g. after a message arrived off screen.
--- A marker that was not there yet needs the full redraw.
function Viewport:refresh_markers()
	local above, below = self:elided()
	local drawn = self._markers or { above = false, below = false }

	if drawn.above ~= (above > 0) or drawn.below ~= (below > 0) then
		return self:rebuild()
	end

	if above > 0 then
		self:_set(0, 1, { self:_marker(above, "above") })
		self:clear_rows(0, 1)
	end
	if below > 0 then
		local count = vim.api.nvim_buf_line_count(self._buf)
		self:_set(count - 1, count, { self:_marker(below, "below") })
		self:clear_rows(count - 1, count)
	end
	self:_apply_markers()
end

---@private
function Viewport:_apply_markers()
	local above, below = self:elided()
	local count = vim.api.nvim_buf_line_count(self._buf)

	if above > 0 then
		vim.api.nvim_buf_set_extmark(self._buf, Viewport.ns, 0, 0, { end_row = 1, hl_group = Highlights.ELISION })
	end
	if below > 0 then
		vim.api.nvim_buf_set_extmark(
			self._buf,
			Viewport.ns,
			count - 1,
			0,
			{ end_row = count, hl_group = Highlights.ELISION }
		)
	end
end

--- Write a section-local rewrite into the buffer.
---@param patch Crust.Chat.Patch?
---@return boolean applied false when the section is not materialized
function Viewport:patch(patch)
	if not patch or not vim.api.nvim_buf_is_valid(self._buf) then
		return false
	end

	local row = self._rows[patch.section]
	if not row then
		return false
	end

	local first = row + patch.first - 1
	self:_set(first, first + patch.removed, patch.lines)

	local delta = #patch.lines - patch.removed
	if delta ~= 0 then
		for index = patch.section + 1, self._last do
			if self._rows[index] then
				self._rows[index] = self._rows[index] + delta
			end
		end
	end

	return true
end

--- Clear the highlights of a row range, e.g. before a block is rewritten.
---@param first integer 0-based
---@param last integer exclusive
function Viewport:clear_rows(first, last)
	if vim.api.nvim_buf_is_valid(self._buf) then
		vim.api.nvim_buf_clear_namespace(self._buf, Viewport.ns, first, last)
	end
end

--- 0-based row of a block's first line, nil when it is not materialized.
---@param block Crust.Chat.Output.Block
---@return integer?
function Viewport:block_row(block)
	local row = self._rows[block.section]
	if not row then
		return nil
	end
	return row + block.first - 1
end

--- Draw a block's highlights, wherever it sits now.
---@param block Crust.Chat.Output.Block
function Viewport:apply_block(block)
	local row = self:block_row(block)
	if not row then
		return
	end

	for line, group in pairs(block.line_highlights or {}) do
		vim.api.nvim_buf_set_extmark(self._buf, Viewport.ns, row + line - 1, 0, { line_hl_group = group })
	end

	for _, hl in ipairs(block.highlights or {}) do
		vim.api.nvim_buf_set_extmark(self._buf, Viewport.ns, row + hl.line - 1, hl.col, {
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

--- Draw everything a section owns: its rule, its marks, its blocks and the
--- @mentions of a user message.
---@param index integer
function Viewport:apply(index)
	local row = self._rows[index]
	local section = self._transcript:section(index)
	if not row or not section then
		return
	end

	if section.separator and row > 0 then
		vim.api.nvim_buf_set_extmark(self._buf, Viewport.ns, row - 1, 0, {
			end_col = #Transcript.SEPARATOR,
			hl_group = Highlights.SEPARATOR,
		})
	end

	for _, mark in ipairs(section.marks) do
		vim.api.nvim_buf_set_extmark(self._buf, Viewport.ns, row + mark.line - 1, mark.col, {
			end_col = mark.end_col,
			hl_group = mark.group,
			priority = mark.priority,
		})
	end

	for _, block in ipairs(section.blocks) do
		self:apply_block(block)
	end

	if section.mentions then
		Mentions.highlight(self._buf, row, row + #section.lines)
	end
end

--- Re-scan a materialized section for @mentions.
---@param index integer
function Viewport:refresh_mentions(index)
	local row = self._rows[index]
	local section = self._transcript:section(index)
	if row and section then
		Mentions.highlight(self._buf, row, row + #section.lines)
	end
end

--- Rows covered by the blocks on screen, for the markdown exclusion.
---@return Crust.Regions.Range[]
function Viewport:block_ranges()
	local ranges = {}
	for index = self._first, self._last do
		local section = self._transcript:section(index)
		local row = self._rows[index]
		if section and row then
			for _, block in ipairs(section.blocks) do
				ranges[#ranges + 1] = {
					first = row + block.first - 1,
					last = row + block.first - 1 + block.count,
				}
			end
		end
	end
	return ranges
end

--- Turn a buffer row into a transcript position, so it survives a redraw.
--- Rows on a rule or a marker resolve to the section under them.
---@param row integer 0-based
---@return Crust.Chat.Viewport.Ref?
function Viewport:locate(row)
	local found = nil
	for index = self._first, self._last do
		local first = self._rows[index]
		if first and first <= row then
			found = index
		end
	end

	if not found then
		found = self._first
	end

	local first = self._rows[found]
	if not first then
		return nil
	end
	return { section = found, offset = math.max(row - first, 0) }
end

--- Buffer row of a remembered position, nil when its section is gone.
---@param ref Crust.Chat.Viewport.Ref?
---@return integer?
function Viewport:resolve(ref)
	if not ref then
		return nil
	end

	local row = self._rows[ref.section]
	local section = self._transcript:section(ref.section)
	if not row or not section then
		return nil
	end

	return row + math.min(ref.offset, math.max(#section.lines - 1, 0))
end

return Viewport
