# M-F1 — NoC Interface Freeze

**Status:** rev 4, 2026-09-25. **SIGNED by delegation** (see §14). Binding for all NoC-lane work from this revision.
**Rev 4** applies amendments AM-1..AM-6 from N-8.1 architecture rev 1 (`docs/decisions/N-8.1-ni-endpoint-containment.md` §12),
approved in the 10b review. AM-2 is an architectural transport amendment (TX behaviour + latency); AM-5/AM-6 change protocol
values/behaviour; the rest are clarifications/decisions. No router value changes. (Rev 3 title still read "DRAFT (UNSIGNED)"
although §14 was signed; corrected here.)
**Scope:** the NoC lane interfaces other work builds on: N-8 traffic, N-9/N-10 MAC and enforcement, S-8 attestation protocol, N-14 SoC.
**Source of truth (RTL baseline): commit `acd1f73`** on branch `noc/credit-integration`. That is the RTL the N-2.5 MF1 gate (reports/n25_mf1_2026-09-25, gate HEAD `acd1f73`) and the XSim mf1 regression ran on. Commit chain: `9251bab` (values first read) → `111f0a5` (+ I-3 check, the only RTL change) → `acd1f73` (docs) → later commits are docs/logs only (`git diff --stat acd1f73 HEAD -- NOC_PQATTEST.srcs synth` is empty). Any RTL change after `acd1f73` voids this freeze until the mf1 regression and the N-2.5 gate are re-run.

---

## 1. Topology (frozen)

| Item | Value | Source |
|---|---|---|
| Mesh | 3 × 2, 6 tiles, 5 ports/router (N,S,E,W,LOCAL) | `noc_pkg` MESH_X/Y, NUM_PORTS |
| Port encoding | N=0, S=1, E=2, W=3, LOCAL=4, PORT_NONE=7 | `port_e` |
| Tile map (id → x,y) | CPU0 0→(0,0) · CPU1 1→(1,0) · MEMORY 2→(2,0) · CRYPTO 3→(0,1) · RoT 4→(1,1) · SPOOF 5→(2,1) | `tile_to_coord` |
| Tile index | i = y·MESH_X + x | `noc_mesh_3x2` GEN_R |
| Routing | XY, deterministic | M5 `noc_xy_routing` |
| Switching | wormhole (HEAD acquires, TAIL releases, HEAD_TAIL single-flit) | M7 `allocator.sv` |

## 2. Flit format (frozen)

`flit_t` = 36 stored bits, and there is **no valid bit in the flit**. Validity belongs to the transfer (L-05).

| Field | Bits | Encoding |
|---|---|---|
| `flit_data` | 32 | payload, or the head word below |
| `flit_type` | 2 | HEAD=0, BODY=1, TAIL=2, HEAD_TAIL=3 |
| `vc_id` | 2 | 0=REQUEST, 1=RESPONSE, 2=ATTESTATION, **3 = illegal** |

**Head word** (`head_flit_t`, packed, MSB first):

| Bits | Field | Width |
|---|---|---|
| [31:29] | dest_x | 3 |
| [28:26] | dest_y | 3 |
| [25:23] | src_x | 3 |
| [22:20] | src_y | 3 |
| [19:16] | msg_type | 4 |
| [15:11] | length (total flits incl. head, incl. MAC) | 5 |
| [10:0] | control (overlay by message class) | 11 |

The `control` field has four overlays. They share bits, so which one applies depends on the message:

| Message class | Fields |
|---|---|
| mem write request | wstrb [10:7] |
| mem response | err [10] |
| attestation | status [10:7] |
| transaction tag (memory messages) | tag [0] |

## 3. Virtual channels (frozen)

- **3 VCs per port, 4 flits each** (VC0/1/2_DEPTH = 4).
- **VC class is fixed by message type** (`message_to_vc`):

  | Message type | VC |
  |---|---|
  | MEM_*_REQ | REQUEST (0) |
  | MEM_*_RESP | RESPONSE (1) |
  | ATTEST_* | ATTESTATION (2) |

- **A flit keeps its VC on every hop.** There is no VC reallocation: M9 uses `selected_vc = xbar_sel % NUM_VC`.
- ⚠ **VCs isolate buffers, not output links.** See FD-1 in §10.

## 4. Message types (frozen for ids and lengths)

`MAC_FLITS` = 0 today because `MAC_ENABLE` = 0.

