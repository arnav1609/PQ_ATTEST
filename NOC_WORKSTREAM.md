# PQ-Attest — NoC Workstream

**Owner:** Kalash Bheda
**Scope:** everything from architecture freeze to a timing-closed, security-verified 3×2 NoC on Arty A7-100T (xc7a100tcsg324-1). Ends where SoC integration begins.
**Status of this document:** revision of the 14-phase plan, with corrections and an area-efficiency methodology.

---

## 0. Verdict on the original plan

The shape is right. The phase ordering is mostly right. Seven things are wrong or missing, listed here in order of how expensive they are to discover late.

| # | Problem | Cost if found late |
|---|---|---|
| **C1** | **FPGA area/timing closure is Phase 13.** | You would complete twelve phases before learning whether six routers fit. The LUT estimate spread for one router is unverified. If the real number is at the high end, the crypto lane's budget is wrong and the fix is architectural, not incremental. **Highest-cost error in the plan.** |
| **C2** | **No router top-level module.** The plan goes M7 allocator → credit → NI. Nothing binds M3/M4/M5/M6/M7 together. **Five separate interface mismatches** already exist between M4 and M7 (§3.5). | The two blocks cannot be wired together at all. Every phase after 3 assumes a working router that does not exist. |
| **C3** | **L3 attestation (Ph 9) before L2 authentication (Ph 10).** | The attestation gate trusts a verdict that arrives as a NoC packet. Without L2 auth, a spoofed tile forges its own "attested" message and the entire L3 mechanism is bypassed. The security result would be invalid. |
| **C4** | **No deadlock-freedom phase.** VC2 carries both attestation *challenge* and *response*. | That reintroduces the cyclic channel dependency that separate request/response VCs exist to break. It is safe only under invariant L-11 (RoT issues at most one outstanding challenge mesh-wide) — which is currently an assumption, not a checked property. |
| **C5** | **Outstanding-transaction limit not frozen in Phase 1.** | It sizes the NI reorder buffer. Discovering "we need 8 outstanding" in Phase 5 changes an area number you have already reported. |
| **C6** | `traffic_gen.c` in Phase 8. | There is no CPU in the NoC-only workstream. Traffic generation belongs in SystemVerilog (synthesizable injector for FPGA runs) or Python (offline pattern generation). A C file implies a CPU that does not exist yet. |
| **C7** | Phase 6 two-tile example uses CPU0 (0,0) and MEMORY (2,0). | Those are two hops apart, not adjacent. A two-tile bring-up must use an adjacent pair — CPU0 (0,0) ↔ CPU1 (1,0). |

---

## 1. Corrected phase list

The change is that **area and timing closure moves from one phase at the end to three checkpoints**: an early probe, a mid-point re-check, and final closure.

```
PHASE 1   Architecture + Feasibility Freeze
PHASE 2   Router Datapath                    (M1 M2 M3 M4)
PHASE 2.5 AREA + TIMING PROBE      <-- NEW, was Phase 13
PHASE 3   Routing + Allocation               (M5 M6 M7)
PHASE 3.5 Router Top Level         <-- NEW  (M8)
PHASE 4   Credit Flow Control                (M9)
PHASE 5   Network Interface                  (M10 M11)
PHASE 6   Two-Tile Integration
PHASE 7   Full 3x2 Mesh
PHASE 7.5 Deadlock Freedom         <-- NEW
PHASE 8   Traffic + Performance Baseline     (baseline-v1 FROZEN)
PHASE 9   L2 Packet Authentication  <-- was Phase 10
PHASE 10  L3 Attestation Enforcement <-- was Phase 9
PHASE 11  Security Experiments E1..E4
PHASE 12  Final NoC Verification
PHASE 13  NoC FPGA Closure
=====================  NOC COMPLETE  =====================
PHASE 14  SoC Integration
```

---

## 2. Module inventory

Naming convention going forward: **file name equals module name** (lesson L-02). Existing files that violate this are noted.

