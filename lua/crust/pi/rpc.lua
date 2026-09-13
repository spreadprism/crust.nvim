--- Typed rpc command constructors for `pi --mode rpc`.
--- Every constructor returns a `Crust.Pi.Command` that `Crust.Pi:send()` accepts.

---@alias Crust.Pi.CommandType
---| "prompt"
---| "steer"
---| "follow_up"
---| "abort"
---| "clear_queue"
---| "new_session"
---| "get_state"
---| "get_messages"
---| "set_model"
---| "cycle_model"
---| "get_available_models"
---| "set_thinking_level"
---| "cycle_thinking_level"
---| "get_available_thinking_levels"
---| "set_steering_mode"
---| "set_follow_up_mode"
---| "compact"
---| "set_auto_compaction"
---| "set_auto_retry"
---| "abort_retry"
---| "bash"
---| "abort_bash"
---| "get_session_stats"
---| "export_html"
---| "switch_session"
---| "fork"
---| "clone"
---| "get_fork_messages"
---| "get_entries"
---| "get_tree"
---| "get_last_assistant_text"
---| "set_session_name"
---| "get_commands"
---| "extension_ui_response"

---@alias Crust.Pi.ThinkingLevel "off"|"minimal"|"low"|"medium"|"high"|"xhigh"|"max"
---@alias Crust.Pi.QueueMode "all"|"one-at-a-time"
---@alias Crust.Pi.StreamingBehavior "steer"|"followUp"

---@class Crust.Pi.Image
---@field type "image"
---@field data string base64 encoded
---@field mimeType string

--- Shared payloads --------------------------------------------------------

---@class Crust.Pi.Cost
---@field input number
---@field output number
---@field cacheRead number
---@field cacheWrite number
---@field total? number

---@class Crust.Pi.Usage
---@field input integer
---@field output integer
---@field cacheRead integer
---@field cacheWrite integer
---@field totalTokens? integer
---@field cost? Crust.Pi.Cost

---@class Crust.Pi.Model
---@field id string
---@field name string
---@field api string
---@field provider string
---@field baseUrl string
---@field reasoning boolean
---@field input string[] supported input kinds, e.g. { "text", "image" }
---@field contextWindow integer
---@field maxTokens integer
---@field cost Crust.Pi.Cost

---@class Crust.Pi.ToolCall
---@field id string
---@field name string
---@field arguments string|table

---@class Crust.Pi.Content
---@field type "text"|"thinking"|"toolCall"|"image"
---@field text? string
---@field thinking? string
---@field [string] any

---@class Crust.Pi.ToolResult
---@field content? Crust.Pi.Content[]
---@field details? table

---@class Crust.Pi.Message
---@field role "user"|"assistant"|"toolResult"|"bashExecution"
---@field content? string|Crust.Pi.Content[]
---@field timestamp integer
---@field usage? Crust.Pi.Usage
---@field stopReason? "stop"|"length"|"toolUse"|"error"|"aborted"
---@field toolCallId? string
---@field toolName? string
---@field isError? boolean
---@field [string] any

---@class Crust.Pi.Entry
---@field type string
---@field id string
---@field parentId string?
---@field timestamp string
---@field message? Crust.Pi.Message

---@class Crust.Pi.TreeNode
---@field entry Crust.Pi.Entry
---@field children Crust.Pi.TreeNode[]
---@field label? string
---@field labelTimestamp? string

---@class Crust.Pi.CommandInfo
---@field name string invoke with "/" .. name
---@field description? string
---@field source "extension"|"prompt"|"skill"
---@field location? "user"|"project"|"path"
---@field path? string

---@class Crust.Pi.CompactionResult
---@field summary string
---@field firstKeptEntryId string
---@field tokensBefore integer
---@field estimatedTokensAfter integer heuristic, not provider exact
---@field usage? Crust.Pi.Usage
---@field details? table

--- Response data ----------------------------------------------------------

---@class Crust.Pi.Data.State
---@field model Crust.Pi.Model?
---@field thinkingLevel Crust.Pi.ThinkingLevel
---@field isStreaming boolean
---@field isCompacting boolean
---@field steeringMode Crust.Pi.QueueMode
---@field followUpMode Crust.Pi.QueueMode
---@field sessionFile? string
---@field sessionId string
---@field sessionName? string
---@field autoCompactionEnabled boolean
---@field messageCount integer
---@field pendingMessageCount integer

---@class Crust.Pi.Data.Messages
---@field messages Crust.Pi.Message[]

---@class Crust.Pi.Data.Queue
---@field steering string[]
---@field followUp string[]

