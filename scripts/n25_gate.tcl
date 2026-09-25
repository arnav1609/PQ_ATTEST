# n25_gate.tcl - N-2.5 timing-closure GATE on an OPEN routed design. Read-only.
# Defines: n25_gate <run_name> <out_dir>  -> writes reports + gate_summary.txt, returns PASS|FAIL
# Gate (all must hold): WNS>=0, TNS=0, WHS>=0, THS=0, WPWS>=0, 0 nets with routing errors,
# check_timing clean except the 2 known false-pathed pins (rst no_input_delay, led no_output_delay),
# 0 DRC errors, and the D7/D7b registers physically present (6 eject_wr_q, 14 link valid regs).

proc n25_parse_dts {s} {
  # Design Timing Summary: first numeric row after the "WNS(ns)" header
  set lines [split $s "\n"]
  set i [lsearch -regexp $lines {^\s*WNS\(ns\)}]
  if {$i < 0} { error "Design Timing Summary not found" }
  for {set k [expr {$i+1}]} {$k < [llength $lines]} {incr k} {
    set l [string trim [lindex $lines $k]]
    if {[regexp {^-?[0-9]} $l]} { break }
  }
  set v [regexp -all -inline {\S+} $l]
  if {[llength $v] < 12} { error "DTS row malformed: $l" }
  return [dict create WNS [lindex $v 0] TNS [lindex $v 1] TNS_FAIL [lindex $v 2] TNS_TOT [lindex $v 3] \
                      WHS [lindex $v 4] THS [lindex $v 5] THS_FAIL [lindex $v 6] \
                      WPWS [lindex $v 8] TPWS [lindex $v 9] TPWS_FAIL [lindex $v 10]]
}

proc n25_parse_check_timing {s} {
  set bad {}
  foreach {all name n} [regexp -all -inline {[0-9]+\. checking (\w+) \(([0-9]+)\)} $s] {
    if {$n == 0} continue
    if {($name eq "no_input_delay" || $name eq "no_output_delay") && $n <= 1} continue
    lappend bad "$name=$n"
  }
  return $bad
}

proc n25_util {s key} {
  if {[regexp "\\|\\s*${key}\\*?\\s*\\|\\s*(\[0-9\]+)" $s -> n]} { return $n }
  return NA
}

