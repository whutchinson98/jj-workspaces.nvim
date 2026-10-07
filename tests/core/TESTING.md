# Core tests

From the project root, with `nvim` and `jj` on PATH:

```sh
nvim --headless --clean -l tests/core/run.lua
```

No external plugins or Python are required. The entry point sets runtimepath to
the project, isolates jj configuration, creates uniquely owned temporary
repositories, and removes only its own fixture directory on success or failure.
It never invokes mutating jj commands in the project checkout.

- `run.lua`: actual public API integration, configuration, discovery, creation,
  parent verification, metadata-only forget, callbacks, and lifecycle events.
- `editor.lua`: window/tab scoping, focus, context races, dirty buffers, symlinks,
  directory fallback, jumps, stale workspaces, and moved current workspaces.
- `faults.lua`: runner fault injection alongside real jj commands, a real killed
  subprocess, incomplete native add, uncertain forget, lock release, immutable
  configuration, and logging.

Validated locally on Linux with Neovim 0.11.0 and 0.12.5, both using jj 0.44.0.
Other platforms remain unverified. The timeout executable fixture uses Linux
`/usr/bin/env -S`; the production runner does not use a shell or that fixture.

External processes can race with the plugin: identity and registrations are
revalidated, but there is no cross-process editor/repository lock. Interrupted
mutations deliberately return conservative `unknown`/`partial` results and never
roll back, delete workspace files, repair stale state, or retry automatically.
