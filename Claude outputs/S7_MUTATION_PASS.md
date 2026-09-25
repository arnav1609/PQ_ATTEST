# Task 1 — S-7 Mutation Pass (ready to run via the WORKING Vivado flow)

Baseline verified: `NOC_PQATTEST.sim/sim_1/behav/xsim/simulate.log` (2026-09-19 00:08)
= **CHECKS 105 / ERRORS 0 / STAGE 7 PASS**. The TB and DUT complete in ~6 s elapsed
via Vivado `launch_simulation` (`--debug typical`). Do NOT use headless `xsim -R` on
this host — it hangs (observed twice: pq_kdf_tb, pqattest_tb). Use `launch_simulation`.

Prerequisite: **reboot first** to clear the orphaned `xsim.exe`/`xsimk.exe` kernels
(they wedge XSim → rc=139). Never `taskkill`; reboot. `vivado.exe` must be closed.

For each mutation: apply the edit → in Vivado Tcl `relaunch_simulation` → read the
named checks in `simulate.log` → **revert the edit**. One mutation live at a time.
`git stash` / re-copy the pristine file after each. All edits are to the DUT/pkg,
never the TB.

---

## Mutation 1 — empty customization
File `pqattest_stg7.sv`, line 149.
```
- assign kmac_custom_len = AUTH_CUSTOM_BYTES;   // 14
+ assign kmac_custom_len = 5'd0;                 // MUT1
```
MUST FAIL: `V08 customization check : tag` and `V08 : customization is NOT empty`.
(Empty S makes the DUT emit V08_EMPTY_CUSTOM, which is exactly what that check forbids.)

## Mutation 2 — output length hardwired
File `pqattest_stg7.sv`, line 312.
```
- .out_len_sel  ((len_sel_q == TAG_LEN_256) ? KMAC_L_256 : KMAC_L_128),
+ .out_len_sel  (KMAC_L_256),                    // MUT2
```
MUST FAIL: `V07 baseline L=128 : tag[127:0]` and
`V07 : L=128 tag is NOT the truncated L=256 tag`.
(Forcing L=256 makes the L=128 request return the truncated L=256 tag — the exact
"absorbed not truncated" property the check guards.)

## Mutation 3 — transcript field offsets swapped
File `pqattest_stg7_pkg.sv`, lines 77-78.
```
- localparam int NONCE_OFF = EPOCH_OFF + EPOCH_BYTES;        // 17
- localparam int MEAS_OFF  = NONCE_OFF + NONCE_BYTES;        // 33
+ localparam int NONCE_OFF = 33;   // MUT3 swapped
+ localparam int MEAS_OFF  = 17;   // MUT3 swapped
```
MUST FAIL: `V04 NONCE mutation : tag` and `V05 MEASUREMENT mutation : tag`
(and V01 baseline tag too — the transcript layout is wrong for every vector).

## Mutation 4 — accept a request field while busy  (adapted to this FSM)
The work order's `(state_q == S_IDLE) &&` wording does not match this DUT; the guard is
the `case(state_q)`/`S_IDLE:` dispatch. A naive re-latch in S_WAIT would NOT change the
tag because `kmac128` already latched its inputs at `kmac_start_q`. The minimal faithful
mutation is to let a start-while-busy overwrite a *latched* field the parent still reads
at done — `len_sel_q`:

File `pqattest_stg7.sv`, in `S_WAIT:` (line ~241), insert one line before `if (kmac_done)`:
```
  S_WAIT: begin
+     if (start) len_sel_q <= tag_len_sel;   // MUT4: field accepted while busy
      if (kmac_done) begin
```
MUST FAIL: `start while busy : second request was NOT latched` (tag becomes the
zero-extended L=128 form, != V01) and `start while busy : tag_len_sel NOT overwritten`
(tag_bytes reads 16, not 32).

---

## Acceptance
Five `simulate.log` captures: mut1..mut4 each showing its named FAIL(s) with a non-zero
ERRORS count, then a final reverted run showing **105 / 0** again and `git diff` empty.
If any mutation still gives 105/0, that check is vacuous — report it, do not patch around.

## RESULTS — executed 2026-09-19/20 (Vivado GUI, live Tcl console as record)

Supersedes the "NOT yet executed" note that stood here. Source of record:
project doc `claude/pq-attest-verification-status.md` (console captures).

| Mut | Injected | CHECKS / ERRORS | Checks that fired |
|---|---|---|---|
| M1 | `kmac_custom_len = 5'd0` | 105 / 14 | `V08 : customization is NOT empty` + `V08 ... : tag` |
| M2 | `out_len_sel` tied `KMAC_L_256` | 105 / 2 | `V07 ... : tag[127:0]` + `V07 : L=128 tag is NOT the truncated L=256 tag` |
| M3 | `NONCE_OFF` / `MEAS_OFF` swapped | 105 / 13 | `V04 ... : tag` + `V05 ... : tag` |
| M4 | `len_sel_q` overwritten while busy (corrected form, see above) | 105 / 2 | both `start while busy` checks |
| -- | reverted | 105 / 0 | `git diff` empty |

4/4 caught.

### Finding from M3 (fixed)
MEAS overwrote NONCE in the transcript, so V01 and V04 tags were identical,
yet `V04 NONCE mutation : freshness is bound into the tag` still PASSED: it
compared against the golden constant V01. Fixed by capturing the observed
baseline into `obs_v01`; all seven differs-from-baseline sites now use it.
2026-09 recovery: the V07 truncation check was moved to `obs_v01` as well.

### Still owed on the CURRENT tree (TB edited since the pass)
- Run A: reverted DUT -> expect 105 / 0.
- Run B: re-apply M3 -> expect a non-zero ERRORS count that now INCLUDES
  `V04 NONCE mutation : freshness is bound into the tag`.
Until both are captured to `logs/`, the obs_v01 fix is written, not proven.
