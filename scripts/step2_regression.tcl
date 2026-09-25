# Path-to-N-8, STEP 2: regression on the new synthesizable noc_mesh_3x2.
# Runs N-7 (now instantiating noc_mesh_3x2), M8, N-6, TB1 - each from a CLEAN
# snapshot (reset_simulation) with a recompile proof, logs saved after close_sim.
# Usage (Vivado Tcl console):  source C:/vivado_verilog_proj/NOC_PQATTEST/scripts/step2_regression.tcl
set R    C:/vivado_verilog_proj/NOC_PQATTEST
set XDIR $R/NOC_PQATTEST.sim/sim_1/behav/xsim
set MESH $R/NOC_PQATTEST.srcs/sources_1/new/noc_mesh_3x2.sv
set DATE [clock format [clock seconds] -format %Y-%m-%d]

# REQUIRED: the new RTL file is not in the project yet.
if {[llength [get_files -quiet $MESH]] == 0} {
  add_files -norecurse -fileset sources_1 $MESH
  puts "ADDED noc_mesh_3x2.sv to sources_1"
} else {
  puts "noc_mesh_3x2.sv already in project"
}
set_property is_enabled true [get_files $MESH]
update_compile_order -fileset sources_1

proc s2_run {top tag} {
  global R XDIR DATE
  puts "\n######## $tag ($top) ########"
  set_property top $top [get_filesets sim_1]
  set_property top_lib xil_defaultlib [get_filesets sim_1]
  after 5000
  catch {reset_simulation -simset sim_1 -mode behavioral}
  set_property -name {xsim.simulate.runtime} -value {1ns} -objects [get_filesets sim_1]
  set t0 [clock seconds]
  set ok 0
  for {set t 0} {$t < 3 && !$ok} {incr t} {
    if {[catch {launch_simulation} e]} { puts "launch retry ($t): $e"; after 5000 } else { set ok 1 }
  }
  if {!$ok} { puts "$tag: launch FAILED 3x"; return }
  set sdb $XDIR/xsim.dir/xil_defaultlib/${top}.sdb
  if {[file exists $sdb] && [file mtime $sdb] >= $t0} {
    puts "$tag: RECOMPILED ${top}.sdb @ [clock format [file mtime $sdb]]"
  } else {
    puts "$tag: *** ${top} NOT RECOMPILED - RESULT INVALID ***"
  }
  catch {run all}
  catch {close_sim}
  file copy -force $XDIR/simulate.log $R/logs/${tag}_step2_${DATE}.log
  puts "saved logs/${tag}_step2_${DATE}.log"
}

set err [catch {
  s2_run tb_noc_mesh_n7          n7_mesh3x2
  s2_run tb_noc_router_m9_credit n35_m8
  s2_run tb_n6_two_tile_stress   n6
  s2_run tb_noc_stage2           n2_tb1
} emsg]
set_property -name {xsim.simulate.runtime} -value {20us} -objects [get_filesets sim_1]
if {$err} { puts "SCRIPT ERROR: $emsg" }
puts "STEP 2 regression script finished"