| ID | Module | File | Phase | Status |
|---|---|---|---|---|
| M1 | `noc_pkg` | `NOC_PKG.sv` | 1 | Frozen |
| M2 | `noc_fifo` | `NOC_FIFO.sv` | 2 | Verified |
| M3 | `noc_crossbar` | `NOC_CROSSBAR.sv` | 2 | Verified |
| M4 | `noc_router_datapath` | `NOC_DATAPTAH.sv` *(typo — rename)* | 2 | Verified |
| M5 | `noc_xy_routing` | `NOC_XY_ROUTING.sv` | 3 | Verified |
| M6 | `NOC_ARBITER` | `NOC_arbiter.sv` | 3 | **Exhaustively verified** |
| M7 | `NOC_ALLOCATOR` | `allocator.sv` *(rename)* | 3 | Verified vs golden model |
| **M8** | `noc_router` | `noc_router.sv` | **3.5** | **Does not exist** |
| M9 | `noc_credit_control` | `noc_credit_control.sv` | 4 | Not started — **name already fixed by RTL**, see note |
| M10 | `noc_ni` | `noc_ni.sv` | 5 | Not started |
| M11 | `noc_addr_decoder` | `noc_addr_decoder.sv` | 5 | Not started |
| M12 | `noc_mesh` | `noc_mesh.sv` | 7 | Not started |
| M13 | `noc_l2_auth` | `noc_l2_auth.sv` | 9 | Not started |
| M14 | `noc_attest_gate` | `noc_attest_gate.sv` | 10 | Not started |
| M15 | `noc_fault_status` | `noc_fault_status.sv` | 10 | Not started |
| M16 | `noc_top` | `noc_top.sv` | 13 | Not started |

> **M9 naming.** `NOC_FIFO.sv` and `NOC_DATAPTAH.sv` already reference **`noc_credit_control`** by name in four separate comments ("the counters live in noc_credit_control", "Credit pulses brought out for noc_credit_control", "Until noc_credit_control exists there is no backpressure"). The module name is therefore already fixed by the code that depends on it. Do not introduce a second name for it.

---

## 3. Phase detail

### PHASE 1 — Architecture Freeze

**Frozen parameters** (all present in `noc_pkg`):

```
Topology        3 x 2 mesh, 6 routers
Ports/router    5  (N S E W LOCAL)
VCs/router      3  (VC0 request, VC1 response, VC2 attestation)
Flit data       32 bits
Flit stored     36 bits  (32 data + 2 flit_type + 2 vc_id)
FIFO depth      4 baseline  (VC2 to be swept 4/8/16 in Phase 2.5)
Routing         deterministic XY, dimension order X then Y
Flow control    credit based
Switching       wormhole
Reset           synchronous, ACTIVE HIGH, single clock domain
Target          50 MHz, WNS >= 0, TNS = 0
```

**Must be added to the freeze (C5):**

```
N_OUTSTANDING   maximum outstanding NI transactions per tile
```

This sizes the NI reorder buffer and therefore appears in every area number you report. Freeze it now. Recommend starting at **2** and justifying any increase with a measured latency number from Phase 8.

**Still open, must close before Phase 5:**

- **O-01** tile-selector **encoding** — the *field* is already frozen at `address[TILE_SEL_MSB:TILE_SEL_LSB]` = `address[27:24]`, 4 bits wide. What is open is which 4-bit code maps to which of the six tiles. (This is an **address** field, not a flit-header field; `flit_data[31:29]`/`[28:26]` carry dest_x/dest_y and are separate.)
- **O-02** packet length table per message type
- **O-03** MAC width and scope (which header fields are authenticated)

**Exit:** `tb_noc_pkg` passes; O-01/02/03 closed; N_OUTSTANDING frozen.

---

### PHASE 2 — Router Datapath *(complete)*

**M2 `noc_fifo`** — one per (physical input × VC) = 15 per router.

| Responsibility | Note |
|---|---|
| Enqueue / dequeue flits | 36-bit `flit_t` |
| `occupancy`, `free_slots` | `free_slots` is the credit foundation — already present |
| `full` / `empty` | |
| `credit_valid` | pulses on dequeue; this is the credit-return source |
| Overflow / underflow detection | asserted, never silently dropped |

Storage is `(* ram_style = "distributed" *)`. Two separate reasons, of different strength — see §4.1. The BRAM exclusion is structural and settled; the distributed-vs-flip-flop margin is argued but not yet measured.

**M3 `noc_crossbar`** — 5×5, purely combinational data selection. Does not route, arbitrate, or manage credit. Contract **L-07**: the allocator must hold each `select_*` unchanged from a packet's HEAD through its TAIL. The crossbar cannot detect a violation and does not try.

