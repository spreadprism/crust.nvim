# How herdr knows a pane is running pi

herdr does not detect anything. Pi reports itself over a unix socket, and the
report carries the pane id herdr injected into that pane's environment.

Reference implementation: the herdr-managed pi extension at
`~/.pi/agent/extensions/herdr-agent-state.ts` (`HERDR_INTEGRATION_ID=pi`).

## Mechanism

1. herdr spawns each pane's shell with `HERDR_ENV=1`, `HERDR_SOCKET_PATH`, and
   `HERDR_PANE_ID`.
2. The extension's `enabled()` gate requires all three. If any is missing the
   extension is a no-op, so the same file is safe outside herdr.
3. On `session_start` (only when `ctx.hasUI === true`, i.e. the root session)
   it sends `pane.report_agent_session` with `pane_id`, `agent: "pi"`,
   `source: "herdr:pi"`, and a session ref (`agent_session_path`, falling back
   to `agent_session_id`).
4. State changes send `pane.report_agent` with `state` of `working`
   (`agent_start`), `idle` (`agent_settled` + `ctx.isIdle()`), or `blocked`
   (the `herdr:blocked` event, refcounted so nested blocks don't race).
5. On `session_shutdown` it sends `pane.release_agent` only when
   `reason === "quit"`. Pi rebinds extension runtimes on `/reload`, `/new`,
   `/resume`, and `/fork`; releasing there would suppress the replacement
   runtime's reports.

## Transport details worth copying

- Line-delimited JSON-RPC-ish requests over `net.createConnection(socketPath)`;
  on Windows the path becomes `\\.\pipe\<path>`.
- Each send is tried twice: 500 ms timeout, then 1500 ms. Delivery is confirmed
  by receiving any `data`; an `end` with no data counts as failure.
- State sends are serialized through a single-slot queue (`queuedState`), so
  rapid transitions collapse to the latest state instead of arriving out of
  order. A monotonic `seq` (`Date.now() * 1000`, incremented) lets the server
  discard stale reports.

## What crust does with this

`lua/crust/integrations/herdr.lua` is the same mechanism, from neovim:

```lua
require("crust").setup({
  herdr = {
    enabled = true,      -- only ever does anything inside a herdr pane
    agent = "crust",     -- name in the sidebar and in `herdr agent list`
    source = "crust.nvim",
  },
})
```

- `M.available()` gates on the config flag **and** on `HERDR_ENV=1` plus a
  non-empty `HERDR_PANE_ID` and `HERDR_BIN_PATH`. The environment is what
  decides in practice: outside herdr nothing is spawned, whatever the flag
  says. Set `enabled = false` to stay out of a herdr pane anyway.
- `setup()` checks the environment first: no pane, no augroup and no report.
  Inside one it claims the pane with an `idle` report and releases it on the
  first of `VimLeavePre` / `VimLeave`. `crust.stop()` releases too.
- The quit release runs **synchronously** (`release({ sync = true })`):
  neovim kills the children it still owns as it exits, so a fire-and-forget
  `release-agent` is killed before herdr hears it and the agent stays listed
  — one stale entry per editor session.
- The chat drives the state: `working` on `agent_start`, `idle` from
  `Chat:_settle()` (turn end, cancel, stderr failure, process exit).
- Reports go through the CLI (`"$HERDR_BIN_PATH" pane report-agent …`) with
  `vim.system`, a 1500 ms timeout and no error surfaced; the socket is left
  alone because the CLI is the portable path.
- A single-slot queue collapses a burst of transitions to the latest one, and
  `seq` is `max(seq + 1, os.time() * 1000)` so herdr discards stale reports.

Other long-running work can share the indicator without touching the chat:

```lua
local herdr = require("crust.integrations.herdr")
herdr.busy("review", true)   -- working while any key is busy
herdr.busy("review", false)  -- idle once none is
herdr.report("blocked", { message = "approve the edit" })
```

## Takeaway

"Window with pi open" means "a pane that reported an agent session on the
socket", keyed by `HERDR_PANE_ID`. No process scanning, no window-manager
queries, no title parsing.
