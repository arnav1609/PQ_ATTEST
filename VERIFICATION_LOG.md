# PQ-Attest NoC — Verification Log

## Stage 2 — Router foundation

**Status: NOT SIGNED OFF.** The testbench printed `OVERALL : PASS`, but four
XSim limitations found in the elaboration log mean that PASS did not yet carry
the evidence it claims. Re-run required after the fixes below.

---

### Run 1 — 2026-09-06

| Block | Reported | Real status |
|---|---|---|
| noc_pkg | PASS | PASS |
| noc_fifo | FAIL (2) | TB stimulus defect |
| noc_crossbar | PASS | PASS |
| noc_xy_routing | PASS + 7 immediate-assertion errors | Algorithm correct, checker raced |
| noc_router_datapath | FAIL (36) | TB assertion defect |

**Zero RTL functional defects.** Five testbench defects, all in checker or
stimulus code.

| ID | Defect | Root cause |
|---|---|---|
| V-01 | 36 false "VC leaked" failures | Property required `$stable(empty_north_vc1)` while the same phase drove `rd_en_north_vc1`. A read that empties a VC legitimately changes that flag; the property blamed the write. **Also too weak** — `empty` only moves at the 0↔1 boundary, so real leakage into a non-empty VC would have passed |
| V-02 | `read attempted while empty` in phases labelled legal | `$asserton` re-armed while a stale random `rd_en` from the previous phase was still asserted |
| V-03 | `FLIT DROPPED` in a legal-traffic phase | Valid gated on `!(all three VCs full)`, which still permits a write to an individually full VC |
| V-04 | XY immediate assertion fired sporadically | Delta-cycle race between separate combinational processes — see V-06 |
| V-05 | Reset mid-traffic produced a false underflow | Reset empties the FIFOs while a stale read strobe is still asserted |

---

### Run 2 — 2026-09-06

Reported `OVERALL : PASS`, all five blocks clean. **The XY assertion still
fired 4 times**, and the elaboration log exposed three further problems that
invalidate the PASS.