**M4 `noc_router_datapath`** — physical input → VC identification → 15 FIFOs → head-flit exposure.

**Exit:** achieved. Stage 2 signed off with `DP all three VCs full : 7`, negative control 2/2, `All guarded states were exercised`.

---

### PHASE 2.5 — AREA + TIMING PROBE *(new; this is the correction that matters most)*

**Do this before writing another line of RTL.**

Out-of-context synthesis, no top-level constraints beyond a 50 MHz clock:

1. `noc_fifo` alone — **compare `ram_style = "distributed"` against plain flip-flops.** At depth 4 the distributed-RAM choice is not obviously right (§4.1).
2. `noc_router_datapath` — sweep `VC2_DEPTH` = 4, 8, 16.
3. `noc_crossbar` alone.
4. `NOC_ALLOCATOR` alone — this is the long combinational path.
5. `noc_router` (M8) once it exists — the real per-router number.

Record into `RESOURCES.md`, per configuration:

```
LUT   LUT%   FF   FF%   LUTRAM   BRAM   Fmax   WNS   TNS   critical path
```

**Decision gate:** `6 × router_LUT` must leave enough headroom for NI ×6, crypto lane, and RoT. If it does not, the fixes are architectural and you want to make them now: reduce VC2 depth, reduce flit width, share the routing units (§4.2), or pipeline the allocator.

**Rule:** never report an area figure without its Fmax, and never report a synthesis figure as a hardware figure.

**Exit:** `RESOURCES.md` populated; per-router LUT/FF/Fmax known; 6-router projection has headroom.

---

### PHASE 3 — Routing + Allocation *(complete)*

**M5 `noc_xy_routing`** — `coord_t current, coord_t dest` → `port_id_t route_port, logic route_valid`. On a malformed request `route_valid` is low and the port is forced to LOCAL, keeping a bad packet inside the router where the NI can raise an error.

**M6 `NOC_ARBITER`** — generic round-robin, parameter `N`. **Proved exhaustively equivalent to an independent Python model over all 2¹⁵ request patterns × all 15 pointer values = 491,520 vectors, zero mismatches.** See §4.3 for the area rewrite.

**M7 `NOC_ALLOCATOR`** — routing + arbitration + request matrix + wormhole reservation + grant + `xbar_sel` + `fifo_rd_en`.

Wormhole contract:

```
HEAD       acquire output reservation
BODY       retain
TAIL       release
HEAD_TAIL  single flit, no persistent reservation
```

**Exit:** achieved. Golden-model equivalence, 20,000 cycles, zero output and zero state mismatches; negative control 2/2.

---

### PHASE 3.5 — Router Top Level (M8) *(new; C2)*

`noc_router.sv` binds M4 → M5 → M6 → M7 → M3 and **owns the five mappings that currently do not exist**.

Verified against the port lists of `noc_router_datapath` and `NOC_ALLOCATOR`:

| # | Signal | M4 side | M7 side | Mismatch |
|---|---|---|---|---|
| 1 | Head flits | 15 **scalars** `head_<port>_vc<n>` (`flit_t`) | `head_flit [15]` **unpacked array** | shape |
| 2 | Empty flags | 15 **scalars** `empty_<port>_vc<n>` | `fifo_empty [15]` **unpacked array** | shape |
| 3 | FIFO read enable | 15 **scalars** `rd_en_<port>_vc<n>` | `fifo_rd_en [14:0]` **packed vector** | shape |
| 4 | VC output select | 15 **scalars** `sel_<port>_vc<n>` | *nothing produces these* | **missing function** |
| 5 | Crossbar select | `noc_crossbar.select_*`, 3-bit **port index** 0–4 | `xbar_sel[p]`, 4-bit **input-VC index** 0–14 | **different meaning, not just width** |

Gaps 1–3 are mechanical re-shaping. **Gaps 4 and 5 are design work, not wiring.**

