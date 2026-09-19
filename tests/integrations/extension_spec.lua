local Tools = require("crust.integrations.extension")

--- Call a tool the way pi does: name plus a json object string.
---@param name string
---@param args? table
---@return table
local function call(name, args)
	return vim.json.decode(Tools.call(name, vim.json.encode(args or vim.empty_dict())))
end

describe("extension tools", function()
	describe("manifest", function()
		it("describes every tool", function()
			local manifest = vim.json.decode(Tools.manifest())
			assert.is_true(#manifest > 0)

			local names = {}
			for _, tool in ipairs(manifest) do
				names[tool.name] = tool
				assert.is_string(tool.description)
				assert.are.equal("object", tool.parameters.type)
			end

			assert.is_table(names.nvim_context)
			assert.is_true(names.nvim_context.context)
			assert.is_table(names.nvim_diagnostics.parameters.properties.path)
		end)
	end)

	describe("call", function()
		it("reports unknown tools and bad arguments instead of raising", function()
			assert.is_string(vim.json.decode(Tools.call("nvim_nope", "{}")).error)
			assert.is_string(vim.json.decode(Tools.call("nvim_context", "not json")).error)
		end)
	end)

	describe("nvim_context", function()
		it("reports cwd, the current buffer and the cursor", function()
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
			vim.api.nvim_win_set_buf(0, buf)

			local snapshot = call("nvim_context")
			assert.are.equal(vim.fn.getcwd(), snapshot.cwd)
			assert.are.equal(buf, snapshot.current.buf)
			assert.are.equal(2, snapshot.current.lines)
			assert.are.equal(1, snapshot.cursor.line)
			assert.is_table(snapshot.buffers)
		end)

		it("reports the last real window, not the chat input", function()
			Tools.setup()

			local file = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_lines(file, 0, -1, false, { "one", "two", "three" })
			vim.api.nvim_win_set_buf(0, file)
			vim.api.nvim_win_set_cursor(0, { 3, 0 })
			-- WinEnter does not fire for the window we are already in.
			vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = file })

			-- The chat input takes over the only window, as it does on :Crust chat.
			local input = vim.api.nvim_create_buf(false, true)
			vim.bo[input].filetype = require("crust.filetypes").input
			vim.api.nvim_buf_set_name(input, "crust://input-test")
			local win = vim.api.nvim_open_win(input, true, {
				relative = "editor",
				row = 0,
				col = 0,
				width = 20,
				height = 3,
			})

			local snapshot = call("nvim_context")
			assert.are.equal(file, snapshot.current.buf)
			assert.are.equal(3, snapshot.cursor.line)
			for _, item in ipairs(snapshot.buffers) do
				assert.are_not.equal(input, item.buf)
			end

			vim.api.nvim_win_close(win, true)
		end)
	end)

	describe("nvim_diagnostics", function()
		it("returns an empty list for an unknown file", function()
			local result = call("nvim_diagnostics", { path = "/tmp/crust-no-such-file.lua" })
			assert.are.same({}, result.diagnostics)
		end)

		it("reports diagnostics of a buffer", function()
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "broken" })
			local ns = vim.api.nvim_create_namespace("crust-test")
			vim.diagnostic.set(ns, buf, {
				{ lnum = 0, col = 0, severity = vim.diagnostic.severity.ERROR, message = "boom" },
			})

			local found = false
			for _, item in ipairs(call("nvim_diagnostics").diagnostics) do
				if item.message == "boom" then
					found = true
					assert.are.equal("ERROR", item.severity)
					assert.are.equal(1, item.line)
				end
			end
			assert.True(found)
		end)
	end)
end)
