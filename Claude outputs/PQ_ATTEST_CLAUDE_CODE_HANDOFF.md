# PQ-Attest — full project brief and handoff to Claude Code

Written 2026-09-17 by the Cowork session that closed Stages 1–4 and built Stage 5.
Audience: a fresh Claude Code session running on Kalash's Windows machine with
direct access to the Vivado project.

**Read this whole file before touching any RTL.**

---

## 0. SCOPE — read this first and do not exceed it

**This is a verification and cleanup pass. You are not building anything.**

### What you ARE asked to do

1. Read this brief, then read the actual files. Where the two disagree, **the files
   win** — fix this brief and say so.
2. Elaborate everything. Nothing in Stage 5 has ever been through a compiler.
3. Run every existing testbench. Diagnose every failure.
4. **Fix defects in work that already exists** — compile errors, wrong logic, broken
   connections, dead files, convention violations, stale documentation.
5. Re-verify what previous sessions claimed. Do not take any "PASS" on trust.
6. Write one report of what you found and what you changed.

### What you are NOT asked to do — DO NOT DO THESE

- **Do not build Stage 6, 7, 8, or anything beyond.** Kalash is doing those himself.
  Not even a stub, a package, a port, or a placeholder file.
- **Do not add new features or capability** to any existing module.
- **Do not write new testbenches**, and do not add new tests to existing ones. If a
  coverage gap matters, **write it in the report** and stop there. See §11 Step 7.
- **Do not refactor anything that works.** "Cleaner" is not a defect. If a module
  passes and is correct, leave it alone even if you would have written it differently.
- **Do not touch the NoC lane.**
- **Do not resolve open design questions** (§10). Report them; Kalash decides.
- **Do not rename, reorganize, or restructure** files, signals, or the project
  hierarchy beyond the specific deletions listed in §8.

### The one judgement call you will face

You will find things that are *not wrong* but *not covered* — untested paths, missing
assertions, thin stimulus. **Those are report items, not work items.** The distinction:

- A **defect** is something that is wrong now. Fix it.
- A **gap** is something correct but unproven. Report it.

If you genuinely cannot tell which one you are looking at, write it in the report as
an open question and leave the code alone.

You are the polishing pass. Assume the previous session was thorough but not
infallible — it made and retracted several errors, listed in §9.

## 1. Project identity

**PQ-Attest** — a post-quantum-secured Network-on-Chip RISC-V SoC with runtime tile
attestation.

| | |
|---|---|
| Board | Digilent Arty A7-100T |
| Part | `xc7a100tcsg324-1` |
| Tools | Vivado 2024.1, XSim |
| Language | SystemVerilog-2012 |
| Project root | `C:\vivado_verilog_proj\NOC_PQATTEST` |
| RTL | `NOC_PQATTEST.srcs\sources_1\new\` |
| Testbenches | `NOC_PQATTEST.srcs\sim_1\new\` |
| Python reference | `PQ_Attest\software\` |
| Team | 4 people; Kalash owns the crypto lane |

**Goal.** A tile in the NoC can prove to a verifier, at runtime, that it is running
the expected code, using only post-quantum-safe primitives (Keccak-family, no RSA,
no ECC). Target outputs: a working A7-100T demo, a GitHub portfolio project, and an
IEEE conference paper.

**The governing rule of this project:** the Python reference in `PQ_Attest/software/`
is the specification. RTL is correct when it reproduces the reference byte-for-byte,
and for no other reason. A testbench that passes against hand-written expected values
that were never checked against the reference proves nothing.

Reference suite status: `python run_all_tests.py` → **8/8 PASS, 0.32 s**. Run it
first; if it does not pass, stop, because the spec itself is broken.

---

## 2. Two lanes

**Crypto lane — ACTIVE.** Keccak → SHA3-256 / KMAC128 / TRNG conditioning → KDF →
measurement → attestation. This is all of Stages 1–11 below.

**NoC lane — ON HOLD.** Routers, crossbar, FIFOs, credit control, network interface
(M10), address decoder (M11). Do not work on it unless asked. Two unresolved items
are parked there, recorded in §10.

---

## 3. Stage map

| Stage | Content | Status |
|---|---|---|
| 1 | Keccak-f[1600] permutation | **sim-verified** |
| 2 | SHA3-256 | pass, **smoke** (see §6) |
| 3 | KMAC128 | pass, **smoke** |
| 4 | TRNG conditioning + health tests | pass, **smoke** |
| 5 | Tile-key KDF | RTL written, **never elaborated** ← you are here |
| 6 | Tile measurement | not started |
| 7 | Runtime attestation | not started |
| 8 | Attestation protocol boundary | **undecided — see §10** |
| 9 | Security-property regression (11 scenarios) | not started |
| 10 | End-to-end integration (16 checks) | not started |
| 11A/B | Functional freeze / implementation freeze | not started |

---

## 4. Architecture

```
keccak_theta → keccak_rho → keccak_pi → keccak_chi → keccak_iota     (pq_keccak_*.sv)
        └────────── keccak_round ──────────┘
                    └── keccak_f1600 (24 rounds, 1/clk) ──┐
                                                          ├── sha3_256      Stage 2
                                                          ├── kmac128       Stage 3
                                                          │     └── kmac_encode
                                                          │           └── pq_kdf   Stage 5
                                                          └── trng_conditioner Stage 4
                                                                └── trng_top, trng_health