---@class Crust.Pi.Data.Cancelled
---@field cancelled boolean

---@class Crust.Pi.Data.Fork : Crust.Pi.Data.Cancelled
---@field text string text of the message forked from

---@class Crust.Pi.Data.Models
---@field models Crust.Pi.Model[]

---@class Crust.Pi.Data.CycleModel
---@field model Crust.Pi.Model
---@field thinkingLevel Crust.Pi.ThinkingLevel
---@field isScoped boolean

---@class Crust.Pi.Data.ThinkingLevel
---@field level Crust.Pi.ThinkingLevel

---@class Crust.Pi.Data.ThinkingLevels
---@field levels Crust.Pi.ThinkingLevel[]

---@class Crust.Pi.Data.Bash
---@field output string
---@field exitCode integer
---@field cancelled boolean
---@field truncated boolean
---@field fullOutputPath? string

---@class Crust.Pi.Data.ContextUsage
---@field tokens integer?
---@field contextWindow integer
---@field percent integer?

---@class Crust.Pi.Data.SessionStats
---@field sessionFile string
---@field sessionId string
---@field userMessages integer
---@field assistantMessages integer
---@field toolCalls integer
---@field toolResults integer
---@field totalMessages integer
---@field tokens Crust.Pi.Usage
---@field cost number
---@field contextUsage? Crust.Pi.Data.ContextUsage

---@class Crust.Pi.Data.Path
---@field path string

---@class Crust.Pi.Data.ForkMessages
---@field messages { entryId: string, text: string }[]

---@class Crust.Pi.Data.Entries
---@field entries Crust.Pi.Entry[]
---@field leafId string?

---@class Crust.Pi.Data.Tree
---@field tree Crust.Pi.TreeNode[]
---@field leafId string?

---@class Crust.Pi.Data.Text
---@field text string?

---@class Crust.Pi.Data.Commands
---@field commands Crust.Pi.CommandInfo[]

---@alias Crust.Pi.ResponseData
---| Crust.Pi.Data.State
---| Crust.Pi.Data.Messages
---| Crust.Pi.Data.Queue
---| Crust.Pi.Data.Cancelled
---| Crust.Pi.Data.Fork
---| Crust.Pi.Data.Models
---| Crust.Pi.Data.CycleModel
---| Crust.Pi.Data.ThinkingLevel
---| Crust.Pi.Data.ThinkingLevels
---| Crust.Pi.Data.Bash
---| Crust.Pi.Data.SessionStats
---| Crust.Pi.Data.Path
---| Crust.Pi.Data.ForkMessages
---| Crust.Pi.Data.Entries
---| Crust.Pi.Data.Tree
---| Crust.Pi.Data.Text
---| Crust.Pi.Data.Commands
---| Crust.Pi.Model model returned by set_model

--- Reply to a command, correlated by `id`. `command` is "parse" for malformed input.
---@class Crust.Pi.Response
---@field type "response"
---@field id? string echo of the command id
---@field command Crust.Pi.CommandType|"parse"
---@field success boolean
---@field error? string set when success is false
---@field data? Crust.Pi.ResponseData

--- Events -----------------------------------------------------------------

---@alias Crust.Pi.EventType
---| "response"
---| "agent_start"
---| "agent_end"
---| "agent_settled"
---| "turn_start"
---| "turn_end"
---| "message_start"
---| "message_update"
---| "message_end"
---| "bash_execution_update"
---| "tool_execution_start"
---| "tool_execution_update"
---| "tool_execution_end"
---| "queue_update"
---| "compaction_start"
---| "compaction_end"
---| "auto_retry_start"
---| "auto_retry_end"
---| "summarization_retry_scheduled"
---| "summarization_retry_attempt_start"
---| "summarization_retry_finished"
---| "extension_error"
---| "extension_ui_request"
---| "_stderr" synthesized by Crust.Pi from process stderr
---| "_process_exit" synthesized by Crust.Pi when the process exits

---@alias Crust.Pi.AssistantEventType
---| "text_start"
---| "text_delta"
---| "text_end"
---| "thinking_start"
---| "thinking_delta"
---| "thinking_end"
---| "toolcall_start"
---| "toolcall_delta"
---| "toolcall_end"

---@class Crust.Pi.AssistantEvent
---@field type Crust.Pi.AssistantEventType
---@field contentIndex integer
---@field delta? string
---@field content? string full text on text_end
---@field id? string tool call id on toolcall_start
---@field toolName? string
---@field toolCall? Crust.Pi.ToolCall complete call on toolcall_end