| ID | Finding | Severity | Why it matters |
|---|---|---|---|
| **V-06** | `$assertoff` / `$asserton` **with a scope argument is not supported by XSim** (`[XSIM 43-4481]`). It silently degrades to `$assertoff(0)` — **every assertion in the entire design, including the testbench's own SVA**, was switched off | **Critical** | Phases 3, 4, 8 and 9 ran with **no checking at all** and still contributed to a PASS. That is roughly half the FIFO stimulus and all of the datapath stress traffic |
| **V-07** | `cover property` is **not supported by XSim** (`[XSIM 43-4127]`). Every cover statement was discarded | **Critical** | The run produced **no evidence** that the guarded corners were reached. An assertion that never observes the state it guards is indistinguishable from a broken one |
| **V-08** | `always_comb` reading `model_a.size()` / `model_a[0]` — XSim drops queue-element sensitivity (`[XSIM 43-5612]`) | **High** | A combinational block whose only sensitivity is queue elements has **no** sensitivity. The reference-model mirrors could freeze at time zero, making the FIFO comparison **vacuous** — and a vacuous checker reports PASS forever |
| **V-09** | XY immediate assertion still firing after the first fix | Medium | The race was one level higher than diagnosed: between the **compute** block (`computed_port`) and the **qualify** block, not between qualify and check. Moving only the assertions was insufficient |
| **V-10** | RTL modules carry no `` `timescale `` (`[XSIM 43-4100]`) | Low | Mixed-timescale designs can behave differently between tools |

---

### Fixes applied after Run 2

| ID | Fix |
|---|---|
| V-06 | All `$assertoff` / `$asserton` calls **removed**. DUT assertions now fire during the deliberate-violation phases; that console noise is expected and documented. Testbench SVA stays armed for the entire run |
| V-07 | Procedural coverage counters added for all 25 guarded states, printed in the report, with an explicit **COVERAGE HOLE** verdict when any counter is zero |
| V-08 | Model mirrors moved into the clocked block, updated with blocking assignments immediately after the queue is modified. No dependence on queue sensitivity |
| V-09 | Coordinate check, route computation, output qualification and both immediate assertions collapsed into **one** `always_comb`, making evaluation atomic |

---

### Lessons

1. **A tool warning about an unsupported construct is a verification result,
   not noise.** Three of the four problems above were printed during
   elaboration of Run 1 and ignored because the run "passed".

2. **Assertion control is not portable.** Scoped `$assertoff` is silently
   global in XSim. Prefer structuring stimulus so illegal traffic is confined
   to phases where console noise is acceptable, over disabling checkers.

3. **Never let a checker depend on a dynamic type's sensitivity.** Mirror into
   plain variables inside a clocked block.

4. **Combinational immediate assertions belong in the same procedural block as
   the logic they check.** Any separation is a delta-cycle race, and it
   presents as a sporadic functional failure.

5. **A clocked and an unclocked checker disagreeing about the same property
   means the unclocked one is wrong.** That disagreement is what located V-04
   and V-09.

---

### Sign-off criteria for Stage 2

All must hold in a single run before Stage 2 is closed:

1. `OVERALL : PASS`, zero failures in all five blocks
2. **Zero** immediate-assertion errors from `noc_xy_routing`
3. `All guarded states were exercised` — no coverage hole
4. No `read attempted while empty` or `FLIT DROPPED` in any phase labelled
   *legal traffic*
5. A **negative control** passes: inject a deliberate defect, confirm the
   testbench reports FAIL, then revert. Until this is done, a PASS only proves
   the testbench did not fail — not that it is capable of failing

Then, and only then: the router resource synthesis probe.

---

## Golden-model exhaustive verification — 2026-09-06

**Method.** `golden/golden_model.py` implements the NoC from the
**specification** and has never read the RTL. `golden/rtl_model.py` is a
line-by-line transcription of what the **RTL says**. The two were compared
exhaustively.

### Result

```
XY routing (4096 exhaustive)                             4,096
Crossbar (8^5 selects x 2^5 valids)                    537,824
FIFO depth 4   (80 transitions, 0 uncovered)                89
FIFO depth 6   (168 transitions, 0 uncovered)              183
FIFO depth 8   (288 transitions, 0 uncovered)              309
FIFO depth 16  (1088 transitions, 0 uncovered)           1,133
FIFO depth 3   (48 transitions, 0 uncovered)                54
FIFO depth 5   (120 transitions, 0 uncovered)              132
FIFO depth 7   (224 transitions, 0 uncovered)              242
FIFO ordering (40k sequences x 9 cycles, 2 depths)      80,004
VC decode (exhaustive)                                       8
VC mux (2^3 selects x 2^3 empty states, exhaustive)         64
Address decode (16 regions x 16 selectors + locals)        263
Packet length table                                          8
tile <-> coord round trip                                    6
---------------------------------------------------------------
TOTAL COMPARISONS                                      624,415
RESULT                                        ZERO MISMATCHES
```

The model's own self-check passed first: convergence, mesh diameter, turn
restriction, out-of-mesh rejection and FIFO invariants all hold in the golden
model before it was permitted to judge anything.

### What this establishes

- The routing function is correct over the **entire** input space, not a
  sample. Including every illegal coordinate.
- The FIFO control FSM is correct at **seven depths**, including the
  non-power-of-two cases 3, 5 and 7. Every reachable state driven with every
  input, legal and illegal, zero uncovered transitions. The original spec only
  required depth 4 to work; the explicit wrap comparison generalises.
- The crossbar mapping is correct across the full 8^5 select space crossed
  with all 32 valid patterns, illegal encodings 5–7 included.
- The address decoder rejects all 10 unmapped tile selectors and all six local
  regions. Decision L-08 holds.
- `priority case` VC-mux resolution is deterministic across all 64
  select/empty combinations.

### What this does NOT establish

Transcription captures what the source **says**, not what the tool **does**.
Outside its reach entirely:

- delta-cycle and scheduling behaviour (this is what produced V-04 and V-09)
- X propagation and reset-release behaviour
- enum casts of out-of-range values
- latch inference and synthesis semantics
- packed-union support in Vivado
- `ram_style` honouring and the resulting resource cost

**Only XSim and Vivado synthesis can close those.** This narrows the search
space; it does not replace the run.

### Testbench defects found and fixed before first execution

`TB_GOLDEN.sv` was audited before being handed over. Five defects, all mine:

| # | Defect | Consequence |
|---|---|---|
| 1 | `32'hVC00_0000` — `V` is not a hex digit | Would not compile |
| 2 | `e_count[$clog2(depth+1)-1:0]` where `depth` is a task argument | Non-constant part-select, illegal |
| 3 | `(es[o] < 0) ? '0 : xb_in[es[o]]` | Index of −1 on illegal selects; ternary does not reliably prevent evaluation |
| 4 | `flit_t f;` declared mid-block | Rejected by stricter parsers |
| 5 | Width-select applied to an `int` in the VC comparison | Wrong comparison semantics |

