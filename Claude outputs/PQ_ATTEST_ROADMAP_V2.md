# PQ-Attest v1 — Cryptographic/Attestation Closure Roadmap (corrected)

Revision 2, 2026-09-15. Supersedes the previous roadmap.
Corrections are marked **[CORRECTED]** with the evidence that forced them.

---

## Scope (unchanged, and worth keeping)

This document covers Keccak through hardware regression and synthesis freeze for
the scope defined by the PQ-Attest Python reference folders. It is **not** the
full PQ-Attest project. ML-DSA, NoC security enforcement, fault/quarantine
handling, baseline NoC work, and full SoC integration are all out of scope.

"Stage 11 complete" means the Python-defined cryptographic and attestation scope
is closed. It does not mean PQ-Attest is finished. Keep that distinction in any
paper or resume writeup — it is an easy thing to overstate.

---

## [CORRECTED] What actually exists right now

The previous roadmap stated: *"Stage 1 through 4 are treated as passed… Everything
from Stage 5 onward is unbuilt RTL."*

That is wrong by two stages. Measured from the delivered archive:

| File | Size | Reality |
|---|---|---|
| `rtl/keccak/keccak_round.sv` | 6089 B | exists |
| `rtl/keccak/keccak_f1600_core.sv` | 2268 B | exists |
| `rtl/keccak/keccak_f1600.sv` | **0 B** | **empty placeholder** |
| `rtl/keccak/tb_keccak_f1600.sv` | **0 B** | **empty placeholder — no Keccak TB exists** |
| `rtl/sha3/sha3_256_core.sv` | 11350 B | exists, 2-block max |
| `rtl/sha3/tb_sha3_256_core.sv` | 4688 B | exists, **does not read the Python vectors** |
| `kmac128.sv` | — | **DOES NOT EXIST** |
| TRNG conditioning RTL | — | **DOES NOT EXIST** |

**The unbuilt boundary is Stage 3, not Stage 5.**

Stages 5 and 7 both say "reuse `kmac128.sv`". There is no `kmac128.sv`. Building
Stage 5 next would mean building the KDF controller on top of a primitive that
does not exist.

Python side is in good shape and independently confirmed:
`python software/run_all_tests.py` → **8/8 PASS, 0.30 s**.

---

## [CORRECTED] Stage 0 — close what is claimed closed

Do this before anything else. None of it is large.

**0.1 — Delete or fill the two empty files.**
`keccak_f1600.sv` and `tb_keccak_f1600.sv` are 0 bytes. Nothing instantiates a
`keccak_f1600` module; `sha3_256_core` instantiates `keccak_f1600_core` directly.
They are dead. Either delete them or write the missing Keccak TB. Right now
Stage 1 has **no testbench at all**, so "Stage 1 passed" is not supported by
evidence.

**0.2 — Wire the Python golden vectors into the RTL testbenches.**
`tb_sha3_256_core.sv` contains no `$fopen`, `$fscanf`, or `$readmemh`. It checks
against expectations hardcoded inside the testbench. `CODE_EXPLANATION.md` states
the purpose of `kdf_vectors.txt` was for a hardware TB to read with `$fscanf()`.
That link does not exist.

You currently have a verified Python model and a separately-checked RTL model and
**no evidence they agree**. This is the same failure shape as the 23 dB vs 0.19 dB
sim-vs-hardware mismatch you hit before: two self-consistent models, never
compared. Fix it here, once, and every later stage inherits the harness.

**0.3 — Add the missing suites to `run_all_tests.py`.**
The runner covers 8 suites. It does **not** run `trng_vectors.py`,
`trng_healthtests.py`, `sha3_256_ref.py`, or `keccak_ref.py` self-tests. Stage 4's
Python is not in the aggregate regression at all.

**Exit gate:** every existing RTL module has a TB that reads its Python golden
vectors from file; empty files gone; `run_all_tests.py` covers every Python module.

---

## [CORRECTED] Stage 3 — KMAC128 RTL  *(was assumed done; it does not exist)*

This is the real next build, not Stage 5.

