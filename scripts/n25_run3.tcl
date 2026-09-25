# n25_run3.tcl - N-2.5 RUN 3 (D7 LINK_PIPE + D7b EJECT_PIPE), end to end, GUI Tcl console.
#   source C:/vivado_verilog_proj/NOC_PQATTEST/scripts/n25_run3.tcl
# Steps: [1] XSim regression (RTAG d7b) -> [2] regression check, STOP on any failure
#        [3] reset + synth + impl (default strategy) -> [4] gate + triage + archived reports
# Set N25_SKIP_SIM 1 before sourcing to skip [1] (the log check [2] still runs).
# Set N25_SKIP_SYNTH 1 to reuse a completed, up-to-date synth_1.
# Takes ~15-25 min. Do not touch the GUI while it runs.
set R    C:/vivado_verilog_proj/NOC_PQATTEST
set DATE [clock format [clock seconds] -format %Y-%m-%d]
set OUT  $R/reports/n25_run3_$DATE
source $R/scripts/n25_gate.tcl

# ---------- [1] + [2] regression ----------
proc r3_check {f want} {
  # want = "<checks>/<errors>" or "PASS/0" for TB1. Line-anchored so ProtocolErrors is not read as Errors.
  if {![file exists $f]} { return "MISSING $f" }
  set fh [open $f]; set t [read $fh]; close $fh
  if {$want eq "PASS/0"} {
    if {[regexp {OVERALL\s*:\s*(PASS|FAIL)\s*\(([0-9]+) failures\)} $t -> a b]} {
      return [expr {"$a/$b" eq $want ? "OK" : "GOT $a/$b WANT $want"}]
    }
    return "NO RESULT LINE"
  }
  if {![regexp {(?n)^\s*Checks\s*=\s*([0-9]+)} $t -> a]} { return "NO Checks LINE" }
  if {![regexp {(?n)^\s*Errors\s*=\s*([0-9]+)} $t -> b]} { return "NO Errors LINE" }
  if {![regexp {(?n)^\s*RESULT\s*=\s*PASS} $t]} { return "GOT $a/$b, RESULT not PASS" }
  return [expr {"$a/$b" eq $want ? "OK" : "GOT $a/$b WANT $want"}]
}
if {![info exists N25_SKIP_SIM] || !$N25_SKIP_SIM} {
  set RTAG d7b
  source $R/scripts/d7_regression.tcl
}
set reg [list \
  n7_pipe1 [r3_check $R/logs/n7_pipe1_d7b_$DATE.log 1756/0] \
  n35_m8   [r3_check $R/logs/n35_m8_d7b_$DATE.log   47/0] \
  n6       [r3_check $R/logs/n6_d7b_$DATE.log       126/0] \
  n2_tb1   [r3_check $R/logs/n2_tb1_d7b_$DATE.log   PASS/0] ]
set bad 0
puts "\n---- D7b regression ----"
foreach {k v} $reg { puts [format "%-9s %s" $k $v]; if {$v ne "OK"} {set bad 1} }
puts "(n7_pipe0 is informational - Verilator covers it)"
if {$bad} { error "REGRESSION NOT CLEAN - synthesis NOT started. Fix/rerun first." }

# ---------- [3] synth + impl ----------
# wait_on_run can return an ERROR even when the run finished: Vivado's
# "Spawn failed: No error" (host fact) poisons it. So never trust its return
# value - wait, then judge the run by its own PROGRESS/STATUS properties.
proc r3_wait {run} {
  if {[catch {wait_on_run $run} e]} { puts "NOTE: wait_on_run $run said: $e (checking run status instead)" }
  for {set i 0} {$i < 720 && [get_property PROGRESS [get_runs $run]] ne "100%" && ![string match "*ERROR*" [get_property STATUS [get_runs $run]]]} {incr i} {
    after 5000
  }
  set st [get_property STATUS [get_runs $run]]
  set pr [get_property PROGRESS [get_runs $run]]
  puts "$run: PROGRESS $pr | STATUS $st"
  if {$pr ne "100%" || [string match "*ERROR*" $st]} { error "$run did not complete: $st" }
}
foreach d [get_designs -quiet] { current_design $d; close_design }
set_property top noc_mesh_synth_top [get_filesets sources_1]
update_compile_order -fileset sources_1
set skip_synth [expr {[info exists N25_SKIP_SYNTH] && $N25_SKIP_SYNTH && [get_property PROGRESS [get_runs synth_1]] eq "100%" && ![get_property NEEDS_REFRESH [get_runs synth_1]]}]
if {$skip_synth} {
  puts "synth_1 already complete and up to date - reusing it"
} else {
  reset_run synth_1
  launch_runs synth_1 -jobs 4
  r3_wait synth_1
}
reset_run impl_1
launch_runs impl_1 -jobs 4
r3_wait impl_1

# ---------- [4] gate + triage + archive ----------
open_run impl_1 -name impl_1
set V [n25_gate impl_1 $OUT]
set TRIAGE_DIR n25_run3_$DATE
set TRIAGE_RUN impl_1
source $R/scripts/n25_timing_triage.tcl
file copy -force $R/NOC_PQATTEST.runs/synth_1/noc_mesh_synth_top_utilization_synth.rpt $OUT/synth_utilization.rpt
file copy -force $R/NOC_PQATTEST.runs/synth_1/runme.log $OUT/synth_runme.log.txt
file copy -force $R/NOC_PQATTEST.runs/impl_1/runme.log  $OUT/impl_runme.log.txt
if {$V eq "PASS"} {
  puts "\nRUN 3 PASS -> timing closed. Next: M-F1 interface-freeze draft."
} else {
  puts "\nRUN 3 FAIL -> paste gate_summary.txt + triage_summary.txt. If ONLY small setup"
  puts "negatives: source scripts/n25_physopt.tcl (one PhysOpt attempt, pre-agreed D6/D7)."
}
