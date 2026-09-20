--- Display spec for the `write` tool: rendered exactly like `edit`, a path as
--- title and changed line counts as body.
---
--- pi sends `{ path, content }` and answers with a unified diff in
--- `result.details.diff` when the file already existed.

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

		-- No diff came back, fall back to the size of the written file.
		local content = display.args.content
		if type(content) == "string" and content ~= "" then
			local lines = #vim.split(content, "\n", { plain = true })
			return { lines .. (lines == 1 and " line" or " lines") }
		end

		return nil
	end,
}
