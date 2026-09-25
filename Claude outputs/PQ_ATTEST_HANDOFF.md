# PQ-Attest — session handoff

Paste this whole block into a new session to bring it up to speed.

---

## Who I am and what this is

I'm Kalash Bheda, B.Tech EXTC at DJSCE Mumbai (grad 2028), B.Tech HONOURS in VLSI.
Goal: ASIC Design Engineer. I want direct, conclusion-first, technically rigorous
answers — push back when I'm wrong, never fabricate, always flag uncertainty.
Address me by name.

**PQ-Attest** = Post-Quantum-Secured Network-on-Chip RISC-V SoC with Runtime Tile
Attestation, on a single FPGA. 4 undergraduates, 2 semesters (~30 weeks). Target
output: working FPGA demo + conference/journal paper.

- Board: **AMD Arty A7-100T** (`xc7a100tcsg324-1`), **Vivado 2024.1**
- 6-tile 3x2 mesh NoC; each tile must periodically prove identity to an on-chip
  Root of Trust using post-quantum crypto; the NI refuses to forward packets
  until it does.
- Research contribution: runtime periodic per-tile PQ-signed attestation used as
  **NoC admission control**, with quantified area/latency/throughput cost.
- Three security layers: L1 boot verification, L2 per-packet authentication,
  L3 runtime tile attestation.
- I write ALL the SystemVerilog including the crypto, deliberately, for RTL and
  interview experience. Arnav owns cryptography (algorithms, protocols,
  parameters, test vectors, security argument) but writes no RTL.
- My self-assessment: strong in Verilog/FPGA/Vivado/timing closure; beginner in
  RISC-V internals, NoC, cryptography, hardware security.

**Known risks I've logged:** P1 resource budget may exceed the device; P3 novelty
is a combination claim; P7 ML dataset doesn't exist; P8 no dedicated verification
engineer; P9 nobody can review my RTL; **P10 threat model still outstanding**.
Two silent failure modes I fear most: **F1 NoC deadlock**, **F2 broken freshness
path**.

---

## Two independent lanes

### Lane A — NoC (my lane, Windows Vivado project)

Path: `C:\vivado_verilog_proj\NOC_PQATTEST`

Key docs in that folder: `NOC_WORKSTREAM.md`, `PLAN_COMPLIANCE_AUDIT.md`,
`VERIFICATION_LOG.md`.

Module map from `NOC_WORKSTREAM.md`:

| ID | Module | File | Phase |
|----|--------|------|-------|
| M1 | `noc_pkg` | `NOC_PKG.sv` | 1 |
| M2 | `noc_fifo` | `NOC_FIFO.sv` | 2 |
| M3 | `noc_crossbar` | `NOC_CROSSBAR.sv` | 2 |
| M4 | `noc_router_datapath` | `NOC_DATAPTAH.sv` | 2 |
| M5 | XY routing | `NOC_XY_ROUTING.sv` | 3 |
| M6 | arbiter | `NOC_arbiter.sv` | 3 |
| M7 | allocator | `allocator.sv` | 3 |
| M8 | `noc_router` | `noc_router.sv` | 3.5 |
| M9 | `noc_credit_control` | `noc_credit_counter.sv` | 4 |
| M10 | network interface | `noc_network_interface.sv` | 5 |
| M11 | `noc_addr_decoder` | `noc_addr_decoder.sv` | 5 |
| M12 | `noc_mesh` | 7 | M13 `noc_l2_auth` 9 | M14 `noc_attest_gate` 10 |
| M15 | `noc_fault_status` 10 | M16 `noc_top` 13 |

M1–M9 done. **M10 and M11 are where we are.**

### Lane B — crypto (Python reference + Keccak/SHA3 RTL)

Delivered to me as zips (`PQ_Attest 2`, `PQ_Attest 3`, `Pq_Attest_final`).
Separate tree from the NoC Vivado project. Contains:

