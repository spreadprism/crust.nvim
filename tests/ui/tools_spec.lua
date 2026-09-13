local Tools = require("crust.ui.chat.tools")
local Display = require("crust.ui.chat.tools.display")
local Output = require("crust.ui.chat.output")
local config = require("crust.config")
local Highlights = require("crust.ui.highlights")

--- Highlighted substrings of a rendered display, as { group, text } pairs.
---@param display Crust.Chat.Tools.Display
---@return table[]
local function segments(display)
	local render = display:render()
	local out = {}
	for _, hl in ipairs(render.highlights) do
		if not hl.priority then
			out[#out + 1] = { hl.group, render.lines[hl.line]:sub(hl.col + 1, hl.end_col) }
		end
	end
	return out
end

---@param text string
---@return Crust.Pi.ToolResult
local function result(text)
	return { content = { { type = "text", text = text } } }
end

describe("ui.chat.tools", function()
	local icons

	before_each(function()
		config.options = {}
		config.config = nil
		icons = config.get().icons
	end)

	describe("display", function()
		it("starts pending and resolves to success on end", function()
			local display = Display.new("bash", Tools.DEFAULT, { command = "ls" })
			assert.are.equal("pending", display.status)

			display:update({ type = "tool_execution_end", result = result("ok") })
			assert.are.equal("success", display.status)
			assert.are.equal("ok", display:result_text())
		end)

		it("resolves to error when the call fails", function()
			local display = Display.new("bash", Tools.DEFAULT, {})
			display:update({ type = "tool_execution_end", isError = true, result = result("boom") })
			assert.are.equal("error", display.status)
		end)

		it("keeps partial results while pending", function()
			local display = Display.new("bash", Tools.DEFAULT, {})
			display:update({ type = "tool_execution_update", partialResult = result("half") })
			assert.are.equal("pending", display.status)
			assert.are.equal("half", display:result_text())
		end)

		it("uses the configured icon for each status", function()
			local display = Display.new("bash", Tools.DEFAULT, {})
			assert.are.equal(icons.pending, display:icon())
			display:set_status("success")
			assert.are.equal(icons.success, display:icon())
			display:set_status("error")
			assert.are.equal(icons.error, display:icon())
		end)

		it("renders icon, tool name, then title", function()
			local display = Display.new("bash", { title = "tool title" }, {})
			assert.are.equal(icons.pending .. " bash: tool title", display:lines()[1])
		end)

		it("renders the tool name alone when there is no title", function()
			local display = Display.new("bash", {}, {})
			assert.are.equal(icons.pending .. " bash", display:lines()[1])
		end)

		it("accepts a function title and indents body lines", function()
			local display = Display.new("thing", {
				title = function(d)
					return d.name .. "!"
				end,
				body = function()
					return { "one", "two" }
				end,
			}, {})
			assert.are.same({
				icons.pending .. " thing: thing!",
				"  one",
				"  two",
			}, display:lines())
		end)

		it("joins the body onto the title line when inline", function()
			local display = Display.new("thing", {
				inline = true,
				title = "do it",
				body = function()
					return { "fast", "twice" }
				end,
			}, {})
			assert.is_true(display:is_inline())
			assert.are.same({ icons.pending .. " thing: do it fast twice" }, display:lines())
		end)

		it("renders an inline title alone when the body is empty", function()
			local display = Display.new("thing", { inline = true, title = "do it" }, {})
			assert.are.same({ icons.pending .. " thing: do it" }, display:lines())
		end)

		it("is not inline unless the spec asks for it", function()
			local display = Display.new("thing", { title = "do it" }, {})
			assert.is_false(display:is_inline())
		end)

		it("accepts a string body", function()
			local display = Display.new("thing", {
				body = function()
					return "a\nb"
				end,
			}, {})
			assert.are.same({ "  a", "  b" }, { display:lines()[2], display:lines()[3] })
		end)
	end)

	describe("highlights", function()
		it("defines every group with default = true", function()
			Highlights.setup(true)
			for name in pairs(Highlights.groups) do
				assert.is_truthy(name:match("^Crust"))
				assert.is_not_nil(vim.api.nvim_get_hl(0, { name = name }))
			end
		end)

		it("highlights icon, tool, title and inline body separately", function()
			local display = Display.new("read", Tools.spec("read"), { path = "README.md" })
			display:update({ type = "tool_execution_end", result = result(string.rep("x\n", 55) .. "x") })

			assert.are.same({
				{ Highlights.TOOL_ICON_SUCCESS, icons.success },
				{ Highlights.TOOL, "read:" },
				{ Highlights.TOOL_TITLE, "README.md" },
				{ Highlights.TOOL_BODY_INLINE, "56 lines" },
			}, segments(display))
		end)

		it("highlights each body line for multi-line tools", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "ls" })
			display:update({ type = "tool_execution_end", result = result("a\nb") })

			assert.are.same({
				{ Highlights.TOOL_ICON_SUCCESS, icons.success },
				{ Highlights.TOOL, "bash:" },
				{ Highlights.TOOL_TITLE, "ls" },
				{ Highlights.TOOL_BODY, "a" },
				{ Highlights.TOOL_BODY, "b" },
			}, segments(display))
		end)

		-- "lua" ships with neovim, the bash parser does not exist in the
		-- isolated test runner. The bash spec uses the same mechanism.
		it("highlights the title with a treesitter language", function()
			local display = Display.new("eval", { title_lang = "lua", title = 'local x = "hi"' }, {})
			local groups = vim.tbl_map(function(segment)
				return segment[1]
			end, segments(display))

			assert.is_falsy(vim.tbl_contains(groups, Highlights.TOOL_TITLE))
			assert.is_truthy(vim.tbl_contains(groups, "@keyword"))
			assert.is_truthy(vim.tbl_contains(groups, "@string"))
		end)

		it("highlights the title in place, after the tool name", function()
			local display = Display.new("eval", { title_lang = "lua", title = "local x" }, {})
			for _, segment in ipairs(segments(display)) do
				if segment[1] == "@keyword" then
					assert.are.equal("local", segment[2])
				end
			end
		end)

		it("highlights body lines with a treesitter language", function()
			local display = Display.new("eval", {
				body_lang = "lua",
				title = "run",
				body = function()
					return { "local a = 1", 'local b = "two"' }
				end,
			}, {})

			local render = display:render()
			assert.are.same({
				icons.pending .. " eval: run",
				"  local a = 1",
				'  local b = "two"',
			}, render.lines)

			local body_lines = {}
			for _, hl in ipairs(render.highlights) do
				if hl.line > 1 then
					body_lines[hl.line] = true
					-- Columns must account for the two-space indent.
					assert.is_true(hl.col >= 2)
					assert.is_true(hl.end_col <= #render.lines[hl.line])
				end
			end
			assert.is_true(body_lines[2])
			assert.is_true(body_lines[3])
		end)

		it("configures the bash title to render as shell code", function()
			assert.are.equal("bash", Tools.spec("bash").title_lang)
		end)

		it("falls back to the flat groups without a language", function()
			local display = Display.new("thing", {
				title = "plain",
				body = function()
					return { "one" }
				end,
			}, {})

			assert.are.same({
				{ Highlights.TOOL_ICON_PENDING, icons.pending },
				{ Highlights.TOOL, "thing:" },
				{ Highlights.TOOL_TITLE, "plain" },
				{ Highlights.TOOL_BODY, "one" },
			}, segments(display))
		end)

		it("falls back when the language is not installed", function()
			local display = Display.new("thing", { title = "plain", title_lang = "not-a-language" }, {})
			local groups = vim.tbl_map(function(segment)
				return segment[1]
			end, segments(display))
			assert.is_truthy(vim.tbl_contains(groups, Highlights.TOOL_TITLE))
		end)

		--- Background segments only, as { group, text } pairs.
		---@param display Crust.Chat.Tools.Display
		local function backgrounds(display)
			local render = display:render()
			local out = {}
			for _, hl in ipairs(render.highlights) do
				if hl.priority then
					out[#out + 1] = { hl.group, render.lines[hl.line]:sub(hl.col + 1, hl.end_col) }
				end
			end
			return out
		end

		it("shades only the title text, not the icon or tool name", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "echo foobar" })
			display:update({ type = "tool_execution_end", result = result("foobar") })

			assert.are.same({ { Highlights.TOOL_BACKGROUND, "echo foobar" } }, backgrounds(display))
		end)

		it("gives output lines a full-width line background", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "echo foobar" })
			display:update({ type = "tool_execution_end", result = result("foo\nbar") })

			local render = display:render()
			assert.are.same({ "  foo", "  bar" }, { render.lines[2], render.lines[3] })
			assert.are.same({
				[2] = Highlights.TOOL_BODY_BACKGROUND,
				[3] = Highlights.TOOL_BODY_BACKGROUND,
			}, render.line_highlights)
		end)

		it("shades an inline body as a range, it shares the title line", function()
			local display = Display.new("read", Tools.spec("read"), { path = "x" })
			display:update({ type = "tool_execution_end", result = result("a\nb") })

			assert.are.same({
				{ Highlights.TOOL_BACKGROUND, "x" },
				{ Highlights.TOOL_BODY_BACKGROUND, "2 lines" },
			}, backgrounds(display))
			assert.are.same({}, display:render().line_highlights)
		end)

		it("draws backgrounds below the text highlights", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "echo hi" })
			for _, hl in ipairs(display:render().highlights) do
				if hl.group:find("Background", 1, true) then
					assert.is_true(hl.priority < 4096)
				else
					assert.is_nil(hl.priority)
				end
			end
		end)

		it("adds no background when there is no title", function()
			local display = Display.new("mystery", Tools.DEFAULT, {})
			assert.are.same({}, backgrounds(display))
		end)

		it("keeps backgrounds in sync when a block shrinks", function()
			local out = Output.new()
			local tools = Tools.new()
			local ns = vim.api.nvim_get_namespaces()["crust.chat.output.highlights"]

			tools:render(out, {
				type = "tool_execution_start",
				toolCallId = "1",
				toolName = "bash",
				args = { command = "ls" },
			})
			tools:render(out, {
				type = "tool_execution_update",
				toolCallId = "1",
				toolName = "bash",
				partialResult = result("a\nb\nc"),
			})
			tools:render(out, {
				type = "tool_execution_end",
				toolCallId = "1",
				toolName = "bash",
				result = result("a"),
			})

			local rows = {}
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(out:buf(), ns, 0, -1, { details = true })) do
				if mark[4].line_hl_group or (mark[4].priority and mark[4].priority < 4096) then
					rows[#rows + 1] = mark[2]
				end
			end

			-- Title range plus one output line, nothing stranded past the block.
			assert.are.same({ 0, 1 }, rows)
		end)

		it("uses a status-specific icon group", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "ls" })
			assert.are.equal(Highlights.TOOL_ICON_PENDING, segments(display)[1][1])
			display:update({ type = "tool_execution_end", isError = true, result = result("boom") })
			assert.are.equal(Highlights.TOOL_ICON_ERROR, segments(display)[1][1])
		end)

		it("applies the highlights to the output buffer", function()
			local out = Output.new()
			local tools = Tools.new()
			tools:render(out, {
				type = "tool_execution_start",
				toolCallId = "1",
				toolName = "read",
				args = { path = "README.md" },
			})
			tools:render(out, {
				type = "tool_execution_end",
				toolCallId = "1",
				toolName = "read",
				result = result("a\nb"),
			})

			local ns = vim.api.nvim_get_namespaces()["crust.chat.output.highlights"]
			local marks = vim.api.nvim_buf_get_extmarks(out:buf(), ns, 0, -1, { details = true })
			local groups = {}
			for _, mark in ipairs(marks) do
				if not mark[4].line_hl_group and (not mark[4].priority or mark[4].priority >= 4096) then
					groups[#groups + 1] = mark[4].hl_group
				end
			end

			-- Exactly one set of marks: the pending render must not linger.
			assert.are.same({
				Highlights.TOOL_ICON_SUCCESS,
				Highlights.TOOL,
				Highlights.TOOL_TITLE,
				Highlights.TOOL_BODY_INLINE,
			}, groups)
		end)
	end)

	describe("specs", function()
		it("falls back to the default spec for unknown tools", function()
			assert.are.equal(Tools.DEFAULT, Tools.spec("definitely-not-a-tool"))
		end)

		it("summarizes the most telling argument by default", function()
			local display = Display.new("grep", Tools.DEFAULT, { pattern = "foo" })
			assert.are.equal("foo", display:title())
		end)

		it("shows no title when no argument matches", function()
			local display = Display.new("mystery", Tools.DEFAULT, { weird = 42 })
			assert.are.equal("", display:title())
			assert.are.same({ icons.pending .. " mystery" }, display:lines())
		end)

		it("renders bash as the command with its output", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "ls  -la" })
			assert.are.equal("ls -la", display:title())
			display:update({ type = "tool_execution_end", result = result("a\nb") })
			assert.are.same({ "a", "b" }, display:body())
		end)

		it("truncates long bash output", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "ls" })
			local lines = {}
			for i = 1, 30 do
				lines[i] = "line " .. i
			end
			display:update({ type = "tool_execution_end", result = result(table.concat(lines, "\n")) })

			local body = display:body()
			assert.are.equal(11, #body)
			assert.are.equal("… 20 more lines", body[1])
			assert.are.equal("line 30", body[#body])
		end)

		it("renders read inline as a path plus its line count", function()
			local display = Display.new("read", Tools.spec("read"), { path = "/tmp/x.lua" })
			assert.are.equal("/tmp/x.lua", display:title())
			display:update({ type = "tool_execution_end", result = result("a\nb\nc") })
			assert.are.same({ "3 lines" }, display:body())
			assert.are.same({ icons.success .. " read: /tmp/x.lua 3 lines" }, display:lines())
		end)

		it("keeps bash multi-line", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "ls" })
			display:update({ type = "tool_execution_end", result = result("a\nb") })
			assert.are.same({ icons.success .. " bash: ls", "  a", "  b" }, display:lines())
		end)

		it("registers a custom spec", function()
			Tools.register("custom-tool", { title = "custom!" })
			assert.are.equal("custom!", Tools.spec("custom-tool").title)
			Tools.registry["custom-tool"] = nil
		end)
	end)

	describe("render", function()
		---@type Crust.Chat.Output
		local out
		---@type Crust.Chat.Tools
		local tools

		before_each(function()
			out = Output.new()
			tools = Tools.new()
		end)

		it("handles only tool execution events", function()
			assert.is_true(Tools.handles("tool_execution_start"))
			assert.is_true(Tools.handles("tool_execution_update"))
			assert.is_true(Tools.handles("tool_execution_end"))
			assert.is_false(Tools.handles("message_update"))
		end)

		it("updates one block in place across the call lifecycle", function()
			tools:render(out, {
				type = "tool_execution_start",
				toolCallId = "call-1",
				toolName = "bash",
				args = { command = "sleep 2" },
			})
			assert.are.same({ icons.pending .. " bash: sleep 2", "", "" }, out:lines())

			tools:render(out, {
				type = "tool_execution_update",
				toolCallId = "call-1",
				toolName = "bash",
				partialResult = result("hi"),
			})
			tools:render(out, {
				type = "tool_execution_end",
				toolCallId = "call-1",
				toolName = "bash",
				result = result("hi"),
			})

			assert.are.same({ icons.success .. " bash: sleep 2", "  hi", "", "" }, out:lines())
		end)

		it("keeps assistant text streamed between tool events out of the block", function()
			tools:render(out, {
				type = "tool_execution_start",
				toolCallId = "call-1",
				toolName = "bash",
				args = { command = "ls" },
			})
			out:append("thinking…")
			tools:render(out, {
				type = "tool_execution_end",
				toolCallId = "call-1",
				toolName = "bash",
				result = result("done"),
			})

			assert.are.same({
				icons.success .. " bash: ls",
				"  done",
				"",
				"thinking…",
			}, out:lines())
		end)

		it("renders separate blocks for separate calls", function()
			tools:render(out, { type = "tool_execution_start", toolCallId = "a", toolName = "bash", args = { command = "one" } })
			tools:render(out, { type = "tool_execution_start", toolCallId = "b", toolName = "bash", args = { command = "two" } })
			tools:render(out, { type = "tool_execution_end", toolCallId = "a", toolName = "bash", result = result("1") })

			assert.are.same({
				icons.success .. " bash: one",
				"  1",
				"",
				icons.pending .. " bash: two",
				"",
				"",
			}, out:lines())
		end)

		it("marks failed calls with the error icon", function()
			tools:render(out, { type = "tool_execution_start", toolCallId = "a", toolName = "read", args = { path = "x" } })
			tools:render(out, {
				type = "tool_execution_end",
				toolCallId = "a",
				toolName = "read",
				isError = true,
				result = result("no such file"),
			})

			assert.are.same({ icons.error .. " read: x no such file", "", "" }, out:lines())
		end)

		it("ignores events without a tool call id", function()
			tools:render(out, { type = "tool_execution_start", toolName = "bash" })
			assert.are.same({ "" }, out:lines())
		end)
	end)
end)
