# D7 regression: LINK_PIPE link stage in noc_mesh_3x2 + noc_fifo pointer-assert fix.
# Runs, each from a CLEAN snapshot with a recompile proof, logs saved after close_sim:
#   N-7 with TB_LINK_PIPE=1 (default, the synthesized config)   -> logs/n7_pipe1_d7_<date>.log
#   N-7 with TB_LINK_PIPE=0 (pre-D7 wiring, must still be 1762/0) -> logs/n7_pipe0_d7_<date>.log
#   M8, N-6, TB1 (touched only by the noc_fifo assertion fix)      -> logs/{n35_m8,n6,n2_tb1}_d7_<date>.log
# Usage (Vivado Tcl console, project open, no simulation running):
#   source C:/vivado_verilog_proj/NOC_PQATTEST/scripts/d7_regression.tcl
set R    C:/vivado_verilog_proj/NOC_PQATTEST
set XDIR $R/NOC_PQATTEST.sim/sim_1/behav/xsim
set DATE [clock format [clock seconds] -format %Y-%m-%d]
# Log tag: set RTAG before sourcing (default d7).
if {![info exists RTAG]} {set RTAG d7}
set SIM  [get_filesets sim_1]
set MO   {xsim.elaborate.xelab.more_options}
set MO_SAVED [get_property $MO $SIM]
update_compile_order -fileset sources_1

proc d7_run {top tag {elab_extra ""}} {
  global R XDIR DATE SIM MO MO_SAVED RTAG
  puts "\n######## $tag ($top) elab_extra={$elab_extra} ########"
  set_property top $top $SIM
  set_property top_lib xil_defaultlib $SIM
  set_property -name $MO -value [string trim "$MO_SAVED $elab_extra"] -objects $SIM
  after 5000
  catch {reset_simulation -simset sim_1 -mode behavioral}
  set_property -name {xsim.simulate.runtime} -value {1ns} -objects $SIM
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
  file copy -force $XDIR/simulate.log $R/logs/${tag}_${RTAG}_${DATE}.log
  puts "saved logs/${tag}_${RTAG}_${DATE}.log"
}

set err [catch {
  d7_run tb_noc_mesh_n7          n7_pipe1
  d7_run tb_noc_mesh_n7          n7_pipe0 {-generic_top TB_LINK_PIPE=0}
  d7_run tb_noc_router_m9_credit n35_m8
  d7_run tb_n6_two_tile_stress   n6
  d7_run tb_noc_stage2           n2_tb1
} emsg]
set_property -name $MO -value $MO_SAVED -objects $SIM
set_property -name {xsim.simulate.runtime} -value {20us} -objects $SIM
if {$err} { puts "SCRIPT ERROR: $emsg" }
puts "Regression ($RTAG) finished. Expect: pipe1 1756/0 (T7 has 6 fewer link checks - 3 flits"
puts "cleared inside link registers by the mid-run reset), pipe0 1762/0, M8 47/0, N-6 126/0, TB1 PASS."