**Modules needed**
- `kmac_encode.sv` — `left_encode`, `right_encode`, `encode_string`, `bytepad`
- `cshake128.sv` — cSHAKE128 with `function_name` and `customization`
- `kmac128.sv` — KMAC128 on top of cSHAKE128, **variable output length**

**Blocking requirement carried forward from the old roadmap, now correctly
placed:** KMAC128 must support both 128-bit and 256-bit output. The KDF vectors
need it — V01–V05 request 16 bytes, V06 requests 32. Build and prove variable
output length **here**, in Stage 3, not as a workaround in Stage 5.

**Verification questions**
1. Does `kmac128.sv` reproduce the NIST SP 800-185 KAT vectors that
   `kmac128_ref.py` already passes?
2. Is variable output length exercised at **both** 16 and 32 bytes, with a
   separate passing vector for each?
3. Does `bytepad` produce the correct 168-byte rate padding for cSHAKE128?
4. Is `encode_string` correct for a **zero-length** input? KDF V05 depends on it.
5. Does the RTL instantiate `keccak_f1600_core` as a submodule, or reimplement
   any part of the permutation? A second Keccak has its own bug surface.
6. Little-endian: were the SV golden literals converted from Python's byte array
   using the lane reinterpretation, not pasted from `.hex()`?

**Exit gate:** KMAC128 RTL matches `kmac128_ref.py` on every NIST KAT and on both
output lengths, read from file, confirmed in an XSim transcript.

---

## Stage 4 — TRNG Conditioning RTL  *(scope decision required)*

No RTL exists. **Whether this is in scope depends on the Stage 8 nonce decision**
(see below). If the nonce is verifier-issued, the tile does not generate nonces
and the TRNG conditioner feeds nothing in this roadmap's scope.

**Decide Stage 8's nonce model first, then decide whether Stage 4 gets built.**
Do not build it speculatively.

---

## [CORRECTED] Stage 5 — Tile-Key KDF

### The interface table in the previous roadmap is wrong

It specified:

```
tile_id  = <fixed width, matching real tile count>
epoch    = <fixed width>
context  = <fixed width, matching actual customization strings used elsewhere>
```

The actual golden vectors in `kdf_vectors.txt` say otherwise:

| Field | Hex in vector | Decodes to | Length |
|---|---|---|---|
| `ROOT_SECRET` | `000102…1e1f` | binary | 32 B |
| `TILE_ID` | `54494c455f3031` | ASCII **`"TILE_01"`** | 7 B |
| `EPOCH` | `45504f43485f30303031` | ASCII **`"EPOCH_0001"`** | 10 B |
| `CONTEXT` | `50512d4154544553542d4b4446` | ASCII **`"PQ-ATTEST-KDF"`** | 13 B |

`tile_id` is **not** a 3-bit tile index. It is a 7-byte ASCII string. `epoch` is
**not** a counter — it is a 10-byte ASCII string. If you build the RTL with a
fixed-width numeric `tile_id`, you will not reproduce a single golden vector.

They are also **variable length**, and `encode_string` prepends the bit length —
so the encoding itself changes with length. V04 uses a 14-byte context; **V05 uses
an empty context**. The interface must carry `(bytes, byte_length)` pairs, not
bare fixed registers.

### Corrected interface freeze

```
root_secret      [255:0]           // 32 bytes, fixed
tile_id          [MAX_ID*8-1:0]    // byte array
tile_id_len      [$clog2(MAX_ID+1)-1:0]
epoch            [MAX_EPOCH*8-1:0]
epoch_len        [...]
context          [MAX_CTX*8-1:0]
context_len      [...]             // MUST accept 0  (V05)
requested_len    [1:0]             // encodes 16 or 32 bytes
start            1 bit

derived_key      [255:0]           // widest case
key_len          [5:0]             // bytes actually valid
valid / busy / done                // 1 bit each
```

Pick `MAX_ID`, `MAX_EPOCH`, `MAX_CTX` from the real strings plus headroom, and
**write the chosen numbers down** before coding. Suggested: 16 / 16 / 32 bytes.

### Verification questions
1. Do all six golden vectors from `kdf_vectors.txt` pass bit-exact, read from file?
2. V02 changes only `tile_id`, V03 only `epoch`, V04 only `context`. Does each
   produce the **specific** Python output for that change, not merely a different
   value from V01?
