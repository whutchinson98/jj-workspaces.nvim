# HUT-97: Automatic publishing

Status: **Accepted omission for v1**; no push feature is added.
Tracking: [HUT-97](https://linear.app/hutchery/issue/HUT-97).
Depends on HUT-96.

## Decision: drop autopush, not merely disable it by default

Workspace management must not publish references or commits. Do not provide an
`autopush` option, choose a remote, infer a bookmark from a workspace name, or
invoke `git push`/`jj git push`. Unknown legacy options fail setup validation.
A rejected or absent remote has no bearing on local workspace creation.

Upstream's opt-in autopush combines branch tracking, publishing, and rebase. Its
command also appends a filesystem path as a push refspec. None of that provides
a sound jj workspace contract: a workspace name is not a publishable bookmark,
and creation should not make private work public or move shared remote state.

Users explicitly create/move bookmarks and publish via jj or another integration.
A locally known bookmark used as a creation parent is not moved or pushed.
Plugin hooks can invoke arbitrary user code, but bundled examples must not suggest
silent publication on Create. Hook-side network results are outside the core
operation result and must not be presented as a plugin publishing guarantee.

This policy concerns the future plugin. The maintainer's explicit instruction to
commit this project's work and push its `main` bookmark is a separate development
workflow and remains honored.

## Acceptance scenarios

- Every core operation and every failure/retry/reconciliation path has zero push
  commands, regardless of remote names, bookmark names, or configuration.
- A workspace with the same name as an existing bookmark does not move or publish
  it; explicit revision selection preserves bookmark state.
- `autopush=true` and other legacy publishing options return useful validation
  errors instead of being ignored or triggering side effects.
- Local creation succeeds offline; remote authentication/push rejection cannot
  interrupt it because no publication is attempted.
- Documentation distinguishes workspace registration, local change creation,
  bookmark management, and remote publication.

## Evidence and scope

No remote or publication is needed by the checked-in workspace creation probes.
Production command-runner tests must enforce the no-push invariant once code
exists. Future publication support requires explicit bookmark/remote selection,
confirmation, and a separate feature decision; it is not an unfinished part of
this completed omission task.