```

Packages: `keccak_pkg` (in `pq_keccak_pkg.sv`), `sha3_pkg`, `kmac_pkg`, `trng_pkg`,
`pq_kdf_pkg`.

Note the file/module name mismatches that already exist and are intentional:
`pq_keccak_pkg.sv` declares `package keccak_pkg`; `kmac_128.sv` declares module
`kmac128` (no underscore).

---

## 5. NON-NEGOTIABLE CONVENTIONS

Violating any of these silently produces a wrong cryptographic answer with every
unit test still green. Each was learned from an actual bug in this project.

### 5.1 Byte order — byte *i* lives at `[i*8 +: 8]`

Every digest, tag, key, message and nonce packs **byte 0 at the LSB end**.

```systemverilog
tag_out[i*8 +: 8]     = byte i     // kmac128
digest[i*8 +: 8]      = byte i     // sha3_256  (FIXED — see §9)
conditioned_out[i*8 +: 8] = byte i // trng_conditioner
derived_key[i*8 +: 8] = byte i     // pq_kdf
```

`sha3_256` originally packed byte 0 at the **MSB** end, opposite everything else.
Fixed at the producer. Do not reintroduce a second convention; if an external
interface needs big-endian, swap once at that boundary.

**Consequence for every testbench:** golden vectors from NIST or from the Python
reference are in *printed* order (byte 0 leftmost) and must be byte-swapped before
comparison. `SHA3_TB` has `bswap256()`; `pq_kdf_tb` has `bswap()` with a self-test.

### 5.2 Reset polarity is NOT uniform — check before you wire

| Module | Reset |
|---|---|
| `keccak_f1600` | `rst` — **active HIGH, synchronous** |
| `sha3_256`, `kmac128`, `pq_kdf`, `trng_*` | `rst_n` — **active LOW** |

`sha3_256` bridges with `.rst(~rst_n)`. Every future `keccak_f1600` instantiation
must do the same. This is the single most likely integration bug in the project.

### 5.3 KMAC output length is ABSORBED, not truncated

`KMAC128(K,X,128) != KMAC128(K,X,256)[0:16]`. KMAC absorbs `right_encode(L)`, so L
changes the message. Proven against this project's own vectors:

```
V01 golden (L=128)     : 9c699e785af03e632e2da3cbe9ede27c
KMAC(V01, L=256)[:16]  : f3d22e09c5b0ba3b0e5a7c85ab7703fc   <- this is V06's prefix
```

`right_encode(128)` = `80 01` (2 bytes); `right_encode(256)` = `01 00 02` (3 bytes).
The differing width also moves the KMAC domain byte `0x04` that follows it.

`kmac_encode` and `kmac128` therefore take `out_len_sel`. It has **no default port
value** — deliberately. A default would silently restore wrong behaviour for an
unconnected caller, which is exactly the bug it caused once already. Every
instantiation must connect it.

### 5.4 One owner per spec step

`kmac_encode` owns `right_encode(L)` and the domain byte. `pq_kdf` must NOT append
them. A deleted module (`pq_kdf_block_formatter.sv`) appended `right_encode(L)` a
second time, producing `X ‖ rc(L) ‖ rc(L)` — that was the original Stage 5 bug.

### 5.5 KDF uses EMPTY customization

The context string goes in the **message**, not the cSHAKE customization field.
Stage 7 (attestation) does the opposite. Wiring `"PQ-ATTEST-AUTH"` into
customization here fails all six vectors identically.

---

## 6. Stage-by-stage state, with evidence

Statuses use this ladder. `sim-verified` requires **all three**: an independent golden
model, a stated stimulus strategy, and mutation testing showing the TB catches
injected bugs.

`unwritten → lint-clean → smoke → sim-verified → formally-proven → hw-validated`

### Stage 1 — Keccak-f[1600] — sim-verified

Files: `pq_keccak_pkg.sv`, `pq_keccak_{theta,rho,pi,chi,iota,round,f1600}.sv`
TB: `pq_keccak_tb.sv` + `keccak_rounds.memh` (600 lanes)

Verified by transcribing the RTL's exact index expressions into Python and comparing
against `keccak_ref.py`:
- 200 random states per step module — identical
- 50 full permutations — identical
- `f1600(all-zero)[0][0] = f1258f7940e1dde7` — the published FIPS 202 value
- all 600 per-round golden lanes regenerated and matched, **x-major** (`i = x*5+y`),
  which is how the TB indexes them

Non-obvious implementation details that are correct and must not be "simplified":
- π is written in **gather** form, `out[a][b] = in[(3*(b+15-3a))%5][a]`, not scatter.
  The scatter form writes to a computed LHS index, which synthesis cannot always
  prove complete. The two were checked equal at all 25 positions.
- χ wraps with `(x>=3) ? (x-3) : (x+2)`.
- `rotl64` special-cases `n==0`; `x >> 64` is undefined otherwise.
- `keccak_iota` clamps an out-of-range round index and asserts, because `round_t` is
  5 bits but `ROUND_CONSTANTS` has 24 entries.

**Known gaps:** stimulus is the all-zero input only. Add random-input vectors.

**Known wart (deliberately not fixed):** a `start` pulse arriving in `KECCAK_DONE` is
dropped while `busy` is low. No current caller does this. This module feeds three
stages — do not change it without a reason and a test.

### Stage 2 — SHA3-256 — 49/0, smoke

Files: `SHA3_PKG.sv`, `SHA3_256.sv`, `SHA3_PAD.sv`, `SHA3_ABSORB.sv`
TB: `SHA3_TB.sv`

Interface is **block-streaming**: the caller supplies one 136-byte block per `start`,
with `valid_bytes` and `is_final`. Message length is unbounded by the core.

All 6 KATs independently reproduced from `hashlib.sha3_256`: `""`, `"abc"`,
`"hello world"`, and 135 / 136 / 137 bytes of `'a'` (0x61).

Three fixes were applied this session and are already in the file — verify they are
present:
1. digest packing changed to byte *i* at `[i*8 +: 8]` (§5.1)
2. `is_final` **latched at accept** into `is_final_q`. It was read live in
   `KECCAK_WAIT` ~26 cycles after `start`, so a caller that dropped it early got no
   digest and no error.
3. concurrent assertion `a_no_full_final_block` — `sha3_pad` only pads when
   `valid_bytes < RATE_BYTES`, so `is_final` with a full 136-byte block got **no
   padding at all** and emitted a wrong digest silently. FIPS 202 requires an extra
   all-padding block; the contract is `valid_bytes=0, is_final=1`.

**Known gap:** no mutation testing.

### Stage 3 — KMAC128 — 10/0, smoke

Files: `kmac_pkg.sv`, `kmac_encode.sv`, `kmac_128.sv`, `kmac_absorb.sv`
TB: `kmac_tb.sv`

All 5 tags independently reproduced from `kmac128_ref.py`; the reference itself
reproduces the NIST SP 800-185 KMAC128 KAT. A structural test confirms exactly 3
Keccak permutations.

`kmac_pkg` was widened for Stage 5: `MAX_MSG_BYTES` 16 → **40** (KDF message is
23–37 bytes). `KMAC_L_128`/`KMAC_L_256` and `RIGHT_ENC_BYTES_*` added.

**Known gaps:** no mutation testing, and **no L=128 KAT** — `out_len_sel` low is the
path Stage 5 depends on most and it has no known-answer test. Add one.

### Stage 4 — TRNG conditioning — smoke

Files: `TRNG_PKG.sv`, `TRNG_TOP.sv`, `TRNG_CONDITIONER.sv`, `TRNG_HEALTH.sv`,
`TRNG_SOURCE.sv`, `TRNG_PAD.sv`
TBs: `TRNG_TB.sv`, `TRNG_TOP_TB.sv`

All 5 conditioned outputs and nonces independently reproduced from
`trng_conditioning_ref.py`. 512 raw bytes → padding (`0x01` at byte 512 — **Keccak**
padding, not SHA3's `0x06`; `0x80` at byte 543; 68 words = 4 blocks of 17) → absorb
with `x=i%5, y=i/5` → squeeze 32 bytes from lanes `[0..3][0]`. Nonce = low 128 bits.

**SCOPE WARNING — do not overclaim.** `trng_source.sv` is a **vector replayer**, not
an entropy source. No ring oscillator, no jitter sampling. It also emits *bytes*
while `trng_top`/`trng_conditioner` consume 64-bit *words*, and it ignores
`entropy_ready`, so it cannot drive `trng_top` as written. `TRNG_PAD.sv` is likewise
orphaned — the conditioner inlines the same mux.

What is supportable: **entropy conditioning and online health testing**. Not "a TRNG".
`trng_health` implements a repetition-count test only, not SP 800-90B's adaptive
proportion test.

**Note:** the previous session never saw `TRNG_TB`/`TRNG_TOP_TB` simulation logs. The
vectors are confirmed correct; whether the testbenches currently pass is **unverified**.
Run them.

### Stage 5 — Tile-key KDF — RTL written, NEVER ELABORATED

Files: `pq_kdf_pkg.sv`, `pq_kdf.sv`
TB: `pq_kdf_tb.sv` + `kdf_vectors_rtl.txt`

Algorithm, from `kmac128_ref.py`:

```python
kdf_message = encode_string(tile_id) + encode_string(epoch) + encode_string(context)
return kmac128(key=root_secret, message=kdf_message,
               output_bytes=key_bytes, customization=b"")