- **Gap 5** is the important one. `xbar_sel[EAST] = 7` means "input VC 7 wins EAST". The crossbar wants "input **port** LOCAL feeds EAST". M8 must convert VC index → port index (`port = vc / NUM_VC`) **and** separately drive `sel_<port>_vc<n>` so M4 presents the right VC's head flit on that port's output. Those are two halves of one decision and both must come from the same grant.
- **M8 must also enforce contract L-07.** `NOC_ALLOCATOR` drives `xbar_sel` combinationally from `arb_valid`; on a stall cycle it drops to 0, which the crossbar decodes as `PORT_NORTH`, not as idle. M8 must hold the selection from HEAD through TAIL, or gate the crossbar with a valid.

**Exit:** `tb_noc_router` — a single router forwards a complete multi-flit packet from a LOCAL input to an EAST output with the correct flit sequence; L-07 hold verified across an injected stall.

---

### PHASE 4 — Credit-Based Flow Control (M9)

**Do not build a second credit counter.** `noc_fifo` already exposes `free_slots` and `credit_valid`. M9 connects them; it does not duplicate them.

Credit lives at the **sender**, tracking **downstream receiver** space:

```
sender credit[port][vc]  initialised to downstream DEPTH
send a flit              credit--
credit_return arrives    credit++
credit == 0              NO TRANSFER, even if M7 grants
```

**Core rule:** `transfer = grant AND credit_available`. `fifo_rd_en` stops being "allocation permission" and becomes "actual dequeue".

**SVA:**

```
0 <= credit <= DEPTH
send            -> credit_available
credit_return   -> downstream really freed a slot
never: credit underflow, credit overflow, FIFO overflow
same-cycle send + credit_return handled correctly
```

The last one is the classic bug. Test it explicitly.

**Debt D1 closes here.** After this phase, `noc_fifo`'s "FLIT DROPPED — write attempted while full" must never fire on legal traffic again. That assertion becomes a live invariant rather than an expected message.

**Exit:** `tb_noc_credit_control` passes; sustained full-rate traffic into a stalled receiver drops zero flits.

---

### PHASE 5 — Network Interface (M10, M11)

**M10 `noc_ni`**

```
tile transaction -> packetize -> flits -> NoC
NoC -> flits -> depacketize -> tile transaction
```

| Responsibility | Constraint |
|---|---|
| Packetization / depacketization | per O-02 length table |
| Destination extraction | via M11 |
| VC selection | request→VC0, response→VC1, attestation→VC2 |
| Outstanding transaction tracking | **bounded by N_OUTSTANDING** (C5) |
| Response matching / reordering | buffer sized by N_OUTSTANDING |
| Local vs remote decode | via M11 |

**M11 `noc_addr_decoder`** — address → {local, remote} and → destination tile. Uses `TILE_SEL_MSB/LSB` (O-01).

**Exit:** `tb_noc_ni` covers local read/write, remote read/write, response return, back-to-back requests, and N_OUTSTANDING simultaneous transactions with correct matching.

---

### PHASE 6 — Two-Tile Integration

**Correction (C7):** use an **adjacent** pair.

```
CPU0 (0,0) -- NI -- Router0 --EAST/WEST-- Router1 -- NI -- CPU1 (1,0)
```

Full path both directions, including credit return. Measure round-trip latency in cycles — this is the first number that goes into `baseline-v1`.

**Exit:** `tb_noc_2tile` — write then read-back returns correct data; zero dropped flits; latency recorded.

---

### PHASE 7 — Full 3×2 Mesh (M12)

```
        x=0        x=1        x=2
y=0    CPU0  ---  CPU1  ---  MEMORY
         |          |          |
y=1   CRYPTO ---  RoT   ---  SPOOF
```

`noc_mesh.sv` wires N↔S and E↔W between routers and ties off the mesh edges.

Use **`noc_pkg::opposite_port()`** for the wiring — it already exists (N↔S, E↔W, LOCAL↔LOCAL) and is exactly this function. Writing the mapping by hand in the mesh wrapper duplicates a frozen definition and invites the two to drift.

**Edge tie-off is a real correctness item.** A router at x=0 has no WEST neighbour. `noc_pkg::port_exists(coord, port)` already encodes which ports exist per coordinate — `PORT_WEST` requires `x > 0`, `PORT_EAST` requires `x+1 < MESH_X`, and so on. The mesh wiring must agree with that function exactly. If it does not, `noc_xy_routing` will happily return `route_valid = 1` for a port the wrapper left unconnected, and the flit disappears with no error anywhere.

