# HUT-95: Workspace creation and initial state

Status: **Accepted design**, not an implemented create operation.
Tracking: [HUT-95](https://linear.app/hutchery/issue/HUT-95).
Depends on HUT-99. Remote/publishing/rebase decisions are separate tasks.

## Decision: create a local workspace with a new working-copy change

```lua
ws.create({ name = "feature", path = "../feature", revision = "@", switch = true }, callback)
```

`name` is required and independent of directory or bookmark. `revision` defaults
to `@`, interpreted in the captured source workspace. It must resolve to exactly
one commit; it is a **parent**, not the commit the new workspace will directly
edit. The result has a new working-copy change on top of that parent. There is
no implicit bookmark creation, checkout of a Git branch, fetch, tracking, push,
or rebase. Accepting a bookmark as a revision expression does not move it.

Always pass an explicit resolved parent to `jj workspace add`. Native jj's
omitted-revision default uses the source working copy's **parents**, which is
not the same as starting on top of its current state. This intentional adaptation
makes the default include the source's snapshotted content. Multi-parent creation,
editing an existing change directly, and bookmark management are outside v1.

`switch` defaults true. False means create without touching editor cwd/buffers.
For automatic switching, use the invoking scope/configuration captured at request
start and the same safety/event rules as an explicit switch, not a second public
request that would conflict with the operation lock.

## Destination selection

An explicit `path` follows HUT-94: absolute paths stay explicit; relative paths
use the source workspace root. This is unchanged by `workspace_directory`.

If `path` is omitted, derive `<base>/<name>`, where base is the configured absolute
`workspace_directory`, otherwise the current workspace root's parent directory.
This gives a convenient sibling by default without treating bare relative paths
as siblings. Derivation requires name to be a safe single filename component:
not empty, `.`/`..`, NUL, or containing `/` or `\`. A more complex valid jj name
requires an explicit path. Never silently sanitize a name into a different one.

The configured base is optional and is used only for this omitted-path default.
It must already exist and be a directory; do not create arbitrary parent chains.
The destination must not exist (even as an empty directory/symlink) and must not
be inside any registered workspace or its metadata. This prevents accidental
nested working copies and source snapshotting of their contents. Use canonical
existing ancestors plus path-component boundaries for this check. Other plugin
operations still discover legitimately pre-existing nested repositories normally.

## Preflight, command sequence, and snapshots

1. Validate names/options/context, duplicates, destination and parent directory;
   capture a before-inventory and refuse an already registered name/path.
2. Reject loaded modified buffers under the source workspace: jj snapshots disk,
   not unsaved Neovim text. Never write them automatically. Recheck before mutation.
   If auto-switch is requested, also run the known switch buffer/context guards.
3. Resolve the revision with a bounded `jj log --no-graph -r <expression>` using an
   explicit JSON template for full commit IDs. This step intentionally permits
   jj's normal disk snapshot; require exactly one result. Do not use `--all` or
   infer a single result from the first line of a multi-result revset.
4. Recheck destination/identity/context, then run `jj workspace add --name <name>
   --revision <full-id> --sparse-patterns=copy -- <absolute-destination>` from the
   source root. **Do not use `--ignore-working-copy` for add**: jj must initialize
   the destination working copy. Disable automatic stale updates via the runner.
5. Verify registration, canonical path, shared repo identity, and the new working
   copy's parent before emitting Create; then optionally perform editor switching.

Normal jj snapshot/ignore/size rules apply; disk changes can be recorded in the
source working-copy commit. There is no promise that creation leaves the operation
log untouched. If source files change again between resolution and add, the
pinned parent remains the resolved commit; do not silently choose a different
one. Unknown/invalid/conflicted outcomes must remain explicit in the result.

## Failure contract

Do not assume add is transactional. On jj 0.44.0, both an invalid revision passed
directly to add and using `--ignore-working-copy` can leave a registered directory
before returning failure. Pre-resolving the parent avoids the first known case;
omitting the read-only flag avoids the second, but does not eliminate IO races.

After nonzero exit or timeout, inspect without mutating. Report observed remnants
in `data` with `created=false` or unknown completeness; do not emit Create merely
because a path/name exists. Return `partial` when changes attributable to this
request are established, otherwise `unknown` when attribution/outcome is unclear.
Even a failed preflight revision query may have snapshotted the source; record
that side effect if verified. No automatic forget, recursive deletion, rollback,
or retry follows failure. Explain how to inspect the named workspace manually.

Successful add plus failed editor switch is `partial` with `created=true` and
`switched=false`, with Create but no false Switch event. A source-only snapshot
or incomplete add is not a successful creation event. Completion occurs once.

## Acceptance scenarios and evidence

- Independent name/path/revision, explicit absolute/root-relative paths, omitted
  sibling path, configured base, complex names, and missing/occupied destinations.
- Default `@` and explicit single revision yield the correct **new child**; invalid,
  empty, and multi-result selectors do not reach add. Sparse patterns are copied.
- No bookmark is created/moved and no remote is needed; source disk snapshots are
  documented while unsaved editor buffers block creation before mutation.
- Duplicate/racing registrations, nonexistent source, stale source, cwd changes,
  IO failure, timeout, and incomplete native add never trigger destructive cleanup.
- Auto-switch succeeds, is disabled, or fails independently with correct events,
  result fields, and preserved files/buffers.

`python3 -B tests/probes/workspaces.py` adds five isolated jj 0.44.0 tests: explicit
parent/content, native default-parent difference, duplicate handling, preflight
and occupied destination, and two native partial-failure cases. They use no
remotes and test jj behavior, not a Lua implementation. Neovim creation guards,
path derivation, concurrent actors, and event integration remain acceptance work.