```

KDF message layout (byte index), built combinationally in 12 lines:

```
[0]      0x01           left_encode(56) length byte
[1]      0x38           56 = 7 × 8
[2..8]   TILE_ID        (7 bytes, fixed)
[9]      0x01           left_encode(80) length byte
[10]     0x50           80 = 10 × 8
[11..20] EPOCH          (10 bytes, fixed)
[21]     0x01           left_encode(8·ctx_len)
[22]     ctx_len × 8    one byte: 8·14 = 112 < 256
[23..]   CONTEXT        (0..14 bytes)
total = 23 + context_len   (23..37)
```

Both ID and epoch are fixed-length, so `encode_string` on them is a **compile-time
constant** — that is why no encoder module is needed. `context_len = 0` is legal and
must still emit `01 00` (that is vector V05).

FSM: `S_IDLE → S_KMAC → S_WAIT → S_DONE`. Request latched on accept; `start` while
busy ignored. For L=128 the upper 128 bits of `derived_key` are zeroed, not left
stale.

**`pq_kdf.sv` has never compiled.** One bug was already caught by reading: a port was
named `context`, a **reserved SystemVerilog keyword** (IEEE 1800 Table B.1, DPI).
Renamed `context_in`. Expect more.

`kdf_vectors_rtl.txt` exists because `kdf_vectors.txt` writes V05's empty context as
`|  |`; `$fscanf` skips whitespace and would read the next field as the context,
silently corrupting that vector and everything after it. The RTL file is fixed-width
with an explicit `ctx_len` and was regenerated from `derive_tile_key()` and checked
byte-for-byte against the shipped file.

`pq_kdf_tb.sv` self-tests its `bswap` against a **hand-computed anchor**
(`"TILE_01"` → `56'h31305f454c4954`) before running any vector, because a wrong swap
fails all six identically and looks like a broken KDF. A round-trip test alone is
insufficient — it also passes if `bswap` is the identity.

