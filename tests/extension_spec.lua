-- Specs poke at private fields and pass luassert messages that its
-- stubs do not declare, none of which matters for the code under test.
---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Config = require("crust.config")
local Extension = require("crust.extension")

describe("extension", function()
	after_each(function()
		Config.config = nil
	end)

	it("is off by default", function()
		assert.False(Extension.enabled())
		assert.are.same({}, Extension.args())
		assert.are.same({}, Extension.env())
	end)

	it("passes the bundled extension when enabled", function()
		local args = Extension.args({ enabled = true })
		assert.are.equal("-e", args[1])
		assert.are.equal(1, vim.fn.filereadable(args[2]))
		assert.truthy(args[2]:match("extensions/nvim%.ts$"))
	end)

	it("warns and passes nothing for a missing extension", function()
		local args = Extension.args({ enabled = true, path = "/tmp/crust-no-such-extension.ts" })
		assert.are.same({}, args)
	end)

	it("exports the socket in the process environment", function()
		local env = Extension.env({ enabled = true, server = "/tmp/crust-test.sock" })
		assert.are.equal("/tmp/crust-test.sock", env[Extension.SERVER_ENV])
	end)

	describe("token", function()
		it("is 32 random hex characters, stable for the session", function()
			local token = Extension.token()
			assert.are.equal(32, #token)
			assert.truthy(token:match("^[0-9a-f]+$"))
			assert.are.equal(token, Extension.token())
		end)

		it("authorizes only itself", function()
			assert.True(Extension.authorized(Extension.token()))
			assert.False(Extension.authorized("nope"))
			assert.False(Extension.authorized(nil))
			assert.False(Extension.authorized(""))
		end)

		it("hands it over in a private one-shot file", function()
			local env = Extension.env({ enabled = true, server = "/tmp/crust-test.sock" })
			local path = env[Extension.TOKEN_ENV]
			assert.is_string(path)
			assert.are.same({ Extension.token() }, vim.fn.readfile(path))
			assert.are.equal("600", string.format("%o", vim.uv.fs_stat(path).mode % 512))
			vim.fn.delete(path)
		end)
	end)

	it("starts a neovim server when there is none configured", function()
		local address = Extension.server({ enabled = true })
		assert.is_string(address)
		assert.is_true(#address > 0)
		-- Cached, so a second chat reuses the same socket.
		assert.are.equal(address, Extension.server({ enabled = true }))
	end)

	it("sets up the tools that need state of their own", function()
		Extension.setup({ enabled = true, server = "/tmp/crust-test.sock" })
		assert.is_true(#vim.api.nvim_get_autocmds({ group = "crust.extension.context" }) > 0)
	end)
end)