proc n25_gate {run out} {
  file mkdir $out
  set ts [report_timing_summary -max_paths 10 -report_unconstrained -check_timing_verbose -return_string]
  set fh [open [file join $out timing_summary_routed.rpt] w]; puts $fh $ts; close $fh
  report_route_status -file [file join $out route_status.rpt]
  set rs [report_route_status -return_string]
  report_utilization -file [file join $out utilization_routed.rpt]
  set us [report_utilization -return_string]
  report_utilization -hierarchical -hierarchical_depth 4 -file [file join $out util_hier_routed.rpt]
  report_methodology -file [file join $out methodology_routed.rpt]
  report_power -file [file join $out power_routed.rpt]

  set d  [n25_parse_dts $ts]
  set ct [n25_parse_check_timing $ts]
  set route_err NA
  regexp {nets with routing errors[ .]*:\s*([0-9]+)} $rs -> route_err

  set drc_err NA
  if {![catch {report_drc -name n25_drc -file [file join $out drc_routed.rpt]}]} {
    if {[catch {set drc_err [llength [get_drc_violations -quiet -name n25_drc -filter {SEVERITY == Error}]]}]} {set drc_err NA}
  }

  # D7 / D7b physical presence (replicas excluded)
  set n_ej  [llength [get_cells -quiet -hier -filter {IS_SEQUENTIAL && NAME =~ "*eject_wr_q_reg*" && NAME !~ "*replica*"}]]
  set n_ejd [llength [get_cells -quiet -hier -filter {IS_SEQUENTIAL && NAME =~ "*eject_flit_q_reg*" && NAME !~ "*replica*"}]]
  set n_lk  [llength [get_cells -quiet -hier -filter {IS_SEQUENTIAL && NAME =~ "*qv_*_reg*" && NAME !~ "*replica*"}]]

  # Worst path: start/end, levels, route share
  set wp [lindex [get_timing_paths -setup -max_paths 1 -nworst 1] 0]
  set wsp [get_property NAME [get_property STARTPOINT_PIN $wp]]
  set wep [get_property NAME [get_property ENDPOINT_PIN $wp]]
  set wll [get_property LOGIC_LEVELS $wp]
  set wdd [get_property DATAPATH_DELAY $wp]
  set wnd NA; catch {set wnd [get_property DATAPATH_NET_DELAY $wp]}

  set fails {}
  if {[dict get $d WNS]  < 0} {lappend fails "WNS=[dict get $d WNS]"}
  if {[dict get $d TNS] != 0} {lappend fails "TNS=[dict get $d TNS]"}
  if {[dict get $d WHS]  < 0} {lappend fails "WHS=[dict get $d WHS]"}
  if {[dict get $d THS] != 0} {lappend fails "THS=[dict get $d THS]"}
  if {[dict get $d WPWS] < 0} {lappend fails "WPWS=[dict get $d WPWS]"}
  if {$route_err ne "0"} {lappend fails "route_errors=$route_err"}
  if {[llength $ct]} {lappend fails "check_timing: $ct"}
  if {$drc_err ne "0"} {lappend fails "DRC_errors=$drc_err"}
  if {$n_ej != 6} {lappend fails "eject_wr_q regs=$n_ej (expect 6)"}
  if {$n_lk != 14} {lappend fails "link valid regs=$n_lk (expect 14)"}
  set verdict [expr {[llength $fails] ? "FAIL" : "PASS"}]

  set git NA; catch {set git [string trim [exec git -C [get_property DIRECTORY [current_project]] rev-parse --short HEAD]]}
  set L {}
  lappend L "N-2.5 GATE | run $run | [clock format [clock seconds]] | Vivado [version -short] | [get_property PART [current_design]]"
  lappend L "git HEAD $git | strategy [get_property STRATEGY [get_runs $run]] | clock period [get_property PERIOD [get_clocks clk]] ns"
  lappend L [format "setup  WNS %s  TNS %s  failing %s / %s endpoints" [dict get $d WNS] [dict get $d TNS] [dict get $d TNS_FAIL] [dict get $d TNS_TOT]]
  lappend L [format "hold   WHS %s  THS %s  failing %s" [dict get $d WHS] [dict get $d THS] [dict get $d THS_FAIL]]
  lappend L [format "pulse  WPWS %s  TPWS %s" [dict get $d WPWS] [dict get $d TPWS]]
  lappend L "route  nets with routing errors: $route_err | DRC errors: $drc_err | check_timing issues: [expr {[llength $ct] ? $ct : {none (rst/led known)}}]"
  lappend L "util   LUT [n25_util $us {Slice LUTs}] | LUTRAM [n25_util $us {LUT as Memory}] | FF [n25_util $us {Slice Registers}] | BRAM [n25_util $us {Block RAM Tile}] | DSP [n25_util $us DSPs]"
  lappend L "D7/D7b present: eject_wr_q $n_ej/6 | eject_flit_q bits $n_ejd (<=216) | link valid regs $n_lk/14"
  lappend L "worst  $wsp -> $wep | levels $wll | data $wdd ns | net $wnd ns"
  lappend L "VERDICT $verdict [expr {[llength $fails] ? "- $fails" : "- timing closed at [get_property PERIOD [get_clocks clk]] ns"}]"
  set fh [open [file join $out gate_summary.txt] w]; puts $fh [join $L "\n"]; close $fh
  puts "\n================ N-2.5 GATE ================"; puts [join $L "\n"]; puts "============================================"
  return $verdict
}
