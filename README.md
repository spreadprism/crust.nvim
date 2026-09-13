# crust.nvim

nvim integration of [PI](https://pi.dev)

> [!WARNING]
> Early work in progress. API and commands may change.

## Requirements

- Neovim >= 0.13
- `pi` on `$PATH` (configurable via `bin`)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (tests only)

## Installation

<!-- lazy.nvim / packer / rocks snippet -->

## Usage

<!-- open the chat, type a prompt, <CR> to submit -->

### Commands

| Command | Description |
| --- | --- |
| `:Crust chat` | Open the chat panel (default) |
| `:Crust toggle` | Toggle the chat panel |
| `:Crust stop` | Close the panel and stop the pi process |

### Lua API

<!-- require("crust").open() / .toggle() / .stop() / .chat() -->

## Configuration

<!-- setup() defaults: { bin = "pi" } -->

## How it works

<!-- pi client (lua/crust/pi/client.lua) spawns pi, rpc.lua builds commands,
     events stream into the chat output buffer -->

## Development

<!-- just minimal   -> nvim --clean with only crust.nvim loaded
     just test      -> headless plenary busted run over tests/
     CRUST_TEST_PI_EXTENSIONS -> ":"-separated pi extensions for test runs -->

## Roadmap

<!-- known gaps / planned features -->

## License

<!-- TBD -->
