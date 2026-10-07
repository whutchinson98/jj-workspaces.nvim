# HUT-96: Remote discovery, fetching, and tracking

Status: **Accepted omission for v1**; no production remote integration is added.
Tracking: [HUT-96](https://linear.app/hutchery/issue/HUT-96).
Depends on HUT-95.

## Decision: drop automatic remote operations from workspace creation

Do not discover a default remote, assume `origin`, fetch any remote, or establish
bookmark tracking when creating, listing, switching, or forgetting a workspace.
There is no `upstream` or remote-selection configuration in the core API.
A workspace is a local working directory with its own working-copy change, not
a Git branch with an upstream relationship.

Upstream conditionally detects `origin`, fetches all remotes, and attempts tracking
of a same-named branch. That couples a local filesystem action to network access
and assumes a name relationship that does not hold for jj workspaces. Its failure
pipeline can leave a worktree without an expected Create/switch notification.
Those are reasons to remove the coupling, not translate each Git command blindly.

A user may explicitly supply an already-known local revision expression, including
a locally known remote bookmark, as the creation parent. Resolve it using the
normal single-revision rules. A missing reference is an error with a suggestion
to fetch manually, not permission to fetch. Do not change bookmark tracking or
create a bookmark just because a workspace has the same name. No credentials,
network timeout policy, or remote picker is needed for this plugin's v1 workflow.

Users fetch/track through jj CLI or their preferred jj integration **before**
invoking workspace creation. After a fetch, fresh inventory/revision queries see
the new local state; the plugin maintains no remote cache. This does not forbid
explicit user hooks from doing additional work, but such hooks are user-owned,
not default plugin behavior or completion guarantees.

## Acceptance scenarios

- Creation, listing, switching, and forgetting work in a no-remote repository and
  offline. Adding an `origin` remote does not change the command sequence.
- Zero, one, or many configured remotes are never contacted or auto-selected.
- A locally known remote bookmark can resolve as a parent without being moved or
  tracked; a missing reference produces an error without a network retry.
- Old `upstream`/remote options are rejected, not silently ignored or translated.
- Mocked command-runner tests assert no `git fetch`, `jj git fetch`, or bookmark
  track/set operation in any core success, failure, or recovery path.
- UI describes revision selection as selecting local known state, not freshness
  verification or remote synchronization.

## Evidence and scope

The creation capability probes create a new child workspace in a repository with
no remotes or bookmarks. That proves the underlying local workflow is viable;
negative command-runner assertions await Lua implementation. Reintroducing remote
features requires a separate explicit design and opt-in API, not a hidden default.
