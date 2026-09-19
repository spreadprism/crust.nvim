--- Matching shared by every completion front end.
---
--- Nothing here knows about blink.cmp or `completefunc`: the callers pass a
--- `make_item` and get back items in priority order, prefix matches first,
--- fuzzy matches after.

---@class Crust.Completion
local M = {}

local Files = require("crust.completion.files")
local Commands = require("crust.completion.commands")

--- Whether every character of `query` appears in `target`, in order.
---@param query string
---@param target string
---@return boolean
function M.fuzzy_match(query, target)
	query, target = query:lower(), target:lower()

	local at = 1
	for index = 1, #target do
		if target:byte(index) == query:byte(at) then
			at = at + 1
			if at > #query then
				return true
			end
		end
	end
	return #query == 0
end

--- Find the trigger character of the word the cursor sits in.
--- A space ends the word, so `@` in prose does not open a mention.
---@param line string
---@param col integer cursor column, 0-indexed like `nvim_win_get_cursor`
---@param trigger string single character, e.g. "@"
---@return integer? col 1-indexed position of the trigger
function M.find_trigger(line, col, trigger)
	local byte = trigger:byte(1)

	for index = col, 1, -1 do
		local current = line:byte(index)
		if current == byte then
			return index
		end
		if current == 32 then
			return nil
		end
	end
	return nil
end

--- Most items any front end gets. A popup cannot show more, and building
--- thousands of tables on every keystroke is what makes completion feel
--- like a freeze.
M.MAX_ITEMS = 200

--- Files matching `prefix`, with directories collapsed into one entry so a
--- deep tree does not flood the popup. Stops at `MAX_ITEMS`.
---@param prefix string text typed after `@`
---@param make_item fun(path: string, kind: "file"|"dir", fuzzy: boolean): table
---@return table[]
function M.complete_files(prefix, make_item)
	local paths = Files.list()
	local items = {}
	local seen_dirs = {}
	local matched = {}

	for _, path in ipairs(paths) do
		if #items >= M.MAX_ITEMS then
			return items
		end

		if prefix == "" or path:sub(1, #prefix) == prefix then
			matched[path] = true

			local rest = path:sub(#prefix + 1)
			local slash = rest:find("/", 1, true)
			if slash then
				local dir = prefix .. rest:sub(1, slash)
				if not seen_dirs[dir] then
					seen_dirs[dir] = true
					items[#items + 1] = make_item(dir, "dir", false)
				end
			else
				items[#items + 1] = make_item(path, "file", false)
			end
		end
	end

	if prefix ~= "" then
		for _, path in ipairs(paths) do
			if #items >= M.MAX_ITEMS then
				return items
			end
			if not matched[path] and M.fuzzy_match(prefix, path) then
				items[#items + 1] = make_item(path, "file", true)
			end
		end
	end

	return items
end

--- Skills are invoked as `/skill:name`, but typing the bare name should find
--- them too.
---@param command Crust.Pi.CommandInfo
---@return string? short lowercased name after "skill:"
local function skill_short(command)
	if command.source == "skill" then
		return command.name:lower():match("^skill:(.+)$")
	end
	return nil
end

--- Commands matching `prefix`.
---@param prefix string text typed after `/`
---@param make_item fun(command: Crust.Pi.CommandInfo, fuzzy: boolean): table
---@return table[]
function M.complete_commands(prefix, make_item)
	local commands = Commands.list()

	if prefix == "" then
		return vim.tbl_map(function(command)
			return make_item(command, false)
		end, commands)
	end

	prefix = prefix:lower()
	local items = {}
	local seen = {}

	---@param name string already lowercased
	local function is_prefix(name)
		return name:sub(1, #prefix) == prefix
	end

	for _, command in ipairs(commands) do
		local short = skill_short(command)
		if is_prefix(command.name:lower()) or (short and is_prefix(short)) then
			seen[command.name] = true
			items[#items + 1] = make_item(command, false)
		end
	end

	for _, command in ipairs(commands) do
		if not seen[command.name] then
			local short = skill_short(command)
			if M.fuzzy_match(prefix, command.name:lower()) or (short and M.fuzzy_match(prefix, short)) then
				items[#items + 1] = make_item(command, true)
			end
		end
	end

	return items
end

---@class Crust.Completion.Context
---@field kind "file"|"command"
---@field prefix string text typed after the trigger
---@field col integer 0-indexed column the replacement starts at

--- What the cursor is completing, if anything.
--- `/commands` only count on the first line, at its very start, the way pi
--- parses them.
---@param line string
---@param col integer cursor column, 0-indexed
---@param row integer cursor line, 1-indexed
---@return Crust.Completion.Context?
function M.context(line, col, row)
	if row == 1 then
		local slash = M.find_trigger(line, col, "/")
		if slash == 1 then
			return { kind = "command", prefix = line:sub(2, col), col = 0 }
		end
	end

	local at = M.find_trigger(line, col, "@")
	if at then
		return { kind = "file", prefix = line:sub(at + 1, col), col = at - 1 }
	end

	return nil
end

return M
