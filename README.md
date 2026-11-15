# straps-divergent

Fork a [straps.nvim](https://github.com/ducharmemp/straps) session. A fork is a new session whose transcript is a verbatim copy of the source transcript, followed by one new instruction. In strict mode, the fork runs in parallel with the source. The agent gets a `fork` tool; you get `:StrapsFork`. Contextual mode has the restrictions below.

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

`require("straps-divergent").setup()` must run after `require("straps").setup()`. `setup()` takes no options and warns when given a non-empty table. It errors when straps is not set up, because its prompt section registers after the straps layers and keeps the prompt cache prefix stable.

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

## Contextual authorization

With experimental contextual authorization enabled, generic human `:StrapsFork` and `fn.fork` invocations refuse because they lack a trusted exact-call context. An admitted agent `fork` without delegation copies the conversation into an inactive child; a human must adopt its task with `:StrapsAdopt` before starting it. Explicit fork task delegation is rejected because the copied prompt has no valid private construction receipt. Copied conversation, permission grants, and archive access confer no task authority. Independent readonly/allow ceilings and other guards still apply.

The execution descriptions below apply to strict mode. Contextual mode retains the copy semantics subject to these restrictions.

## The `fork` tool

The agent calls `fork{ task = "..." }`. The tool:

1. Copies the session transcript up to the current point (or up to block `upto`) into a new session buffer.
2. Appends a `# You are a fork` section to the copied system block, naming the source buffer and the cut point.
3. Pairs the trailing run of tool calls that have no result yet (the fork call itself and any call issued after it in the same turn): the fork call gets a success result; every other one gets an error result marked "not run in this fork". With `upto` set, the fork call is claimed only when every block past the cut is a tool block of the same batch; a cut inside an earlier turn claims nothing.
4. Appends `task` as the fork's instruction and starts its run.

The fork is a subagent of the source: `spawn_wait{ buffers = { N } }` collects its final reply, a `[straps]` notice arrives when it finishes, `:StrapsStop` on the source stops it, and it counts against `config.max_spawn_depth` (the tool stays listed at the limit and refuses there). Without `allow` or `readonly`, it copies the source's permission grants wholesale (including `:StrapsAuto` grants, which `spawn` does not pass on). With `readonly = true` or `allow = { ... }`, it gets only those grants, with `spawn`'s meaning: granted calls run without a prompt and read-only calls pass. Restricted forks may watch any session, including automatic wake, and remove only their own watch subscriptions without a grant. `send_message{to="parent"}` also passes without a grant. Every other call is denied. The two are mutually exclusive, and a gated source can grant only a subset of its own grants. It also copies the source's tool filter, provider, model and effort, and resolves the source's session-scoped registry entries. It loses `ask_user`, as every subagent does.

Parameters: `task` (required), `upto` (a block number as `transcript_excise` lists them, 2 or more), `show`, `max_turns` (default 24), `timeout_ms` (default 600000), `model`, `effort`, `readonly`, `allow`, `delegation` (contextual task subset; explicit fork delegation currently refuses). With `upto`, the fork call is claimed only when every block past the cut is a tool block of that call's batch; otherwise every unpaired call in the copy gets a "not run in this fork" result.

## `:StrapsFork`

```
:[vertical|tab] StrapsFork[!] [upto] [-- instruction]
```

Run it on an idle session buffer. It copies the transcript (up to block `upto`), appends the instruction, opens the fork in a split (`:vertical` for a vsplit, `:tab` for a tabpage) and starts its run. Without `!` and without `-- instruction`, it prompts for one. With `!`, the fork opens idle, so you can edit it before `<CR>`. On success it notifies `straps-divergent: forked into buffer N`.

A command fork is a peer: it has no parent, nothing notifies the source when it ends, `:StrapsStop` on the source leaves it running, `ask_user` stays available, and it keeps the source's turn cap. Grants, tool filter, scoped entries and model settings are copied as for the tool. The command refuses while the source has a run active; `:StrapsStop` it first.

## Context archives

Straps context management is opt-in and disabled by default. Forks without `[straps-context:<id>]` receipts keep the existing behavior and require no archive API.

When the copied transcript contains archive receipts, both child and peer forks call `require("straps.context_archive").inherit(source, child, upto)`. Core transfers trusted access only for authorized receipts through the copied block cutoff, including their summary descendants. Pasting a receipt ID grants no access. Restricted forks retain the same archive authorization checks and read-tool permission checks. Core persists inherited archive grants so recovery does not depend on keeping the source buffer open.

A receipt-bearing fork requires the compatible core archive API. Missing support or rejected inheritance refuses the fork with an error before it starts. An inheritance failure removes the newly created fork buffer and transcript; cleanup failures appear in the error.

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
STRAPS_ROOT=/path/to/straps busted tests/fork_spec.lua
```

`STRAPS_DIR` remains a compatibility fallback. `:checkhealth straps-divergent` reports setup and registration without forking.

Without `STRAPS_ROOT` or `STRAPS_DIR`, the specs look for a straps checkout at `../straps`. Run one busted process per spec; `nix flake check` does that against the straps input recorded in `flake.lock`.
