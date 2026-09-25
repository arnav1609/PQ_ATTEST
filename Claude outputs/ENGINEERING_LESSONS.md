# Engineering Lessons — combined carry-forward record

Two projects, one set of root causes.

- **MVDR anti-jamming** (Arty A7-100T, MicroBlaze, Vitis) — lessons as recorded by Kalash
- **PQ-Attest** (Arty A7-100T, Vivado/XSim, SystemVerilog crypto lane, Stages 1–6)

Every entry is tied to a real event. The value is in **Part 1** — the shared root
causes. The per-project detail below it is evidence, not the lesson.

---

# PART 1 — THE SEVEN ROOT CAUSES

Both projects' failures collapse into seven patterns. If a future session
internalises only this page, most of the damage is avoided.

## RC-1 · Reasoning from a representation instead of the artifact

| Project | Event |
|---|---|
| MVDR | Vitis programmed a **stale bitstream**; the FPGA never matched the design being debugged |
| MVDR | "Build Finished successfully" while the linker reused a **stale `main.c.obj`** |
| PQ-Attest | Judged the project by a **stale zip** → falsely claimed Stages 3/4 had no RTL and SHA3 was capped at 272 bytes. Both retracted. |
| PQ-Attest | Scanned a **stale uploads cache** and reported deleted files as present |
| PQ-Attest | Wrote a handoff brief saying three SHA3 fixes were applied **when the commit had failed** |

**Rule:** the artifact is the working tree, the running bitstream, the `.xpr`, the
compiled object. A zip, a summary, a status message, a cached copy, and a memory
of a file are all representations. **Read the artifact.**

## RC-2 · Ambiguous evidence read as confirmation

| Project | Event |
|---|---|
| MVDR | "Build succeeded" taken as "the source recompiled" |
| PQ-Attest | A **49/0 `SHA3_TB` run** taken as proof the byte-order patch was live. It was not evidence either way: unpatched RTL + unpatched TB literals are self-consistent, and the patched pair would have been too. **Both states give 49/0.** |

**Rule:** before treating a green result as proof of X, ask *"would this result
look different if X were false?"* If no, it is not evidence.

## RC-3 · Interface changes treated as local edits

| Project | Event |
|---|---|
| PQ-Attest | Added `out_len_sel` to `kmac_encode`/`kmac_128` **without grepping instantiations** → `kmac_tb` collapsed 3/7. The TB kept the old port list, the input floated, and every KAT absorbed a different message. |
| PQ-Attest | Two **byte orders** in one crypto lane (SHA3 MSB-first, everything else LSB-first) — latent, would have surfaced at Stage 6 as a wrong tag with all unit tests green |
| PQ-Attest | **Reset polarity is not uniform**: `keccak_f1600` is active-HIGH sync; everything else active-low |
| PQ-Attest | Two modules each believing they owned `right_encode(L)` → `X ‖ rc(L) ‖ rc(L)` |

**Rule:** grep every instantiation before changing a port list. Write the
convention down (byte order, reset polarity, who owns each spec step). On a
multi-person RTL project, the interface assumption living in one head is the
most expensive bug class there is.

## RC-4 · Persisting on the expensive hypothesis before the cheap probe

| Project | Event |
|---|---|
| MVDR | An hour in the debugger before checking `clk_wiz_0_locked` on an ILA. A one-minute probe was the answer. |
| MVDR | Theorised about AGC before having the R12-phase measurement |
| PQ-Attest | **Three wrong diagnoses** of "all red" — file typed Verilog (disproven), duplicate `trng_top` (real but not in the fileset), files missing from the fileset (they were in it) — before reading the `.xpr`, which was two tool calls away |

**Rule:** rank hypotheses by *cost to test*, not by plausibility. Run the cheapest
discriminating probe first. In Vivado that is usually: read the `.xpr`, read the
`.prj` the tool actually generated, check `is_enabled`.

## RC-5 · State that fails silently

| Project | Symptom | Real cause |
|---|---|---|
| MVDR | core "held in reset" | MMCM not locked → `proc_sys_reset` asserted |
| MVDR | program "hangs" after a print | newlib `Balloc` failed — 2 KB heap too small for `printf("%f")` |
| MVDR | fix "didn't take" | stale `.obj` relinked |
| PQ-Attest | every symbol undeclared | **30 of 34 sources were `UserDisabled="1"`** in the `.xpr`; earlier sims passed off a stale `xil_defaultlib` |
| PQ-Attest | every KAT wrong, structure right | unconnected port read as `'z` |
| PQ-Attest | self-test failed, function was fine | a 61-digit `'h` literal in a 256-bit field **zero-extends silently** instead of erroring |
| PQ-Attest | wrong digest, no error | `sha3_pad` skips padding when `valid_bytes == RATE_BYTES` |

