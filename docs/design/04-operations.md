# HUT-107: Asynchronous execution, progress, and results

Status: **Accepted design**, not an implemented runner.
Tracking: [HUT-107](https://linear.app/hutchery/issue/HUT-107).
Depends on HUT-109; logging uses HUT-108 without making it a runtime prerequisite.

## Decision: retain asynchronous execution, define completion explicitly

Run jj through `vim.system(argv, { cwd = captured_root, ... }, on_exit)` without
a shell. Discovery, version checks, inventory, and mutations all use the runner;
no blocking `:!`, `system()`, or `:wait()` on Neovim's interactive main loop.
Schedule all editor API use, progress delivery, events, and callbacks onto the
main loop. A public operation returns a unique session-local string ID immediately
and completes exactly once, including preflight validation/spawn failures.

The optional callback receives a single result table:

```lua
{
  id = "op-17",
  operation = "create", -- discover, list, create, switch, forget
  status = "success",   -- success, noop, error, partial, unknown
  data = {},           -- operation-specific immutable-by-convention payload
  error = nil,         -- or { code, message, stage, exit_code?, stderr? }
  warnings = {},
}
```

Do not overload `ok=true` to conceal partial success. `noop` means the requested
state already held and no lifecycle event is emitted. `partial` means a known
state change succeeded but a later step failed (for example creation succeeded,
editor switching failed). `unknown` means a possibly mutating process was
interrupted/timed out and its outcome cannot be confidently reconstructed.
Neither partial nor unknown means "safe to retry automatically".

Stable error codes: `invalid_argument`, `dependency`, `not_repository`,
`unsupported`, `busy`, `context_changed`, `unavailable`, `modified_buffer`,
`command_failed`, `timeout`, `invalid_output`, and `editor_failed`. Codes classify
plugin-observed conditions; do not parse translated human stderr to manufacture
finer guarantees. Always preserve a bounded diagnostic and the stage.

## Context, concurrency, and process lifecycle

Capture effective cwd, invoking window/tab, buffer identity, and config at request
start. Resolve repository identity before acting. Serialize create/forget/switch
operations **per Neovim instance** initially: a second mutation or switch returns
`busy`, with no hidden queue or focus change. Read-only requests may overlap;
each has independent state. This intentionally simple lock is not a cross-process
lock; jj handles repository concurrency, and targets must still be revalidated.

Keep the operation lock through events and the completion callback, then release
it in a protected finally path. Reentrant mutation from a listener/callback gets
`busy`; scheduling it for a later tick is supported. Listener errors cannot strand
the lock. Closing/changing the invoking editor context prevents late editor
side effects, not delivery of the result for a mutation already performed.

Use no pager/color and argv-separated flags/values, with `--` before positional
user names/paths. Pass explicit cwd, not process-global `chdir`. Read-only commands
use `--ignore-working-copy`; mutating commands specify their snapshot behavior in
the relevant design. Set `snapshot.auto-update-stale=false` on mutations so user
configuration cannot silently enable an unrequested workspace repair. Do not
suppress jj errors or add `--ignore-immutable`/`--allow-conflicts` as retries.

Each CLI invocation has a captured `operation_timeout_ms` (default 30000). On
expiry, terminate and reap the process before finishing; escalating termination
must be bounded. Drain both streams while bounding retained output (1 MiB stdout,
64 KiB stderr). Inventory truncation is an explicit error, never a partial list.
Do not leave a child blocked because its output buffer filled. Long-running jj
processes must not block editor redraw/input.

After an interrupted mutation, run a bounded read-only reconciliation if possible.
Report only verified postconditions and otherwise `unknown`, with guidance to
inspect jj state. Do not delete a half-created destination, roll back the repo,
rerun a command, or emit a success event based only on a directory's existence.
Public cancellation and returned raw job handles are deferred; picker cancellation
before submission starts no operation. No statusline API is promised.

## Progress and notifications

Progress is a stage label, not a guessed percentage: `discovering`, `validating`,
`creating`, `switching`, `forgetting`, `complete`. Associate it with the operation
ID. Debug logging can record stage changes. User notifications are concise and
bounded, not every stdout line; terminal error/partial/unknown results must be
visible when `notify=true`. Successful read-only requests need no notification.
Callbacks receive results regardless of `notify`. Frontends own UI prompts, not
the process runner. No credentials or interactive network prompts are required
by the initial local-only command set.

## Acceptance scenarios

- Mocked spawn/exit/timeout/output-overflow and validation paths complete once,
  asynchronously on the main loop, without leaking the global operation lock.
- Read-only calls overlap with distinct IDs; mutation overlap gets `busy`.
- Closing a window, switching cwd/buffers, or reconfiguring during a job does not
  cause a delayed action in a different context or erase a real mutation result.
- Partial creation reports the created name/path and switch failure; retry does
  not create another workspace or erase the first one.
- Timeout before/after jj state changes yields reconciled or unknown state, not
  blind retries; retained output is bounded while streams continue draining.
- Hooks/callbacks that throw do not kill the runner or change committed outcomes.
- No human-table parsing, shell interpolation, automatic stale update, forced
  history changes, fetch, or push is introduced by generic error recovery.

## Evidence and scope

Upstream uses mixed synchronous/asynchronous Plenary jobs, shared progress counts,
and inconsistent completion paths. HUT-94's probes establish read-only inventory
without snapshots or stale repair. Main-loop, timeout, and completion behavior
above must be tested with the future Lua runner; existing CLI probes do not prove
those editor guarantees.
