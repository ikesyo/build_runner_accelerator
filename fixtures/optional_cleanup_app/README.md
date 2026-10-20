# Optional producer and cleanup fixture

Two optional builders map `.seed` → `.stage` → `.ready`. A normal consumer
writes `.final`. The post-process builder reads `.stage` and `.ready`, writes
receipts containing their bytes, and calls `deletePrimaryInput()`.

`build.yaml` uses source outputs. `build.cache.yaml` puts both optional producer
outputs in the artifact tree. `build.no_demand.yaml` disables the normal consumer.
`build.secondary.yaml` starts with a `.request` consumer that skips optional
reads, then activates the chain through a new secondary read.

Run the stock build_runner 2.16.2 comparisons with the same SDK and pub cache:

```bash
bash scripts/correctness_optional_cleanup.sh
bash scripts/watch_smoke_optional_cleanup.sh
```

The correctness script compares source files, cache asset membership, and cache
bytes across no demand, two-stage demand, new secondary demand, no-op, demand removal/restoration,
normal-output deletion, input edits, omitted outputs, stale-output removal,
rename, source deletion, and recovery from producer and cleanup failures.
On failure it checks that native outputs, cache, and graph retain their previous
committed bytes. Watch covers edits, producer failure/recovery, rename, deletion,
and recreation. Both scripts run in the compatibility-lifecycle suite.

Stock does not activate either optional producer when only cleanup matches its
declared outputs. When the normal consumer demands the chain, stock leaves the
producer files on disk after cleanup calls `deletePrimaryInput()`. Receipts
show that cleanup ran; the physical file comparison includes the producer files.

`CONFIG=build.yaml`, `CONFIG=build.cache.yaml`, `CONFIG=build.no_demand.yaml`,
or `CONFIG=build.secondary.yaml`
selects one correctness configuration. `STOCK_ONLY=1 KEEP_TEMP=1` retains an
isolated stock workspace and prints its path for inspection.
