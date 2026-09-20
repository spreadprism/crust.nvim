--- `@path` expander: the model gets the file, the user keeps the mention.
---
--- `@justfile` is replaced with the mention followed by a fenced block of
--- the file's current content. Unsaved changes count: when the path is open
--- in a loaded buffer the buffer lines win over what is on disk, so the
--- model sees the same text the user is looking at.

---@class Crust.Expansion.File : Crust.Expansion.Expander
local M = {}

M.name = "file"

--- Upper bound on an expanded file. Anything past it is cut, with a note, so
--- one `@` on a huge log cannot blow up the prompt.
M.MAX_BYTES = 100 * 1024

--- Spans that look like a mention. `crust.ui.mentions` owns what a mention
--- is, so the highlight and the expansion can never disagree.
---@param text string
---@return Crust.Expansion.Match[]
function M.trigger(text)
	local mentions = require("crust.ui.mentions")

	local matches = {}
	local offset = 0
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		for _, range in ipairs(mentions.ranges(line)) do
			matches[#matches + 1] = {
				first = offset + range.col + 1,
				last = offset + range.end_col,
				text = line:sub(range.col + 1, range.end_col),
			}
		end
		offset = offset + #line + 1
	end

	return matches
end

--- Absolute path behind a plain path, nil when it is not a readable file.
---@param path string no leading "@", no line range
---@return string?
function M.resolve(path)
	-- Callers used to pass the mention itself; keep that working.
	path = path:gsub("^@", "")
	if path == "" then
		return nil
	end

	local full = vim.fn.expand(path)
	if not vim.startswith(full, "/") then
		full = vim.fs.joinpath(vim.fn.getcwd(), full)
	end
	full = vim.fs.normalize(full)

	if vim.fn.filereadable(full) ~= 1 then
		return nil
	end
	return full
end

---@class Crust.Expansion.File.Target
---@field path string absolute
---@field first integer? 1-based first line of the requested range
---@field last integer? inclusive, nil with `first` set means "to the end"

--- Split a mention into a file and an optional line range: `@file:12`,
--- `@file:12-40` and `@file:12-` all work. The whole mention is tried as a
--- path first, so a file whose name really ends in `:12` still resolves.
---@param mention string including the leading "@"
---@return Crust.Expansion.File.Target?
function M.target(mention)
	local raw = mention:sub(2)

	local path = M.resolve(raw)
	if path then
		return { path = path }
	end

	local base, range = raw:match("^(.+):(%d[%d%-]*)$")
	if not base then
		return nil
	end

	path = M.resolve(base)
	if not path then
		return nil
	end

	local first, last = range:match("^(%d+)%-(%d*)$")
	if not first then
		first = range:match("^(%d+)$")
		last = first
	end
	if not first then
		return nil
	end

	first, last = tonumber(first), tonumber(last)
	if last and last < first then
		first, last = last, first
	end

	return { path = path, first = math.max(first, 1), last = last }
end

--- Lines of `path`, from the loaded buffer when there is one.
---@param path string absolute
---@return string[]
local function content(path)
	local buf = vim.fn.bufnr(path)
	if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
		return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	end
	return vim.fn.readfile(path)
end

--- A fence long enough to survive backticks inside the content.
---@param text string
---@return string
local function fence(text)
	local longest = 2
	for run in text:gmatch("`+") do
		longest = math.max(longest, #run)
	end
	return string.rep("`", longest + 1)
end

--- Mention, then the file in a fenced block tagged with its filetype. The
--- mention above the fence is the path, so the fence does not repeat it. A
--- range only sends those lines, and the fence carries the resolved numbers
--- — `:40-` or a range past the end say nothing about where the slice
--- actually ends, so the model still needs them to quote real lines.
---@param match Crust.Expansion.Match
---@return string?
function M.expansion(match)
	local target = M.target(match.text)
	if not target then
		return nil
	end

	local lines = content(target.path)
	---@type string " lines=<first>-<last>", empty for a whole file
	local label = ""
	if target.first then
		local last = math.min(target.last or #lines, #lines)
		if target.first > #lines then
			return nil
		end
		label = " lines=" .. target.first .. "-" .. last
		lines = vim.list_slice(lines, target.first, last)
	end

	local text = table.concat(lines, "\n")
	if #text > M.MAX_BYTES then
		text = text:sub(1, M.MAX_BYTES) .. "\n… truncated at " .. M.MAX_BYTES .. " bytes"
	end

	-- Content sniffing is wrong for a slice (no shebang, no modeline), so a
	-- ranged mention goes by filename alone.
	local lang = vim.filetype.match({
		filename = target.path,
		contents = not target.first and vim.split(text, "\n", { plain = true }) or nil,
	}) or ""
	local bounds = fence(text)

	return table.concat({
		match.text,
		"",
		bounds .. lang .. label,
		text,
		bounds,
	}, "\n")
end

return M
