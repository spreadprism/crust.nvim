--- Replay stored messages into the chat panel.
---
--- `get_messages` answers with the whole conversation of the session pi is
--- on. Tool calls arrive as `toolCall` content parts and their results as
--- separate `toolResult` messages, so they are folded back into the same
--- events `Crust.Chat.Tools` already renders while streaming.

local M = {}

local Highlights = require("crust.ui.highlights")

--- pi timestamps messages in milliseconds, os.date wants seconds.
---@param timestamp any
---@return integer?
local function seconds(timestamp)
	if type(timestamp) ~= "number" then
		return nil
	end
	if timestamp > 1e11 then
		return math.floor(timestamp / 1000)
	end
	return math.floor(timestamp)
end

--- Concatenated text of a message body.
---@param content string|Crust.Pi.Content[]|nil
---@return string
function M.text(content)
	if type(content) == "string" then
		return content
	end
	if type(content) ~= "table" then
		return ""
	end

	local parts = {}
	for _, part in ipairs(content) do
		if type(part) == "table" and part.type == "text" and part.text and part.text ~= "" then
			parts[#parts + 1] = part.text
		end
	end
	return table.concat(parts, "\n")
end

--- Tool calls of an assistant message, in order.
---@param content string|Crust.Pi.Content[]|nil
---@return Crust.Pi.ToolCall[]
function M.tool_calls(content)
	if type(content) ~= "table" then
		return {}
	end

	local calls = {}
	for _, part in ipairs(content) do
		if type(part) == "table" and part.type == "toolCall" and part.id then
			calls[#calls + 1] = part --[[@as Crust.Pi.ToolCall]]
		end
	end
	return calls
end

--- Tool arguments, which pi may send as a json string.
---@param arguments string|table|nil
---@return table
function M.args(arguments)
	if type(arguments) == "table" then
		return arguments
	end
	if type(arguments) == "string" then
		local ok, decoded = pcall(vim.json.decode, arguments)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	return {}
end

---@param output Crust.Chat.Output
---@param tools Crust.Chat.Tools
---@param message Crust.Pi.Message
local function assistant(output, tools, message)
	local text = M.text(message.content)
	local calls = M.tool_calls(message.content)
	if text == "" and #calls == 0 then
		return
	end

	output:header(require("crust.config").get().labels.agent, Highlights.AGENT_TITLE, seconds(message.timestamp))
	if text ~= "" then
		output:append(text .. "\n")
	end

	for _, call in ipairs(calls) do
		tools:render(output, {
			type = "tool_execution_start",
			toolCallId = call.id,
			toolName = call.name,
			args = M.args(call.arguments),
		})
	end
end

--- Write a whole conversation into an empty output panel.
---@param messages Crust.Pi.Message[]?
---@param output Crust.Chat.Output
---@param tools Crust.Chat.Tools
function M.render(messages, output, tools)
	for _, message in ipairs(messages or {}) do
		if message.role == "user" then
			local text = M.text(message.content)
			if text ~= "" then
				output:header(
					require("crust.config").get().labels.user,
					Highlights.USER_TITLE,
					seconds(message.timestamp)
				)
				output:append(text .. "\n")
			end
		elseif message.role == "assistant" then
			assistant(output, tools, message)
		elseif message.role == "toolResult" and message.toolCallId then
			tools:render(output, {
				type = "tool_execution_end",
				toolCallId = message.toolCallId,
				toolName = message.toolName,
				result = { content = message.content, details = message.details },
				isError = message.isError,
			})
		end
	end

	output:follow()
end

return M