The six vectors: V01 baseline, V02 tile separation, V03 epoch separation, V04 context
separation, **V05 empty context**, **V06 256-bit key**. V05 and V06 are the ones that
catch the classic errors.

---

## 7. VIVADO / xvlog RESTRICTIONS LEARNED THE HARD WAY

Each of these cost real debugging time. Do not rediscover them.

| Rejected | Use instead |
|---|---|
| `context` as an identifier | reserved keyword — rename |
| `head_flit_t'(x).src_x` — member select on a **cast** | assign the cast to a named signal first |
| `bswap(v,n)[55:0]` — part-select on a **function call** | assign to a temp, then select |
| `dut.TX_IDLE` — hierarchical ref to an enum **label** | expose a status output; keep the TB black-box |
| `initial` block inside a `package` | move it into a module |
| zero-width vectors | guard the width parameter |
| `{string_var, "literal"}` concatenation | `$sformatf` |
| `.name()` on an enum | avoided project-wide for portability |

**Testbench sampling discipline (TSETTLE).** Drive at `negedge` → wait ~1 ns → sample
→ release after the `posedge` that consumes the transfer. A blocking assign followed
by an immediate read returns the pre-`always_comb` value. This produced a phantom
failure and a watchdog hang once.

---

## 8. File inventory — what is real, dead, or orphaned