---@alias Crust.Pi.UiMethod
---| "select"
---| "confirm"
---| "input"
---| "editor"
---| "notify"
---| "setStatus"
---| "setWidget"
---| "setTitle"
---| "set_editor_text"

--- Any line decoded from pi stdout. Only `type` is always present.
---@class Crust.Pi.Event
---@field type Crust.Pi.EventType
---@field id? string response id, bash_execution_update id, or ui request id
--- response
---@field command? Crust.Pi.CommandType|"parse"
---@field success? boolean
---@field error? string
---@field data? Crust.Pi.ResponseData
--- agent_end / turn_end / message_*
---@field messages? Crust.Pi.Message[]
---@field message? string|Crust.Pi.Message
---@field willRetry? boolean
---@field toolResults? Crust.Pi.Message[]
---@field usage? Crust.Pi.Usage
---@field assistantMessageEvent? Crust.Pi.AssistantEvent
--- bash_execution_update
---@field delta? string
--- tool_execution_*
---@field toolCallId? string
---@field toolName? string
---@field args? table
---@field partialResult? Crust.Pi.ToolResult
---@field result? Crust.Pi.ToolResult|Crust.Pi.CompactionResult
---@field isError? boolean
--- queue_update
---@field steering? string[]
---@field followUp? string[]
--- compaction_* / retries
---@field reason? "manual"|"threshold"|"overflow"
---@field aborted? boolean
---@field errorMessage? string
---@field attempt? integer
---@field maxAttempts? integer
---@field delayMs? integer
---@field finalError? string
---@field source? "compaction"|"branchSummary"
--- extension_error
---@field extensionPath? string
---@field event? string
--- extension_ui_request
---@field method? Crust.Pi.UiMethod
---@field title? string
---@field options? string[]
---@field timeout? integer
---@field placeholder? string
---@field prefill? string
---@field notifyType? "info"|"warning"|"error"
---@field statusKey? string
---@field statusText? string
---@field widgetKey? string
---@field widgetLines? string[]
---@field widgetPlacement? "aboveEditor"|"belowEditor"
---@field text? string
--- _process_exit
---@field code? integer
---@field [string] any

---@class Crust.Pi.Command
---@field type Crust.Pi.CommandType
---@field id string? request id, set by Crust.Pi:send when missing
local Command = {}
Command.__index = Command

---@param command_type Crust.Pi.CommandType
---@param fields? table<string, any>
---@return Crust.Pi.Command
function Command.new(command_type, fields)
	local self = setmetatable(fields or {}, Command)
	self.type = command_type
	return self
end

---@param value any
---@return boolean
function Command.is(value)
	return getmetatable(value) == Command
end

---@return string
function Command:encode()
	return vim.json.encode(self)
end

---@param path string
---@param mime_type string
---@return Crust.Pi.Image?
---@return string? err
function Command.image_from_file(path, mime_type)
	local file, err = io.open(path, "rb")
	if not file then
		return nil, err or ("cannot read " .. path)
	end
	local data = file:read("*a")
	file:close()
	return { type = "image", data = vim.base64.encode(data), mimeType = mime_type }
end

--- Prompting ---------------------------------------------------------------

---@class Crust.Pi.PromptOpts
---@field images? Crust.Pi.Image[]
---@field streaming_behavior? Crust.Pi.StreamingBehavior required while the agent streams

---@param message string
---@param opts? Crust.Pi.PromptOpts
---@return Crust.Pi.Command
function Command.prompt(message, opts)
	opts = opts or {}
	return Command.new("prompt", {
		message = message,
		images = opts.images,
		streamingBehavior = opts.streaming_behavior,
	})
end

---@param message string
---@param images? Crust.Pi.Image[]
---@return Crust.Pi.Command
function Command.steer(message, images)
	return Command.new("steer", { message = message, images = images })
end

---@param message string
---@param images? Crust.Pi.Image[]
---@return Crust.Pi.Command
function Command.follow_up(message, images)
	return Command.new("follow_up", { message = message, images = images })
end

---@return Crust.Pi.Command
function Command.abort()
	return Command.new("abort")
end

--- Removes queued steering and follow-up messages and returns their text.
---@return Crust.Pi.Command
function Command.clear_queue()
	return Command.new("clear_queue")
end

---@param parent_session? string path of the session to record as parent
---@return Crust.Pi.Command
function Command.new_session(parent_session)
	return Command.new("new_session", { parentSession = parent_session })
end

--- State -------------------------------------------------------------------

---@return Crust.Pi.Command
function Command.get_state()
	return Command.new("get_state")
