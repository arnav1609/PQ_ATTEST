# n25_physopt.tcl - ONE pre-agreed tool-only attempt if run 3 misses by a small setup margin.
# New run impl_pe (strategy Performance_ExplorePostRoutePhysOpt) on the SAME synth_1; impl_1 kept.
#   source C:/vivado_verilog_proj/NOC_PQATTEST/scripts/n25_physopt.tcl
set R    C:/vivado_verilog_proj/NOC_PQATTEST
set DATE [clock format [clock seconds] -format %Y-%m-%d]
source $R/scripts/n25_gate.tcl
foreach d [get_designs -quiet] { current_design $d; close_design }
if {[llength [get_runs -quiet impl_pe]]} { reset_run impl_pe } else {
  create_run impl_pe -parent_run synth_1 -flow {Vivado Implementation 2024} -strategy Performance_ExplorePostRoutePhysOpt
}
launch_runs impl_pe -jobs 4
wait_on_run impl_pe
if {[get_property PROGRESS [get_runs impl_pe]] ne "100%"} { error "impl_pe failed: [get_property STATUS [get_runs impl_pe]]" }
open_run impl_pe -name impl_pe
set V [n25_gate impl_pe $R/reports/n25_run3pe_$DATE]
set TRIAGE_DIR n25_run3pe_$DATE
set TRIAGE_RUN impl_pe
source $R/scripts/n25_timing_triage.tcl
puts [expr {$V eq "PASS" ? "PHYSOPT PASS -> closed by strategy (record: margin is tool-dependent)." : "PHYSOPT FAIL -> STOP. Council decision on allocator pipelining before any RTL."}]
