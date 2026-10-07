# jj-workspaces.nvim

Create, switch, and forget [jj](https://jj-vcs.dev/) workspaces from Neovim, with
an asynchronous Lua API and optional Telescope pickers.

**Forgetting a workspace removes its registration, not its files.** The plugin
does not automatically fetch, push, rebase, or repair stale workspaces.

## Requirements

- Neovim **0.11+**
- jj **0.44+**, on `PATH` or configured with `jj_command`
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) and
  [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)

The core has no external Lua dependencies. Both colocated and non-colocated jj
repositories are supported. Linux is tested; other platforms are unverified.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim), including Telescope keybindings:

```lua
{
  "whutchinson98/jj-workspaces.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("jj-workspaces").setup({})
    require("telescope").load_extension("jj_workspaces")
  end,
  keys = {
    {
      "<leader>wc",
      function() require("telescope").extensions.jj_workspaces.create_workspace() end,
      desc = "Create jj workspace",
    },
    {
      "<leader>wv",
      function() require("telescope").extensions.jj_workspaces.workspaces() end,
      desc = "View jj workspaces",
    },
  },
}
```

For the Lua API without Telescope:

```lua
{
  "whutchinson98/jj-workspaces.nvim",
  main = "jj-workspaces",
  opts = {},
}
```

Other plugin managers can install the repository normally. Calling
`require("jj-workspaces").setup({})` is optional; defaults work without it.
No keymaps or Ex commands are installed unless you configure them.

## Telescope

Run the pickers from an editing window inside a jj workspace:

```lua
require("telescope").extensions.jj_workspaces.workspaces()
require("telescope").extensions.jj_workspaces.create_workspace()
```

### View and switch

The workspace picker searches workspace names, paths, and commit IDs.

- **Enter** switches to the selected workspace.
- **Ctrl-D** asks to forget its registration, keeping all files.
- Unavailable paths remain visible but cannot be switched to.

### Create

Choose a parent revision, then enter a workspace name and directory.

- **Enter** selects a candidate, or uses typed text when no candidate is selected.
- **Ctrl-R** uses the typed revision expression even when a candidate is selected.
- The **Current workspace (@)** entry snapshots disk changes at creation time.
  Other candidates pin the selected commit ID.
- Empty directory input uses the default destination; canceling a prompt makes
  no changes before submission.

Picker calls accept standard Telescope options and `cwd`, `scope`,
`on_complete(result)`, `jj_command`, and `revision_timeout_ms`. If the core uses a
custom `jj_command`, pass it to `create_workspace()` too for its revision query.

Each call returns a cancellation function. Canceling after a mutation is submitted
does not undo it. A `vim.ui.select` provider that closes the workspace picker
cancels its pending forget confirmation; use the Lua API if your provider does
not preserve that picker.

## Lua API

```lua
local ws = require("jj-workspaces")
```

### Create a workspace

```lua
-- Create a sibling directory named "feature", then switch into it.
ws.create({ name = "feature" })
```

Or choose a directory and parent without switching:

```lua
ws.create({
  name = "review",
  path = "../review-dir",
  revision = "main", -- must resolve to one existing commit
  switch = false,
})
```

The name, directory, and parent revision are independent:

- An explicit relative `path` is relative to the **source workspace root**, not
  the editor's current subdirectory. Absolute paths are used as supplied.
- An omitted `path` uses a sibling directory named after the workspace, or
  `<workspace_directory>/<name>` when configured. Complex names need an explicit path.
- The destination must not exist, its parent must exist, and it cannot be inside
  another jj workspace or repository metadata.
- `revision` defaults to `@`. The new workspace gets a **new working-copy change
  on top of that parent**, not an edit of the selected change.
- Creation may snapshot source files on disk. Unsaved loaded source buffers block
  creation; the plugin never writes them automatically or creates a bookmark.

### Switch to a workspace

```lua
ws.switch("feature")                    -- use the configured cwd scope
ws.switch("feature", { scope = "tab" }) -- tab-local cwd instead
```

