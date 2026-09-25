# N-2.5 run 2 — mesh with D7 LINK_PIPE=1 (2026-09-23, Kalash, GUI)

Provenance: Vivado 2024.1 GUI project flow, default strategies, xc7a100tcsg324-1, 20.000 ns.
RTL = commit 041a036 (LINK_PIPE=1 default, EJECT_PIPE did not exist yet). Synth 23:07 IST, route 23:13 IST.
LINK_PIPE confirmed live in the netlist: FF 1,437 -> 1,955 post-synth (+518 = 14 links x 37 bits, exact).

| metric | run 1 (no link reg) | run 2 (LINK_PIPE=1) |
|---|---|---|
| LUT post-place | 10,652 | 10,417 (16.43%) |
| FF post-place | 1,438 | 1,956 |
| WNS | -1.301 ns | **-0.317 ns** |
| TNS | -1535.499 ns | -9.265 ns |
| failing endpoints | 2,648 / 16,785 | **50** / 17,793 |
| WHS | +0.035 | +0.029 |

Run 2 worst path (all top-10 identical class): R0 local_vc0 FIFO rd_ptr -> LUTRAM head -> route/lock
-> input arbiter -> output arbiter -> crossbar valid -> eject FIFO LUTRAM WE (fanout 52).
20 levels, data 19.703 ns, 83% route. Entirely INSIDE one router.
Predicted by run-1 triage: all 132 intra-router failures were eject-FIFO LUTRAM pins (worst -0.343).
Fix: D7b EJECT_PIPE=1 in noc_router (register before the eject FIFO). Run-1 triage says the next
intra-router wall after that was ~+0.40 ns (eject count CE / rd_ptr) - an ESTIMATE, placement differs.
Not yet triaged per-endpoint for run 2 (only top-10 paths in the summary).
