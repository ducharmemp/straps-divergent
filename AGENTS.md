# straps-divergent

This repo is a plugin for straps.nvim. It adds a `fork` tool and a `:StrapsFork` command; both copy a session transcript into a new session through `fn.fork` in `lua/straps-divergent/init.lua`. Every entry is a registry `define_default`, so the rules in straps' own AGENTS.md apply: an edit to this file on disk does not change a running session, and `registry_define` in a session does not change this file.

## Conventions

- Do not vendor straps. Tests locate it through `$STRAPS_DIR` or `../straps`.
- Call `require("straps-divergent").setup()` after `require("straps").setup()`. `register()` enforces that order.
- Keep `README.md` and `doc/straps-divergent.txt` consistent with behavior changes.
- Version control is jujutsu (`jj`). Create no commits unless asked.

## Tests

Each `tests/*_spec.lua` is a self-contained busted spec run by `nlua` inside a headless Neovim. Run one busted process per spec:

```sh
STRAPS_DIR=/path/to/straps busted tests/fork_spec.lua
STRAPS_DIR=/path/to/straps busted tests/setup_order_spec.lua
```

`nix flake check` runs every spec against the straps input recorded in `flake.lock`.
