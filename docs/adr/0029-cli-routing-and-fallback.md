# 0029: CLI capability routing and lossless stock fallback

Status: Accepted

## Context

The launcher kept stock arguments only in its Dart lane. Selecting native
could silently discard a build filter or other user request; later manifest
fallback reconstructed only the command and added a deletion flag. Unsupported
commands still attempted binary resolution. Fallback failure became status 1,
and native watch could resume watching after stock watch exited.

The supported build_runner window is >=2.16.2 <2.17.0. Its
`delete-conflicting-outputs` / `-d` flag is retired and does not control deletion.
Stock automatically handles conflicting outputs. Native stages replacements and
missing-output deletion until all actions succeed; that transactional failure
contract remains unchanged.

## Decision

CLI capabilities form a boundary independent of manifest capabilities.
Auto uses native only for fully supported CLI requests, then validates the
manifest. Rust rejects unsupported CLI or manifests. Dart runs stock.
Unsupported CLI routes before downloads, workspace loading, and manifest
creation. Stock owns validation of unknown options, stock values, positional
build directories and command-specific syntax, and its status is preserved.
Invalid accelerator values fail in every mode.

Accelerator options are stripped; stock argument spelling, order, values and
`--` are retained. Native receives the complete stock invocation as an internal
JSON argument vector, alongside its supported options, so late fallback cannot
lose compile-mode or stock flags. On Unix late fallback execs stock. Other
platforms wait for stock and propagate its status; they never restart native
watch after stock terminates.

The native addition in this change is acceptance of the retired deletion flag
and its alias for build/watch, with precisely its stock non-operational meaning.
No invocation auto-adds the flag. Build filters remain unsupported: correct
implementation requires demand-driven dependency builders, multiple/package/asset
filters, preserving previously built unrelated outputs and incremental/watch
behavior. Merely filtering Rust actions or accepting a string is insufficient.
Release, config, define, output, workspace, logging, and output-preservation
options likewise remain on stock. The README table is the public scope.

Leading help/version describe the accelerator. Command-level help/version are
stock requests. Accelerator parsing stops at `--`. Prewarm and its alias retain
their no-op Dart/unavailable-auto contract but reject stock-only arguments.
Aot-cache-key remains a native-only utility, never a fabricated stock command.

Direct stock execution on Unix uses a small source/AOT launcher re-entry that
creates a session and execs the selected Dart command. This preserves its PID,
argument vector, stdio and status while allowing launcher-only Ctrl-C to reach
the inner stock build process. Shutdown is bounded to five seconds.

Unix native invocations supervise a subprocess group. Ctrl-C/termination
forward to all children with a bounded five-second grace period and cleanup;
Ctrl-C returns 130. Internal AOT helpers inherit the same supervisor context;
only explicit detached prewarm starts a separate session. Successful exits allow intentional
background AOT compilation to finish; cancellation and failures clean the whole
internal subtree. Windows uses a kill-on-close job for native subprocess-tree
cleanup and forwards console interruption to the child group. Platform execution still
requires Windows CI validation.

## Consequences and validation

Full stock CLI compatibility is not a release criterion for this change.
Users can trust that supported flags have their documented meaning and that
unsupported requests are handled as a whole by stock, or rejected in rust.
Clean is a stock operation and does not clean native caches (their graph
formats are independent).

Launcher/Rust parser regressions cover capability routing, stock option values,
separators, compile flags and malformed accelerator inputs.
`scripts/correctness_cli.sh` compares stock/native conflict handling with flag
omission, long spelling and alias, chained builders, zero-output deletion,
no-op, incremental and watch; it also checks early/manifest fallback, unknown
options, stock help/errors, exit codes and Ctrl-C. Existing full compatibility
fixtures cover deletion, rename, failure, optional builders and watch.
