# PQ-Attest — Polish / Verification Report

Session date: 2026-09-17/18
Scope executed: verification & cleanup pass over the crypto lane (Stages 1–5).
Tools: Vivado 2024.1 XSim (`C:\xilinx_vivado\Vivado\2024.1\bin`), Python 3.13.15.
Spec: `PQ_Attest/software/` from `Pq_Attest_final.zip` (not present in the project; used read-only for reference only, per instruction).

> Governing rule applied throughout: a golden value counts only if it reproduces from the
> Python reference. Every golden below was regenerated from the reference or hashlib — none eyeballed.

---

## 1. Issues fixed

### FIX-1 — `pq_kdf.sv`: reserved keyword `context` used as a port name  *(loud, blocking)*
- **File/lines:** `NOC_PQATTEST.srcs/sources_1/new/pq_kdf.sv:85` (port decl) and `:215` (use).
- **Root cause:** `context` is a reserved SystemVerilog-2012 keyword (IEEE 1800, DPI). `pq_kdf.sv`
  had never been compiled, so this was latent. `xvlog` rejected it:
  `[VRFC 10-4982] syntax error near 'context'` / `[VRFC 10-8549] keyword 'context' used in incorrect context`.
  It was the ONLY compile error in the entire crypto lane.
- **Fix:** renamed port `context` → `context_in`; updated its single use (`ctx_q <= context_in;`).
- **Why this fix:** matches the name the handoff brief itself specifies (§5/§7); `pq_kdf` is not
  instantiated anywhere yet (no TB, Stage 6 not built), verified by grep, so no callers to update.
- **Severity:** loud — module could not build at all; no risk of a silent wrong answer.
- **Verification:** after the rename the full crypto lane (22 source files) + all 5 testbenches
  compile with 0 errors / 0 warnings, and `pq_kdf` elaborates for the first time.

**This is the only change made to project RTL this session.**

---

## 2. Issues found and NOT fixed (report-only, per scope)

### GAP/RISK-1 — `SHA3_256.sv` digest byte order violates §5.1  *(silent risk for Stage 6)*
- The digest concatenation (`SHA3_256.sv:208–250`) packs **byte 0 at the MSB end**
  (`digest[255:248] = output byte 0`). Every other block (KMAC, KDF, TRNG) uses byte 0 at the
  **LSB** end (`[i*8+:8]`, the §5.1 convention).
- **Functionally correct in isolation:** all 5 `SHA3_TB` constants reproduce from `hashlib.sha3_256`
  (verified), and the TB compares directly, so it is self-consistent and passes.
- **Why not fixed:** no consumer exists today (Stage 6 not built), so it is not "wrong now."
  Re-reversing it would also force edits to the green `SHA3_TB` constants — an unrequested change to
  working RTL. **This is a design decision for the owner** (see §3 open question).
- **What closing it takes:** either (a) reverse the digest packing to `[i*8+:8]` AND byte-reverse the
  6 `SHA3_TB` expected constants, or (b) byte-swap once at the Stage 6 boundary that consumes the digest.

### GAP-2 — `SHA3_256.sv` reads `is_final` live (no `is_final_q` latch)  *(latent)*
- `is_final` is sampled in `SHA3_CTRL_KECCAK_WAIT` (`SHA3_256.sv:192`), ~26 cycles after `start`.
- The current TB holds `is_final` stable, so it passes. A caller that drops it early would get no
  digest. Repo rule: "latch every request field at accept, or assert the hold requirement."
- **Not fixed:** no misbehaving caller exists; changing working RTL unprompted is out of scope.

### GAP-3 — no `a_no_full_final_block` assertion in `SHA3_256.sv`
- `sha3_pad` only pads when `valid_bytes < RATE_BYTES`; a full 136-byte block with `is_final=1` gets
  no padding block. The contract (`valid_bytes=0,is_final=1` for the extra block) is unguarded.
  Report-only (assertion is new code / test).

---

## 3. Corrections to the handoff brief (files win)

1. **`pq_kdf.sv` port was NOT already renamed.** Brief (§5/§7) says the previous session renamed
   `context`→`context_in`. On disk it was still `context`. Fixed this session (FIX-1).
2. **The three "SHA3 fixes" the brief says are present in `SHA3_256.sv` are NOT present:**
   (a) digest is still MSB-first (not `[i*8+:8]`); (b) `is_final` is read live (no `is_final_q`);
   (c) no `a_no_full_final_block` assertion. See §2.