| id | msg_type | VC | payload flits | total length (MAC off) |
|---|---|---|---|---|
| 0 | MEM_RD_REQ | REQ | 1 | 2 |
| 1 | MEM_RD_RESP | RESP | 1 | 2 |
| 2 | MEM_WR_REQ | REQ | 2 | 3 |
| 3 | MEM_WR_RESP | RESP | 0 | 1 (HEAD_TAIL) |
| 4 | ATTEST_CHALLENGE | ATT | 5 (160 bits) | 6 |
| 5 | ATTEST_RESPONSE | ATT | 16 (512 bits) | 17 |
| 6 | ATTEST_GRANT | ATT | 0 | 1 |
| 7 | ATTEST_REVOKE | ATT | 0 | 1 |

- 8–15 are reserved. **(rev 4, AM-5)** A reserved msg_type is rejected: NI TX raises `tx_error` and sends nothing; NI RX
  consumes it as a framing error (HEAD → discard to terminator, HEAD_TAIL → back to idle). Until N-8.1 RTL lands, the RTL still
  maps them to VC0 / length 1 (known gap, N-8.1 Gap C).
- **(rev 4, AM-6)** A HEAD whose length field ≠ `message_length(msg_type)` is rejected and consumed to its terminator, never delivered.
- With MAC on, every packet grows by 4 flits (128-bit tag). MAX_PACKET_FLITS = 21, which fits the 5-bit length field.

## 5. Transaction tags (frozen)

- **Up to 2 outstanding remote memory transactions per NI** (`N_OUTSTANDING` = 2).
- **The tag is 1 bit, carried in `control[0]`.**
- **The NI (M10) allocates the tag; the CPU does not.** A response must echo its request's tag.

## 6. Address map (frozen)

| Region | Base | Size |
|---|---|---|
| Local IMEM | 0x0000_0000 | 16 KB |
| Local DMEM | 0x0000_4000 | 16 KB |
| UART / GPIO / STATUS / NI regs | 0x1000_0000 / _1000 / _2000 / _3000 | 4 KB each |
| Remote | addr[31:28] = 0x2, tile = addr[27:24] | tile ≥ 6 → invalid (decoder `valid`=0) |

The only decoder is `address_to_coord_safe` (L-08).

## 7. Router ↔ router flow control (frozen, 7c)

- **Credit-based, one counter per output port × VC.** Each counter resets to 4.
- **The upstream counter decrements when the flit is granted**, not when it arrives.
- **`credit_out` is a registered 1-cycle pulse**, raised one clock after the downstream FIFO pops. It drives the neighbour's `credit_return`.
- **Link stage (`LINK_PIPE=1`, frozen ON):** each router-to-router data link has one register. Credits are not piped.
- **Credit round trip = 4 cycles = VC depth 4 (invariant I-1).** One VC can sustain 1 flit/cycle, with zero slack.

## 8. NI ↔ router (LOCAL) flow control (frozen, 7c)

- **Ready/valid in both directions, one ready bit per direction.**
  - LOCAL in: a transfer happens when `in_valid_local && in_ready_local`.
  - LOCAL out: a transfer happens when `out_valid_local && out_ready_local`.
- **`out_valid_local` = `!eject_empty`.** It comes from a register and never depends on `out_ready_local`. This is required because the NI's `noc_rx_ready` is combinational on `noc_rx_valid`/`noc_rx_flit`.
- **The flit is held stable until accepted** (SVA `a_local_out_flit_hold`).
- **`in_ready_local` is per the incoming flit's VC.** A LOCAL flit with an illegal VC gets `in_ready_local` = 1 (existing behaviour; decided in N-8.1, see §11).

## 9. LOCAL credit behaviour (frozen)

- **LOCAL output credits = 4 + 4 + 4 = 12. The eject FIFO holds 12** (it maps to a 16-deep LUTRAM).
- **Eject stage (`EJECT_PIPE=1`, frozen ON):** the flit and its write strobe are registered before the eject FIFO.
- **Safety:** the credit is consumed at grant, so a flit sitting in the stage already owns a slot.
- **LOCAL credits return when the eject FIFO pops**, internal to the router. `credit_return[LOCAL]` is ignored at the mesh boundary and tied to 0.

## 10. FD-1 — endpoint containment (DECIDED: B′, property frozen, mechanism = N-8.1)