These are alternative calls, not a sequence to run together. Existing workspaces
are selected by **name**, not path. Selecting the current workspace is a no-op.

By default, switching opens the corresponding current file in the new workspace
and clears the invoking window's jumplist. A modified source or destination buffer
blocks replacement. Other windows and old buffers are retained. If the invoking
window, buffer, or cwd changes while a request runs, late editor actions are refused.

### Forget a workspace

```lua
ws.forget("review")
```

This removes registration only. It refuses current workspaces, targets active in
other editor windows, and targets with known modified buffers. Files remain on
disk, but further jj use of a forgotten directory may require explicit recovery.
There is no force or recursive-delete option. The direct Lua call does not prompt.

### Inspect workspaces and handle results

```lua
ws.list(nil, function(result)
  if result.status == "success" then
    vim.print(result.data) -- array of { name, path?, commit_id, current? }
  else
    vim.notify(result.error.message, vim.log.levels.ERROR)
  end
end)
```

`ws.discover(opts, callback)` returns context in `result.data`:
`{ repository, root, name?, workspaces }`. Common `opts.cwd` selects an absolute
repository context without changing editor cwd itself. Pass `nil` for omitted
options before a callback.

Every operation returns an ID immediately and calls its optional callback once,
asynchronously. Results contain `id`, `operation`, `status`, `data`, `error`, and
`warnings`. Status is `success`, `noop`, `error`, `partial`, or `unknown`.

Only one mutation or switch can run at a time; overlapping requests return `busy`.
Read-only requests may overlap. Schedule dependent mutations after completion:

```lua
ws.create({ name = "feature", switch = false }, function(result)
  if result.status == "success" then
    vim.schedule(function() ws.switch("feature") end)
  end
end)
```

A created workspace with a failed automatic switch is **partial**, not a creation
to retry. Interrupted commands may leave partial state. Inspect the result and jj
state before retrying; the plugin does not roll back or clean up files automatically.

## Configuration

```lua
require("jj-workspaces").setup({
  jj_command = "jj",                -- executable name or absolute path
  cwd_scope = "global",            -- "global", "tab", or "window"
  update_on_change = true,          -- current-file continuity
  missing_file = "directory",       -- "directory", "keep", or function(context)
  clearjumps_on_change = true,      -- invoking window only
  workspace_directory = nil,       -- existing absolute base for omitted create paths
  log_level = nil,                  -- default "warn"; see Logging below
  operation_timeout_ms = 30000,     -- per CLI invocation
  notify = true,
})
```

With `update_on_change=false`, switching leaves the current buffer untouched.
`missing_file` controls what happens when a counterpart is missing: open the target
directory, keep the buffer, or call your function. Special and unrelated buffers
are retained. A callback receives `{ source, target, window, reason }` after cwd
changes; errors are reported as a partial switch.

Repeated setup starts from fresh defaults. Unknown or invalid options are rejected
without replacing the previous configuration. Running requests retain their settings.

## Hooks

```lua
local unsubscribe = require("jj-workspaces").on_change(function(event)
  -- event.kind: "create", "switch", or "forget"
  vim.print(event.kind, event.workspace.name)
end)

-- unsubscribe() removes this listener only.
```

Events include `operation_id`, `repository`, `workspace`, and `warnings`. Create
adds `parent_revision`; switch adds `previous = { name?, path }` and `scope`.
Hooks run before completion callbacks. Listener failures are isolated as warnings.
Use `vim.schedule` for follow-up mutations from hooks or completion callbacks.

## Logging and help

Log level precedence: `JJ_WORKSPACES_LOG` environment variable → setup `log_level`
→ `vim.g.jj_workspaces_log_level` → `warn`. Supported values: `trace`, `debug`,
`info`, `warn`, `error`, `off`; `fatal` aliases `error`. Invalid strings use `warn`.

Logs are created lazily at `stdpath("cache")/jj-workspaces.log`, with one rotation
backup. They may contain private paths and CLI diagnostics; inspect them before
sharing. `notify=false` does not suppress callbacks or file logging.

For the complete reference, see **`:help jj-workspaces`**.