**Check this explicitly:** for all six routers, assert that every port with `port_exists() == 1` has a driven neighbour, and every port with `port_exists() == 0` is tied off and never granted.

**Exit:** `tb_noc_mesh` — every source→destination pair (6×6 = 36, of which 30 are remote) delivers correctly; all three VCs; simultaneous packets; contention; backpressure.

---

### PHASE 7.5 — Deadlock Freedom *(new; C4)*

The argument you currently rely on:

1. XY dimension-order routing permits only EAST/WEST → NORTH/SOUTH turns, eliminating cyclic channel dependency at the routing level.
2. VC0 (request) / VC1 (response) separation breaks protocol-level dependency.

**Neither covers VC2.** VC2 carries the attestation challenge *and* the attestation response, so the request→response cycle that VC0/VC1 separation exists to break is reintroduced inside a single VC.

It is safe only under **invariant L-11: the RoT has at most one outstanding attestation challenge mesh-wide.** That is currently an assumption.

**This phase converts it into a checked property:**

- SVA in the RoT NI: at most one outstanding challenge at any time.
- Directed test: attempt to issue a second challenge while one is outstanding; confirm it is blocked, not queued.
- Stress test: fill VC2 in every router, then inject an attestation response; confirm forward progress.
- Liveness watchdog across the mesh: if no flit is consumed anywhere for N cycles while flits are queued, fail.

**If L-11 cannot be guaranteed by the RoT design, the fix is architectural: split VC2 into VC2-challenge and VC2-response.** That is a 3→4 VC change, which is a 33% increase in FIFO area per router. **This is exactly why it must be decided before Phase 8 freezes the baseline, and why Phase 2.5 needs to have measured the per-VC cost.**

**Exit:** deadlock argument written down in `noc_architecture.md` with the checked property named; stress test passes; liveness watchdog silent.

---

### PHASE 8 — Traffic + Performance Baseline

**Correction (C6):** the injector is **SystemVerilog** (synthesizable, so the same one runs on FPGA) with **Python** generating the patterns offline. No C — there is no CPU yet.

Patterns: uniform random, hotspot, nearest-neighbour, bit-complement.

Measure, sweeping injection rate:

```
zero-load latency        min / mean / max / P95 latency
saturation throughput    accepted vs offered rate
FIFO occupancy           per VC
credit stall cycles
```

**Freeze as `baseline-v1`.** Every later security overhead number is reported as a delta against this. Freeze it with `MAC_ENABLE = 0`.

**Exit:** latency-vs-injection and throughput-vs-injection curves produced; `baseline-v1` tagged and archived.

---

### PHASE 9 — L2 Packet Authentication (M13) *(moved earlier; C3)*

This now comes **before** attestation, because the attestation verdict travels as a NoC packet and must itself be unforgeable.

`MAC_ENABLE = 1` build. Packet grows by `MAC_FLITS` = ⌈128/32⌉ = 4 flits.

The overhead is not uniform, and the headline number comes from the shortest packets. Computed from `message_payload_flits()` and `message_length() = 1 + payload + MAC_FLITS`:

| Message | Payload | Baseline total | With MAC | Growth |
|---|---|---|---|---|
| `MEM_WR_RESP` | 0 | 1 | 5 | **5.0×** |
| `ATTEST_GRANT` / `REVOKE` | 0 | 1 | 5 | **5.0×** |
| `MEM_RD_REQ` | 1 | 2 | 6 | **3.0×** |
| `MEM_RD_RESP` | 1 | 2 | 6 | 3.0× |
| `MEM_WR_REQ` | 2 | 3 | 7 | 2.3× |
| `ATTEST_CHALLENGE` | 5 | 6 | 10 | 1.7× |
| `ATTEST_RESPONSE` | 16 | 17 | 21 | 1.2× |

`MAX_PACKET_FLITS = 1 + 16 + 4 = 21`, set by the attestation response.

The `noc_pkg` comment names the 3× on `MEM_RD_REQ`. **The worst case is actually 5× on the zero-payload messages**, and `MEM_WR_RESP` is on the critical path of every write. Report both: the 3× on the common read request, and the 5× worst case. A reviewer will find the 5× if you do not state it.

```
HEADER | PAYLOAD ... | MAC flit x4
```