### Delete (project + disk). Vivado's Tcl console is a full Tcl interpreter, so
`file delete -force` works there.

| File | Why |
|---|---|
| `pq_kdf_block_formatter.sv` | double-appended `right_encode(L)` — the Stage 5 bug |
| `pq_kdf_controller.sv` | empty Vivado template stub |
| `pq_kdf..sv` | double-dot typo, no logic |
| `SHA3_TB.v` | 0 bytes |
| `TB_GOLDEN.sv.duplicate` | duplicate |

### Remove from the fileset, keep on disk (unreachable RTL in a crypto fileset costs
reviewer confidence)

`pq_kdf_sp800185_encoder.sv`, `pq_kdf_message_builder.sv`, `TRNG_PAD.sv`

### Delete only after Stage 5 is green — these are the only rollback

`kmac_pkg.sv.bak`, `kmac_encode.sv.bak`, `kmac_128.sv.bak`

---

## 9. Errors the previous session MADE — verify these, do not trust them

The previous agent was wrong more than once. Independently re-check anything below.

1. **Invented an entire `noc_pkg` API that did not exist.** Wrote M10 and its TB
   against imagined type and parameter names. Everything was rejected by xvlog.
2. **Judged the project by a stale zip.** Claimed Stages 3/4 had no RTL and that
   SHA3 was capped at 272 bytes. **Both retracted** — the 272-byte cap belonged to
   `rtl/sha3/sha3_256_core.sv` in the reference archive, not to the project's
   `SHA3_256.sv`, which is block-streaming and unbounded.
3. **Changed `kmac_encode`/`kmac_128` port lists without updating instantiations**,
   which broke `kmac_tb` to 3/7. Root cause: did not grep for the module name.
4. **Overstated a DoS risk in M10** — retracted; the existing `else` branch already
   prevented it.
5. Introduced a TSETTLE sampling bug in the NI testbench.

**Standing rule that came out of this: read the file in the Vivado project. Never a
zip, a summary, or a memory of it.**

---

## 10. Open, unresolved, and undecided

- **`NOC_PKG.sv` shrank 30,144 → 20,347 bytes** at some point and it was never
  explained. Check `git log` or a backup before trusting the NoC lane.
- **Unknown whether the M10 5-hunk `rx_head_shape_ok` patch was ever applied.**
- **Stage 8 nonce origin is undecided** — verifier-issued or tile-generated. This
  decides whether a real entropy source is in scope at all, and it gates Stages 4
  and 9. Do not build Stage 8 until Kalash decides.
- **Stage 6 / SHA3 capacity question** was raised against the stale zip and is
  probably moot now that the real `SHA3_256.sv` is known to be block-streaming.
  Confirm, then close it.
- **No synthesis or implementation run exists.** There are therefore no Fmax,
  utilization or power numbers for this project, and none should be written into a
  README, a paper, or a post until a run produces them. Post-synth and post-route
  numbers are different numbers; label which, and never present an FPGA utilization
  figure as ASIC area.

---

## 11. YOUR TASK, IN ORDER

Work top to bottom. Do not skip ahead; each step gates the next. Stop and report if a
step fails in a way you cannot resolve without making a design decision.

**Step 0 — Establish ground truth.**
```
cd PQ_Attest\software && python run_all_tests.py      # expect 8/8 PASS
```
If this fails, stop and report. The reference is the spec; if it is broken, nothing
downstream can be verified.

**Step 1 — Clean the fileset.** Apply §8 exactly — the listed deletions and fileset
removals, nothing more. Confirm `pq_kdf_pkg.sv` and `pq_kdf.sv` are in `sources_1`,
and `pq_kdf_tb.sv` in `sim_1`. `kdf_vectors_rtl.txt` is read at runtime by absolute
path — do NOT add it to the project.

**Step 2 — Elaborate everything.**
```
xvlog -sv <all sources> && xelab -debug typical <top> -s <snap>
```
`pq_kdf.sv` has never compiled. Fix every error, and every warning that indicates a
real problem. Report each one with its root cause. Ignore cosmetic warnings and say
which ones you ignored.

