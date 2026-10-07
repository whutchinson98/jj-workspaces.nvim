# HUT-103: Telescope workspace listing and switching

Status: **Accepted design**, not an implemented Telescope extension.
Tracking: [HUT-103](https://linear.app/hutchery/issue/HUT-103).
Depends on HUT-99; no remote/publishing/rebase prerequisite.

## Decision: retain an optional picker over the core inventory

```lua
require("telescope").load_extension("jj_workspaces")
require("telescope").extensions.jj_workspaces.workspaces(opts)
```

No core require depends on Telescope, and no Git-named or singular aliases are
provided. The extension consumes the same asynchronous core discovery/list results
as other callers; it does not run or parse its own human-readable jj command.
Telescope and its dependencies are supplied by the user's package manager.

Capture the originating window/tab, buffer, effective cwd, and repository before
opening a picker. A picker window's cwd is not the workspace context. Validate
that origin again before applying an action. Close/execute through the valid
origin window rather than switching the Telescope prompt buffer or whichever
window happens to have focus later. Do not use a cwd override to defeat the
context-change protections of HUT-99.

## Entries and search

Display columns for current marker, workspace name, path (or `[unavailable]`), and
short working-copy commit ID. Identity is exact name plus captured repository;
never use a truncated ID or display-transformed path as an action argument.
Search ordinal includes name, full path when known, and full commit ID. Use
Telescope's generic sorter and display-width-aware formatting. Transform paths
for display only; sanitize control characters in display/search strings without
changing underlying names/paths. Do not split records on spaces.

Keep unavailable entries visible and clearly marked. Current marker requires a
validated name/path match; unknown current identity gets no guessed marker. No
branch, dirty, locked, conflict, or freshness guarantee is displayed by default.
No file previewer or filesystem scan is needed. Empty inventory, outside-repo
invocation, capability failure, and load errors have distinct messages rather
than a silently empty picker.

## Actions and asynchronous lifecycle

- Enter selects one available workspace and calls core switch. Selecting the
  current workspace closes the picker and produces the core no-op.
- Empty/unavailable selection reports why it cannot switch and leaves the picker
  open. No nil dereference and no path reconstruction.
- Escape/normal Telescope close cancels selection, with no workspace operation.
- Forget and its Ctrl-D mapping are specified in HUT-105; no multi-selection
  batch mutation is supported.

Use per-picker state, not module-global selection/force flags. Tag async inventory
requests with a generation; ignore results for a closed/replaced picker. Closing
or canceling a picker does not cancel a mutation already submitted, whose result
must still be delivered without reopening the UI or stealing focus. Revalidate
selected targets through core immediately before action.

Preserve standard Telescope layout, sorting, path-display, and theme options.
Compose the caller's `attach_mappings` with extension defaults, invoking the
caller last so it can override mappings; preserve Telescope's boolean return
semantics. Do not overwrite caller options in place. API-specific options are
removed before passing the remaining table to Telescope. `opts.cwd`, if supplied,
is an absolute context override using HUT-109 semantics.

Switch success closes the picker. Failure after submission reports through the
normal result notification/callback and does not reopen it automatically. Tests
must cover normal/insert mode actions, custom mappings, and asynchronous closure.

## Acceptance scenarios

- Core works without Telescope; extension loading failures are actionable.
- List/display/search handles no/one/many entries, equal-looking paths, Unicode,
  spaces/control characters, unavailable paths, and unknown current identity.
- Enter routes an exact name to the correct originating repository/window; no
  action targets the prompt buffer or a changed/closed origin.
- No-selection/unavailable actions are guarded; no hidden bulk operation exists.
- Closing/reopening pickers cannot apply stale results or share action state.
- Caller options/mappings are composed without mutation; themes do not change
  identity or require Git branch fields.
- No data-only refresh snapshots, fetches, repairs, or claims working-copy freshness.

## Evidence and scope

Upstream's optional Telescope list shows branch/path/SHA, searches branch only,
and maps Enter to switching. The jj adaptation uses workspace-native identity,
adds name/path/ID search, and specifies safer context/selection behavior. jj and
Neovim capability probes pass; Telescope is not installed or exercised by those
probes. Pinned-version integration tests are required with the implementation.
