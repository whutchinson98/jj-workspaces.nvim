# HUT-106: Lifecycle hooks

Status: **Accepted design**, not an implemented event dispatcher.
Tracking: [HUT-106](https://linear.app/hutchery/issue/HUT-106).
Depends on HUT-107.

## Decision: retain lifecycle integrations with success-only events

`on_change(callback)` registers a listener and returns an idempotent unsubscribe
function. Event kinds are string values `create`, `switch`, and `forget`. There
is intentionally no `delete` event that might imply files were removed. Do not
carry over branch/upstream fields as workspace identity. No old `on_tree_change`
alias, enum mutation surface, or all-listeners `reset()` is required.

Every event contains:

```lua
{
  operation_id = "op-17",
  kind = "switch",
  repository = "/canonical/shared/metadata", -- opaque identity, not a path base
  workspace = { name = "feature", path = "/work/feature" },
  previous = { name = "default", path = "/work/project" }, -- switch only
  scope = "global", -- switch only
  warnings = {},
}
```

`workspace.path` may be nil only for forgetting an unavailable workspace. For
switch, `previous.name` can be nil if the old context's name is unavailable;
`previous.path` is the previous workspace root, not its exact editor subdirectory.
Create adds `parent_revision` with the resolved parent commit ID. Fields describe
verified state when the event is emitted, not a live context object. Each listener
receives its own deep copy so it cannot modify another listener's payload.

## Ordering and errors

Capture the listener list at the start of each dispatch and invoke it in
registration order on the main loop. Subscribe/unsubscribe during dispatch
changes subsequent events only. Protect each callback separately and log/report
exceptions without skipping other listeners. Callbacks cannot veto a completed
operation or request an implicit rollback. Returned coroutines/promises are not
awaited; asynchronous listener work is the listener's responsibility.

- **Create:** emit only after jj success and postcondition validation establish
  the new registered workspace. Emit before the optional automatic switch.
- **Switch:** emit after cwd and configured built-in buffer/jumplist handling
  have run, including any warnings. A successful cwd change followed by a
  failed buffer update still emits Switch with a warning and returns `partial`.
- **Forget:** emit only after confirming registration is absent. It means jj
  metadata was forgotten, not that any directory/buffer/revision was deleted.

For create-and-switch, the same operation ID covers Create then Switch then the
single completion callback. If creation succeeds but switching fails, emit only
Create and return `partial` with the created workspace and switch error. A failed
creation, failed cwd change, preflight rejection, or no-op emits no corresponding
success event. An unknown timed-out outcome is not promoted to an event unless
its postcondition can be verified as belonging to this operation.

All lifecycle events precede the completion callback. Hook failures appear in
result warnings but do not retroactively fail a successful workspace operation.
The operation lock remains held through events/completion (HUT-107); a listener
wanting a follow-up mutation schedules a new request for a later tick. Built-in
file/jump handling is not installed as removable user listeners.

## Acceptance scenarios

- Every operation exposes the documented names, canonical path meanings, optional
  fields, and same-ID event/callback ordering.
- Create-without-switch emits only Create; create-plus-failed-switch emits Create
  and a partial result, with no false Switch event.
- Failed mutation, invalid target, duplicate selection, and unknown outcome do
  not claim success. Reconciliation cannot claim a concurrent actor's mutation.
- Listener registration order is stable; unsubscribe is idempotent; modifying the
  listener list during dispatch affects only later events.
- Throwing/mutating listeners cannot disrupt other listeners, built-in state,
  operation-lock release, or exactly-once completion.
- The lack of veto/await semantics and the reentrant `busy` policy are documented
  in integration examples; no callback silently publishes changes or repairs jj.

## Evidence and scope

Upstream documents Create/Switch/Delete hooks, runs callbacks in order, and uses
them for third-party integrations. It lacks exception isolation and unsubscribe,
and some failures emit misleading success events. This design intentionally
adapts those semantics. Acceptance tests require the future Lua implementation;
existing CLI probes only validate the jj context underlying the payloads.
