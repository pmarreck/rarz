# Build layout and qualification

The build has one implementation, a Zig library and C CLI. No implementation
selector file is needed. `scripts/targets.json` declares five targets; Nix
exposes each with ReleaseFast, ReleaseSafe, and Debug profiles. Linux uses musl.
The Windows GNU compiler ABI does not add a variant directory.

`./build` selects Nix packages and verifies the resulting executable with LLVM
before publication. Checks require the expected architecture, executable file
type, static Linux linkage, and system-only macOS/Windows dependencies. Native
products also execute `--about` and must report the requested platform and
profile. Compiler targets use baseline CPU settings, without `-mcpu=native`.
Foreign products are explicitly reported as runtime-unverified.

Complete products are retained through unique `.nix-out/PF/[musl/]PROFILE.*`
Nix roots. Profile views under `zig-out` and direct command entries under
`bin/PF` are published atomically, with one publication lock per platform.
POSIX entries point to a specific retained generation; changing a profile view
cannot silently change the selected command. Windows entries are executable
copies with a hash record recognizing both sides of an interrupted replacement.
Identical retries preserve the current entry and generation. Failed generations
remain available for diagnosis. A killed publisher can leave its lock; inspect
the recorded PID and preserve the directory before clearing a stale lock.

The old flat `zig-out` and root `result` are preserved. No shell configuration
or global PATH is changed. To roll back a selection, republish a known-good
source revision, or restore the previous relative entry link while retaining
its Nix root. Unknown files and symlinked output ancestors are rejected.

The complete `./test` entrypoint includes pure target/scope classifiers, real
header publication controls, failed builds, malformed products, protected
unmanaged files, lock exclusion, symlink escapes, exact-product execution,
and real cross-target publication through `checks.build-publication`. Mutation
controls use private trees inside Nix or Bubblewrap confinement.

The initial Linux cross-build produced all five ReleaseFast products and
verified their file headers and dependencies. This is compile/publication
evidence. Native macOS, Linux ARM64, and Windows execution, minimum supported
OS versions, and case-insensitive filesystem qualification remain unverified.
There is no application bundle or signing claim. Full native runtime
qualification is a separate outstanding requirement.

The corrected migration candidate passed complete `./test` on October 27,
2026, including 451 safety-checked unit tests, all CLI suites, the full v70
gate, and the five-target Nix publication check with native Debug/ReleaseSafe
identity checks. The assessment default-path regression proves that a stale
flat binary cannot override `bin/PF/rarz`. `./build --all` published all five
targets while preserving the old flat outputs. All seven declared CI targets
also built locally. These results retain the native runtime limits above.
