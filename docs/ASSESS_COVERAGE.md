# Corrupt-input detection assessment

The [seed-44 campaign](COVERAGE_20261028_SEED44.md) uses the uncached reference
protocol and preserves one newly found RAR2 decoded-size miss. The prior
[seed-43 campaign](COVERAGE_20261028.md) records the quick-open reference finding.
The [October 15 campaign](COVERAGE_20261015.md) preserves the first default run
and its original gaps.

`./assess-coverage` measures how often `rarz t` rejects damage confirmed by
the independent UNRAR implementation. Supply one or more known-good,
unencrypted, standalone RAR archives. Both validators must accept every
pristine input before any mutations run.
`-` or `@stdin` accepts one streamed input, saved as a private `stdin.rar`
snapshot in the report directory so repeated trials and later replay use
the same bytes.

```sh
./assess-coverage --output coverage-report archive.rar another.rar
./assess-coverage --profile sniper --profile bolter archive.rar
./assess-coverage --help
```

Without input arguments, the command uses the independent producer fixtures
`rar2_v20_m3.rar`, `rar4_m3.rar`, and `rar5_m3.rar` under `tests/fixtures`.
The default profiles are `sniper`, `bolter`, `shotgun_variable`, `nuke`,
`robespierre`, and `badonkachomp`. These cover single-bit flips, whole-byte
bit flips, scattered bit flips, a large overwrite, and prefix/suffix
deletion. Each archive/profile pair is reported separately. Custom profile
JSON paths can be supplied with repeated `--profile` arguments.

The Bash entry point enters the pinned Nix development shell automatically.
Build rarz first with `./build`; assessment selects the current platform's
`bin/PF/rarz`. Select another existing binary explicitly with `--rarz`.
The development shell supplies LuaJIT, lua-cjson, GNU command-line tools,
UNRAR, and corruption-reader. The pinned corruption_reader repository
currently requires authorized SSH access; an unauthenticated archive fetch
cannot substitute for it. Its consumer CLI v1 requires version 0.7.0 or newer.
`--mutator` and `--reference` select explicit executable paths.

On a shared Linux build host, use the shared memory/concurrency envelope:

```sh
build-budget --project rarz -- nix develop -c ./assess-coverage --output coverage-report
```

The assessment is a Unix development tool, tested on Linux x86-64. It does
not establish native Windows or macOS execution coverage. Each child process
has a default 10-second wall limit and 1024 MiB virtual-memory limit; both
are configurable. Larger archives may require more memory. A resource
failure leaves an incomplete result. Multi-volume mutation requires a
separate adapter and is refused. The defaults do not include the large v70
corpus. The assessment never extracts archive contents to disk.

## Statistical contract

The accepted default is a 95% pointwise Wilson score confidence interval
with no more than 5 percentage points of half-width. The fixed sample target
is `ceil(z² / (4 × margin²))`, or 385 eligible cases at the default settings.
This conservative target is chosen before observing rarz's detection rate;
sampling never stops because the observed rate looks favorable.
The formula and independent numerical test follow the
[NIST/SEMATECH binomial-proportion interval description](https://www.itl.nist.gov/div898/handbook/prc/section2/prc241.htm).

An eligible case changes the input bytes and receives an explicit damage
result from UNRAR. The estimate is therefore conditional on reference-confirmed
damage under the selected mutation profile. Reference-valid mutations are
reported separately, including disagreements where rarz rejects them.
Declared no-ops and byte-identical applied mutations never enter the
denominator. The default attempt cap is four times the sample target per
pair. Insufficient eligible cases produce an incomplete assessment, with
the achieved interval and all counts preserved.

The intervals use the usual independent Bernoulli sampling model, with
deterministic pseudorandom draws with replacement. Repeated mutation plans
are possible. The master seed defaults to 42, and rounds start at zero for
each pair. Repeating a seed is replay, not new evidence. The mutator derives
plans from seed, profile, and round rather than archive contents; different
inputs can share plans. Accordingly, the report makes no pooled or
simultaneous confidence claim across pairs. Wilson intervals are approximate
frequentist intervals, not a proof of universal coverage or a minimum-rate
certification. Three fixtures cannot represent every RAR feature or archive.

## Outcomes and evidence

| Outcome | Meaning |
| --- | --- |
| `detected` | UNRAR confirms damage; rarz returns INVALID with exit 1 |
| `missed` | UNRAR confirms damage; rarz returns VALID with exit 0 |
| `unverifiable` | UNRAR confirms damage; rarz returns UNVERIFIABLE with exit 69 |
| `survived` | Both accept the changed input |
| `disagreement` | UNRAR accepts; rarz returns INVALID |
| `inconclusive` | A tool crashes, times out, contradicts its verdict, or returns an unclassified result |
| `noop` | Mutator explicitly reports an unchanged case |
| `unchanged` | Mutator reports an applied plan but byte comparison finds no change |

Only explicit, matching verdict/exit pairs count as rarz detection. UNRAR
damage classification accepts checksum-error exit 3, exit 1 with the exact
`Unexpected end of archive` diagnostic, and exit 13 with the `ERROR: Bad
archive ...` diagnostic observed in UNRAR 7.20. Other nonzero results remain
inconclusive. This reference is an operational oracle, not a complete formal
specification of RAR validity. Disagreements need examination before changing
either decoder's interpretation.

Reference-confirmed damaged cases remain in the denominator even when rarz
cannot finish. Any inconclusive or unverifiable case makes the assessment
incomplete, even if the sample target was reached. Pristine rejection also
makes it incomplete, preventing an always-reject validator from scoring 100%.
Tests additionally inject an always-accept validator to prove misses count.

The command prints a JSON summary to stdout and progress to stderr. Use a
new `--output` directory for durable evidence; the default is a private
temporary directory. Existing directories are refused. Reports include
input and executable SHA-256 hashes, tool version output, process limits,
seed, per-pair counts, rates, intervals, and a final input-integrity check.
They contain local paths and potentially archive filenames, so review them
before publication.

The current reference invocation is `unrar t -p- -idq -qo-`. Disabling
quick-open makes the reference inspect primary headers instead of accepting
cached copies. The exact argument list is recorded as `reference_args` in
the summary. Reports without that field used the earlier invocation with
quick-open enabled. Keep results from these protocols separately identified;
the historical reports are not recalculated in place.

`summary.json` is checkpointed after each pair. A `running` status after an
interruption is incomplete evidence. `trials.jsonl` preserves every completed mutation's
full replay record and both process observations for every changed case.
Output observations are capped at 64 KiB per stream; truncation makes a
process outcome inconclusive. The first 50 anomalous cases per pair also
retain their mutated bytes and replay record under `cases/`.
Each trial includes its mutated-byte SHA-256 for replay verification.
On an execution error, the current mutation and process scratch files are
retained for diagnosis rather than removed.

```sh
# Replay a retained case against the original input with its recorded hash.
nix develop -c corruption-reader apply --case coverage-report/cases/17.json \
  -o replay.rar original.rar
./run t replay.rar

# Every trial is replayable even if its mutated bytes were not retained.
jq -c 'select(.id == 17) | .mutation.record' coverage-report/trials.jsonl > case.json
```

Exit 0 means the target was reached with no misses or disagreements; exit 1
means a completed assessment found misses or disagreements; exit 2 means
incomplete evidence or an execution error. Exit 0 does not claim a 100%
population detection rate: read the interval. The bounded assessment controls
run through `tests/cli/test_assess_coverage.sh`, automatically included in
`./test`; the full statistical campaign remains an explicit command.
