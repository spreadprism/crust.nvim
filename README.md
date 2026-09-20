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
| `:Crust rename [name]` | Rename the live session, prompts without a name |
| `:Crust stop` | Close the panel and stop the pi process |

## Sessions

```lua
require("crust").open({ continue = true }) -- resume the last session
require("crust").toggle({ session = path }) -- resume a specific file
require("crust").continue()
require("crust").new_session() -- fresh session, same windows
require("crust").sessions() -- picker
require("crust").rename_session("bug hunt")
require("crust.sessions").list() -- Crust.Session[], newest first
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
  },
  sessions = {
    agent_dir = nil, -- defaults to $PI_CODING_AGENT_DIR or ~/.pi/agent
  },
})
```