- `software/` — from-scratch Python: `keccak_ref`, `sha3_256_ref`, `kmac128_ref`
  (cSHAKE128 + KMAC128 + `derive_tile_key`), `trng_conditioning_ref`,
  `measurement_ref`, `attestation_ref`, `attestation_protocol`,
  `kdf_vectors`/`kdf_verification`, `security_regression`,
  `cross_module_regression`, `run_all_tests.py`.
- `rtl/keccak/` — `keccak_round.sv`, `keccak_f1600_core.sv`
- `rtl/sha3/` — `sha3_256_core.sv`, `tb_sha3_256_core.sv`
- Golden vectors: `kdf_vectors.txt`, `trng_vectors.txt`

**Verified state:** `python software/run_all_tests.py` → **8/8 PASS, 0.30 s**
(KMAC128 NIST KAT, Measurement Reference, KDF Golden Vectors, KDF Verification,
Attestation Vectors, Attestation Protocol, Security-Property Regression,
Cross-Module Regression).

**Two open issues in Lane B:**
1. `rtl/keccak/keccak_f1600.sv` and `rtl/keccak/tb_keccak_f1600.sv` are **0 bytes**.
   Nothing instantiates a `keccak_f1600` module — only `keccak_f1600_core`.
   Dead placeholders; delete them or fill them.
2. `tb_sha3_256_core.sv` contains **no `$fopen` / `$fscanf` / `$readmemh`**. The
   RTL is checked against expectations hardcoded in the TB, NOT against the
   Python golden vectors. The stated purpose of `kdf_vectors.txt` was for a
   hardware TB to read it with `$fscanf()`. That link does not exist yet, so the
   Python reference and the RTL are not actually cross-checked.

---

## Lane A detailed state

### `noc_pkg` (M1) — the frozen single source of truth

Facts I need you to use rather than re-derive:

- `FLIT_WIDTH = 32`, `NUM_VC = 3`, `MESH_X=3`, `MESH_Y=2`, `NUM_TILES=6`,
  `NUM_PORTS=5`
- `flit_t = { logic [31:0] flit_data; flit_type_e flit_type; logic [1:0] vc_id; }`
  — **no valid bit** (contract L-05)
- `flit_type_e = { FLIT_HEAD, FLIT_BODY, FLIT_TAIL, FLIT_HEAD_TAIL }` — note
  **HEAD_TAIL, not SINGLE**
- `vc_e = { VC_REQUEST, VC_RESPONSE, VC_ATTESTATION }`
- `msg_type_e` (4 bits) = MSG_MEM_RD_REQ, MSG_MEM_RD_RESP, MSG_MEM_WR_REQ,
  MSG_MEM_WR_RESP, MSG_ATTEST_CHALLENGE, MSG_ATTEST_RESPONSE, MSG_ATTEST_GRANT,
  MSG_ATTEST_REVOKE
- `tile_id_e` = TILE_CPU0(0,0) TILE_CPU1(1,0) TILE_MEMORY(2,0) TILE_CRYPTO(0,1)
  **TILE_ROT(1,1)** TILE_SPOOF(2,1)
- `head_flit_t` is **exactly 32 bits, no spare**:
  `dest_x[2:0] dest_y[2:0] src_x[2:0] src_y[2:0] msg_type[3:0] length[4:0] control[10:0]`
  `control` is a packed union: `raw[10:0]`, `mem_wr{wstrb[3:0],unused[6:0]}`,
  `mem_resp{err,unused[9:0]}`, `attest{status[3:0],unused[6:0]}`
- Helpers: `tile_to_coord`, `coord_to_tile`, `valid_coord`,
  `address_to_coord_safe`, `message_to_vc`, `message_payload_flits`,
  `message_length`, `opposite_port`, `port_exists`, `input_vc_port`,
  `make_input_vc`
