# PQ-Attest — progress handoff, both lanes

**As of 2026-09-18.** Supersedes `PQ_ATTEST_STATE_2026-09-18.md`, which covered the
crypto lane only. Written for whichever model picks this up next.

Grounded in disk reads and this session's real compile/elaborate runs. **Where this
file and the files disagree, the files win** — correct this file and say so.

---

## 1. State in one paragraph

Both lanes now compile and elaborate clean. The **crypto lane** (Stages 1–5) has
Stage 1 sim-verified and Stages 2–3 passing with every golden independently re-derived
from the Python reference; **Stages 4 and 5 are unproven** — neither has ever been
simulated. The **NoC lane** (M1–M11, Phases 1–5) is architecturally aligned with the
frozen roadmap on every checked parameter, statically audited on its three
correctness-critical invariants, and was **not functionally simulated this session** —
its functional numbers are prior-run provenance. Everything is blocked on one thing:
the XSim host is wedged and needs a reboot. Two design questions are open.

---

## 2. Changes made — all on disk, all committed

| # | Change | File | Why | Verified |
|---|---|---|---|---|
| 1 | port `context` → `context_in` | `sources_1/new/pq_kdf.sv` | `context` is a reserved SV keyword (IEEE 1800 Table B.1, DPI). **Only compile error in the crypto lane.** Latent because the file had never been compiled. | Whole crypto lane + 5 TBs compile clean; `pq_kdf` elaborated for the first time |
| 2 | connect `out_len_sel`, default `KMAC_L_256` in `clear_inputs()` | `sim_1/new/kmac_tb.sv` | TB still used the old port list after `out_len_sel` was added → floated → every KAT absorbed the wrong message | `kmac_tb` 3/7 → **10/10** |
| 3 | **new** `pq_kdf_tb.sv` (18,177 B) + `kdf_vectors_rtl.txt` (2,489 B) | `sim_1/new/` | Stage 5 had no testbench and no vectors on disk | Elaborates clean against `context_in`. **Never run.** |
| 4 | relocated coverage `always` block below all declarations | `sim_1/new/TB1.sv` (`tb_noc_stage2`) | `xb_sel`/`xy_valid` used before declaration → `[VRFC 10-3380]`. TB1 is in the `.xpr` fileset, so the Phase-2 NoC TB could not compile. | NoC lane + all NoC TBs **0 errors** (was 2); `tb_noc_stage2` elaborates |
| 5 | `git init` + `.gitignore` + reports | repo root, `Claude outputs/` | No version control — the root cause of the unrecoverable `NOC_PKG.sv` loss | 86 files tracked, build dirs excluded |

**Commits:** `73a45f9` initial → `b75a867` crypto report → `36d8fdc` NoC cross-check →
`4e7b0f9` TB1 fix → `f6ad8c2` N-1 marked fixed.

**Reports:** `Claude outputs/POLISH_REPORT.md` (crypto), `Claude outputs/NOC_CROSSCHECK.md` (NoC).

**Untouched:** `SHA3_256.sv`, `SHA3_TB.sv`, the `.xpr` fileset, all NoC RTL.

---

## 3. Verification status — use these words, not the testbench banners

Ladder: `unwritten → lint-clean → smoke → sim-verified → formally-proven → hw-validated`

`sim-verified` requires **all three**: independent golden model, stated stimulus
strategy, mutation testing proving the TB can fail. A "STAGE N PASS" banner is not a
status. **Do not upgrade anything without a run behind it.**

### Crypto lane

| Stage | Module | Status | Evidence |
|---|---|---|---|
| 1 | `keccak_f1600` + 5 steps | **sim-verified** | 600/600 per-round lanes vs `keccak_ref.py`; negative control caught an injected 1-bit flip; `f1600(0)[0][0] = f1258f7940e1dde7` (FIPS 202) |
| 2 | `sha3_256` | **smoke** | 5/5 goldens = `hashlib.sha3_256`; sim 49/0 on 2026-09-15, file byte-unchanged (11,222 B). No mutation test. |
| 3 | `kmac128` | **smoke** | 5/5 tags = `kmac128_ref.py`; reference reproduces the NIST SP 800-185 KAT; sim 10/0 on 2026-09-15, file unchanged. No mutation test, **no L=128 KAT**. |
| 4 | `trng_conditioner` | **UNPROVEN** | 5 conditioned outputs + nonces = `trng_conditioning_ref.py`. **Never simulated, in any session.** |
| 5 | `pq_kdf` | **lint-clean + elaborated** | All 6 KDF keys reproduce when `pq_kdf`'s exact byte layout is fed to the reference KMAC. TB elaborates. **Never simulated.** |
| 6+ | — | not started | Kalash's own work |

