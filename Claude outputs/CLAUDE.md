# PQ-Attest — repo rules

Post-quantum-secured NoC RISC-V SoC with runtime tile attestation.
Arty A7-100T · `xc7a100tcsg324-1` · Vivado 2024.1 · SystemVerilog-2012.

**Full project brief: `docs/PQ_ATTEST_CLAUDE_CODE_HANDOFF.md`. Read it before any
RTL work.** Current state, per-module verification status, and open questions:
`docs/verification/crypto-lane.md` and `docs/OPEN.md`.

## The specification

`PQ_Attest/software/` is the spec. RTL is correct when it reproduces the Python
reference byte-for-byte, and for no other reason. Verify with
`python run_all_tests.py` (expect 8/8) before trusting anything downstream.

Never write a golden vector by hand. Regenerate it from the reference.

## Conventions that produce silent wrong answers if broken

1. **Byte order: byte *i* at `[i*8 +: 8]`.** Every digest, tag, key, nonce. NIST and
   Python print the opposite order, so testbenches byte-swap on load.
2. **Reset polarity is not uniform.** `keccak_f1600` is active-HIGH sync `rst`;
   everything else is active-low `rst_n`. Bridge with `.rst(~rst_n)`.
3. **KMAC output length is absorbed, not truncated.**
   `KMAC128(K,X,128) != KMAC128(K,X,256)[0:16]`. `out_len_sel` has no default port
   value on purpose — connect it explicitly, every time.
4. **One owner per spec step.** `kmac_encode` owns `right_encode(L)` and the domain
   byte. Nothing else appends them.
5. **KDF customization is empty.** Context goes in the message. Stage 7 is the
   opposite.

## Working rules

- Read the file before writing against it. Never work from a zip, a summary, or memory.
- **Grep every instantiation before changing a port list.** The highest-value habit
  in this repo; skipping it has already broken a green testbench once.
- Latch every request field at accept, or assert the hold requirement. An input read
  26 cycles after `start` is a bug waiting for a caller who behaves reasonably.
- Assert a contract at the point you assume it. A guard condition documents nothing.
- Elaborate a file the day you write it.

## Verification ladder

`unwritten → lint-clean → smoke → sim-verified → formally-proven → hw-validated`

`sim-verified` requires **all three**: an independent golden model, a stated stimulus
strategy, and mutation testing showing the testbench catches injected bugs. A "STAGE N
PASS" banner is not a status. Downgrade honestly after any RTL edit.

## Vivado / xvlog rejections (do not rediscover)

- `context` is a reserved keyword
- no member select on a cast: `t'(x).field`
- no part-select on a function call: `f(x)[7:0]`
- no hierarchical reference to an enum label: `dut.STATE_NAME`
- no `initial` block inside a `package`
- no zero-width vectors
- `{string_var, "lit"}` fails — use `$sformatf`

Testbench sampling: drive at `negedge`, wait ~1 ns, sample, release after the
consuming `posedge`.

## Numbers

No synthesis or implementation run exists yet, so this project has no Fmax,
utilization or power figures. Do not write one anywhere until a run produces it.
Label post-synth vs post-route. Never present an FPGA utilization figure as ASIC area.

## Notes

Session log, decisions and verification status live in `docs/` and are committed with
the RTL change that motivated them. Update them in the same commit.

## Scope

Crypto lane is active through Stage 5. **NoC lane is on hold** — ask before touching it.
**Stage 8 (nonce origin) is undecided** — it gates Stages 4 and 9. Ask before building it.

**Stages 6+ are Kalash's own work. Do not start, stub, or scaffold them.**
Do not add new features, new testbenches, or new tests to existing testbenches
without being asked. A coverage gap is a report item, not a work item: a defect is
something wrong now and gets fixed; a gap is something correct but unproven and gets
written down. When in doubt about scope, do less and report more — an unrequested
change to working RTL is worse than a gap left open, because the gap is visible and
the change is not.
