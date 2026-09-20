--- Display spec for the `edit` tool: path as title, changed line counts as
--- body, rendered inline like `read`.
---
--- pi sends `{ path, edits = { { oldText, newText } } }` and answers with a
--- unified diff in `result.details.diff`.

local diff = require("crust.ui.chat.tools.diff")

---@type Crust.Chat.Tools.Spec
return {
	-- A counter fits on the title line, an error message does not.
	inline = function(display)
		return display.status ~= "error"
	end,

	title = diff.title,
	body_highlights = diff.body_highlights,
	preview_body = diff.preview_body,

	body = function(display)
		if display.status == "error" then
			return display:result_text()
		end

		if display.status == "pending" then
			return nil
		end

		local summary = diff.summary(display)
		if summary then
			return { summary }
		end

		-- No diff came back, fall back to the number of replacements asked for.
		local edits = display.args.edits
		if type(edits) == "table" and #edits > 0 then
			return { #edits .. (#edits == 1 and " edit" or " edits") }
		end

		return nil
	end,
}
