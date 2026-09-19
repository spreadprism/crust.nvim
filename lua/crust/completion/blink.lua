--- blink.cmp source for `@` mentions and `/` commands.
---
--- Registered by module path, so blink stays optional and this file is only
--- loaded when the user wires it up:
---
---   require("blink.cmp").setup({
---     sources = {
---       per_filetype = { crust_input = { "crust" } },
---       providers = { crust = { name = "Crust", module = "crust.completion.blink" } },
---     },
---   })

local Completion = require("crust.completion")
local Files = require("crust.completion.files")

local Kind = vim.lsp.protocol.CompletionItemKind

---@type table<string, integer>
local command_kinds = {
	extension = Kind.Event,
	prompt = Kind.Snippet,
	skill = Kind.Module,
}

local source = {}

function source.new()
	return setmetatable({}, { __index = source })
end

--- Only the chat input completes, never a normal buffer.
---@return boolean
function source:enabled()
	return Files.is_input_buf()
end

---@return string[]
function source:get_trigger_characters()
	return { "@", "/", "." }
end

---@param command Crust.Pi.CommandInfo
---@param fuzzy boolean
---@return table
local function command_item(command, fuzzy)
	return {
		label = "/" .. command.name,
		kind = command_kinds[command.source] or Kind.Function,
		insertText = "/" .. command.name,
		filterText = "/" .. command.name,
		-- Fuzzy hits sort and score below the prefix ones.
		sortText = (fuzzy and "1" or "0") .. command.name,
		score_offset = fuzzy and -10 or 0,
		labelDetails = { description = command.description or command.source },
	}
end

---@param path string
---@param kind "file"|"dir"
---@param fuzzy boolean
---@return table
local function file_item(path, kind, fuzzy)
	return {
		label = "@" .. path,
		kind = kind == "dir" and Kind.Folder or Kind.File,
		insertText = "@" .. path,
		filterText = "@" .. path,
		sortText = (fuzzy and "1" or "0") .. path,
		score_offset = fuzzy and -10 or 0,
	}
end

---@param ctx table blink completion context
---@param callback fun(response: table)
function source:get_completions(ctx, callback)
	local context = Completion.context(ctx.line, ctx.cursor[2], ctx.cursor[1])

	local items = {}
	if context and context.kind == "command" then
		items = Completion.complete_commands(context.prefix, command_item)
	elseif context and context.kind == "file" then
		items = Completion.complete_files(context.prefix, file_item)
	end

	-- The list depends on the typed prefix, so blink must re-query instead of
	-- filtering a cached response.
	callback({
		items = items,
		is_incomplete_forward = #items > 0,
		is_incomplete_backward = #items > 0,
	})
end

return source
