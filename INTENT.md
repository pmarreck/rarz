# Project intent

rarz provides RAR archive parsing, validation, extraction, and writing through
a Zig library, a C FFI, and a command-line interface. Its users are library
consumers, CLI users, and the Mecha Validate file-integrity application.

## Desired outcomes

- Correctly handle real-world RAR archives across supported generations,
  including legacy compressed archives, solid archives, and split volumes.
- Distinguish verified content, proven damage, unsupported features, and
  incomplete verification. Encryption or resource limits do not prove damage.
- Verify large entries incrementally with bounded decoder memory rather than
  impose arbitrary archive-size exclusions. Dictionary and PPM heap needs
  remain explicit resource requirements.
- Support interoperable archive creation and extraction through the same C API
  used by the CLI.

## Architecture and constraints

Keep the Zig core focused on in-memory computation and the C CLI responsible
for I/O. Preserve the opaque-handle, buffer-based C API boundary. External RAR
implementations serve as fixture producers and test oracles, not production
dependencies.

The established project goal is a clean-room implementation. Preserve that
constraint; implementation provenance needs review where historical reports
describe reference-source ports. This dependency refresh does not resolve that
separate provenance question.

The earliest formats and features without independent producer evidence must
remain explicitly unsupported or incomplete. Password support and extraction
metadata fidelity have recorded future work; their absence must not be hidden
by weakening validation claims.

## Verification

Use independent producer fixtures, byte comparisons against reference
extraction, and deterministic corruption cases with replayable parameters.
Check pristine inputs as well as damaged inputs. Keep validation rejection,
crashes, timeouts, and resource exhaustion distinct. Run the complete `./test`
entry point and `./build` before shipping implementation changes.

The measured feature matrix lives in
[the RAR coverage report](docs/MECHA_VALIDATE_V1_RAR_GATE.md). It describes
evidence and limitations, not a substitute for these desired outcomes.

## Sources

Recovered from `PROJECT_OVERVIEW.md` at commit `80ec687`, the coverage report, and
the accepted July/August 2026 validation decisions archived in
[development context](docs/plan_context/development-history.md).
The overview's glossary and format-family definitions are preserved in
[TERMINOLOGY.md](TERMINOLOGY.md).
