# crust.nvim

> [!WARNING]
> Early work in progress. API and commands may change.

Because [PI](https://pi.dev) needs a Crust

## Requirements

- Neovim >= 0.13
- `pi` on `$PATH` (configurable via `bin`)
- [snacks.nvim](https://github.com/folke/snacks.nvim) (optional, session picker with delete)
- [blink.cmp](https://github.com/Saghen/blink.cmp) (optional, popup completion in the chat input)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (tests only)

## Commands

| Command | Description |
| --- | --- |
| `:Crust chat` | Open the chat panel (default) |
| `:Crust toggle` | Toggle the chat panel |
| `:Crust new` | Start a new session in the current chat |
| `:Crust continue` | Open the chat on the most recent session of the cwd |
| `:Crust sessions` | Pick a past session: `<CR>` resumes, `<C-d>` deletes |
| `:Crust last` | Switch the chat to the most recent other session |
| `:Crust send` | Put a mention for the current buffer in the prompt, `:'<,'>Crust send` for a range |
| `:Crust rename [name]` | Rename the live session, prompts without a name |
| `:Crust transcript` | Open the full conversation in a scratch buffer |
| `:Crust stop` | Close the panel and stop the pi process |

## Sending context

`send` puts a mention for what you are looking at into the prompt — it does
not submit — and focuses the input:

```lua
vim.keymap.set({ "n", "x" }, "<leader>ca", function()
  require("crust").send()
end, { desc = "crust: send context" })
```

| Where | Normal mode | Visual mode |
| --- | --- | --- |
| file buffer | `@path` | `@path:first-last` |
| oil buffer | `@dir/` | one `@dir/name` per selected entry |

`smart` is the one-key version: it opens the panel when it is away, and sends
context once it is up. From inside the chat it just focuses the prompt.

```lua
vim.keymap.set({ "n", "x" }, "<leader>cc", function()
  require("crust").smart()
end, { desc = "crust: open or send context" })
```

The text is the ordinary `@mention` syntax, so the file expander sends the
content (or just those lines) to the model while the prompt stays short.
Mentions are appended, so several calls collect several files. Pass
`{ visual = true }` when the mapping already left visual mode (`:<C-u>lua …`),
and `{ buf = n }` to describe another buffer.

## Sessions

```lua
require("crust").open({ continue = true }) -- resume the last session
require("crust").toggle({ session = path }) -- resume a specific file
require("crust").continue()
require("crust").new_session() -- fresh session, same windows
require("crust").sessions() -- picker
require("crust").session_last() -- switch to the previous session, no picker
require("crust").rename_session("bug hunt")
require("crust.sessions").list() -- Crust.Session[], newest first
```

## Models

```lua
require("crust").model() -- picker over pi's configured models
require("crust").model("anthropic/claude-haiku-4-5") -- switch, no picker
require("crust").model("haiku") -- any unambiguous id, name or fragment
```

The list is `get_available_models` from the running instance, so it is
whatever that pi is configured with. A query is matched against the
`provider/id` form of pi's `--model` flag first, then the bare id, then the
display name, then any unambiguous part of those; an ambiguous one reports
its candidates instead of guessing. Without a query it opens the picker —
snacks.nvim when installed, `vim.ui.select` otherwise — with the live model
marked. The prompt bar picks the new model up from the following
`get_state`.

```lua
vim.keymap.set("n", "<leader>cm", function()
  require("crust").model()
end, { desc = "crust: switch model" })
```

The history is parsed once at startup, in the background, and the session
directory is watched from then on, so opening the chat or the picker never
waits on disk. A lookup still re-globs the directory and reparses only the
files whose mtime moved, so the cache cannot go stale.

## Preload

`setup` warms up on `vim.schedule`, after startup: the session history is
parsed and watched, and the chat buffers are built — treesitter, keymaps and
completion included. Opening the panel is then two window splits.

```lua
require("crust").setup({
  preload = {
    sessions = true,
    chat = true,
    pi = false, -- also start the pi process, before anything is typed
  },
})
```

## Completion

The chat input completes `@path` mentions against the project files and
`/commands` against pi's command list. `<C-x><C-u>` works out of the box;
with blink.cmp, register the shipped source:

```lua
require("blink.cmp").setup({
  sources = {
    per_filetype = {
      crust_input = { "crust" },
    },
    providers = {
      crust = { name = "Crust", module = "crust.completion.blink" },
    },
  },
})
```

## Prompt bar

The last row of the prompt window carries a bar: what the session has cost so
far on the left, the model answering on the right.

```
 $0.284                                            󰚩 claude-opus-4-6
```

It is drawn as virtual lines on the input buffer, so it costs no window and no
'laststatus'. Everything in it uses `CrustInputBar` (blue, the mention colour),
with `CrustInputBarWarning` and `CrustInputBarError` for components that pass
their thresholds.

The two sides are lists of component names, literal separators or your own
functions. A component that returns `nil` hides itself and the separators
around it.

```lua
require("crust").setup({
  input_bar = {
    enabled = true,
    layout = {
      left = { "cost", " · ", "context" },
      right = { "model", " · ", "thinking" },
    },
    components = {
      cost = { icon = "\u{f155}", warn = 5, error = 10 }, -- dollars
      context = { icon = "\u{f0e4}", warn = 70, error = 90 }, -- percent full
      model = { icon = "󰚩" },
    },
  },
})
```

A component table you pass owns its icon: whatever it says is the icon, and
saying nothing means none — `cost = { icon = nil }` (or `false`, or `""`)
draws the cost bare, while its `warn`/`error` levels keep their defaults.
Components you do not mention keep theirs.

Built-ins: `cost` (`$0.284`), `model`, `context` (`63.9%/200k`), `tokens`
(`↑3.8k ↓58k`), `cache` (`R7.2M W416k`) and `thinking` (`xhigh`). A custom
component is a function of the bar state:

```lua
left = {
  function(state)
    return state.cost > 1 and ("spent $%.2f"):format(state.cost) or nil
  end,
},
```

Cost and tokens accumulate over the session and reset with it; the model and
thinking level come from pi's `get_state`.

## Tool calls

A tool call in the scrollback is one line: the command cut to the panel width
and, under it, the tail of the output. Press `K` over a call to open the whole
thing in a floating window — the full command, highlighted with the tool's
language, and the full output with its terminal colours. `q`, `<Esc>` or
leaving the float closes it.

File writes show their diff there instead of the "wrote …" line. Tool specs
decide what the float holds with `preview_title` and `preview_body`.

```lua
require("crust").setup({
  keymaps = {
    preview = "K", -- false leaves `K` alone in the output panel
  },
})
```

## Expansion

A prompt is rewritten on its way to pi. `@justfile` is sent as the mention
plus the file's current content in a fenced block — from the buffer when the
file is open, so unsaved edits count. The chat output still shows what you
typed, one blue `CrustMention`.

The mention sits above the fence, so it is the path — the fence carries only
the filetype, plus the resolved `lines=` when a range was asked for:

```
@lua/crust/init.lua:40      one line
@lua/crust/init.lua:40-80   a range, clamped to the file
@lua/crust/init.lua:40-     from there to the end
```

Add your own with two functions, `trigger` (which spans do I claim) and
`expansion` (what replaces this span, nil to leave it):

```lua
require("crust.expansion").register({
  name = "diff",
  trigger = function(text)
    local first, last = text:find("@diff", 1, true)
    return first and { { first = first, last = last, text = "@diff" } } or {}
  end,
  expansion = function()
    return "```diff\n" .. vim.fn.system("git diff") .. "\n```"
  end,
})
```

Turn the whole thing off with `expansion = { enabled = false }`.

```lua
require("crust").setup({
  keymaps = {
    cancel = "<C-c>",
    sessions = "<leader>s",
    preview = "K", -- expand the tool call under the cursor
  },
  sessions = {
    agent_dir = nil, -- defaults to $PI_CODING_AGENT_DIR or ~/.pi/agent
  },
  window = {
    input_min_height = 5, -- the prompt never gets shorter, `<C-w>+` makes it taller
    auto_insert = false,  -- true starts insert mode whenever the prompt takes focus
  },
})
```