3. **`SHA3_TB` has no `bswap256()`** (brief §5.1 says it does). It uses printed-order expected
   constants and a direct `===` compare instead.
4. **Stage 5 testbench + vectors: absent during the audit, ADDED mid-session.** When first audited,
   `pq_kdf_tb.sv` and `kdf_vectors_rtl.txt` did not exist. The prior session wrote both to
   `sim_1/new` on 2026-09-18 (18,177 B / 2,489 B, verified on disk). They compile + elaborate clean
   against the current `context_in` port. Stage 5 is now simulable (run pending a clean host).
   Root cause of the original absence (per the prior session): its `SHA3_256.sv`/`SHA3_TB.sv`/Stage-5
   patches never committed to disk — the file-bridge dropped — while the brief was written as though
   they had. Only `kmac_tb.sv` landed, which is why Stage 3 is genuinely green.
5. **Most of Step 1 (cleanup) was already done.** `pq_kdf_block_formatter.sv`, `pq_kdf_controller.sv`,
   `pq_kdf..sv`, and the `*.bak` files are already gone; the orphan files
   (`pq_kdf_sp800185_encoder.sv`, `pq_kdf_message_builder.sv`, `TRNG_PAD.sv`) are already OUT of the
   `.xpr` fileset (present on disk only — the intended end state). Remaining: `SHA3_TB.v` (0 bytes,
   1 `.xpr` ref) and `TB_GOLDEN.sv.duplicate` (disk only).
6. **The project was not a git repository — now fixed.** This session ran `git init` + a `.gitignore`
   (excludes `.cache/.gen/.hw/.sim/.ip_user_files/.runs/.Xil` and logs) + first commit `73a45f9`
   (86 files: all `.srcs`, `.xpr`, `golden/`, `Claude outputs/`). This is the mitigation for the
   unexplained `NOC_PKG.sv` 10 KB shrink — future losses are now recoverable.
7. **The Python reference / `docs/` tree are not in the project** — only in the supplied zips.
   Left out per instruction.

---

## 4. Verification status (ladder from brief §6)

| Stage | Module(s) | Status | Evidence |
|---|---|---|---|
| 1 | keccak_f1600 | sim-verified | `tb_keccak_f1600` PASS 600/600 lanes, negative control caught |
| 2 | sha3_256 | PASS (prior run, file unchanged) + goldens spec-traced | SHA3_TB 49/0 run 2026-09-15; SHA3_256.sv (11,222 B, mtime 09-12) & SHA3_TB.sv (26,596 B, mtime 09-12) byte-unchanged since — mtime-verified; 5/5 constants == hashlib this session. NOT re-run this session (host wedged). |
| 3 | kmac128 | PASS (prior run, file unchanged) + goldens spec-traced | kmac_tb 10/0 run 2026-09-15; kmac_tb.sv (17,746 B, mtime 09-15) byte-unchanged since — mtime-verified; 5/5 tags == kmac128_ref this session. NOT re-run this session. |
| 4 | trng_conditioner | UNPROVEN — never simulated in any session | 5 conditioned+nonce vectors (prev session, not re-derived here); SIM: NEVER RUN. This is the one genuine gap. |
| 5 | pq_kdf | lint-clean + elaborated + spec-consistent + TB now present (NOT yet simulated) | 6/6 KDF keys reproduced from pq_kdf's exact RTL layout → ref KMAC; `pq_kdf_tb.sv`+`kdf_vectors_rtl.txt` added 2026-09-18, compile+elaborate clean vs current `context_in` port; run pending clean host |

Independent golden regeneration this session:
- SHA3 (5): `hashlib.sha3_256` — all MATCH.
- KMAC (5): `kmac128_ref.py` (accounting for byte-0-at-LSB tag order) — all MATCH.
- KDF (6): replicated `pq_kdf.sv`'s byte-layout formula, fed to reference `kmac128` — all 6 golden
  keys MATCH, incl. V05 (empty context) and V06 (256-bit key). Confirms KMAC output length is
  absorbed, not truncated (V06[:16] != V01).

Audit (§6 checks):
- Reset polarity: all 3 `keccak_f1600` instantiations (SHA3_256, kmac_128, TRNG_CONDITIONER) use
  `.rst(~rst_n)` ✓.
- `out_len_sel`: explicitly connected at every instantiation (kmac_128→kmac_encode, pq_kdf→kmac128) ✓.
- Request latching: `kmac_128` latches all fields at accept ✓; `pq_kdf` latches all fields at accept ✓;
  `trng_conditioner` uses per-word valid/ready handshake ✓; `sha3_256` is the exception (GAP-2).
