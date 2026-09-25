# Plan Compliance Audit — 2026-09-09

Does the existing RTL match `NOC_WORKSTREAM.md`? Audited by reading the files
on disk, not from memory. Every claim below is checked.

---

## Headline

**Phases 1–3 are substantially complete and better verified than the plan
required. Phase 2.5 has not started, and that is now the blocking item.**

The single most important fact from this audit:

> **`NOC_PQATTEST.runs/` does not exist. There is no `.xdc` anywhere in the
> project. Synthesis has never been run — not once.**

Every number in this project is a simulation number. There is no LUT count, no
FF count, no Fmax, no WNS. That is exactly the gap Phase 2.5 exists to close,
and it is why moving it ahead of Phase 3.5 was the right call.

---

## Phase-by-phase

### PHASE 1 — Architecture Freeze — **PARTIAL**

| Item | Status | Evidence |
|---|---|---|
| `noc_pkg` frozen | **DONE** | 762 lines, P7 note "parameter changed to localparam throughout" |
| Topology / ports / VCs / flit / depth / routing / flow control / switching | **DONE** | all present as `localparam` |
| Reset convention | **DONE** | synchronous active-high, now uniform after the Keccak K3 fix |
| `tb_noc_pkg.sv` | **NOT AS PLANNED** | no such file; the package self-check lives inside `TB1.sv` as the `[PKG]` block. Functionally covered, structurally different from the plan. |
| **O-01** tile-selector encoding | **IMPLEMENTED, NOT DOCUMENTED** | `tile_id_e` = CPU0 0, CPU1 1, MEMORY 2, CRYPTO 3, ROT 4, SPOOF 5; `decode_address()` maps `address[27:24]` straight through `tile_to_coord()`. The encoding *is* frozen in code. |
| **O-02** packet length table | **DONE** | `message_payload_flits()` defines all eight message types |
| **O-03** MAC width and scope | **WIDTH DONE, SCOPE OPEN** | `MAC_TAG_BITS = 128`, `MAC_FLITS_FULL = 4`. *Which header fields are authenticated* is still undefined. |
| `N_OUTSTANDING` | **MISSING** | the only "OUTSTANDING" in the package is a comment about the RoT's single challenge (L-11). No NI parameter exists. |
| `noc_architecture.md` | **MISSING** | |
| `packet_format.md` | **MISSING** | |
| `address_map.md` | **MISSING** | |
| `vc_definition.md` | **MISSING** | |

**Correction to `NOC_WORKSTREAM.md`:** I listed O-01 and O-02 as open. **O-02
is closed and O-01 is closed in code.** What is genuinely missing is the
*documentation*, not the decision. The four architecture `.md` files do not
exist, so the freeze lives only inside a 762-line source file. For an IEEE
submission that is a problem — a reviewer cannot read `localparam` declarations
as a specification.

**Genuinely open:** O-03 scope, and `N_OUTSTANDING`.

---

### PHASE 2 — Router Datapath — **DONE, exceeds plan**

| Module | File | State |
|---|---|---|
| M1 `noc_pkg` | `NOC_PKG.sv` | frozen |
| M2 `noc_fifo` | `NOC_FIFO.sv` | verified, `ram_style="distributed"`, credit hooks present |
| M3 `noc_crossbar` | `NOC_CROSSBAR.sv` | verified, all 5 no-loopback assertions present |
| M4 `noc_router_datapath` | `NOC_DATAPTAH.sv` | verified |

Stage 2 signed off 2026-09-09: `OVERALL PASS`, `DP all three VCs full : 7`,
negative control 2/2, `All guarded states were exercised`.

**Deviation from plan, in your favour.** The plan asked for `tb_noc_fifo.sv`,
`tb_noc_crossbar.sv`, `tb_noc_router_datapath.sv` as separate testbenches. What
exists is one combined `TB1.sv` (`tb_noc_stage2`) with five per-block scoreboards,
plus `goldenmodel.sv` (`tb_noc_golden`) doing reference-model equivalence.
Coverage is *better* than the plan asked for. The plan should be amended to
match reality rather than the files renamed.

**M4 exposes credit outputs already** — `credit_<port>_vc<n>` for all 15, with
comments naming `noc_credit_control` as the consumer. Phase 4 is pre-wired.

---

### PHASE 2.5 — Area + Timing Probe — **NOT STARTED — BLOCKING**

| Item | Status |
|---|---|
| `RESOURCES.md` | **MISSING** |
| Any `.xdc` constraints | **MISSING** |
| `NOC_PQATTEST.runs/` | **DOES NOT EXIST** |
| Any synthesis run, ever | **NO** |

This is the largest gap between plan and reality. Nothing here is a
"nice to have": until this runs, the per-router LUT/FF cost is unknown, the
6-router projection is unknown, and the crypto lane's budget is unknown.

**Minimum to unblock:** an `.xdc` with a 50 MHz clock constraint, then OOC
synthesis of `noc_fifo`, `noc_crossbar`, `noc_router_datapath`, and
`NOC_ALLOCATOR`.

---

### PHASE 3 — Routing + Allocation — **DONE, exceeds plan**

| Module | File | State |
|---|---|---|
| M5 `noc_xy_routing` | `NOC_XY_ROUTING.sv` | verified; V-09 delta-cycle race closed |
| M6 `NOC_ARBITER` | `NOC_arbiter.sv` | **exhaustively equivalent**, 491,520/491,520 |
| M7 `NOC_ALLOCATOR` | `allocator.sv` | equivalent over 20,000 cycles, outputs + state |

