# Neovim ↔ pi extension

How the editor state of the neovim instance that started crust reaches the pi
process it spawned, and how pi asks for more on demand.

No MCP server is involved. Crust ships a **pi extension**
(`extensions/nvim.ts`) that registers two tools and one context hook. The
transport back into neovim is neovim's own RPC socket, driven by
`nvim --server <socket> --remote-expr`.

## Pieces

| File | Role |
| --- | --- |
| `lua/crust/integrations/extension.lua` | Owns the nvim socket, the `-e` CLI args, the env, and the lua functions the extension calls |
| `extensions/nvim.ts` | Runs inside pi: injects state each turn, registers `nvim_context` and `nvim_diagnostics` |
| `lua/crust/pi/client.lua` | Spawns pi with those args and that env |
| `lua/crust/config.lua` | `config.extension` — `enabled`, `path`, `server` |

## Wiring at startup

1. `require("crust").setup()` calls `extension.setup()`
   (`lua/crust/init.lua:47`), which resolves the socket early so it exists
   before the first chat.
2. `M.server()` picks, in order:
   - `config.extension.server` when set to a non-empty string,
   - a socket already created in this session,
   - `v:servername` when nvim was started with `--listen` or already has one,
   - otherwise `vim.fn.serverstart()`.
   A stale pipe (the file no longer exists) is discarded and a new server is
   started.
3. `Pi:_command()` appends `Extension.args()` → `{ "-e", <extension path> }`,
   and `Pi:_env()` supplies `Extension.env()` →
   `{ CRUST_NVIM_SERVER = <socket> }`. Both are empty tables when
   `config.extension.enabled` is false or the extension file is unreadable, so
   pi starts normally without the integration.
4. `vim.fn.jobstart` launches `pi -e <ext> --mode rpc` with that env.

```
neovim (crust)                         pi process
  │                                      │
  │ jobstart: pi -e extensions/nvim.ts   │
  │ env CRUST_NVIM_SERVER=/run/…/nvim.sock
  ├─────────────────────────────────────►│  extension loads
  │                                      │
  │◄──── nvim --server $CRUST_NVIM_SERVER ──── pi.exec("nvim", …)
  │      --remote-expr luaeval("…")      │
  │  lua runs in *this* nvim, prints json│
  └─────────────────────────────────────►│  stdout → tool result / context
```

Note the two directions use different channels: crust → pi is the **rpc stdio
pipe** of the job, pi → neovim is a **separate short-lived `nvim` CLI process**
per request (5s timeout, `pi.exec`).

## Per-turn context injection

The extension hooks `before_agent_start`:

```ts
const snapshot = await remote("require('crust.integrations.extension').snapshot()", ctx.signal);
return {
  message: {
    customType: "crust-nvim",
    content: `Current neovim state (crust.nvim):\n\`\`\`json\n${snapshot}\n\`\`\``,
    display: false,
  },
};
```

`display: false` keeps it out of the chat UI; the model still sees it. If the
`nvim` call fails or returns nothing, the hook returns `undefined` and the turn
proceeds without editor state.

`M.snapshot()` returns JSON:

```json
{
  "cwd": "/home/avalon/workspace/crust.nvim",
  "current": { "buf": 7, "path": "lua/crust/log.lua", "filetype": "lua", "modified": false, "lines": 121 },
  "cursor": { "line": 14, "col": 1 },
  "buffers": [ { "buf": 1, "path": "…", "filetype": "…", "modified": false, "lines": 42 } ]
}
```

Only loaded **and** `buflisted` buffers are listed. Paths are `:~:.`
(relative to cwd, `~` for home). `col` is converted to 1-based.

## Tools

### `nvim_context`

No parameters. Calls `snapshot()` and returns the same JSON on demand — used
when the user says "this file" or "here" mid-turn and the per-turn snapshot is
stale.

### `nvim_diagnostics`

Optional `path`. Calls `M.diagnostics(path)`:

- with a path: resolved with `expand()` + `:p`, looked up via `bufnr()`; an
  unknown file yields `{"diagnostics":[]}` rather than an error,
- without: `vim.diagnostic.get(nil)` — **every loaded buffer**, which is close
  to workspace-wide but not a full project scan.

Each item is `{ path, line (1-based), col (1-based), severity, source, message }`.

## Quoting and failure modes

- Lua is embedded as `luaeval("<lua>")` with `"` escaped in the TS side; the
  `path` argument is wrapped in single quotes with `'` doubled.
- `remote()` returns `null` on a non-zero exit or empty stdout. The context
  hook silently skips; the tools throw `neovim did not answer on <socket>`.
- Each call has a 5s timeout and honours the turn's `AbortSignal`.
- Because the extension shells out to `nvim`, the `nvim` binary must be on pi's
  `PATH`.

## Configuration

```lua
require("crust").setup({
  extension = {
    enabled = true,          -- boolean or fun(): boolean, default false
    path = nil,              -- path to a replacement pi extension
    server = nil,            -- reuse a specific nvim socket
  },
})
```

Disabled by default. `enabled` may be a function, so it can be turned on only
in trusted projects.

## Debugging

- `:echo v:servername` — the socket the extension will be pointed at.
- `:lua print(require("crust.integrations.extension").server())` — what crust
  actually resolved.
- `:lua print(require("crust.integrations.extension").snapshot())` — the exact
  payload the model receives.
- Reproduce the extension's call by hand:

  ```bash
  nvim --server "$CRUST_NVIM_SERVER" --remote-expr \
    'luaeval("require(\"crust.integrations.extension\").snapshot()")'
  ```

- Enable `log.enabled` to get the rpc transcript in
  `stdpath("state")/crust/crust-<session>.log`; the injected context appears
  there as part of the prompt payload.
