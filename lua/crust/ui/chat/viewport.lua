--- The window onto the transcript: which sections are materialized in the
--- output buffer, and where.
---
--- A long session must not cost anything to display, so only the sections
--- around the anchor — the message the user is looking at, the newest one
--- while following — are written to the buffer, plus the pinned head and tail
--- of the conversation (`keep`): the task it started from and the messages it
--- just produced are what one scrolls back for, so they are never elided.
---
--- The result is one to three runs of sections (`segments`), separated by a
--- marker line that announces what was left out. Scrolling into a marker
--- extends the selection (`Crust.Chat.Output` drives that from its scroll
--- autocmd).
---
--- Rows are 0-based buffer rows, lines are 1-based indices into a section.

---@class Crust.Chat.Viewport.Opts
---@field enabled boolean false renders the whole transcript
---@field max_sections integer
---@field max_lines integer
---@field guard_lines integer
---@field keep? { first: integer, last: integer } sections pinned at each end
---@field markers { above: string, below: string }

---@class Crust.Chat.Viewport.Segment  a contiguous run of drawn sections
---@field first integer
---@field last integer

---@class Crust.Chat.Viewport.Gap  an elision marker between two segments
---@field row integer 0-based row of the marker line
---@field count integer elided sections
---@field before integer last section above the gap, 0 above the first one
---@field after integer? first section below it, nil past the last one
---@field key "above"|"below" marker format the gap is drawn with

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
---@field private _segments Crust.Chat.Viewport.Segment[] drawn runs, in order
---@field private _gaps Crust.Chat.Viewport.Gap[] markers on screen, in order
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
	self._segments = {}
	self._gaps = {}

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

--- The elision markers on screen, in row order.
---@return Crust.Chat.Viewport.Gap[]
function Viewport:gaps()
	return self._gaps
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

--- Sections elided above and below the drawn range. Sections elided *inside*
--- it, between two segments, count as above when they sit before the anchor.
---@return integer above, integer below
function Viewport:elided()
	local above, below = 0, 0
	for _, gap in ipairs(self._gaps) do
		if gap.key == "above" then
			above = above + gap.count
		else
			below = below + gap.count
		end
	end
	return above, below
end

