--- Display spec for the `read` tool: path as title, line count as body.

---@type Crust.Chat.Tools.Spec
return {
	inline = true,

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

		local text = display:result_text()
		if not text or text == "" then
			return nil
		end

		local count = select(2, text:gsub("\n", "\n")) + 1
		return { count .. " lines" }
	end,
}
