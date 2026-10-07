# HUT-101: Jump-history cleanup

Status: **Accepted design**, not implemented switch integration.
Tracking: [HUT-101](https://linear.app/hutchery/issue/HUT-101).
Depends on HUT-99.

## Decision: retain, scoped to the invoking window

Keep `clearjumps_on_change=true` by default. On a real successful cwd switch,
execute `:clearjumps` in the captured invoking window after built-in file/fallback
handling and before user Switch listeners. This deliberately improves upstream's
ordering, which cleared before buffer changes could introduce new entries.

Jump cleanup is independent of `update_on_change` and applies even when file
continuity is disabled or keeps the current buffer. Setting it false means the
plugin does not explicitly clear or reconstruct jump history; ordinary Neovim
commands/autocmds may still alter it. A same-workspace no-op and a pre-cwd failure
must not clear anything.

Only clear the invoking window's jumplist, even with global or tab cwd scope.
Do not clear other windows, the changelist, marks, quickfix, alternate buffers,
or terminal history. This reduces accidental navigation to a previous workspace;
it does not guarantee all editor navigation stays within the new workspace.

If cwd changed but buffer handling produced a warning, still attempt jump cleanup
in the surviving captured window. A cleanup error adds a warning and produces a
partial result, without rolling back cwd or hiding the Switch event. User hooks
and autocmds running afterward may legitimately add entries. Never repeatedly
clear jumps to fight user configuration or claim a permanently empty list.

## Acceptance scenarios

- Enabled cleanup occurs after buffer handling and before Switch listeners.
- Disabled cleanup, same-workspace selection, failed discovery, and failed cwd
  change do not explicitly clear the jumplist.
- Buffer continuity enabled/disabled and every cwd scope honor the same policy.
- Multiple windows with populated lists retain all non-invoking lists; another
  tab's captured window can be targeted without stealing user focus.
- Built-in buffer warnings do not skip cleanup; closed windows or API errors
  produce a partial result without erasing another window's list.
- Listener-created jumps remain, and no documentation promises changelist,
  session, or global-history isolation.

## Validation

The editor capability probe now populates two independent window jumplists and
verifies that targeted `clearjumps` clears only one without changing focus. It
runs with `nvim --headless --clean -l tests/probes/editor.lua` on Neovim 0.12.5.
This proves the primitive's scope, not the future plugin's ordering or error
handling. The future switch integration needs the acceptance tests above.