--- The drawn runs of sections: the pinned head, the window around the anchor
--- and the pinned tail, merged wherever they touch.
---@return Crust.Chat.Viewport.Segment[]
function Viewport:segments()
	local count = self._transcript:count()
	local opts = self:opts()
	if not opts.enabled then
		return { { first = 1, last = count } }
	end

	local keep = opts.keep or {}
	local head = math.min(math.max(keep.first or 0, 0), count)
	local tail = math.min(math.max(keep.last or 0, 0), count)

	---@type Crust.Chat.Viewport.Segment[]
	local wanted = {}
	if head > 0 then
		wanted[#wanted + 1] = { first = 1, last = head }
	end
	-- The pinned ends are mandatory, so the budget only bounds the window.
	local first, last = self:select()
	wanted[#wanted + 1] = { first = first, last = last }
	if tail > 0 then
		wanted[#wanted + 1] = { first = count - tail + 1, last = count }
	end

	table.sort(wanted, function(a, b)
		return a.first < b.first
	end)

	---@type Crust.Chat.Viewport.Segment[]
	local merged = {}
	for _, segment in ipairs(wanted) do
		local previous = merged[#merged]
		-- Touching runs are joined: a marker for zero messages is noise.
		if previous and segment.first <= previous.last + 1 then
			previous.last = math.max(previous.last, segment.last)
		else
			merged[#merged + 1] = { first = segment.first, last = segment.last }
		end
	end

	return merged
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

--- Segment holding the anchor, so a gap can tell whether what it hides is
--- older or newer than what the user is looking at.
---@private
---@param segments Crust.Chat.Viewport.Segment[]
---@return integer
function Viewport:_pivot(segments)
	local anchor = self._anchor or self._transcript:count()
	for index, segment in ipairs(segments) do
		if anchor >= segment.first and anchor <= segment.last then
			return index
		end
	end
	return #segments
end

--- True when `segments` is what is already on screen.
---@private
---@param segments Crust.Chat.Viewport.Segment[]
---@return boolean
function Viewport:_drawn(segments)
	if #segments ~= #self._segments then
		return false
	end
	for index, segment in ipairs(segments) do
		local drawn = self._segments[index]
		if drawn.first ~= segment.first or drawn.last ~= segment.last then
			return false
		end
	end
	return true
end

--- Rewrite the whole window: pick the sections, draw them, highlight them.
function Viewport:rebuild()
	if not vim.api.nvim_buf_is_valid(self._buf) then
		return
	end

	local total = self._transcript:count()
	local segments = self:segments()
	local pivot = self:_pivot(segments)

	local lines = {}
	local rows = {}
	---@type Crust.Chat.Viewport.Gap[]
	local gaps = {}

	---@param before integer
	---@param after integer?
	---@param at integer segment the gap sits in front of
	local function gap(before, after, at)
		local key = at <= pivot and "above" or "below"
		local count = (after or total + 1) - before - 1
		gaps[#gaps + 1] = { row = #lines, count = count, before = before, after = after, key = key }
		lines[#lines + 1] = self:_marker(count, key)
	end

	for index, segment in ipairs(segments) do
		local previous = segments[index - 1]
		if previous then
			lines[#lines + 1] = ""
			gap(previous.last, segment.first, index)
		elseif segment.first > 1 then
			gap(0, segment.first, index)
		end

		local offset = #lines
		local drawn, at = self._transcript:render(segment.first, segment.last)
		vim.list_extend(lines, drawn)
		for section, row in pairs(at) do
			rows[section] = row + offset
		end
	end

	local tail = segments[#segments]
	if tail and tail.last < total then
		lines[#lines + 1] = ""
		gap(tail.last, nil, #segments + 1)
	end

	if #lines == 0 then
		lines[1] = ""
	end

	self._rows = rows
	self._segments = segments
	self._gaps = gaps
	self._first = segments[1] and segments[1].first or 1
	self._last = tail and tail.last or 0

	self:_set(0, -1, lines)

	vim.api.nvim_buf_clear_namespace(self._buf, Viewport.ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(self._buf, Mentions.ns, 0, -1)
	for _, segment in ipairs(segments) do
		for index = segment.first, segment.last do
			self:apply(index)
		end
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
	local tail = self._segments[#self._segments]
	-- A tail that stops short of the section before the new one has a marker
	-- under it: the message does not belong there.
	if not tail or tail.last ~= total - 1 then
		return false
	end

	-- Anything else — an eviction at the top, a pinned head that moved, a
	-- budget that no longer fits — is a redraw.
	local segments = self:segments()
	local grown = segments[#segments]
	if not grown or grown.last ~= total or grown.first ~= tail.first then
		return false
	end
	segments[#segments] = { first = tail.first, last = tail.last }
	if not self:_drawn(segments) then
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
	tail.last = total
	self:apply(total)

	return true
end

--- Redraw the marker lines alone, e.g. after a message arrived off screen.
--- A marker that was not there yet, or a pinned end that moved, needs the
--- full redraw.
function Viewport:refresh_markers()
	local segments = self:segments()
	if not self:_drawn(segments) then
		return self:rebuild()
	end

	local total = self._transcript:count()
	for _, gap in ipairs(self._gaps) do
		local count = (gap.after or total + 1) - gap.before - 1
		if count ~= gap.count then
			gap.count = count
			self:_set(gap.row, gap.row + 1, { self:_marker(count, gap.key) })
			self:clear_rows(gap.row, gap.row + 1)
		end
	end
	self:_apply_markers()
end

---@private
function Viewport:_apply_markers()
	for _, gap in ipairs(self._gaps) do
		vim.api.nvim_buf_set_extmark(self._buf, Viewport.ns, gap.row, 0, {
			end_row = gap.row + 1,
			hl_group = Highlights.ELISION,
		})
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

	-- Everything the rewrite touches is redrawn: `nvim_buf_set_lines` drops
	-- the marks of the rows it replaces and drags the rest to the end of the
	-- new text, so they are cleared first and put back after.
	local touched = self:_touched(patch)
	local first = row + patch.first - 1

	if touched then
		self:clear_rows(row + touched.first - 1, row + math.max(touched.last, patch.first + patch.removed - 1))
	end
	self:_set(first, first + patch.removed, patch.lines)
	if touched then
		self:_redraw(patch.section, touched)
	end

	local delta = #patch.lines - patch.removed
	if delta ~= 0 then
		for index, at in pairs(self._rows) do
			if index > patch.section then
				self._rows[index] = at + delta
			end
		end
		for _, gap in ipairs(self._gaps) do
			-- A gap sits under the last section above it.
			if gap.before >= patch.section then
				gap.row = gap.row + delta
			end
		end
	end

	return true
end

--- Section to re-anchor on when the window comes within `guard` rows of an
--- elision marker, nil while every marker is out of reach.
---@param top integer 1-based first visible line
---@param bottom integer 1-based last visible line
---@param guard integer
---@return integer?
function Viewport:reach(top, bottom, guard)
	for _, gap in ipairs(self._gaps) do
		local line = gap.row + 1
		-- Anchoring below a gap pulls earlier messages in, anchoring above it
		-- pulls later ones.
		local earlier = gap.after
		local later = gap.before > 0 and gap.before or nil

		if line < top then
			if top - line <= guard then
				return earlier or later
			end
		elseif line > bottom then
			if line - bottom <= guard then
				return later or earlier
			end
		-- The marker itself is on screen: grow towards the closer edge.
		elseif line - top <= bottom - line then
			return earlier or later
		else
			return later or earlier
		end
	end

	return nil
end

---@class Crust.Chat.Viewport.Touched  what a patch has to redraw
---@field first integer 1-based first section line covered
---@field last integer 1-based last section line covered
---@field blocks Crust.Chat.Output.Block[]
---@field marks Crust.Chat.Mark[]

--- Marks and blocks a rewrite lands on, nil when it lands on plain text.
---
--- A patch routinely reaches back into a finished call: appending a block
--- continues the last line of the section, which is the previous block's
--- last line whenever the two are stacked without a gap. The range is grown
--- to whole blocks, they are redrawn as a unit.
---@private
---@param patch Crust.Chat.Patch
---@return Crust.Chat.Viewport.Touched?
function Viewport:_touched(patch)
	local section = self._transcript:section(patch.section)
	if not section then
		return nil
	end

	local first = patch.first
	-- The rewrite covers the removed rows and the ones written in their place.
	local last = patch.first + math.max(patch.removed, #patch.lines) - 1

	---@type Crust.Chat.Output.Block[]
	local blocks = {}
	for _, block in ipairs(section.blocks) do
		local block_last = block.first + block.count - 1
		if block_last >= first and block.first <= last then
			blocks[#blocks + 1] = block
			first = math.min(first, block.first)
			last = math.max(last, block_last)
		end
	end

	---@type Crust.Chat.Mark[]
	local marks = {}
	for _, mark in ipairs(section.marks) do
		if mark.line >= first and mark.line <= last then
			marks[#marks + 1] = mark
		end
	end

	if #blocks == 0 and #marks == 0 then
		return nil
	end

	return { first = first, last = last, blocks = blocks, marks = marks }
end

--- Draw the marks and blocks a patch overwrote, in their new places.
---@private
---@param index integer section
---@param touched Crust.Chat.Viewport.Touched
function Viewport:_redraw(index, touched)
	local row = self._rows[index]
	if not row then
		return
	end

	for _, mark in ipairs(touched.marks) do
		vim.api.nvim_buf_set_extmark(self._buf, Viewport.ns, row + mark.line - 1, mark.col, {
			end_col = mark.end_col,
			hl_group = mark.group,
			priority = mark.priority,
		})
	end

	for _, block in ipairs(touched.blocks) do
		self:apply_block(block)
	end
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

--- Block covering a buffer row, nil when the row is prose or a marker.
---@param row integer 0-based
---@return Crust.Chat.Output.Block?
function Viewport:block_at(row)
	for index, at in pairs(self._rows) do
		local section = self._transcript:section(index)
		for _, block in ipairs(section and section.blocks or {}) do
			local first = at + block.first - 1
			if row >= first and row < first + block.count then
				return block
			end
		end
	end

	return nil
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
	for index in pairs(self._rows) do
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
