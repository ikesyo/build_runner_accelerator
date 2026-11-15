# ADR 0053: Session asset-id interning for batch and resolver-reset messages

- Status: Accepted
- Date: 2026-11-15
- Extends: ADRs 0003, 0051 and 0052

## Decision

A payload census of the single-visibility benchmark profile (16,384
actions) found that asset-id strings are about 48% of all JSON the native
frontend sends to the worker: 3.88 MB raw in 114,688 occurrences per clean
build, drawn from a unique universe of only 24,576 ids (0.8 MB). The same
ids recur across `build_batch` blocked lists, request inputs and outputs,
`reset_resolver` source/cache lists, and the overlay blob index, whose
keys repeat the `updated_cache` set verbatim.

Advertise `asset-id-interning-v1`. When the worker advertises it, the
native client keeps a per-connection ordered dictionary of asset ids and
may send `build_batch` and `reset_resolver` messages in interned form:

- The message carries `asset_dict_add`, a list of ids appended to the
  connection dictionary, in order, before any other field of the message
  is interpreted. Its presence marks the message as interned; it may be
  empty when the message introduces no new ids.
- Id positions carry dictionary indexes (JSON integers) instead of
  strings: `blocked_assets`, request `input` and `allowed_outputs` in a
  batch, and the four source/cache lists in a resolver reset. The overlay
  blob `index` keys, which JSON requires to be strings, carry the decimal
  form of the index.
- The worker resolves indexes while decoding, so the decoded batch and
  reset are identical to the string form, including all existing
  validation. A reference outside the dictionary, a non-integer where an
  index is required, or a malformed `asset_dict_add` is a protocol error.

The dictionary has the same lifetime as the ADR 0051 visibility cache:
initialization clears it on both sides; build and resolver resets and
single or nested builds leave it intact. The client appends additions
when a message is sent and never rolls them back; a worker that accepted
the message has applied the same additions during decode, and a decode
failure is a protocol error that ends the connection, so the two sides
cannot diverge on a live connection. Workers without the capability
always receive the string form.

Single `build` messages and asset RPC traffic keep the string form: the
census showed no asset ids in this profile's asset responses, and the
lazy single-build path is comparatively rare and small. Interning them
can be added later under the same capability without a new negotiation.

No graph format, scheduler policy, output publication or build_runner
behavior changes. The capability is an optional transport optimization
within the existing protocol v1 framing.