A static proof of a message layout is **not** a proof of RTL.

### NoC lane (Phases 1–5 / M1–M11)

| Module | Status | Evidence |
|---|---|---|
| M1 `noc_pkg` | **aligned + lint-clean** | Every frozen-roadmap parameter matched exactly (see §4) |
| M2 `noc_fifo` / M3 `noc_crossbar` / M4 datapath | **lint-clean** | Compile + elaborate; 15 FIFOs (5 ports × 3 VC) structurally correct. Deep functional re-verify needs sim. |
| M5 `noc_xy_routing` | **lint-clean + statically audited** | X-before-Y dimension order; malformed dest → `route_valid=0` + port forced LOCAL; `port_exists()` guard; embedded contract assertions; documented delta-cycle-race fix |
| M6 `NOC_ARBITER` | **lint-clean** (prior-run provenance) | Roadmap records 491,520 vectors / 0 mismatch. **Not re-run.** |
| M7 `NOC_ALLOCATOR` | **lint-clean + statically audited** | Wormhole reservation FSM: HEAD acquires+locks, BODY retains on owner-match, TAIL releases on owner-match, HEAD_TAIL no-op, illegal encoding holds state; A10 trap present. **See N-2.** |
| M8 `noc_router` | **lint-clean + statically audited** | CONTRACT L-07 (`xbar_sel` hold during stall) implemented with output qualification. **See N-2.** |
| M9 `noc_credit_control` | **lint-clean, NOT integrated** | Standalone verification recorded in roadmap. Not wired into `noc_router`. **See N-2.** |
| M10 `noc_network_interface` | **lint-clean** (prior-run provenance) | Roadmap records 159 checks / 0 errors. **Not re-run.** |
| M11 `noc_addr_decoder` | **lint-clean** (prior-run provenance) | Roadmap records 36 checks incl. self-remote and illegal-tile rejection. **Not re-run.** |

**Nothing in the NoC lane was functionally simulated this session.** Every functional
number above is a prior run, recorded in the roadmap. Treat it as provenance, not as
evidence you produced.

---

## 4. NoC architecture alignment — verified against the frozen roadmap

| Frozen spec | `noc_pkg` | |
|---|---|---|
| 3×2 mesh, 6 tiles | `MESH_X=3, MESH_Y=2, NUM_TILES=6` | ✅ |
| 5 ports N/S/E/W/LOCAL | `NUM_PORTS=5`; `port_e` NORTH0/SOUTH1/EAST2/WEST3/LOCAL4 | ✅ |
| 3 VCs Req/Resp/Attest | `NUM_VC=3`; `vc_e` REQUEST0/RESPONSE1/ATTESTATION2 | ✅ |
| 32-bit flit / 36-bit stored | `FLIT_WIDTH=32`; `flit_t` = 32 + 2(type) + 2(vc) = 36 | ✅ |
| FIFO depth 4 | `FIFO_DEPTH = VC0/1/2_DEPTH = 4` | ✅ |
| `N_OUTSTANDING=2` (C5) | `N_OUTSTANDING=2` | ✅ |
| `addr[27:24]` = tile sel (O-01/L-03) | `TILE_SEL_MSB=27, LSB=24` | ✅ |
| Tile→coord map | CPU0(0,0) CPU1(1,0) MEMORY(2,0) CRYPTO(0,1) RoT(1,1) SPOOF(2,1) | ✅ exact |
| MAC 128b = 4 flits, off till Ph9 | `MAC_TAG_BITS=128, MAC_FLITS_FULL=4, MAC_ENABLE=0` | ✅ |
| Packet length table (O-02) | `message_payload_flits()`: RD_REQ1 / RD_RESP1 / WR_REQ2 / WR_RESP0 / CHAL5 / RESP16 | ✅ |

Internal consistency holds: `ATTEST_CHALLENGE_WIDTH = 160 = 5×32` (payload 5 flits) and
`ATTEST_RESPONSE_WIDTH = 512 = 16×32` (payload 16 flits) — widths and flit counts agree.

---

## 5. Open questions RESOLVED this session

1. **`rx_head_shape_ok` (M10) — was the 5-hunk patch applied?** **YES.** 6 references
   present in `noc_network_interface.sv`. This had been open since the T14 failures.
