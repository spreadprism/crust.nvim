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

---@param items table[]
---@return table
local function response(items)
	-- The list depends on the typed prefix, so blink must re-query instead of
	-- filtering a cached response.
	return { items = items, is_incomplete_forward = true, is_incomplete_backward = true }
end

---@param ctx table blink completion context
---@param callback fun(response: table)
---@return fun() cancel
function source:get_completions(ctx, callback)
	local context = Completion.context(ctx.line, ctx.cursor[2], ctx.cursor[1])

	if not context then
		callback(response({}))
		return function() end
	end

	if context.kind == "command" then
		callback(response(Completion.complete_commands(context.prefix, command_item)))
		return function() end
	end

	-- Answer from the cache right away, so the popup never waits on a file
	-- scan, and send a second answer if the refresh brings new paths.
	callback(response(Completion.complete_files(context.prefix, file_item)))

	local cancelled = false
	Files.ensure(nil, function()
		if not cancelled then
			callback(response(Completion.complete_files(context.prefix, file_item)))
		end
	end)

	return function()
		cancelled = true
	end
end

return source
