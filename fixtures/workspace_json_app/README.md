# JSON workspace fixture

Two Pub workspace members use JSON Serializable and source_gen combining and
part-cleanup builders. `scripts/correctness_workspace_json.sh` compares stock
and native clean, no-op, edit, delete, rename, and failure recovery behavior.