2. **`NOC_PKG.sv` shrank 30,144 → 20,347 bytes — what was lost?** **Nothing currently
   referenced.** All modules compile clean against it; 64 declarations present. Treat
   as harmless. Git now protects the history from a silent repeat.
3. **No version control.** Closed — `git init`, 86 files, build dirs excluded.

---

## 6. Open decisions — Kalash's to make, NOT the model's

### D1 — SHA3 byte order (gates Stage 6, silent-corruption risk)

`SHA3_256.sv` packs digest byte 0 at the **MSB** end. `kmac128`, `trng_conditioner` and
`pq_kdf` all pack byte *i* at `[i*8 +: 8]` — byte 0 at the **LSB** end.

Stage 6 feeds the SHA3 digest into a KMAC message and `kmac128.msg_in` is LSB-first.
Get this wrong and every attestation tag is wrong **with every unit test still green**.

- **Option A (recommended):** reverse `SHA3_256.sv` to `[i*8 +: 8]`; add a `bswap256`
  adapter to `SHA3_TB` so the NIST literals stay readable. Zero consumers today →
  blast radius is exactly two files. Stage 6 *and* Stage 7 both read that digest.
- **Option B:** byte-swap at the Stage 6 boundary. Zero risk to Stage 2 today, but two
  conventions live in the repo permanently and it is already two swap sites.

**Apply only on a clean host, gated on `SHA3_TB` returning 49/0.**

### D2 — Phase 2.5 (area/timing probe) — genuinely open

Skipped by instruction. **No synthesis or implementation run exists for this project.**
There are therefore no Fmax, LUT/FF/BRAM or power numbers. Do not write one anywhere
until a run produces it. Label post-synth vs post-route; never present an FPGA
utilization figure as ASIC area.

### D3 — Stage 8 nonce origin (verifier-issued vs tile-generated)

Still undecided. Gates Stages 4 and 9 — it determines whether a real entropy source is
in scope at all. Do not build Stage 8 until Kalash decides.

---

## 7. Known issues, report-only — do NOT fix without being asked

### Crypto
- `sha3_256` reads `is_final` **live** in `KECCAK_WAIT` (~26 cycles after `start`),
  not latched at accept. A caller that drops it early gets no digest and no error.
- No assertion on `is_final && valid_bytes == RATE_BYTES`. `sha3_pad` only pads when
  `valid_bytes < RATE_BYTES`, so a **full final block silently gets no padding**.
  FIPS 202 requires an extra all-padding block; the contract is
  `valid_bytes=0, is_final=1`.

### NoC — N-2: credit flow control is NOT integrated at the router
Credit signals are left **unconnected on purpose** in `noc_router.sv` (lines 134–135),
and the allocator advances its reservation on **arbitration grant**
(`out_valid = arbiter grant_valid`) with **no credit input** — it sees only `fifo_empty`.

Consequence, stated plainly: the invariants *"reservation changes only on ACTUAL
TRANSFER"* and *"zero dropped flits under backpressure"* are **not yet enforced
end-to-end**. This is correct phase-staging — Phase 6 (two-tile integration) closes it,
and its exit criteria explicitly cover credit return, no drops, and backpressure.

**"Phase 4 ✅ DONE" is module-level only (M9 standalone). Do not read it as "the router
enforces credit today."**

### Coverage gaps — confirm, do not close
1. No mutation / negative-control test in `SHA3_TB`, `kmac_tb`, `TRNG_TB`.
   `pq_keccak_tb` has one — the pattern is there to copy. Until these exist, those
   three are `smoke` regardless of banners, and nobody can answer *"how do you know
   your testbench can fail?"*
2. No L=128 KAT in `kmac_tb` — all 5 vectors are L=256, so `out_len_sel` low is the
   path Stage 5 depends on most and has no known-answer test.
3. `pq_keccak_tb` drives only the all-zero input.
4. `pq_kdf_tb` covers context lengths {0, 13, 14} only.

---

## 8. THE BLOCKER

~13 orphaned `xsimk.exe` / `xsim.exe` kernels are holding wedged named shared-memory
objects. Every XSim run dies at startup with `rc=139` (EXCEPTION_ACCESS_VIOLATION,
*"Could not open file mapping object"*) or hangs to timeout.

Root cause confirmed: **host process state, not RTL.** Already ruled out — unique
snapshot names, fresh work dirs, per-sim timeouts, closing Vivado. Orphan count grew
6 → 13 across the session; they do not self-clear. `taskkill` is permission-blocked.

