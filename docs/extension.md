# Neovim ↔ pi extension

How the editor state of the neovim instance that started crust reaches the pi
process it spawned, and how pi asks for more on demand.

No MCP server is involved. Crust ships a **pi extension**
(`extensions/nvim.ts`) that is a generic bridge: at startup it asks neovim for
a json **tool manifest** and registers whatever is in it. The transport back
into neovim is neovim's own RPC socket, driven by
`nvim --server <socket> --remote-expr`.

Adding, removing or changing a tool is a **lua-only** change in
`lua/crust/integrations/extension/tools.lua`. `extensions/nvim.ts` never has
to be touched.

## Pieces

| File | Role |
| --- | --- |
| `lua/crust/integrations/extension/tools.lua` | The tool registry: name, description, json-schema parameters and handler of every tool |
| `lua/crust/integrations/extension/init.lua` | Owns the nvim socket, the `-e` CLI args, the env, and re-exports `tools()` / `call()` |
| `extensions/nvim.ts` | Runs inside pi: fetches the manifest, registers each tool, injects the context-flagged ones each turn |
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
5. While loading, the extension makes one **blocking** `nvim --remote-expr`
   call (`execFileSync`) for
   `require('crust.integrations.extension').tools()` and registers every entry
   of the manifest. Tools must exist before the first turn, so this one call
   cannot be async. If neovim does not answer, the extension registers nothing
   and pi runs normally.

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

## The tool manifest

`M.tools()` returns a json array of tool specs:

```json
[
  {
    "name": "nvim_context",
    "label": "Neovim Context",
    "description": "Current neovim state: cwd, listed buffers, …",
    "parameters": { "type": "object", "properties": {} },
    "promptSnippet": "Inspect the current neovim editor state",
    "promptGuidelines": ["Use nvim_context when the user says 'this file'…"],
    "context": true
  }
]
```

`parameters` is plain json schema, which is exactly what typebox emits at
runtime, so it is handed to `pi.registerTool` as is. `context: true` means the
result is also injected as hidden context before every turn.

Every call comes back as
`require('crust.integrations.extension').call('<name>', '<json args>')`, which
dispatches to the tool's `handler(args)` under `pcall`. A missing tool, bad
json or a raising handler returns `{"error": "…"}` instead of killing the turn.

### Adding a tool

Append to `TOOLS` in `lua/crust/integrations/extension/tools.lua`:

```lua
{
  name = "nvim_quickfix",
  label = "Neovim Quickfix",
  description = "The current quickfix list.",
  parameters = { type = "object", properties = vim.empty_dict() },
  handler = function()
    return vim.json.encode(vim.fn.getqflist())
  end,
}
```

Restart the chat (the manifest is read once per pi process) and the tool is
there.

## Per-turn context injection

The extension hooks `before_agent_start` and calls every tool flagged
`context = true` with no arguments:

```ts
return {
  message: {
    customType: "crust-nvim",
    content: `Current neovim state (crust.nvim):\n${sections.join("\n")}`,
    display: false,
  },
};
```

`display: false` keeps it out of the chat UI; the model still sees it. If the
`nvim` call fails or returns nothing, the hook returns `undefined` and the turn
proceeds without editor state.

`M.ctx()` returns JSON:

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

### Which window is "current"

Never a crust panel. While the user types a prompt the focused window is
`crust://input`, and reporting that says nothing about what they are working
on. `M.win()` resolves, in order:

1. the focused window, when it is not a panel and not a float,
2. the last non-panel window, remembered by a `WinEnter`/`BufWinEnter`
   autocmd registered in `Context.setup()`,
3. the first ordinary window in the window list.

A window counts as a panel when its filetype is `crust_input`,
`crust_output` or `crust_status`, or its name starts with `crust://`. The same
test filters the buffer list. When only panels are open, `current` and
`cursor` are omitted from the json rather than pointing at the chat.

## Shipped tools

### `nvim_context`

No parameters, `context = true`. Calls `Context.ctx()` and returns the same
JSON on demand — used when the user says "this file" or "here" mid-turn and
the per-turn snapshot is stale.

### `nvim_diagnostics`

Optional `path`. Calls `M.diagnostics(path)`:

- with a path: resolved with `expand()` + `:p`, looked up via `bufnr()`; an
  unknown file yields `{"diagnostics":[]}` rather than an error,
- without: `vim.diagnostic.get(nil)` — **every loaded buffer**, which is close
  to workspace-wide but not a full project scan.

Each item is `{ path, line (1-based), col (1-based), severity, source, message }`.

## Quoting and failure modes

- Lua is embedded as `luaeval("<lua>")` with `\` and `"` escaped on the TS
  side; the json argument string is wrapped in single quotes with `\`, `'` and
  newlines escaped.
- `remote()` returns `null` on a non-zero exit or empty stdout. The context
  hook silently skips; the tools throw `neovim did not answer on <socket>`.
- A failing manifest fetch at startup means **no tools at all** for that pi
  process — check that neovim is still listening on the socket.
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
- `:lua print(require("crust.integrations.extension").ctx())` — the exact
  payload the model receives.
- `:lua print(require("crust.integrations.extension").tools())` — the manifest
  pi registers.
- `:lua print(require("crust.integrations.extension").call("nvim_diagnostics", "{}"))`
  — a tool call exactly as pi makes it.
- Reproduce the extension's call by hand:

  ```bash
  nvim --server "$CRUST_NVIM_SERVER" --remote-expr \
    'luaeval("require(\"crust.integrations.extension\").ctx()")'
  ```

- Enable `log.enabled` to get the rpc transcript in
  `stdpath("state")/crust/crust-<session>.log`; the injected context appears
  there as part of the prompt payload.
