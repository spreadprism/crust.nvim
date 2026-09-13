local Config = require("crust.config")
local Mcp = require("crust.integrations.mcp_server")

describe("mcp_server", function()
	after_each(function()
		Config.config = nil
	end)

	it("is off by default", function()
		assert.False(Mcp.enabled())
		assert.are.same({}, Mcp.args())
		assert.are.same({}, Mcp.env())
	end)

	it("passes the bundled extension when enabled", function()
		local args = Mcp.args({ enabled = true })
		assert.are.equal("-e", args[1])
		assert.are.equal(1, vim.fn.filereadable(args[2]))
		assert.truthy(args[2]:match("extensions/mcp%-server%.ts$"))
	end)

	it("warns and passes nothing for a missing extension", function()
		local args = Mcp.args({ enabled = true, extension = "/tmp/crust-no-such-extension.ts" })
		assert.are.same({}, args)
	end)

	it("exports the socket in the process environment", function()
		local env = Mcp.env({ enabled = true, server = "/tmp/crust-test.sock" })
		assert.are.same({ [Mcp.SERVER_ENV] = "/tmp/crust-test.sock" }, env)
	end)

	it("starts a neovim server when there is none configured", function()
		local address = Mcp.server({ enabled = true })
		assert.is_string(address)
		assert.is_true(#address > 0)
		-- Cached, so a second chat reuses the same socket.
		assert.are.equal(address, Mcp.server({ enabled = true }))
	end)

	describe("snapshot", function()
		it("reports cwd, the current buffer and the cursor", function()
			local buf = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
			vim.api.nvim_win_set_buf(0, buf)

			local snapshot = vim.json.decode(Mcp.snapshot())
			assert.are.equal(vim.fn.getcwd(), snapshot.cwd)
			assert.are.equal(buf, snapshot.current.buf)
			assert.are.equal(2, snapshot.current.lines)
			assert.are.equal(1, snapshot.cursor.line)
			assert.is_table(snapshot.buffers)
		end)
	end)

	describe("diagnostics", function()
		it("returns an empty list for an unknown file", function()
			local result = vim.json.decode(Mcp.diagnostics("/tmp/crust-no-such-file.lua"))
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
			for _, item in ipairs(vim.json.decode(Mcp.diagnostics()).diagnostics) do
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
