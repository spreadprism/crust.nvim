---@diagnostic disable: invisible, deprecated, redundant-parameter, param-type-mismatch

local Errors = require("crust.pi.errors")

--- The real thing, as pi wraps it over two stderr lines.
local RATE_LIMIT = {
	'Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your'
		.. " account's rate limit. Please try again",
	' later."},"request_id":"req_011Cfg2yxbMsU8ECbLNc4yqS"}',
}

--- A dead oauth refresh, as pi reports it on the message it gave up on:
--- the sentence, the same failure again under `details=`, then the stack.
local OAUTH = table.concat({
	"OAuth refresh failed for anthropic: Anthropic token refresh request failed."
		.. " url=https://platform.claude.com/v1/oauth/token; details=Error: HTTP request failed."
		.. ' status=400; url=https://platform.claude.com/v1/oauth/token; body={"error":'
		.. ' "invalid_grant", "error_description": "Refresh token not found or invalid"};'
		.. " stack=Error: HTTP request failed. status=400",
	"    at postJson (file:///nix/store/pi/anthropic.js:75:4438)",
	"    at async refreshAnthropicToken (file:///nix/store/pi/anthropic.js:75:7484)",
}, "\n")

describe("pi.errors", function()
	describe("join", function()
		it("puts a json body wrapped over two lines back together", function()
			local joined = Errors.join(RATE_LIMIT)

			assert.are.equal(1, #joined)
			assert.is_truthy(joined[1]:find("request_id", 1, true))
		end)

		it("leaves ordinary lines alone and drops the empty ones", function()
			assert.are.same({ "warming up", "done" }, Errors.join({ "warming up", "", "done" }))
		end)

		it("does not join across a body that closed", function()
			local joined = Errors.join({ '{"a":1}', "after" })
			assert.are.same({ '{"a":1}', "after" }, joined)
		end)

		it("ignores braces inside strings", function()
			local joined = Errors.join({ '{"text":"a { b"}', "after" })
			assert.are.same({ '{"text":"a { b"}', "after" }, joined)
		end)

		it("reports a body that never closed rather than swallowing it", function()
			assert.are.same({ '{"error":{' }, Errors.join({ '{"error":{' }))
		end)
	end)

	describe("parse", function()
		it("pulls the status, kind, message and request id out", function()
			local parsed = Errors.parse(Errors.join(RATE_LIMIT)[1])

			assert.are.equal(429, parsed.status)
			assert.are.equal("rate_limit_error", parsed.kind)
			assert.are.equal("req_011Cfg2yxbMsU8ECbLNc4yqS", parsed.request_id)
			assert.are.equal(
				"This request would exceed your account's rate limit. Please try again later.",
				parsed.message
			)
		end)

		it("takes a bare json body without a status line", function()
			local parsed = Errors.parse('{"error":{"type":"overloaded_error","message":"Overloaded"}}')

			assert.are.equal("overloaded_error", parsed.kind)
			assert.are.equal("Overloaded", parsed.message)
			assert.is_nil(parsed.status)
		end)

		it("keeps a plain line as the message, without its prefix", function()
			local parsed = Errors.parse("Error: 500 something went wrong")

			assert.are.equal(500, parsed.status)
			assert.are.equal("something went wrong", parsed.message)
			assert.is_nil(parsed.kind)
		end)

		it("reads an oauth body, past the details and the stack trace", function()
			local parsed = Errors.parse(OAUTH)

			assert.are.equal(400, parsed.status)
			assert.are.equal("invalid_grant", parsed.kind)
			assert.are.equal("Refresh token not found or invalid", parsed.message)
		end)

		it("answers nothing for an empty line", function()
			assert.is_nil(Errors.parse(""))
			assert.is_nil(Errors.parse("   "))
		end)
	end)

	describe("pretty", function()
		it("reduces the rate limit wall to one sentence", function()
			assert.are.equal(
				"rate limit (429): This request would exceed your account's rate limit. Please try again later.",
				Errors.pretty(Errors.join(RATE_LIMIT)[1])
			)
		end)

		it("names the kind when there is no status", function()
			assert.are.equal(
				"overloaded: Overloaded",
				Errors.pretty('{"error":{"type":"overloaded_error","message":"Overloaded"}}')
			)
		end)

		it("keeps the status alone when the body has no kind", function()
			assert.are.equal("500: something went wrong", Errors.pretty("Error: 500 something went wrong"))
		end)

		it("reduces a dead refresh token to the line that matters", function()
			assert.are.equal("invalid grant (400): Refresh token not found or invalid", Errors.pretty(OAUTH))
		end)

		it("hands back what it does not understand", function()
			assert.are.equal("stack traceback: ...", Errors.pretty("stack traceback: ..."))
		end)
	end)

	describe("is_fatal", function()
		it("calls a rate limit hopeless, retry or not", function()
			assert.is_true(Errors.is_fatal(Errors.join(RATE_LIMIT)[1]))
			assert.is_true(Errors.is_fatal('{"error":{"type":"rate_limit_error","message":"slow down"}}'))
			assert.is_true(Errors.is_fatal("Error: 429 too many requests"))
		end)

		it("calls the other refusals hopeless too", function()
			assert.is_true(Errors.is_fatal('{"error":{"type":"authentication_error","message":"bad key"}}'))
			assert.is_true(Errors.is_fatal("Error: 401 unauthorized"))
			assert.is_true(Errors.is_fatal(OAUTH))
		end)

		it("leaves a transient failure to pi's own retry", function()
			assert.is_false(Errors.is_fatal('{"error":{"type":"overloaded_error","message":"Overloaded"}}'))
			assert.is_false(Errors.is_fatal("Error: 500 internal"))
			assert.is_false(Errors.is_fatal("listening on /tmp/pi.sock"))
		end)
	end)

	describe("is_error", function()
		it("knows a failure from noise", function()
			assert.is_true(Errors.is_error(RATE_LIMIT[1]))
			assert.is_true(Errors.is_error('{"type":"error","error":{"message":"nope"}}'))
			assert.is_true(Errors.is_error("Error: boom"))

			assert.is_false(Errors.is_error("listening on /tmp/pi.sock"))
			assert.is_false(Errors.is_error(""))
		end)
	end)
end)
