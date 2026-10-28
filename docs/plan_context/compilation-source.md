# Compilation source boundary

All package and compiled-unit derivations previously used the complete flake
source. Updating PLAN or a coverage report therefore changed their inputs and
rebuilt all target products. Compilation now includes `src`, `include`, the
fixture corpus, the Zig build files, LICENSE, and the two installed/required Zig
test helpers. The compiler and dependency inputs remain pinned by the flake.

The complete test entry point still prepares adapters from the full source.
Shell tests, evidence, and publication logic therefore retain their dependency
on the files they execute or inspect. The build-publication check also evaluates
a source-boundary classifier over required and excluded path sets, plus all
literal `b.path(...)` inputs in the language build graph.

The classifier first failed against an unrestricted predicate. Actual bounded
builds then exposed two needed helper files, `tests/microbench.zig` and
`tests/diagnose_crc.zig`; both are declared explicitly. Native unit/package and
five-target publication checks pass with the corrected boundary.

A disposable copy of the tracked source supplied the reuse control. Appending
only to README left the derivation identities for the default package,
test-artifacts package, and compiled unit check unchanged. The build-publication
check identity changed, preserving adapter invalidation. This establishes reuse
for that documentation edit, not a measured end-to-end speedup or native
execution qualification of foreign targets.

Native macOS ARM64 unit and package-smoke checks also pass. Full native macOS
CLI/isolation and Linux ARM64/Windows execution remain separately unqualified;
this source-boundary change does not remove those existing limits.
A subsequent edit to `src/lib/root.zig` in the same disposable tree changed the
default package derivation, confirming that compiled source still invalidates
the product.

Complete integrated `./test` passed 469 units, every CLI suite, and the intact
and two damaged v70 controls. Runtime peak was 11,837,726,720 bytes under the
unchanged 16 GiB limit. The native `./build` also passed.