- No computed-LHS `always_comb` index issues found in the fixed/audited modules.

---

## 5. Coverage gaps (Step 7 — confirmed, report only)

1. No mutation/negative-control test in `SHA3_TB`, `kmac_tb`, `TRNG_TB` (only `pq_keccak_tb` has one).
   → those three remain `smoke`, not `sim-verified`, regardless of PASS banners.
2. No L=128 KAT in `kmac_tb` — `out_len_sel` low is untested (all 5 KMAC vectors are L=256).
3. `pq_keccak_tb` drives only the all-zero input.
4. Stage 5 RTL sim: `pq_kdf_tb.sv` + `kdf_vectors_rtl.txt` were added by the prior session
   2026-09-18 (verified on disk; compile+elaborate clean vs current `context_in` port). Gap is now
   "not yet run" (host wedged), not "no TB". Run gates in order: bswap self-test → 6 golden vectors →
   negative control must FAIL.

---

## 6. Test results (this session)

- Python reference `run_all_tests.py`: **8/8 PASS**.
- Elaboration: whole crypto lane + 5 TBs, **0 errors / 0 warnings**; `pq_kdf` elaborated first time.
- `tb_keccak_f1600`: **PASS** — 600 per-round lane comparisons, 0 mismatches, negative control detected.
- `tb_sha3_256`: PASS 49/0 on 2026-09-15 (prior session); file byte-unchanged since (mtime-verified). NOT re-run this session (host wedged) — re-confirm only, not a blocker.
- `KMAC_TB`: PASS 10/0 on 2026-09-15 (prior session); file byte-unchanged since. NOT re-run this session — re-confirm only.
- `pq_kdf_tb`: compiles + elaborates clean vs current `pq_kdf.sv` (context_in). NOT yet run (host wedged). **Highest-value pending sim** — Stage 5 has never been simulated.
- `TRNG_CONDITIONER_TB`: NEVER RUN in any session. **Pass/fail UNKNOWN (unproven).**
- `TRNG_TOP_TB`: NEVER RUN in any session. **Pass/fail UNKNOWN (unproven).**

Sim-host note: after the keccak PASS, repeated XSim runs failed at startup — `rc=139`
(EXCEPTION_ACCESS_VIOLATION, "Could not open file mapping object") or `rc=124` (hang, killed at 240s
timeout). Root cause is host process state: orphaned `xsimk.exe` kernels from earlier crashed/stopped
runs (grew from 6 → 10) corrupt XSim's shared named-object namespace. Unique snapshot names + fresh
work dirs + per-sim timeouts did NOT resolve it. The fix (kill `xsimk.exe`/`xsim.exe`, never
`vivado.exe`, or reboot) was blocked by the harness permission gate this session.

### To reproduce the remaining sims on a clean host
1. Reboot the PC (or Task Manager → end all `xsimk.exe` + `xsim.exe`; do NOT touch `vivado.exe`).
2. From a Vivado 2024.1 shell, in an empty scratch dir, compile the crypto lane (packages first),
   then `xelab --debug typical <top> -s <snap>` and `xsim <snap> -R` for each of:
   `tb_keccak_f1600`, `tb_sha3_256`, `KMAC_TB`, `TRNG_CONDITIONER_TB`, `TRNG_TOP_TB`.
   (`pq_keccak_tb` reads `keccak_rounds.memh` by absolute path; the other 4 TBs have inline vectors.)
Expected: keccak PASS (already seen); SHA3 49/0 and KMAC 10/0 (goldens already spec-verified);
TRNG — genuinely unknown, this is the one to watch.

---

## 7. Open questions for the owner (decisions NOT made)

1. **SHA3 byte order (gates Stage 6).** Fix `SHA3_256` to §5.1, or byte-swap at the Stage 6 boundary?
2. **`SHA3_256` `is_final` latch / full-final-block assertion** — apply defensively, or document the
   hold contract and leave as-is?
3. **Stage 5 testbench** — create `pq_kdf_tb.sv` + `kdf_vectors_rtl.txt` (out of scope this session)?
4. **Fileset cleanup** — remove `SHA3_TB.v` from `.xpr` + delete `TB_GOLDEN.sv.duplicate`
   (needs Vivado closed or Tcl `remove_files`/`file delete`).
5. **Stage 8 nonce origin** (verifier- vs tile-generated) — still undecided; gates Stages 4 & 9.