**Fix: reboot the PC.** Or Task Manager → end all `xsimk.exe` and `xsim.exe`; never
`vivado.exe`.

---

## 9. Next steps, in order

1. **Reboot.** Nothing below runs until this happens.
2. **`pq_kdf_tb`** — Stage 5's first simulation ever. Gates **in this order**:
   1. the `bswap` self-test passes — *until it does, no vector result means anything*
   2. all 6 golden vectors pass (V05 empty context and V06 256-bit key catch the
      classic errors)
   3. the negative control **FAILS** as designed
   4. `start`-while-busy is ignored

   If a vector fails, the fault is in `pq_kdf`'s message construction — Stage 3 is
   independently green, so KMAC is not the suspect.
3. **`TRNG_TB` and `TRNG_TOP_TB`** — the only genuinely unknown results in the project.
4. **`tb_noc_stage2` (TB1.sv)** — first run since the N-1 fix; confirm the relocated
   coverage block behaves identically.
5. **Re-run the NoC functional TBs** to convert prior-run provenance into evidence you
   produced: arbiter, M10 (159 checks), M11 (36 checks).
6. **Apply D1** (SHA3 byte order) and gate it on one `SHA3_TB` re-run.
7. Optional: re-run `SHA3_TB` / `kmac_tb`. The 2026-09-15 logs are valid for the
   current files.
8. Fileset cleanup still outstanding: `SHA3_TB.v` (0 bytes, 1 `.xpr` reference) and
   `TB_GOLDEN.sv.duplicate` (disk only). Needs Vivado closed, or Tcl `remove_files` +
   `file delete`.
9. **Stop. Hand back to Kalash. Do not start Stage 6 or NoC Phase 6.**

---

## 10. Traps — each cost real debugging time

**Conventions that produce silent wrong answers:**
- Byte order: byte *i* at `[i*8 +: 8]` everywhere **except** SHA3 (see D1).
- **Reset polarity is not uniform.** `keccak_f1600` is active-HIGH synchronous `rst`;
  everything else is active-low `rst_n`. Bridge with `.rst(~rst_n)`. All three current
  instantiations do this correctly — verify any new one.
- KMAC output length is **absorbed**, not truncated:
  `KMAC128(K,X,128) != KMAC128(K,X,256)[0:16]`. `out_len_sel` has **no default port
  value** on purpose; connect it explicitly, every time.
- `kmac_encode` owns `right_encode(L)` and the domain byte. Nothing else appends them.
- KDF customization is **empty**; context goes in the message. Stage 7 is the opposite.

**xvlog rejections:** `context` is reserved · no member select on a cast `t'(x).f` ·
no part-select on a function call `f(x)[7:0]` · no hierarchical ref to an enum label
`dut.STATE` · no `initial` in a `package` · no zero-width vectors ·
`{string_var, "lit"}` fails, use `$sformatf` · declarations must precede use in a
module (the TB1 defect).

**Testbench sampling:** drive at `negedge`, wait ~1 ns, sample, release after the
consuming `posedge`.

---

## 11. Errors previous sessions made — verify, do not trust

1. A Cowork session **claimed three SHA3 fixes and the `pq_kdf` rename were on disk.
   They were not.** The device bridge dropped mid-write, the commit failed, the files
   went out as chat attachments and were never saved. Only `kmac_tb.sv` landed.
2. Compounding it: a **49/0 `SHA3_TB` run was read as proof the patch was live.** It was
   not evidence either way — unpatched RTL with unpatched TB literals is self-consistent,
   and the patched pair would have been too. Both give 49/0.
3. An earlier session **invented an entire `noc_pkg` API** that did not exist.
4. An earlier session **judged the project by a stale zip** — claimed Stages 3/4 had no
   RTL and SHA3 was capped at 272 bytes. Both retracted.
5. A port list was changed **without grepping instantiations**, breaking `kmac_tb` to 3/7.

**Standing rules: read the file in the Vivado project, never a zip or a summary. Grep
every instantiation before changing a port list. When in doubt about scope, do less and
report more — an unrequested change to working RTL is worse than a gap left open,
because the gap is visible and the change is not.**

---

## 12. Scope

Crypto lane through Stage 5 and NoC Phases 1–5 are the completed work. **Stages 6+ and
NoC Phase 6+ are Kalash's own work — do not start, stub, or scaffold them.** Do not add
features, new testbenches, or new tests to existing testbenches without being asked.

A **defect** is something wrong now → fix it. A **gap** is something correct but
unproven → report it. If you cannot tell which, report it as an open question and change
nothing.
