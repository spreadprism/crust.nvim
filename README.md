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
