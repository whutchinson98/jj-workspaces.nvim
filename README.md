# jj-workspaces.nvim

Create, switch, and forget [jj](https://jj-vcs.dev/) workspaces from Neovim.
Inspired by [git-worktree.nvim](https://github.com/ThePrimeagen/git-worktree.nvim),
but built around workspace names and jj revisions—not Git branches.

- Async Lua API; optional Telescope workspace and revision pickers.
- Global, tab-local, or window-local cwd switching.
- Current-file continuity, unsaved-buffer guards, and configurable jump cleanup.
- Create/switch/forget hooks with explicit success, partial, and unknown outcomes.
- **Forget removes registration only. It never deletes your workspace files.**
- No automatic fetch, tracking, push, rebase, or stale-workspace repair.

## Requirements

- **Neovim 0.11+** and **jj 0.44+**, available on `PATH` or configured explicitly.
- No external Lua dependency for the core.
- Optional: `telescope.nvim` and its `plenary.nvim` dependency.

Tested on Linux with Neovim **0.11.0 and 0.12.5**, jj **0.44.0**. Other platforms
and future jj versions are not guaranteed; required CLI capabilities are checked.

## Install

For lazy.nvim:

```lua
{
  "whutchinson98/jj-workspaces.nvim",
  main = "jj-workspaces",
  opts = {},
}
```

Or install with your preferred plugin manager and call
`require("jj-workspaces").setup({})`. Setup is optional; defaults work without it.
No global keymaps or Ex commands are installed automatically.

## Quick start

Run these from a jj workspace (colocated or non-colocated):

```lua
local ws = require("jj-workspaces")

-- New child change on top of @, in a sibling directory, then switch into it.
ws.create({ name = "feature" })

-- Explicit directory and parent; do not switch the editor.
ws.create({ name = "review", path = "../review-dir", revision = "main", switch = false })

-- Existing workspace names, not paths or bookmarks.
ws.switch("feature")
ws.switch("default", { scope = "tab" })

-- Must not be active in this editor. Registration only: files remain.
ws.forget("review")
```

Operations are asynchronous. Submit dependent operations after completion rather
than issuing several mutations back-to-back (overlapping mutations return `busy`).

### Paths and revisions

- An explicit relative `path` is relative to the **source workspace root**, not
  Neovim's current subdirectory. Absolute paths are used as supplied.
- With no `path`, creation uses `<parent-of-source-root>/<name>`, or
  `<workspace_directory>/<name>` when configured. Complex names require a path.
- The destination must not exist, its parent must exist, and it must not be nested
  inside a jj workspace or repository metadata. No parent directories are created.
- `revision` defaults to `@` and must resolve to exactly one commit. It is the
  **parent of a new working-copy change**, not a command to edit that same change.
- Creation allows jj to snapshot source files on disk. Unsaved loaded source
  buffers block creation; the plugin never writes them automatically.
- No bookmark is created or moved to match the workspace name. Fetch/publish and
  conflict/stale-workspace recovery remain explicit user actions outside this API.

## Telescope (optional)

Install Telescope and Plenary normally, then load the extension:

```lua
require("telescope").load_extension("jj_workspaces")

vim.keymap.set("n", "<leader>jw", function()
  require("telescope").extensions.jj_workspaces.workspaces()
end, { desc = "jj workspaces" })

vim.keymap.set("n", "<leader>jc", function()
  require("telescope").extensions.jj_workspaces.create_workspace()
end, { desc = "Create jj workspace" })
```

Workspace picker: **Enter** switches; **Ctrl-D** confirms forgetting registration
while keeping files. There is no force toggle. Search uses name, path, and commit
ID; unavailable paths remain visible but cannot be entered.

Creation picker: **Enter** selects a parent, **Ctrl-R** uses the typed revision.
The special `@` entry snapshots at creation time; other candidates pin full commit
IDs. Then enter a workspace name and directory. Empty directory uses the core
default; canceling either prompt makes no changes.

Standard Telescope options and custom `attach_mappings` are supported. Additional
options: `cwd`, `scope`, `on_complete(result)`, `jj_command`, and
`revision_timeout_ms`. If you configure a custom core `jj_command`, also pass it
to `create_workspace({ jj_command = "/path/to/jj" })` for the revision query.
Each picker call returns a cancellation function; submitted mutations still finish.

A `vim.ui.select` provider that closes the workspace picker cancels its pending
forget confirmation. A late answer cannot mutate anything. The core Lua API
remains available if your UI provider does not preserve that picker.

## Configuration

```lua
require("jj-workspaces").setup({
  jj_command = "jj",                 -- executable name or absolute path, not shell text
  cwd_scope = "global",             -- "global", "tab", or "window"
  update_on_change = true,           -- only the invoking window's current file
  missing_file = "directory",        -- "directory", "keep", or function(context)
  clearjumps_on_change = true,       -- only the invoking window
  workspace_directory = nil,        -- existing absolute base for omitted create paths
  log_level = nil,                   -- default "warn"; see precedence below
  operation_timeout_ms = 30000,      -- per CLI invocation
  notify = true,
})
```

Repeated setup starts from fresh defaults. Invalid/unknown options are rejected
without replacing the previous configuration. Running requests retain their
captured settings. Old Git plugin options such as `autopush`, `force`, and
`change_directory_command` are not accepted.

Log level precedence: `JJ_WORKSPACES_LOG` environment variable → setup value →
`vim.g.jj_workspaces_log_level` → `warn`. Levels: `trace`, `debug`, `info`, `warn`,
`error`, `off` (`fatal` aliases `error`). Invalid strings fall back to `warn`.
Logs are lazy, bounded JSONL at `stdpath("cache")/jj-workspaces.log`, with one
rotation backup. Logs may contain private paths and CLI diagnostics; inspect them
before sharing. `notify=false` does not suppress callbacks or file logging.

## Results and hooks

Every core operation returns an operation ID immediately and invokes its optional
callback once, asynchronously on the main loop:

```lua
local ws = require("jj-workspaces")
ws.list(nil, function(result)
  if result.status == "success" then
    vim.print(result.data) -- array of { name, path?, commit_id, current? }
  else
    vim.notify(result.error.message, vim.log.levels.ERROR)
  end
end)

local unsubscribe = ws.on_change(function(event)
  -- kind: "create", "switch", "forget"
  -- workspace: { name, path?, commit_id }; repository; operation_id; warnings
  -- switch adds previous { name?, path } and scope
  -- create adds parent_revision
  vim.print(event.kind, event.workspace.name)
end)
-- unsubscribe() removes this listener only.
```

Results contain `id`, `operation`, `status`, `data`, `error`, and `warnings`.
Statuses: `success`, `noop`, `error`, `partial`, `unknown`. A created workspace
with a failed automatic switch is **partial**, not a failed creation to retry.
Interrupted jj mutations can leave partial state; inspect the returned data and jj
state before retrying. No automatic rollback, retry, or file cleanup is attempted.

`discover(opts, callback)` returns `{ repository, root, name?, workspaces }`.
Common `opts.cwd` is an absolute repository-context override; it does not change
editor cwd itself. Switching/forgetting take a workspace name as their first
argument. Use `nil` for omitted options before a callback.

Hooks precede completion. Listener failures are isolated as warnings. The mutation
lock remains held through hooks/completion; use `vim.schedule` for a follow-up
mutation. Read-only requests may overlap. If the invoking cwd/window/buffer changes
while an operation runs, late editor effects are refused instead of redirected.

See `:help jj-workspaces` for the complete API and safety behavior.

## Tests and development

```sh
make test                 # real core API + isolated capability probes
make test-telescope       # real Telescope, including core/jj end-to-end
make lint                 # StyLua 2.5.2
```

For optional dependencies, point `TELESCOPE_DIR` and `PLENARY_DIR` at checkouts:

```sh
TELESCOPE_DIR=/path/to/telescope.nvim \
PLENARY_DIR=/path/to/plenary.nvim make test-telescope
```

Override `NVIM` to test another Neovim binary. Fixtures own unique temporary
directories, configure no remotes, and never mutate this repository. There are
41 core integration tests and 29 Telescope tests (including real jj integration).
The older 17 CLI capability tests and 15 editor assertions remain as independent
checks. See `tests/core/TESTING.md` and `tests/telescope/README.md` for coverage.

CI covers Neovim 0.11.0 and 0.12.5 with jj 0.44.0 and pinned Telescope/Plenary.
The [design documents](docs/design/) record rationale and intended behavior;
their original design-stage status notes are historical, not the current product
status. Implementation commits and verification are recorded in
[Linear](https://linear.app/hutchery/project/jj-workspace-nvim-b13c0a2e9724).
