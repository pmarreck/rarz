# Seed-44 corruption assessment, October 28, 2026

The first campaign with reference quick-open disabled found one RAR2 miss.
rarz detected 6,929 of 6,930 reference-confirmed damaged inputs. All 18
archive/profile pairs reached their fixed target of 385 eligible mutations and
the agreed 95% pointwise confidence with at most ±5-percentage-point uncertainty.
Pristine inputs passed both validators and their hashes remained unchanged.

The RAR2 sniper pair detected 384/385 cases, with a 95% Wilson interval of
98.54%–99.95%. The other 17 pairs each detected 385/385, with intervals of
99.01%–100%. These estimates are conditional on reference-confirmed damage in
these fixtures and profiles. They are neither pooled nor simultaneous claims
and do not establish coverage of every RAR feature.

| Outcome | Cases |
| --- | ---: |
| Reference-confirmed damage detected | 6,929 |
| Reference-confirmed damage missed | 1 |
| Reference-valid mutation accepted by both | 6 |
| Reference-valid mutation rejected by rarz | 0 |
| Inconclusive reference execution | 3 |
| Unverifiable rarz, no-op, or unchanged mutations | 0 |
| Total mutations | 6,939 |

The campaign exited 2 (`incomplete`) because of its inconclusive reference
results. All three were missing-volume errors (UNRAR exit 6), which remain
outside the confirmed-damage denominator. The reference invocation was
`unrar t -p- -idq -qo-`; the prior seed-43 campaign used the default quick-open
behavior and remains a separate historical result.

## Miss and reproduction

Case 214, sniper round 213, flips bit 3 at zero-based byte offset 12393 in
`rar2_v20_m3.rar`, changing `f5` to `fd`. The exact mutant SHA-256 is
`43d9c3f33b8a3733c22259b3657d8f3a86b342304361016ead15c367d5c58d57`.

UNRAR reports a checksum error for `text1.txt`. Its extraction produces 7,214
bytes, compared with 7,212 bytes from the pristine archive. rarz reports VALID
and emits exactly the pristine 7,212-byte prefix. The decoder clips an overlong
final match to the declared size, concealing the extra bytes before checksum
verification. This is a missed corruption even though the retained prefix is
unchanged. The persistent regression records this observed failure.

The subsequent decoder correction rejects overlong matches in buffered and
streaming sessions. Its exact-case replay and pristine controls passed, followed
by complete 471-unit/CLI/v70 acceptance and native macOS unit/package checks.
These regression results do not alter the campaign counts above.

## Evidence

The tested ReleaseSafe implementation and assessment scripts match commit
`c2cb48d`; their hashes identify the precommit build. This campaign predates
the subsequent VINT, Huffman, and decoded-size guards. Later regression results
must not replace its recorded miss or be counted as new statistical samples.

- [Per-pair counts, intervals, and tool identities](evidence/coverage-20261028-seed44.json)
- [Miss and three inconclusive replay records](evidence/coverage-20261028-seed44-cases.jsonl)
- [Tested source and executable hashes](evidence/coverage-20261028-seed44-candidate.sha256)
- [Assessment contract and sampling limits](ASSESS_COVERAGE.md)
- [Prior seed-43 campaign](COVERAGE_20261028.md)
