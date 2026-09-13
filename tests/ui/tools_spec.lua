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
		out[#out + 1] = { hl.group, render.lines[hl.line]:sub(hl.col + 1, hl.end_col) }
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
			assert.are.equal("> " .. icons.pending .. " bash: tool title", display:lines()[1])
		end)

		it("renders the tool name alone when there is no title", function()
			local display = Display.new("bash", {}, {})
			assert.are.equal("> " .. icons.pending .. " bash", display:lines()[1])
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
				"> " .. icons.pending .. " thing: thing!",
				"> one",
				"> two",
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
			assert.are.same({ "> " .. icons.pending .. " thing: do it fast twice" }, display:lines())
		end)

		it("renders an inline title alone when the body is empty", function()
			local display = Display.new("thing", { inline = true, title = "do it" }, {})
			assert.are.same({ "> " .. icons.pending .. " thing: do it" }, display:lines())
		end)

		it("accepts a function for inline", function()
			local spec = {
				title = "t",
				inline = function(display)
					return display.status ~= "error"
				end,
				body = function()
					return { "detail" }
				end,
			}

			local display = Display.new("thing", spec, {})
			assert.is_true(display:is_inline())

			display:set_status("error")
			assert.is_false(display:is_inline())
			assert.are.same({ "> " .. icons.error .. " thing: t", "> detail" }, display:lines())
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
			assert.are.same({ "> a", "> b" }, { display:lines()[2], display:lines()[3] })
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
				{ Highlights.TOOL_PREFIX, "> " },
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
				-- the block prefix of each line is added last
				{ Highlights.TOOL_PREFIX, "> " },
				{ Highlights.TOOL_PREFIX, "> " },
				{ Highlights.TOOL_PREFIX, "> " },
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
				"> " .. icons.pending .. " eval: run",
				"> local a = 1",
				'> local b = "two"',
			}, render.lines)

			local body_lines = {}
			for _, hl in ipairs(render.highlights) do
				if hl.line > 1 and hl.group ~= Highlights.TOOL_PREFIX then
					body_lines[hl.line] = true
					-- Columns must account for the block prefix.
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
				{ Highlights.TOOL_PREFIX, "> " },
				{ Highlights.TOOL_PREFIX, "> " },
			}, segments(display))
		end)

		it("falls back when the language is not installed", function()
			local display = Display.new("thing", { title = "plain", title_lang = "not-a-language" }, {})
			local groups = vim.tbl_map(function(segment)
				return segment[1]
			end, segments(display))
			assert.is_truthy(vim.tbl_contains(groups, Highlights.TOOL_TITLE))
		end)

		it("puts the block prefix in front of every line", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "cat x" })
			display:update({ type = "tool_execution_end", isError = true, result = result("no such file\n\ncode 1") })

			assert.are.same({
				"> " .. icons.error .. " bash: cat x",
				"> no such file",
				"> ",
				"> code 1",
			}, display:lines())
		end)

		it("shifts highlights past the block prefix", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "cat x" })
			display:update({ type = "tool_execution_end", result = result("out") })

			local render = display:render()
			for _, hl in ipairs(render.highlights) do
				local text = render.lines[hl.line]:sub(hl.col + 1, hl.end_col)
				if hl.group == Highlights.TOOL then
					assert.are.equal("bash:", text)
				elseif hl.group == Highlights.TOOL_BODY then
					assert.are.equal("out", text)
				end
			end
		end)

		it("cuts a long title to the given width", function()
			local long = "ls -la MARKDOWN.md 2>/dev/null || find . -maxdepth 3 -iname MARKDOWN.md"
			local display = Display.new("bash", Tools.spec("bash"), { command = long })

			local line = display:lines(40)[1]
			assert.are.equal(40, vim.fn.strdisplaywidth(line))
			assert.are.equal("…", line:sub(-3))
		end)

		it("leaves a short title alone", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "ls" })
			assert.are.equal(display:lines()[1], display:lines(40)[1])
		end)

		it("does not cut output lines", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "ls" })
			display:update({ type = "tool_execution_end", result = result(string.rep("x", 80)) })

			assert.are.equal(82, #display:lines(40)[2])
		end)

		it("drops highlights past the cut and clamps the one crossing it", function()
			local long = "echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
			local display = Display.new("bash", Tools.spec("bash"), { command = long })

			local render = display:render(30)
			local limit = #render.lines[1]
			for _, hl in ipairs(render.highlights) do
				if hl.line == 1 then
					assert.is_true(hl.col < limit)
					assert.is_true(hl.end_col <= limit)
				end
			end
		end)

		it("shades every line of the call", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "echo foobar" })
			display:update({ type = "tool_execution_end", result = result("foobar") })

			assert.are.same({
				Highlights.TOOL_BACKGROUND,
				Highlights.TOOL_BODY_BACKGROUND,
			}, display:render().line_highlights)
		end)

		it("gives output lines a full-width line background", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "echo foobar" })
			display:update({ type = "tool_execution_end", result = result("foo\nbar") })

			local render = display:render()
			assert.are.same({ "> foo", "> bar" }, { render.lines[2], render.lines[3] })
			assert.are.same({
				Highlights.TOOL_BACKGROUND,
				Highlights.TOOL_BODY_BACKGROUND,
				Highlights.TOOL_BODY_BACKGROUND,
			}, render.line_highlights)
		end)

		it("shades an inline call as one line", function()
			local display = Display.new("read", Tools.spec("read"), { path = "x" })
			display:update({ type = "tool_execution_end", result = result("a\nb") })

			assert.are.same({ Highlights.TOOL_BACKGROUND }, display:render().line_highlights)
		end)

		it("shades a call that has no title", function()
			local display = Display.new("mystery", Tools.DEFAULT, {})
			assert.are.same({ Highlights.TOOL_BACKGROUND }, display:render().line_highlights)
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
				if mark[4].line_hl_group then
					rows[#rows + 1] = mark[2]
				end
			end

			-- Title line plus one output line, nothing stranded past the block.
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
				if not mark[4].line_hl_group then
					groups[#groups + 1] = mark[4].hl_group
				end
			end

			-- Exactly one set of marks: the pending render must not linger.
			-- extmarks come back ordered by position, so the prefix is first
			assert.are.same({
				Highlights.TOOL_PREFIX,
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
			assert.are.same({ "> " .. icons.pending .. " mystery" }, display:lines())
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

		it("renders a failed read as a multi-line body", function()
			local display = Display.new("read", Tools.spec("read"), { path = "markdown.md" })
			display:update({ type = "tool_execution_end", isError = true, result = result("ENOENT: no such file") })

			assert.is_false(display:is_inline())
			assert.are.same({
				"> " .. icons.error .. " read: markdown.md",
				"> ENOENT: no such file",
			}, display:lines())
		end)

		it("renders read inline as a path plus its line count", function()
			local display = Display.new("read", Tools.spec("read"), { path = "/tmp/x.lua" })
			assert.are.equal("/tmp/x.lua", display:title())
			display:update({ type = "tool_execution_end", result = result("a\nb\nc") })
			assert.are.same({ "3 lines" }, display:body())
			assert.are.same({ "> " .. icons.success .. " read: /tmp/x.lua 3 lines" }, display:lines())
		end)

		it("keeps bash multi-line", function()
			local display = Display.new("bash", Tools.spec("bash"), { command = "ls" })
			display:update({ type = "tool_execution_end", result = result("a\nb") })
			assert.are.same({ "> " .. icons.success .. " bash: ls", "> a", "> b" }, display:lines())
		end)

		describe("edit", function()
			local PATH = "sample.lua"

			---@param diff string?
			---@return Crust.Pi.ToolResult
			local function edit_result(diff)
				return {
					content = { { type = "text", text = "Successfully replaced 1 block(s) in " .. PATH .. "." } },
					details = diff and { diff = diff } or nil,
				}
			end

			---@param args table
			---@return Crust.Chat.Tools.Display
			local function display_for(args)
				return Display.new("edit", Tools.spec("edit"), args)
			end

			it("renders the path inline, like read", function()
				local display = display_for({ path = PATH, edits = { { oldText = "a", newText = "b" } } })
				display:update({
					type = "tool_execution_end",
					result = edit_result(" 1 local a = 1\n-2 local b = 2\n+2 local b = 42\n 3 local c = 3"),
				})

				assert.is_true(display:is_inline())
				assert.are.equal(PATH, display:title())
				assert.are.same({ "> " .. icons.success .. " edit: " .. PATH .. " +1 -1" }, display:lines())
			end)

			it("counts added and removed lines from the diff", function()
				local display = display_for({ path = PATH, edits = { { oldText = "a", newText = "b" } } })
				display:update({
					type = "tool_execution_end",
					result = edit_result(" 1 keep\n-2 gone\n-3 gone\n+2 new\n 4 keep"),
				})

				assert.are.same({ "+1 -2" }, display:body())
			end)

			it("falls back to the number of edits without a diff", function()
				local display = display_for({
					path = PATH,
					edits = { { oldText = "a", newText = "b" }, { oldText = "c", newText = "d" } },
				})
				display:update({ type = "tool_execution_end", result = edit_result(nil) })

				assert.are.same({ "2 edits" }, display:body())
			end)

			it("says one edit in the singular", function()
				local display = display_for({ path = PATH, edits = { { oldText = "a", newText = "b" } } })
				display:update({ type = "tool_execution_end", result = edit_result(nil) })

				assert.are.same({ "1 edit" }, display:body())
			end)

			it("shows nothing while pending", function()
				local display = display_for({ path = PATH, edits = { { oldText = "a", newText = "b" } } })
				assert.are.same({}, display:body())
				assert.are.same({ "> " .. icons.pending .. " edit: " .. PATH }, display:lines())
			end)

			it("renders a failure as a multi-line body", function()
				local display = display_for({ path = "gone.lua", edits = { { oldText = "x", newText = "y" } } })
				display:update({
					type = "tool_execution_end",
					isError = true,
					result = result("Could not find edits[0] in gone.lua"),
				})

				assert.is_false(display:is_inline())
				assert.are.same({
					"> " .. icons.error .. " edit: gone.lua",
					"> Could not find edits[0] in gone.lua",
				}, display:lines())
			end)

			it("shows only the tool name without a path", function()
				assert.are.equal("", display_for({}):title())
			end)
		end)

		describe("write", function()
			local PATH = "new.lua"

			---@param diff string?
			---@return Crust.Pi.ToolResult
			local function write_result(diff)
				return {
					content = { { type = "text", text = "Successfully wrote to " .. PATH } },
					details = diff and { diff = diff } or nil,
				}
			end

			---@param args table
			---@return Crust.Chat.Tools.Display
			local function display_for(args)
				return Display.new("write", Tools.spec("write"), args)
			end

			it("renders the path inline with diff counts, like edit", function()
				local display = display_for({ path = PATH, content = "a\nb" })
				display:update({
					type = "tool_execution_end",
					result = write_result(" 1 keep\n-2 gone\n+2 new\n+3 new"),
				})

				assert.is_true(display:is_inline())
				assert.are.equal(PATH, display:title())
				assert.are.same({ "> " .. icons.success .. " write: " .. PATH .. " +2 -1" }, display:lines())
			end)

			it("falls back to the line count of the content without a diff", function()
				local display = display_for({ path = PATH, content = "a\nb\nc" })
				display:update({ type = "tool_execution_end", result = write_result(nil) })

				assert.are.same({ "3 lines" }, display:body())
			end)

			it("says one line in the singular", function()
				local display = display_for({ path = PATH, content = "only" })
				display:update({ type = "tool_execution_end", result = write_result(nil) })

				assert.are.same({ "1 line" }, display:body())
			end)

			it("shows nothing while pending", function()
				local display = display_for({ path = PATH, content = "a" })
				assert.are.same({}, display:body())
				assert.are.same({ "> " .. icons.pending .. " write: " .. PATH }, display:lines())
			end)

			it("renders a failure as a multi-line body", function()
				local display = display_for({ path = PATH, content = "a" })
				display:update({
					type = "tool_execution_end",
					isError = true,
					result = result("EACCES: permission denied"),
				})

				assert.is_false(display:is_inline())
				assert.are.same({
					"> " .. icons.error .. " write: " .. PATH,
					"> EACCES: permission denied",
				}, display:lines())
			end)
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
			assert.are.same({ "> " .. icons.pending .. " bash: sleep 2", "", "" }, out:lines())

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

			assert.are.same({ "> " .. icons.success .. " bash: sleep 2", "> hi", "", "" }, out:lines())
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
				"> " .. icons.success .. " bash: ls",
				"> done",
				"",
				"thinking…",
			}, out:lines())
		end)

		it("renders separate blocks for separate calls", function()
			tools:render(out, { type = "tool_execution_start", toolCallId = "a", toolName = "bash", args = { command = "one" } })
			tools:render(out, { type = "tool_execution_start", toolCallId = "b", toolName = "bash", args = { command = "two" } })
			tools:render(out, { type = "tool_execution_end", toolCallId = "a", toolName = "bash", result = result("1") })

			assert.are.same({
				"> " .. icons.success .. " bash: one",
				"> 1",
				"",
				"> " .. icons.pending .. " bash: two",
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

			assert.are.same({ "> " .. icons.error .. " read: x", "> no such file", "", "" }, out:lines())
		end)

		---@param id string
		---@param name string
		---@param args table
		---@param text string
		---@param is_error? boolean
		local function call(tools, out, id, name, args, text, is_error)
			tools:render(out, { type = "tool_execution_start", toolCallId = id, toolName = name, args = args })
			tools:render(out, {
				type = "tool_execution_end",
				toolCallId = id,
				toolName = name,
				isError = is_error,
				result = result(text),
			})
		end

		it("stacks consecutive inline calls without a blank line", function()
			call(tools, out, "1", "read", { path = "a.md" }, "a")
			call(tools, out, "2", "read", { path = "b.md" }, "a\nb")

			assert.are.same({
				"> " .. icons.success .. " read: a.md 1 lines",
				"> " .. icons.success .. " read: b.md 2 lines",
				"",
				"",
			}, out:lines())
		end)

		it("keeps a blank line around multi-line calls", function()
			call(tools, out, "1", "bash", { command = "ls" }, "a")
			call(tools, out, "2", "read", { path = "a.md" }, "a")

			assert.are.same({
				"> " .. icons.success .. " bash: ls",
				"> a",
				"",
				"> " .. icons.success .. " read: a.md 1 lines",
				"",
				"",
			}, out:lines())
		end)

		it("does not stack across streamed text", function()
			call(tools, out, "1", "read", { path = "a.md" }, "a")
			out:append("thinking…")
			call(tools, out, "2", "read", { path = "b.md" }, "a")

			assert.are.same({
				"> " .. icons.success .. " read: a.md 1 lines",
				"",
				"thinking…",
				"",
				"> " .. icons.success .. " read: b.md 1 lines",
				"",
				"",
			}, out:lines())
		end)

		it("separates a call that stopped being inline", function()
			call(tools, out, "1", "read", { path = "a.md" }, "a")
			call(tools, out, "2", "read", { path = "x.md" }, "boom", true)
			call(tools, out, "3", "read", { path = "y.md" }, "a")

			assert.are.same({
				"> " .. icons.success .. " read: a.md 1 lines",
				"> " .. icons.error .. " read: x.md",
				"> boom",
				"",
				"> " .. icons.success .. " read: y.md 1 lines",
				"",
				"",
			}, out:lines())
		end)

		it("cuts the title to the output window", function()
			out:open(40)
			tools:render(out, {
				type = "tool_execution_start",
				toolCallId = "1",
				toolName = "bash",
				args = { command = string.rep("long-command ", 20) },
			})

			assert.is_true(vim.fn.strdisplaywidth(out:lines()[1]) <= out:width())
			out:close()
		end)

		it("ignores events without a tool call id", function()
			tools:render(out, { type = "tool_execution_start", toolName = "bash" })
			assert.are.same({ "" }, out:lines())
		end)
	end)
end)
