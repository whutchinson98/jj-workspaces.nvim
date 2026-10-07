# jj-workspaces.nvim

A planned Neovim plugin for jj workspaces, inspired by
[git-worktree.nvim](https://github.com/ThePrimeagen/git-worktree.nvim).

**Status: the 16 feature-design tasks are complete. The production Lua plugin is
not implemented yet.** This repository currently contains specifications and
isolated capability probes, not an installable Telescope extension.

## Design

The core design manages local workspaces by name, independently of bookmarks.
Explicit relative paths resolve from the active workspace root. Creation selects
an explicit parent and optionally switches; editor switching preserves unsaved
data. Forgetting removes registration only, never files. Automatic fetching,
tracking, publishing, rebase, and stale-workspace repair are intentionally omitted.

The planned core targets Neovim 0.11+ and jj 0.44+ with capability checks and no
Plenary dependency. Telescope remains optional. Those are support targets, not
claims that minimum-version or Telescope integration testing is complete.

| Order | Issue | Specification | Decision |
| --- | --- | --- | --- |
| 01 | HUT-94 | [Discovery and paths](docs/design/01-discovery-and-paths.md) | Adapt |
| 02 | HUT-109 | [Lua API and setup](docs/design/02-api-and-setup.md) | Adapt |
| 03 | HUT-108 | [Logging](docs/design/03-logging.md) | Adapt |
| 04 | HUT-107 | [Asynchronous operations](docs/design/04-operations.md) | Adapt |
| 05 | HUT-106 | [Lifecycle hooks](docs/design/05-lifecycle-hooks.md) | Adapt |
| 06 | HUT-99 | [Editor switching](docs/design/06-switching.md) | Adapt |
| 07 | HUT-100 | [Current-file continuity](docs/design/07-file-continuity.md) | Adapt |
| 08 | HUT-101 | [Jump history](docs/design/08-jump-history.md) | Retain, scoped |
| 09 | HUT-95 | [Workspace creation](docs/design/09-creation.md) | Adapt |
| 10 | HUT-102 | [Metadata-only forget](docs/design/10-forgetting.md) | Adapt; no file deletion |
| 11 | HUT-96 | [Remote policy](docs/design/11-remote-policy.md) | Omit automatic fetch/tracking |
| 12 | HUT-97 | [Publishing policy](docs/design/12-publishing-policy.md) | Omit autopush |
| 13 | HUT-98 | [Rebase policy](docs/design/13-rebase-policy.md) | Omit automatic rebase |
| 14 | HUT-103 | [Telescope listing](docs/design/14-telescope-list.md) | Adapt |
| 15 | HUT-104 | [Telescope creation](docs/design/15-telescope-create.md) | Adapt |
| 16 | HUT-105 | [Telescope forget](docs/design/16-telescope-forget.md) | Adapt; confirm, no force |

[Linear project](https://linear.app/hutchery/project/jj-workspace-nvim-b13c0a2e9724)
contains the dependency graph, upstream evidence, and commit references. Each
completed task has its own atomic jj commit pushed to `main`.

## Capability probes

Requirements: Python 3.9+, jj, and Neovim for the editor checks. Validated on Linux
with **jj 0.44.0 and Neovim 0.12.5**. No third-party Python packages or Neovim
plugins are needed.

```sh
python3 -B tests/probes/discovery.py
python3 -B tests/probes/workspaces.py
nvim --headless --clean -l tests/probes/editor.lua
```

These run 9 discovery tests, 8 workspace-operation tests, and 15 counted editor
assertions (plus setup/sanity guards). Fixtures use unique owned temporary
directories and no remotes. They verify underlying CLI/editor behavior, including
partial creation failures and file-preserving forget. They **do not** exercise a
production plugin, Telescope, or every supported version/platform.

## Next phase

Implement the contracts in dependency order with Lua unit/integration tests and
minimum-version CI. Each specification distinguishes verified capabilities from
implementation acceptance requirements. Do not mistake a completed design issue
for shipped plugin functionality or carry upstream bugs forward as compatibility.