3. V05: zero-length context handled correctly by `encode_string`?
4. V06: does `requested_len` actually change KMAC128's squeeze length — proven in
   Stage 3 first?
5. Identical inputs → identical outputs; back-to-back different inputs → no
   leakage between them?
6. `start` while `busy` ignored, in-progress operation unaffected?
7. Does reset clear everything, including any partial hash of a previous
   `root_secret`?
8. Little-endian conversion used for the SV literals, not `.hex()` paste?
9. **Internal checkpoint comparison** for at least one vector: `encode_string`
   output bytes → constructed KMAC input block → absorbed Keccak state → final
   tag. Debugging a 256-bit mismatch blind is how a day disappears.

**Exit gate:** six vectors pass from file, control tests pass, checkpoints match
at least once, confirmed in a real XSim transcript.

---

## [CORRECTED] Stage 6 — Tile Measurement

`M[n] = SHA3-256(TILE_ID || CONFIG || IMEM)`, no separators, no length fields.
Confirmed against `measurement_ref.py` line 97–99.

### The "architecture decision to confirm" is already foreclosed

The previous roadmap asked whether to stream or use a monolithic register.
`sha3_256_core.sv` has already decided, and decided badly for this use:

```systemverilog
input  logic [2175:0] message_block,   // 272 bytes MAX
input  logic [8:0]    message_len,
logic block_index;                     // 1 bit  -> 2 blocks only
logic [1:0] total_blocks;              // always 1 or 2
```

**The existing SHA3-256 core is hard-capped at 272 bytes.** The measurement golden
vectors use a 16-byte IMEM, so they will pass and tell you nothing about the real
case. Any genuine instruction memory — even 1 KB, let alone the 16 KB under
discussion on the NoC side — cannot be hashed by this core.

**This is a Stage 2 scope decision, and it must be made before Stage 5, not at
Stage 6,** because it decides whether Stage 2 gets reopened.

Pick one and write down which:

- **(A) Rewrite `sha3_256_core.sv` as a streaming absorber** with a
  `msg_valid`/`msg_ready`/`msg_last` byte or lane interface and unbounded block
  count. Correct, and it is what a real measurement engine needs. Reopens Stage 2.
- **(B) Redefine "IMEM" in the measurement** to mean a fixed-size config/identity
  blob under 272 bytes, and state explicitly in the paper that full instruction
  memory measurement is out of v1 scope. Honest and cheap, but you must not later
  describe it as measuring instruction memory.

Option (A) is the one I would choose if there is any chance the paper claims to
measure tile firmware. Option (B) is defensible only if the claim is scoped to
match.

### Verification questions
1. Do all six vectors from `measurement_ref.py` pass, read from file?
2. `tile_id`-only change → matches Python's value for that specific change?
3. Same, independently, for config-only and IMEM-only.
4. Empty config/IMEM: does concatenation produce just the tile ID, with no
   phantom separator or padding?
5. Does the multi-block vector exercise more than one absorption block?
6. Does the controller **instantiate** `sha3_256_core`, or reimplement any of it?

**Exit gate:** six vectors pass, each single-input change moves the output exactly
where it should, and the (A)/(B) decision is recorded.

---

## Stage 7 — Runtime Attestation

`TAG = KMAC128(K_tile, TILE_ID || EPOCH || NONCE || MEASUREMENT, out=32 B,
customization="PQ-ATTEST-AUTH")`

**Verified against the Python** (`attestation_ref.py` lines 78–81 and line 28):
field order and customization string are both exactly as the roadmap stated. No
correction needed here.

### Verification questions
1. Tag values reproduce the Python reference bit-exact, read from file?
2. Field order is literally `TILE_ID || EPOCH || NONCE || MEASUREMENT`? A
   NONCE/EPOCH swap still compiles and still yields 256 bits — only the vectors
   expose it. Check against vectors, never by inspection.
3. Nonce-only change → verification fails?
4. Same, independently, for measurement, tile ID, epoch, tile key.
5. Single-bit flip in a valid tag → verification fails?
6. `"PQ-ATTEST-AUTH"` hardwired byte-for-byte?