**Rule:** a hang, a wall of undeclared symbols, or a silently wrong value is
usually **environment state**, not logic. Check: is the file enabled? is the
library stale? is the port connected? is the literal the right width?

## RC-6 · Verification that cannot fail

| Project | Event |
|---|---|
| MVDR | The checks that **worked** were structural: `Hermitian error = 0`, `wᴴa = 1.000000`. They proved the compute correct and correctly localised the bug upstream. |
| PQ-Attest | `SHA3_TB`, `kmac_tb`, `TRNG_TB` all print PASS banners; **none has a mutation test**. Nobody has shown they can fail. |
| PQ-Attest | The Stage 6 start-while-busy test restarted with the **same inputs** — it passed whether or not the second start was latched. Vacuous. |

**Rule:** a testbench that has never failed has verified nothing. Every TB gets a
**negative control**: inject a one-bit error and require a FAIL. Every protocol
test must change something, or it proves nothing.

## RC-7 · Not matching the codebase's own proven pattern

| Project | Event |
|---|---|
| PQ-Attest | Wrote `module m import pkg::*; #(parameter ...)` — a header style **no working module in the project uses**. All four (`sha3_256`, `pq_kdf`, `kmac128`, `keccak_f1600`) import with **no parameter list** and take constants from a package. Then patched the symptom twice more instead of matching the pattern. |
| PQ-Attest | Proposed splitting Stage 6 into a "message builder" + controller — the same split that produced the Stage 5 `block_formatter` bug |

**Rule:** before inventing a structure, look at what already compiles in this
repo and copy it. A pattern proven four times beats a pattern that is merely
legal.

---

# PART 2 — OPERATING RULES (do these, every time)

## Before changing code
- [ ] Read the actual file in the actual project. Never a zip, summary, or memory.
- [ ] `grep` every instantiation before touching a port list.
- [ ] Check the codebase's existing pattern for this kind of module and match it.

## Before claiming anything
- [ ] Would this evidence look different if my claim were false? If not, it is not evidence.
- [ ] Did the write actually land? Verify size/mtime on disk — a failed commit is silent.
- [ ] No number without provenance: tool version, exact part, post-synth vs post-route. **FPGA utilisation is not ASIC area.**

## Vivado / XSim preflight
```tcl
# 1. is anything disabled? (cost us hours)
foreach f [get_files -quiet -of_objects [get_filesets sources_1]] {
    if {![get_property is_enabled [get_files $f]]} { puts "DISABLED: [file tail $f]" }
}
# 2. what did the tool ACTUALLY compile?
#    read NOC_PQATTEST.sim/sim_1/behav/xsim/<top>_vlog.prj
# 3. force a clean build - --incr caches stale analysis
close_sim
reset_simulation -simset sim_1 -mode behavioral
launch_simulation
```
- The editor's red underline is **not** a compiler. `xvlog` is the only opinion.
- `update_compile_order ... No update performed` in the GUI is normal.
- Orphaned `xsimk.exe`/`xsim.exe` wedge XSim (`rc=139`). Reboot; never kill `vivado.exe`.
- Vivado's Tcl console is a full Tcl interpreter — `file delete -force` works there.

## xvlog rejections (do not rediscover)
| Rejected | Use instead |
|---|---|
| `context`, `config` as identifiers | reserved — rename (`context_in`, `config_data`) |
| `import pkg::*;` + `#(parameter ...)` in a header | put constants in a package, drop `#()` |
| scoped `pkg::PARAM` in an ANSI port declaration | import in the header, or a literal + elaboration check |
| `t'(x).field` — member select on a cast | assign the cast to a named signal first |
| `f(x)[7:0]` — part-select on a function call | assign to a temp, then select |
| `dut.STATE_NAME` — hierarchical enum label | expose a status output; keep the TB black-box |
| `initial` inside a `package` | move into a module |
| `{string_var, "lit"}` | `$sformatf` |
| blocking `=` and `<=` on one variable in one `always_ff` | all non-blocking |
| zero-width vectors | guard the width parameter |

## Testbench discipline
- **TSETTLE:** drive at `negedge`, wait `#1`, sample, release after the consuming
  `posedge`. Inside a wait loop: `@(posedge clk); #1;` — reading right after the
  edge returns the **pre-edge** value, so a one-cycle pulse is missed.
- **Negative control in every TB.** Flip one bit, require a FAIL.
- **Self-test any adapter before the thing it adapts.** A byte-swap helper gets a
  *hand-computed anchor* — a round-trip alone also passes for the identity function.
- **Every sized literal on one line.** A short `'h` literal zero-extends silently.
- **Expected values in RTL byte order, printed form in a comment** — keeps the swap
  out of the pass/fail path entirely.
- Golden values are **regenerated from the reference**, never hand-copied.
- A protocol test must **change an input**, or it proves nothing.

