# PQ-Attest NoC — Cross-Check of Completed Stages (Phases 1–5)

Session 2026-09-18. Scope: cross-check the *completed* NoC stages (Phases 1–5 / M1–M11)
against the frozen architecture in the roadmap. Phase 2.5 skipped (per instruction).
Phases 6+ NOT started. Method: compile + elaborate (real, this session) + static
architectural/behavioural audit. Functional NoC simulation was NOT run — the XSim host
is wedged (orphaned kernels, `rc=139`), and `taskkill` is permission-blocked.

## Build evidence (this session, real)
- **Full NoC lane compiles: 0 errors / 0 warnings** (`NOC_PKG` + 10 modules).
- **All 8 NoC modules elaborate clean:** `noc_router`, `noc_network_interface`,
  `noc_crossbar`, `noc_xy_routing`, `NOC_ALLOCATOR`, `noc_credit_control`,
  `noc_addr_decoder`, `noc_router_datapath`.
- **NoC testbench compile: 1 real defect** — see Finding N-1.

## Architecture alignment (noc_pkg vs frozen roadmap) — ALIGNED
| Frozen spec | noc_pkg | Verdict |
|---|---|---|
| 3×2 mesh, 6 tiles | MESH_X=3, MESH_Y=2, NUM_TILES=6 | ✅ |
| 5 ports N/S/E/W/LOCAL | NUM_PORTS=5; port_e NORTH0/SOUTH1/EAST2/WEST3/LOCAL4 | ✅ |
| 3 VCs Req/Resp/Attest | NUM_VC=3; vc_e REQUEST0/RESPONSE1/ATTESTATION2 | ✅ |
| 32-bit flit / 36-bit stored | FLIT_WIDTH=32; flit_t = 32 + 2(type) + 2(vc) = 36 | ✅ |
| FIFO depth 4 | FIFO_DEPTH=VC0/1/2_DEPTH=4 | ✅ |
| N_OUTSTANDING=2 (C5) | N_OUTSTANDING=2 | ✅ |
| addr[27:24]=tile sel (O-01/L-03) | TILE_SEL_MSB=27,LSB=24 | ✅ |
| Tile→coord map | CPU0(0,0) CPU1(1,0) MEMORY(2,0) CRYPTO(0,1) RoT(1,1) SPOOF(2,1) | ✅ exact |
| MAC 128b=4 flits, off till Ph9 | MAC_TAG_BITS=128, MAC_FLITS_FULL=4, MAC_ENABLE=0 | ✅ |
| Packet length table (O-02) | message_payload_flits(): RD_REQ1/RD_RESP1/WR_REQ2/WR_RESP0/CHAL5/RESP16 | ✅ |

Internal consistency confirmed: ATTEST_CHALLENGE_WIDTH=160=5×32 (payload=5 flits);
ATTEST_RESPONSE_WIDTH=512=16×32 (payload=16 flits). Widths and flit counts agree.

## Per-module behavioural cross-check
- **M1 noc_pkg** — aligned (above). Note: the 30,144→20,347 B shrink flagged in the
  brief removed nothing currently referenced (all modules compile clean; 64 decls).
  History now protected by git.
- **M2 noc_fifo / M3 noc_crossbar / M4 datapath** — compile+elaborate clean; 15 FIFOs
  (5 ports × 3 VC) structure matches. Deep functional re-verify needs sim (blocked).
- **M5 noc_xy_routing** — ALIGNED & self-checking. X-before-Y dimension order;
  malformed dest → route_valid=0, port forced LOCAL; port_exists() defence-in-depth;
  embedded contract assertions; documented delta-cycle-race fix (single always_comb).
- **M6 NOC_ARBITER** — compile/elaborate clean; roadmap records exhaustive prior
  verification (491,520 vectors, 0 mismatch). Not re-run this session.
- **M7 NOC_ALLOCATOR** — reservation FSM structurally correct: HEAD acquires+locks,
  BODY retains with owner-match, TAIL releases with owner-match, HEAD_TAIL no-op,
  illegal-encoding holds state; A10 trap (physical-port vs input-VC index) present.
  **Reservation advances on arbitration grant (out_valid = arbiter grant_valid); the
  allocator does NOT receive credit** (takes fifo_empty only). See Finding N-2.
- **M8 noc_router** — CONTRACT L-07 (xbar_sel hold during stall) is implemented
  (explicit section + output qualification). **credit_* signals left UNCONNECTED on
  purpose (lines 134–135)** — credit flow control not integrated at the router. N-2.
- **M9 noc_credit_control** — compiles/elaborates clean; roadmap records standalone
  verification. NOT wired into noc_router yet (deferred; exercised in Phase 6). N-2.
- **M10 noc_network_interface** — compiles/elaborates clean. `rx_head_shape_ok` patch
  IS present (6 refs) → the brief's "unknown whether applied" item is CLOSED: applied.
  Roadmap records 159 checks / 0 errors (prior). Not re-run this session.
- **M11 noc_addr_decoder** — compiles/elaborates clean. noc_pkg's address_to_coord_safe
  decodes only region 0x2 and rejects tile_sel ≥ NUM_TILES (illegal-tile → valid=0);
  roadmap records 36 checks incl. self-remote & illegal rejection. Not re-run.

## Findings
### N-1 (defect, testbench) — `TB1.sv` (tb_noc_stage2) did not compile — FIXED
`xb_sel`, `xy_valid` and other datapath signals were referenced by a coverage `always`
block at line ~197, **before their declaration** → `[VRFC 10-3380] used before its
declaration`. TB1.sv IS in the .xpr fileset. Root cause: the coverage/observation
`always` block sat above the per-block DUT signal declarations it samples.
**FIX APPLIED (commit 4e7b0f9):** relocated the entire coverage block verbatim to just
before `endmodule`, below all declarations. Behaviorally identical (a `@(posedge clk)`
counter block; position among always blocks does not change semantics).
**Verified:** NoC lane + all NoC TBs now compile **0 errors** (was 2); `tb_noc_stage2`
elaborates. Functional run still pending a clean sim host.

### N-2 (alignment note, NOT a defect) — credit flow control not yet integrated in router
Per roadmap phase-staging this is expected, but state it plainly: "Phase 4 ✅" is
**module-level** (M9 standalone). In `noc_router.sv` credit is unconnected (lines
134–135) and the allocator reserves on arbitration grant without credit. Therefore
the invariants "reservation changes only on ACTUAL TRANSFER" and "zero dropped flits
under backpressure" are **not yet enforced end-to-end** — they become real at Phase 6
(two-tile integration), whose exit criteria explicitly cover credit return / no drops /
backpressure. No action now; flagged so "Phases 1–5 done" is not over-read as
"router enforces credit today."

## Verdict
- **Completed NoC stages (M1–M11) are architecturally ALIGNED** with the frozen roadmap;
  everything compiles and elaborates clean; the two brief-level unknowns (rx_head_shape_ok,
  NOC_PKG shrink) are resolved.
- **Two items to note:** N-1 (TB1 compile defect — fix recommended, one-block move) and
  N-2 (credit not yet integrated in router — correct for the current phase, Phase 6 closes it).
- **Not verified this session:** functional NoC simulation (host wedged). Module-level
  functional claims (arbiter 491k vectors, M10 159 checks, M11 36 checks) are prior-run
  provenance, not re-run here.
- **Phase 2.5 (area/timing probe): skipped per instruction; remains genuinely open** (no
  synthesis numbers exist).
