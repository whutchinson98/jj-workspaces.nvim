# Telescope extension: usage and runtime tests

The implementation lives entirely in `lua/telescope/`. Telescope and Plenary
are optional for the core, but required to load this extension. Target runtime:
Neovim 0.11+, jj 0.44+, Telescope with its Plenary dependency.

```lua
require('telescope').load_extension('jj_workspaces')
local extension = require('telescope').extensions.jj_workspaces
extension.workspaces({})
extension.create_workspace({})
```

## Interaction and options

- Workspace picker: Enter switches; Ctrl-D in normal/insert mode asks to
  **forget registration, keeping files**. Cancel is the first/default choice.
  Missing paths remain visible and may be forgotten, but cannot be switched to.
  Core enforces current/active workspace, unsaved-buffer and repository guards.
- Parent picker: Enter chooses a candidate, or uses nonempty prompt text if
  nothing matches. **Ctrl-R uses the typed expression even if a candidate is
  selected.** `@` is explicitly labeled snapshot-at-creation; other candidates
  retain full commit IDs, independent of subsequent bookmark movement.
- Parent suggestions come from an asynchronous, bounded, read-only jj log of
  `@` and local bookmarks, with up to 100 distinct commits. Capability/query
  errors are shown rather than disguised as an empty revision picker.
- Name and directory use asynchronous `vim.ui.input`. Nil cancels any stage;
  an empty name asks again. Empty directory input **omits `path`**, leaving the
  configured default entirely to core. Relative paths are source-root-relative.
  Automatic switch is enabled; other creation variants belong to the core API.
- The directory prompt deliberately does not invent an absolute default: core's
  configuration is not public. Likewise, the revision query uses `jj` on PATH,
  or the extension-only `jj_command` option. If core uses a custom executable,
  pass that same executable explicitly here; no private core module is read.
- Standard Telescope layout, theme, sorter and path-display options are copied,
  never modified in place. `attach_mappings` runs after extension mappings and
  its boolean return retains Telescope's semantics. Previewing and picker caching
  are disabled: resuming cached operation state would reuse stale context.
- Extension API options are `cwd` (absolute repository override), `scope`
  (core switch scope), `on_complete(result)` (submitted mutation completion),
  `jj_command` (revision-query executable, not shell text), and
  `revision_timeout_ms` (positive integer, default 30000). They are not forwarded
  as Telescope options. Core create-only fields are not picker prefill options.
- Each call returns a cancellation function, including during discovery/loading.
  Opening a replacement flow invalidates earlier UI callbacks. Cancellation never
  rolls back or retries an already-submitted mutation; its completion still runs.
  Error/partial/unknown outcomes remain visible even with core notifications off.
  If core notifications are also enabled, errors may be reported by both layers.

Invocations must originate in an editing window, not a prompt buffer. Window,
tab, cwd, buffer and repository identity are checked before submission. A
changed context cannot redirect an operation into another window or repository.
A UI provider that closes/replaces the original workspace picker also cancels its
pending forget confirmation: a late affirmative response cannot mutate anything.
Providers must leave that picker alive to complete a confirmation. This follows
Telescope's own close/BufLeave lifecycle rather than overriding its autocmds.

## Run the integration suite

Run from the repository root. Dependencies are not installed or downloaded by the
suite. Point the optional environment variables at existing checkouts (or make
Telescope and Plenary available through the runtimepath yourself):

```sh
TELESCOPE_DIR=/path/to/telescope.nvim \
PLENARY_DIR=/path/to/plenary.nvim \
nvim --headless --clean -l tests/telescope/run.lua
```

This uses **real Telescope pickers, action mappings, selection, windows,
refreshes and close autocmds** with a deferred mock of the public core API. It
also runs a real jj JSON candidate query against a disposable repository. It
covers normal/insert mappings, caller composition, origin capture and changes,
empty/unavailable selections, exact names, escaped display/search, cancellation,
duplicate/late callbacks, replacement generations, pending requests, refresh
failure/closure, pinned and typed revisions, default-path omission, asynchronous
query errors/output bounds, and exception cleanup. Tests never run mutating jj
commands against this project or configure remotes.

Additionally run the real-core end-to-end test:

```sh
JJ_WORKSPACES_REAL_CORE=1 \
TELESCOPE_DIR=/path/to/telescope.nvim \
PLENARY_DIR=/path/to/plenary.nvim \
nvim --headless --clean -l tests/telescope/run.lua
```

That test uses real core APIs, Telescope and jj in an owned temporary repository.
It creates using `@` with disk edits made **after** opening the picker, verifies a
new child and automatic switching, switches back, forgets with confirmation,
refreshes the live picker, and checks that dirty files and `.jj` remain intact.

## Recorded local validation

- Neovim 0.11.0 and 0.12.5; jj 0.44.0; Linux.
- Telescope `40aedd8a68c78a656a10a8d62d80c54af59420fb`.
- Plenary `74b06c6c75e4eeb3108ec01852001636d85a932b`.
- Base suite: 28 tests. With real-core integration: 29 tests.
- Local dependency paths: `/home/hutch/.local/share/nvim/lazy/telescope.nvim`
  and `/home/hutch/.local/share/nvim/lazy/plenary.nvim`.

Additional Telescope versions, non-Linux platforms, and third-party UI providers
are not yet integration-tested. Mocked asynchronous
UI callbacks exercise cancellation and duplicate delivery, but do not claim
coverage of every provider's focus/close behavior. The suite requires jj on PATH;
missing Telescope/Plenary produces an actionable failure, not a passing skip.
