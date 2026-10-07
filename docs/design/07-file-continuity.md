# HUT-100: Current-file continuity

Status: **Accepted design**, not implemented buffer handling.
Tracking: [HUT-100](https://linear.app/hutchery/issue/HUT-100).
Depends on HUT-99.

## Decision: preserve the current file's relative location, never unsaved edits

`update_on_change=true` retains upstream's useful behavior: show the corresponding
file in the destination workspace in the invoking window. It does not copy file
contents between workspaces or migrate every open buffer. Setting it false changes
cwd only (plus independently configured jump cleanup), leaving buffers untouched.

For a named normal-file buffer inside the previous workspace root, compute a
relative path using directory boundaries, then join it to the destination root.
Canonicalize existing paths for identity; do not match arbitrary substrings.
A symlink resolving outside either workspace does not establish a counterpart.
Open only an existing regular file, not a directory or inaccessible target.
Reuse an existing buffer for that exact destination filename when safe; do not
reload another buffer or discard its contents. A buffer already at the intended
destination is unchanged. Do not carry old cursor/view positions automatically.

Unnamed unmodified normal buffers use the fallback. Terminal, prompt, help,
quickfix, and other special buffers are retained without fallback. A normal file
outside the old workspace is also retained; unrelated files should not disappear
merely because editor cwd changed. This intentionally narrows upstream's fallback.

## Preflight and unsaved data

Determine the intended buffer change before changing cwd. If replacing the
current buffer would hide a modified buffer, reject with `modified_buffer`;
do not rely on `hidden`, `autowrite`, or `confirm` to decide silently. Likewise,
reject when the destination buffer is already modified and is not the unchanged
current buffer. Never save, reload, rename, wipe, or force-abandon either buffer.
The user saves/discards changes explicitly, or disables file continuity to keep
the current buffer while changing cwd. There is no force override in this API.

A fallback callback is conservatively treated as potentially replacing the
current buffer, so a modified source is rejected before invoking it. `missing_file
= "keep"` is non-replacing. Recheck source/destination modification state and
buffer identity after asynchronous discovery, immediately before editor effects.
Other windows' modified buffers are not an excuse to wipe them; leave them alone.

## Fallback contract

`missing_file` is one of:

- `"directory"` (default): structured `:edit` of the destination root, with
  filename expansion disabled. This delegates directory UI to the user's editor
  setup; it does not install or require netrw. Failure is a warning/partial switch.
- `"keep"`: retain the current buffer after changing cwd.
- `function(context)`: a synchronous main-loop callback after cwd changes,
  receiving source/target workspace records, window ID, and reason (`missing`,
  `unnamed`, `inaccessible`, or `outside_target`). It may implement a file picker.

Callbacks are trusted user configuration, protected with `pcall`; they cannot
roll back an already completed cwd change. Do not await a returned promise or
coroutine. A thrown callback, removed target file, BufEnter/autocmd failure, or
post-cwd buffer race leaves existing buffers intact, emits Switch with warnings,
and returns `partial`. No attempt is made to reverse arbitrary autocmd effects.

Built-in buffer changes precede jump cleanup and the Switch event. Do not purge
old-workspace buffers, close other windows, rewrite sessions, or claim a full
workspace-session switch. Such functionality is separate future scope.

## Acceptance scenarios

- Existing counterpart is opened/reused only in the invoking window; contents
  are never copied, old buffers remain, and other windows are unchanged.
- Root-relative mapping handles similarly named roots, spaces, and symlinks;
  source/target escapes do not open an unrelated file.
- Missing/unnamed files invoke the selected fallback; special/outside-project
  buffers remain; an already-target buffer is not unnecessarily reopened.
- Modified source/destination blocks a replacing action before cwd, with no
  implicit write or discard even when `autowrite` or `hidden` is enabled.
- Disabled continuity and keep fallback preserve the current buffer; jump cleanup
  remains independently configurable.
- Concurrent buffer changes, disappearing files, unavailable directory UI, and
  throwing callbacks report a partial switch without losing unsaved content.
- No cursor/view/session-transfer guarantee is accidentally advertised.

## Evidence and scope

Upstream `update_current_buffer` relocates only the current buffer and falls back
on several cases, but has no explicit unsaved-buffer policy and uses substring
path matching. These are intentional safety adaptations. Editor cwd probes and
jj discovery probes pass; buffer-policy acceptance tests await implementation.