Running total for Stage 2: **fourteen testbench defects, zero RTL defects.**

---

## Run 3 — 2026-09-09 — Stage 3 + crypto lane static review and repair

**Status: STAGE 2 STILL NOT SIGNED OFF.** Nothing below changes that. The
Stage 2 coverage hole (`DP all three VCs full : 0`) and the Stage 2 negative
control are still open. Stage 3 (M6/M7) and the Keccak lane were built on top
of an unverified PASS; that ordering was wrong and is being corrected now.

### Defects found

All six blocking defects were **elaboration blockers**, not behavioural bugs.
None of them could have been found by running the simulator, because nothing
compiled.

| # | File | Defect | Class |
|---|------|--------|-------|
| A1 | `allocator.sv` | Instantiated `NOC_XY_ROUTING`; module is `noc_xy_routing`. SystemVerilog is case-sensitive. | Unresolved reference |
| A2 | `allocator.sv` | Connected scalar `current_x/current_y/dest_x/dest_y`; module takes two `coord_t` structs. | Port mismatch |
| A3 | `allocator.sv` | Declared `port_e route_port[]`; module output is `port_id_t`. Same family as L-01. | Type mismatch |
| K1 | `pq_keccak_round.sv` | `keccak_f1600` instantiated `keccak_round`, which existed in no file. The five step modules were never chained. | Missing module |
| T1 | `stage3_tb.sv` | `logic grant_valid [NUM_PORTS]` (unpacked) connected to `output logic [NUM_PORTS-1:0]` (packed). | Illegal connection |
| F1 | `pq_keecak_iota.sv` | 0-byte misspelled duplicate. | Stray file |

### V-11 — transposed golden vector in `pq_keccak_tb.sv`

**The most dangerous defect in this run, and it would not have looked like a
testbench defect.**

Twenty of the twenty-five hand-typed `expected_zero` lanes were wrong —
transposed, not mistyped. The Python reference prints the state with `y` as
the outer loop, so printed row 0 is `state[0][0] … state[4][0]`; the testbench
read the printed row index as the *first* subscript. Only the five diagonal
lanes landed correctly.

The RTL is correct. Running that testbench produces twenty lane failures
against a correct implementation, and the obvious response is to start editing
θ/ρ/π/χ. **That is V-01 again** — 36 "VC leaked" failures that were a wrong
property, not a wrong DUT.

Fix: expected values are no longer transcribed. `gen_keccak_vectors.py`
emits them in the RTL's own `[x][y]` order and the testbench reads them with
`$readmemh`. The rho offsets and iota round constants in `pq_keccak_pkg.sv`
were **derived** from their algorithmic definitions and compared, not taken
on trust.

