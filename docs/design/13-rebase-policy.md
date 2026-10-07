# HUT-98: Automatic rebase and workspace freshness

Status: **Accepted omission for v1**; no rebase operation is added.
Tracking: [HUT-98](https://linear.app/hutchery/issue/HUT-98).
Depends on HUT-96; not on automatic publication.

## Decision: explicit parent selection replaces implicit synchronization

Do not run `jj rebase` or Git rebase during workspace creation or switching.
Do not infer a remote destination, move an existing change to a bookmark, or
attempt to make a new workspace "up to date" automatically. HUT-95's explicitly
resolved parent is the creation input; the new workspace receives a new child
working-copy change. No additional post-create history transformation is needed.

This excludes an explicit rebase command, not jj's intrinsic behavior: snapshotting
a working copy can rewrite that change and rebase descendants according to jj's
own model. Creation intentionally permits documented source snapshots. The plugin
must not promise that all commit IDs remain unchanged when such snapshots occur.

Upstream runs Git rebase whenever its upstream pipeline is active, even with
`autopush=false`, then treats failure as acceptable and switches anyway. That
coupling and conflict handling are not retained. A failed jj creation is reported
using its actual postconditions, not dismissed as a harmless rebase failure.

## Staleness and conflicts are separate concepts

A stale jj working copy is not a request to rebase history. Discovery and switching
use read-only queries and may enter an available directory as-is. They do not
snapshot it or run `workspace update-stale`. Mutating commands set
`snapshot.auto-update-stale=false` and surface a stale-workspace error rather than
repairing implicitly, even if the user's global config enables automatic repair.

Users update stale workspaces, resolve conflicts, or rebase revisions explicitly
through jj. Existing conflicted local revisions may be selected as a creation
parent if jj accepts them; preserve their semantics and do not promise a clean
checkout. Never add force/ignore-immutable options, resolve conflict markers, or
rewrite a requested parent to hide an error. Informational conflict indicators
would be a separate UI enhancement, not a prerequisite for navigation.

## Acceptance scenarios

- Creation uses exactly the resolved parent and performs no explicit rebase;
  changing remote state or a same-named bookmark does not silently choose another.
- Autopush is absent, not a switch controlling hidden rebase behavior.
- Read-only navigation in a stale workspace does not change files, commit state,
  or local working-copy metadata. Mutation refuses implicit repair regardless of
  `snapshot.auto-update-stale` user settings.
- Conflict-bearing parents are not automatically rewritten or resolved; jj errors
  and partial state are reported without success-only fiction.
- Mocked command sequences exclude `rebase`, `workspace update-stale`, forced
  history changes, and rollback on every success and recovery path.
- Docs explain the difference among parent selection, snapshotting, stale-copy
  reconciliation, conflict resolution, and rebasing.

## Validation and scope

The discovery probe verifies stale-workspace inspection without changing its
local working-copy state. Creation probes verify explicit-parent semantics.
`jj help -k config` documents `snapshot.auto-update-stale`; the mutation probes
explicitly disable it. Full stale-error/UI integration awaits implementation.
This is a completed decision to omit an automatic feature, not a rebase TODO.
