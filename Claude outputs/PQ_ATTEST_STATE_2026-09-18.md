# PQ-Attest — state handoff

**As of 2026-09-18.** Written for whichever model picks this up next.
Verified against the actual disk at `C:\vivado_verilog_proj\NOC_PQATTEST`, not from
conversation memory. Where this file and the files disagree, **the files win.**

---

## 1. One-paragraph state

The crypto lane (Stages 1–5) compiles and elaborates clean for the first time. Stage 1
is genuinely sim-verified. Stages 2 and 3 pass with every golden value independently
re-derived from the Python reference. **Stages 4 and 5 are NOT proven** — Stage 4 has
never been simulated in any session, and Stage 5 has a testbench that elaborates but
has never been run. Everything is blocked on one thing: the XSim host is wedged with
~13 orphaned simulator processes and needs a reboot. One open design decision (SHA3
byte order) gates Stage 6.

---

## 2. Verification status — use these words, not the testbench banners

Ladder: `unwritten → lint-clean → smoke → sim-verified → formally-proven → hw-validated`
`sim-verified` requires **all three**: independent golden model, stated stimulus
strategy, mutation testing proving the TB can fail.

| Stage | Module | Status | Evidence |
|---|---|---|---|
| 1 | `keccak_f1600` + steps | **sim-verified** | 600/600 per-round lanes vs `keccak_ref.py`; negative control caught an injected 1-bit flip; `f1600(0)[0][0] = f1258f7940e1dde7` (FIPS 202) |
| 2 | `sha3_256` | **smoke** | 5/5 goldens = `hashlib.sha3_256`; sim 49/0 on 2026-09-15, file byte-unchanged since (11,222 B). No mutation test. |
| 3 | `kmac128` | **smoke** | 5/5 tags = `kmac128_ref.py`; reference reproduces the NIST SP 800-185 KAT; sim 10/0 on 2026-09-15, file unchanged (17,746 B). No mutation test, **no L=128 KAT**. |
| 4 | `trng_conditioner` | **UNPROVEN** | 5 conditioned outputs + nonces = `trng_conditioning_ref.py`. **Never simulated, in any session.** |
| 5 | `pq_kdf` | **lint-clean + elaborated** | All 6 KDF keys reproduce when `pq_kdf`'s exact byte layout is fed to the reference KMAC. TB elaborates clean. **Never simulated.** |
| 6+ | — | not started | Kalash is doing these himself |

**Do not upgrade any of these without a run behind it.** A static proof of a message
layout is not a proof of RTL.

---

## 3. What changed in the project, and by whom

| Change | Who | State |
|---|---|---|
| `pq_kdf.sv`: port `context` → `context_in` | Claude Code, 2026-09-18 | On disk, committed. `context` is a reserved SV keyword (IEEE 1800 Table B.1). This was the **only compile error in the whole lane**. |
| `kmac_tb.sv` (17,746 B): connect `out_len_sel`, default `KMAC_L_256` | Cowork session, 2026-09-15 | On disk. Fixed a 3/7 regression back to 10/10. |
| `pq_kdf_tb.sv` (18,177 B) + `kdf_vectors_rtl.txt` (2,489 B) | Cowork session, 2026-09-18 | On disk in `sim_1\new`. Elaborate clean against `context_in`. Never run. |
| `git init` + `.gitignore` + 2 commits (`73a45f9`, `b75a867`), 86 files | Claude Code, 2026-09-18 | Done. Build dirs excluded. |

**Nothing else has been modified.** `SHA3_256.sv`, `SHA3_TB.sv`, the `.xpr` fileset and
the entire NoC lane are untouched.

---

## 4. THE BLOCKER

~9 `xsimk.exe` + 4 `xsim.exe` orphaned kernels are holding wedged named shared-memory
objects. Every new XSim run dies at startup with `rc=139`
(EXCEPTION_ACCESS_VIOLATION, *"Could not open file mapping object"*) or hangs to timeout.

Root cause is confirmed and is **host process state, not RTL**. Already ruled out:
unique snapshot names, fresh work dirs, per-sim timeouts, closing Vivado. The orphan
count grew 6 → 13 across the session; they do not self-clear.

**Fix: reboot the PC.** Or Task Manager → end all `xsimk.exe` and `xsim.exe` — never
`vivado.exe`. Claude Code's `taskkill` is denied by its permission gate, so it cannot
do this itself.

---

## 5. Next steps, in order

1. **Reboot.** Nothing below can run until this happens.
2. **`pq_kdf_tb`** — Stage 5's first simulation ever. Gates **in this order**:
   1. the `bswap` self-test passes — *until it does, no vector result means anything*
   2. all 6 golden vectors pass (V05 empty context and V06 256-bit key are the ones
      that catch the classic errors)
   3. the negative control **FAILS** as designed
   4. `start`-while-busy is ignored

   If a vector fails, the fault is in `pq_kdf`'s message construction — Stage 3 is
   independently green, so KMAC is not the suspect.
3. **`TRNG_TB` and `TRNG_TOP_TB`** — the only genuinely unknown results in the project.
4. **Apply the SHA3 byte-order decision** (§6) and gate it on one `SHA3_TB` re-run.
5. Optional: re-run `SHA3_TB` / `kmac_tb` for fresh logs. The 2026-09-15 logs are valid
   for the current files.
6. Fileset cleanup still outstanding: `SHA3_TB.v` (0 bytes, 1 `.xpr` reference) and
   `TB_GOLDEN.sv.duplicate` (disk only). Needs Vivado closed, or Tcl
   `remove_files` + `file delete`.