TAIL is the **last MAC flit**, not the last payload flit. The allocator must hold the reservation until the MAC flits have been forwarded — already noted in `noc_pkg`, must be verified in M8.

Replay protection: a monotonic counter included in the authenticated input.

**Tests:** correct packet; modified header; modified payload; modified MAC; replayed packet; counter mismatch; `MAC_ENABLE = 0` regression.

**Exit:** `tb_noc_l2_auth` passes all seven; overhead measured against `baseline-v1`.

---

### PHASE 10 — L3 Attestation Enforcement (M14, M15)

```
RESET -> UNATTESTED -> ATTESTING -> ATTESTED -> data enabled
                           |
                           +--> FAILED -> data blocked permanently
```

Rule: an unattested tile's **data** traffic (VC0/VC1) is blocked; its **attestation** traffic (VC2) is allowed, otherwise it could never become attested.

`noc_fault_status` records: which tile, which check failed, timestamp, and whether it was blocked.

**Tests:** genuine tile; failed attestation; data blocked while unattested; attestation permitted while unattested; successful transition; revocation; timeout; runtime substitution.

**Exit:** `tb_noc_attest_gate` passes; blocked-traffic count observable in fault status.

---

### PHASE 11 — Security Experiments

| ID | Scenario | Expected |
|---|---|---|
| E1 | Genuine tile | attests, data flows |
| E2 | Spoofed tile (SPOOF at (2,1)) | attestation fails, data blocked |
| E3 | Replay | counter mismatch, packet rejected |
| E4 | Runtime substitution | re-attestation fails, tile isolated |

Evidence per experiment: UART transcript, ILA capture, fault-status dump, packet trace. Archive under `security/E1_genuine/` etc.

**Every experiment needs a negative control** — a run where the mechanism is disabled and the attack succeeds. Without it you have not shown the mechanism did the blocking.

---

### PHASE 12 — Final NoC Verification

`tb_noc_final.sv` — functional + constrained-random + stress + security in one environment.

Network-level SVA:

```
no FIFO overflow / underflow
no credit overflow / underflow
no illegal route
no illegal grant
no VC granted to two outputs
no wormhole owner change mid-packet
no packet corruption end-to-end
no data traffic from an unattested tile
no forward-progress stall (liveness)
```

**Every one of these needs its guarded state reached and a negative control.** Project record so far: **twenty checker defects, zero RTL defects.** Assume the checker is wrong before assuming the RTL is.

**Exit:** all pass; coverage report shows no hole; NoC RTL frozen.

---

### PHASE 13 — NoC FPGA Closure (M16)

Full `noc_top` through synthesis and implementation. Report, for both `MAC_ENABLE = 0` and `= 1`:

```
LUT  LUT%  FF  FF%  LUTRAM  BRAM  BRAM%  DSP  Fmax  WNS  TNS
```

Artefact `noc_fpga_closed/`: `utilization.rpt`, `timing.rpt`, `power.rpt`, `constraints.xdc`, `baseline-v1-results/`.

**"Vivado says it fits" is not a result.** The result is the table above with a headroom statement for the crypto lane and RoT.

**Exit:** WNS ≥ 0, TNS = 0 at 50 MHz; headroom documented.

---

## 4. Area-efficiency methodology

### 4.1 FIFO storage — the reasoning is sound, the magnitude is not measured

Arithmetic that is certain (verified against `noc_pkg`):

```
flit_t                 36 bits = 32 FLIT_WIDTH + 2 flit_type_e + 2 VC_ID_WIDTH
FIFOs per router       5 ports x 3 VCs = 15
Storage per router     15 x 4 x 36 = 2,160 bits
Storage, 6 routers     12,960 bits
```

`noc_fifo` forces `(* ram_style = "distributed" *)` and gives two reasons (L-12). They are not equally strong, and it is worth separating them:

**Reason 1 — BRAM is structurally excluded, and this is decisive.** The comment states it exactly: *"BRAM has a registered read port and this FIFO presents its head combinationally."* The allocator reads `head_flit` combinationally in the same cycle it arbitrates. A BRAM output would arrive a cycle late. This is an architectural exclusion, not an area trade-off — **do not re-open it in the probe.**