Both Stage 3 testbenches pass. V-12 closed: the three broken concurrent
assertions replaced with immediate assertions inside the `always_comb`.

**Exceeds plan:** the plan asked for `tb_noc_allocator.sv` with SVA. What exists
is that *plus* `stage3_golden_tb.sv` doing exhaustive model equivalence with the
clock stopped. That is a stronger result than the plan specified.

---

### PHASE 3.5 — Router Top Level — **NOT STARTED**

`noc_router.sv` does not exist. The five interface mismatches documented in
`NOC_WORKSTREAM.md` §3.5 are all still present. Confirmed by re-reading both
port lists this session.

---

### PHASES 4–14 — **NOT STARTED** (as expected)

No `noc_credit_control`, `noc_ni`, `noc_addr_decoder`, `noc_mesh`,
`noc_l2_auth`, `noc_attest_gate`, `noc_fault_status`, `noc_top`.

---

## Cross-cutting findings

### F1 — Synthesis has never been run

Stated again because it is the finding that matters. No `.xdc`, no `.runs/`.
**Do not report any area or timing figure until this changes**, and when it
does, report area with Fmax, never alone.

### F2 — L-02 is violated on 15 of 20 files

Distinguishing two cases, because they are not equally dangerous:

**Case-only (5 files) — cosmetic on Windows, breaks on Linux/CI:**

```
NOC_CROSSBAR.sv    -> noc_crossbar
NOC_FIFO.sv        -> noc_fifo
NOC_PKG.sv         -> noc_pkg
NOC_XY_ROUTING.sv  -> noc_xy_routing
NOC_arbiter.sv     -> NOC_ARBITER
```

**Genuinely different (15 files) — this is the dangerous class:**

```
NOC_DATAPTAH.sv    -> noc_router_datapath     (typo + different)
allocator.sv       -> NOC_ALLOCATOR
TB1.sv             -> tb_noc_stage2
goldenmodel.sv     -> tb_noc_golden
stage3_tb.sv       -> tb_noc_allocator
stage3_golden_tb.sv-> tb_stage3_golden
pq_keccak_*.sv     -> keccak_*                (9 files)
```

**This is not theoretical.** `allocator.sv` was overwritten with the contents of
`stage3_tb.sv` earlier today. `module NOC_ALLOCATOR` vanished from the project
and nothing elaborated. A file called `allocator.sv` that contains
`NOC_ALLOCATOR` gives no protection against that; a file called
`NOC_ALLOCATOR.sv` makes the mistake visible the moment it happens.

**Correction to `NOC_WORKSTREAM.md`:** I wrote "two files have violated this".
The real number is 15 of 20.

### F3 — A Stage-2 golden model already existed

`golden/golden_model.py`, dated 2026-09-06, with vectors `gv_xy.txt` (4096),
`gv_xbar.txt` (16,807 replayed of 32,768 generated), `gv_fifo4/6.txt`,
`gv_vc.txt`, replayed by `goldenmodel.sv`.

Its docstring states the same discipline used for Stage 3: *"Written from the
SPECIFICATION only. It has never read the RTL."*

**This corrects an error in `VERIFICATION_LOG.md`**, where I called the Stage 3
run "the first reference-model equivalence check in the project". It was not.
The log has been corrected in place rather than silently edited.

### F4 — `TB_GOLDEN.sv.duplicate`

Renamed earlier today; byte-identical to `goldenmodel.sv`, which is the copy in
the project. Reversible if that turns out to be the wrong choice.

### F5 — Backup

`NOC_PQATTEST.xpr.bak_20260909` from before the `.xpr` edits. Keep until the
next clean full run, then delete.

---

## Corrections this audit forced

| Where | Was | Is |
|---|---|---|
| `NOC_WORKSTREAM.md` §1 | O-01, O-02 open | **O-02 closed; O-01 closed in code, undocumented** |
| `NOC_WORKSTREAM.md` appendix | "two files violate L-02" | **15 of 20** |
| `VERIFICATION_LOG.md` Run 4 | "first reference-model check" | **second — Stage 2 had one on 2026-09-06** |

Three claims of mine, three wrong. Consistent with the project record: the
checkers and the paperwork are where the defects are.

---

## What to do next, in order

1. **Write the `.xdc`.** 50 MHz clock. Nothing else needed for an OOC probe.
2. **Run Phase 2.5.** OOC-synthesise `noc_fifo` (both storage styles),
   `noc_crossbar`, `noc_router_datapath` (VC2 depth 4/8/16), `NOC_ALLOCATOR`.
   Populate `RESOURCES.md` with LUT / FF / LUTRAM / Fmax / WNS per config.
3. **Decide from the numbers**, before writing M8: does `6 × router` leave room
   for 6 NIs, the crypto lane, and the RoT? If not, the fixes in §4 of the
   workstream doc are cheaper now than after Phase 7 multiplies everything by six.
4. **Freeze `N_OUTSTANDING`** in `noc_pkg`. Recommend 2.
5. **Close O-03 scope** — which header fields the MAC covers.
6. **Then** M8 `noc_router` (Phase 3.5).

Renaming files for L-02 and writing the four architecture `.md` files are real
debts, but they are not on the critical path. The `.xdc` is.
