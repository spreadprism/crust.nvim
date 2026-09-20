--- The chat transcript: the conversation as data, independent of any buffer.
---
--- The output panel used to *be* the buffer, so every write scanned the whole
--- scrollback and every session paid for its own length. The transcript owns
--- the text instead, split into sections — one `---` delimited message each —
--- and the buffer became a projection of a slice of it (`crust.ui.chat.viewport`).
---
--- Every mutation is section local and reports a `Crust.Chat.Patch`, so the
--- view can rewrite a handful of rows instead of re-rendering the history.

---@class Crust.Chat.Mark  a highlight, relative to its section
---@field line integer 1-based index into the section lines
---@field col integer byte offset, 0-based
---@field end_col integer byte offset, exclusive
---@field group string highlight group
---@field priority? integer extmark priority
---@field overlay? string text drawn over the range

---@class Crust.Chat.Output.Block  a rewritable run of lines, e.g. a tool call
---@field id integer
---@field section integer index of the owning section
---@field first integer 1-based index of the block's first line in the section
---@field count integer lines the block occupies
---@field highlights? Crust.Chat.Tools.Highlight[]
---@field line_highlights? table<integer, string>

---@class Crust.Chat.Section
---@field id integer stable across the transcript's life
---@field lines string[]
---@field marks Crust.Chat.Mark[] highlights owned by the section itself
---@field blocks Crust.Chat.Output.Block[] in line order
---@field mentions boolean re-scan for `@mentions` when the section is drawn
---@field separator boolean draw a `---` rule before the section

---@class Crust.Chat.Patch  a section-local rewrite, in section coordinates
---@field section integer
---@field first integer 1-based first rewritten line
---@field removed integer lines the rewrite replaces
---@field lines string[] lines written in their place

---@class Crust.Chat.Transcript
---@field private _sections Crust.Chat.Section[]
---@field private _next_section integer
---@field private _next_block integer
local Transcript = {}
Transcript.__index = Transcript

--- Rule drawn between two messages.
Transcript.SEPARATOR = "---"

---@return Crust.Chat.Transcript
function Transcript.new()
	local self = setmetatable({}, Transcript)
	self:clear()
	return self
end

--- Drop everything and start over with one empty section.
function Transcript:clear()
	self._sections = {}
	self._next_section = 0
	self._next_block = 0
	self:_push(false)
end