**Reason 2 — distributed RAM vs flip-flops is argued but not quantified.** The comment says that without the attribute Vivado *"may map this array to flip-flops plus an explicit read mux, which roughly doubles the LUT cost of the largest block in the NoC."* The mechanism is right — the read mux is the cost, not the storage — but *"roughly doubles"* is an estimate. On Artix-7 each slice has 4 LUTs and 8 flip-flops, so flip-flops are usually the less-contended resource, and at depth 4 the read mux is only 4:1.

**Phase 2.5 quantifies reason 2. It does not re-litigate reason 1.** Synthesise `noc_fifo` both ways and record LUT / FF / LUTRAM for each. The expected outcome is that distributed RAM wins; the point is to replace the word *"roughly"* with a number, so the choice is defensible in a paper and re-checkable if `VC2_DEPTH` grows to 8 or 16 — where the read mux, and therefore the trade-off, changes.

### 4.2 Routing — 15 instances per router is wasteful

`NOC_ALLOCATOR` instantiates `noc_xy_routing` **once per input VC = 15 per router = 90 across the mesh.**

Only the HEAD flit of a packet needs routing. BODY and TAIL follow the reservation. So 15 parallel routers compute a result that is discarded for most flits, every cycle.

**Recommended: route precomputation at enqueue.**

*Terminology matters if this goes in a paper.* This is **not** lookahead routing. Lookahead routing computes the port for the **next** router one hop upstream and carries it in the flit. What is proposed here computes **this** router's port at the moment the flit is written into this router's FIFO. Simpler, and it does not change the flit format on the link. Call it route precomputation.

```
current:   flit sits in FIFO -> 15x XY unit -> request matrix
proposed:  flit arrives      ->  1x XY unit per input PORT (5/router)
                             -> store 3-bit route WITH the flit
                             -> allocator reads the stored route
```

Cost: 3 extra bits per FIFO entry = 3 × 4 × 15 = 180 bits per router.
Saving: 10 XY instances per router, 60 across the mesh.
**Second benefit, which matters more:** XY routing leaves the allocation critical path entirely. The current path is `FIFO → XY → request matrix → arbiter → grant → xbar_sel`, which is the longest combinational path in the router. Removing XY from it is the cheapest Fmax improvement available.

This is standard practice in NoC design and is worth doing before Phase 7 multiplies everything by six.

### 4.3 Arbiter — the search loop is the wrong structure

`NOC_ARBITER` is functionally **proven correct** (491,520/491,520 exhaustive). This is purely an area and timing note, not a correctness one.

The implementation is a 15-iteration sequential search with a `found` flag. That synthesises to a priority chain 15 stages deep — large in LUTs and slow.

**Standard alternative: mask-based round robin.**

```
mask      = ~((1 << rr_ptr) - 1)        // requesters at or above pointer
hi        = priority_encode(req & mask) // first one above pointer
lo        = priority_encode(req)        // first one overall, for wrap
grant     = (req & mask) ? hi : lo
```

Two priority encoders and a mux, no ripple chain. Smaller and substantially faster.

**Because the golden model already exists, this rewrite is cheap and safe:** rewrite, re-run `tb_stage3_golden` Phase A, and 491,520 exhaustive vectors confirm it is bit-identical to the current behaviour. That is the payoff for having built the model — you can now refactor for area with proof rather than hope.

### 4.4 Crossbar — 25 connections, only 20 are legal

`noc_crossbar` is 5×5. A flit never leaves by the port it arrived on, and the module already asserts this on **all five ports** — `a_no_loopback_north/south/east/west/local` are all present (verified, not assumed).

**Five of the 25 crossbar paths are excluded by a checked invariant.** Each output becomes a **4:1** mux over 36 bits instead of **5:1**.

**I initially wrote "roughly 20%" here. That understates it, and the reason is specific to the 7-series LUT.** A LUT6 has six inputs. A 4:1 mux needs 4 data + 2 select = 6 inputs, so it fits in **one LUT6 per bit**. A 5:1 mux needs 5 data + 3 select = 8 inputs, so it does **not** fit and costs two LUT6 plus an F7MUX per bit. The saving on the crossbar data path is therefore expected to be closer to **half**, not a fifth — 36 bits × 5 outputs is the whole crossbar, so this is one of the larger single wins available.

Stated as an expectation, not a result: **Phase 2.5 synthesises `noc_crossbar` both ways and records the actual numbers.** Do not quote the "half" figure until the probe confirms it.