end

---@return Crust.Pi.Command
function Command.get_messages()
	return Command.new("get_messages")
end

--- Model -------------------------------------------------------------------

---@param provider string
---@param model_id string
---@return Crust.Pi.Command
function Command.set_model(provider, model_id)
	return Command.new("set_model", { provider = provider, modelId = model_id })
end

---@return Crust.Pi.Command
function Command.cycle_model()
	return Command.new("cycle_model")
end

---@return Crust.Pi.Command
function Command.get_available_models()
	return Command.new("get_available_models")
end

--- Thinking ----------------------------------------------------------------

---@param level Crust.Pi.ThinkingLevel
---@return Crust.Pi.Command
function Command.set_thinking_level(level)
	return Command.new("set_thinking_level", { level = level })
end

---@return Crust.Pi.Command
function Command.cycle_thinking_level()
	return Command.new("cycle_thinking_level")
end

---@return Crust.Pi.Command
function Command.get_available_thinking_levels()
	return Command.new("get_available_thinking_levels")
end

--- Queue modes -------------------------------------------------------------

---@param mode Crust.Pi.QueueMode
---@return Crust.Pi.Command
function Command.set_steering_mode(mode)
	return Command.new("set_steering_mode", { mode = mode })
end

---@param mode Crust.Pi.QueueMode
---@return Crust.Pi.Command
function Command.set_follow_up_mode(mode)
	return Command.new("set_follow_up_mode", { mode = mode })
end

--- Compaction and retry ----------------------------------------------------

---@param custom_instructions? string
---@return Crust.Pi.Command
function Command.compact(custom_instructions)
	return Command.new("compact", { customInstructions = custom_instructions })
end

---@param enabled boolean
---@return Crust.Pi.Command
function Command.set_auto_compaction(enabled)
	return Command.new("set_auto_compaction", { enabled = enabled })
end

---@param enabled boolean
---@return Crust.Pi.Command
function Command.set_auto_retry(enabled)
	return Command.new("set_auto_retry", { enabled = enabled })
end

---@return Crust.Pi.Command
function Command.abort_retry()
	return Command.new("abort_retry")
end

--- Bash --------------------------------------------------------------------

--- Runs a shell command and adds its output to the conversation context.
---@param command string
---@return Crust.Pi.Command
function Command.bash(command)
	return Command.new("bash", { command = command })
end

---@return Crust.Pi.Command
function Command.abort_bash()
	return Command.new("abort_bash")
end

--- Session -----------------------------------------------------------------

---@return Crust.Pi.Command
function Command.get_session_stats()
	return Command.new("get_session_stats")
end

---@param output_path? string
---@return Crust.Pi.Command
function Command.export_html(output_path)
	return Command.new("export_html", { outputPath = output_path })
end

---@param session_path string
---@return Crust.Pi.Command
function Command.switch_session(session_path)
	return Command.new("switch_session", { sessionPath = session_path })
end

---@param entry_id string user message to fork from
---@return Crust.Pi.Command
function Command.fork(entry_id)
	return Command.new("fork", { entryId = entry_id })
end

---@return Crust.Pi.Command
function Command.clone()
	return Command.new("clone")
end

---@return Crust.Pi.Command
function Command.get_fork_messages()
	return Command.new("get_fork_messages")
end

---@param since? string entry id cursor, returns entries strictly after it
---@return Crust.Pi.Command
function Command.get_entries(since)
	return Command.new("get_entries", { since = since })
end

---@return Crust.Pi.Command
function Command.get_tree()
	return Command.new("get_tree")
end

---@return Crust.Pi.Command
function Command.get_last_assistant_text()
	return Command.new("get_last_assistant_text")
end

---@param name string
---@return Crust.Pi.Command
function Command.set_session_name(name)
	return Command.new("set_session_name", { name = name })
end

---@return Crust.Pi.Command
function Command.get_commands()
	return Command.new("get_commands")
end

--- Extension UI ------------------------------------------------------------

---@class Crust.Pi.UiResponseOpts
---@field value? string select, input and editor answers
---@field confirmed? boolean confirm answers
---@field cancelled? boolean dismiss any dialog

---@param request_id string id of the extension_ui_request being answered
---@param opts Crust.Pi.UiResponseOpts
---@return Crust.Pi.Command
function Command.extension_ui_response(request_id, opts)
	return Command.new("extension_ui_response", {
		id = request_id,
		value = opts.value,
		confirmed = opts.confirmed,
		cancelled = opts.cancelled,
	})
end

return Command
