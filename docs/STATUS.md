# PQ-Attest — CANONICAL STATUS & PLAN (rev 15, 2026-09-25)

Live-tree verified. ✅ = done with evidence · ⬜ = pending (in order)
HIST = passed once on an earlier tree, not yet reproduced on the clean baseline.
Mirror of project doc `claude/final-plan-2026-09-22.md`. Repo copy: `docs/STATUS.md`.

## LIVE STATE (read from disk, after M-0)
- Branch `noc/credit-integration`. (M-0 baseline was da80888.) CURRENT: RTL baseline `acd1f73`
  (= N-2.5 MF1 gate + XSim mf1); later commits docs/logs only. HEAD: see `git log -1`.
- Working tree clean except untracked zips + `_recovery_backup/`
- No `MUT-` markers in sources · no 0-byte .sv · `.gitattributes` present (LF)
- `kmac_encode.sv` restored (8'h80) · `stage3_golden_tb.sv` restored (31,723 B) + `transfer_valid`
- sources_1 top = `noc_router` · sim_1 top = `tb_noc_mesh_n7`
- tb6_1.sv / tb_noc_router_m9_credit.sv in sim_1, 0 in sources_1
- Note: noc_addr_decoder / noc_network_interface AutoDisabled in sources_1 (not under noc_router).
  If a sim with tb6_1 as top reports them missing: `set_property is_enabled true [get_files ...]`

## FINAL DECISION
1. M-0 RECOVERY done. Next: crypto + NoC re-proof, then 7c, then M-F INTERFACE FREEZE. Not Stage 8.
2. 7c recommended: credits router<->router; ready/valid router<->LOCAL NI. Kalash to freeze.
3. N-6 with NIs and NO bypasses is the freeze gate. S-8, N-9, E4-P3 wait on the freeze.

## M-0 RECOVERY — DONE
✅ 1  snapshot -> logs/recovery_snapshot_2026-09-23.txt (2aa8c73)
✅ 2  .git/index.lock removed
✅ 3  Task-7 NOT stashed (N-6/N-7 depend on it): committed as WIP baseline on
      branch noc/credit-integration (f3ee128) — Kalash's decision
✅ 4  kmac_encode.sv restored from HEAD: 8'h80 x1, 8'h81 x0, no MUT-
✅ 5  stage3_golden_tb.sv restored; .transfer_valid(grant_valid) added (efd75cf)
✅ 6  tb_noc_router_m9_credit.sv + tb6_1.sv moved sources_1 -> sim_1 (da80888)
✅ 7  sources_1 top = noc_router (da80888)
✅ 8  .gitattributes + EOL renormalize (e55bd81) · logs/ exists · docs/STATUS.md
✅ 9  S7_MUTATION_PASS.md: M1-M4 results recorded (f0ac037)
✅ -  N-7 log committed (b0c2e94)

## NoC LANE
N-1 Architecture
 ✅ 3x2 mesh, 5 ports, 3 VCs (REQ/RESP/ATTEST), 32-bit flit, FIFO 4, XY, wormhole
 ✅ tile map CPU0(0,0) CPU1(1,0) MEM(2,0) CRYPTO(0,1) RoT(1,1) SPOOF(2,1)
 ✅ header/flit format, N_OUTSTANDING=2, 1-bit tag
 ✅ 7c FROZEN: credits R<->R, ready/valid R<->LOCAL NI (docs/decisions/7c-flow-control.md) · ⬜ confirm MAC_ENABLE asymmetry deliberate · ⬜ NOC_PKG 30,144->20,347 provenance

N-2 Datapath (M2 FIFO, M3 crossbar, M4 datapath) — HIST SMOKE
 ✅ RTL · ✅ TB1 compiles (4e7b0f9) · ✅ historical pass
 ✅ rerun TB1: OVERALL PASS, NEG 2/2 (7981fa6; DUT-assert noise confined to deliberate phases) · ⬜ mutation pass

N-2.5 Synthesis probe — CLOSED at 50 MHz (run 3, PhysOpt strategy), thin margin — see run 3
 Run 1 | Vivado 2024.1 GUI, project flow, default strategies | xc7a100tcsg324-1 | 20.000 ns (50 MHz)
       | top noc_mesh_synth_top (LFSR-driven, XOR-fold to 1 pin) over noc_mesh_3x2 | RTL = 609550c
       | wrapper as synthesized: reports/n25_2026-09-23/noc_mesh_synth_top.AS_SYNTHESIZED.sv (logic = 8ac48c9)
 ✅ post-synth: LUT 10,371 (16.36%) = 8,259 logic + 2,112 LUTRAM · FF 1,437 · F7 43 · BRAM 0 · DSP 0
 ✅ post-place: LUT 10,652 (16.80%) · LUTRAM 1,716 · FF 1,438 · Slices 2,889 (18.23%)
 ✅ 6/6 routers present (GEN_R[0..5] in power hierarchy); 66 LUTRAM FIFOs = 20 live input ports x 3 VC + 6 eject
    (edge-port FIFOs trimmed legitimately); LUTRAM 2,112 = 60x32 + 6x32 LUTs, exact
 ❌ post-route: WNS -1.301 ns · TNS -1535.499 ns · 2,648/16,785 failing endpoints · WHS +0.035 · 0 unrouted
    critical path: R4 west_vc0 FIFO rd_ptr -> LUTRAM head -> allocator (in-arb, out-arb) -> xbar_sel ->
    crossbar valid -> out_v_n[4] -> R1 south_vc1 FIFO WE. 22 levels, 20.699 ns, 82% route.
    ROOT CAUSE: router->router data links were combinational, so two routers shared one cycle.
 ✅ power (vectorless, medium confidence): 0.155 W total, 0.058 W dynamic
 ✅ synth warnings triaged: 8-7186 (48) elaboration-stage per-field messages, final map IS LUTRAM ·
    8-7129 grant[] unused in noc_credit_control (assert-only port; cleanup candidate) · head_flit data bits
    unused by allocator (expected) · 8-2898 SVA ignored (expected)
 ✅ D7 fix: noc_mesh_3x2 LINK_PIPE=1 (default) - one register stage on every router->router data link.
    Credits unpiped. Credit RTT 3 -> 4 cycles = VC depth 4 (full per-VC rate kept, zero slack).
    +1 cycle per hop. Verilator 5.48 cross-check: N-7 pipe1 1756/0, pipe0 1762/0, N-6 126/0, M8 47/0.
    (pipe1 has 6 fewer checks, all in T7: 3 flits cleared inside link registers by the mid-run reset.)
 ✅ run-1 triage: inter 2,516 FAIL (worst -1.301) · intra 132 FAIL (worst -0.343), ALL 132 = eject-FIFO LUTRAM pins
 ✅ XSim D7 regression (logs/*_d7_2026-09-23.log): N-7 pipe1 1756/0 · M8 47/0 · N-6 126/0 · TB1 PASS
    ⚠ n7_pipe0 XSim log not produced (generic_top run) - Verilator pipe0 1762/0 covers it
 ✅ run 2 (LINK_PIPE=1, RTL 041a036): WNS -0.317 · TNS -9.265 · 50 failing · FF +518 (link regs live)
    reports/n25_run2_2026-09-23. Remaining path = input FIFO -> allocator -> crossbar -> eject FIFO WE, ONE router.
    (My run-1 estimate of '~1 ns in-router margin' was WRONG for the LOCAL/eject path: it was -0.343.)
 ✅ D7b fix: noc_router EJECT_PIPE=1 (default) - register before the eject FIFO. LOCAL credit taken at grant,
    eject depth 12 = LOCAL credit -> no overflow. +1 cycle LOCAL latency. a_eject_no_overflow now on eject_wr_q.
    Verilator: N-7 1756/0 · N-6 126/0 · M8 47/0; mutant (strobe not delayed) KILLED.
 ✅ XSim D7b (logs/*_d7b_2026-09-24.log): N-7 pipe1 1756/0 · M8 47/0 · N-6 126/0 · TB1 PASS (2516 = baseline)
 ✅ synth (RTL fd92428 = 93dc92c RTL): FF 2,177 = 1,955 + 6x37 (eject stage live) · LUT 10,345 · 0 errors
    (wait_on_run returned ERROR after 'Spawn failed: No error' although synth completed -> script hardened)
 ✅ RUN 3 = impl_pe, strategy Performance_ExplorePostRoutePhysOpt (opt/place/phys_opt/route Explore +
    post-route phys_opt), reports/n25_run3pe_2026-09-24, gate PASS:
    WNS +0.202 · TNS 0 · 0/18,237 failing · WHS +0.047 · THS 0 · WPWS 8.750 · 0 route errors · 0 DRC errors
    check_timing clean (rst/led known) · LUT 10,114 · LUTRAM 1,716 · FF 2,178 · BRAM 0 · DSP 0
    registers present: eject_wr_q 6/6, eject_flit_q 216/216, link valid 14/14
 ⚠ margin 0.202 ns (1% of 20 ns). Worst path: FIFO head -> allocator -> crossbar -> eject_flit_q D, 19 levels,
    19.761 ns, 80% route. Endpoints <0.5 ns: eject_flit_q 18, link q_* 32, allocator output_owner 5 - i.e. the
    single-cycle allocate+traverse stage is the limiting path at 50 MHz under THIS implementation
    (Vivado 2024.1, xc7a100tcsg324-1, PhysOpt strategy). Not a proven architectural ceiling.
 ⚠ default strategy on D7b RTL NOT run (impl_1 empty) - closure is only shown with the PhysOpt strategy.
    Rule: pin Performance_ExplorePostRoutePhysOpt for this design; rerun the gate after ANY NoC RTL change.
 ✅ default strategy (impl_1, same synth, report 00:58 IST 25-Sep, reports/n25_run3default_2026-09-24):
    WNS +0.048 · TNS 0 · 0/18,237 failing · WHS +0.047 · 0 route errors. CLOSES, but margin 0.048 ns (0.24%).
    Worst: R1 west_vc2 FIFO rd_ptr -> R1 link q_e_reg D, 19 levels. Full n25_gate not yet run on impl_1.
    => pinned strategy stays PhysOpt (+0.202 ns); default is a fallback, not the reference.

M-F1 NoC INTERFACE FREEZE — DRAFT rev 0 written, UNSIGNED: docs/decisions/M-F1-interface-freeze.md
 ✅ frozen-in-draft: topology, flit + head bit map, VC classes (no VC realloc), 8 msg types + lengths, 1-bit tag,
    address map, R<->R credits (RTT 4 = depth 4), LOCAL ready/valid, LOCAL credit 12 = eject 12, latency deltas
 ✅ I-3 elaboration check in noc_router (EJECT_DEPTH >= total LOCAL credit), sim-only, netlist unchanged
 ⚠ FD-1 (decision needed): wormhole lock is per OUTPUT PORT, not per (port,VC) -> VCs isolate buffers, not links;
    protocol-level deadlock possible (not demonstrated). Options A per-VC lock / B consumption rule + N-8 test (rec.) / C
 ⬜ OPEN-1..5 (attest layout, MAC format, nonce 128->160, status codes, error behaviour) -> S-8 owner or excluded
 ✅ XSim mf1 (with I-3), all 4 RECOMPILED 25-Sep 01:09-01:11 IST: N-7 pipe1 1756/0 · M8 47/0 · N-6 126/0 ·
    TB1 PASS (2516 = baseline). logs/*_mf1_2026-09-25.log
 ⚠ n7_pipe0 (TB_LINK_PIPE=0 via xelab -generic_top) 'launch FAILED 3x' in d7 AND mf1 (compile step after
    'Spawn failed'). Informational config only; Verilator pipe0 1762/0 covers it. Fix the generic path later.
 ✅ N-2.5 gate on FINAL RTL (acd1f73), impl_1 pinned PhysOpt: PASS, WNS +0.202, TNS 0, 0/18,237, WHS +0.047,
    0 route/DRC errors, D7/D7b regs present. reports/n25_mf1_2026-09-25 (identical to impl_pe: same netlist+strategy)
 ✅ I-3 negative: EJECT_DEPTH=11 -> $fatal at t=0 (Verilator, repo untouched) logs/i3_negative_verilator_2026-09-25.log
 ✅ FD-1 DECIDED (reviewed with Kalash's second reviewer): B' = trusted-NI endpoint containment, PROPERTY frozen
    in M-F1 §10 (consume-to-TAIL, no router change, reported, forward progress). Mechanism = N-8.1 (first N-8 item).
    Transport: all 6 tiles may initiate; authorization = N-10. No NI buffer size frozen.
 ✅ M-F1 rev 1: transport-only; attestation semantics moved to S-8 (S8-1..5)
 ✅ M-F1 rev 2 (external review 25-Sep): provenance = acd1f73; ownership ends on terminator flit (HEAD_TAIL
    explicit); watchdog counts tile-induced stall only; sticky/counter reporting; finite N-8.1 acceptance test;
    NI framing gap recorded (RX_PAYLOAD exits on counter, not TAIL); NI timing unmeasured
 ✅ M-F1 rev 3 SIGNED by delegation 25-Sep (terminator defined MAC-aware; persistent observable;
    truncated-packet boundary test; framing tests in both MAC modes). Kalash countersign optional.

N-3 Routing/allocation (M5 XY, M6 arbiter, M7 allocator) — HIST SMOKE
 ✅ RTL · ✅ historical 491,520-vector arbiter check · ✅ stage3_tb.sv present
 ✅ golden TB restored + transfer_valid · ✅ rerun: 491,520/0, 20000 cyc 0 mismatch, NEG 2/2 (7981fa6) · ⬜ mutation

N-3.5 Router M8 — IMPLEMENTED, PASS UNPROVEN
 ✅ RTL · ✅ tb_noc_router_m9_credit.sv tracked, in sim_1
 ✅ run: 30/0 RESULT PASS (7981fa6) · ✅ reset SVA a_no_output_after_reset: CLOSED - fired only in N-7
   under array-port connections; 0 with plain-signal connections (DIAG-EXP-1, be383be). Assertion kept ON.

N-4 Credit M9 — WIP (committed f3ee128)
 ✅ standalone M9 + credit_control_tb · ✅ interposition in noc_router (credit_return in)
 ✅ credit_out ports + LOCAL ready/valid via 12-entry eject buffer (1eede14) · ✅ N-7 taps replaced by ports
 ✅ M8 TB 47/0 incl. T7 eject stall, T8 in_ready backpressure, T9 no comb valid<-ready
 ⚠ FOUND 2026-09-23: Task-7 (f3ee128) wrapped NOC_CROSSBAR a_no_loopback_* asserts in
   `ifdef NOC_CROSSBAR_COMB_ASSERTS` - defined NOWHERE, so they are OFF in N-6/N-7/all sims.
   ✅ CLOSED by council D2 (2026-09-23): crossbar comb loopback asserts stay OFF intentionally; router-level
   clock-sampled a_no_loopback_*_sync cover all 5 outputs in integration. Not a coverage gap.
   (superseded) ⬜ root-cause why they were disabled (likely always_comb delta glitch) · ⬜ fix as
   deferred `assert final` / sampled check, re-enable · ⬜ rerun M8, TB1, N-7 with them ON

N-5 NI M10 / decoder M11 — STANDALONE ONLY
 ✅ RTL · ✅ ni_tb, m11_tb historical
 ⬜ M10 rx_head_shape_ok provenance · ✅ LOCAL ready into router (in_ready_local / out_ready_local)

N-6 Two-tile WITH NIs — SMOKE + MUTATION-TESTED (3/3), NO BYPASSES — NOT sim-verified
 ⚠ ladder: sim-verified needs an INDEPENDENT golden model; N-6 has directed expectations +
   conservation counters, no reference model. Upgrade path: scoreboard/ref model (N-7/N-8).
 ✅ tb6_1.sv = tb_n6_two_tile_stress (M11 + 2x M10 NI + 2x M8 router)
 ✅ bypasses removed (c1aa379): NI tx_ready<-in_ready_local · out_ready_local<-NI noc_rx_ready ·
   credit_return<-neighbour credit_out port · injectors honour in_ready_local
 ✅ T11/T12 RX ready=0 hold (whole / mid-packet) · ✅ T13 LOCAL input full backpressure (4ee4ff8)
 ✅ conservation TOTAL IN == TOTAL OUT + per-router after T1,T2,T7,T8,T11,T12
 ✅ control 126/0 PASS, $finish 4656 ns · logs/n6_control_restored_t13_2026-09-23.log
 ✅ mutation 3/3 KILLED on TB 4ee4ff8 (recompile verified per run):
    M-a eject_rd ignores ready -> 18 FAIL + hold SVAs · M-b WEST VC0 credit lost -> 4 FAIL + T13 watchdog TIMEOUT (hang cause inferred, not traced)
    M-c in_ready tied 1 -> 5 FAIL + 21x FIFO 'FLIT DROPPED' SVA (survived the 118-check TB -> T13 added)
 ⚠ T13 hold branch has no timeout: a lost-credit bug shows as watchdog TIMEOUT (still FAIL) and hides
   later checks. Bound it next time the TB is touched.
 ℹ residual hierarchical refs are OBSERVATION only (credit_count, full flags), not in any handshake
 ℹ LESSON: Tcl 'file copy' keeps mtime + xvlog --incr -> stale snapshot; mutation script stamps mtime,
   reset_simulation, and proves .sdb recompiled per run

N-7 3x2 mesh — PASS (routers only, credits via credit_out ports)
 ✅ tb_noc_mesh.sv · ✅ 1761/0/0 (2026-09-22 17:16) · ✅ log committed
 ✅ rerun after 7c: 1761/0/0, InjBlocked 0
 ✅ 330 SVA Error lines (80 reset-SVA + 250 legal-vc) RESOLVED: DIAG-EXP-1 (be383be) changed ONLY the GEN_R
   port-connection style (array elements -> plain per-instance signals) -> 0 SVA lines, 1761/0/0, InjBlocked 0,
   $finish 9401 ns unchanged. Not an RTL defect; likely XSim artifact (mechanism inferred). Plain-signal TB kept.
   Log: logs/n7_diag_exp1_2026-09-23.log
 ⬜ rerun after N-6 on final RTL (keep both runs)

N-7.5 Deadlock freedom
 ✅ XY-acyclic + VC-class argument · ✅ network-level dynamic evidence (N-7)
 ⬜ protocol-level dynamic evidence (needs NIs)

N-8 Traffic/performance — BLOCKED on freeze
 ⬜ explain architecture · ⬜ traffic generator · ⬜ injection sweep 1..64
 ⬜ monitors: latency, throughput, occupancy, credit stalls · ⬜ cycles now, ns after N-2.5

N-9 L2 MAC ⬜ · N-10 L3 enforcement ⬜ · N-11 security attacks ⬜
N-12 final regression ⬜ · N-13 FPGA closure 50 MHz ⬜ · N-14 SoC integration ⬜

## PQ-ATTEST (CRYPTO) LANE
S-1 Keccak-f[1600] — SIM-VERIFIED (narrow stimulus)
 ✅ 600 golden lanes, negative control · ⬜ random-input vectors

S-2 SHA3-256 — HIST SMOKE 49/0
 ✅ byte-order fixed · ⬜ rerun, log · ⬜ mutation · ⬜ latch is_final + full-block assertion

S-3 KMAC128 — SMOKE, CURRENT 11/0 (45e831f)
 ✅ L=128 KAT added · ✅ domain-byte mutation detected · ✅ MUT-S3b reverted
 ✅ rerun 11/0, log · ⬜ L=128-only mutation properly · ⬜ key-encoding mutation

S-4 TRNG conditioning — HIST SMOKE 19/0
 ✅ nonce 128-bit (TRNG_TOP.nonce_out) · ⬜ rerun, log · ⬜ mutation

S-5 Tile-key KDF — SMOKE, CURRENT 35/0 (db37449)
 ✅ TILE_ID 7 B / EPOCH 10 B frozen · ✅ rerun, log · ⬜ ctx lengths 1-12 · ⬜ mutation
 ⬜ record pq_kdf busy/async-reset outlier (leave RTL, bridge at integration)

S-6 Measurement — SMOKE, CURRENT 33/0 (db37449)
 ✅ rerun, log · ⬜ mutation · ⬜ decide length-prefix ambiguity

S-7 Attestation tag — SIM-VERIFIED, CURRENT 105/0 + 4/4 mutation
 ✅ RTL · ✅ in-repo NIST-validated reference, 8/8 vectors · ✅ obs_v01 fix
 ✅ V07 truncation check -> obs_v01 (f0ac037)
 ✅ Run A 105/0 (4e907ac) · ✅ Run B M3 -> 105/14 incl. V04 freshness FAIL (401a838)

S-8 Attestation protocol ⬜ (after freeze) · S-9 security regression ⬜
S-10 full chain TRNG->KDF->measure->attest->verify ⬜ · S-11 final freeze ⬜

## M-F INTERFACE FREEZE (after N-6 passes) — must cover
flit format · VC semantics · message types · transaction tags · address map ·
router<->router credits · NI<->router ready/valid · LOCAL credit behaviour ·
attestation request/response · MAC format · nonce semantics · status/error

## MASTER ORDER (both lanes) — live plan from 2026-09-25
✅ 1-6  M-0 recovery · crypto + NoC re-proof · 7c · N-4/N-5 · N-6 (126/0, mut 3/3)
✅ 7    N-7 on noc_mesh_3x2 (1756/0 with LINK_PIPE)
✅ 8    N-2.5 NoC synth/impl: 50 MHz, PhysOpt, WNS +0.202 (D7 LINK_PIPE, D7b EJECT_PIPE, I-3)
✅ 9    M-F1 NoC transport freeze rev 3 SIGNED
▶ 10   N-8.1 NI endpoint containment (FD-1 B′), strictly in order:
        a. architecture doc (RX FSM + framing bug, ownership-to-terminator, watchdog rule, discard state,
           sticky flag + counter, MAC-aware terminator, finite SPOOF topology + derived cycle bound)
           ✅ WRITTEN: docs/decisions/N-8.1-ni-endpoint-containment.md (rev 0, 2026-09-25). Also found:
           HEAD-stall gap (AM-1), TX supply-withholding gap -> TX store-and-forward (AM-2), bad-length HEAD
           delivered today (AM-6), reserved msg_type sent/delivered (AM-5), discarded response leaks txn slot.
        ✅ b. review applied: N-8.1 arch rev 1 FROZEN as implementation spec; M-F1 rev 4 (AM-1..AM-6) signed by delegation
        ✅ c. NI RTL written (noc_network_interface.sv): terminator-only RX FSM, F1-F10, RX_DISCARD, HEAD-pending +
           per-packet watchdog, sticky/counter/info + trusted clear, txn-slot free at terminator, VC/msg/length
           rejection, TX store-and-forward, SVAs (a_tx_no_bubble, a_tx_vc_legal, a_ready_low_only_for_tile,
           a_wd_range, a_discard_ready, a_rx_flit_hold). Expiry rx_abort registered (no tile-in -> tile-out comb path).
           NOC_PKG: `ifdef PQ_MAC_ON (default unchanged). No router/allocator file touched.
           VERILATOR ONLY (XSim pending, scripts/n81_xsim.tcl): tb_ni_n81 m0w16 115/0 · m0w1 114/0 · m1w16 113/0 ·
           m1w1 112/0 · tb_noc_ni 161/0 · N-6 126/0 (TB NIs WD_LIMIT=64: T11/T12 hold the tile 40 cycles; with the
           default W=16 they are contained - expected behaviour change) · mutation M-n1..M-n7 7/7 KILLED on tb_ni_n81.
           logs/n81_*_verilator_2026-09-25.log
        d. remaining: XSim run of n81_xsim.tcl (Kalash) · SPOOF system TB tb_noc_n81 (10-run matrix, §9)  ← NEXT
        e. full XSim regression (N-7, M8, N-6, TB1) + N-7 pipe0 generic fix
        f. NI OOC synthesis/timing (labelled OOC) · N-2.5 re-gate (NOC_PKG.sv touched, default-preserving)
11   N-8 performance (only after 10 closes): traffic generator · injection sweep 1..64 · latency/throughput/
     occupancy/credit-stall monitors · independent scoreboard (lifts N-6 toward sim-verified) · N-7.5 evidence
||   S-8 attestation protocol in parallel from 10a: S8-1..5 (fields, MAC, nonce 128->160, status, errors)
||   D4 crypto OOC synth before any whole-design resource claim
12   N-9 L2 MAC (MAC_ENABLE=1; re-run framing tests + N-2.5 gate) → N-10 L3 enforcement (initiator authz)
13   N-11/S-9 security regression → S-10 full chain → N-12 final regression → N-13 FPGA closure → N-14/S-11
Verification debt (visible, not blocking): mutation N-2 datapath, N-3 allocator, S-2/S-4/S-6.
Parallel filler: mutation passes S-2, S-4, S-6; SHA3 is_final latch; E4 P0-P2 + repo-state checker.

## HOST FACTS (Vivado 2024.1 GUI, this PC)
- SECOND SIMULATOR: Verilator (pip wheel 5.48.0) runs in the Cowork Linux VM against the repo directly:
  scripts/verilator_build.sh. Needs make vars CFG_CXXFLAGS_PCH_I=-include and USER_CPPFLAGS=
  "-fcoroutines -std=c++20" (wheel mis-configured). Reproduces XSim: N-7 1762/0, N-6 126/0, M8 47/0.
  XSim stays the project reference; Verilator is a cross-check.
- noc_fifo a_{write,read}_pointer_in_range used PTR_WIDTH'(DEPTH): for DEPTH=4 that is 2'(4)=0, so the
  property was 'ptr < 0' (always false). Verilator fired it; XSim never did (mechanism unknown).
  Fixed to int compare 2026-09-23. Lesson: never size-cast a bound to the width of the thing it bounds.
- simulate.log is flushed only on close_sim. Copy it AFTER close_sim, never before.
- After $finish the GUI sim can be resumed: an extra `run` fires the TB watchdog. Don't `run` past $finish.
- `Spawn failed: No error` = Vivado lost a child process's exit code (seen during background
  project refresh right after `set_property top`). Snapshot may be fine; wait a few s, retry.
- Tcl `file copy` PRESERVES the source mtime; xvlog --incr only recompiles files newer than their .sdb.
  Swapping sources by copy can silently reuse a stale snapshot. Stamp mtime + reset_simulation, and
  check the .sdb timestamp (scripts/n6_mutation.tcl does all three).
- Long NoC TBs: set xsim.simulate.runtime 1ns, `run all`, restore 20us after.

## STANDING RULE
Before "done": git diff -w --stat clean/committed · no MUT- in sources · no 0-byte .sv.
Every PASS records commit, branch, TB, snapshot, CHECKS/ERRORS/RESULT, end time; log in logs/.
