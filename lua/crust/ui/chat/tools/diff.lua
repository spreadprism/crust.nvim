--- Shared diff accounting for tool specs that write files (`edit`, `write`).

local M = {}

local Highlights = require("crust.ui.highlights")

--- Added and removed line counts from `result.details.diff`, or nil when there
--- is none.
---@param display Crust.Chat.Tools.Display
---@return integer? added
---@return integer? removed
function M.counts(display)
	local details = display.result and display.result.details
	local diff = details and details.diff
	if type(diff) ~= "string" then
		return nil, nil
	end

	local added, removed = 0, 0
	for _, line in ipairs(vim.split(diff, "\n", { plain = true })) do
		local first = line:sub(1, 1)
		if first == "+" then
			added = added + 1
		elseif first == "-" then
			removed = removed + 1
		end
	end
	return added, removed
end

--- The `+3 -0` counter line, nil when the result carried no diff.
---@param display Crust.Chat.Tools.Display
---@return string?
function M.summary(display)
	local added, removed = M.counts(display)
	if not added then
		return nil
	end
	return "+" .. added .. " -" .. removed
end

--- Colour the two counters like a diff: `+3` as DiffAdd, `-0` as DiffDelete.
--- Nil for any other body, e.g. "2 edits" or an error message, which keeps
--- the plain body group.
---@param display Crust.Chat.Tools.Display
---@return Crust.Ui.Ansi.Range[]?
function M.body_highlights(display)
	local summary = M.summary(display)
	if not summary or display:body()[1] ~= summary then
		return nil
	end

	local added, removed = summary:match("^(%S+) (%S+)$")
	return {
		{ line = 1, col = 0, end_col = #added, group = Highlights.DIFF_ADD },
		{ line = 1, col = #added + 1, end_col = #added + 1 + #removed, group = Highlights.DIFF_DELETE },
	}
end

--- Path argument shortened for display, or "" when absent.
---@param display Crust.Chat.Tools.Display
---@return string
function M.title(display)
	local path = display.args.path or display.args.file_path
	if type(path) ~= "string" or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":~:.")
end

--- The unified diff pi answered with, for the preview float. The result text
--- of a write is a confirmation line, the diff is the interesting part.
---@param display Crust.Chat.Tools.Display
---@return string?, string? text, treesitter language
function M.preview_body(display)
	local details = display.result and display.result.details
	local diff = details and details.diff
	if type(diff) ~= "string" or diff == "" then
		return nil, nil
	end
	return diff, "diff"
end

return M
