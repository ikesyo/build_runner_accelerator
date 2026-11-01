# ADR 0047: Experimental compiler dependency isolation

- Status: Experimental, opt-in
- Amends: ADR 0042 (compiler-only package copies)

## Decision

`BUILD_RUNNER_ACCELERATOR_EXPERIMENTAL_COMPILE_ISOLATION=1` opts into copying
four compiler packages into content-addressed workspace setup state. The
default remains disabled. This is an internal experiment, not a public 1.x
configuration guarantee.

The initial window is build_runner 2.16.1/2.16.2, Analyzer 14.5.0/14.6.0 and
dart_style 3.1.13/3.1.14 in a consumer workspace. Reject other versions and
unexpected source shapes before native actions; never silently ignore a failed
requested transformation. The accelerator's own package is copied too. Retain
each package's pubspec and license and never edit original packages or the
application's configuration/lockfile.

Separate unchanged parseFile/parseString implementations from Analyzer's
resolveFile/context factory. Re-export the parse APIs from their original
library; redirect known parsing consumers and replace a documentation-only
context import with a docImport. A builder using the full public API can still
bring its required implementations into compilation.

Remove the stock CLI import from the copied process adapter. Calling
ChildProcess.run in this mode writes a diagnostic to stderr and exits the worker
with an error, rather than starting stock build_runner. This intentionally
unsupported entrypoint cannot be caught by a builder and turned into successful
publication. Other process helpers retain their implementations. This is a
narrower experimental boundary, not a claim that private runner APIs are
generally interchangeable.

## Identity and lifecycle

Compose isolation after the existing legacy resolver backport. Publish complete,
validated source directories before atomically selecting the effective package
configuration. Include the transformed source identity in configuration identity
so manifests and AOT artifacts cannot cross default/experimental modes. Store
kernel configuration stamps as well; reject an unstamped kernel under the
experiment and a stamped kernel whose effective configuration changed.

Use separate default/backport and experimental compiler config selectors so
background prewarm in one mode cannot select the other mode's copies. Workers,
probes and prewarm restore original builder-visible package roots whenever a
compiler-copy config is present, including a retained experimental snapshot after
opting out. Source enumeration,
asset reads, analysis namespace and SDK-summary identity continue to use the
original application resolution. Logical compiler dependency keys resolve to the
current copied packages after workspace relocation. Damaged setup state fails
validation; disabling the variable restores the normal selector/backport path.
On Unix, a disposable validation receipt avoids rereading, transforming and
hashing source/copy contents when all recorded metadata is unchanged. Bind it
to the incoming resolution, canonical roots and transformation revision; check
files and directories using device/inode/mode/size plus nanosecond mtime/ctime,
including the selected config. Any change or missing/malformed receipt returns
to full validation. Capture metadata before validation and recheck it before
publishing the receipt. This assumes coherent Unix filesystem metadata and is
not an adversarial integrity mechanism. Other platforms retain full validation.
Worker AOT digest reuse is an independent default optimization governed by
[ADR 0005](0005-performance-and-validation-policy.md). It applies with this
experiment disabled as well; it is not part of the compiler-view flag.
Setup copies are disposable preparation state, including under --only-check.
Content-addressed snapshots remain for reuse until workspace state is cleaned;
the experiment does not add an automatic eviction policy for these copies.

Keep output/graph publication at the existing all-success boundary. No new worker
protocol operation, stock fallback or default worker-count policy is introduced.

## Evidence and limits

The [dependency investigation](../benchmarks/aot-cold-parse-isolation-2026-10.md)
records a one-pair isolated compile reduction of 32.135 to 31.302 seconds, with
1,294 to 1,107 source files. It does not establish a stable or end-to-end clean
speedup. Runtime preparation/copying is additional work absent from that probe.
A later three-pair runtime comparison, including preparation and launcher,
observed Clean medians of 37.977 s OFF and 37.296 s ON (1.8%) on the ten-model
fixture, with a roughly 52 ms no-op median increase. The overlapping ranges and
narrow workload support retaining the default-off experimental boundary.
Correctness checks must cover source preservation, ON/OFF transitions, output
equality and failure rollback before expanding the supported version window.
