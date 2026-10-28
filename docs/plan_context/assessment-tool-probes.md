# Failed tool probes retain incomplete evidence

The assessor previously collected tool identities before entering its failure
checkpoint. If process setup failed, the empty output could be reported as an
unsupported corruption-reader version, while `summary.json` remained marked
`running` with no tool evidence.

A regression supplies a mutator whose identity probe exits 125 with a recorded
diagnostic. The corrected path requires successful, untruncated identity
execution before interpreting a version. It retains each observation under
`tools.<name>.identity` and finalizes the summary as `incomplete` on failure.
The probe's stdout, stderr, exit status, and classification remain available.

Native macOS testing exposed the original defect when the shell rejected the
requested 1 GiB virtual-memory limit before executing a tool. The diagnostic
fix does not raise, remove, or replace that limit. The native assessment memory
contract remains unresolved; no successful macOS statistical campaign or
complete macOS test-suite result is claimed.

On the tested macOS 26.7.2 runtime, a shell reported 435,300,336 KiB of virtual
address space and 2,160 KiB resident. The same shell rejected the requested
1 GiB cap. [XNU's resource-limit implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_resource.c)
rejects an address-space limit below current mapped usage. These observations
explain this failure; a larger virtual reservation does not establish the
same amount of resident memory.

A resident-memory policy would need separate semantics and enforcement
qualification. [XNU's memory-status controls](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus.c)
require root or a private entitlement for the relevant limit-setting commands.
No privilege, system policy, or memory budget was changed in this work.

The focused regression failed before the change and passed afterward. Final
Linux acceptance passed 505 unit tests, every required CLI suite, the v70
corruption gate, and the optimized build. Runtime cgroup peak memory was
11,839,541,248 bytes. A native macOS reproduction independently confirmed the
new incomplete report and retained limit-setup evidence at the unchanged cap.
End-to-end feedback took 17 minutes 10 seconds: 9 minutes 38 seconds of
preparation/admission and 7 minutes 32 seconds of runtime. The unit phase took
about one second; the large-corpus gate took 6 minutes 35 seconds. This is
acceptance timing under shared load, not a controlled performance comparison.
