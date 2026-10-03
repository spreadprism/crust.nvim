--- Build the mention for "send this to the chat".
---
--- What is sent depends on the buffer and on the mode the call came from:
---
---   normal, file buffer   `@path`
---   visual, file buffer   `@path:first-last`
---   normal, oil buffer    `@dir/`, the directory being browsed
---   visual, oil buffer    one `@dir/name` per selected entry
---
--- The text is the same `@mention` syntax the prompt already understands, so
--- `crust.expansion.file` turns it into file content on the way to pi.

---@class Crust.Send
local M = {}

---@class Crust.Send.Opts
---@field buf? integer buffer to describe, defaults to the current one
---@field visual? boolean use the selected lines; defaults to "am I in visual mode"
---@field first? integer 1-based first line, for callers with a range of their own (`:'<,'>Crust send`)
---@field last? integer inclusive last line, defaults to `first`

--- Path as it goes into a mention: relative to the cwd when it is below it,
--- `~`-shortened otherwise.
---@param path string
---@return string
function M.relative(path)
	return vim.fn.fnamemodify(vim.fs.normalize(path), ":~:.")
end

--- Filetypes of the chat panels: none of them is a file to talk about.
---@type table<string, true>
local PANELS = {
	[require("crust.filetypes").input] = true,
	[require("crust.filetypes").output] = true,
	-- Spelled out instead of required, so this module never pulls in the ui.
	["crust_status"] = true,
}

--- True for a buffer belonging to the chat itself.
---@param buf integer
---@return boolean
local function is_panel(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return true
	end
	if PANELS[vim.bo[buf].filetype] then
		return true
	end
	return vim.api.nvim_buf_get_name(buf):match("^crust://") ~= nil
end

--- The buffer the user last worked in, chat panels aside.
---
--- `lastused` only has a second of resolution, so a buffer that is on screen
--- wins a tie: after a `<C-w>` into the chat, the file still visible next to
--- it is the one the mapping means.
---@return integer? buf nil when nothing but the chat is loaded
function M.last_buf()
	local visible = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		visible[vim.api.nvim_win_get_buf(win)] = true
	end

	local best, best_rank = nil, nil
	for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
		local buf = info.bufnr
		if info.name ~= "" and not is_panel(buf) then
			local rank = { info.lastused or 0, visible[buf] and 1 or 0, buf }
			if
				not best_rank
				or rank[1] > best_rank[1]
				or (rank[1] == best_rank[1] and rank[2] > best_rank[2])
				or (rank[1] == best_rank[1] and rank[2] == best_rank[2] and rank[3] > best_rank[3])
			then
				best, best_rank = buf, rank
			end
		end
	end

	return best
end

---@return boolean
local function in_visual_mode()
	return vim.fn.mode():match("^[vV\22]") ~= nil
end

--- First and last selected line, 1-based and ordered.
---
--- While visual mode is still active the marks of the *previous* selection
--- are what `'<` holds, so the live positions are read instead. A caller that
--- already left visual mode (`:<C-u>lua …`) falls back to the marks.
---@return integer first, integer last
---@param opts Crust.Send.Opts
local function selected_lines(opts)
	-- `vim.fn.line` is typed as `integer?`, and so is an `opts` the caller
	-- left out: everything goes through one guard to stay an integer.
	---@param value integer?
	---@return integer
	local function line_number(value)
		if type(value) ~= "number" or value < 1 then
			return 1
		end
		return math.floor(value)
	end

	local first, last
	if opts.first then
		first, last = line_number(opts.first), line_number(opts.last or opts.first)
	elseif in_visual_mode() then
		first, last = line_number(vim.fn.line("v")), line_number(vim.fn.line("."))
	else
		first, last = line_number(vim.fn.line("'<")), line_number(vim.fn.line("'>"))
	end

	if first > last then
		first, last = last, first
	end
	return first, last
end

---@class Crust.Send.Entry
---@field path string absolute
---@field directory boolean

--- Entries of an oil buffer on `first`..`last`.
---@param buf integer
---@param first integer
---@param last integer
---@return Crust.Send.Entry[]
local function oil_entries(buf, first, last)
	local ok, oil = pcall(require, "oil")
	if not ok then
		return {}
	end

	local dir = oil.get_current_dir(buf)
	if not dir then
		return {}
	end

	local entries = {}
	for lnum = first, last do
		local entry = oil.get_entry_on_line(buf, lnum)
		if entry and entry.name and entry.name ~= ".." then
			entries[#entries + 1] = {
				path = vim.fs.joinpath(dir, entry.name),
				directory = entry.type == "directory",
			}
		end
	end
	return entries
end

--- Directory an oil buffer is browsing, nil when it is not one.
---@param buf integer
---@return string?
local function oil_dir(buf)
	if vim.bo[buf].filetype ~= "oil" then
		return nil
	end

	local ok, oil = pcall(require, "oil")
	return ok and oil.get_current_dir(buf) or nil
end

--- Mention text for the current context, nil when there is nothing to send
--- (an unnamed scratch buffer, an empty oil selection).
---@param opts? Crust.Send.Opts
---@return string?
function M.mention(opts)
	opts = opts or {}

	local buf = opts.buf or vim.api.nvim_get_current_buf()
	local visual = opts.visual
	if visual == nil then
		visual = opts.first ~= nil or in_visual_mode()
	end

	local dir = oil_dir(buf)
	if dir then
		if not visual then
			return "@" .. M.relative(dir) .. "/"
		end

		local first, last = selected_lines(opts)
		local mentions = {}
		for _, entry in ipairs(oil_entries(buf, first, last)) do
			-- The trailing slash marks a directory, and has to go on after
			-- `M.relative`: normalizing a path drops it.
			mentions[#mentions + 1] = "@" .. M.relative(entry.path) .. (entry.directory and "/" or "")
		end
		return #mentions > 0 and table.concat(mentions, " ") or nil
	end

	local name = vim.api.nvim_buf_get_name(buf)
	if name == "" then
		return nil
	end

	local path = "@" .. M.relative(name)
	if not visual then
		return path
	end

	local first, last = selected_lines(opts)
	if first == last then
		return path .. ":" .. first
	end
	return path .. ":" .. first .. "-" .. last
end

return M