- `addr_decode_t = { logic valid; coord_t coord; }`
- MAC: **trailing flits, never header bits** (L-09). `MAC_ENABLE = 0` in the
  baseline build, `MAC_TAG_BITS = 128`, `MAC_FLITS_FULL = 4`, `MAC_FLITS = 0`
  while disabled.
- Payload flit counts: RD_REQ 1, RD_RESP 1, WR_REQ 2, WR_RESP 0,
  ATTEST_CHALLENGE 5, ATTEST_RESPONSE 16, GRANT 0, REVOKE 0.
  `message_length = 1 + payload + MAC_FLITS`.
- Memory map: local IMEM 0x0000_0000, DMEM 0x0000_4000, UART 0x1000_0000,
  GPIO 0x1000_1000, STATUS 0x1000_2000, NI 0x1000_3000; remote 0x2T00_0000 with
  T = addr[27:24], T=6..15 → bus error.
- **Deadlock note L-11:** VC2 carries both attestation challenges AND responses,
  which reintroduces a dependency cycle. The invariant that makes it safe is
  that the RoT issues **at most one outstanding challenge mesh-wide**. Enforced
  in the RoT, not in the package. Concurrent attestation would require a 4th VC.

### M10 `noc_network_interface` — current status

Originally written (by an earlier session of yours) against a **package API that
does not exist** — `TILE_ID_W`, `pkt_class_e`, `NONCE_W`, `KEY_EPOCH_W`, `LEN_W`,
`FLIT_DATA_W`, `MAC_TAG_W`, `noc_header_t`, `FLIT_SINGLE`, `flit_t.ftype`,
`pack_tail`/`unpack_tail`. xvlog rejected all of it. It was fully rewritten
against the real `noc_pkg`. Module renamed `noc_ni` → `noc_network_interface`.

Design decisions baked in, with reasons:
- **D.10:** `src_x`/`src_y` come from the `LOCAL_TILE_ID` parameter, never from
  the tile. There is deliberately no `tx_src_*` port. A tile that can set its own
  source coordinate can impersonate any other tile.
- **Parse before authenticate:** RX does NOT trust `head.length`. It recomputes
  the payload count from `msg_type` and flags mismatch on `rx_length_error`.
- **Protocol errors are drops, not stalls:** an unexpected flit is consumed and
  discarded with `rx_protocol_error` pulsed. Refusing it would back-pressure the
  router forever — that would turn a spoofed flit into failure mode F1.
- Exports `tx_busy` / `rx_busy` status outputs so the TB is fully black-box.
  (Vivado will NOT resolve a hierarchical reference to an enum *label* declared
  inside a module, e.g. `dut.TX_IDLE` — that was a real compile error.)
- `head_flit_t'(x).src_x` is **rejected by xvlog** — a member select cannot be
  applied to a cast expression. The cast must land in a named signal first
  (`tx_head_on_wire`).

### The M10 shape-check patch — STATUS UNKNOWN, PLEASE CONFIRM

The testbench found a real gap: M10 accepted a `FLIT_HEAD_TAIL` for a message
type that owes payload flits (e.g. `MSG_MEM_RD_RESP`), handing the tile a
"complete" packet with `rx_payload_last` asserted and no data behind it. A spoof
tile sends one flit and CPU0 believes it got a memory response.

A 5-hunk patch was given to me in chat adding `rx_head_shape_ok`:

```systemverilog
assign rx_head_shape_ok =
    rx_is_head_tail ? ((rx_head_payload_n == 5'd0) && (MAC_FLITS == 0))
                    : ((rx_head_payload_n != 5'd0) || (MAC_FLITS != 0));
```

gating three places that `rx_head_for_us` already gates (RX output block, RX
next-state, RX register latch), plus the declaration and the removal of a now-
unreachable `else rx_state_d = RX_IDLE`.

**Last known sim result: 143 checks, 4 errors — all four in T14, which is exactly
the patch's test.** I do not know whether I applied the patch afterwards. Ask me.