## Embedded / soft-core (from MVDR)
- Debug a dead soft-core **top-down from the clock**: right bitstream? → MMCM
  `locked`? → `proc_sys_reset` released? → does it step? Expose `locked` on an ILA
  from day one.
- Program the FPGA from **Vivado Hardware Manager** and confirm the running
  bitstream's identity before trusting a Vitis run.
- `printf("%f")` bare-metal needs **≥16–32 KB heap**. `Balloc failed` reads as a hang.
- One canonical project under version control. Divergent copies caused a
  wrong-source build.
- Never launch a second IDE instance on one workspace — workspace-lock deadlock.
- Serial terminal open **before** the run, or the banner is lost.

## DSP / fixed-point (from MVDR)
- Adaptive beamformer constraint = the **desired** steering vector, never the
  estimated interferer direction.
- **Diagonal loading is not optional** (~5% of the mean diagonal); normalise
  weights before quantising to Q1.15.
- Accumulator width from the math: `W_acc ≥ 2·W_in + ceil(log2 N)`.
- Push the conjugate into the datapath so a plain cascade yields `wᴴx`.
- Verify the **signal path into** the algorithm on hardware, not only in sim.

## Crypto-specific (PQ-Attest)
- Byte order: **byte i at `[i*8 +: 8]`**, everywhere. One convention, fixed at the
  producer, never swapped per consumer.
- KMAC output length is **absorbed**, not truncated:
  `KMAC128(K,X,128) ≠ KMAC128(K,X,256)[0:16]`.
- A control input like `out_len_sel` gets **no default port value** — a default
  masks exactly the failure it would cause.
- One owner per spec step. `kmac_encode` owns `right_encode(L)` and the domain byte.
- KDF customization is **empty** (context in the message); Stage 7 is the opposite.
- SHA3 with `valid_bytes == RATE_BYTES` and `is_final` gets **no padding** — send
  the data non-final, then one block of `valid_bytes=0, is_final=1`.
- `sha3_256` reads `is_final` **live** ~26 cycles after start — the caller must
  hold it in a register.

## The verification ladder — never upgrade casually
`unwritten → lint-clean → smoke → sim-verified → formally-proven → hw-validated`

`sim-verified` requires **all three**: an independent golden model, a stated
stimulus strategy, and **mutation testing**. A "STAGE N PASS" banner is not a
status. After any RTL edit, drop to the highest level still actually true.

---

# PART 3 — AGENT SELF-RULES

Written from mistakes I made, not hypotheticals.

1. **Read the artifact before forming a hypothesis.** Three wrong "all red"
   diagnoses came from skipping this. The `.xpr` was always two tool calls away.
2. **Verify the write landed.** A failed `device_commit_files`, a Vivado editor
   re-saving a stale buffer — both silent. Check size and mtime.
3. **Never claim a fix is applied without seeing it on disk.**
4. **Say "I cannot compile here"** rather than asserting a file is correct. Every
   time I guessed at an error I had not seen, I was wrong.
5. **When simplifying, do not drop the load-bearing step.** A "simple list" that
   omitted `add_files` cost a full cycle.
6. **Match the codebase's proven pattern** before inventing structure.
7. **Own errors in writing, in the handoff**, so the next session does not inherit
   a confident brief with no track record attached.
8. **When in doubt about scope, do less and report more.** An unrequested change
   to working RTL is worse than a gap left open — the gap is visible, the change
   is not.

---

# PART 4 — OPEN ITEMS (do not lose)

**MVDR / TD-1 — jammer phase missing from the hardware covariance.** R12 is nearly
real on hardware (≈ −1.5° to −16°) instead of ≈156° for a 60° arrival, so MVDR
cannot null the jammer and Case 3 is shallowest instead of deepest. Next step:
instrument jammer phase generator → mixer → covariance; try feeding covariance
from `rx_valid` (as the sim does) rather than `sv_valid`; regenerate the
bitstream; confirm suppression scales with jammer power.

**PQ-Attest**
- No mutation test in `SHA3_TB`, `kmac_tb`, `TRNG_TB` → none is `sim-verified`.
- No L=128 KAT in `kmac_tb` — the path Stage 5 depends on most is untested.
- `pq_keccak_tb` drives only the all-zero input.
- `sha3_256`: `is_final` not latched; no full-final-block assertion. Both open.
- Measurement message has **no length prefixes** — `TILE_ID ‖ CONFIG ‖ IMEM` is
  length-ambiguous where Stage 5 is not. Document or note as future work.
- NoC N-2: credit flow control **not integrated at the router**. "Phase 4 done" is
  module-level only.
- Stage 8 nonce origin undecided; gates Stages 4 and 9.
- **No synthesis or implementation run exists** — this project has no Fmax,
  utilisation or power numbers. Do not write one anywhere until a run produces it.
