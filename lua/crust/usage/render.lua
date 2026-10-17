--- Formatting of a usage response, the same shapes the `claude-usage`
--- script prints:
---
---     Claude plan usage
---       5-hour session       ████░░░░░░░░░░░░░░░░  21%  (resets in 3h 12m)
---       Weekly (all models)  ███████████░░░░░░░░░  54%  (resets in 2d 4h)
---
--- `rows` is the data behind it, `lines` the rendered block with highlight
--- ranges, `summary` the two figures the input bar shows.

---@class Crust.Usage.Row
---@field label string
---@field percent number? nil hides the bar, e.g. extra usage without a limit
---@field detail string "(resets in 3h 12m)" or the credits spent
---@field tag string? severity or "limit reached"
---@field kind string? the raw `limits[].kind`

---@class Crust.Usage.Highlight
---@field line integer 1-based
---@field col integer
---@field end_col integer
---@field group string

---@class Crust.Usage.Render
local M = {}

local Highlights = require("crust.ui.highlights")

--- Cells of the progress bar, as in the script.
M.BAR_WIDTH = 20

--- Group for a percentage, red over 80, orange over 50.
---@param percent number
---@return string
function M.level(percent)
	if percent >= 80 then
		return Highlights.USAGE_ERROR
	elseif percent >= 50 then
		return Highlights.USAGE_WARNING
	end
	return Highlights.USAGE_OK
end

---@param value number?
---@return number
local function pct(value)
	return math.max(math.floor((value or 0) + 0.5), 0)
end

--- Epoch seconds of an ISO 8601 timestamp, UTC or with a `Z`/`+00:00` suffix.
---@param text string?
---@return integer?
function M.timestamp(text)
	if type(text) ~= "string" then
		return nil
	end

	local year, month, day, hour, min, sec = text:match("^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)")
	if not year then
		return nil
	end

	local parts = {
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = tonumber(hour),
		min = tonumber(min),
		sec = tonumber(sec),
		isdst = false,
	}

	-- os.time reads the table as local time; the difference between that and
	-- the same instant printed as UTC is the offset to add back.
	local local_epoch = os.time(parts)
	if not local_epoch then
		return nil
	end
	local offset = os.difftime(local_epoch, os.time(os.date("!*t", local_epoch) --[[@as osdateparam]]))
	return math.floor(local_epoch + offset)
end

--- "(resets in 3h 12m)", the way the script words it.
---@param epoch integer?
---@param now? integer
---@return string
function M.resets_in(epoch, now)
	if not epoch then
		return ""
	end

	local secs = epoch - (now or os.time())
	---@param a integer
	---@param ua string
	---@param b integer
	---@param ub string
	local function two(a, ua, b, ub)
		local text = a .. ua
		if b > 0 then
			text = text .. " " .. b .. ub
		end
		return "(resets in " .. text .. ")"
	end

	if secs <= 0 then
		return "(resets now)"
	elseif secs < 60 then
		return "(resets in <1m)"
	elseif secs < 3600 then
		return "(resets in " .. math.floor(secs / 60) .. "m)"
	elseif secs < 86400 then
		return two(math.floor(secs / 3600), "h", math.floor(secs % 3600 / 60), "m")
	end
	return two(math.floor(secs / 86400), "d", math.floor(secs % 86400 / 3600), "h")
end

--- "5-hour session", "Weekly (all models)", "Weekly (Opus)".
---@param limit Crust.Usage.Limit
---@return string
function M.label(limit)
	local kind = limit.kind or "limit"
	if kind == "session" then
		return "5-hour session"
	elseif kind == "weekly_all" then
		return "Weekly (all models)"
	elseif kind == "weekly_scoped" then
		local scope = limit.scope or {}
		local model = scope.model or {}
		return "Weekly (" .. (model.display_name or "model") .. ")"
	end
	local text = kind:gsub("_", " ")
	return text:sub(1, 1):upper() .. text:sub(2)
end