### `ni_tb.sv` (module `tb_noc_ni`) — T01..T14 + SVA

Coverage: reset/idle, single-flit TX, multi-flit TX, TX back-pressure, illegal
destination, message→VC over all 8 types, single-flit RX metadata, multi-flit RX,
RX back-pressure, back-to-back RX, stray BODY, misrouted packet, lying length
field, malformed packet shape. ~143 checks.

**The one rule this TB lives or dies by** — do not let anyone remove it:

```
Drive at the negedge. Wait TSETTLE (1 ns). Sample. Release after the posedge
that consumes the transfer.
```

Without the settle, a blocking assignment followed by an immediate read of a DUT
output reads the value from *before* the DUT's `always_comb` re-ran, the TB
concludes the transfer hasn't happened, waits a cycle, and by then the transfer
is a flit in the past. That produced a bogus `T03 payload0 : flit_type` failure
and a watchdog hang. Also: `{string_var, "literal"}` concatenation and enum
`.name()` were both replaced (xvlog/editor issues), and `chk` prints `[PASS]`
for every check by my preference.

### M10 is NOT complete against its own exit criteria

`NOC_WORKSTREAM.md` Phase 5 requires M10 to do:

| Responsibility | Status |
|---|---|
| Packetization / depacketization | done |
| VC selection | done |
| **Destination extraction — via M11** | missing |
| **Local vs remote decode — via M11** | missing |
| **Outstanding transaction tracking, bounded by N_OUTSTANDING (C5)** | missing |
| **Response matching / reordering** | missing |

Exit criterion: *"`tb_noc_ni` covers local read/write, remote read/write,
response return, back-to-back requests, and N_OUTSTANDING simultaneous
transactions with correct matching."* — none of those five are covered yet.
So "M10 143/143" means the packetizer passes its own tests, not that M10 is done.

### M11 `noc_addr_decoder` — designed, not yet in the project

Purely combinational. No clock, no reset, no FSM, no handshake. Ports:

```systemverilog
module noc_addr_decoder #(
    parameter int          LOCAL_TILE_ID = 0,
    parameter logic [31:0] IMEM_SIZE     = noc_pkg::LOCAL_IMEM_SIZE,
    parameter logic [31:0] DMEM_SIZE     = noc_pkg::LOCAL_DMEM_SIZE,
    parameter logic [31:0] PERIPH_SIZE   = noc_pkg::LOCAL_PERIPH_SIZE,
    parameter bit          SELF_REMOTE_IS_ERROR = 1'b1
) (
    input  logic [31:0]            addr,
    input  logic                   addr_valid,
    output logic                   is_local,
    output noc_pkg::local_target_e local_sel,
    output noc_pkg::addr_decode_t  remote,
    output logic                   bus_error
);
```

Contract: when `addr_valid` is high, **exactly one** of
`{is_local, remote.valid, bus_error}` is high. Wraps
`noc_pkg::address_to_coord_safe()` rather than re-implementing O-01. Has
elaboration-time region-overlap checks because the if/else chain is a priority
encoder and an overlap would resolve silently.

**Requires a ~20-line addition to `noc_pkg` (section 15b)**: `LOCAL_IMEM_SIZE`
(0x4000, derived), `LOCAL_DMEM_SIZE` (0x4000, a CHOICE), `LOCAL_PERIPH_SIZE`
(0x1000, derived), and `local_target_e { LOCAL_NONE, LOCAL_IMEM, LOCAL_DMEM,
LOCAL_UART, LOCAL_GPIO, LOCAL_STATUS, LOCAL_NI }`. The enum cannot live inside
the module — a type used in a port declaration must come from a package.

