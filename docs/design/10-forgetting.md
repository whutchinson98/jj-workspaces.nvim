# HUT-102: Forgetting a workspace, not deleting its files

Status: **Accepted design**, not an implemented removal operation.
Tracking: [HUT-102](https://linear.app/hutchery/issue/HUT-102).
Depends on HUT-106.

## Decision: adapt removal to metadata-only forget

Provide `forget(name, opts, callback)`, mapping to `jj workspace forget`. Do not
provide filesystem deletion or a `delete` alias in v1. This is an intentional
reduction from Git worktree remove, not a claim of identical semantics.

jj explicitly documents that forget leaves the directory untouched. It removes
the workspace's registration/working-copy reference, not its files, buffers,
bookmarks, or the shared repo storage. A forgotten directory is not guaranteed to
remain immediately usable as a jj workspace; users may need explicit recovery or
re-registration. Do not promise permanent retention of commits that lose their
last reference. Include the previous working-copy commit ID in the result/log so
users have a reference for manual recovery, without asserting an automatic undo.

There is **no force option**. Reject `force`, `delete_files`, and old Git deletion
options instead of pretending they are honored. Removing files is left to a
separate explicit user action outside the plugin. No recursive delete, automatic
cleanup of `.jj`, branch/bookmark deletion, garbage collection, or auto-switch.

## Safety and sequence

1. Capture source context and inventory. Require a validated current workspace
   name and an explicit target name; never rely on jj's omitted-name default,
   which forgets the current workspace. Unknown names are errors, not no-ops.
2. Refuse the current workspace, any target currently serving as the effective
   workspace of another window/tab in this Neovim instance, and loaded modified
   file buffers known to belong to the target. Require explicit save/leave actions
   first. Do not switch away or save on the user's behalf.
3. Do not privilege the literal name `default`: it can be forgotten from another
   workspace when these guards pass, since no storage directory is deleted.
   The last remaining/current workspace cannot pass the active-workspace guard.
4. Revalidate target registration/repository and the guards immediately before
   mutation. For available paths, reject replacement by another repository.
   A registered name with an unavailable path may be forgotten: no path is needed
   for this metadata operation. Warn that its on-disk/editor state cannot be
   inspected; do not guess a path to scan or remove.
5. Run `jj workspace forget --ignore-working-copy -- <exact-name>` from the
   captured source root. Unlike add, forget supports the read-only-working-copy
   flag while mutating the registry; it must not snapshot source or target files.
6. Confirm the named registration is absent, emit Forget, then complete with
   `data = { workspace = old_record, files_deleted = false }`.

The direct Lua call is explicit and has no interactive prompt. Frontend
confirmation belongs to HUT-105. Cancellation before submission starts no command.
Unsaved-buffer guards are best-effort within this editor, not a claim that other
processes have no open/dirty buffers. Unavailable-path forget cannot prove the
absence of such buffers. The absence of file deletion is the critical safety
boundary even when those external states cannot be inspected.

On preflight/command failure, call the common completion callback once, not a
separate undocumented success/failure options pair. After timeout, reconcile
registration without touching files and return partial/unknown as appropriate;
never retry forget or infer that files were removed. No Delete event is emitted.
A throwing hook cannot suppress completion or change the verified result.

## Acceptance scenarios

- Ordinary forget removes only registration; dirty, untracked, ignored files,
  `.jj` files, and already-open buffers remain byte-for-byte untouched.
- Current/last and another-window-active targets are blocked; the name `default`
  alone is not protected when it is inactive. Modified known target buffers block.
- Unknown names, wrong repository, renamed/replaced directories, and context
  races do not remove another registration or fall back to current-workspace forget.
- Missing/moved/unrecorded path can be forgotten by name without invented paths;
  the warning honestly describes the limited inspection possible.
- No source snapshot, target stale update, local-file delete, remote operation,
  force bypass, or automatic cwd/buffer migration occurs.
- Timeout/failure/hook error has one completion and correct event/outcome semantics.

## Validation

`jj workspace forget --help` documents that disk contents are not touched.
Three new tests in `tests/probes/workspaces.py` verify preservation of a dirty
workspace's files/metadata, forgetting an unavailable path, and no source-file
snapshot with `--ignore-working-copy`. All eight workspace capability tests pass
on jj 0.44.0. Editor-active/modified-buffer guards are future plugin tests, not
claims established by these CLI-only probes.
