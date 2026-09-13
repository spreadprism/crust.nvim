--- Treesitter highlighting for standalone strings.
---
--- Tool titles and bodies are not part of the output buffer's markdown tree,
--- so they are parsed on their own with `get_string_parser` and turned into
--- plain highlight ranges the output panel can apply as extmarks.

---@class Crust.Syntax.Range
---@field line integer 1-based line within the parsed text
---@field col integer byte offset, 0-based
---@field end_col integer byte offset, exclusive
---@field group string highlight group, e.g. "@function.call"

---@class Crust.Syntax
local M = {}

---@type table<string, boolean>
local supported = {}

--- True when the parser for `lang` is installed.
---@param lang string treesitter language, e.g. "bash"
---@return boolean
function M.available(lang)
	if supported[lang] == nil then
		-- language.add reports failure with a nil return, not an error.
		local ok, added = pcall(vim.treesitter.language.add, lang)
		supported[lang] = ok and added ~= nil and added ~= false and vim.treesitter.query.get(lang, "highlights") ~= nil
	end
	return supported[lang]
end

--- Highlight ranges for a piece of text.
--- Multi-line nodes are skipped: callers render line by line.
---@param text string
---@param lang string
---@return Crust.Syntax.Range[]?
function M.highlight(text, lang)
	if text == "" or not M.available(lang) then
		return nil
	end

	local query = vim.treesitter.query.get(lang, "highlights")
	if not query then
		return nil
	end

	local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
	if not ok then
		return nil
	end

	local tree = parser:parse(true)[1]
	if not tree then
		return nil
	end

	local ranges = {}
	for id, node in query:iter_captures(tree:root(), text) do
		local start_row, start_col, end_row, end_col = node:range()
		if start_row == end_row then
			ranges[#ranges + 1] = {
				line = start_row + 1,
				col = start_col,
				end_col = end_col,
				group = "@" .. query.captures[id],
			}
		end
	end

	return ranges
end

return M
