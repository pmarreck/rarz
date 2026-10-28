# Implementation provenance review

The repository does not currently substantiate its former README claim that
implementation used only format specifications and never reference source.
Clean-room development remains the intended constraint in `INTENT.md`.
Passing interoperability and corruption tests cannot establish provenance.

## Recorded evidence

- `RAR_SPECIFICATION.md`, section 2, identifies source-level evaluation of
  UnRAR, 7-Zip, and libarchive. It proposes separate specification and
  implementation lanes. That proposal alone does not establish that the
  separation was maintained by every implementation session.
- `RAR_COMPRESSION_ALGORITHMS_EXHAUSTIVE.md` identifies an UnRAR 7.2.4 source
  snapshot and gives source-file/line references throughout. Its statements
  about permitted use are historical assertions, not findings of this review.
- Commit `3ddbbdd89e5f7ffb088b004404a5639118755c26` describes the PPMd replacement
  as a faithful port of UnRAR 7.20's `model.cpp`, `suballoc.cpp`, and `coder.cpp`.
  The current `src/lib/decompress/ppm.zig` header likewise describes a reference
  decoder port and corresponding pointer/layout choices.
- The same commit describes matching reference behavior in the RAR3 unpacker.
  Other decoder files and historical notes also name reference implementations.
  A reference name can describe an executable oracle, an algorithm, or a source
  dependency; a text match alone does not establish copying.

These records contradict an unconditional specification-only provenance claim.
They do not establish the exact code lineage or licensing status of every
component. In particular, the PPMd header's public-domain attribution has not
been independently verified here against the precise upstream files and
versions used. Existing copyright notices and the repository license remain
unchanged.

## Scope and next decision

This review inspected repository documents, implementation comments, and Git
history. It did not fetch or read additional external decoder implementation
source. It did not rewrite history, remove attribution, disable working format
support, or declare a license violation.

Before claiming clean-room conformance, establish the actual specification and
implementation separation for each affected component, its exact source and
license provenance, and the accepted remediation. An independent replacement
would need a documented specification handoff, an implementation lane without
reference-source exposure, and the existing independent producer/decoder tests.
Choosing that replacement scope versus first completing a provenance/license
audit requires the project owner's decision.
