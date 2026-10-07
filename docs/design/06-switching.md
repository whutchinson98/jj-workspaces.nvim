# HUT-99: Switching workspace and editor cwd

Status: **Accepted design**, not an implemented switch operation.
Tracking: [HUT-99](https://linear.app/hutchery/issue/HUT-99).
Depends on HUT-106 and the discovery/API/runner contracts.

## Decision: switch editor context, not jj history

`switch(name, opts, callback)` enters an existing workspace by exact name. It
runs no `jj edit`, `new`, `rebase`, checkout, or implicit stale update. Workspace
identity and path validation follow HUT-94. Names are not paths or bookmarks.
Unavailable paths, replaced directories, or a different repository at the target
produce an error before changing editor state.

Choose `cwd_scope` globally in setup, optionally override with `opts.scope`:

| Scope | Editor command | Effect |
| --- | --- | --- |
| `global` (default) | `cd` | Neovim global cwd, subject to its existing local overrides |
| `tab` | `tcd` | Invoking tab's cwd |
| `window` | `lcd` | Invoking window's cwd |

Use `nvim_win_call` to act in the captured invoking window and structured
`nvim_cmd` arguments with `magic.file=false`, not a concatenated Ex string or
filename expansion. Query a non-current window's effective cwd with explicit
window/tab numbers (`win_id2tabwin` then `getcwd`); a no-argument `getcwd()` inside
`nvim_win_call` does not reliably describe another tab's cwd. Apply Neovim's native cwd
scope semantics; do not iterate through and clear other windows' local cwd
settings. A global change may affect other windows without local overrides;
only the invoking window gets buffer/jumplist handling. Return the effective scope
and target root, rather than promising every tab now uses the new workspace.

## Operation sequence

1. Capture window/tab, effective cwd, buffer ID, and configuration at invocation.
   With `opts.cwd`, capture the distinct explicit repository context as well.
2. Discover and revalidate the exact named target, shared repository identity,
   directory accessibility, and boundary. Read-only jj calls do not snapshot.
3. Compute the intended current-buffer action and check for unsafe unsaved data
   before changing cwd (HUT-100). Hold the operation lock from HUT-107.
4. Recheck that the original window/tab exists and its effective cwd and buffer
   are unchanged. Focus moving elsewhere alone is not a change to that window;
   apply scoped editor actions through it without stealing focus. A changed
   context returns `context_changed`, never a delayed switch in another window.
5. Change cwd to the absolute target root, then apply file continuity and jump
   cleanup, and dispatch Switch with any warnings.
6. Complete once; release the lock even if editor APIs or hooks fail.

Selecting the current named workspace is a **no-op**: preserve cwd (including a
subdirectory), buffer, and jump history; emit no Switch event. It is not a shortcut
for `cd` to the workspace root. A different workspace always enters its root,
not a reconstructed subdirectory; current-file continuity is a separate action.

If cwd fails, no Switch event is emitted. If cwd succeeds but file/jump handling
fails, retain the new cwd, emit Switch with warnings, and return `partial`.
Do not roll back a cwd whose autocmds may already have performed user actions.
Callbacks that throw are warnings, not a failed switch. Never delete old buffers,
save files implicitly, restore sessions, or migrate other windows.

A stale but available workspace can be entered **as-is**; the plugin promises no
freshness guarantee and runs no mutation as part of switching. Users invoke jj's
recovery workflow explicitly if needed. Existing dirty files/conflicts do not
alone prohibit editor navigation; unsaved buffer replacement is checked separately.

## Acceptance scenarios

- Each scope changes the intended effective cwd while preserving unrelated local
  overrides and focus; explicit `opts.cwd` selects only the repository context.
- Same-workspace selection from a subdirectory is a side-effect-free no-op.
- Names containing spaces are matched literally; directory spaces, quotes, and
  Ex separators are passed as one argument without command execution.
- Missing/unavailable/replaced target, wrong repo, and invalid scope leave editor
  state untouched and emit no success event.
- Closed/moved invoking window, changed cwd/buffer, and in-flight configuration
  changes cannot redirect the switch or reuse stale captured state.
- Modified-buffer preflight happens before cwd; a later editor/autocmd failure
  reports partial success without a misleading rollback or lost buffer.
- No jj working-copy mutation, snapshots, rebase, fetch, push, or automatic repair
  is caused by navigation. Events and completion use HUT-106 ordering.

## Validation and limits

`nvim --headless --clean -l tests/probes/editor.lua` probes native global/tab/window
cwd scoping, cross-tab targeted changes without focus theft, and structured
arguments with spaces, quotes, and `|` (12 assertions). It runs in a
clean Neovim with owned temporary directories and passed on Neovim 0.12.5.
The existing jj discovery probes cover registered paths and nonmutating queries.
These validate backend/editor capabilities, not the future plugin's context
checks, event dispatch, or buffer safety. Minimum Neovim 0.11 CI remains required.