### Non-blocking issues fixed

| ID | Issue |
|----|-------|
| K2 | `pq_keccak_round.sv` held module `keccak_f1600` — file/module name disagreement (L-02). `keccak_f1600` moved to `pq_keccak_f1600.sv`. |
| K3 | Keccak used active-low `rst_n`; the NoC uses active-high `rst`. Two polarities in one SoC violates the plan's Stage 0 exit gate. Keccak converted to active-high. |
| K4 | `keccak_f1600` gained `round_valid` / `round_index` observation ports. Plan §5 requires comparison "at meaningful internal checkpoints, not only final output"; without these a wrong step module is only observable 24 rounds later. |
| K5 | `round_t` is 5 bits and indexed a 24-entry constant array. Clamped and asserted. |
| K6 | `keccak_pi` rewritten from scatter to gather form. The bijection was verified numerically at all 25 positions; the gather form makes full assignment structural rather than something the synthesiser has to prove. |
| V-10 | `timescale 1ns/1ps` added to all NoC and Keccak modules. |
| A4 | New assertion `a_owner_presents_body_or_tail` — catches the *cause* of the condition `a_input_vc_one_output_max` guards. |
| A5 | Coverage counters added to `NOC_ALLOCATOR` (XSim rejects `cover property`, XSIM 43-4127). `cov_multi_output_request` must be driven non-zero by a directed malformed-packet test before M7 can be signed off — per V-07, an assertion whose guarded state is never reached is indistinguishable from a broken one. |

### Open — NOT fixed, requires a decision

**M7 does not connect to M3 or M4 as built.** This is an interface gap, not a
typo, and inventing an adapter silently would be worse than naming it:

- `NOC_ALLOCATOR.xbar_sel` is a 4-bit **input-VC** index (0–14).
  `noc_crossbar.select_*` is a 3-bit **port_id_t** (0–4). Different widths,
  different meaning.
- `NOC_ALLOCATOR.fifo_rd_en` is a 15-bit vector.
  `noc_router_datapath` takes fifteen **scalar** ports `rd_en_<port>_vc<n>`
  and fifteen more `sel_<port>_vc<n>`.
- `noc_crossbar`'s L-07 contract requires the select to be **held from HEAD to
  TAIL**. `NOC_ALLOCATOR` drives `xbar_sel` combinationally from `arb_valid`,
  so on any stall cycle it drops to 0 — which decodes as `PORT_NORTH`, not as
  "idle". The crossbar cannot detect this and does not try to.

A router top level (M8) has to own this mapping. It does not exist yet, which
is why the mismatch has not surfaced: `stage3_tb` instantiates `NOC_ALLOCATOR`
alone.

### Verification status of this run

**Static review only. Nothing here has been simulated.** No SystemVerilog
simulator was available in the review environment. The Python reference *was*
executed and reproduces the standard Keccak-f[1600] zero-state vector, and the
rho/iota constants and the pi gather form were verified numerically. Every
statement about the RTL itself is source review, not execution.

Running total: **fifteen testbench defects, zero RTL defects.**

---

## Run 4 — 2026-09-09 — Stage 3 golden-model equivalence

**Result: OVERALL PASS.**

*Correction (2026-09-09, on audit):* this was originally written as "the first
reference-model equivalence check in the project". **That is wrong.**
`golden/golden_model.py` (2026-09-06) already established the method for Stage
2 — XY routing complete over all 4096 coordinate combinations, crossbar
complete over all 8^5 = 32,768 select combinations, FIFO complete transition
coverage via a BFS covering walk, VC decode complete. Stage 3 followed an
existing precedent rather than setting one. The claim is corrected here rather
than quietly edited, because overstating a first is the same class of error as
overstating a result.

### Evidence