**Exit gate:** all vectors reproduce; every negative test actually fails.

---

## Stage 8 — Attestation Protocol Boundary  *(decide before Stage 4 and 9)*

Recommended default unchanged: the on-chip Attestation Engine covers measurement,
KDF, tag generation and response construction; request/response sequencing and the
ACCEPT/REJECT decision sit in a verifier not assumed to be built here.

**The architectural fork, restated because two later stages depend on it:**

- **Verifier-issued nonce (challenge-response).** Proves freshness against a
  specific challenge. Matches `Request = (tile_id, epoch, nonce)` in
  `attestation_protocol.py`. **Stage 4's TRNG is then out of scope here.**
- **Tile-generated nonce (self-issued heartbeat).** Proves the tile is alive and
  producing fresh values. Does **not** prove the verifier's specific request was
  answered. Requires Stage 4.

Pick one. Stage 4's existence and Stage 9's replay tests both hang off it.

### Verification questions
1. Which model, and is it consistent with `attestation_protocol.py`?
2. Does the verifier check `tile_id`, `epoch`, `nonce` against the original
   request **before** any cryptographic verification?
3. Tampered response, correct fields, wrong tag → REJECT for a reason
   distinguishable from a field mismatch?
4. Valid pair → ACCEPT using the same tag comparison verified in Stage 7?

**Exit gate:** model decided and written down; ACCEPT works; every invalid case
REJECTs with a distinguishable reason.

---

## [CORRECTED] Stage 9 — Security-Property Regression

The previous roadmap said "nine scenarios" and listed nine. **`security_regression.py`
actually has eleven**, and the list differs:

```
 1. Valid round-trip -> ACCEPT
 2. Replay old response -> REJECT (nonce mismatch)
 3. Patched nonce in old response -> REJECT (tag fail)
 4. Modified measurement -> REJECT
 5. Wrong tile key -> REJECT
 6. Wrong epoch -> REJECT (epoch mismatch)
 7. Wrong root secret -> REJECT          <-- missing from the old roadmap
 8. Fresh nonce -> different tag         <-- missing from the old roadmap
 9. Cross-tile substitution -> REJECT
10. Tampered tag -> REJECT
11. Deterministic -> same ACCEPT
```

All 11 pass in Python today (verified).

**Dependency, unchanged and still the sharpest point in the document:** a KMAC tag
by itself does not prevent replay. `KMAC(K, TILE_ID||EPOCH||N1||M)` stays valid
forever unless something external tracks that N1 was used. Scenarios 2 and 3 only
mean anything once Stage 8 defines **where that freshness state lives**.

### Verification questions
1. Does each of the **eleven** scenarios have an RTL or RTL+TB equivalent, or is
   this stage Python-only? State which, explicitly, per scenario.
2. Replay: does rejection come from the verifier's freshness state — and is that
   state actually implemented in RTL, or is Python passing because the Python
   model tracks state the RTL does not have?
3. Patch-nonce-keep-old-tag: does REJECT come from the tag mismatch, or does the
   freshness check catch it first for an unrelated reason?
4. Cross-tile substitution: rejection specifically from the tile-key mismatch?
5. Determinism: two independent runs compared, not a property asserted once?

**Exit gate:** all eleven pass, with per-scenario RTL-vs-Python coverage stated.

---

## Stage 10 — End-to-End Integration

Reference: `cross_module_regression.py` — **16 checks, verified passing in Python.**
The old roadmap's count was correct here.

One top-level module must actually instantiate KDF + measurement + attestation.
Per-module tests against shared vectors will not catch an interface mismatch
between stages.

### Verification questions
1. Does an RTL chain exist connecting Stage 5, 6, 7, or is this still Python-only?
2. Do all 16 checks reproduce the same pass/fail in RTL?
3. Does the test run Tile-1 then Tile-2 **without a reset between**, proving no
   state leaks?
4. One top-level instantiation, or only isolated per-module tests?

**Exit gate:** one deterministic RTL chain matching all 16 Python checks.

---

## Stage 11A — Functional Freeze

Every RTL TB from Stages 1–10 passes in one aggregate run, bit-exact against
Python, with state isolation proven.