--- Minor units into "215.48": the API sends cents with a decimal count.
---@param value number?
---@param decimals integer
---@return string
local function money(value, decimals)
	local amount = math.floor((value or 0) + 0.5)
	if decimals <= 0 then
		return tostring(amount)
	end
	local factor = math.floor(10 ^ decimals + 0.5)
	local fraction = tostring(amount % factor)
	return math.floor(amount / factor) .. "." .. string.rep("0", decimals - #fraction) .. fraction
end

--- The limits (and extra usage) of a response as drawable rows.
---@param data Crust.Usage.Data?
---@param now? integer
---@return Crust.Usage.Row[]
function M.rows(data, now)
	---@type Crust.Usage.Row[]
	local rows = {}
	if type(data) ~= "table" then
		return rows
	end

	for _, limit in ipairs(data.limits or {}) do
		local severity = limit.severity
		rows[#rows + 1] = {
			label = M.label(limit),
			percent = pct(limit.percent),
			detail = M.resets_in(M.timestamp(limit.resets_at), now),
			tag = (severity and severity ~= "normal") and severity or nil,
			kind = limit.kind,
		}
	end

	local extra = data.extra_usage
	if type(extra) == "table" and extra.is_enabled == true then
		local decimals = extra.decimal_places or 2
		local currency = extra.currency or ""
		local used, limit = extra.used_credits or 0, extra.monthly_limit or 0
		local percent, detail = nil, nil

		if limit > 0 then
			percent = pct(extra.utilization or (100 * used / limit))
			detail = "(" .. money(used, decimals) .. " / " .. money(limit, decimals) .. " " .. currency .. ")"
		else
			detail = "(" .. money(used, decimals) .. " " .. currency .. " used, no limit)"
		end

		rows[#rows + 1] = {
			label = "Extra usage",
			percent = percent,
			detail = detail,
			tag = extra.spend_limit_reached == true and "limit reached" or nil,
			kind = "extra_usage",
		}
	end

	return rows
end

--- `████░░░░░░░░░░░░░░░░`, filled share first.
---@param percent number
---@return string filled
---@return string empty
function M.bar(percent)
	local filled = math.min(math.floor(percent / 5), M.BAR_WIDTH)
	return string.rep("█", filled), string.rep("░", M.BAR_WIDTH - filled)
end

--- The 7-day per-model breakdown, nil when nothing was used.
---@param data Crust.Usage.Data?
---@return string?
function M.breakdown(data)
	local breakdown = type(data) == "table" and data.seven_day_breakdown or nil
	local parts = {}
	for _, row in ipairs((type(breakdown) == "table" and breakdown.rows) or {}) do
		if (row.percent or 0) > 0 then
			parts[#parts + 1] = (row.display_name or "model") .. " " .. row.percent .. "%"
		end
	end
	if #parts == 0 then
		return nil
	end
	return "Weekly breakdown: " .. table.concat(parts, ", ")
end

--- The whole block, ready to put in a buffer.
---@param data Crust.Usage.Data?
---@param opts? { now?: integer, title?: string }
---@return string[] lines
---@return Crust.Usage.Highlight[] highlights
function M.lines(data, opts)
	opts = opts or {}
	local lines, highlights = {}, {}

	---@param line integer
	---@param col integer
	---@param text string
	---@param group string
	local function mark(line, col, text, group)
		if text ~= "" then
			highlights[#highlights + 1] = { line = line, col = col, end_col = col + #text, group = group }
		end
	end

	lines[1] = opts.title or "Claude plan usage"
	mark(1, 0, lines[1], Highlights.USAGE_TITLE)

	local rows = M.rows(data, opts.now)
	if #rows == 0 then
		lines[2] = "  No limits reported."
		mark(2, 0, lines[2], Highlights.USAGE_DIM)
		return lines, highlights
	end

	local width = 0
	for _, row in ipairs(rows) do
		width = math.max(width, vim.fn.strdisplaywidth(row.label))
	end

	for _, row in ipairs(rows) do
		local index = #lines + 1
		local label = "  " .. row.label .. string.rep(" ", width - vim.fn.strdisplaywidth(row.label)) .. "  "
		local parts = { label }
		local col = #label
		mark(index, 0, label, Highlights.USAGE_LABEL)

		if row.percent then
			local group = M.level(row.percent)
			local filled, empty = M.bar(row.percent)
			mark(index, col, filled, group)
			col = col + #filled
			mark(index, col, empty, Highlights.USAGE_DIM)
			col = col + #empty

			local percent = string.format(" %3d%% ", row.percent)
			mark(index, col, percent, group)
			col = col + #percent
			parts[#parts + 1] = filled .. empty .. percent
		end

		if row.detail ~= "" then
			mark(index, col, row.detail, Highlights.USAGE_DIM)
			col = col + #row.detail
			parts[#parts + 1] = row.detail
		end

		if row.tag then
			local tag = "  [" .. row.tag .. "]"
			mark(index, col, tag, Highlights.USAGE_ERROR)
			parts[#parts + 1] = tag
		end

		lines[index] = table.concat(parts)
	end

	local breakdown = M.breakdown(data)
	if breakdown then
		local index = #lines + 1
		lines[index] = "  " .. breakdown
		mark(index, 0, lines[index], Highlights.USAGE_DIM)
	end

	return lines, highlights
end

--- The two figures the input bar shows: the 5-hour session and the weekly
--- all-models limit, whichever of them the response carries.
---@param data Crust.Usage.Data?
---@param now? integer
---@return { session: Crust.Usage.Row?, weekly: Crust.Usage.Row? }
function M.summary(data, now)
	local out = {}
	for _, row in ipairs(M.rows(data, now)) do
		if row.kind == "session" and not out.session then
			out.session = row
		elseif row.kind == "weekly_all" and not out.weekly then
			out.weekly = row
		end
	end
	-- A plan without a named weekly_all still has a weekly limit; take the
	-- first scoped one rather than showing nothing.
	if not out.weekly then
		for _, row in ipairs(M.rows(data, now)) do
			if row.kind == "weekly_scoped" then
				out.weekly = row
				break
			end
		end
	end
	return out
end

return M
