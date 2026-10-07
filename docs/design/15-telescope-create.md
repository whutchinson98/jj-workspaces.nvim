# HUT-104: Telescope interactive creation

Status: **Accepted design**, not an implemented interactive flow.
Tracking: [HUT-104](https://linear.app/hutchery/issue/HUT-104).
Depends on HUT-95 and HUT-103.

## Decision: select a parent, then name and locate a workspace

```lua
require("telescope").extensions.jj_workspaces.create_workspace(opts)
```

Retain upstream's picker-plus-prompts workflow, but replace Git branch creation
with explicit jj parent selection. Workspace name, destination, and parent are
separate inputs; no remote, tracking, push, rebase, or bookmark-creation prompt.
The core creation contract is authoritative and performs all final validation.

## Interaction

1. Capture the origin context as in the listing picker. Load a bounded, read-only
   candidate set using an explicit jj log JSON template, not Telescope's Git
   branch builtin. Initial suggestions include `@` and local bookmarks, at most
   100 distinct commits, with full IDs retained and short ID/description/bookmark
   labels displayed. Query failure is reported, not presented as "no revisions".
2. Provide a clearly labeled **Current workspace (@; snapshot at creation)**
   choice. This submits literal `@`, allowing the documented disk snapshot at
   submission time. Other selected entries submit full commit IDs, pinning the
   displayed revision even if a bookmark moves while prompts are open.
3. Enter selects a candidate. When no candidate is selected, nonempty prompt text
   may be submitted as a revision expression. Ctrl-R explicitly uses the prompt
   text even when a filtered candidate is selected; document it in picker help.
   Empty free text is rejected rather than accidentally choosing `root()` or a
   new branch. A typed expression is evaluated by core at submission, not assumed
   to be a filename or passed to a shell.
4. Close the revision picker and request **Workspace name** using asynchronous
   `vim.ui.input`. No default name is inferred from arbitrary revision text.
   Nil means cancel; empty name is invalid with a chance to correct it.
5. Request **Workspace directory**, showing the absolute omitted-path default
   from HUT-95 (configured base or sibling). Empty input accepts that default;
   nil cancels. If the name cannot safely form a directory component, require
   an explicit path instead of suggesting a sanitized one. Relative overrides
   still use the source workspace root, not the displayed default base.
6. Revalidate origin and submit exactly one core create request in that origin's
   window context, with automatic switch enabled. Core validates single revision,
   existing/duplicate paths, unsaved buffers, and registration races.

Prompts may be overridden by a UI plugin; never use blocking `vim.fn.input` or
wait on the main loop. The flow has one per-invocation generation/token. Late
prompt callbacks after cancellation/replacement must do nothing. Opening another
flow does not share its draft name, path, or parent. The mutation lock is acquired
only when core creation is submitted, not while a user thinks at a prompt.

## Failures and options

If origin cwd/buffer/window changed while the picker/prompts were open, stop with
`context_changed`; do not create in a new repository or switch a different
window. Canceling at any pre-submit step has zero mutation. After submission,
closing a UI does not erase or retry a pending operation; report its final result
without reopening the picker or stealing focus.

A create-success/switch-failure result must show the created name/path and explain
that it already exists; offer textual guidance to switch later, not an automatic
second create. An incomplete add shows the core partial/unknown diagnostic and
never offers implicit deletion. No remote retry or history repair occurs.

Telescope layout/sorting/theme and `attach_mappings` options follow HUT-103 and
are not overwritten in place. `opts.cwd` chooses a context with the same origin
checks. Other core-creation variants, including `switch=false`, remain available
through the Lua API rather than adding an unbounded prompt/configuration surface.

## Acceptance scenarios and scope

- Selected candidate, current-state special entry, typed single revision, missing,
  ambiguous/multi-result input, and bookmark movement have explicit semantics.
- Name/path are independent; configured/default/explicit destinations follow the
  same core rules, including complex names and root-relative paths.
- Nil versus empty input differs correctly at each prompt; cancel and stale UI
  callbacks invoke no create. Duplicate submit invokes it at most once.
- Origin context changes, modified buffers, invalid paths, and runner busy/errors
  surface without focus theft, partial-state deletion, or hidden retries.
- Caller options/mappings are preserved; no Git builtin, network call, branch
  creation, synchronous input, or implicit revision repair is introduced.

The jj create probes establish parent/path capabilities. Telescope interactions,
`vim.ui.input` overrides, cancellation races, and frontend/core integration are
specified acceptance tests, not exercised by the current capability probes.
