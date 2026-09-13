--- Keep parts of a buffer out of its treesitter tree.
---
--- Tool blocks are written as markdown-ish text (`> `, `---`, backticks), but
--- they are ours, not the agent's prose. Excluding their rows from the
--- markdown parser leaves them raw: the treesitter highlighter has no nodes
--- there, and render-markdown.nvim, which walks the same language trees,
--- skips them too.

---@class Crust.Regions
local M = {}

---@class Crust.Regions.Range
---@field first integer 0-based first row
---@field last integer 0-based row after the last one

--- Rows not covered by `excluded`, as { first, last } pairs.
---@param line_count integer
---@param excluded Crust.Regions.Range[] may overlap and be unsorted
---@return Crust.Regions.Range[]
function M.complement(line_count, excluded)
	local sorted = vim.deepcopy(excluded)
	table.sort(sorted, function(a, b)
		return a.first < b.first
	end)

	local included = {}
	local row = 0
	for _, range in ipairs(sorted) do
		if range.first > row then
			included[#included + 1] = { first = row, last = math.min(range.first, line_count) }
		end
		row = math.max(row, range.last)
	end

	if row < line_count then
		included[#included + 1] = { first = row, last = line_count }
	end

	return included
end

--- Translate row ranges into treesitter regions.
---@param buf integer
---@param ranges Crust.Regions.Range[]
---@return table[] regions
function M.to_regions(buf, ranges)
	local line_count = vim.api.nvim_buf_line_count(buf)

	local regions = {}
	for _, range in ipairs(ranges) do
		local first = math.max(range.first, 0)
		local last = math.min(range.last, line_count)
		if first < last then
			regions[#regions + 1] = {
				{
					first,
					0,
					vim.api.nvim_buf_get_offset(buf, first),
					last,
					0,
					vim.api.nvim_buf_get_offset(buf, last),
				},
			}
		end
	end

	return regions
end

--- Parse `buf` as if only the rows outside `excluded` existed.
---@param buf integer
---@param excluded Crust.Regions.Range[]
---@return boolean applied false when the buffer has no parser
function M.exclude(buf, excluded)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end

	local ok, parser = pcall(vim.treesitter.get_parser, buf)
	if not ok or not parser then
		return false
	end

	local line_count = vim.api.nvim_buf_line_count(buf)
	local regions = M.to_regions(buf, M.complement(line_count, excluded))
	if #regions == 0 then
		-- Everything is excluded, an empty list would mean "the whole buffer".
		regions = { { { 0, 0, 0, 0, 0, 0 } } }
	end

	parser:set_included_regions(regions)
	pcall(parser.parse, parser, true)

	return true
end

return M