**What the RTL does (unchanged, frozen):** the allocator reserves a whole **output port** per packet
(`output_locked[p]`, `output_owner[p]` in `allocator.sv`), not an (output port, VC) pair. VCs isolate
buffers, not links. The router is **not** modified for FD-1 (option A rejected: it rewrites the
allocator, which is the +0.202 ns critical path).

**Why a rule on tiles is not enough:** the NI couples the network to the tile. In
`noc_network_interface.sv` a valid packet for the local tile gets `noc_rx_ready = rx_ready`
(RX_IDLE / RX_PAYLOAD, ~L827, ~L877). A tile holding `rx_ready = 0` therefore stalls the eject FIFO
and, through wormhole reservation, shared router ports. SPOOF is an adversarial tile by design, so
"tiles always consume" cannot be assumed. (Malformed / misaddressed / unmatched traffic is already
consumed with `noc_rx_ready = 1` + `rx_protocol_error`; the gap is valid traffic only.)

**FROZEN REQUIREMENT FD-1 (B′):**
1. Tile-side backpressure must not propagate into the NoC indefinitely. The trusted NI bounds it.
2. Once the NI accepts a packet HEAD it **owns** that packet until the accepted flit that terminates it
   (TAIL; for a single-flit packet the HEAD_TAIL itself), and consumes it without depending on the tile.
   Ownership ends on the actual terminator flit, not on a length/payload counter: a length mismatch may
   raise an error but must never create a router/NI disagreement about packet boundaries. Router and NI must never disagree about whether a packet is
   in flight: "drop" means *keep accepting and discard to the terminator*, never "stop accepting".
   **Terminator** = the accepted TAIL flit, or HEAD_TAIL for a single-flit packet. It is NOT "the last
   payload flit": with MAC_ENABLE = 1 the last payload flit is BODY and the last MAC flit is TAIL
   (`noc_network_interface.sv` TX: `(tx_last_payload && MAC_FLITS==0) ? TAIL : BODY`, `tx_last_mac ? TAIL : BODY`).
   **(rev 4, AM-3)** Precisely: terminator(k, type) = (k = 0 ∧ HEAD_TAIL) ∨ (k ≥ 1 ∧ TAIL), k = flit position in the packet.
   A mid-packet HEAD or HEAD_TAIL is **not** a terminator, mirroring the allocator (only the owner's TAIL releases a locked
   output, `allocator.sv` ~L470; A4 flags the malformed case).
3. Credits, packet accounting and wormhole release in the router stay exactly as in §7-9. No router
   RTL change.
4. Every containment event is reported by **at least one persistent observable**: a sticky containment
   flag (cleared only by reset or an explicit clear) or a monotonic containment-event counter. A one-cycle
   pulse alone is insufficient. (N-8.1 plan: implement both; the sticky flag is the acceptance criterion.)
5. A malicious endpoint may hold a network resource temporarily, but cannot retain it indefinitely solely by
   withholding tile-side consumption **or supply** (rev 4, AM-2). Traffic that needed that resource completes after containment.
   **(rev 4, AM-2 — architectural transport amendment)** The NI acquires the complete packet payload from its tile **before**
   injecting the HEAD (TX store-and-forward); from HEAD to terminator it supplies every flit without depending on the tile.
   Cost: HEAD latency + T_fill; measured in N-8.
6. The endpoint watchdog counts **tile-induced** stall only: cycles with packet owned AND `noc_rx_valid = 1`
   AND tile not accepting. It must not advance when the upstream NoC simply has no next flit
   (`noc_rx_valid = 0`).
   **(rev 4, AM-1)** The count also includes the **HEAD-pending** interval: cycles in which a deliverable HEAD/HEAD_TAIL is
   valid at the NI and the tile has not accepted it (RX_IDLE forwards `rx_ready` for it today). Responsibility starts at
   presentation; ownership (rule 2) starts at acceptance. The count is per packet and cumulative (not reset per flit).

**Mechanism: NOT frozen — N-8.1 deliverable.** Candidate to evaluate first, because it matches the
NI's existing error path: a per-packet watchdog in the NI (rule 6); on expiry the NI enters a
*discard-to-terminator* state with `noc_rx_ready = 1` and raises an error. It needs no packet buffer, so
the 17-flit (21 with MAC) packet vs 12-flit eject depth is not an issue. Alternatives (bounded
receive buffer, buffer + watchdog) are compared in N-8.1 before any RTL.

