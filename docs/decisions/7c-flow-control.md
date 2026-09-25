# 7c — Flow control at router boundaries (FROZEN 2026-09-23)

Decided by Claude at Kalash's delegation ("decide urself best for my proj").

## Decision
**Chose:** Option A.
- Router <-> router: **credit-based**, per VC (NUM_VC=3), credit = downstream FIFO depth (4).
- Router <-> LOCAL NI: **ready/valid**, both directions, one ready bit per direction.

**Over:**
- B: credits on all 5 ports (NI becomes a credit sender/receiver).
- C: ready/valid everywhere.

**Because (evidence from the tree, not preference):**
1. The NI (M10, `noc_network_interface.sv`) already speaks ready/valid on its NoC side:
   `noc_tx_valid/noc_tx_ready`, `noc_rx_valid/noc_rx_ready`, with its own stability
   SVA (`a_tx_valid_stable`, `a_tx_flit_stable`, :1131-1145). A needs **zero NI changes**.
   B would rewrite a module that already passed ni_tb / m11_tb and freeze NI buffer depth
   into the interface.
2. Router<->router credits are already implemented and pass: tb_noc_router_m9_credit
   30/0 (7981fa6), N-7 mesh 1761/0/0. C would discard verified work.
3. C puts a combinational ready path across every mesh link (router N's ready depends on
   router N+1's state), which lengthens inter-router timing paths. Credits register the
   return path. This matters at N-2.5/N-13.

**Costs:**
- Two protocols in one router: LOCAL output is qualified by `out_ready_local`, the four
  mesh outputs by credit counters. Asymmetry must be documented and tested.
- `noc_rx_ready` from the NI is **combinational on `noc_rx_valid` and `noc_rx_flit`**
  (NI :798-925). So the router MUST NOT make `out_valid_local`/`out_flit_local` depend on
  `out_ready_local`, or a combinational loop forms. Rule: valid from arbitration only;
  ready only gates commit (FIFO pop + allocator reservation via `transfer_valid[LOCAL]`).
- Single ready bit per direction (not per VC): a stalled VC at the NI blocks the LOCAL
  output for all VCs. Acceptable for one-tile-per-router; revisit if NI gets per-VC buffers.

**Revisit if:** the NI gains per-VC receive buffers, or N-2.5 shows the LOCAL ready path
on the critical path (then register it: skid buffer on LOCAL out).

## Interface contract this freezes (router side)
| Signal | Dir (router) | Meaning |
|---|---|---|
| `credit_return[p][vc]` | in | 1-cycle pulse, downstream freed one slot in VC `vc` of port `p` (mesh ports) |
| `credit_out_<p>[vc]` | out | router's own input FIFO of port p/VC popped this cycle (to upstream) — NEW, replaces TB hierarchical taps |
| `in_ready_local` | out | router LOCAL input FIFO for `in_flit_local.vc_id` not full — NEW, drives NI `noc_tx_ready` |
| `out_ready_local` | in | NI accepts `out_flit_local` this cycle — NEW, from NI `noc_rx_ready` |
| `out_valid_local` | out | must NOT depend on `out_ready_local`; held with stable flit until accepted (SVA) |

Transfer on LOCAL out = `out_valid_local && out_ready_local`. Transfer on LOCAL in =
`in_valid_local && in_ready_local`.
