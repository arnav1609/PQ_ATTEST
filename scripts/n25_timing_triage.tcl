# n25_timing_triage.tcl - N-2.5 step 4, read-only analysis of the ROUTED impl_1.
# Run in the Vivado GUI Tcl console with NOC_PQATTEST.xpr open:
#     source C:/vivado_verilog_proj/NOC_PQATTEST/scripts/n25_timing_triage.tcl
# Changes NOTHING in the design or project. Writes into reports/$TRIAGE_DIR/:
#   util_hier_routed.rpt      per-router / per-submodule LUT, LUTRAM, FF
#   paths_lt3ns.csv           every endpoint with setup slack < 3.0 ns (worst path each)
#   triage_summary.txt        inter- vs intra-router split, worst slack per class
set proj_dir [get_property DIRECTORY [current_project]]
# Output folder: set TRIAGE_DIR before sourcing to avoid overwriting an earlier run's triage.
if {![info exists TRIAGE_DIR]} {set TRIAGE_DIR n25_2026-09-23}
set out [file join $proj_dir reports $TRIAGE_DIR]
file mkdir $out

set d ""
catch {set d [current_design]}
if {![info exists TRIAGE_RUN]} {set TRIAGE_RUN impl_1}
if {$d ne $TRIAGE_RUN} { open_run $TRIAGE_RUN -name $TRIAGE_RUN }

report_utilization -hierarchical -hierarchical_depth 4 -file [file join $out util_hier_routed.rpt]

set paths [get_timing_paths -setup -max_paths 20000 -nworst 1 -unique_pins -slack_lesser_than 3.0]
set fh [open [file join $out paths_lt3ns.csv] w]
puts $fh "slack_ns,logic_levels,src_router,dst_router,class,src_pin,dst_pin"
array set cnt {}; array set worst {}
foreach p $paths {
    set s  [get_property SLACK $p]
    set ll [get_property LOGIC_LEVELS $p]
    set sp [get_property NAME [get_property STARTPOINT_PIN $p]]
    set ep [get_property NAME [get_property ENDPOINT_PIN $p]]
    if {![regexp {GEN_R\[([0-9])\]} $sp -> sr]} {set sr -}
    if {![regexp {GEN_R\[([0-9])\]} $ep -> dr]} {set dr -}
    if {$sr eq "-" || $dr eq "-"} {set c wrapper} elseif {$sr eq $dr} {set c intra} else {set c inter}
    if {$c eq "intra" && [string match *u_eject_fifo* $ep]} {set c intra_eject}
    if {$s < 0} {set k "$c,FAIL"} else {set k "$c,pass"}
    if {![info exists cnt($k)]} {set cnt($k) 0; set worst($k) $s}
    incr cnt($k)
    if {$s < $worst($k)} {set worst($k) $s}
    puts $fh "$s,$ll,$sr,$dr,$c,$sp,$ep"
}
close $fh

set fs [open [file join $out triage_summary.txt] w]
puts $fs "N-2.5 triage | $TRIAGE_RUN routed | [clock format [clock seconds]] | [llength $paths] endpoints with slack < 3.0 ns"
puts $fs "class,status : endpoints  worst_slack_ns"
foreach k [lsort [array names cnt]] { puts $fs [format "%-14s : %6d  %8.3f" $k $cnt($k) $worst($k)] }
close $fs
puts "TRIAGE DONE -> $out"
set fr [open [file join $out triage_summary.txt] r]; puts [read $fr]; close $fr
