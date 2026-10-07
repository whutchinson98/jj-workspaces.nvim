# jj-workspace.nvim

Inspired by [git-worktree.nvim](https://github.com/ThePrimeagen/git-worktree.nvim) but for working with jj vcs.

## Design decisions

This project is in the design stage; the Neovim plugin is not implemented yet.

- [HUT-94: Repository discovery and workspace paths](docs/design/01-discovery-and-paths.md)
- [HUT-109: Lua API, setup, and dependencies](docs/design/02-api-and-setup.md)

The remaining decisions are recorded in numbered documents under
[`docs/design/`](docs/design/), in task order. These specify the future plugin;
capability probes are not plugin implementation tests.

Run the isolated discovery capability probes (Python 3.9+ and jj required;
validated with jj 0.44.0 on Linux):

```sh
python3 tests/probes/discovery.py
```
