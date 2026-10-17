--- Claude subscription usage: the numbers behind Claude Code's `/usage`.
---
--- Port of the `claude-usage` skill script: a bearer token from
--- `pi auth print-bearer-token --provider anthropic`, then a GET on the
--- undocumented `https://api.anthropic.com/api/oauth/usage`.
---
--- The endpoint is rate limited (HTTP 429), so an answer is reused for
--- `M.TTL` seconds and a stale one survives a failed request: the bar keeps
--- showing the last known figures instead of blinking out.

---@class Crust.Usage.Limit
---@field kind string "session", "weekly_all", "weekly_scoped", …
---@field percent number
---@field resets_at string? ISO 8601
---@field severity string?
---@field scope table?

---@class Crust.Usage.Data the decoded API response
---@field limits Crust.Usage.Limit[]?
---@field extra_usage table?
---@field seven_day_breakdown table?

---@class Crust.Usage
local M = {}

--- Seconds an answer is reused before a new request is made.
M.TTL = 60
--- Hard stop on both the token and the http call.
M.TIMEOUT_MS = 15000

M.URL = "https://api.anthropic.com/api/oauth/usage"
M.BETA = "anthropic-beta: oauth-2025-04-20"

---@class Crust.Usage.State
---@field data Crust.Usage.Data?
---@field fetched_at integer? os.time of the last successful fetch
---@field err string?
---@field pending fun(data: Crust.Usage.Data?, err: string?)[]? callbacks of the in-flight request
---@field failed_at integer? os.time of the last failure, the retry cooldown
local state = { data = nil, fetched_at = nil, err = nil, pending = nil, failed_at = nil }

--- Forget everything that was fetched. Exposed for tests and `/login`.
function M.clear()
	state.data, state.fetched_at, state.err, state.pending, state.failed_at = nil, nil, nil, nil, nil
end

--- Put a response in the cache as if it had just been fetched. The seam
--- tests (and anything holding a saved `--json` body) use instead of the
--- network.
---@param data Crust.Usage.Data?
function M.inject(data)
	state.data, state.fetched_at, state.err, state.failed_at = data, os.time(), nil, nil
end

--- Last answer without touching the network, plus its age in seconds.
---@return Crust.Usage.Data? data
---@return integer age seconds since it was fetched, 0 when there is none
function M.peek()
	if not state.data then
		return nil, 0
	end
	return state.data, os.time() - (state.fetched_at or os.time())
end

---@return string? err of the last request, cleared by a success
function M.error()
	return state.err
end

---@return boolean
function M.is_fresh()
	return state.data ~= nil and (os.time() - (state.fetched_at or 0)) < M.TTL
end

---@return boolean
function M.is_loading()
	return state.pending ~= nil
end

---@private
---@param data Crust.Usage.Data?
---@param err string?
local function finish(data, err)
	local callbacks = state.pending or {}
	state.pending = nil

	if data then
		state.data, state.fetched_at, state.err, state.failed_at = data, os.time(), nil, nil
	else
		state.err, state.failed_at = err, os.time()
	end

	for _, callback in ipairs(callbacks) do
		pcall(callback, state.data, err)
	end
end

--- `pi auth print-bearer-token --provider anthropic`, asynchronously.
---@private
---@param callback fun(token: string?, err: string?)
local function bearer_token(callback)
	local bin = require("crust.config").get().bin or "pi"
	local argv = { bin, "auth", "print-bearer-token", "--provider", "anthropic" }

	local ok = pcall(vim.system, argv, { text = true, timeout = M.TIMEOUT_MS }, function(result)
		local token = vim.trim(result.stdout or "")
		if result.code ~= 0 or token == "" then
			callback(nil, "Pi has no Anthropic OAuth login. Sign in with a Claude Pro/Max subscription (/login).")
			return
		end
		callback(token, nil)
	end)

	if not ok then
		callback(nil, "could not run '" .. bin .. "'")
	end
end

--- Map an http status onto the message the skill prints.
---@param code string
---@return string
local function http_error(code)
	if code == "401" or code == "403" then
		return "Anthropic rejected the login. Sign in again (/login)."
	elseif code == "429" then
		return "Rate limited by Anthropic. Try again in a minute."
	elseif code == "000" or code == "" then
		return "Couldn't reach api.anthropic.com."
	end
	return "Request failed (HTTP " .. code .. ")."
end

--- GET the usage endpoint with `token`.
---@private
---@param token string
---@param callback fun(data: Crust.Usage.Data?, err: string?)
local function request(token, callback)
	local argv = {
		"curl",
		"-sS",
		"--max-time",
		tostring(math.floor(M.TIMEOUT_MS / 1000)),
		"-w",
		"\n%{http_code}",
		M.URL,
		"-H",
		"Authorization: Bearer " .. token,
		"-H",
		M.BETA,
	}

	local ok = pcall(vim.system, argv, { text = true, timeout = M.TIMEOUT_MS }, function(result)
		local out = result.stdout or ""
		-- `-w` appends the status on its own line, whatever the body was.
		local body, code = out:match("^(.*)\n(%d*)%s*$")
		body, code = body or out, vim.trim(code or "")

		if result.code ~= 0 and code == "" then
			callback(nil, "Couldn't reach api.anthropic.com.")
			return
		end
		if code ~= "200" then
			callback(nil, http_error(code))
			return
		end

		-- `luanil` drops the json nulls: without it they decode to `vim.NIL`,
		-- a truthy userdata that survives every `x or default` and raises on
		-- the first bit of arithmetic. Anthropic sends null for a limit it has
		-- no figure for.
		local decoded_ok, decoded =
			pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
		if not decoded_ok or type(decoded) ~= "table" then
			callback(nil, "Anthropic sent something that is not json.")
			return
		end
		callback(decoded, nil)
	end)

	if not ok then
		callback(nil, "curl is required")
	end
end

--- Fetch the usage, bypassing the cache. Concurrent calls share one request.
---@param callback? fun(data: Crust.Usage.Data?, err: string?)
function M.fetch(callback)
	if state.pending then
		if callback then
			table.insert(state.pending, callback)
		end
		return
	end

	state.pending = callback and { callback } or {}

	bearer_token(function(token, err)
		if not token then
			finish(nil, err)
			return
		end
		request(token, finish)
	end)
end

--- The usage, from the cache when it is younger than `M.TTL`.
---
--- A failed request still answers with the stale data (and the error), the
--- way the skill script falls back to its cache file.
---@param callback fun(data: Crust.Usage.Data?, err: string?)
function M.get(callback)
	if M.is_fresh() then
		callback(state.data, nil)
		return
	end
	M.fetch(callback)
end

--- Refresh in the background when the cache went stale, and call back only
--- when something actually changed. Callers that draw the figures (the input
--- bar) use this: it never blocks and never loops, because a fresh cache
--- returns without doing anything.
---@param callback? fun(data: Crust.Usage.Data?, err: string?)
function M.ensure(callback)
	if M.is_fresh() or state.pending then
		return
	end
	-- A failure waits out the same minute as a success, so a logged-out
	-- account does not spawn a request per keystroke.
	if state.failed_at and (os.time() - state.failed_at) < M.TTL then
		return
	end
	M.fetch(callback)
end

return M
