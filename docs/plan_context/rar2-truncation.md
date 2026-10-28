# RAR2 partial final headers

The three accepted suffix deletions in the October 15 campaign end at bytes
11,997, 12,138, and 12,400. The next file headers begin at offsets 11,991,
12,136, and 12,396, leaving 6, 2, and 4 bytes of a seven-byte base header.
`BlockIterator.next` returned end-of-input for those short headers, so both
structural and payload validation silently stopped before observing damage.

A persistent iterator test covers all six incomplete lengths, a complete base
header, and clean EOF. It failed with 451 other unit tests passing. The CLI
regression covers all 18 partial-header cuts at the three affected boundaries;
every cut was accepted by rarz and independently rejected by UNRAR before the
fix. It also proves both validators accept the pristine fixture and prefixes
ending exactly at those complete-file boundaries.

The correction returns `EndOfData` for a nonempty incomplete base header.
Exact EOF remains valid, preserving vintage RAR archives without an ENDARC
block. No new terminal marker requirement is imposed. The October 15 campaign
report remains historical evidence; its counts are not rewritten after a fix.
Complete `./test` passed on October 27, 2026: all 452 safety-checked unit tests,
every CLI suite, and the pristine/two-mutation v70 gate. Runtime peak was
11,837,755,392 bytes. This establishes `rarz t` and iterator behavior. The FFI
collection paths still swallow parser errors; their verification consequences
are a separate queued regression and are not claimed fixed here.
