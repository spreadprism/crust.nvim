--- Making sense of what pi writes to stderr.
---
--- Provider failures arrive as a status line with a json body glued to it:
---
---   Error: 429 {"type":"error","error":{"type":"rate_limit_error",
---   "message":"This request would exceed your account's rate limit."},
---   "request_id":"req_011Cfg2yxbMsU8ECbLNc4yqS"}
---
--- Shown raw that is a wall of punctuation in the middle of a conversation,
--- and it arrives split over several stderr lines, so half of it lands in
--- one message and half in the next. This module puts the pieces back
--- together and reduces them to the sentence a reader needs:
---
---   rate limit: This request would exceed your account's rate limit.
---
--- Anything it does not recognise is handed back untouched: a stack trace
--- is more useful whole than summarised.

---@class Crust.Pi.Errors
local M = {}

---@class Crust.Pi.Errors.Parsed
---@field message string the human half, never empty
---@field kind? string provider error type, e.g. "rate_limit_error"
---@field status? integer http status, when the line carried one
---@field request_id? string provider request id, for a support ticket

--- Failures that waiting cannot fix: the provider has already decided.
--- A rate limit is the one that matters: pi would otherwise sit there
--- retrying a request that is refused by the minute, with the panel
--- spinning and no way to tell what is happening.
---@type table<string, true>
local FATAL_KINDS = {
	rate_limit_error = true,
	authentication_error = true,
	-- A dead refresh token: the next request is refused the same way.
	invalid_grant = true,
	invalid_client = true,
	permission_error = true,
	invalid_request_error = true,
}

---@type table<integer, true>
local FATAL_STATUS = {
	[400] = true,
	[401] = true,
	[403] = true,
	[404] = true,
	[429] = true,
}

--- Lines that are plainly not a failure, whatever they contain.
---@param text string
---@return boolean
function M.is_error(text)
	if text == nil or vim.trim(text) == "" then
		return false
	end
	if text:match("^%s*Error[:%s]") or text:match("^%s*error[:%s]") then
		return true
	end
	-- A json payload that calls itself an error, wrapped or not.
	return text:match('"type"%s*:%s*"error"') ~= nil or text:match('"error"%s*:%s*{') ~= nil
end

--- Braces still open in `text`, ignoring the ones inside strings.
---@param text string
---@return integer depth
local function depth(text)
	local level, index, in_string, escaped = 0, 1, false, false

	while index <= #text do
		local char = text:sub(index, index)
		if in_string then
			if escaped then
				escaped = false
			elseif char == "\\" then
				escaped = true
			elseif char == '"' then
				in_string = false
			end
		elseif char == '"' then
			in_string = true
		elseif char == "{" then
			level = level + 1
		elseif char == "}" then
			level = level - 1
		end
		index = index + 1
	end

	return level
end

--- Put stderr lines back into logical messages.
---
--- A json body wrapped over several lines is one message, not three: lines
--- are joined until their braces balance out. Everything else is passed
--- through as it came.
---@param lines string[]
---@return string[]
function M.join(lines)
	local joined, pending, level = {}, nil, 0

	for _, line in ipairs(lines) do
		if pending then
			pending = pending .. " " .. vim.trim(line)
			level = level + depth(line)
			if level <= 0 then
				joined[#joined + 1] = pending
				pending, level = nil, 0
			end
		elseif line ~= "" then
			local open = depth(line)
			if open > 0 then
				pending, level = line, open
			else
				joined[#joined + 1] = line
			end
		end
	end

	-- A body that never closed is still worth reporting.
	if pending then
		joined[#joined + 1] = pending
	end

	return joined
end

--- Pull the useful fields out of one stderr message.
---@param text string
---@return Crust.Pi.Errors.Parsed? parsed nil when nothing was recognised
function M.parse(text)
	if type(text) ~= "string" or vim.trim(text) == "" then
		return nil
	end

	-- pi repeats itself when a request fails: the sentence, then the same
	-- failure again under `details=`, then a stack trace. The first part
	-- plus the json body is the whole story.
	local trimmed = text:match("^(.-)\n%s+at [^\n]") or text
	trimmed = trimmed:gsub("; stack=.*", "")

	-- The body may have been wrapped mid-sentence; json has no newlines of
	-- its own, so folding them back into spaces is safe.
	local flat = trimmed:gsub("%s*\n%s*", " ")

	---@type Crust.Pi.Errors.Parsed
	local parsed = { message = vim.trim(flat) }

	local status = flat:match("^%s*[Ee]rror:%s*(%d%d%d)") or flat:match("^%s*(%d%d%d)%s") or flat:match("status=(%d%d%d)")
	if status then
		parsed.status = tonumber(status)
	end

	local body = flat:match("%b{}")
	local decoded = nil
	if body then
		local ok, value = pcall(vim.json.decode, body)
		decoded = ok and type(value) == "table" and value or nil
	end

	if not decoded then
		-- No json, or json that did not survive the wrapping: the line
		-- itself is the message, minus the status prefix.
		parsed.message = vim.trim((flat:gsub("^%s*[Ee]rror:%s*%d*%s*", "")))
		return parsed.message ~= "" and parsed or nil
	end

	local inner = type(decoded.error) == "table" and decoded.error or decoded
	parsed.kind = type(inner.type) == "string" and inner.type ~= "error" and inner.type or nil
	-- OAuth names the failure in `error` and explains it in
	-- `error_description`: {"error":"invalid_grant","error_description":...}
	if not parsed.kind and type(decoded.error) == "string" and decoded.error ~= "error" then
		parsed.kind = decoded.error
	end
	parsed.request_id = type(decoded.request_id) == "string" and decoded.request_id or nil

	local message = inner.message or decoded.message or decoded.error_description
	if type(message) == "string" and vim.trim(message) ~= "" then
		parsed.message = vim.trim(message)
	end

	return parsed
end

--- True when retrying is pointless: the turn should stop now rather than
--- be attempted again.
---@param text string
---@return boolean
function M.is_fatal(text)
	local parsed = M.parse(text)
	if not parsed then
		return false
	end

	if parsed.kind and FATAL_KINDS[parsed.kind] then
		return true
	end
	return parsed.status ~= nil and FATAL_STATUS[parsed.status] == true
end

--- One line a reader can act on, for `vim.notify` or the chat panel.
---@param text string
---@return string
function M.pretty(text)
	local parsed = M.parse(text)
	if not parsed then
		return vim.trim(tostring(text))
	end

	-- `rate_limit_error` reads as "rate limit", the "error" is implied by
	-- where this is shown.
	local label = parsed.kind and parsed.kind:gsub("_?error$", ""):gsub("_", " ") or nil
	if label == "" then
		label = nil
	end

	if label and parsed.status then
		return label .. " (" .. parsed.status .. "): " .. parsed.message
	end
	if label then
		return label .. ": " .. parsed.message
	end
	if parsed.status then
		return parsed.status .. ": " .. parsed.message
	end
	return parsed.message
end

return M
