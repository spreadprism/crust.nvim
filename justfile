set quiet := true

[private]
default:
  just --list --unsorted

# open nvim with only crust.nvim loaded (no user config)
minimal *args:
  nvim --clean -u tests/minimal.lua {{ args }}

# extensions: ":" separated pi extension paths loaded in the isolated test runs
test extensions=env("CRUST_TEST_PI_EXTENSIONS", ""):
  CRUST_TEST_PI_EXTENSIONS={{ quote(extensions) }} nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
