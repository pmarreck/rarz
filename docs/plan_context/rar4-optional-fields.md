# RAR4 optional fields and record bounds

RAR4 file parsing previously read fields past the declared header boundary,
ignored salt and extended times, and advanced across unavailable payloads.
Three persistent framing tests reproduced those errors. Independent salt and
extended-time truncation tests then reproduced the missing field checks.

The iterator now confines field reads to the header and checks payload size
against remaining input before adding offsets. Unknown record types retain
forward-compatible traversal within those bounds. A header-only large-file
unit control still proves both 32-bit size halves are retained; traversal
correctly rejects its absent multi-gigabyte payload.

The first integrated run caught an existing reference-accepted exception:
per-file verification tolerates a shortened optional ENDARC body. A dedicated
unit regression failed before narrowing the new bounds check. The iterator now
returns that terminal record with its original declared size while stopping at
actual EOF. It never reads missing bytes. Whole-header CRC validation still
rejects the missing body; per-file enumeration can retain its established
behavior. Incomplete base headers and required file fields remain errors.

The parser retains an optional eight-byte salt and four optional extended times
(modification, creation, access, archival). Each time retains its DOS calendar
value, odd-second correction, and fractional value in 100-nanosecond units.
No timezone is invented. The additive C metadata API continues to expose the
base RAR4 time; this parser change does not promise extended-time restoration.
Service/comment payload verification remains separate work.

RARLAB's [RAR 4 technical note](https://sources.debian.org/src/rar/2:4.0.b3-1/technote.txt/)
defines header/payload sizes and the optional salt and extended-time flags.
Fractional-width expectations were additionally checked using UNRAR 7.20:
zero through three stored bytes yielded 0, 117964800, 123443200, and 123456700
nanoseconds for controlled versions of the same producer header. All four
archives passed the independent reader's content test. The four-position,
16-nibble test covers presence, odd seconds, width, and every required-byte
truncation. Raw unknown future trailing fields remain tolerated.

## Independent fixture

`tests/fixtures/rar4_extended_times.rar` was created with RAR 6.21 from nixpkgs
commit `205fd4226592cc83fd4c0885a3e4c9c400efabb5`. Its SHA-256 is
`998e8f17fd0852c907a119e3fd27945333332b7ab649b82e1ade9aa9738d33de`.
The producer ran with `TZ=UTC0`, `LC_ALL=C`, and umask 077 in disposable,
filesystem-confined scratch. With that producer available as `rar`, the inputs
and command were:

```bash
printf 'independent optional-field control\n' > data
touch -m -d @951782401.1234567 data
touch -a -d @951782403.7654321 data
rar a -ma4 -m0 -idq -tsm4 -tsa4 fixture.rar data
```

UNRAR independently reports modification time `2000-02-29 00:00:01.123456700`
and access time `2000-02-29 00:00:03.765432100`. The fixture contains stored data,
so payload decoding cannot conceal a header interpretation error. Existing
compressed, encrypted, split-volume, and legacy producer fixtures remain
required controls. The reference was used as an executable oracle; no reference
implementation source was consulted for this change.

## Acceptance

After correcting the optional ENDARC regression, the complete `./test` run
passed 501 unit tests, all CLI suites, the Windows emulation gate, and the
bounded large-archive corpus. Native macOS ARM64 unit/package checks and the
optimized `./build` also passed. These checks do not establish native Windows
or Linux ARM64 runtime qualification.