| Check | Scope | Result |
|---|---|---|
| Phase A, arbiter | **491,520 / 491,520 vectors** — all 2^15 request patterns x all 15 pointer values. Complete, not sampled. | **0 mismatches** |
| Phase B, allocator | 20,000 cycles, cycle-accurate, well-formed traffic. grant, grant_valid, xbar_sel, fifo_rd_en, output_locked, output_owner compared every cycle. | **0 output, 0 state mismatches** |
| Phase C, negative control | 2 deliberate defects injected | **2 / 2 detected** |
| `NOC_ALLOCATOR` assertions | during Phase B | **0 fired** |

Phase A runs with the **clock stopped**, so no concurrent assertion evaluates
at all. The combinational arbitration function was judged on its outputs
alone, with the disputed SVA removed from the experiment by construction.

The Python model was written from the specification, not transliterated from
the RTL, and self-checks before emitting anything — including a routing
convergence proof over all 36 source/destination pairs with strictly
decreasing Manhattan distance.

### V-12 — the arbiter assertions were broken, the arbiter was not

Against those zero mismatches, `NOC_ARBITER` raised **179,984** assertion
failures in the same run:

| Assertion | Fires | Truth |
|---|---|---|
| `a_grant_implies_request` | 79,984 | design correct |
| `a_valid_matches_grant` | 100,000 | design correct |
| `a_onehot_grant` | 0 | **could not fail** |

`$sampled()` gave the cause directly:

```
SAMPLED : grant=00000000000000000xxxxxxxxxxxxxxx
CURRENT : grant=010000000000000
```

`grant` and `grant_valid` are combinational outputs of the arbiter's
`always_comb`. `rr_ptr` updates by NBA on the same clock edge and re-triggers
that block, so the **preponed value is X**. Every failure was the checker
reading a value that never existed on the wire.

The silent one is the more dangerous half: `a_onehot_grant` did not hold — it
was never able to fail, because `$onehot0(X)` does not evaluate false. Per
V-07 that is worse than having no assertion.

**This is V-09 one level up.** In `noc_xy_routing` the fix was to collapse
compute, qualify and check into a single `always_comb` so the checker sees one
atomic snapshot. Same defect class, same fix: the three properties are now
IMMEDIATE assertions inside the `always_comb`, guarded by `!$isunknown(req)`.
`a_pointer_stable_without_grant` and `a_req_not_unknown` stay concurrent —
they reference a real register and an input, whose preponed values are well
defined.

### T09 state leak (stage3_tb)

T09 injects a HEAD with no TAIL, so the EAST reservation is never released —
inherent to the defect, not an oversight. Cleanup was `clear_inputs()` and two
ticks, which does nothing to reservation state, so EAST stayed locked for the
rest of the run and T10/T11 executed against a corrupted DUT. That produced 4
spurious `TB: VC0 granted to more than one output` failures and 3
`owner presents HEAD mid-packet` errors belonging to T09. T09 now ends with
`reset_dut()` and verifies all five locks are clear.

### Coverage-counter defect (stage3_golden_tb)

The Phase A coverage loop strided by 97 "for speed" and reported
`arb: all 15 requesting : 0`, flagging a COVERAGE HOLE on a run that had
compared all 491,520 vectors including that one. `req` all-ones occurs 15
times, at indices `ptr*32768 + 32767`; a stride of 97 never lands on them.
A coverage counter that under-reports manufactures doubt about a complete
result. Now counted exactly.

### Status

- **Arbitration logic: proved equivalent to an independent model over its
  complete combinational input space.** Not sampled. Complete.
- Allocator: 20,000 cycles equivalent, including reservation state.
- Still open, unchanged: credit flow control (D1), the M7->M3 / M7->M4
  interface mismatch (needs M8), and `xbar_sel` hold across stalls (L-07).

Running total: **eighteen testbench/checker defects, zero RTL defects.**

### Run 4b — confirmation after the V-12 fix

Both testbenches re-run with the immediate assertions in place.

**`tb_stage3_golden` — OVERALL PASS, and now with exact coverage:**