**Acceptance evidence (N-8.1, required before N-8 proper) — finite and deterministic:**
- **Topology fixed in the N-8.1 test plan before RTL:** the source of the 17-flit ATTEST_RESPONSE to SPOOF
  (tile 5), the exact router output ports its wormhole reservation holds, and a finite set of competing
  packets from other tiles that must cross those same ports (packet counts stated).
- **Completion bound:** every competing packet completes within a cycle bound derived in the plan from
  watchdog limit + path length + packet length (not guessed).
- **Drain condition** after the finite workload: all router input FIFOs and eject FIFOs empty, all link
  and eject stage valids 0, every credit counter back to its reset value.
- **Containment observed:** sticky containment flag set (acceptance criterion) and event counter incremented, both still readable after the discard.
- **Negative control:** same workload with the watchdog disabled must hit a fixed timeout of the same
  cycle bound (deterministic FAIL, not an open-ended hang).
- **Separate tests** (different failure classes, not merged with the above): premature TAIL, BODY at the
  expected end, HEAD_TAIL on a multi-flit message type, length field ≠ message length, illegal VC 3 at
  LOCAL input, and **missing TAIL / truncated packet** (sender stops mid-packet).
- **Truncated packet is a protocol-boundary test, not a containment case:** under this freeze only the
  terminator releases a router reservation; neither the NI nor the router may release it on length
  expiry or idleness, and no router timeout is added. The test documents the resulting stall and hands
  sender-side detection to S-8/N-10.
- **Framing tests run in both framing modes:** MAC_ENABLE = 0 (last payload = TAIL) and MAC_ENABLE = 1
  (last MAC flit = TAIL), so terminator handling is not hard-coded to one mode.

**Known NI framing gap to fix in N-8.1 (verified in RTL):** `RX_PAYLOAD` leaves on the payload
*counter* (`rx_payload_cnt_q + 1 >= rx_payload_n_q`, `noc_network_interface.sv` ~L885/L968), not on
the TAIL flit. A premature TAIL lets the router release the path while the NI stays in `RX_PAYLOAD`;
the next packet's HEAD is then consumed as a protocol error and its BODY flits are misattributed. Rule 2
above requires ownership to end on the terminator flit.

**Initiators:** the transport layer imposes **no initiator authorization restriction**: every tile NI has
transport TX capability and the decoder accepts remote tiles 0-5. Which initiator/message pairs are *authorized* is N-10
policy, not M-F1. No endpoint buffer size (e.g. "36 flits") is frozen here; any bound is derived in
N-8.1 from outstanding transactions and packet lengths.

## 11. Out of scope for M-F1 (owned by S-8, NOT frozen here)

M-F1 is the **NoC transport** freeze. These are attestation-protocol semantics and are frozen in S-8:

| # | Item | What exists today | Missing |
|---|---|---|---|
| S8-1 | Attestation request/response field layout | widths only: challenge 160 bits (5 flits), response 512 bits (16 flits) | field map (nonce, measurement, tag, epoch) |
| S8-2 | MAC format | MAC_TAG_BITS 128 = 4 trailing flits (L-09); MAC_ENABLE = 0 | key, KMAC customization, coverage, enable point |
| S8-3 | Nonce semantics | TRNG nonce 128 bits; challenge field 160 bits | 128->160 mapping, freshness window |
| S8-4 | Attestation status codes | 4-bit `control.attest.status` | value table |
| S8-5 | Error behaviour at the tile | NI `tx_error`, `rx_protocol_error`, `rx_length_error` | tile reaction per error |

Transport-level item kept here: the router accepts a LOCAL flit with illegal VC 3 (`in_ready_local = 1`).
**(rev 4, AM-4) Decided:** the NI TX cannot emit VC 3 (`message_to_vc` maps every msg_type onto 0..2; SVA `a_tx_vc_legal`
in N-8.1). Router LOCAL-in behaviour for VC 3 is unchanged (accept + drop, unreachable from a trusted NI). NI RX flags any VC
mismatch, VC 3 included, as a framing error.

## 12. Timing and latency contract

