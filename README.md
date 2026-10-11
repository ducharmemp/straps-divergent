# straps-divergent

Fork a [straps.nvim](https://github.com/ducharmemp/straps) session. A fork is a new session whose transcript is a verbatim copy of the source transcript, followed by one new instruction. The fork runs in parallel with the source. The agent gets a `fork` tool; you get `:StrapsFork`.

`spawn` starts a child with an empty context. `fork` starts a child that already holds everything this conversation holds: the files read, the findings, the decisions. Use it when the task needs that context and restating it would take more text than the task itself. Each request the fork makes resends the copied transcript as input tokens.

## Requirements

- straps.nvim, set up before this plugin.
- The straps requirements: Neovim >= 0.11, `curl`, an API key.

## Install

With lazy.nvim:

```lua
{
  "ducharmemp/straps-divergent",
  dependencies = { "ducharmemp/straps" },
  config = function()
    require("straps").setup()
    require("straps-divergent").setup()
  end,
}
```

`require("straps-divergent").setup()` must run after `require("straps").setup()`. It errors otherwise, because its prompt section registers after the straps layers and keeps the prompt cache prefix stable.

With Nix, the flake exports `packages.<system>.default`, an overlay that adds `vimPlugins.straps-divergent`, and a nixvim module; it takes straps as a flake input. Import the module next to the straps module:

```nix
imports = [
  straps.nixvimModules.default
  straps-divergent.nixvimModules.default
];
plugins.straps.enable = true;
plugins.straps-divergent.enable = true;
```

The module emits its `setup()` call with `lib.mkAfter`, so it runs after straps' `setup()`.

## The `fork` tool

The agent calls `fork{ task = "..." }`. The tool:

1. Copies the session transcript up to the current point (or up to block `upto`) into a new session buffer.
2. Appends a `# You are a fork` section to the copied system block, naming the source buffer and the cut point.
3. Pairs the trailing run of tool calls that have no result yet (the fork call itself and any call issued after it in the same turn): the fork call gets a success result; every other one gets an error result marked "not run in this fork". With `upto` set, the fork call is claimed only when every block past the cut is a tool block of the same batch; a cut inside an earlier turn claims nothing.
4. Appends `task` as the fork's instruction and starts its run.

The fork is a subagent of the source: `spawn_wait{ buffers = { N } }` collects its final reply, a `[straps]` notice arrives when it finishes, `:StrapsStop` on the source stops it, and it counts against `config.max_spawn_depth` (the tool stays listed at the limit and refuses there). It copies the source's permission grants wholesale (including `:StrapsAuto` grants, which `spawn` does not pass on), its tool filter, provider, model and effort, and resolves the source's session-scoped registry entries. It loses `ask_user`, as every subagent does.

Parameters: `task` (required), `upto` (a block number as `transcript_excise` lists them, 2 or more), `show`, `max_turns` (default 24), `timeout_ms` (default 600000), `model`, `effort`.

## `:StrapsFork`

```
:[vertical] StrapsFork[!] [upto] [-- instruction]
```

Run it on an idle session buffer. It copies the transcript (up to block `upto`), appends the instruction, opens the fork in a split (`:vertical` for a vsplit, `:tab` for a tabpage) and starts its run. Without `!` and without `-- instruction`, it prompts for one. With `!`, the fork opens idle, so you can edit it before `<CR>`.

A command fork is a peer: it has no parent, nothing notifies the source when it ends, `:StrapsStop` on the source leaves it running, `ask_user` stays available, and it keeps the source's turn cap. Grants, tool filter, scoped entries and model settings are copied as for the tool. The command refuses while the source has a run active; `:StrapsStop` it first.

## Registry entries

| Entry | Purpose |
| --- | --- |
| `fn.fork(source, opts)` | The copy mechanism both the tool and the command call. Returns the fork's buffer number. |
| `fn.fork_section(source, child, upto, opts)` | The `# You are a fork` text. Redefine it to change the wording. |
| `tool.fork` | The agent-facing tool (capability `spawn`, so the `spawn` grant covers it). |
| `fn.system_prompt_layer.divergent` | The `# Forking` section of the system prompt. |

Every entry is registered with `define_default`, so a redefinition survives a second `setup()`.

## Tests

```sh
STRAPS_DIR=/path/to/straps busted tests/fork_spec.lua
```

Without `STRAPS_DIR`, the specs look for a straps checkout at `../straps`. Run one busted process per spec; `nix flake check` does that against the straps input recorded in `flake.lock`.