```
arbiter vectors compared      : 491520 of 491520
allocator cycles compared     : 20000
arb: no requester             : 15
arb: exactly one requester    : 225
arb: several requesters       : 491265
arb: all 15 requesting        : 15
arb: pointer wrapped to win   : 32752
NEG defects injected/detected : 2 / 2
  Arbiter proved EXHAUSTIVELY equivalent to the model
  over its complete combinational input space.
```

The four request-population buckets sum to exactly 491,520 — the partition is
complete, so the coverage figures now account for every vector rather than a
strided sample.

**`tb_noc_allocator` — OVERALL PASS.** Round robin measured as
`winners: 1 0 1 0 1 0 (5 rotations)`. The arbiter control experiment reads
zero on every instance:

```
ARB[NORTH] checks=16  grant_wo_req=0  valid_mismatch=0
ARB[SOUTH] checks=16  grant_wo_req=0  valid_mismatch=0
ARB[EAST ] checks=16  grant_wo_req=0  valid_mismatch=0
ARB[WEST ] checks=16  grant_wo_req=0  valid_mismatch=0
ARB[LOCAL] checks=16  grant_wo_req=0  valid_mismatch=0
```

**Zero NOC_ARBITER assertion failures**, against 179,984 in the previous run
on the same RTL. V-12 is closed and the fix is confirmed by three independent
readings: exhaustive model equivalence, the procedural counters, and the
now-silent immediate assertions.

### A7 — coverage counters were cleared by reset

`tb_noc_allocator` still reported `DUT multi-output request : 0` and declared
a COVERAGE HOLE, on a run whose own log shows T09 printing
`VC0 requested 2 outputs, won 2` and both DUT assertions firing.

Cause: the allocator's coverage counters were reset on `rst`, and T09 now ends
with `reset_dut()` to clean up the corruption it deliberately injects. The
reset zeroed the evidence one microsecond after it was produced.

Coverage answers "was this state EVER reached in this run". Reset is a normal
mid-run event here, so tying coverage to it silently changes the question to
"reached since the last reset". Counters are now initialised at declaration
and never cleared. `cov_head_acquire` and `cov_tail_release` were being
undercounted by the same mechanism (2 and 2 reported, 5 and 4 actual).

Also fixed: `expected_dut_errors` said 1 for T09, which raises two assertions,
not one. A wrong expected count would make a correct future run look like a
regression.

### V-10 closed

The "at least one module in design doesn't have timescale" warning survived
every module being fixed, because the two **packages** (`noc_pkg`,
`keccak_pkg`) had none. Added. A package has no processes so nothing changes
behaviourally — but a warning that is always present is a warning that gets
ignored by habit, and that is how a real one gets missed.

Running total: **twenty testbench/checker defects, zero RTL defects.**

---

## Run 5 — 2026-09-10 — M7 restructure, M8 written, Python cycle model

**NOT A SIMULATION RESULT.** No SystemVerilog simulator was available. Every
result in this entry comes from `sim_noc_router.py`, a Python transliteration
of the RTL. It cannot prove elaboration, width truncation, X propagation,
latch inference or delta-cycle behaviour. `xelab`/`xsim` remain outstanding.

### A9 — the structural defect that forced the M7 rewrite

`noc_router_datapath` gives each **physical input one path to the crossbar**.
The single-stage allocator ran five independent 15-way arbiters over the
flattened input-VC space, so it could grant

```
NORTH VC0 -> EAST     and     NORTH VC1 -> WEST
```

in one cycle. Both grants individually legal; the datapath carries one.
`fifo_rd_en` pops **both** FIFOs, one flit reaches the crossbar, **the other is
destroyed**. Silent packet corruption.

Invisible to everything that existed: `stage3_tb` used VCs on different ports,
and the golden model modelled the allocator's decision rather than the
datapath's structural limit. It surfaced only when `noc_router` was written and
`a_onehot0_north` in the datapath fired on legal traffic.

