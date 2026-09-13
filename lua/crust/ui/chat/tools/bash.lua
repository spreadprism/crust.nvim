--- Display spec for the `bash` tool: command as title, output tail as body.

local MAX_BODY_LINES = 10

---@type Crust.Chat.Tools.Spec
return {
	title_lang = "bash",
	title_prefix = "> ",
	body_prefix = "> ",

	title = function(display)
		local command = display.args.command
		if type(command) ~= "string" or command == "" then
			return ""
		end
		return (command:gsub("%s+", " "))
	end,

	body = function(display)
		local text = display:result_text()
		if not text or text == "" then
			return nil
		end

		local lines = vim.split(vim.trim(text), "\n", { plain = true })
		if #lines <= MAX_BODY_LINES then
			return lines
		end

		local tail = vim.list_slice(lines, #lines - MAX_BODY_LINES + 1, #lines)
		table.insert(tail, 1, "… " .. (#lines - MAX_BODY_LINES) .. " more lines")
		return tail
	end,
}
