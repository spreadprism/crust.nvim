set quiet := true

[private]
default:
  just --list --unsorted

# open nvim with only crust.nvim loaded (no user config)
minimal *args:
  nvim --clean -u tests/minimal.lua {{ args }}

# run the specs: target is a file or a directory, extensions is a ":" separated list of pi extension paths
test target="tests/" extensions=env("CRUST_TEST_PI_EXTENSIONS", ""):
  #!/usr/bin/env bash
  set -euo pipefail
  target={{ quote(target) }}
  if [ -d "$target" ]; then
    cmd="PlenaryBustedDirectory $target {minimal_init = 'tests/minimal_init.lua'}"
  elif [ -f "$target" ]; then
    # not PlenaryBustedFile: it respawns nvim without -u and drags the user config in
    cmd="lua require('plenary.busted').run('$target')"
  else
    echo "no such file or directory: $target" >&2
    exit 1
  fi
  # VIMINIT would be sourced on top of the minimal init and drag the user config in
  CRUST_TEST_PI_EXTENSIONS={{ quote(extensions) }} env -u VIMINIT nvim --headless -u tests/minimal_init.lua -c "$cmd"
