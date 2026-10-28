# RAR5 file versions

RAR archives created with `-ver` keep prior revisions in file-version extra
records. The base header can store the same name for every revision. Treating
that base name as the extraction name overwrote the historical revisions.

The parser now retains the version number. The single-archive and multi-volume
C APIs expose historical names as `name;N`, with decimal version numbers; the
current unversioned entry retains its base name. Generated names live in the
archive handle's arena and remain valid until close. Input bytes remain
read-only, and the C struct layout is unchanged. Split parts must match both
the base name and version before they can be merged.

rarz continues to extract all enumerated entries. For versioned archives this
matches UNRAR's `x -ver` output. UNRAR's default extraction selects only the
latest revision; version selection flags are outside this change.

Before creating output, the CLI checks the complete normalized name set.
Duplicate file destinations, including a literal `name;N` colliding with a
historical revision, cause extraction to fail before writing files. Repeated
directory entries remain allowed. Names exceeding the existing extraction
buffer or containing embedded null bytes are rejected instead of truncated.
This comparison follows the CLI's existing separator normalization; it does
not establish protection against every filesystem alias, case-folding rule,
symlink, or pre-existing destination. Those require separate path-policy work.
Integrity validation and enumeration remain available for colliding archives.

Independent RAR 7.20 store/compressed controls retain three revisions and compare
the complete extracted tree with UNRAR `-ver`. Collision fixtures append an
unchanged file block from a separate literal-name producer archive. UNRAR with
quick-open disabled confirms both colliding names and intact contents before
the extraction-refusal assertion. Adding the literal name with RAR itself
replaces the historical entry, so it cannot establish this test case.
C API controls cover absent, zero, one, multibyte, and
maximum unsigned version numbers through both open functions, and verify that
the archive bytes remain unchanged. Record tests cover missing fields and
prevent borrowing a following record's bytes. A split-part control distinguishes
matching from differing versions; removing the version comparison makes it fail.

References are the [RAR5 version-record specification](https://www.rarlab.com/technote.htm)
and the RAR 7.20 distribution's `rar.txt` description of `-ver`.

Acceptance on 2026-10-28 passed all 489 unit tests, every CLI suite, the v70
corpus/mutation gate, native macOS unit/package checks, and `./build`.
