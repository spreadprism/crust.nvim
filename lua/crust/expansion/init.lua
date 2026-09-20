--- Prompt expansion: what the model sees is not what the user typed.
---
--- An expander is two functions. `trigger` scans the prompt and reports the
--- spans it recognises; `expansion` turns one of those spans into the text
--- that replaces it. The rewrite happens on the way to pi only — the chat
--- output keeps rendering the prompt as it was typed, so `@justfile` stays a
--- short blue mention in the scrollback while the model receives the file.

---@class Crust.Expansion.Match
---@field first integer 1-based byte offset of the span in the prompt
---@field last integer inclusive byte offset
---@field text string the matched text, e.g. "@justfile"
---@field data? any anything `trigger` wants to hand to `expansion`

---@class Crust.Expansion.Expander
---@field name string
---@field trigger fun(text: string): Crust.Expansion.Match[]? spans this expander claims
---@field expansion fun(match: Crust.Expansion.Match): string? replacement, nil keeps the text

---@class Crust.Expansion
local M = {}

--- Built-in expanders, in priority order: on overlapping spans the earlier
--- one wins. `M.register` appends to this list.
---@type Crust.Expansion.Expander[]
M.expanders = {
	require("crust.expansion.file"),
}

--- Add an expander, e.g. from a user config.
---@param expander Crust.Expansion.Expander
function M.register(expander)
	M.expanders[#M.expanders + 1] = expander
end

--- Collect every claimed span, sorted by position. Overlaps are dropped:
--- two expanders rewriting the same bytes would corrupt each other's output.
---@private
---@param text string
---@param expanders Crust.Expansion.Expander[]
---@return { match: Crust.Expansion.Match, expander: Crust.Expansion.Expander }[]
function M._claims(text, expanders)
	local claims = {}
	for index, expander in ipairs(expanders) do
		local ok, matches = pcall(expander.trigger, text)
		if not ok then
			vim.notify(
				"crust: expansion trigger failed for " .. expander.name .. ": " .. tostring(matches),
				vim.log.levels.WARN
			)
			matches = nil
		end
		for _, match in ipairs(matches or {}) do
			claims[#claims + 1] = { match = match, expander = expander, order = index }
		end
	end

	table.sort(claims, function(a, b)
		if a.match.first ~= b.match.first then
			return a.match.first < b.match.first
		end
		return a.order < b.order
	end)

	local kept, last = {}, 0
	for _, claim in ipairs(claims) do
		if claim.match.first > last then
			kept[#kept + 1] = claim
			last = claim.match.last
		end
	end

	return kept
end

--- Rewrite a prompt for the model.
---@param text string as typed by the user
---@param expanders? Crust.Expansion.Expander[] defaults to `M.expanders`
---@return string expanded, unchanged when nothing triggered
function M.expand(text, expanders)
	if text == "" then
		return text
	end
	if not require("crust.config").enabled(require("crust.config").get().expansion.enabled) then
		return text
	end

	local out, pos = {}, 1
	for _, claim in ipairs(M._claims(text, expanders or M.expanders)) do
		local ok, replacement = pcall(claim.expander.expansion, claim.match)
		if not ok then
			vim.notify(
				"crust: expansion "
					.. claim.expander.name
					.. " failed on "
					.. claim.match.text
					.. ": "
					.. tostring(replacement),
				vim.log.levels.WARN
			)
			replacement = nil
		end

		if type(replacement) == "string" then
			out[#out + 1] = text:sub(pos, claim.match.first - 1)
			out[#out + 1] = replacement
			pos = claim.match.last + 1
		end
	end
	out[#out + 1] = text:sub(pos)

	return table.concat(out)
end

return M