Two conditions before cutting:

1. The no-loopback assertions must have been *exercised*, not merely present. Stage 2 reported `XBAR legal selects : 38,982` and `XBAR illegal selects : 3`, so the illegal path is reached — good.
2. Keep an assertion after the cut. Once the path is removed, a selector value that used to be merely illegal becomes structurally impossible, and silence is not the same as correctness.

### 4.5 VC depth

`noc_pkg` already flags VC2 for a 4/8/16 sweep. Do it in Phase 2.5, not later. Note the coupling: if Phase 7.5 forces VC2 to split into challenge/response VCs, you go from 3 VCs to 4, which is +33% FIFO area per router. **Measure the per-VC cost early so that decision is priced.**

### 4.6 Reporting discipline

- Never an area number without its Fmax.
- Never a synthesis number described as a hardware number.
- Always baseline first (`MAC_ENABLE = 0`), then the delta.
- Every configuration recorded in `RESOURCES.md` with the exact Vivado version and constraints, so numbers are comparable across months.

---

## 5. Phase exit criteria — one line each

| Phase | Exit |
|---|---|
| 1 | Architecture frozen; O-01/02/03 closed; N_OUTSTANDING frozen |
| 2 | Datapath verified; coverage complete; negative control fires |
| **2.5** | **`RESOURCES.md` populated; 6-router projection has headroom** |
| 3 | Routing + allocation equivalent to golden model |
| **3.5** | **One router forwards a multi-flit packet; L-07 hold verified** |
| 4 | Zero flits dropped under sustained backpressure; D1 closed |
| 5 | NI handles N_OUTSTANDING transactions with correct matching |
| 6 | Two-tile write/read-back correct; latency recorded |
| 7 | All 30 remote source→destination pairs deliver |
| **7.5** | **Deadlock argument checked, not assumed; liveness watchdog silent** |
| 8 | `baseline-v1` frozen with latency and throughput curves |
| 9 | L2 auth passes all seven tests; overhead measured vs baseline |
| 10 | Attestation gate blocks data, permits attestation traffic |
| 11 | E1–E4 with evidence **and negative controls** |
| 12 | All network SVA pass, every guarded state reached, no hole |
| 13 | WNS ≥ 0, TNS = 0 at 50 MHz; headroom documented |

---

## 6. What "NoC complete" means

Not "the six routers simulate correctly". It means:

```
Functionally verified      every guarded state reached, negative controls fire
Equivalence checked        against an independent model, exhaustive where feasible
Deadlock argued            as a checked property, not an assumption
Performance baselined      baseline-v1 frozen, curves published
Security verified          E1-E4 with negative controls
Synthesized                real numbers, not estimates
Timing closed              WNS >= 0, TNS = 0 at 50 MHz
Resource closed            headroom documented for crypto + RoT
Interface frozen           handed over as a contract, not evolving RTL
```

Only then does Phase 14 start, and what you hand over is a **frozen interface** — ports, protocol, address map, clock/reset convention, and the outstanding-transaction limit — not a moving target.

---

## Appendix — verification lessons carried forward

These came from twenty defects found in this project. All twenty were in checkers and testbenches. Zero were in RTL.

| ID | Lesson |
|---|---|
| **L-02** | File name must equal module name. Two files have violated this and both cost time. |
| **V-01** | A failing check is more likely a wrong property than a wrong DUT. Check the checker first. |
| **V-07** | An assertion whose guarded state is never reached is indistinguishable from a broken one. Every assertion needs a coverage obligation. |
| **V-09** | Combinational checks belong *inside* the `always_comb` that produces the values, as immediate assertions. Separate processes have no guaranteed evaluation order. |
| **V-12** | Concurrent SVA sampling combinational outputs in the preponed region can read X. 179,984 failures on provably correct RTL. Same fix as V-09. |
| **A7** | Coverage counters must not be cleared by reset. Reset is a normal mid-run event; clearing them changes the question being asked. |
| — | Every testbench needs a **watchdog** and a **negative control**. One hung for 1.65 ms and reported nothing; one reported PASS for three days without ever being able to fail. |
| — | Golden-model equivalence beats assertions. It is what settled the arbiter question, and it is what makes the area rewrites in §4 safe to attempt. |
