# RAR2 embedded archive comments

An archive produced by the original RAR 2.90 passes UNRAR but previously failed
rarz with a header-CRC mismatch. RAR 2.x includes the embedded comment in the
main header's total size, while the main header checksum ends after its fixed
13-byte fields. The comment has its own header checksum and decoded-content
checksum. The producer's bundled TechNote.txt documents these boundaries.

The main-header CRC boundary is corrected for archives carrying this flag.
Validation also checks the nested comment's bounds, type, header CRC, decoded
size, and content CRC. Merely shortening the outer checksum would leave
corrupt comments unexamined. A real compressed-comment fixture supplies the
positive control; mutations of the outer header, nested header, and compressed
payload supply six negative controls. The matched archive without a comment
remains valid. File-level embedded comments and unqualified legacy compression
variants are outside this fixture's evidence.

## Producer and reproduction

The fixture producer is RAR 2.90, dated September 7, 2001. Its official
[Windows distribution](https://www.rarlab.com/rar/wrar290.exe) has SHA-256
`7c2e3ec5c5eccc01d38374f6ef317ae1e22ac84eac159a7ce37a4f9e1d9579f6`.
The extracted Rar.exe has SHA-256
`3f938b2f4cc13b9b85d61417b36af45a970dbee0e09e9d9e13f4e00350485112`.
Only generated test data is committed. No reference implementation source was
used for this diagnosis or correction.

Generation ran under Wine in a private prefix and filesystem namespace.
The payload contains 400 copies of `RAR2 independent embedded comment CRC control.`
with newlines. The comment is `Independent RAR 2.90 archive comment control.`
with one newline. Both input mtimes were fixed to January 1, 2026 at 00:00 UTC.

```sh
wine Rar.exe a -inul -m3 control.rar data.txt
wine Rar.exe a -inul -m3 -zcomment.txt comment.rar data.txt
unrar t -p- -idq -qo- control.rar
unrar t -p- -idq -qo- comment.rar
```

Both reference checks succeeded. The fixture hashes are recorded in the fixture
manifest. The comment archive's main header is 89 bytes, comprising 13 fixed
bytes and a 76-byte comment block; its declared decoded comment length is 46.

## Reference classifier finding

Flipping one bit at byte 45 corrupts the comment payload. UNRAR 7.20 prints
`The archive comment is corrupt` on stderr but exits zero, including with the
assessment's `-idq -qo-` flags. Five other header mutations return exit 3 with
that diagnostic. The assessment and legacy gate classifiers now recognize the
exact comment diagnostic at exit zero as damage. Crashes, timeouts, other exit
statuses, generic warnings, and filename/prefix lookalikes retain their existing
classification. Exhaustive exit-code sets and the actual producer mutation test
this rule.

This is a reference-classification change for future runs. Historical campaigns
retain their original outcomes and counts.

Complete integrated `./test` passed 473 unit tests, every CLI suite, and the
intact/two-corruption v70 controls. Runtime peak was 11,838,062,592 bytes under
the unchanged 16 GiB limit. Native macOS unit/package checks and the native
build also passed. The assessment adapter independently classified four exact
payload mutations as damaged despite reference exit zero; these regression
controls are not new statistical campaign samples.