- **Clock:** 50 MHz (20 ns), closed **under Vivado 2024.1, xc7a100tcsg324-1, strategy Performance_ExplorePostRoutePhysOpt**: WNS +0.202 ns, all gate checks PASS (N-2.5 run 3 `impl_pe`, and again on the final RTL: `impl_1`, reports/n25_mf1_2026-09-25). Default strategy: WNS +0.048 ns, 0 failing (timing report only, full gate not run). This is an implementation result, not an intrinsic property of the RTL.
- **Implementation strategy is pinned on `impl_1`:** `Performance_ExplorePostRoutePhysOpt`. Default strategy also met timing once, at +0.048 ns (0.24%); it is a fallback, not the reference.
- **Latency added by the timing fixes:**
  - +1 cycle per router-to-router hop (`LINK_PIPE`)
  - +1 cycle per LOCAL delivery (`EJECT_PIPE`)
- **NI timing is not measured:** the N-2.5 gate synthesizes `noc_mesh_synth_top` (6 routers, no NI).
  NI timing is checked separately when N-8.1 changes the NI.
- **Absolute per-hop latency is not measured yet.** That is an N-8 deliverable, in cycles first.
- **Rule:** any NoC RTL change requires the XSim regression and the N-2.5 gate to run again before merge. The margin is 1%.

## 13. Invariants (checked where stated)

| id | Invariant | Checked by |
|---|---|---|
| I-1 | credit round trip ≤ VC depth (4 ≤ 4) | analysis §7; N-7/N-6 pass. A throughput test is due in N-8 |
| I-2 | a flit never enters a full FIFO | FIFO SVA "FLIT DROPPED": 0 firings in N-7/N-6/M8, fires on mutant M-c. TB1 fires it only in its deliberate-violation phases |
| I-3 | EJECT_DEPTH ≥ total LOCAL credit | elaboration `$fatal` in `noc_router.sv`; negative test: EJECT_DEPTH=11 → `$fatal` at t=0 (logs/i3_negative_verilator_2026-09-25.log); XSim mf1 regression PASS with it |
| I-4 | `out_valid_local` independent of `out_ready_local` | M8 T9, 7c rule |
| I-5 | VC id never changes in flight | N-7 per-link legal-VC checks; RTL `xbar_sel % NUM_VC` |

## 14. Sign-off

Evidence in the repo at signature:
- [x] RTL baseline `acd1f73`; `git diff acd1f73 HEAD -- NOC_PQATTEST.srcs synth` empty
- [x] XSim mf1 with I-3, all RECOMPILED: N-7 1756/0, M8 47/0, N-6 126/0, TB1 PASS (logs/*_mf1_2026-09-25.log)
- [x] I-3 negative test fires: EJECT_DEPTH=11 → `$fatal` at t=0 (logs/i3_negative_verilator_2026-09-25.log)
- [x] N-2.5 gate on `impl_1`, pinned PhysOpt: PASS, WNS +0.202 ns, 0/18,237 (reports/n25_mf1_2026-09-25)
- [x] FD-1 decided: B′ requirement §10 (mechanism = N-8.1)
- [x] Two independent external reviews (25-Sep): rev 2 "ready to sign"; rev 3 applies their three
      non-blocking wording/test-plan items (terminator definition, persistent observable, truncated packet)

Signing freezes §1-§10 and §12-§13. It does **not** claim FD-1 is implemented. N-8.1 must meet the §10
acceptance evidence before any other N-8 work. M-F1 is re-opened if FD-1 cannot be met without a router
change, or if any RTL after `acd1f73` changes a frozen value.

**Rev 4 (2026-09-25), signed by delegation** on Kalash's instruction to apply the 10b review ("review with all skills nd apply").
The N-8.1 NI RTL is the sanctioned mechanism for §10 and does not void this freeze by itself; it still requires the full
XSim regression and (because `NOC_PKG.sv` gains a default-preserving MAC define) the N-2.5 gate before merge.

**Signed by delegation:** Claude, on Kalash's explicit instruction of 2026-09-25 ("all questions u asked
me finalize them urself"), after a council review (below). Same delegation model as the 7c freeze.
Kalash may countersign or re-open at any time.

Council summary (why signing now is right):
- Contrarian: the only real risks (FD-1 unimplemented, NI framing bug, thin +0.202 ns) are all written
  in as conditions or re-open triggers, not hidden.
- First principles: M-F1 freezes *how packets move*. Nothing in the three edits or the open NI work changes
  a transport value, so waiting buys no information.
- Expansionist: signing unblocks N-8.1 and S-8 in parallel; delay blocks both.
- Outsider: provenance is now a single commit with evidence files in the repo.
- Executor: next action is the N-8.1 architecture document, no RTL.

Countersigned: ____________ (Kalash) Date: ________