Assertion layer **on top of** KATs, not instead: KATs catch wrong answers,
assertions catch control bugs that produce a right answer by accident.

- `busy` high ⇒ a `start` pulse in that window is ignored
- `done` asserted for exactly one cycle
- reset clears all state, not just the control FSM
- `valid && !ready` holds `valid` until the transfer completes
- no operation proceeds while reset is active
- round/block counters stay in range
- a busy controller's state does not move from inputs it should not be sampling

### Verification questions
1. Single runner invoking every stage's TB, one aggregate pass/fail count?
2. For every stateful block: run A, reset, run B, confirm B does not depend on A.
   This is **different** from testing reset alone.
3. Are the assertions actually in the RTL, or only implied by passing TBs?
4. **Any X or Z propagation in a passing sim?** A test that passes despite
   unknowns is not a clean pass.

**Exit gate:** all TBs pass in one run, zero failures, zero X/Z, Python↔RTL
bit-exact everywhere, state isolation proven, assertions present and passing.
**FUNCTIONAL FREEZE.**

---

## Stage 11B — Implementation Freeze

Only after 11A. Synthesis, implementation, timing, utilization on the
Arty A7-100T (`xc7a100tcsg324-1`) — **measured, not estimated**.

### Verification questions
1. Synthesis completes without errors against the target part?
2. Actual LUT / FF / BRAM / DSP numbers?
3. Actual Fmax, and is WNS ≥ 0 at 50 MHz?
4. Keccak is now shared across SHA3, KMAC, KDF and attestation. **Is it actually
   the critical path?** Measure it from the timing report; do not assume.
5. If 1-round-per-clock does not close, is the response a deliberate
   architectural change, not an ad hoc pipeline stage added to pass one number?
6. Is there a **written** record that survives the Vivado session closing?

**Note for later integration:** the NoC lane will have its own clock target. Record
this lane's Fmax as a number, not just a pass/fail at 50 MHz, so the two can be
reconciled when the lanes merge.

**Exit gate:** synthesis clean, timing closed at ≥ 50 MHz, utilization recorded in
writing. **IMPLEMENTATION FREEZE.**

---

## Decisions needed from Kalash before any RTL is written

1. **Stage 6 / SHA3 capacity:** option (A) rewrite `sha3_256_core.sv` as a
   streaming absorber, or (B) redefine "IMEM" as a ≤272-byte blob and scope the
   paper claim to match? This decides whether Stage 2 reopens.
2. **Stage 8 nonce origin:** verifier-issued or tile-generated? This decides
   whether Stage 4 (TRNG RTL) is in scope at all.
3. **Stage 5 field widths:** confirm `MAX_ID` / `MAX_EPOCH` / `MAX_CTX`
   (suggested 16 / 16 / 32 bytes) given that `tile_id` and `epoch` are ASCII
   strings, not numbers.
4. **Provenance:** the old roadmap's Stage 10 refers to *"the same class of bug
   that showed up between `kmac_encode.sv` and `kmac128.sv` earlier in this
   project."* Neither file is in the archive I was given. Is there RTL I have not
   seen, or did that history get invented?

---

## Corrected build order

```
Stage 0   close the gaps in what is claimed closed      <- start here
Stage 1   Keccak-f1600  (needs a TB; currently has none)
Stage 2   SHA3-256      (TB must read Python vectors; capacity decision)
Stage 3   KMAC128 RTL   <- DOES NOT EXIST, real next build
Stage 4   TRNG          (in scope only if Stage 8 says tile-generated nonce)
Stage 5   Tile-Key KDF  (corrected interface)
Stage 6   Measurement   (blocked on the Stage 2 capacity decision)
Stage 7   Attestation
Stage 8   Protocol boundary  (decide early — Stages 4 and 9 depend on it)
Stage 9   Security regression (11 scenarios, not 9)
Stage 10  Integration (16 checks)
Stage 11A Functional freeze
Stage 11B Implementation freeze
```

---

## What comes after this document's scope

ML-DSA, RISC-V integration, the NoC, and CRPA all sit outside what the Python
reference folders define. None are exit criteria here. This roadmap is done when
11B passes — the end of the cryptographic/attestation closure phase, not the end
of PQ-Attest.
