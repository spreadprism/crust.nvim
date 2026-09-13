--- Live checks that the prompt and context flags reach a real pi session,
--- and that pi's own AGENTS.md discovery keeps working next to ours.

local Pi = require("crust.pi.client")
local Rpc = require("crust.pi.rpc")
local config = require("crust.config")

local ANSWER_TIMEOUT_MS = 120000
local TEST_MODEL = "anthropic/claude-haiku-4-5"

---@return string[]
local function isolated_args()
	local args = { "--no-session", "--no-skills", "--no-tools" }
	for _, path in ipairs(vim.split(vim.env.CRUST_TEST_PI_EXTENSIONS or "", ":", { trimempty = true })) do
		vim.list_extend(args, { "-e", path })
	end
	return args
end

--- Run one prompt in `cwd` and return the assistant's text.
---@param cwd string
---@param opts table extra Pi options
---@param message string
---@return string
local function ask(cwd, opts, message)
	local text = {}
	local done = false

	local pi = Pi.new(vim.tbl_extend("force", {
		bin = config.get().bin,
		model = TEST_MODEL,
		args = isolated_args(),
		cwd = cwd,
		log = false,
		on_event = function(event)
			local ev = event.assistantMessageEvent
			if event.type == "message_update" and ev and ev.type == "text_delta" then
				text[#text + 1] = ev.delta
			elseif event.type == "agent_end" then
				done = true
			end
		end,
	}, opts))

	local ok, err = pi:connect()
	assert(ok, err)
	pi:send(Rpc.prompt(message))

	vim.wait(ANSWER_TIMEOUT_MS, function()
		return done
	end, 200)
	pi:close()

	return table.concat(text)
end

describe("pi context", function()
	local dir

	before_each(function()
		config.options = {}
		config.config = nil
		dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
	end)

	after_each(function()
		vim.fn.delete(dir, "rf")
	end)

	---@param name string
	---@param lines string[]
	---@return string path
	local function write(name, lines)
		local path = dir .. "/" .. name
		vim.fn.writefile(lines, path)
		return path
	end

	it("still loads the project's own AGENTS.md", function()
		write("AGENTS.md", {
			"# Project rules",
			"",
			"The project codename is BLUEFISH.",
			"When asked for the codename, answer with it and nothing else.",
		})

		local answer = ask(dir, {}, "What is the project codename?")
		assert.is_truthy(answer:upper():find("BLUEFISH", 1, true), "answer was: " .. answer)
	end)

	it("loads an extra context file next to AGENTS.md", function()
		write("AGENTS.md", { "The project codename is BLUEFISH." })
		local extra = write("EXTRA.md", { "The deploy target is MOONBASE." })

		local answer = ask(dir, { context = { files = extra } }, "Give the codename and the deploy target.")
		assert.is_truthy(answer:upper():find("BLUEFISH", 1, true), "answer was: " .. answer)
		assert.is_truthy(answer:upper():find("MOONBASE", 1, true), "answer was: " .. answer)
	end)

	it("loads extra context lines", function()
		local answer = ask(
			dir,
			{ context = { append = "The deploy target is MOONBASE. Answer with it when asked." } },
			"What is the deploy target?"
		)
		assert.is_truthy(answer:upper():find("MOONBASE", 1, true), "answer was: " .. answer)
	end)

	it("can turn off pi's context discovery", function()
		write("AGENTS.md", { "The project codename is BLUEFISH." })

		local answer = ask(
			dir,
			{ context = { enabled = false } },
			"What is the project codename? If you do not know, answer exactly: UNKNOWN"
		)
		assert.is_falsy(answer:upper():find("BLUEFISH", 1, true), "answer was: " .. answer)
	end)

	it("keeps the session working with a replaced system prompt", function()
		local answer = ask(dir, {
			prompt = {
				system_prompt = "You are a test bot. Always answer with exactly: PROMPT-OK",
				include_defaults = false,
			},
		}, "hello")
		assert.is_truthy(answer:find("PROMPT-OK", 1, true), "answer was: " .. answer)
	end)
end)
