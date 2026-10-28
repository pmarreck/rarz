# Parser errors during archive collection

The four FFI collection paths stopped on iterator errors and returned the
entries collected so far. Consequently, `rarz verify` returned success for all
18 partial RAR2 file headers that `rarz t` correctly rejected after 279bb66.
Collection now propagates parser errors so opening the malformed archive fails.
Each collector stops at an explicit ENDARC record before trailing padding.

Four unit regressions failed first, covering RAR4 and RAR5 through both open
APIs. They then passed with the existing suite, totaling 457 tests. The CLI
controls cover all 18 partial headers, complete vintage file boundaries, and
genuine multi-volume producer fixtures. A truncated RAR5 final header was also
accepted by the old FFI and independently rejected by UNRAR.

Two RAR4 reference observations remain distinct. UNRAR accepts a shortened
optional end-record body, and the existing FFI behavior is preserved. Cutting
the required continuation header to six bytes instead makes UNRAR request a
nonexistent fifth volume with exit 6. That result remains inconclusive under
the shared classifier; the directly observed missing base-header bytes establish
the API refusal. It receives no statistical detection credit.

Header CRC and mandatory terminator checks remain validation-policy concerns;
this change addresses swallowed parser errors. Complete `./test` passed all 457
unit tests, every CLI suite, and the pristine/two-mutation v70 gate on October
27, 2026. Runtime cgroup peak was 11,838,853,120 bytes. Native macOS ARM64 Nix
checks also passed all 457 units and installed-package smoke tests.
