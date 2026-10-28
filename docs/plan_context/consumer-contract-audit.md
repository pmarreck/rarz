# Consumer verification and resource audit

This review compares rarz's published C contract with Validate's current
adapter at commit `3a9c10c6b3916309209ed7d7e4716b599e2c6e7e`. The inspected
consumer files were unmodified. It is a source/contract review, not a new
consumer test-suite result. Historical notes about a Zig-only consumer no
longer describe that adapter: it now imports `rarz.h` and calls the C API.

## Verification evidence

| Case | Published C contract and implementation | Consumer treatment and limit |
| --- | --- | --- |
| No stored checksum | Decoded size is checked; `RARZ_VERIFY_NO_CHECKSUM` contributes to the separate no-checksum count and incomplete status. | The adapter preserves the count and maps incomplete verification to an indeterminate result. |
| Unsupported filter or failed decode | `RARZ_VERIFY_UNSUPPORTED` is distinct from a checksum mismatch. The existing API groups unsupported decoding and corrupt undecodable streams here. | The unsupported count survives the public mapping; this does not establish damage or a specific unsupported-filter reason. |
| Encrypted file content | Encryption is an entry property alongside an unsupported result. The single-volume path records it without decoding ciphertext. | The inspected consumer preserves unsupported counts but omits the separate encryption count from its public summary. The volume-open path required a direct API regression after the CLI's own guard concealed a missing property. |
| Service, quick-open, or recovery data | File-entry verification and its accounting invariant do not enumerate or hash all ancillary payloads. | A `full` result derived from verified file entries must not be interpreted as every-byte service/recovery coverage. Header checking does not close this gap. |

`rarz_verify_archive` retains the sum of verified, damaged, unsupported,
no-checksum, error, and directory counts. Validate checks that accounting
invariant before mapping the result. Its incomplete/error paths remain
indeterminate. This supports retaining the existing per-entry ABI while
resolving ancillary-payload evidence separately. The deferred three-dimension
redesign is not required merely to describe these current limits.

The older Zig `policy.ValidationResult` and CLI `t` surface have different
semantics and less complete evidence. `is_valid` alone must not be read as
equivalent to the C archive verification summary. In particular, the policy's
unverified count currently describes encrypted skips, not every missing
checksum or unsupported decode.

## Resource admission

The consumer's `src/core/admission_estimate.zig` already documents the RAR3
PPMd model heap of up to 256 MiB, which is declared inside the compressed
stream and is absent from `rarz_max_dictionary_size()`. It keeps a generic
pre-open estimate and describes two-phase admission as future work.
There is no implemented exact PPM reservation contract in those inspected
paths. The consumer's RAR file header comments still describe dictionary-only
residency more strongly than this known limit supports.

There is another explicit term in the current C multi-volume verifier:
compressed parts are assembled into a contiguous packed-data buffer before
streaming decoded output. Its memory requirement can therefore include packed
entry size as well as the dictionary, PPM model, and fixed state. Output
streaming does not establish bounded packed-input storage.

A consumer admission agreement must account for these terms or report a
resource-limited incomplete result. Coordinating that agreement remains open;
this audit changes no consumer policy, verdict, ABI, or resource limit.
