--- Display spec for a skill load. Pi sends no skill event: the model loads a
--- skill by reading its `SKILL.md`, so `Tools:render` relabels that read, and
--- a `/skill:name` command is expanded into the prompt, so the chat panel
--- builds a display of its own with `name` as the only argument.

---@param path string
---@return string
local function skill_name(path)
	local base = vim.fn.fnamemodify(path, ":t")
	if base:lower() == "skill.md" then
		return vim.fn.fnamemodify(path, ":h:t")
	end
	return vim.fn.fnamemodify(path, ":t:r")
end

---@type Crust.Chat.Tools.Spec
return {
	-- A line count fits on the title line, an error message does not.
	inline = function(display)
		return display.status ~= "error"
	end,

	title = function(display)
		local name = display.args.name
		if type(name) == "string" and name ~= "" then
			return name
		end

		local path = display.args.path or display.args.file_path
		if type(path) ~= "string" or path == "" then
			return ""
		end
		return skill_name(path)
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
		return { count .. " lines loaded" }
	end,
}
