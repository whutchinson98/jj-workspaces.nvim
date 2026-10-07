# HUT-94: Repository discovery and workspace paths

Status: **Accepted design**. This specifies future plugin behavior; it does not
claim that a Lua implementation exists yet.

Tracking: [HUT-94](https://linear.app/hutchery/issue/HUT-94).

## Decision

**Adapt** upstream discovery and path resolution to jj's repository/workspace
model. Support both colocated and non-colocated jj repositories. No Git fallback,
bare-Git workflow, or privileged "main workspace" is assumed.

Default directory arguments are relative to the **current workspace root**, not
the editor's current subdirectory or the original checkout. Existing workspaces
are selected by **workspace name**, using jj's recorded path. Names, paths,
bookmarks, and revisions are distinct concepts.

An optional shared creation-directory setting is deferred to
[HUT-95](https://linear.app/hutchery/issue/HUT-95). It will not silently change how
existing workspaces are located.

## Context and identity

At operation start, capture the effective cwd of the invoking Neovim window,
including any window/tab-local directory. Do not derive context from the current
buffer filename. The exact Lua API and execution mechanism belong to HUT-109 and
HUT-107; these are data/behavior requirements, not final exported function names.

The internal context needs:

- **Invocation cwd:** absolute directory captured at request time.
- **Workspace root:** the active working directory's top-level path, validated
  with `jj workspace root --ignore-working-copy`.
- **Repository key:** an opaque, canonical identity for the shared jj metadata
  store. It is not a directory base for user paths and is not a permanent ID.
- **Current workspace name:** matched from the inventory by canonical root path;
  unknown if the association cannot be established unambiguously.
- **Inventory:** workspace names, optional absolute paths, working-copy commit
  IDs, and path availability. Do not identify a workspace by a bookmark or commit
  ID: names are only unique within their repository, and commits can change.

For the validated jj layout, the metadata key can be obtained read-only from
`<root>/.jj/repo`: resolve the directory itself, or resolve the pointer file's
contents relative to its parent `.jj` directory. Canonicalize the result and
validate it through jj before using it. Keep this version-sensitive detail behind
one backend adapter, never write these files, and reject unsupported/broken
layouts rather than guessing. Two linked workspaces share this key; two
independent repositories with a workspace named `default` do not.

Do not retain one global "current repository" across requests. Capture context
for each operation; if an async discovery response arrives after its invoking
context changes, do not apply it to the new context. No cross-request cache is
required initially. Revalidate a selected target immediately before an action.

## Repository boundaries

Walk upward from the invocation cwd before asking jj to discover its root:

1. At the nearest directory containing `.jj`, validate that jj workspace.
   Colocated `.git` at that same level is supported.
2. If `.git` is encountered first, stop. Both `.git` directories and worktree
   pointer files are boundaries; do not attach to an ancestor jj repository.
3. Broken `.jj` metadata is an error, not permission to continue upward or use
   Git. No marker before the filesystem root means "not in a jj workspace".
4. Nested jj repositories use their own context, not the ancestor's.

This explicit check is necessary: jj 0.44.0 itself discovers an ancestor jj
repository when invoked inside a nested Git-only repository.

Resolve symlinks when comparing existing directory identities, using filesystem
semantics rather than substring matching. Never infer containment from a shared
string prefix (for example, `project` versus `project-other`). Do not walk into
metadata directories as ordinary project roots.

## Directory arguments

| Input | Meaning |
| --- | --- |
| Absolute directory path | Use the supplied location; never prepend another directory. |
| Relative directory path | Resolve against the captured current workspace root. |
| `../feature` | Sibling of that root, even when invoked from `src/deep`. |
| Workspace name | Exact inventory lookup in the captured repository; not a path expression. |

Example: with workspace root `/code/project` and editor cwd
`/code/project/src/deep`, `../feature` resolves to `/code/feature` and `feature`
resolves to `/code/project/feature` **when used as a directory argument**.
Switching to workspace name `feature` instead uses its registered location,
which may be entirely elsewhere.

Keep name and path inputs distinct in the future API. A missing named workspace
must not fall back to interpreting its name as a filesystem path. A legacy
path-based selection helper, if retained later, must match a registered workspace
rather than enter any arbitrary directory.

Normalize relative `.`/`..` components without requiring a creation destination
to exist. Preserve absolute paths as supplied for execution; use canonical paths
separately for existing-directory comparisons. There is no shell evaluation,
glob expansion, environment substitution, or implicit tilde expansion. Reject
empty/NUL-containing input. Pass CLI arguments as an argv array, not a shell
command. Spaces, quotes, tabs, and newlines must not split records or arguments.
Non-UTF-8 paths that cannot be represented by the JSON/backend interface must
produce a clear error, not a truncated or substituted path.

## Read-only inventory

Use explicit machine-readable templates instead of parsing `jj workspace list`'s
human display. The capability probe uses JSON Lines with this jj template:

```text
'{"name":' ++ json(name) ++ ',"path":' ++ json(root) ++ ',"commit_id":' ++ json(target.commit_id()) ++ "}\n"
```

Run with an explicit captured cwd/repository and
`--ignore-working-copy --no-pager --color=never`. Decode JSON; never split on
whitespace. `json(self)` is insufficient on jj 0.44.0 because it omits the root.
When consuming plain `workspace root` output, remove only its one output newline,
not arbitrary whitespace that could be part of the path. Process exit failures,
malformed output, and unsupported template capabilities are errors, not an empty
inventory. Never silently fall back to parsing the default template.

Read-only here means discovery must not snapshot user files, modify the working
copy, fetch, push, forget, register, or repair workspaces. Do not use commands such
as `jj config path --repo` for identity: that command can create configuration
state. The exact minimum jj release/capability policy is decided in HUT-109;
these probes establish behavior on **jj 0.44.0**, not compatibility with all older
versions.

## Unavailable paths and stale working copies

An inventory entry remains visible when jj cannot resolve its path. Represent
that entry with its name/commit and `path = null`; report it as unavailable and
refuse to enter it. Do not guess `<shared directory>/<name>`, search the disk,
forget it, or repair it automatically. jj may not distinguish an old unrecorded
path from a moved/deleted directory, so do not invent a more specific diagnosis.

A recorded, existing directory is not sufficient proof that it is still the
right workspace. Before switching, revalidate its nearest boundary, shared
repository key, and named inventory association; handle replacement directories,
permission errors, and races without silently selecting another repository.

A manually moved **current** workspace is a special case: jj can return its
current root while its inventory path is null. Return the root and inventory,
leave the current name unknown, and refuse operations requiring that name until
it can be validated. Do not infer it from a coincidentally matching commit ID.
User-directed recovery belongs to a separate, explicitly chosen workflow.

A stale working copy is different from an unavailable path. Read-only discovery
may inspect it using `--ignore-working-copy`, but must not call
`workspace update-stale`. Do not label all existing paths "fresh": this inventory
does not prove working-copy freshness. Action-specific stale handling belongs to
the corresponding core-operation design.

## Acceptance scenarios

These requirements must become plugin tests when the implementation is built:

- Colocated and non-colocated roots, their subdirectories, and linked workspaces.
- Multiple independent repositories, duplicate workspace names across repos,
  effective window/tab cwd, and external cwd changes without stale cached context.
- Nearest nested jj repository, nested Git-only `.git` directory/file boundaries,
  broken jj metadata, and invocation outside all repositories.
- Root-relative versus absolute paths, `../`, nonexistent creation destinations,
  symlink identity, similar prefixes, and paths containing whitespace/quotes.
- Machine-readable name/path/commit inventory independent of user display
  templates; errors on invalid output or unsupported capabilities.
- Missing/moved/unrecorded paths remain listed but cannot be entered; replaced
  directories or changed registrations are rejected at action time.
- Moved current workspace has an unknown name rather than a guessed identity.
- Stale working copies and unsnapshotted files are not modified by discovery.
- No Git fallback, remote calls, implicit path repair, or filesystem deletion.

### Reproducible capability checks

```sh
python3 tests/probes/discovery.py
```

Nine isolated CLI probes pass on jj 0.44.0 on Linux. They exercise normal and
colocated layouts, subdirectories, escaped paths and independent names, shared
metadata identity, independent repositories, relative-path bases, nested
boundaries, non-repository errors, moved/missing paths, unsnapshotted files, and
stale-workspace inspection. All mutations stay in an owned temporary directory;
no remotes are used. Python is a probe-only dependency, not a plugin dependency.

These are **jj capability checks, not Lua plugin tests**. Neovim cwd scoping,
frontend guards, error UX, symlink edge cases, legacy layouts, permission errors,
and concurrency remain implementation acceptance requirements above.

## Sources

- [Upstream discovery and paths](https://github.com/ThePrimeagen/git-worktree.nvim/blob/f247308e68dab9f1133759b05d944569ad054546/lua/git-worktree/init.lua)
- [jj WorkspaceRef templates](https://docs.jj-vcs.dev/latest/templates/#workspaceref-type)
- [jj workspace commands](https://docs.jj-vcs.dev/latest/cli-reference/#jj-workspace)
- Local `jj 0.44.0` help for `workspace list`, `workspace root`, global
  `--ignore-working-copy`, templates, and `config path`, plus the checked-in probes.