**Three decisions still open on M11:**
1. `DMEM_SIZE` — 16 KB proposed (4 × RAMB36 per memory). Not frozen.
2. Self-addressed remote access (a tile's own T value in the remote region) —
   proposed as `bus_error`. Not decided.
3. Whether to edit `noc_pkg` at all vs. a separate `noc_addr_pkg`.

### Transaction tagging — DECIDED

`N_OUTSTANDING = 2` (recommended by `PLAN_COMPLIANCE_AUDIT.md`; it is listed
there as **MISSING from `noc_pkg`**, one of only two genuinely open items along
with O-03).

Chosen approach: **Option 5 — M10 allocates the slot and the slot index IS the
tag.** The CPU never generates or sees a tag. `TXN_TAG_WIDTH = $clog2(2) = 1`.

**Tag location: `control[0]`.** Derivation: the tag must be free in the request
overlay *and* the response overlay. `mem_wr` uses `control[10:7]` (wstrb),
`mem_resp` uses `control[10]` (err), `attest` uses `control[10:7]` (status). The
intersection of free bits is `control[6:0]`, bounded by `mem_wr`. So the tag goes
at the LSB end, inside the existing `unused` fields — **no head-flit format
change, no M1 re-verification**. Headroom is 7 bits = 128 outstanding.

Two contracts this creates:
- The **responder** must echo the request's tag into the response's
  `control.mem_resp.tag`. That is an obligation on the far-end tile, not on the
  requester's M10, and it needs writing into the workstream.
- Tag matching is **spoofable until M13** — `TILE_SPOOF` can forge a
  `MSG_MEM_RD_RESP` with any tag. Free mitigation now: M10 must check the
  response's `src` coordinate equals the destination the request in that slot
  was sent to. One comparator against a field already stored.

---

## Other open items logged but not closed

- M10 **never checks `noc_rx_flit.vc_id` on RX**. It assumes the router never
  interleaves packets at the LOCAL output. That is an M8 property M10 does not
  verify; if the allocator ever grants mid-packet, M10 silently splices two
  packets together. Belongs in `VERIFICATION_LOG.md` whether or not it's fixed.
  Cheap fix: latch the head's `vc_id`, require payload flits to match.
- `rx_protocol_error` is **one bit for four distinct causes** (misrouted, stray
  body, bad shape, wrong VC). The paper needs per-cause counts. A 2–3 bit
  `rx_err_code` costs nothing and saves re-instrumenting later.
- `noc_tx_ready` timing: the incoming flit's `flit_data` feeds combinationally
  back to the upstream ready via the `message_payload_flits` decode. Fine on
  A7-100T today; measure it after full-mesh synthesis. If it becomes critical
  path, register the head decode — do not remove the check.
- P10 threat model still not written. The 64-bit-vs-128-bit MAC truncation and
  several "is this an attack or a bug" calls all depend on it.

---

## How I want you to work

- **Never write into `C:\vivado_verilog_proj\NOC_PQATTEST` without asking me
  first.** Give me code in chat; I paste it myself.
- Read the actual files before asserting what they contain. Three separate times
  we burned cycles because code was written against an imagined API or a guessed
  error instead of the real one.
- A red underline in the Vivado editor is **not** an xvlog error — the editor
  runs a weaker parser. Ask me for the `[VRFC …]` line and its line number.
- When you can't verify something (no simulator in your sandbox), say so plainly
  rather than implying it's tested.
- Tell me when a plan is wrong, including when another tool produced it.

---

## What I need from you now

1. Confirm what you understand of the above and flag anything that looks stale.
2. Ask me: did I apply the M10 5-hunk shape patch, and what does the sim say now?
3. Then we pick up at: freeze `N_OUTSTANDING` + section 15b in `noc_pkg` →
   M11 RTL + `tb_noc_addr_decoder` → M10 outstanding-table and response matching
   → extend `tb_noc_ni` to the real Phase 5 exit criteria.

Also note: I worked with a different agent while you were unavailable, so some
of the above may have moved. Ask me what changed rather than assuming.
