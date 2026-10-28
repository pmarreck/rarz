# Toolchain refresh and independent producer

The root nixpkgs input moves from revision
`d1c15b7d5806069da59e819999d70e1cec0760bf` to
`f05535a0efcb2134c478d1e88434fadf486d42b5` (October 27, 2026).
The Zig overlay and corruption-reader pins remain unchanged.

The reference versions change from RAR/UNRAR 7.20 to RAR 7.23 and UNRAR 7.3.2.
Historical campaign receipts keep their original tool identities and results.
Running their regression cases with a new oracle does not rewrite those
campaigns or supply new statistical samples.

## Linux producer packaging failure

The new packaged RAR 7.23 executable exited 139 for help and for both stored
and compressed fixture creation inside a Nix check. The unmodified executable
from the same hash-pinned producer archive successfully printed help and
created an archive when invoked with the new pinned glibc loader/libraries.
Invoking the rewritten executable through that same loader still failed.
Disabling stripping and preserving old sections during ELF rewriting also
failed. This comparison isolates a packaging/binary-rewriting failure; it
does not identify the exact instruction or upstream defect.

`nix/rar-producer.nix` supplies only the test producer command on Linux. It
retains the upstream bytes, invokes the pinned loader explicitly, and checks
help plus an independently read stored-archive round trip during construction.
It preserves the producer's license and attribution files. The separate
UNRAR oracle remains the source-built nixpkgs package. macOS retains its
normal producer package. This helper is not a distributed rarz dependency or
a general replacement package for RAR and its self-extractor.

The existing Windows metadata integration test reproduced the producer
failure before this change and passed afterward for both compression methods.
The complete 505-unit/CLI/v70 suite passed with the new tools, along with the
optimized build, five-target publication checks, native macOS unit/package
and classifier/v70-driver checks, and all-system flake evaluation. The admitted
Linux runtime peaked at 11,840,159,744 bytes. Source, test, and build-input
hashes matched the accepted worktree after integration; the main optimized
build then passed using the same product. Complete native macOS CLI and
Linux ARM64/Windows runtime qualification remain separate work.