---@private
---@param separator boolean
---@return Crust.Chat.Section
function Transcript:_push(separator)
	self._next_section = self._next_section + 1

	---@type Crust.Chat.Section
	local section = {
		id = self._next_section,
		lines = { "" },
		marks = {},
		blocks = {},
		mentions = false,
		separator = separator,
	}

	self._sections[#self._sections + 1] = section
	return section
end

---@return Crust.Chat.Section[]
function Transcript:sections()
	return self._sections
end

---@return integer
function Transcript:count()
	return #self._sections
end

---@param index integer
---@return Crust.Chat.Section?
function Transcript:section(index)
	return self._sections[index]
end

---@return Crust.Chat.Section section, integer index
function Transcript:last()
	return self._sections[#self._sections], #self._sections
end

--- Rows a section takes once drawn, its leading rule included.
---@param index integer
---@return integer
function Transcript:height(index)
	local section = self._sections[index]
	if not section then
		return 0
	end
	return #section.lines + (section.separator and 2 or 0)
end

--- Index of the last non-blank line of a section, 0 when it has none.
---@param section Crust.Chat.Section
---@return integer
local function last_content(section)
	for index = #section.lines, 1, -1 do
		if section.lines[index] ~= "" then
			return index
		end
	end
	return 0
end

--- Drop the trailing blank lines of the open section, so rules and blocks
--- never stack up. At least one line is kept: it is the line appends
--- continue, exactly like the last line of a buffer.
---@private
---@return boolean has_content false when the whole transcript is blank
---@return integer trimmed lines left in the section
function Transcript:_trim()
	local section = self._sections[#self._sections]
	local keep = last_content(section)

	for index = #section.lines, math.max(keep, 1) + 1, -1 do
		section.lines[index] = nil
	end
	if #section.lines == 0 then
		section.lines[1] = ""
	end

	if keep > 0 then
		return true, #section.lines
	end
	-- A blank open section still leaves the earlier messages standing.
	return #self._sections > 1, #section.lines
end

--- True while nothing has been written yet.
---@return boolean
function Transcript:is_empty()
	if #self._sections > 1 then
		return false
	end
	return last_content(self._sections[1]) == 0
end

--- Append raw text to the open section, continuing its last line.
---@param text string
---@return Crust.Chat.Patch
function Transcript:append(text)
	local section, index = self:last()
	local parts = vim.split(text, "\n", { plain = true })

	local first = #section.lines
	section.lines[first] = section.lines[first] .. parts[1]
	for part = 2, #parts do
		section.lines[#section.lines + 1] = parts[part]
	end

	return {
		section = index,
		first = first,
		removed = 1,
		lines = vim.list_slice(section.lines, first),
	}
end

--- Open a new message. The first message reuses the empty section the
--- transcript starts with, so it gets no rule above it.
---@param head string header line, e.g. "󰚩 Mar 7 2024, 09:05"
---@param marks? Crust.Chat.Mark[] highlights of the header line
---@return Crust.Chat.Section section, integer index
function Transcript:begin_section(head, marks)
	local has_content = self:_trim()

	local section = self._sections[#self._sections]
	if has_content then
		section = self:_push(true)
	end

	section.lines = { head, "", "" }
	section.marks = marks or {}
	section.blocks = {}
	section.mentions = false

	return section, #self._sections
end

--- Append a rewritable block to the open section, isolated by one blank line
--- on each side so streamed text never reads as part of it.
---@param lines string[]
---@param highlights? Crust.Chat.Tools.Highlight[]
---@param line_highlights? table<integer, string>
---@param compact? boolean append directly under the previous line
---@return Crust.Chat.Output.Block block, Crust.Chat.Patch patch
function Transcript:append_block(lines, highlights, line_highlights, compact)
	local section, index = self:last()

	local before = #section.lines
	local has_content, trimmed = self:_trim()
	local prefix = has_content and (compact and "\n" or "\n\n") or ""

	-- The first rewritten row: the trim may have cut rows away, and the
	-- append continues whatever line survived it.
	local first = math.max(math.min(trimmed, before), 1)

	self:append(prefix .. table.concat(lines, "\n") .. "\n\n")

	self._next_block = self._next_block + 1
	---@type Crust.Chat.Output.Block
	local block = {
		id = self._next_block,
		section = index,
		-- The append leaves two blank lines under the block.
		first = #section.lines - #lines - 1,
		count = #lines,
		highlights = highlights,
		line_highlights = line_highlights,
	}
	section.blocks[#section.blocks + 1] = block

	return block, {
		section = index,
		first = first,
		removed = before - first + 1,
		lines = vim.list_slice(section.lines, first),
	}
end

--- Rewrite a block in place, wherever its section has drifted to.
---@param block Crust.Chat.Output.Block
---@param lines string[]
---@param highlights? Crust.Chat.Tools.Highlight[]
---@param line_highlights? table<integer, string>
---@return Crust.Chat.Patch? patch nil when the block is gone, e.g. after a clear
function Transcript:replace_block(block, lines, highlights, line_highlights)
	local section = self._sections[block.section]
	if not section or not vim.tbl_contains(section.blocks, block) then
		-- The transcript was cleared under the block, e.g. a session switch.
		return nil
	end

	local first, count = block.first, block.count
	local kept = vim.list_slice(section.lines, 1, first - 1)
	vim.list_extend(kept, lines)
	vim.list_extend(kept, section.lines, first + count)
	section.lines = kept

	local delta = #lines - count
	block.count = #lines
	block.highlights = highlights
	block.line_highlights = line_highlights

	if delta ~= 0 then
		for _, other in ipairs(section.blocks) do
			if other.first > first then
				other.first = other.first + delta
			end
		end
	end

	return { section = block.section, first = first, removed = count, lines = lines }
end

--- True when nothing but blank lines follows the block, so the next block can
--- be stacked directly under it.
---@param block Crust.Chat.Output.Block
---@return boolean
function Transcript:block_ends_transcript(block)
	if block.section ~= #self._sections then
		return false
	end

	local section = self._sections[block.section]
	return last_content(section) == block.first + block.count - 1
end

--- Draw a range of sections, rules included.
---@param first? integer defaults to the first section
---@param last? integer defaults to the last section
---@return string[] lines
---@return table<integer, integer> rows 0-based first row of each section
function Transcript:render(first, last)
	first = first or 1
	last = last or #self._sections

	local out = {}
	local rows = {}

	for index = first, last do
		local section = self._sections[index]
		if section then
			if section.separator then
				out[#out + 1] = ""
				out[#out + 1] = Transcript.SEPARATOR
			end
			rows[index] = #out
			vim.list_extend(out, section.lines)
		end
	end

	if #out == 0 then
		out[1] = ""
	end

	return out, rows
end

--- The whole conversation as text, whatever the view shows.
---@return string[]
function Transcript:lines()
	return (self:render())
end

return Transcript