**Step 3 — Regression on the green stages.** `pq_keccak_tb`, `SHA3_TB` (expect 49/0),
`kmac_tb` (expect 10/0). Any deviation means Step 1 or 2 broke something — fix it
before continuing.

**Step 4 — Run the TRNG testbenches** (`TRNG_TB`, `TRNG_TOP_TB`). Their pass/fail
state is genuinely unknown; nobody has seen a log. Report what you find. If they fail,
diagnose and fix the **defect** — but do not extend the testbenches.

**Step 5 — Run `pq_kdf_tb`.** Gates in order:
   1. the `bswap` self-test passes — until it does, no vector result means anything
   2. all 6 golden vectors pass
   3. the negative control **fails** as designed
   4. `start`-while-busy is ignored

If a vector fails, the fault is in `pq_kdf`'s message construction — Stage 3 is
independently green, so KMAC is not the suspect. Fix the defect; do not add vectors.

**Step 6 — Audit for defects previous sessions may have missed.** This is a **read and
verify** pass over code that already exists. Check specifically:

   - reset polarity at every `keccak_f1600` instantiation (§5.2)
   - every `out_len_sel` connection — it has no default, so an unconnected one is a
     silent wrong answer (§5.3)
   - byte order at every producer/consumer boundary (§5.1)
   - any input consumed more than one cycle after `start` without being latched —
     this is the Stage 2 `is_final` bug class; check `kmac128`, `pq_kdf`,
     `trng_conditioner`
   - any `always_comb` with a computed left-hand index
   - that the three SHA3 fixes listed in §6 Stage 2 are actually present in the file
   - that every golden value in every testbench still reproduces from the Python
     reference — regenerate them, do not eyeball them

Fix what is **wrong**. Report what is merely **unproven**.

**Step 7 — Coverage gaps: REPORT ONLY. DO NOT IMPLEMENT.**

These are known and deliberately left open. Kalash will decide when and whether to
close them. **Confirm each one still applies, describe what closing it would take,
and write nothing into the RTL or testbenches.**

   1. No mutation / negative-control test in `SHA3_TB`, `kmac_tb`, `TRNG_TB`.
      (`pq_keccak_tb` has one.) Until these exist, those three are `smoke`, not
      `sim-verified`, regardless of their PASS banners.
   2. No L=128 KAT in `kmac_tb` — `out_len_sel` low is untested.
   3. `pq_keccak_tb` drives only the all-zero input.
   4. `pq_kdf_tb` covers context lengths {0, 13, 14} only.

If you find a **further** gap, add it to this list in the report. Do not close it.

**Step 8 — Write `docs/POLISH_REPORT.md`.** Structure:

   - **Issues fixed** — one entry each: file and line, root cause (not symptom), the
     fix, why that fix over the alternatives, severity, and whether the issue was
     *silent* (wrong answer with tests green) or *loud*
   - **Issues found and NOT fixed** — what, why not, and what it would take
   - **Corrections to this brief** — anything in it that turned out to be wrong
   - **Verification status** — every module on the §6 ladder, with the evidence
   - **Coverage gaps** — Step 7's list, confirmed and expanded
   - **Test results** — every testbench, pass/fail counts, before and after

**Step 9 — Update the repo notes.** Append to `docs/sessions/2026-09.md`; update
`docs/verification/crypto-lane.md` and `docs/OPEN.md`. Add a `docs/decisions/` note
only if you made a decision that changed the code — with its `Costs` and
`Revisit if` lines. Commit notes with the RTL change that motivated them.

**Step 10 — Stop.** Do not begin Stage 6. Do not propose starting it. Hand back to
Kalash with the report.

## 12. Rules for how you work

- **Read the file before writing against it.** Two of the previous session's worst
  errors came from skipping this.
- **Grep every instantiation before changing a port list.** This is the single
  highest-value habit for this codebase.
- **When in doubt about scope, do less and report more.** An unrequested change to
  working RTL is worse than a gap left open, because the gap is visible and the
  change is not.
- **Never mark a module verified because a testbench printed PASS.** Use the ladder
  in §6 and state the evidence.
- **Do not upgrade a claim without a run behind it.** No numbers without tool
  version, part, and post-synth vs post-route.
- **Commit docs with the RTL change that motivated them**, in the same commit.
- **Ask before touching the NoC lane, Stage 8, or anything from Stage 6 onward.**
- When you fix something in a currently-green stage, say so explicitly and re-run
  that stage's testbench as the gate.