**Fix: two-stage separable input-first allocation.**

```
stage 1   per physical input, N=3 arbiter -> one VC AND its single target output
stage 2   per output,         N=5 arbiter -> one physical input
```

`NOC_ARBITER` is reused **unmodified** at both widths — verified at n = 3, 5, 15:
no winner or pointer overflow, grant always one-hot0 and always implying a
request, at every reachable pointer value.

### A9-b — the model caught my first architecture before any RTL existed

Selecting only the VC in stage 1 is **not sufficient**. The five stage-2
arbiters are independent, so two outputs can both select the same physical
input — the identical hazard, one level up. The self-check failed immediately:

```
AssertionError: A9 VIOLATED: input won 2 outputs [0, 0, 1, 2]
```

Stage 1 now selects the VC **and its single target output**, so `out_req` has at
most one bit per input by construction. This is the entire argument for
updating the model before the RTL.

### A10 — the trap in the rewrite

Stage 2's winner is a **physical port index**, not a VC index. The old code read
`head_flit[arb_winner[p]]`. Left unchanged it reads the wrong flit and corrupts
the reservation. Every site now goes through `head_flit[cand_vc[out_winner[p]]]`.

### Bug 1 (M8) — input-side valid gated by an output-side grant

```systemverilog
.in_valid_north (crossbar_valid_north & xbar_valid_north)   // WRONG
```

`in_valid_X` means "input X has a flit"; `xbar_valid_north` meant "the NORTH
**output** has a grant". On NORTH -> EAST the flit was **dropped** — the most
ordinary turn in the router. Inputs are now offered unconditionally and each
**output** is masked with its own `grant_valid` (contract L-07, correct index).

### Bug 2 (M8) — found by the Python model, would have fired on every N->E

`select_*` defaulted to `PORT_NORTH`. `noc_crossbar` asserts

```
!(in_valid_north && select_north == PORT_NORTH)
```

and that assertion knows nothing about grants. On NORTH -> EAST,
`crossbar_valid_north` is high while the NORTH output has no grant and its
select still sits at its `PORT_NORTH` default — so the crossbar sees a
NORTH-to-NORTH loopback and fires.

**An idle select must not be a real port.** Added `noc_pkg::PORT_NONE = 3'd7`,
outside the legal range; the crossbar's existing `default` branch already
zeroes the output for it.

### Model results

```
T1  LOCAL -> EAST                                  PASS
T2  NORTH -> EAST   (Bug 1 regression)             PASS
T3  NORTH -> WEST                                  PASS
T4  SOUTH -> EAST                                  PASS
T5  NORTH VC0->EAST + VC1->WEST : exactly one      PASS   <- A9
T6  NORTH->EAST and SOUTH->WEST simultaneously     PASS
T7  two inputs contend for EAST : one wins         PASS
T8  wormhole HEAD/BODY/BODY/TAIL, order preserved  PASS
T9  HEAD_TAIL leaves no reservation                PASS
T10 reset clears traffic and reservations          PASS
T11 EAST not stolen while LOCAL owns it            PASS
SOAK 20,000 random cycles, all invariants          PASS
```

Two of the three initial failures were **my testbench**, not the design: T8
collected outputs only after the pushes, by which time three of four flits had
already been forwarded; and the soak drew destinations that produce a U-turn.

### OPEN — no defence against a misrouted incoming flit

Constraining the soak exposed a real gap. A flit arriving on EAST cannot
legitimately be destined further east — XY routing at the upstream router would
never have sent it. `noc_crossbar` **asserts** the U-turn but nothing
**prevents** it. With a hostile tile in the mesh (SPOOF at (2,1)), a crafted
header is exactly this attack. Belongs in Phase 10/11; recorded here so it is
not rediscovered by accident.

Running total: **twenty-three testbench/checker defects, two RTL defects**
(both introduced today in new code: A9 architecture, Bug 1 wiring; both found
before any simulator saw them).
