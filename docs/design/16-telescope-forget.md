# HUT-105: Telescope forget and confirmation

Status: **Accepted design**, not an implemented picker action.
Tracking: [HUT-105](https://linear.app/hutchery/issue/HUT-105).
Depends on HUT-102 and HUT-103.

## Decision: explicit, confirmed metadata removal; no force toggle

Map Ctrl-D in insert and normal mode in the workspace listing picker to
**Forget workspace (keep files)**. Preserve the familiar action location, not
Git's destructive meaning. All labels, help, notifications, and confirmation
text must say forget/registration rather than imply directory deletion.

Do not install Ctrl-F as a force action. There is no force state, one-shot bypass,
force confirmation, or core force API to reset. This intentionally removes the
upstream buggy toggle rather than translating it into an unsafe cleanup action.
Other Telescope defaults may retain their own unrelated Ctrl-F meaning.

The picker always confirms forgetting. There is no `confirm_telescope_deletions`
compatibility option or configurable bypass in v1; an explicit direct Lua
`forget` call remains available to user-authored automation without UI prompting.

## Action flow

1. Require one selected entry. Capture its exact name/repository/path and the
   originating context, not just the current list index. No bulk selection or
   default-to-current behavior. Precheck known active-workspace protections.
2. Ask asynchronously via `vim.ui.select`, with **Cancel first/default** and
   **Forget workspace (keep files)** as the affirmative choice. Example wording:

   `Forget workspace "feature" at /work/feature? Files will remain on disk.`

   Also explain that registration is removed and the directory may need explicit
   recovery before further jj use. For an unavailable path, show `[unavailable]`
   and warn that its on-disk/editor state could not be inspected. Do not invent
   a path or imply there is nothing left to preserve. Escape/control characters
   for display without changing the underlying selected name.
3. Nil, Cancel, prompt closure, or a stale per-picker confirmation token stops
   without invoking core. Do not accept a free-text string merely starting with y.
   Allow only one pending confirmation per picker; repeated Ctrl-D is ignored.
4. On affirmative selection, revalidate origin and call core forget for the
   captured name, even if list sorting/selection changed. Core rechecks guards
   and registration immediately before mutation; the UI cannot bypass them.
5. On verified success, refresh the still-open picker from fresh core inventory,
   preserving search text and selecting a nearby remaining row. On failure, leave
   state visible and show the exact error; never suggest force or delete files.

If the original picker closed or was replaced, discard its confirmation/refresh
callbacks and do not reopen it. Once a mutation has been submitted, it still
finishes and reports its outcome even if the picker is closed; closing the UI
cannot roll back a forget. A refresh failure after successful forget does not
change the successful core result: report a UI warning and mark the list stale.
Do not fabricate a refreshed list by assuming every failure left registration
unchanged. Partial/unknown outcomes require a fresh query or explicit user
inspection, never a blind second forget.

Per-picker state stores selection snapshots, generation, pending-confirmation,
and busy flags only. Clear them on every terminal UI path with exception-safe
cleanup; no module-global destructive-action state. Caller mappings follow the
composition/override rules in HUT-103.

## Acceptance scenarios

- Both modes invoke the same single-entry forget action; nil selection is safe.
- Confirmation always states files remain and defaults to cancellation; unavailable
  paths have honest warnings and no fabricated directory.
- Active/current/modified-buffer/replaced targets are blocked by core even after
  confirmation. No UI shortcut can force past a failed guard.
- Changing selection/order while confirming cannot forget a different name;
  repeated keys, canceled prompts, stale callbacks, and picker reopen are safe.
- Success refreshes a live picker; failure retains context; closed pickers do not
  reopen or steal focus. Refresh errors do not erase the verified core outcome.
- No force toggle, recursive deletion, extra Git command, network call, implicit
  save, workspace repair, or automatic navigation is introduced by Ctrl-D.
- Custom mappings and alternate `vim.ui.select` providers preserve the same
  cancellation, captured-context, and exactly-once submission semantics.

## Evidence and scope

Upstream's Ctrl-F never clears an enabled force flag, its confirmation omits the
force argument, and state can leak across picker sessions. Removing force and
requiring an accurately worded confirmation avoids carrying those defects over.
The jj forget probes verify file preservation; Telescope lifecycle/prompt tests
remain requirements for the future implementation. Completion of this final
design task does not claim that a working Neovim plugin now exists.
