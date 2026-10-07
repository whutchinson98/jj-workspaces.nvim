# HUT-109: Lua API, setup, and dependencies

Status: **Accepted design**, not an implemented plugin API.
Tracking: [HUT-109](https://linear.app/hutchery/issue/HUT-109).
Depends on HUT-94. Decisions below use the delegated instruction to continue
without pausing for every issue.

## Decision: adapt, without Git compatibility shims

Use `require("jj-workspaces")` and Telescope extension `jj_workspaces`, matching
the GitHub repository's plural name. No `git-worktree` module aliases, branch-name
arguments disguised as workspace names, plugin-defined Ex commands, or global
keymaps in the initial release. Users can bind Lua calls themselves.

Target Neovim **0.11+** and jj **0.44+** with the required workspace/root/JSON
template capabilities. Core dependencies: only Neovim and the `jj` executable.
Use `vim.system`, `vim.uv`, and `vim.json`; do not require Plenary for core jobs,
paths, or logging. Telescope is loaded lazily by its extension only; its own
transitive dependencies remain the user's package-manager responsibility.

This is a support target, not a claim that every version is tested. Current CLI
probes pass on jj 0.44.0; local Neovim is 0.12.5. Before a release, CI must cover
the minimum Neovim version, the supported jj range, and the chosen Telescope
version. Initial platform validation is Linux; other platforms are unverified.
Fail clearly on missing/incompatible executables or capabilities. Never fall back
to Git or human-output parsing.

## Public surface

```lua
local ws = require("jj-workspaces")
ws.setup(config)                            -- optional
ws.discover(opts, callback)                 -- context + inventory
ws.list(opts, callback)                     -- inventory only
ws.create({ name = "feature", path = "../feature", revision = "@" }, callback)
ws.switch("feature", opts, callback)       -- exact workspace name
ws.forget("feature", opts, callback)       -- metadata only, not file deletion
local unsubscribe = ws.on_change(function(event) end)
```

All operations use one options table and one optional completion callback;
`switch` and `forget` additionally take the exact name as their first argument.
If the options table is omitted, callers pass `nil` before a callback. There is
no positional branch/upstream compatibility signature. Completion/result shapes
are specified in HUT-107; lifecycle events in HUT-106. Public operations return an
operation ID immediately, not a synchronous result or promise.

Common options allow `cwd` as an absolute context override. Without it, capture
the invoking window's effective cwd (HUT-94). An override selects the repository
context but does not silently change editor cwd. Editor effects still target the
captured invoking window and must pass the context-stability checks in HUT-99.
No callbacks are invoked inline, including validation failures.

Do not expose mutable global root setters, raw job handles, or the upstream
`set_status` stub. No global `reset()` that ambiguously resets state: listeners
have an explicit unsubscribe closure. Module loading does not inspect a repo,
spawn jobs, write logs, require Telescope, or alter editor state.

## Setup contract

`setup(nil)` is equivalent to `setup({})`. Construct fresh defaults, validate the
whole supplied table, then atomically replace configuration. Unspecified values
return to defaults on repeated setup; rejected configuration leaves the previous
configuration intact. Deep-copy inputs; operation requests capture an immutable
configuration snapshot. Reconfiguration does not cancel running jobs, remove
listeners, install keymaps, or change existing cwd/buffers.

Reject unknown keys and wrong types rather than silently ignoring misspellings
or old Git-specific options. The initial keys reserved for subsequent designs:

| Key | Initial default / contract |
| --- | --- |
| `jj_command` | `"jj"`; a nonempty executable name or absolute path, not shell text |
| `cwd_scope` | `"global"`; only `global`, `tab`, `window` |
| `update_on_change` | `true`; current-file continuity |
| `missing_file` | `"directory"`; also `"keep"` or a Lua callback |
| `clearjumps_on_change` | `true` |
| `workspace_directory` | `nil`; optional absolute base for default creation destinations |
| `log_level` | `nil`; resolved by the logging precedence in HUT-108 |
| `operation_timeout_ms` | `30000`; positive finite integer |
| `notify` | `true`; built-in user notifications, not completion callbacks |

Feature details and per-operation overrides are specified by their later tasks.
There is no arbitrary `change_directory_command`, Ex fallback string, `autopush`,
implicit remote, automatic rebase, deletion force, or recursive-delete option.
UI confirmation policy is defined in HUT-105; core `forget` is an explicit call.
Do not implement a general plugin configuration language or dynamic root setter.

## Acceptance scenarios

- Requiring core outside a repository, with no jj or Telescope installed, has no
  side effects; the first relevant operation reports a useful capability error.
- Defaults work without setup; repeated setup resets unspecified values and does
  not mutate caller tables, running-operation settings, or registered listeners.
- Invalid/unknown options are rejected atomically; executable paths with spaces
  are one argv element, never interpreted as shell commands.
- Every operation invokes its completion callback once on the main loop,
  including invalid input, missing binaries, and repository errors.
- Core works without Telescope/Plenary; loading the optional extension provides
  an actionable error when its dependencies are missing.
- Minimum-version CI verifies APIs; future jj capability changes fail explicitly.
- Public docs and examples use workspace names, independent paths/revisions, and
  the same result/configuration schema across every frontend.

## Evidence and scope

The upstream setup rebuilt defaults and exposed Lua operations, with Plenary as a
hard dependency and Telescope optional. We retain the Lua-first shape, not its
undocumented state-mutating helpers. HUT-94's checked-in probes validate the jj
capabilities this design requires. No production Lua implementation is included
in this task; Neovim/Telescope compatibility is a release acceptance requirement.
