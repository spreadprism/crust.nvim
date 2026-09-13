--- Display spec for the `edit` tool: path as title, changed line counts as
--- body, rendered inline like `read`.
---
--- pi sends `{ path, edits = { { oldText, newText } } }` and answers with a
--- unified diff in `result.details.diff`.

--- Added and removed line counts from a diff, or nil when there is none.
---@param display Crust.Chat.Tools.Display
---@return integer? added
---@return integer? removed
local function diff_counts(display)
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

---@type Crust.Chat.Tools.Spec
return {
	-- A counter fits on the title line, an error message does not.
	inline = function(display)
		return display.status ~= "error"
	end,

	title = function(display)
		local path = display.args.path or display.args.file_path
		if type(path) ~= "string" or path == "" then
			return ""
		end
		return vim.fn.fnamemodify(path, ":~:.")
	end,

	body = function(display)
		if display.status == "error" then
			return display:result_text()
		end

		if display.status == "pending" then
			return nil
		end

		local added, removed = diff_counts(display)
		if added then
			return { "+" .. added .. " -" .. removed }
		end

		-- No diff came back, fall back to the number of replacements asked for.
		local edits = display.args.edits
		if type(edits) == "table" and #edits > 0 then
			return { #edits .. (#edits == 1 and " edit" or " edits") }
		end

		return nil
	end,
}
