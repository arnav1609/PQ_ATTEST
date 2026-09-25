# N-2.5 run 1 — 3x2 NoC mesh, synth + impl (2026-09-23)

Provenance: Vivado 2024.1 (win64, build 5076996), GUI project flow, default synth/impl strategies,
part xc7a100tcsg324-1, `create_clock -period 20.000` (synth/n25_mesh.xdc), top `noc_mesh_synth_top`.
RTL = commit 609550c (no RTL modified in the working tree at run time). Wrapper as synthesized:
`noc_mesh_synth_top.AS_SYNTHESIZED.sv` (comment/format-only diff vs 8ac48c9; logic identical).
Run artifacts copied verbatim from NOC_PQATTEST.runs/{synth_1,impl_1} (runme.log renamed *.log.txt).
Synth end 21:52 IST, route end ~21:55 IST.

| metric | value | stage |
|---|---|---|
| LUT | 10,371 (16.36%) = 8,259 logic + 2,112 LUTRAM | post-synth |
| LUT | 10,652 (16.80%), LUTRAM 1,716 | post-place |
| FF | 1,437 / 1,438 | synth / place |
| BRAM / DSP | 0 / 0 | |
| WNS / TNS | -1.301 ns / -1535.499 ns, 2,648 of 16,785 endpoints | post-route |
| WHS | +0.035 ns | post-route |
| Power | 0.155 W (0.058 dynamic), vectorless | post-route |

Verdict vs council gate D6: area GREEN, timing YELLOW -> D7 applied (LINK_PIPE in noc_mesh_3x2).
These numbers describe the PRE-D7 mesh (combinational router->router links). They are superseded
for timing by run 2 once it exists; keep this folder as the before-picture.

Triage (scripts/n25_timing_triage.tcl) adds util_hier_routed.rpt, paths_lt3ns.csv, triage_summary.txt.
