set quiet := true

[private]
default:
  just --list --unsorted

test:
  nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

