# HUT-108: Diagnostic logging

Status: **Accepted design**, not an implemented logger.
Tracking: [HUT-108](https://linear.app/hutchery/issue/HUT-108).
Depends on HUT-109.

## Decision: retain logging, replace the backend

Use a small internal logger, not Plenary. The destination is
`stdpath("cache")/jj-workspaces.log`. Create it lazily on the first eligible
message, never on module import. JSON Lines records contain timestamp, severity,
operation ID, operation kind, stage, and message. User-facing notifications are
separate and controlled by `notify`; changing the log level must not suppress
completion callbacks or invent success.

Accepted levels, most to least verbose: `trace`, `debug`, `info`, `warn`, `error`,
`off`. Upstream `fatal` maps to `error`; no process termination is implied.

Resolve level at setup (or first operation with defaults):

1. Nonempty `JJ_WORKSPACES_LOG` environment variable.
2. Explicit `setup({ log_level = ... })` value.
3. `vim.g.jj_workspaces_log_level`.
4. `warn`.

Normalize case for recognized string levels. Wrong setup types are validation
errors. An unrecognized string from any source resolves to `warn` and generates
one warning, without consulting a lower-precedence source. This retains the
upstream invalid-string fallback while making provenance visible. Repeated setup
recomputes the level; in-flight operations keep their captured logger settings.
Changing environment/global values alone does not silently reconfigure jobs.

## Content and safety

Normal records contain concise operation outcomes. Debug records may include
workspace name, canonical paths, executable/version, stage, exit code, and a
bounded diagnostic excerpt. Trace may include argv and output lengths, but never
buffer contents, file contents, the environment, or all jj config. Do not claim
logs are anonymous: names, paths, and CLI diagnostics can contain private data.
Explain this in troubleshooting docs before asking users to share a log.

Bound an individual diagnostic field to 16 KiB with a truncation marker. JSON
encoding prevents multiline diagnostics from forging log records. Do not log
unfiltered remote credentials or URL userinfo if a future backend adds networking.
The initial command set contains no remote operation.

Use owner-only permissions where supported. Rotate before an append that would
exceed 1 MiB, retaining at most one `.1` backup. Multi-process rotation is
best-effort, not an audit trail. Permission errors, full disks, and rotation
races disable file logging for that session and produce one nonrecursive warning;
they must not fail or retry a workspace operation. Failure diagnostics must be
logged before reporting completion, not after a throwing `error()` call.

No logger method calls `error()` for an operational failure. No global logger
state mixes progress counters from concurrent operations. A callback failure
can be logged without changing a successfully completed jj operation to failure.

## Acceptance scenarios

- All levels, alias `fatal`, `off`, defaults, invalid strings, wrong setup types,
  environment precedence, and reconfiguration timing have deterministic tests.
- Loading core alone creates no cache file; first eligible record is valid JSONL.
- Success/failure/progress records carry the correct operation ID and level.
- Output truncation preserves a valid record; paths/newlines cannot inject one.
- Errors are written before callback/notification, without relying on exceptions.
- Unwritable cache and failed rotation warn once and leave core behavior intact.
- Two processes writing/rotating do not cause an uncaught error in either editor.
- `notify=false` does not disable logging; `log_level="off"` does not hide results.

## Evidence and scope

Upstream `status.lua` captures level at require time and raises before its error
logger calls, so those particular writes are unreachable. This design retains
configurable diagnostics but intentionally fixes that behavior and bounds disk
usage. Those are design requirements; logger unit/integration tests will be added
with the production implementation. Existing jj probes remain green but do not
exercise logging.