7. Hand back to Kalash. **Do not start Stage 6.**

---

## 6. The open decision — SHA3 byte order (gates Stage 6)

`SHA3_256.sv` packs digest byte 0 at the **MSB** end. `kmac128`, `trng_conditioner`
and `pq_kdf` all pack byte *i* at `[i*8 +: 8]` — byte 0 at the **LSB** end.

Stage 6 feeds the SHA3 digest into a KMAC message, and `kmac128.msg_in` is LSB-first.
Get this wrong and every attestation tag is wrong **with every unit test still green**.

- **Option A (recommended):** reverse `SHA3_256.sv` to `[i*8 +: 8]`, add a `bswap256`
  adapter to `SHA3_TB` so the NIST literals stay readable. Zero consumers today →
  blast radius is exactly two files. Stage 6 *and* Stage 7 both read that digest.
- **Option B:** byte-swap at the Stage 6 boundary. Zero risk to Stage 2 today, but two
  conventions live in the repo permanently and it is already two swap sites.

**Kalash decides.** Apply only on a clean host, gated on `SHA3_TB` returning 49/0.

Two further SHA3 items, both report-only, both latent, neither a bug today:
- `is_final` is read **live** in `KECCAK_WAIT` (~26 cycles after `start`), not latched
  at accept. A caller that drops it early gets no digest and no error.
- No assertion on `is_final && valid_bytes == RATE_BYTES`. `sha3_pad` only pads when
  `valid_bytes < RATE_BYTES`, so a full final block silently gets no padding. FIPS 202
  requires an extra all-padding block; the contract is `valid_bytes=0, is_final=1`.

---

## 7. Coverage gaps — REPORT ONLY, do not close without being asked

1. No mutation / negative-control test in `SHA3_TB`, `kmac_tb`, `TRNG_TB`.
   `pq_keccak_tb` has one — the pattern is there to copy. Until these exist, those
   three are `smoke` regardless of their PASS banners, and nobody can answer *"how do
   you know your testbench can fail?"*
2. No L=128 KAT in `kmac_tb` — all 5 vectors are L=256, so `out_len_sel` low is the
   path Stage 5 depends on most and it has no known-answer test.
3. `pq_keccak_tb` drives only the all-zero input.
4. `pq_kdf_tb` covers context lengths {0, 13, 14} only.

---

## 8. Traps — each cost real debugging time

**Conventions that produce silent wrong answers:**
- Byte order: byte *i* at `[i*8 +: 8]` everywhere except SHA3 (see §6).
- **Reset polarity is not uniform.** `keccak_f1600` is active-HIGH synchronous `rst`;
  everything else is active-low `rst_n`. Bridge with `.rst(~rst_n)`. All three current
  instantiations do this correctly — verify any new one.
- KMAC output length is **absorbed**, not truncated:
  `KMAC128(K,X,128) != KMAC128(K,X,256)[0:16]`. `out_len_sel` has **no default port
  value** on purpose; connect it explicitly every time.
- `kmac_encode` owns `right_encode(L)` and the domain byte. Nothing else appends them.
- KDF customization is **empty**; context goes in the message. Stage 7 is the opposite.

**xvlog rejections:** `context` is reserved · no member select on a cast `t'(x).f` ·
no part-select on a function call `f(x)[7:0]` · no hierarchical ref to an enum label
`dut.STATE` · no `initial` in a `package` · no zero-width vectors ·
`{string_var, "lit"}` fails, use `$sformatf`.

**Testbench sampling:** drive at `negedge`, wait ~1 ns, sample, release after the
consuming `posedge`.

---

## 9. Errors previous sessions made — verify, do not trust

1. **A Cowork session claimed three SHA3 fixes and the `pq_kdf` rename were applied to
   disk. They were not.** The device bridge dropped mid-write, the commit failed, the
   files went out as chat attachments and were never saved. Only `kmac_tb.sv` landed.
2. Compounding it: a **49/0 `SHA3_TB` run was read as proof the patch was live.** It
   was not evidence either way — unpatched RTL with unpatched TB literals is
   self-consistent, and the patched pair would have been too. Both give 49/0.
3. An earlier session **invented an entire `noc_pkg` API** that did not exist.
4. An earlier session **judged the project by a stale zip** — claimed Stages 3/4 had no
   RTL and SHA3 was capped at 272 bytes. Both retracted; the real `SHA3_256.sv` is
   block-streaming and unbounded.
5. A port list was changed **without grepping instantiations**, breaking `kmac_tb` to 3/7.

**Standing rule: read the file in the Vivado project. Never a zip, a summary, or a
memory of one. Grep every instantiation before changing a port list.**

---

## 10. Scope

Crypto lane through Stage 5 is the active work. **NoC lane is on hold** — `NOC_PKG.sv`
shrank 30,144 → 20,347 bytes at some point with no explanation, and it is unknown
whether the M10 `rx_head_shape_ok` patch was applied. **Stage 8 (nonce origin:
verifier-issued vs tile-generated) is undecided** and gates Stages 4 and 9.

**No synthesis or implementation run exists**, so this project has no Fmax,
utilization or power numbers. Do not write one anywhere until a run produces it.

Reports live in `Claude outputs\POLISH_REPORT.md`. The `docs/` tree from the
session-log pass (decisions, verification, sessions, OPEN.md) was **never unpacked** —
it exists only as a tarball in chat.
